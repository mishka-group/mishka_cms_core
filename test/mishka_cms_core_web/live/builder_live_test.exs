defmodule MishkaCmsCoreWeb.Test.BuilderLiveTest do
  @moduledoc """
  End-to-end tests for the visual page builder, driven through the real LiveView.

  Everything here is asserted by stable `pb-*` DOM id, which is the house rule and also the thing
  that makes this suite survive a restyle. The React editor had no test of this kind at any level,
  which is how it shipped with a save endpoint that was never routed.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.PageStarter
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.BuilderPageStarterPlugin, as: PageStarterPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe, as: ToolbarInvokedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarProbe, as: ToolbarProbe

  require Ash.Query

  @password "Password123!"
  @template ~s(<section id="hero"><h1>Contact Us</h1><p>Reach out any time.</p></section>)

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    page = create_page!(site_id: site.id, template: @template)

    # `SiteState` is process-global ETS, not sandboxed, so a cached site outlives this test's
    # transaction. Leaving "localhost" behind breaks any sibling that asserts a host does NOT
    # resolve — which is exactly how it broke ApiTenantLookupPlugTest.
    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, create_admin("boss@example.com")), site: site, page: page}
  end

  defp cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp create_admin(email, site_id \\ nil, permissions \\ ["*"]) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    for permission <- permissions do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
      |> Ash.create!(authorize?: false)
    end

    user
  end

  # A fresh conn on a site's own address, the test host unless told — the setup's conn is already
  # signed in as the master.
  defp build_conn_for_host(host \\ "localhost") do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Writing the live record is Publish, and Publish is two gestures: the stage is chosen, then the
  # button beside it carries it out.
  defp publish!(view) do
    render_click(view, "set_stage", %{"stage" => "published"})
    render_click(view, "apply_stage", %{})
  end

  defp undo!(view), do: more!(view, "#pb-undo")
  defp redo!(view), do: more!(view, "#pb-redo")

  # The ••• button TOGGLES, so opening an already-open menu closes it — two menu actions in a row
  # then fail to find the second item.
  defp more!(view, id) do
    unless has_element?(view, id), do: view |> element("#pb-more-btn") |> render_click()
    view |> element(id) |> render_click()
  end

  defp open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    {:ok, view, render_async(view)}
  end

  # A plugin registered for the length of one test, exactly as an extension registers one.
  defp register_plugin(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)

    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  # The avatar row's letters: yours first, then everyone else's.
  defp avatars(view),
    do:
      view
      |> element("#pb-avatars")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pb-avatars > span")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token

  # An element's own opening tag, for asserting on ITS classes rather than its children's.
  defp opening_tag(html), do: html |> String.split(">", parts: 2) |> hd()

  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)

  # The compiled bundles the frame is served. Read off the LiveView rather than out of its HTML,
  # because the `<link>` is rendered by the root layout — see the canvas tests for why it moved.
  defp css_hrefs(view), do: :sys.get_state(view.pid).socket.assigns.canvas_css_hrefs

  defp editor_html(view) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()
  end

  # The `{@inner_content}` chip — a layout's one obligation, and the node most of these tests act on.
  defp expression_node(view),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :eex))

  defp node_with_tag(view, tag) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.tag == tag))
  end

  # The style overrides a node actually carries — what every control in the Layout and Appearance
  # sections is a way of writing, and the only record of them there is.
  defp styles_of(view, node_id),
    do:
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.get(node_id)
      |> then(&Map.get(&1.meta, :styles, %{}))

  describe "mount" do
    # The editor takes the whole viewport, like the prototype: no admin sidebar, no admin topbar, no
    # 1340px content column. It is a `h-screen` three-column workspace, and nesting it in the admin
    # shell's scrolling, padded, width-capped `<main>` costs it the canvas and adds a second
    # scrollbar. Every other admin page keeps the shell — this is the one exception, so it is pinned.
    test "the editor is a full page: no admin sidebar, topbar or content column", %{
      conn: conn,
      page: page
    } do
      {:ok, view, html} = open_builder(conn, page)

      refute has_element?(view, "#admin-sidebar")
      refute html =~ "max-w-[1340px]"
      refute html =~ "Admin console"

      # The shell's own two contributions are still there: the theme treatment and flashes.
      assert html =~ "data-theme=dark"
      assert has_element?(view, "#pb-root")
    end

    test "an error still surfaces without the admin shell's flash group", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "op", %{"kind" => "delete", "node_id" => "nnotanode"})

      assert has_element?(view, "#flash-error")
    end

    test "parses the page's template into a session tree", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      tags = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.tag)

      assert "section" in tags
      assert "h1" in tags
      assert "p" in tags
    end

    test "embeds the canvas iframe addressed by the session token", %{conn: conn, page: page} do
      {:ok, view, html} = open_builder(conn, page)

      assert html =~ "/admin/dashboard/runtime/builder-canvas/#{token(view)}"
      assert has_element?(view, "#pb-frame-desktop")
    end

    test "every device button is present", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      for device <- ~w(frames desktop tablet mobile) do
        assert has_element?(view, "#pb-device-#{device}")
      end
    end

    test "an unknown section redirects instead of crashing", %{conn: conn} do
      assert {:error, {:redirect, _redirect}} =
               live(conn, "/admin/dashboard/runtime/builder/spreadsheet")
    end

    test "a new page opens an empty document", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page")

      assert view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots) == []
    end
  end

  describe "the canvas LiveView" do
    # WHAT AN EMPTY PAGE OFFERS. The dashed well this replaces told the reader to "pick a
    # component on the left", which asks someone who has never built a page to already know what the
    # first thing should be. The chooser answers that question once and then gets out of the way.
    test "an empty page offers the starter, and picking one fills it", %{conn: conn, site: site} do
      empty =
        create_page!(
          site_id: site.id,
          template: MishkaCmsCore.Runtime.PageBuilder.PageStarter.blank()
        )

      {:ok, view, _html} = open_builder(conn, empty)

      # Emptied right back out — the same state a page created with no markup opens in once its one
      # container is removed.
      render_click(view, "op", %{"kind" => "delete", "node_id" => hd(editor(view).tree.roots)})
      assert editor(view).tree.roots == []

      {:ok, canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-page-starter"
      assert html =~ "This page is empty"
      assert html =~ "pb-starter-two"
      refute html =~ "Choose a layout", "Runtime's Layout is a different thing entirely"

      render_click(canvas, "page_starter", %{"structure" => "two"})

      tree = editor(view).tree
      assert length(tree.roots) == 1, "a structure arrives as ONE undoable insert"
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize(tree) =~ "grid-cols-2"
    end

    # AND A STARTER AN EXTENSION BROUGHT IS ONE OF THEM. The chooser has always drawn the merged
    # list, while the click was resolved against the core's four alone — so a plugin's card was a
    # button with nothing behind it: no structure, no error, and nothing in the log either.
    test "a contributed starter lays out its own structure", %{conn: conn, site: site} do
      register_plugin(PageStarterPlugin, "builder:page_starters")
      structure = PageStarterPlugin.structure()

      empty = create_page!(site_id: site.id, template: PageStarter.blank())
      {:ok, view, _html} = open_builder(conn, empty)
      render_click(view, "op", %{"kind" => "delete", "node_id" => hd(editor(view).tree.roots)})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-starter-#{structure.id}")
      assert has_element?(canvas, "#pb-starter-two"), "beside the core's own"

      canvas |> element("#pb-starter-#{structure.id}") |> render_click()

      tree = editor(view).tree
      assert length(tree.roots) == 1, "a structure arrives as ONE undoable insert"
      assert Serializer.serialize(tree) =~ "grid-cols-[2fr_1fr]"
    end

    test "an unknown structure is a no-op, not a crash", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      before = editor(view).tree
      render_click(canvas, "page_starter", %{"structure" => "no-such-thing"})
      assert editor(view).tree == before
    end

    # A page with something on it is a page someone is already working on.
    test "a page with content is not interrupted by the chooser", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ ~s(id="pb-page-starter")
    end

    # THE FORMATTER PUTS A NEWLINE BETWEEN EVERY PAIR OF CHILDREN, so a grid authored tight comes
    # back from its first save with a whitespace run between each card. Those runs are real nodes and
    # cannot be dropped — `<a>one</a> <a>two</a>` would lose its space — but a box around one is a
    # grid ITEM: an empty cell in the middle of the card row, selectable, and with nothing in the
    # layers panel to match it, because the panel has always hidden them.
    #
    # They stay in the DOM: the drop resolver counts DOM children to work out an insertion index, so
    # a child missing here shifts every index after it.
    test "indentation between tags gets no box of its own", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: "<div class=\"grid\">\n  <p>One</p>\n  <p>Two</p>\n</div>"
        )

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      nodes = Tree.walk(editor(view).tree)
      blanks = Enum.filter(nodes, &(&1.kind == :text and &1.meta[:whitespace?]))

      assert length(blanks) == 3, "the fixture is indented, so the grid has runs around each <p>"

      for node <- blanks do
        assert html =~ ~s(data-node-id="#{node.id}"), "the run must still be a DOM child"
        refute html =~ ~s(phx-value-id="#{node.id}"), "and must not be selectable"
      end

      # `display: contents` is a rule in `#pb-canvas-ui` now rather than a `style` attribute — a
      # Content-Security-Policy has no nonce to offer an attribute — so the marker the rule is keyed
      # on is what there are three of.
      assert length(String.split(html, ~s(data-kind="text" data-ws="true"))) - 1 == length(blanks)
      assert html =~ ~s([data-ws="true"] { display: contents; })

      words = Enum.find(nodes, &(&1.kind == :text and &1.text == "One"))
      assert html =~ ~s(phx-value-id="#{words.id}"), "text with words in it is still selectable"
    end

    # AND A CONTAINER THAT HAS BEEN EMPTIED IS STILL EMPTY. Taking the last thing out of one leaves
    # the indentation that used to sit around it, so `children` reads as a list of blanks rather than
    # `[]` — and the floor that makes a 0px box droppable disappeared at the exact moment it was
    # needed most.
    test "a container holding nothing but indentation still gets a floor", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: "<section id=\"hero\">\n</section>")

      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      tree = editor(view).tree
      [root] = tree.roots

      assert Tree.get(tree, root).children != [], "the fixture is meant to keep its newline"
      assert html =~ "min-height:56px", "the emptied section needs somewhere to aim"
    end

    # THE CANVAS DOES NOT WANT THE ADMIN'S STYLESHEET. It renders a SITE's document, and its own
    # chrome — the selection ring, the component chip, the "needs id" placeholder — is inline styles
    # computed from session state. It used to download all 2.5 MB of `admin.css` anyway, because one
    # `full_tailwind` assign gated the stylesheet and the two web fonts together, and the frames view
    # mounts three of these iframes at once.
    #
    # Asserted on the ASSIGNS rather than the rendered head: the root layout belongs to the host app,
    # which the test endpoint does not use. The layout's half of the contract is one `:if` per link
    # (`assigns[:admin_css]`, `assigns[:admin_fonts]`, `assigns[:live_tailwind]`), so pinning what the
    # canvas sets pins what it loads.
    # AN IFRAME IS BLANK UNTIL ITS DOCUMENT PAINTS, and the canvas frame loads a whole LiveView —
    # with nothing behind it the editor shows an empty rectangle and no reason for the wait. The
    # spinner sits UNDER the frame rather than replacing it: swapping the element out would restart
    # the load, so it could never finish.
    test "the canvas frame shows why it is empty while it loads", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert html =~ "Loading the canvas",
             "the canvas frame renders with nothing to explain the blank rectangle"
    end

    test "asks for fonts and the generator, never the admin stylesheet", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assigns = :sys.get_state(canvas.pid).socket.assigns

      refute assigns[:admin_css], "the canvas must not pull the dashboard's stylesheet"
      assert assigns[:admin_fonts], "its chrome names the admin faces in inline `font:` shorthand"
      assert assigns[:live_tailwind], "a class typed in the inspector must exist a frame later"
    end

    # DIRECTION, SPREAD, ALIGN AND WRAP, each drawn as a picture of what it does — and each writing
    # the same `:set_style` op the Inspector writes, so the two panels cannot disagree and the
    # Tailwind class is `Styles`' business rather than the toolbar's.
    test "the layout panel writes flex classes into the chosen breakpoint", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # Direction only means something once the container is a row, so it appears with it.
      refute has_element?(canvas, "#pb-eltb-direction-flex-row")
      canvas |> element("#pb-eltb-display-flex") |> render_click()
      assert has_element?(canvas, "#pb-eltb-direction-flex-row")

      canvas |> element("#pb-eltb-justify-justify-between") |> render_click()
      canvas |> element("#pb-eltb-align-items-center") |> render_click()

      assert styles_of(view, node.id) == %{
               base: %{
                 "display" => "flex",
                 "justify" => "justify-between",
                 "align" => "items-center"
               }
             }

      # …and the same control, aimed at Mobile, writes a bucket of its own.
      canvas |> element("#pb-eltb-at-mobile") |> render_click()
      canvas |> element("#pb-eltb-direction-flex-col") |> render_click()

      assert styles_of(view, node.id)[:mobile] == %{"direction" => "flex-col"}
    end

    # Pressing the chosen one again clears it, so an element can go back to inheriting.
    test "choosing the same layout option twice clears it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      canvas |> element("#pb-eltb-display-grid") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"display" => "grid"}}

      canvas |> element("#pb-eltb-display-grid") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    # A DEAD BUTTON IS WORSE THAN NO BUTTON. Display works on any element, so the arrow always has
    # something to show; column shapes follow only when the component says which counts it lays out.
    test "a plain element still gets a layout row, without columns", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-eltb-display-flex"), "display is offered on anything"
      refute has_element?(canvas, "#pb-eltb-cols-four"), "but a section has no column count"

      canvas |> element("#pb-eltb-display-grid") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> then(& &1.meta.styles) == %{base: %{"display" => "grid"}}
    end

    test "renders the document with the site's scope", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us"
      assert html =~ "pb-canvas-root"
      assert html =~ "data-node-id"
    end

    # A site's page routinely embeds a GLOBAL component — `<.component component_name="global-footer"
    # site="Global" />` — and the compiled module's name is hashed from that attribute. Scoping it to
    # the page's own site instead named a module nobody ever compiled, so the canvas painted the
    # runtime's red "failed to render" over a component that renders fine on the live site.
    test ~s(a component declaring site="Global" resolves the global module), %{
      conn: conn,
      site: site
    } do
      define_component!("pb-global-footer", nil, "<footer>global footer rendered</footer>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="pb-global-footer" site="Global" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "global footer rendered"
      refute html =~ "failed to render"
    end

    # A COMPONENT IS BUILT ON FIRST USE, and reading its metadata is a use. The canvas asks the
    # compiled module which attributes the component declares so a database-sourced name never mints
    # an atom — and a module that has never been built declares none, so every attribute the author
    # set was dropped and the node rendered with its defaults. The live site was unaffected, which is
    # what made it invisible: the same page looked right to a visitor and wrong to its author.
    test "a lazy component renders on the canvas WITH the attributes the author set", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          site_id: site.id,
          name: "pb-lazy-badge",
          template: ~s(<span class={"badge-" <> @tone}>lazy badge</span>),
          attrs: [%{name: "tone", type: "string", default: "quiet"}],
          precompile: false
        )

      refute Helpers.loaded?(Helpers.module_name(component.name, site.name, "Component"))

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div><.component component_name="pb-lazy-badge" site="#{site.name}" tone="loud" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      # THE FIRST PAINT, not the connected one. Rendering the component builds it as a side effect,
      # so by the second render the module exists and the attributes come back — the bug heals
      # itself one frame too late, after the author has already seen the wrong thing (or, when a
      # missing attribute makes the component raise, an error box where their component should be).
      html =
        conn
        |> get("/admin/dashboard/runtime/builder-canvas/#{token(view)}")
        |> html_response(200)

      # The component's OWN rendered markup, not the node's stored attributes — the canvas echoes
      # those into the DOM as well, so a looser match passes with the component rendering nothing.
      assert html =~ ~s(<span class="badge-loud">lazy badge</span>)
    end

    test "a component with no site attribute still resolves against the site being edited", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-site-hero", site, "<section>site hero rendered</section>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="pb-site-hero" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "site hero rendered"
      refute html =~ "failed to render"
    end

    # `Tree.Styles` lifts recognised utilities out of the authored class attribute and into
    # `meta.styles`, so rendering the authored attribute raw loses them. That dropped `flex` off a
    # nav and the menu stacked, while the SAVED template stayed correct — only serialization was
    # merging them back, so the whole suite stayed green.
    test "absorbed layout classes survive onto the canvas, not just into the save", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<header class="flex justify-between"><nav class="flex gap-6">x</nav></header>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # BOTH are absorbed now — `justify-between` joined the vocabulary with the layout panel — so
      # they come back in the serialiser's own order rather than authored-then-generated. Same
      # classes, and no two utilities here compete on specificity, so order carries nothing.
      assert html =~ ~s(class="flex justify-between")
      assert html =~ ~s(class="gap-6 flex")
    end

    test "a node with no class at all gains none", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section><p>hi</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      [_before, after_tag] = String.split(html, "<section", parts: 2)
      [opening, _rest] = String.split(after_tag, ">", parts: 2)
      refute opening =~ "class="
    end

    # The site's asset URL is keyed on its name and a content hash; a site that is inactive or has
    # never been compiled has neither, so linking it rendered the editor unstyled for exactly the
    # sites people open it on. The bytes are inlined from `AssetsState` instead.
    # The bundle is 3.6 MB on a real site. Inlining it put every byte in the document of every
    # preview the modal opened; linking it by content hash means brotli, an immutable year-long
    # cache, and a frame that paints once already styled.
    test "the canvas links the site's compiled CSS by content hash", %{conn: conn, page: page} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: "abc",
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # THE LINK ITSELF IS IN THE ROOT LAYOUT'S `<head>` now, above the browser generator, so that
      # the classes the editor generates are appended after the bundle and win. What the canvas
      # still owes is the ADDRESS, and that is what is checked here — the test endpoint renders a
      # bare layout, so the tag is not observable from a LiveView test.
      assert css_hrefs(canvas) == ["/assets/css/__shared_base__/abc"]
      refute html =~ ".from-shared-base{color:#123456}"
    end

    # The reason the inline path still exists: a site that has never compiled has bytes in
    # `AssetsState` but no hash to address them by, and that is exactly the site someone opens the
    # editor on.
    test "a bundle with no content hash is inlined instead", %{conn: conn, page: page} do
      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "__shared_base__",
        type: "css",
        value: ".from-shared-base{color:#123456}",
        hash: nil,
        updated_at: DateTime.utc_now()
      })

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-canvas-css"
      assert html =~ ".from-shared-base{color:#123456}"
      refute html =~ "/assets/css/"
    end

    # Tailwind's browser build generates a utility the moment its class appears, but only for tokens
    # it knows — without the kit's `@theme` every `text-natural-*` class comes out blank.
    test "the kit's @theme travels to the browser generator", %{
      conn: conn,
      page: page,
      site: site
    } do
      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "kit-theme",
          content: "@theme { --color-natural-x: #abcdef; }\n.other { color: red }",
          kind: :theme,
          active: true
        },
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ ~s(type="text/tailwindcss")
      assert html =~ "--color-natural-x: #abcdef;"
      # Only the @theme block travels; the rest is already in the compiled bundle.
      refute html =~ ".other { color: red }"
    end

    # THE ORDER IS THE WHOLE FIX. The site's compiled bundle is base styling and belongs in `<head>`;
    # the browser generator injects what it makes into `<head>` too, after the markup already there.
    # Rendered in THIS LiveView's template — which is `<body>` — the bundle came last and overruled
    # every class the editor generated: an author typed `pl-[30px]` onto an element whose page said
    # `px-8`, the class landed, the rule was written, and the padding did not move.
    #
    # The link lives in `root.html.heex` now, above the generator's script. What is checkable here is
    # the half that was wrong: it must not be in the frame's body any more. The test endpoint renders
    # a bare layout, so the head itself is not observable from here.
    test "the compiled bundle is not rendered into the frame's body", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ ~r|<link[^>]+rel="stylesheet"[^>]+/assets/css/|

      # The frame's own chrome is still the frame's, so this is the bundle moving out and not the
      # whole head going missing.
      assert html =~ "pb-canvas-chrome"
    end

    # A node's own LiveView bindings must not reach the frame. `phx-click` would fight the canvas's
    # selection binding, and `phx-hook` names a hook from the SITE's bundle, which this frame does not
    # load — LiveView logged "unknown hook found" in the console for every one.
    test "a node's phx-* bindings are not emitted into the canvas", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<button id="c" phx-hook="SiteClipboard" phx-click="copy" data-x="1" class="btn">Copy</button>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "SiteClipboard"
      refute html =~ ~s(phx-click="copy")
      # Everything that is not a binding still renders, and the attribute stays in the document.
      assert html =~ ~s(data-x="1")
      assert html =~ "btn"
      assert editor_html(view) =~ ~s(phx-hook="SiteClipboard")
    end

    # A link in the document must select, not navigate. `<.link navigate>` renders `data-phx-link`,
    # which LiveView's own interceptor treats as a live redirect — clicking one to select it took the
    # canvas away from the document being edited. The hook cancels it in the capture phase, before
    # that interceptor runs, and pushes the selection itself.
    test "the canvas keeps a page's links selectable rather than live", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<nav><.link navigate="/">Home</.link></nav>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # The href stays — it is the document's content, and the inspector edits it.
      assert html =~ ~s(href="/")
      # The hook is what cancels the navigation, so the canvas must be carrying it.
      assert html =~ ~s(phx-hook="PbCanvas")
    end

    test "an expired session says so rather than erroring", %{conn: conn} do
      {:ok, _canvas, html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

      assert html =~ "session has expired"
    end

    # A `phx-click="select"` on the canvas container would fire on the way up from every node's own
    # click and immediately clear the selection that just happened. Deselecting on background clicks
    # is the hook's job precisely because it can tell whether the click landed on a node.
    test "the canvas container carries no deselect binding of its own", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      # Only the container's OWN opening tag — everything up to its first `>`. Its children carry
      # `phx-click="select"` and should.
      [_before, after_id] = String.split(html, ~s(id="pb-canvas-root"), parts: 2)
      [opening_tag, _children] = String.split(after_id, ">", parts: 2)

      refute opening_tag =~ ~s(phx-click="select")
      assert opening_tag =~ ~s(phx-hook="PbCanvas")
    end

    test "a selection made in the canvas survives — it is not cleared by its own click", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(canvas, "select", %{"id" => h1.id})

      assert editor(view).selection == h1.id
      assert render(view) =~ "h1"
    end

    test "selecting in the canvas updates the chrome over PubSub", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(canvas, "select", %{"id" => h1.id})

      assert render(view) =~ "Attributes" or editor(view).selection == h1.id
      assert editor(view).selection == h1.id
    end
  end

  describe "panels" do
    # A RUNTIME COMPONENT IS BUILT ON FIRST USE, which is right — a kit of 136 must not compile 136
    # modules to open a page that places five. But the canvas walks the tree NODE BY NODE and blocks
    # on each one in turn: measured cold against the real kit, five components are 623 ms serial and
    # 358 ms asked for together, because `chelekom-button-link` alone is 295 ms of it.
    #
    # So the mount asks for all of them at once. Which components get built does not change, and
    # neither does when they are first needed — only the shape of the wait.
    test "opening the editor compiles the document's components before the canvas asks", %{
      conn: conn,
      site: site
    } do
      component =
        create_component!(
          name: "warm-box",
          site_id: site.id,
          template: ~S|<div class="warm">{render_slot(@inner_block)}</div>|
        )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<div id="root"><.component component_name="warm-box" site="#{site.name}">hi</.component></div>|
        )

      module = Helpers.module_name(component.name, site.name, "Component")
      :code.purge(module)
      :code.delete(module)
      refute Helpers.loaded?(module), "the fixture has to start cold"

      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      # The canvas has never mounted; the module is there because the mount asked for it.
      assert Helpers.loaded?(module),
             "the editor did not warm the components its own document uses"
    end
  end

  describe "editing" do
    test "an attribute edit reaches the tree", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "headline"
      })

      edited = view |> editor() |> Map.fetch!(:tree) |> Tree.get(h1.id)
      assert {"class", {:string, "headline"}} in edited.attrs
    end

    test "delete removes the element and undo brings it back", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(view, "h1")

      undo!(view)
      assert node_with_tag(view, "h1")
    end

    test "redo re-applies the undone edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      undo!(view)
      redo!(view)

      refute node_with_tag(view, "h1")
    end

    test "a server-rejected drop leaves the document alone and flashes", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      html =
        render_click(view, "op", %{
          "kind" => "insert",
          "template" => ~s(<div>nope</div>),
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "text and inline"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "locking an element refuses edits to it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "toggle_lock", %{"id" => h1.id})
      html = render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      assert html =~ "locked"
      assert node_with_tag(view, "h1")
    end
  end

  # Checked against the v1 prototype served at :8000, option by option.
  describe "the demo's chrome" do
    # The stage control is the prototype's split button and it has two distinct looks. Publishing is
    # outward-facing, so this is the one place the published styling is checked.
    test "the stage button is violet-tinted as a draft and solid once published", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      draft = view |> element("#pb-stage") |> render()
      assert draft =~ "bg-[#f2f1fc]"
      assert draft =~ "text-[#4f4bcc]"
      assert draft =~ "Draft"
      # The dot is the autosave light; a caret would mean published.
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"

      # Selecting only SELECTS — the page is not live until the button is pressed.
      view |> element("#pb-stage-published") |> render_click()
      assert view |> element("#pb-stage") |> render() =~ "Publish"

      view |> element("#pb-stage") |> render_click()

      # AND ONCE IT IS LIVE THE CHIP FALLS BACK TO DRAFT, because publishing is an act rather than a
      # mode: whatever is done next is unpublished work again. The button stays solid — it is still
      # reporting that the page went out — and offers to keep the next work aside.
      published = view |> element("#pb-stage") |> render()
      assert published =~ "linear-gradient(140deg,#6d69e6,#4f4bcc)"
      assert published =~ "text-white"
      assert published =~ "Save draft"
      refute view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"
    end

    # The theme is client state — `<html data-theme>` plus localStorage — so the button carries a hook
    # and BOTH icons, with CSS choosing. A server-rendered icon lagged the real theme and the toggle
    # only ever turned dark on.
    test "the theme toggle owns both icons and flips on the client", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = view |> element("#pb-theme") |> render()
      assert html =~ ~s(phx-hook="PbTheme")
      assert html =~ "[[data-theme=dark]_&amp;]:hidden"
      assert html =~ "[[data-theme=dark]_&amp;]:block"
    end

    test "the crumb bar reports the device and zoom", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert has_element?(view, "[data-role='pb-viewnote']", "Desktop · 100%")

      view |> element("#pb-device-tablet") |> render_click()
      assert has_element?(view, "[data-role='pb-viewnote']", "Tablet · 834px · 100%")
    end

    test "the canvas floats a per-element toolbar over the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "pb-el-toolbar"
      assert html =~ "pb-eltb-duplicate"
      assert html =~ "pb-eltb-delete"
      assert html =~ "pb-eltb-ask_ai"
      assert html =~ "pb-eltb-comment"

      # No NODE carries the attribute: the ring is a CSS rule keyed on `data-selected`, and the hook
      # sets it on the click so a selection paints without re-rendering the document.
      assert html =~ ~s([data-node-id][data-selected="true"])
      refute html =~ ~s(data-node-id="#{h1.id}" data-selected="true")

      # And the actions work, through the same validated op funnel as everything else.
      render_click(canvas, "toolbar", %{"action" => "duplicate"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.count(&(&1.tag == "h1")) ==
               2

      render_click(canvas, "toolbar", %{"action" => "delete"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.count(&(&1.tag == "h1")) ==
               1
    end

    # THE TOOLBAR IS AN OPEN REGISTRY AND "NOT DELETE" MEANT "DUPLICATE", so every button an
    # extension contributed inserted a copy of the selected element — undoable, autosaved — and the
    # plugin that put it there was never called. Both halves are asserted here: the plugin hears
    # about the press, and the document does not move.
    test "a contributed toolbar action reaches its plugin instead of duplicating the element", %{
      conn: conn,
      page: page
    } do
      Process.register(self(), ToolbarInvokedProbe.waiter())
      register_plugin(ToolbarProbe, "builder:canvas:toolbar")
      register_plugin(ToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      before = editor(view)

      assert has_element?(canvas, "#pb-eltb-probe-toolbar")

      # THE BUTTON READS AS WHAT THE PLUGIN DECLARED, which is the other half of a contributed action
      # being real: the label and the icon were drawn from the core's own five and a plugin's button
      # came out an unlabelled box, whatever its descriptor said.
      button = canvas |> element("#pb-eltb-probe-toolbar") |> render()

      assert button |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() == "Probe",
             "the descriptor's own label is what the button says, not just its tooltip"

      assert button =~ ~s(data-pb-tb="labelled"), "so it is not squeezed into a 30px glyph box"

      assert button =~ ~s(d="M13 2 4 14h7l-1 8 9-12h-7z"),
             "and the sparkle it named, not the box every key outside the core's five fell back to"

      canvas |> element("#pb-eltb-probe-toolbar") |> render_click()

      assert_receive {ToolbarInvokedProbe,
                      %{action: "probe-toolbar", node_id: node_id, token: token}}

      assert node_id == h1.id
      assert token == token(view)

      assert editor(view).tree == before.tree, "a plugin's button is not a document change"
      assert editor(view).past == before.past, "and it is not an undo step either"
    end

    # A KEY THE REGISTRY NEVER OFFERED can only come from a forged or replayed press — the buttons
    # are drawn from that same list. It used to duplicate the element, which is the loudest possible
    # answer to "I don't know what this is"; the quietest correct one is nothing at all, said in the
    # log. Taking the canvas down instead is the iframe reload loop the catch-all clause avoids.
    test "a toolbar action nothing registered changes nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      before = editor(view)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          render_click(canvas, "toolbar", %{"action" => "not-a-registered"})
        end)

      assert log =~ ~s(no toolbar action is registered as "not-a-registered")
      assert has_element?(canvas, "#pb-el-toolbar"), "and the canvas is still up to draw the bar"
      assert editor(view).tree == before.tree
      assert editor(view).past == before.past
    end

    # `layout` IS one of the registry's five, and the only one the core answers by doing nothing —
    # the panel is client state, so the button pushes no event at all. Left to the clause that hands
    # a key back to the plugin that contributed it, a replayed press would be announced to every
    # plugin as an extension's own action.
    test "a core toolbar key is never announced as a plugin's", %{conn: conn, page: page} do
      Process.register(self(), ToolbarInvokedProbe.waiter())
      register_plugin(ToolbarInvokedProbe, "builder:canvas:toolbar:invoked")

      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      render_click(canvas, "toolbar", %{"action" => "layout"})

      refute_receive {ToolbarInvokedProbe, _summary}
    end

    # THE CHROME COLLECTED THIS REGISTRY TOO, into an assign nothing rendered and from a seed that
    # disagreed with the one on screen — so a plugin ran twice per open and saw two different core
    # sets. The bar is drawn inside the frame, and the frame is now the only thing that asks for it.
    test "only the canvas collects the toolbar registry", %{conn: conn, page: page} do
      Process.register(self(), ToolbarProbe.waiter())
      register_plugin(ToolbarProbe, "builder:canvas:toolbar")

      {:ok, view, _html} = open_builder(conn, page)
      refute_received {ToolbarProbe, :collected}

      {:ok, _canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert_received {ToolbarProbe, :collected}
    end

    # THE BAR NEEDS ROOM ABOVE WHAT IT NAMES. It sits 6px above the selection and never closer than
    # 4px to the top of the frame, so on a 16px stage it was pinned over the top of the document's
    # first element — over the chip or the words a double click was aimed at, in every builder. The
    # layout is what is checkable here; where the hook puts the bar is `placeToolbar`'s.
    test "the stage keeps the toolbar's band clear above the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      chrome = canvas |> element("#pb-canvas-chrome") |> render()

      assert chrome =~
               ~s|#pb-canvas-root[data-preview="false"] { padding-top: calc(4px + 26px + 6px); }|

      assert chrome =~ "html { scroll-padding-top: calc(4px + 26px + 6px); }",
             "a selection scrolled into view has to stop short of the bar the same way"

      view |> element("#pb-preview") |> render_click()

      refute render(canvas) =~ "calc(4px + 26px + 6px)",
             "preview draws no bar, so it keeps no band"
    end

    # The canvas frame shows the author's own document and nothing else. An empty page still offers
    # somewhere to click, but a page with content does not get a dashed strip appended below it.
    test "the canvas frame adds no chrome below the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute html =~ "pb-canvas-tail"
      refute html =~ "Drop a component here"
    end
  end

  describe "publishing" do
    test "publish writes the page and reports the published stage", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "live-now"
      })

      # Two steps on purpose: the menu selects the stage, the button carries it out.
      view |> element("#pb-stage-published") |> render_click()
      html = view |> element("#pb-stage") |> render_click()

      assert html =~ "published"

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="live-now")
      refute editor(view).dirty?
    end

    test "the stage button publishes again after an edit, and has nothing to do without one", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      set_class =
        &render_click(view, "op", %{
          "kind" => "set_attr",
          "node_id" => h1.id,
          "name" => "class",
          "value" => &1
        })

      set_class.("first-publish")
      view |> element("#pb-stage-published") |> render_click()
      view |> element("#pb-stage") |> render_click()

      view |> element("#pb-stage-published") |> render_click()
      assert view |> element("#pb-stage") |> render() =~ "Published"
      refute view |> element("#pb-stage") |> render() =~ ~s(phx-click="apply_stage")

      set_class.("second-publish")
      view |> element("#pb-stage-published") |> render_click()
      chip = view |> element("#pb-stage") |> render()
      refute chip =~ "Published"
      assert chip =~ "Publish"
      assert chip =~ ~s(phx-click="apply_stage")

      view |> element("#pb-stage") |> render_click()

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="second-publish")
    end

    test "an edit after a publish is draft work again, autosaved", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      publish!(view)

      assert view |> element("#pb-stage") |> render() =~ "Save draft"

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node_with_tag(view, "h1").id,
        "name" => "class",
        "value" => "after-publish"
      })

      chip = view |> element("#pb-stage") |> render()
      assert chip =~ "Draft"
      refute chip =~ "Save draft"
      assert view |> element("#pb-stage-menu") |> render() =~ "animate-pulse"
    end
  end

  describe "the canvas's own event handlers" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      %{view: view, canvas: canvas}
    end

    # A real mouse drop lands on the CANVAS LiveView, not the chrome — a different handler.
    test "a drop on the canvas inserts", %{view: view, canvas: canvas} do
      section = node_with_tag(view, "section")

      render_click(canvas, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure")
    end

    test "a drop on the canvas moves", %{view: view, canvas: canvas} do
      h1 = node_with_tag(view, "h1")
      render_click(canvas, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})

      assert Tree.get(view |> editor() |> Map.fetch!(:tree), h1.id).parent_id == nil
    end

    test "an illegal drop on the canvas lands beside the target and says so", %{
      view: view,
      canvas: canvas
    } do
      h1 = node_with_tag(view, "h1")

      render_click(canvas, "drop", %{
        "template" => "<section></section>",
        "parent_id" => h1.id,
        "index" => "0"
      })

      assert_push_event(canvas, "pb:drop-moved", %{message: message})
      assert message =~ "Placed after"

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "section" and &1.children == []))

      assert inserted.parent_id == h1.parent_id
    end

    test "the canvas answers a dragstart with the tree's verdict", %{view: view, canvas: canvas} do
      h1 = node_with_tag(view, "h1")
      section = node_with_tag(view, "section")

      render_click(canvas, "drag_start", %{"template" => "<section></section>"})

      assert_push_event(canvas, "pb:drop-hints", %{accepts: accepts})
      assert accepts[h1.id] == false
      assert accepts[section.id] == true
    end

    test "inline text editing writes through the canvas", %{view: view, canvas: canvas} do
      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(canvas, "set_text", %{"id" => text.id, "text" => "Edited inline"})

      assert editor_html(view) =~ "Edited inline"
    end

    # Hover deliberately never reaches the server. Nothing reads it — the layers rail highlights the
    # SELECTION, as the prototype does — and pushing an event per mouseover meant a round trip and a
    # re-render of the whole document for every pixel the pointer travelled. The outline is a CSS rule
    # inside the frame instead.
    test "hovering costs no round trip: the canvas has no hover handler", %{canvas: canvas} do
      assert render(canvas) =~ ~s([data-node-id]:hover)

      # A stray push is ignored rather than mutating anything.
      assert render_click(canvas, "hover", %{"id" => "nabcdefgh"})
    end
  end

  describe "presence" do
    # You are always in the stack — that is what gives the bar the prototype's avatar chip without
    # inventing colleagues. What must NOT appear is a second one.
    test "a lone editor sees only their own avatar", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = view |> element("#pb-avatars") |> render()
      assert html =~ "Only you are editing this page"

      # Exactly one chip: you. A second would mean a second person, which is the case that matters.
      assert html |> String.split("rounded-full") |> length() == 2
    end

    # Two admins share a session by URL. This used to be impossible: `?session=` was ignored, so
    # each mount opened its own private tree and the avatars could never appear.
    test "a second admin joining by session token shares the document and shows up", %{
      conn: conn,
      page: page
    } do
      {:ok, first, _html} = open_builder(conn, page)
      shared = token(first)

      other = create_admin("colleague@example.com")

      second_conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
        |> log_in(other)

      {:ok, second, _html} =
        live(
          second_conn,
          "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{shared}"
        )

      # Same session, not a copy.
      assert token(second) == shared

      # An edit by one is seen by the other, over the session's PubSub topic.
      h1 = node_with_tag(first, "h1")
      render_click(second, "op", %{"kind" => "delete", "node_id" => h1.id})
      refute node_with_tag(first, "h1")

      # And each sees the other in the avatar row.
      assert render(first) =~ "pb-avatars"

      assert Enum.any?(
               MishkaCmsCore.Runtime.PageBuilder.Presence.editors(shared),
               &(&1.id == other.id)
             )
    end

    test "a site admin in a master's session sees the master as M, and the master sees them", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, first, _html} = open_builder(conn, page)
      shared = token(first)
      joiner = create_admin("tenant.joiner@example.com", site.id)

      {:ok, second, _html} =
        live(
          log_in(build_conn_for_host(), joiner),
          "/admin/dashboard/runtime/builder/page/#{page.id}?session=#{shared}"
        )

      assert token(second) == shared
      assert avatars(second) == ["TJ", "M"]
      assert avatars(first) == ["B", "TJ"]
      refute MishkaCmsCore.Runtime.PageBuilder.Presence.editors(shared) |> inspect() =~ "@"
    end

    test "a stale or foreign session token falls back to a fresh session", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?session=nosuchtokenatall")

      assert token(view) =~ ~r/^[a-z0-9]{32}$/
      assert node_with_tag(view, "h1")
    end

    test "initials come from the email's local part" do
      alias MishkaCmsCore.Runtime.PageBuilder.Presence

      assert Presence.initials(%{email: "ada.lovelace@example.com"}) == "AL"
      assert Presence.initials(%{email: "boss@example.com"}) == "B"
      assert Presence.initials(%{email: "a_b_c@example.com"}) == "AB"
      assert Presence.initials(%{}) == "?"
    end
  end

  describe "autosave, history counter and revert" do
    # The prototype puts no counter chip in the bar — the position lives in the undo button's own
    # tooltip, where it explains what that click will do, and in the Record-history sheet.
    test "the undo button reports position and total", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert view |> element("#pb-undo") |> render() =~ "0/0"

      h1 = node_with_tag(view, "h1")
      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})

      assert view |> element("#pb-undo") |> render() =~ "1/1"

      undo!(view)
      assert view |> element("#pb-undo") |> render() =~ "0/1"
    end

    # A CHANGE IS THE TRIGGER, not a clock. It writes a DRAFT and never the live row: a live write
    # enqueues a compile job and would push half-finished work to visitors as it was being made.
    test "a change writes a draft and leaves the live page alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "auto"
      })

      _written = render_async(view)

      {:ok, live_page} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      refute live_page.template =~ ~s(class="auto")

      {:ok, drafts} =
        MishkaCmsCore.Runtime.PageDraft
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read(page: [limit: 10])

      draft = Enum.find(drafts.results, &(&1.source_page_id == page.id))
      assert draft
      assert draft.template =~ ~s(class="auto")
      assert String.starts_with?(draft.label, "Draft · "), draft.label
    end

    test "an autosaved draft is reachable at its shareable preview URL", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      send(view.pid, :autosave)

      _saved = render_async(view)

      # The shareable link lives behind the Preview caret now, with the other ways of looking at the
      # page, instead of a lone tick in the top bar that said nothing about what it did.
      html = render(view)

      assert html =~ "/_preview/page/"
      assert has_element?(view, "#pb-preview-tab")
    end

    test "a clean session does not autosave", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      send(view.pid, :autosave)
      _rendered = render_async(view)

      refute has_element?(view, "#pb-preview-tab")
    end
  end

  describe "a layout, which is not a page with a header on it" do
    @body_layout ~s(<body class="min-h-screen bg-white"><main>{@inner_content}</main></body>)

    # A LAYOUT'S ROOT IS `<body>` — every one in this CMS opens with the element a page is wrapped in
    # — and a document may hold only one. The canvas is an ordinary document that already has a body,
    # so the parser merged the second one's attributes onto the first and dropped the tag: the node
    # the editor was pointing at was not in the frame at all. It looked right on the first render,
    # because the merge happened; every patch after that discarded the attributes outright.
    test "the root <body> is drawn as a container the frame can actually hold", %{
      conn: conn,
      site: site
    } do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      root = node_with_tag(view, "body")

      assert has_element?(canvas, ~s(div[data-node-id="#{root.id}"])),
             "the layout's root is selectable, draggable and stylable like any other container"

      refute has_element?(canvas, ~s(body[data-node-id="#{root.id}"])),
             "a second <body> is dissolved by the parser, taking the node with it"
    end

    # THE HALF THAT PROVES IT. Standing in for the tag is only worth anything if an edit to the root
    # now shows: the old behaviour recorded the override, wrote it into the saved template, and left
    # the frame exactly as it was — an editor that appears to ignore you.
    test "and recolouring that root reaches the frame", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      root = node_with_tag(view, "body")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => root.id,
        "bucket" => "base",
        "prop" => "background",
        "value" => "#ff0000"
      })

      assert canvas |> element(~s(div[data-node-id="#{root.id}"])) |> render() =~ "bg-[#ff0000]"

      # And the substitution is what the canvas draws, never what the document says.
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~ "<body"
    end

    # Publishing is the deliberate "make this live", and this one is already broken — the same
    # promise a required property makes, made by the section instead of by a component.
    test "publishing a layout that renders no page is refused", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      slot = expression_node(view)
      render_click(view, "op", %{"kind" => "delete", "node_id" => slot.id})

      assert publish!(view) =~ "Not published"

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Layout, layout.id, action: :master_get, authorize?: false)

      assert reloaded.template == @body_layout, "the live layout is untouched"
    end

    # The chip whose whole job is to say which document a save lands on called every one of them a
    # page, because the words were written into the markup.
    test "the stage chip names the layout rather than a page", %{conn: conn, site: site} do
      layout = create_layout!(site_id: site.id, template: @body_layout)

      {:ok, _view, html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert html =~ "Live layout"
      refute html =~ "Live page"
    end
  end

  describe "what the canvas shows a run of text" do
    # `&copy;` is what a footer is written with, and a layout's footer is where it lives. Interpolated
    # it renders `&amp;copy;`, so the author read the six letters they typed while the published page
    # and the shareable preview both showed ©.
    test "a character reference is drawn as the character it names", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>&copy; 2026 &mdash; Mishka</p>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      paragraph = canvas |> element(~s(p[data-node-id])) |> render()

      assert paragraph =~ "© 2026 — Mishka"
      refute paragraph =~ "&amp;copy;", "the reference was shown as its own six letters"

      # And the document is untouched by any of that — the substitution is what the frame draws.
      assert view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize() =~
               "&copy; 2026 &mdash; Mishka"
    end

    # THE BOX SAYS `plaintext-only` AND MEANT IT NOWHERE. The hook pushes `textContent`, so the three
    # characters that mean something to HTML arrived as the characters typed and went into the
    # template as markup: typing `<b>bold</b>` put a real element in the document, and the same
    # keystrokes could have put a `<script>` on a published page.
    test "typing stays text, whatever is typed", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>original</p>))

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(canvas, "set_text", %{"id" => text.id, "text" => "Fish & Chips <b>bold</b>"})

      saved = view |> editor() |> Map.fetch!(:tree) |> Serializer.serialize()

      assert saved =~ "Fish &amp; Chips &lt;b&gt;bold&lt;/b&gt;"
      refute saved =~ "<b>", "typed characters became an element in the document"

      # And it comes back to the author as what they typed rather than as markup: the run is still one
      # text node, and no `<b>` was ever built from it.
      assert render(canvas) =~ "Fish &amp; Chips &lt;b&gt;bold&lt;/b&gt;"
      refute has_element?(canvas, ~s(span[data-kind="text"] b))
    end
  end

  describe "the other three sections" do
    test "a layout opens and saves through its own attribute", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<main><p>Layout body</p>{@inner_content}</main>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      assert node_with_tag(view, "main")

      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => p.id,
        "name" => "class",
        "value" => "lead"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Layout, layout.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="lead")
    end

    test "a component opens and saves through its own attribute", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: site.id,
          name: "editable-box",
          template: ~s(<div class="box"><span>Inside</span></div>)
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/component/#{component.id}")

      assert has_element?(view, "#pb-root")
      assert view |> editor() |> Map.fetch!(:section) == "component"

      span = node_with_tag(view, "span")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => span.id,
        "name" => "class",
        "value" => "inner"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Component, component.id,
          action: :master_get,
          authorize?: false
        )

      assert reloaded.template =~ ~s(class="inner")
      assert reloaded.template =~ "Inside"
    end

    # An error page stores a LIST of per-status templates and has no `template` attribute at all, so
    # this is the section that would break if the editor assumed one document per record.
    test "an error page edits one status and writes it back into the list", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}")

      # It opens on the 404 entry — the document itself lives in the canvas iframe, so the session
      # tree is where to look — and offers both statuses.
      assert editor_html(view) =~ "Not found"
      assert has_element?(view, "#pb-status-404")
      assert has_element?(view, "#pb-status-500")

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(h1.children),
        "text" => "Missing"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      # Ash hands typed map entries back atom-keyed even when they were written with string keys.
      by_status =
        Map.new(reloaded.error_pages, fn entry ->
          {entry["status"] || entry[:status], entry["template"] || entry[:template]}
        end)

      assert by_status[404] =~ "Missing"
      # The other status must be untouched — saving one entry cannot clobber the list.
      assert by_status[500] =~ "Boom"
    end

    test "an error page can be opened directly on another status", %{conn: conn, site: site} do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor_html(view) =~ "Boom"
      refute editor_html(view) =~ "Not found"
    end

    # The page an offline site shows is an entry of its own, beside the codes, addressed as
    # `?status=offline`. Read as a number, that address opened the 404 and published over it.
    test "the offline page opens on its own tab and publishes into its own entry", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => "offline", "template" => "<h1>Soon</h1>", "layout" => %{}}
          ]
        )

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=offline")

      assert editor_html(view) =~ "Soon"
      refute editor_html(view) =~ "Not found"
      assert has_element?(view, "#pb-status-offline")

      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_text",
        "node_id" => hd(h1.children),
        "text" => "Back later"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      by_status = Map.new(reloaded.error_pages, &{&1.status, &1.template})

      assert by_status[:offline] =~ "Back later"
      assert by_status[404] =~ "Not found"
    end

    # SWITCHING STATUS IS NOT OPENING ONE FRESH, and that is the whole difference. The tab strip is a
    # `navigate` link, so pressing 500 remounts — and a remount RESUMES the session this actor already
    # has open on this document, which is what stops a reload throwing work away. The session is keyed
    # on section, record and actor, so the status was not part of what it is a session FOR: the strip
    # lit 500, `@status` became 500, and the tree stayed the 404 one.
    test "and switching status inside an open session changes the document", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, first, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=404")

      assert editor_html(first) =~ "Not found"

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      assert editor_html(second) =~ "Boom"

      refute editor_html(second) =~ "Not found",
             "the strip said 500 and the canvas was still showing 404"
    end

    # AND THE COST OF GETTING IT WRONG, which is why this is not a cosmetic bug. `save_fields/3`
    # replaces the entry named by `@status` with whatever the tree serialises to — so a tree left over
    # from 404, saved while the strip reads 500, writes the 404 markup into the 500 entry and the real
    # 500 page is gone with nothing said.
    test "so publishing after a switch cannot write one status over another", %{
      conn: conn,
      site: site
    } do
      error_page =
        create_error_page!(
          site_id: site.id,
          error_pages: [
            %{"status" => 404, "template" => "<h1>Not found</h1>", "layout" => %{}},
            %{"status" => 500, "template" => "<h1>Boom</h1>", "layout" => %{}}
          ]
        )

      {:ok, _first, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=404")

      {:ok, second, _html} =
        live(conn, "/admin/dashboard/runtime/builder/error-page/#{error_page.id}?status=500")

      publish!(second)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page.id,
          action: :master_get,
          authorize?: false
        )

      by_status =
        Map.new(reloaded.error_pages, fn entry ->
          {entry["status"] || entry[:status], entry["template"] || entry[:template]}
        end)

      assert by_status[500] =~ "Boom", "the 404 tree was published over the 500 entry"
      assert by_status[404] =~ "Not found"
    end
  end

  # Selecting an element has been the slowest thing in this editor twice: once at 2.2s, when every
  # mouse move pushed a `hover` event, and again at ~0.5s, when the selection ring was a server-
  # rendered inline style so a click re-rendered all ~200 nodes. Both were found in a browser, not
  # here — so this is the guard: the ring is client-side now, and the server's share of a selection
  # is a small, bounded thing.
  describe "selection cost" do
    test "a selection round trip stays cheap on a large document", %{conn: conn, site: site} do
      sections =
        Enum.map_join(1..40, fn i ->
          ~s(<section id="s#{i}"><h2>Section #{i}</h2><p>Body #{i}</p></section>)
        end)

      page = create_page!(site_id: site.id, template: ~s(<div id="root">#{sections}</div>))
      {:ok, view, _html} = open_builder(conn, page)

      tree = editor(view).tree
      assert Tree.size(tree) > 150
      ids = tree |> Tree.walk() |> Enum.map(& &1.id) |> Enum.take(10)

      # The first click after a fresh compile pays for module loading, which is not what this
      # measures — warm up, then time.
      render_click(view, "select", %{"id" => hd(ids)})

      times =
        for id <- ids do
          {microseconds, _html} = :timer.tc(fn -> render_click(view, "select", %{"id" => id}) end)
          div(microseconds, 1000)
        end

      # THE MIDDLE SAMPLE, NOT THE WORST ONE. Measured at 5–24ms on an idle machine, and what this
      # has to catch is a change in KIND — re-rendering the document on every click, which is
      # seconds, and which moves EVERY sample. A single 415ms outlier among nine samples of 86–174ms
      # is a GC pause or a busy scheduler, and asserting on the max made the whole suite hostage to
      # one of them: it failed on a run sharing this machine with two other suites and a dev server.
      #
      # Raising the ceiling again would have been the wrong repair — it trades away the very
      # sensitivity the test exists for. The median keeps it.
      median = times |> Enum.sort() |> Enum.at(div(length(times), 2))

      assert median < 400,
             "a selection cost #{median}ms (median) on a #{Tree.size(tree)}-node page: #{inspect(times)}"
    end
  end

  describe "saving" do
    test "save writes the serialized tree back to the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => h1.id,
        "name" => "class",
        "value" => "headline"
      })

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(class="headline")
      assert reloaded.template =~ "Contact Us"
    end

    test "save clears the dirty flag", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "op", %{"kind" => "delete", "node_id" => h1.id})
      assert editor(view).dirty?

      publish!(view)
      refute editor(view).dirty?
    end

    test "the saved template still parses — a save can never corrupt a page", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert {:ok, _tree} = Tree.parse(reloaded.template)
    end
  end

  describe "chrome controls" do
    test "the device switcher changes the frame", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-device-mobile") |> render_click()
      assert has_element?(view, "#pb-frame-mobile")

      view |> element("#pb-device-frames") |> render_click()
      assert has_element?(view, "#pb-frame-1180")
      assert has_element?(view, "#pb-frame-560")
    end

    # The toggle mirrors the PAGE, not the panels around it: an author checking a Persian or Arabic
    # layout wants the document flipped. It rides on the session, which is how it reaches the canvas
    # inside the iframe.
    # The all-breakpoints view is the whole page shown smaller — not a short window onto it. Its
    # frames therefore carry no fixed height and nothing scrolls inside them; the height is measured
    # in the browser and the box is simply the real width scaled down.
    test "each frame is a real device viewport, scaled", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      html = view |> element("#pb-framerow") |> render()

      # Each box is its real width times the zoom, and each frame is a real screen shown at it.
      assert html =~ "width:calc(1180px * var(--pb-frame-zoom))"
      assert html =~ "width:1180px;height:820px;zoom:var(--pb-frame-zoom)"
      assert html =~ "width:560px;height:844px;zoom:var(--pb-frame-zoom)"
      assert view |> element("#pb-canvas-scroll") |> render() =~ "--pb-frame-zoom:0.3"
    end

    # The frame row hugs the left edge in both directions. Centring it meant the frames slid sideways
    # as the zoom changed, and stacking them re-centred each one under the last.
    test "the frames view is left-aligned, in a row and stacked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      # The row's OWN opening tag: each frame's label line is legitimately `items-center`.
      row_class = fn -> view |> element("#pb-framerow") |> render() |> opening_tag() end

      assert row_class.() =~ "items-start"
      refute row_class.() =~ "items-center"
      assert view |> element("#pb-canvas-scroll") |> render() =~ "justify-start"

      view |> element("#pb-framedir") |> render_click()
      assert row_class.() =~ "flex-col"
      assert row_class.() =~ "items-start"
      refute row_class.() =~ "items-center"
    end

    test "a single frame stays centred", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert view |> element("#pb-canvas-scroll") |> render() =~ "justify-center"
    end

    # The zoom is the frame's `zoom` style, and the chrome scales a canvas right-click by exactly the
    # ratio that style paints — so the bounds it can reach are load bearing, not decoration.
    test "the canvas zoom steps, resets and stops at its bounds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      note = fn -> view |> element("[data-role='pb-viewnote']") |> render() end
      frame = fn -> view |> element("#pb-canvas-scroll") |> render() |> opening_tag() end

      assert note.() =~ "100%"
      assert frame.() =~ "--pb-single-zoom:1.0"

      render_click(view, "zoom", %{"step" => "10"})
      assert note.() =~ "110%"
      assert frame.() =~ "--pb-single-zoom:1.1"

      render_click(view, "zoom_reset", %{})
      assert note.() =~ "100%"

      for _ <- 1..8, do: render_click(view, "zoom", %{"step" => "-10"})
      assert note.() =~ "40%"
      assert frame.() =~ "--pb-single-zoom:0.4"

      for _ <- 1..17, do: render_click(view, "zoom", %{"step" => "10"})
      assert note.() =~ "200%"
      assert frame.() =~ "--pb-single-zoom:2.0"

      # "Fit to screen" is the same reset under another name, from the keyboard.
      render_click(view, "shortcut", %{"key" => "fit"})
      assert note.() =~ "100%"
      assert frame.() =~ "--pb-single-zoom:1.0"
    end

    # The zoom is drawn once, as a custom property on the canvas scroll, and the frame reads it: a
    # zoom change re-renders no frame, and `PbZoom` can repaint the whole canvas with one write.
    test "the single frame reads the zoom from the canvas scroll", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 130})

      [scroll, frame] =
        view |> element("#pb-canvas-scroll") |> render() |> String.split(">", parts: 2)

      assert scroll =~ ~s(phx-hook="PbZoom")
      assert scroll =~ ~s(data-single-zoom="130")
      assert scroll =~ "--pb-single-zoom:1.3"
      assert frame =~ "zoom:var(--pb-single-zoom)"
      refute frame =~ "1.3"
      assert view |> element("[data-role='pb-viewnote']") |> render() =~ "130%"
    end

    # The buttons are stepped in the browser; the server hears the settled value once, so they carry
    # no `phx-click` of their own.
    test "the More menu zoom is a client control bounded by the server", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      controls = view |> element("#pb-zoom") |> render()

      assert opening_tag(controls) =~ ~s(phx-hook="PbZoom")
      assert opening_tag(controls) =~ ~s(data-min="40")
      assert opening_tag(controls) =~ ~s(data-max="200")
      assert opening_tag(controls) =~ ~s(data-event="zoom_set")
      refute controls =~ "phx-click"
      assert view |> element("#pb-zoom-in") |> render() =~ ~s(data-zoom-step="10")
      assert view |> element("#pb-zoom-out") |> render() =~ ~s(data-zoom-step="-10")
      assert view |> element("#pb-zoom-reset") |> render() =~ ~s(data-zoom-reset="100")

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 40})
      assert has_element?(view, "#pb-zoom-out[disabled]")
      refute has_element?(view, "#pb-zoom-in[disabled]")

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => 200})
      assert has_element?(view, "#pb-zoom-in[disabled]")
      refute has_element?(view, "#pb-zoom-out[disabled]")
      assert view |> element("#pb-zoom-reset") |> render() =~ "200%"
    end

    test "zoom_set clamps to the bounds and ignores anything but an integer", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      zoom = fn -> :sys.get_state(view.pid).socket.assigns.zoom end

      set = fn value ->
        render_hook(view |> element("#pb-zoom"), "zoom_set", %{"value" => value})
      end

      set.(150)
      assert zoom.() == 150

      set.(5)
      assert zoom.() == 40

      set.(900)
      assert zoom.() == 200

      set.("70")
      assert zoom.() == 70

      for garbage <- ["abc", "80px", "", 80.5, nil, true, %{"v" => 1}, [90]] do
        set.(garbage)
        assert zoom.() == 70, inspect(garbage)
      end

      render_hook(view |> element("#pb-zoom"), "zoom_set", %{})
      assert zoom.() == 70
    end

    test "the frames view gets its own zoom and a row/column toggle", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      refute has_element?(view, "#pb-frzoom-in")

      render_click(view, "set_device", %{"device" => "frames"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "30%"

      controls = view |> element("#pb-frzoom") |> render()
      assert opening_tag(controls) =~ ~s(phx-hook="PbZoom")
      assert opening_tag(controls) =~ ~s(data-min="20")
      assert opening_tag(controls) =~ ~s(data-max="100")
      assert opening_tag(controls) =~ ~s(data-event="frame_zoom_set")
      refute controls =~ "phx-click"
      assert view |> element("#pb-frzoom-in") |> render() =~ ~s(data-zoom-step="10")
      assert view |> element("#pb-frzoom-out") |> render() =~ ~s(data-zoom-step="-10")
      assert view |> element("#pb-frzoom-reset") |> render() =~ ~s(data-zoom-reset="100")

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 40})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "40%"

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 100})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "100%"

      assert view |> element("#pb-framedir") |> render() =~ "In a row"
      view |> element("#pb-framedir") |> render_click()
      assert view |> element("#pb-framedir") |> render() =~ "Stacked"
    end

    test "zoom stops at the prototype's bounds", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})

      for _ <- 1..12, do: render_click(view, "frame_zoom", %{"step" => "-10"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "20%"
      assert has_element?(view, "#pb-frzoom-out[disabled]")

      for _ <- 1..14, do: render_click(view, "frame_zoom", %{"step" => "10"})
      assert view |> element("#pb-frzoom-reset") |> render() =~ "100%"
      assert has_element?(view, "#pb-frzoom-in[disabled]")
      refute has_element?(view, "#pb-frzoom-out[disabled]")
    end

    test "frame_zoom_set clamps to the bounds and ignores anything but an integer", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})
      zoom = fn -> :sys.get_state(view.pid).socket.assigns.frame_zoom end

      set = fn value ->
        render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => value})
      end

      set.(60)
      assert zoom.() == 60

      set.(0)
      assert zoom.() == 20

      set.(400)
      assert zoom.() == 100

      set.("50")
      assert zoom.() == 50

      for garbage <- ["abc", "60%", "", 60.0, nil, false, %{"v" => 1}, [70]] do
        set.(garbage)
        assert zoom.() == 50, inspect(garbage)
      end

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{})
      assert zoom.() == 50
    end

    # The frames never carry the zoom themselves: a zoom change rewrites the one custom property on
    # the canvas scroll and leaves every frame's markup exactly as it was.
    test "the frames read the zoom from the canvas scroll", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "set_device", %{"device" => "frames"})
      row = view |> element("#pb-framerow") |> render()

      render_hook(view |> element("#pb-frzoom"), "frame_zoom_set", %{"value" => 60})

      scroll = view |> element("#pb-canvas-scroll") |> render() |> opening_tag()

      assert view |> element("#pb-framerow") |> render() == row
      assert scroll =~ ~s(data-frame-zoom="60")
      assert scroll =~ "--pb-frame-zoom:0.6"
      refute row =~ "zoom:0."
    end

    test "the direction toggle flips the canvas, not the editor chrome", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-dir-rtl") |> render_click()

      assert editor(view).dir == "rtl"

      # The chrome's own root tag only — `phx-value-dir="rtl"` on the toggle itself contains that
      # same string, so a whole-page match would pass no matter what.
      [_before, after_id] = view |> render() |> String.split("pb-root", parts: 2)
      [opening_tag, _rest] = String.split(after_id, ">", parts: 2)
      refute opening_tag =~ "dir="

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ ~s(dir="rtl")

      view |> element("#pb-dir-ltr") |> render_click()
      assert editor(view).dir == "ltr"
    end

    test "the mobile bar's direction tab flips the canvas", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      assert editor(view).dir == "ltr"

      view |> element("#pb-mobtab-dir") |> render_click()

      assert editor(view).dir == "rtl"
      assert view |> element("#pb-mobtab-dir") |> render() =~ "RTL"
    end

    test "an open canvas follows the direction without being reloaded", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ ~s(dir="ltr")

      view |> element("#pb-dir-rtl") |> render_click()

      assert render(canvas) =~ ~s(dir="rtl")
    end
  end
end
