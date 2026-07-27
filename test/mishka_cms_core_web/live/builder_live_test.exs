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
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.PageStarter
  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.BuilderBlockPlugin, as: BlockPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderPageStarterPlugin, as: PageStarterPlugin
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe, as: ToolbarInvokedProbe
  alias MishkaCmsCore.Test.Plugins.BuilderToolbarProbe, as: ToolbarProbe
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

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

  # Save moved off the top bar into the ••• menu when the header was matched to the prototype: the
  # editor autosaves, so the bar has a stage control where the prototype has one and nothing else.
  defp save!(view), do: more!(view, "#pb-save")

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

  # THE ROW AS IT REALLY IS, read back through the same actor the editor writes with. Reading it
  # with `nil` answers `%{}` whatever is in the database — which makes "the rule is gone" pass for
  # the wrong reason, and is how the first version of these two tests fooled itself.
  defp stored_element_css(view, page) do
    actor = :sys.get_state(view.pid).socket.assigns.current_user
    ElementCss.all(actor, page.site_id, "page-#{page.id}")
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

  # A palette entry as the panel sees it, for asserting on what the card would draw.
  defp entry(view, name) do
    view |> editor() |> Map.fetch!(:components) |> Enum.find(&(&1.name == name))
  end

  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)

  # A component that declares one required property and one required slot, and one optional property
  # beside them — the smallest shape that can tell the marked apart from the unmarked.
  defp needy(site) do
    create_component!(
      site_id: site,
      name: "needful",
      template:
        ~s|<figure><img src={@src} alt={@alt} /><figcaption>{render_slot(@caption)}</figcaption></figure>|,
      attrs: [
        %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
        %{"name" => "alt", "type" => "string", "opts" => %{}}
      ],
      slots: [%{"name" => "caption", "opts" => %{"required" => true}, "attrs" => []}]
    )
  end

  defp needful_node(view),
    do:
      view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :component))

  # OPEN, NOT TOGGLED. `default_expanded/1` already opens the roots and the level below them, so a
  # page whose only root is the component under test starts open — and `toggle_expand` would shut it.
  defp expand!(view, id) do
    open? = view |> element(~s([data-layer-row="#{id}"])) |> render() =~ ~s(data-open="true")
    unless open?, do: render_click(view, "toggle_expand", %{"id" => id})
    :ok
  end

  # Every row the layers rail offers as a drop target, by the id a drop would resolve to.
  defp rail_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter("[data-layer-row]")
    |> LazyHTML.attribute("data-layer-row")
    |> Enum.uniq()
  end

  # Which width the frame is showing. Session state on the LiveView rather than in the document, so
  # it is read the same way the canvas hrefs are.
  defp device(view), do: :sys.get_state(view.pid).socket.assigns.device

  defp breakpoint(view), do: :sys.get_state(view.pid).socket.assigns.breakpoint

  # The compiled bundles the frame is served. Read off the LiveView rather than out of its HTML,
  # because the `<link>` is rendered by the root layout — see the canvas tests for why it moved.
  defp css_hrefs(view), do: :sys.get_state(view.pid).socket.assigns.canvas_css_hrefs

  # The palette stays mounted and hides, so "is the palette showing?" is a class question rather than
  # an existence one — see the `hidden` attr on `Panels.palette/1`.
  defp palette_hidden?(view) do
    assert has_element?(view, "#pb-palette"), "the palette stays mounted"
    has_element?(view, ~s(#pb-palette[data-showing="false"]))
  end

  defp editor_html(view) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()
  end

  defp component_node(view, name) do
    view
    |> editor()
    |> Map.fetch!(:tree)
    |> Tree.walk()
    |> Enum.find(&(Node.component_name(&1) == name))
  end

  defp headings(nodes), do: Enum.count(nodes, &(&1.tag == "h1"))

  defp node_parent(view, id),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id) |> Map.fetch!(:parent_id)

  # The `{@inner_content}` chip — a layout's one obligation, and the node most of these tests act on.
  defp expression_node(view),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :eex))

  defp node_with_tag(view, tag) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.tag == tag))
  end

  defp node_count(view), do: view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

  # WHATEVER IS ON SCREEN, both notices at once: a flash is the only place a refused command speaks
  # to the author, and which of the two it picks is not the point of the assertions below. The tags
  # come off first — Tailwind writes `hover:bg-white` into the class list, which reads exactly like
  # an inspected atom to anything looking for one.
  defp flashes(view) do
    ["#flash-info", "#flash-error"]
    |> Enum.filter(&has_element?(view, &1))
    |> Enum.map_join(" ", &(view |> element(&1) |> render() |> String.replace(~r/<[^>]*>/, "")))
    |> String.trim()
  end

  # A flash is set, never unset: nothing on the server clears one, and the hook that pushes
  # `lv:clear-flash` after the fade does not run here — so a stale sentence would answer for the
  # next command and hide a handler that went silent.
  defp clear_flashes(view) do
    for key <- ~w(info error), do: render_click(view, "lv:clear-flash", %{"key" => key})
    view
  end

  # AN INSPECTED TERM WHERE A SENTENCE BELONGS: a map, a tuple, or a bare atom reason. Every one of
  # them is an internal the author has no word for, and all three read the same way in a flash.
  defp internals?(text), do: text =~ ~r/%\{|\{:|:[a-z_]/

  # How an attribute is HELD, which is what a row that shows it can corrupt: `{:expr, source}` is a
  # binding, `{:string, text}` is words, `:boolean` is a bare attribute.
  defp attr_of(view, id, name),
    do: view |> editor() |> Map.fetch!(:tree) |> Tree.get(id) |> Node.attr(name)

  # A value the property will take, for walking the whole vocabulary. An enumerated one must be one
  # of its own; a free-form one is never validated, so any length does.
  defp sample_style(prop), do: prop |> Styles.options() |> List.first("7px")

  # The style overrides a node actually carries — what every control in the Layout and Appearance
  # sections is a way of writing, and the only record of them there is.
  defp styles_of(view, node_id),
    do:
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.get(node_id)
      |> then(&Map.get(&1.meta, :styles, %{}))

  # A comment carries no tag, so it is found by kind instead.
  defp node_with_kind(view, kind) do
    view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == kind))
  end

  describe "mount" do
    test "renders the editor shell", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-root")
      assert has_element?(view, "#pb-left")
      assert has_element?(view, "#pb-right")

      # The top bar has the prototype's stage split-button and no Save — the editor autosaves, and
      # "Save draft now" lives in the ••• menu, which is folded away in the markup rather than
      # fetched: `#pb-more-btn` toggles it in the browser and never reaches this process.
      assert has_element?(view, "#pb-stage")
      assert has_element?(view, "#pb-stage-menu")
      assert has_element?(view, "#pb-more-menu.hidden")
      assert view |> element("#pb-more-btn") |> render() =~ "#pb-more-menu"

      assert has_element?(view, "#pb-save")
      assert has_element?(view, "#pb-undo")
      assert has_element?(view, "#pb-redo")
    end

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

    # THE FAST WAY TO THE ONE THING PEOPLE CHANGE. Everything else on the element toolbar acts at
    # once; layout is a choice, so the bar grows a row of shapes rather than sending the reader off
    # to the Inspector. It offers only what the component itself declares.
    test "the toolbar's layout button opens column shapes for a grid", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "tbgrid",
        template: ~s|<div class="grid">g</div>|,
        attrs: [
          %{
            "name" => "cols",
            "type" => "string",
            "opts" => %{"values" => ~w(one two three four), "default" => "two"}
          }
        ]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-tbgrid") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "select", %{"id" => placed.id})

      {:ok, canvas, _html} =
        live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, "#pb-eltb-layout"), "the four-way arrow is on the toolbar"

      # The row is RENDERED with the selection and revealed in the browser — asking the server to
      # show a row already on the page would patch the toolbar and drop it out of the top layer.
      assert has_element?(canvas, "#pb-eltb-cols"), "the row ships with the selection"

      assert render(canvas) =~ "#pb-eltb-cols { display: none;",
             "and starts hidden, for the hook to open"

      assert has_element?(canvas, "#pb-eltb-cols-four")

      refute render(canvas) =~ ~s(id="pb-eltb-layout" phx-click),
             "the arrow carries no server event at all"

      # THE VALUE MUST RIDE THE BUTTON'S OWN `value`. LiveView's `extractMeta` writes
      # `meta.value = el.value` AFTER collecting `phx-value-*`, so `phx-value-value` on a button is
      # always overwritten with "". `render_click/1` sends the attribute map WITHOUT that override,
      # so it passes either way — this is the only thing that catches it.
      shape = canvas |> element("#pb-eltb-cols-four") |> render()

      assert shape =~ ~s(value="four"),
             "the shape carries its value where the browser will read it"

      refute shape =~ "phx-value-value", "and never where the browser will blank it"

      # THE PANEL MUST OUTLIVE A CHOICE. Choosing writes to the document, so the server re-renders
      # this element — and a patch takes back the `display` the hook wrote, leaving the rule's own
      # `none` underneath. The hook holds the open flag and re-applies it in `placeToolbar`, which
      # `updated()` already calls, so a reader can try six options without reopening between each
      # one. All the server may ever say is "shut"; rendering it open would fight the browser for
      # the same property.
      assert render(canvas) =~ "#pb-eltb-cols { display: none;",
             "the server always renders the panel shut and never tries to render it open"

      canvas |> element("#pb-eltb-cols-four") |> render_click()

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(placed.id)
             |> Map.fetch!(:attrs)
             |> Map.new()
             |> Map.get("cols") == {:string, "four"}
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
    test "switching the left panel to the inspector", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-palette-search")
      refute palette_hidden?(view)

      view |> element("#pb-lefttab-inspector") |> render_click()

      # HIDDEN, NOT REMOVED. The 177 cards stay in the DOM so coming back to the tab costs nothing;
      # what the reader sees is the same either way.
      assert palette_hidden?(view)
      assert render(view) =~ "Select an element on the canvas"
    end

    # STARRING NEVER REACHES THE SERVER. Which four of 177 components one author keeps reaching for
    # is not the site's data, so the star, the two chips and the recent row are the browser's from
    # end to end — the rules are tested in `assets/js/pb_prefs.test.js`. What the server owes them is
    # the handful of hooks and names they read, and that is what this pins: lose `data-name` and the
    # star has nothing to star.
    # WHAT A CARD WILL PUT ON THE PAGE, shown while the pointer rests on it.
    #
    # Everything about showing it is the client's: when to ask, where to put it, when to take it
    # away. The server renders and pushes, and these assert exactly that seam — the panel exists for
    # the hook to find, and the event answers with a document.
    # ENTER IN A STYLE FIELD USED TO RELOAD THE PAGE. A LiveView form with `phx-change` and no
    # `phx-submit` is not intercepted, so the browser applies its implicit-submission rule and does a
    # native GET to the current URL — taking the whole editing session with it.
    test "every style form can be submitted, so Enter never leaves the page", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      forms = ~r/<form[^>]*>/ |> Regex.scan(render(view)) |> List.flatten()
      style_forms = Enum.filter(forms, &(&1 =~ "pb-style-form" or &1 =~ "pb-attr-form"))

      assert style_forms != []
      for form <- style_forms, do: assert(form =~ "phx-submit")
    end

    test "and the search boxes that sit in a form do too", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      for id <- ~w(pb-find-form pb-block-search-form) do
        case Regex.run(~r/<form[^>]*id="#{id}"[^>]*>/, html) do
          nil -> :not_rendered_in_this_state
          [form] -> assert form =~ "phx-submit"
        end
      end
    end

    # A CONTRIBUTED CATEGORY NEEDS A CHIP TO REACH IT BY. The row was built from the core lists, so a
    # block an extension added under its own category could only ever be found under "all" — while
    # showing under every other filter too, because the merge happened after the filtering.
    test "the block category chips include the ones extensions brought", %{conn: conn, page: page} do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: MishkaCmsCore.Test.Plugins.BuilderBlockPlugin,
          event: "builder:blocks",
          extension: :mishka_installer,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile("builder:blocks", :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(
          :name,
          MishkaCmsCore.Test.Plugins.BuilderBlockPlugin,
          false
        )
      end)

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      assert has_element?(view, "#pb-blockcat-social-proof")
      assert has_element?(view, "#pb-blockcat-all")
    end

    test "the hover preview panel is there for the hook to drive", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-card-preview[phx-hook='PbPaletteHover'][hidden]")
      assert has_element?(view, "#pb-card-preview [data-role='pb-card-preview-frame']")
      assert has_element?(view, "#pb-card-preview [data-role='pb-card-preview-note']")
    end

    # THE ONE TOKEN THAT MUST NEVER BE THERE. The frame holds a component's own markup, which is
    # authored in the CMS and therefore untrusted; `allow-same-origin` is granted so the panel can
    # read the drawn height and size itself to it, and that is only safe while nothing inside can
    # run. Add `allow-scripts` beside it and the frame can reach straight into the admin session.
    test "and the frame it draws into can never run scripts", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)

      assert html =~ ~s|sandbox="allow-same-origin"|
      refute html =~ "allow-scripts"
    end

    test "asking for a preview answers with a document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => "<p>a paragraph</p>"})

      assert_push_event(view, "pb:card-preview", %{template: template, html: html})
      assert template == "<p>a paragraph</p>"
      assert html =~ "<p>a paragraph</p>"
    end

    # A component that needs configuring says so, rather than showing an empty box that reads as a
    # broken component.
    test "and a template that will not render answers with the reason", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => "<p>{@nothing_supplies_this}</p>"})

      assert_push_event(view, "pb:card-preview", %{note: note})
      assert is_binary(note) and note != ""
    end

    test "an empty ask is ignored rather than rendered", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_hook(view, "preview_card", %{"template" => ""})

      refute_push_event(view, "pb:card-preview", %{})
    end

    test "the palette carries what the star and recent rows need", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "starrable",
        template: ~s|<div class="p-4">hi</div>|
      )

      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-palette[phx-hook='PbPalettePrefs'][data-scope]")
      assert has_element?(view, "#pb-palette-fav[data-pb-prefchip='fav']")
      assert has_element?(view, "#pb-palette-recent[data-pb-prefchip='recent']")
      assert has_element?(view, "[data-role='pb-count']")

      # Both empty states ship hidden — the server cannot know whether anything is starred.
      assert has_element?(view, "#pb-palette-empty-fav[hidden]")
      assert has_element?(view, "#pb-palette-empty-recent[hidden]")

      cell = view |> element("[data-role='pb-compcell']") |> render()
      assert cell =~ ~s(data-name=)
      assert cell =~ ~s(data-role="pb-fav")

      # NO `phx-click` ON THE STAR. It sits on top of the tile that places the component; an event
      # here would be a round trip, and a re-render of the tile under the pointer.
      star = view |> element("[data-role='pb-fav']") |> render()
      refute star =~ "phx-click"
    end

    # Clicking an element ON THE CANVAS means "work on this", so the chrome swings to its form. The
    # canvas is a second LiveView, so what reaches this one is the session broadcast — which is what
    # the test drives, origin and all.
    test "a canvas click opens the inspector, a panel selection does not", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      token = view |> editor() |> Map.fetch!(:token)

      {:ok, _session} = EditorSession.select(token, section.id, :panel)
      refute palette_hidden?(view)

      {:ok, _session} = EditorSession.select(token, section.id, :canvas)
      assert palette_hidden?(view)
      assert has_element?(view, "#pb-bp-mobile")
    end

    # The grip drags locally and reports once, so the bounds have to reach the browser: without
    # data-min/data-max the drag would run past the ceiling and then jump back when the server
    # clamped what it was finally told. Same numbers on both sides, from `Panels.resize_bounds/1`.
    test "the resize grips carry the same bounds the server clamps to", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      for {panel, id} <- [left: "#pb-grip-left", right: "#pb-grip-right"] do
        {min, max} = Panels.resize_bounds(panel)

        assert view |> element(id) |> render() =~ ~s(data-min="#{min}")
        assert view |> element(id) |> render() =~ ~s(data-max="#{max}")
      end

      # And the value the grip finally reports is clamped again here, because what arrives is
      # whatever the page chose to send.
      # The server's number is the FALLBACK of a custom property a drag overrides — see
      # `Panels.resize_bounds/1` and the `--pb-*` variables — so that is where the clamp shows up.
      render_click(view, "resize", %{"panel" => "left", "value" => 9_000})
      assert render(view) =~ "var(--pb-left-w, #{elem(Panels.resize_bounds(:left), 1)}px)"

      render_click(view, "resize", %{"panel" => "left", "value" => 10})
      assert render(view) =~ "var(--pb-left-w, #{elem(Panels.resize_bounds(:left), 0)}px)"
    end

    # BETWEEN A COMPONENT AND A WHOLE-PAGE PRESET there was nothing, so a landing page meant placing
    # a grid, a heading, a paragraph and a button and repeating it for every band down the page.
    test "a section drops in as one block", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-lefttab-blocks") |> render_click()
      assert has_element?(view, "#pb-block-features-four")

      before = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

      view |> element("#pb-block-features-four") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      after_place = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length()

      assert after_place > before + 20,
             "a four-across feature row is forty-odd nodes, not one"

      # …and it is ONE step, so a section leaves the way it arrived.
      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> length() == before
    end

    test "the block list filters by category and by search", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      view |> element("#pb-blockcat-Footer") |> render_click()
      assert has_element?(view, "#pb-block-footer-columns")
      refute has_element?(view, "#pb-block-hero-centred")

      view |> element("#pb-blockcat-all") |> render_click()
      render_change(view, "block_query", %{"value" => "pricing"})

      assert has_element?(view, "#pb-block-pricing-three")
      refute has_element?(view, "#pb-block-hero-centred")
    end

    # Every block is plain HTML and Tailwind on purpose: one reaching for `chelekom-card` would fail
    # on an install without Chelekom, which is the assumption this whole effort has been removing.
    test "blocks depend on no kit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()
      view |> element("#pb-block-hero-centred") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      kinds =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.kind) |> Enum.uniq()

      refute :component in kinds
    end

    # SPACING AND COLOUR ARE WHAT PEOPLE REACH FOR FIRST, and both shipped folded shut — three folds
    # and a scroll below the component's own properties. Nothing said they were there.
    test "Layout and Appearance are open the first time a node is selected", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      node = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => node.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)

      assert html =~ "Padding", "the Layout controls are on screen without unfolding anything"
      assert has_element?(view, "#pb-swatch-white"), "and so is the background swatch row"
    end

    test "the inspector shows the selected element", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      html = render(view)
      assert html =~ "section"
      assert html =~ ~s(data-role="pb-bptabs")
      assert html =~ "Attributes"
    end

    # TWO ELEMENTS ANSWERING TO ONE ID. Every palette entry is a worked example and an example names
    # things — the kit's delete dialog ships `id="modal-delete-page"` with `id="btn-delete-cancel"`
    # inside it. Placing one twice, which is how an author builds the second dialog, put both names
    # in the document twice: the second button then opened the FIRST dialog, and LiveView raises
    # trying to patch a container it cannot tell apart.
    test "placing the same snippet twice renumbers the copy and repoints its own wiring", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      snippet =
        ~S|<div id="modal-delete-page">Are you sure?</div>| <>
          ~S|<button id="btn-delete" phx-click={JS.exec("data-pb-open", to: "#modal-delete-page")}>Delete</button>|

      for index <- ["0", "1"] do
        render_click(view, "op", %{
          "kind" => "insert",
          "template" => snippet,
          "parent_id" => section.id,
          "index" => index
        })
      end

      tree = editor(view).tree
      written = for node <- Tree.walk(tree), {:string, id} <- [Node.attr(node, "id")], do: id

      assert Enum.sort(written) == [
               "btn-delete",
               "btn-delete-2",
               # the fixture's own <section id="hero">
               "hero",
               "modal-delete-page",
               "modal-delete-page-2"
             ]

      assert length(Enum.uniq(written)) == length(written), "no id may be claimed twice"

      # And the copy's own button opens the copy, not the dialog that was already there.
      openers =
        for node <- Tree.walk(tree),
            {:expr, source} <- [Node.attr(node, "phx-click")],
            do: source

      assert Enum.sort(openers) == [
               ~S|JS.exec("data-pb-open", to: "#modal-delete-page")|,
               ~S|JS.exec("data-pb-open", to: "#modal-delete-page-2")|
             ]
    end

    # DUPLICATE USED TO ANSWER THIS DIFFERENTLY AND WORSE: it replaced the written id with a random
    # one, so `modal-delete-page` became `phx-F_3nK…` — the author's name for the element thrown
    # away — and nothing rewrote the copy's own button, which went on opening the original.
    test "duplicating keeps the author's name for the element and takes the next number", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "op", %{
        "kind" => "insert",
        "template" => ~S|<div id="pricing-card"><a href="#pricing-card">anchor</a></div>|,
        "parent_id" => section.id,
        "index" => "0"
      })

      card =
        editor(view).tree
        |> Tree.walk()
        |> Enum.find(&(Node.attr(&1, "id") == {:string, "pricing-card"}))

      render_click(view, "op", %{"kind" => "duplicate", "node_id" => card.id})

      tree = editor(view).tree
      written = for node <- Tree.walk(tree), {:string, id} <- [Node.attr(node, "id")], do: id

      assert Enum.sort(written) == ["hero", "pricing-card", "pricing-card-2"]

      hrefs = for node <- Tree.walk(tree), {:string, href} <- [Node.attr(node, "href")], do: href
      assert Enum.sort(hrefs) == ["#pricing-card", "#pricing-card-2"]
    end

    # A SEARCH BOX WITH NO WAY OUT. Every filtered list in the editor is filtered by a word held on
    # the SERVER, so selecting the text and deleting it is the only way back to the full list — and
    # nothing on the field said so. The ✖ is shown by `peer-placeholder-shown:hidden`, which is a
    # CSS answer to a CSS question: an input is `:placeholder-shown` exactly while it is empty.
    test "every live text field in the editor carries a clear control", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      render_click(view, "set_left_tab", %{"tab" => "blocks"})
      render_click(view, "toggle_command", %{})
      render_click(view, "open_find", %{})

      html = render(view)

      for field <- ~w(pb-palette-search pb-block-search pb-command-input pb-find-input
                      pb-replace-input) do
        assert html =~ ~s(data-for="#{field}"),
               "#{field} has no clear control"
      end

      # Shown by CSS alone, so an empty field never draws one and no round trip reveals it.
      assert html =~ "peer-placeholder-shown:hidden"
    end

    test "clicking the clear control blanks the field the server is filtering by", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      _loaded = render_async(view)

      render_click(view, "palette_query", %{"value" => "zzzznothing"})
      assert view |> element("#pb-palette-search") |> render() =~ ~s(value="zzzznothing")

      view |> element(~s([data-for="pb-palette-search"])) |> render_click()

      # The box AND the query behind the list, in one round trip — clearing only the box would leave
      # the list filtered by a word no longer written anywhere.
      assert view |> element("#pb-palette-search") |> render() =~ ~s(value="")
    end

    # AND THE CONTROL MUST NOT FOCUS THE FIELD IT JUST CLEARED. LiveView never overwrites the value
    # of a focused input — `mergeFocusedInput` copies every attribute except `value` — so a
    # `JS.focus` in this chain left the box still reading the old word over a list that had gone back
    # to everything. Measured in a browser; the half-cleared state is invisible to a render test,
    # which is why the command itself is asserted here.
    test "the clear control pushes and does not focus the field", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      command =
        view
        |> element(~s([data-for="pb-palette-search"]))
        |> render()

      assert command =~ ~s([&quot;push&quot;)
      refute command =~ "focus", "focusing the field stops LiveView from clearing it"
    end

    # ONE FORM, TWO FIELDS, ONE HANDLER THAT READS BOTH. Clearing the search term by pushing only
    # `find` would have sent no `replace` at all, and the handler's `params["replace"] || ""` would
    # have thrown away the replacement text sitting in the box beside it.
    test "clearing Find leaves Replace alone, and the other way round", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "open_find", %{})
      render_click(view, "find_query", %{"find" => "Contact", "replace" => "Reach"})

      view |> element(~s([data-for="pb-find-input"])) |> render_click()

      assert view |> element("#pb-find-input") |> render() =~ ~s(value="")
      assert view |> element("#pb-replace-input") |> render() =~ ~s(value="Reach")

      render_click(view, "find_query", %{"find" => "Contact", "replace" => "Reach"})
      view |> element(~s([data-for="pb-replace-input"])) |> render_click()

      assert view |> element("#pb-find-input") |> render() =~ ~s(value="Contact")
      assert view |> element("#pb-replace-input") |> render() =~ ~s(value="")
    end

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

    test "the layers panel lists the document's elements", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-layers")
      assert render(view) =~ "section"
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
    test "the palette is grouped under category headings with counts", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "grid-box", type: "layout")
      create_component!(site_id: site.id, name: "big-title", type: "text")

      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      assert html =~ "LAYOUT"
      assert html =~ "TEXT"
      assert html =~ "Global — all sites"
      assert html =~ "Tenant only"
    end

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

    # The layers tree is the other way into the document, and it had three holes: a row named every
    # component ".component", a row could not be dropped onto another one, and there was no way to
    # delete a branch from it.
    test "a component row is named after the component, not the wrapper tag", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="chelekom-alert" site="Global"/></div>)
        )

      # The tree opens two levels deep on arrival, so a component one level in is already listed.
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "chelekom-alert"
      refute html =~ ">.component<"
    end

    # A DEFAULT IS NOT ALWAYS A WORD. `chelekom-banner` declares `params` with a default of
    # `%{kind: "banner"}`, and the layers row rendered it with `to_string/1` — which raises
    # `Protocol.UndefinedError` on a map and took the whole builder LiveView down the moment a banner
    # appeared in the tree. Seven of the kit's components declare a map or list default this way.
    test "a component whose attribute defaults to a map still renders its row", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "mappy",
        template: "<div>{@params[:kind]}</div>",
        attrs: [
          %{"name" => "params", "type" => "map", "opts" => %{"default" => %{"kind" => "banner"}}}
        ],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="mappy" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      assert render(view) =~ "mappy"
    end

    # Rendering the layers row was only the FIRST of eight places that stringified a default. Opening
    # the inspector went through `plain_input/1` and raised there instead — same map, same
    # `Protocol.UndefinedError`, and because a raise inside a render kills the LiveView, the author
    # saw the canvas flash and reconnect rather than an inspector.
    #
    # So this selects the node, which is what a click does, and covers every widget the eight call
    # sites belong to: a map and a list default against a text box, a colour, a link, an image and a
    # select.
    test "selecting a component with structured defaults opens the inspector", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "structy",
        template:
          "<div class={@color}><a href={@href}><img src={@src} /></a>{@params[:kind]}{@classes}{@variant}</div>",
        attrs: [
          %{"name" => "params", "type" => "map", "opts" => %{"default" => %{"kind" => "banner"}}},
          %{"name" => "classes", "type" => "list", "opts" => %{"default" => ["a", "b"]}},
          %{"name" => "color", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{"name" => "href", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{"name" => "src", "type" => "string", "opts" => %{"default" => %{"x" => 1}}},
          %{
            "name" => "variant",
            "type" => "string",
            "opts" => %{"default" => %{"x" => 1}, "values" => ["default", "outline"]}
          }
        ],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="structy" site="#{site.name}"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      component = node_with_tag(view, ".component")

      render_click(view, "inspect", %{"id" => component.id})

      # It is still alive, and it is showing the component rather than a reconnect.
      assert render(view) =~ "structy"
    end

    # A component's slots ARE its children in the tree, and each is named by the slot it fills —
    # written the way the markup writes it, `:label`, rather than as the tree's own `__label_slot`.
    test "a component's slots appear in the tree, named", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root"><.component component_name="chelekom-alert" site="Global">\
          <:label>Careful</:label></.component></div>\
          """
        )

      # Two levels are open on arrival, and a component with a slot is a branch — so both the
      # component and the slot under it are already listed.
      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "chelekom-alert"
      assert html =~ ":label"
      refute html =~ "__label_slot"
    end

    # A component takes a drop only where the drop can land: it needs a slot to hold it. 120 of the
    # kit's components declare one; a component that declares none renders nothing you drop in, so
    # the tree must not offer it as a target.
    test "only a component with a slot is a drop target", %{conn: conn, site: site} do
      with_slot =
        create_component!(
          site_id: nil,
          name: "demo-card",
          slots: [%{"name" => "inner_block", "opts" => %{"required" => false}}],
          template: "<div class=\"card\">{render_slot(@inner_block)}</div>"
        )

      without = create_component!(site_id: nil, name: "demo-rule", template: "<hr class=\"r\"/>")

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root">\
          <.component component_name="#{with_slot.name}" site="Global"/>\
          <.component component_name="#{without.name}" site="Global"/>\
          </div>\
          """
        )

      {:ok, view, _html} = open_builder(conn, page)

      nodes =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :component))

      [card, rule] = Enum.sort_by(nodes, &Node.component_name/1)

      assert view |> element(~s([data-layer-row="#{card.id}"])) |> render() =~
               ~s(data-container="true")

      refute view |> element(~s([data-layer-row="#{rule.id}"])) |> render() =~
               ~s(data-container="true")
    end

    # WHAT CAN GO INSIDE, folded like everything else in the rail. The slot rows used to hang off the
    # component at full volume, and a component that declared NONE got a line reading
    # `__ no slots declared` — the common case, written in the tree's own vocabulary, filed under
    # `.properties`, which is not what it was about. Reported on the editor issue as "it doesn't look
    # good, it's confusing".
    test "a component's slots are a folded group, not loose rows", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-panel",
        slots: [%{"name" => "footer", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-panel" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      panel = component_node(view)
      render_click(view, "toggle_expand", %{"id" => panel.id})

      assert has_element?(view, "#pb-slots-#{panel.id}"), "the rail has no .slots group"

      refute has_element?(view, "#pb-slot-add-#{panel.id}-footer"),
             "the slot rows are open before anybody asked for them"

      view |> element("#pb-slots-#{panel.id}") |> render_click()

      assert has_element?(view, "#pb-slot-add-#{panel.id}-footer")
    end

    # Named the way it is WRITTEN. `<:footer>` is what goes in the markup; `__footer_slot` was the
    # tree's bookkeeping leaking into a label the author has to read.
    test "and a slot is labelled the way it is written in the markup", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-aside",
        slots: [%{"name" => "footer", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-aside" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      aside = component_node(view)
      render_click(view, "toggle_expand", %{"id" => aside.id})
      view |> element("#pb-slots-#{aside.id}") |> render_click()

      row = view |> element("#pb-slot-add-#{aside.id}-footer") |> render()

      assert row =~ ":footer"
      refute row =~ "__footer_slot"
    end

    # THE COMMON CASE SAYS NOTHING UNTIL ASKED. Most components declare no slots at all, and the old
    # line announced that on every one of them.
    test "a component with no slots is silent until the group is opened", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-rule",
        slots: [],
        template: "<hr />"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-rule" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      rule = component_node(view)
      render_click(view, "toggle_expand", %{"id" => rule.id})

      refute render(view) =~ "no slots declared", "the dead line is back"
      refute render(view) =~ "takes nothing inside"

      view |> element("#pb-slots-#{rule.id}") |> render_click()

      assert render(view) =~ "takes nothing inside"
    end

    defp component_node(view) do
      view
      |> editor()
      |> Map.fetch!(:tree)
      |> Tree.walk()
      |> Enum.find(&(&1.kind == :component))
    end

    # A Phoenix slot may be given more than once, and two rows called `__item_slot` tell you nothing
    # about which is which.
    test "repeated slots are numbered in the tree", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-list",
        slots: [%{"name" => "item", "opts" => %{"required" => false}}],
        template: "<ul>{render_slot(@item)}</ul>"
      )

      page =
        create_page!(
          site_id: site.id,
          template: """
          <div id="root"><.component component_name="demo-list" site="Global">\
          <:item>One</:item><:item>Two</:item></.component></div>\
          """
        )

      {:ok, view, _html} = open_builder(conn, page)
      list = component_node(view)

      html = render(view)
      assert html =~ ":item 1"
      assert html =~ ":item 2"

      # And the row to add a third says so rather than claiming the slot is empty. It lives in the
      # component's `.slots` group now, which is folded until it is asked for.
      view |> element("#pb-slots-#{list.id}") |> render_click()
      assert render(view) =~ "add another"
    end

    # The rule that a component needs somewhere to put a child is the SERVER's, not the browser's —
    # the tree only mirrors it, so a tampered payload has to be refused here.
    test "the server refuses a drop into a component with no slot", %{conn: conn, site: site} do
      create_component!(site_id: nil, name: "demo-hr", template: "<hr/>")

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-hr" site="Global"/><p>x</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      tree = editor(view).tree
      target = tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))
      dragged = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      html =
        render_click(view, "drop", %{
          "node_id" => dragged.id,
          "parent_id" => target.id,
          "index" => "0"
        })

      assert html =~ "does not declare a slot"
      # And nothing moved.
      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(dragged.id)
             |> Map.fetch!(:parent_id) ==
               dragged.parent_id
    end

    # A required slot is the same promise as a required property.
    test "a missing required slot blocks the save", %{conn: conn, site: site} do
      create_component!(
        site_id: nil,
        name: "demo-collapse",
        slots: [%{"name" => "trigger", "opts" => %{"required" => true}}],
        template: "<div>{render_slot(@trigger)}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-collapse" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      html = publish!(view)
      assert html =~ "Not saved"
      assert html =~ "demo-collapse.:trigger"
    end

    # A component's markup lives on the COMPONENT, not on the page — so the tree shows it in place
    # rather than sending anyone to another screen, and shows it as a window, not as rows to edit.
    test "a component's own markup is listed inside it, read-only", %{conn: conn, site: site} do
      component =
        create_component!(
          site_id: nil,
          name: "demo-footer",
          template: ~s(<footer class="f"><p>Built with MishkaCMS</p></footer>)
        )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="#{component.name}" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      html = render(view)
      assert html =~ "demo-footer"
      # Its insides are there…
      assert html =~ "footer"

      # …but they carry none of the row actions, because editing them would rewrite the component
      # under every other page using it.
      instance =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      refute has_element?(view, "#pb-layer-delete-#{instance.id} ~ *")
    end

    test "a layers row carries what a drop needs and deletes its branch", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      row = view |> element(~s([data-layer-row="#{section.id}"])) |> render()
      assert row =~ ~s(draggable="true")
      assert row =~ ~s(data-parent-id=)
      assert row =~ ~s(data-index=)
      assert row =~ ~s(data-container="true")
      assert row =~ ~s(data-kind="tag")

      # And the delete button takes the branch with it.
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()
      view |> element("#pb-layer-delete-#{section.id}") |> render_click()
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() < before
      refute has_element?(view, ~s([data-layer-row="#{section.id}"]))
    end

    # A COUNT HAS TO MATCH THE ROWS UNDER IT. The panel has always hidden the indentation between two
    # tags, but it counted it — so an indented `<div>` announced seven children over three rows, and a
    # container holding nothing but a newline offered a chevron that opened onto nothing.
    test "a row counts the children it is going to draw", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: "<section>\n  <p>One</p>\n  <p>Two</p>\n</section>\n<div>\n</div>"
        )

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      assert length(section.children) == 5, "three runs of indentation and two paragraphs"

      row = view |> element(~s([data-layer-row="#{section.id}"])) |> render()
      assert row =~ "(2)"
      refute row =~ "(5)"
      assert row =~ ~s(phx-value-id="#{section.id}"), "and it is still expandable"

      empty = node_with_tag(view, "div")
      assert empty.children != [], "the div is holding its newline"

      empty_row = view |> element(~s([data-layer-row="#{empty.id}"])) |> render()
      refute empty_row =~ "(1)", "a container with only indentation in it has nothing to open"
      refute empty_row =~ "toggle_expand"
    end

    # ONE MENU FOR BOTH SURFACES. The canvas is a frame rendering the site's own document with none
    # of the admin stylesheet, so it forwards its right-clicks to the chrome rather than drawing a
    # second, inline-styled copy — which is why there is exactly one of these in the page and why it
    # carries no `phx-click`: the hook stamps the node and pushes the action, so opening costs
    # nothing and no patch can swap the row out mid-gesture.
    test "the right-click menu is rendered once, for both surfaces", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(
               view,
               "#pb-ctx[phx-hook='PbContextMenu'][data-target='[data-layer-row]']"
             )

      assert has_element?(view, "#pb-ctx[hidden]")

      menu = view |> element("#pb-ctx") |> render()
      refute menu =~ "phx-click"

      for action <- Panels.context_actions(), do: assert(menu =~ ~s(data-action="#{action}"))
    end

    test "an entry acts on the node it names, not on the selection", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "ctx", %{"action" => "duplicate", "node_id" => h1.id})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> headings() == 2
    end

    # WITHOUT THIS the menu edits one element while the inspector beside it still describes another,
    # which is how you change the padding of something you are not looking at. `duplicate` is the
    # wrong entry to assert it with — a copy takes the focus, and should.
    test "opening the menu selects what it was opened on", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})

      assert editor(view).selection == h1.id
    end

    test "wrap puts the node inside a fresh container", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "ctx", %{"action" => "wrap", "node_id" => h1.id})

      wrapper = view |> editor() |> Map.fetch!(:tree) |> Tree.get(node_parent(view, h1.id))
      assert wrapper.tag == "div"
      assert h1.id in wrapper.children
    end

    # The dead end a run of text used to be: a panel saying what it could not do and offering one way
    # out, to the element around it.
    test "a run of text offers the link from the inspector", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      text = Enum.find(Tree.walk(editor(view).tree), &(&1.kind == :text))

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => text.id})
      assert has_element?(view, "#pb-text-link")

      view |> element("#pb-text-link") |> render_click()

      assert Enum.any?(Tree.walk(editor(view).tree), &(&1.tag == "a"))
    end

    test "an element the words sit in offers no such button", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "set_left_tab", %{"tab" => "inspector"})
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})

      refute has_element?(view, "#pb-text-link")
    end

    test "styles travel between two elements", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      p = node_with_tag(view, "p")

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => h1.id,
        "bucket" => "base",
        "prop" => "padding",
        "value" => "8"
      })

      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})
      render_click(view, "ctx", %{"action" => "paste_styles", "node_id" => p.id})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(p.id)
             |> Map.fetch!(:meta)
             |> then(& &1.styles.base) == %{"padding" => "8"}
    end

    # The action is a word off the wire. Anything the menu does not offer is dropped rather than
    # being handed to the session to interpret.
    test "an action the menu never offers is ignored", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(view, "ctx", %{"action" => "publish_everything", "node_id" => h1.id})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # THE BAR ONLY EXISTS WHILE SOMETHING IS HELD. It sits above the canvas rather than floating over
    # it, because a bar that covers the page hides the thing it is about.
    test "holding a second element opens the bulk bar", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      refute has_element?(view, "#pb-multi-bar")

      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})

      assert has_element?(view, "#pb-multi-bar")
      assert render(view) =~ "2 elements held"

      render_click(view, "bulk", %{"action" => "delete"})

      refute has_element?(view, "#pb-multi-bar")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> headings() == 0
    end

    test "clearing lets go without changing the page", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})
      render_click(view, "clear_marks", %{})

      refute has_element?(view, "#pb-multi-bar")
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    # OVER THE PAGE'S WORDS, not its markup. A page says "Contact Us" in four places and the fifth is
    # a class called `contact-us`; renaming the company must not touch the CSS.
    test "find and replace sweeps the text and nothing else", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<section class="contact-us"><h1>Contact Us</h1><p>contact us today</p></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_find", %{})
      assert has_element?(view, "#pb-find")

      render_change(view, "find_query", %{"find" => "contact us", "replace" => "Talk to us"})

      # Two places, and the class is not one of them — the search is case-insensitive so the
      # capitalised heading counts.
      assert render(view) =~ "2 matches in 2 places"

      render_click(view, "replace_all", %{})

      heex = view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize()
      assert heex =~ "<h1>Talk to us</h1>"
      assert heex =~ "<p>Talk to us today</p>"
      assert heex =~ ~s(class="contact-us"), "a class is not a word on the page"
    end

    test "a replace-all is one undo", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><p>one</p><p>one</p><p>one</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize()

      render_click(view, "open_find", %{})
      render_change(view, "find_query", %{"find" => "one", "replace" => "two"})
      render_click(view, "replace_all", %{})

      render_click(view, "undo", %{})
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.Serializer.serialize() == before
    end

    test "searching for something that is not there says so", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "open_find", %{})
      render_change(view, "find_query", %{"find" => "zzzz", "replace" => ""})

      assert has_element?(view, "#pb-find-none")
      assert has_element?(view, "#pb-find-replace-all[disabled]")
    end

    # A `javascript:` in a link the ADMIN renders is the one way a third-party kit's bundle could
    # reach into this page, so only an http(s) address is offered.
    test "a doc_url that is not a web address is not offered", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "sneaky",
        template: ~s|<div>x</div>|,
        extra: %{"doc_url" => "javascript:alert(1)"}
      )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-sneaky") |> render_click()
      render_click(canvas, "select", %{})

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # SELECTING ON THE CANVAS, not in the panel. A panel selection is navigation and leaves the
      # left tab where the reader put it; a canvas click means "work on this", which is what swings
      # the panel to the Inspector the link lives in.
      render_click(canvas, "select", %{"id" => node.id})

      refute has_element?(view, "#pb-docs-link")
    end

    # Clicking a row has to move the ring on the CANVAS, which is a different LiveView. The push that
    # carries it compared the new selection against itself, so it never fired.
    test "selecting in the layers rail reaches the canvas", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      assert_push_event(canvas, "pb:selected", %{id: id})
      assert id == h1.id
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

  # The style write path: without these controls the breakpoint tabs and State chips would choose a
  # bucket that nothing ever writes to, which is what the audit found.
  describe "responsive style overrides" do
    setup %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # Layout and Appearance are open on selection — spacing and colour are what people reach for
      # first. The rest still need opening the way a reader would. "Editing at" is not among them any
      # more: the breakpoint is a permanent tab strip now, not a fold.
      for title <- ~w(state behavior attributes) do
        view |> element("#pb-section-#{title}") |> render_click()
      end

      %{view: view, node: section}
    end

    # THE BOX MODEL, AS A CONTROL. Eight edges, each where it is on the element. Before this the panel
    # offered `Padding Y`, `Padding X`, `Padding top` and `Padding bottom` — four of the eight edges
    # missing outright, including `margin-top`, which is the third most-used utility in the whole
    # block library.
    test "the spacing box draws all eight edges", %{view: view} do
      for edge <- ~w(mt mr mb ml pt pr pb pl) do
        assert has_element?(view, "#pb-edge-base-#{edge}"),
               "the spacing box has no cell for #{edge}"
      end
    end

    test "and typing in one writes that edge and nothing else", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px"}}

      view |> element("#pb-edge-form-base-pl") |> render_change(%{"value" => "2rem"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px", "pl" => "2rem"}}
    end

    # THE BOX HAD NO WAY OUT BUT THE KEYBOARD, and that fails in the one way a control must not: you
    # empty the field, the change does not reach the server, and the next render puts the old value
    # back — so it reads as a box that remembers what you deleted. Every other control here has a
    # Reset; this is the box's.
    test "a set edge can be cleared without retyping", %{view: view, node: node} do
      refute has_element?(view, "#pb-edge-clear-base-mt")

      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})

      assert has_element?(view, "#pb-edge-clear-base-mt")

      view |> element("#pb-edge-clear-base-mt") |> render_click()

      assert styles_of(view, node.id) == %{}
      refute has_element?(view, "#pb-edge-clear-base-mt")
    end

    test "and clearing one edge leaves the others alone", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-edge-form-base-pl") |> render_change(%{"value" => "2rem"})

      view |> element("#pb-edge-clear-base-mt") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"pl" => "2rem"}}
    end

    # Emptying the text is still a clear, for anyone who reaches for the keyboard first.
    test "and emptying the field clears it too", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => ""})

      assert styles_of(view, node.id) == %{}
    end

    test "and it reaches the published page", %{view: view, page: page} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "mt-[40px]"
    end

    # An edge is per-breakpoint like every other override, which is the whole point of putting it in
    # the panel rather than in the CSS box: `mt-10` on desktop and `mt-4` on mobile is one element.
    test "an edge belongs to the breakpoint it was set on", %{view: view, node: node} do
      view |> element("#pb-edge-form-base-mt") |> render_change(%{"value" => "40px"})
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-edge-form-mobile-mt") |> render_change(%{"value" => "12px"})

      assert styles_of(view, node.id) == %{base: %{"mt" => "40px"}, mobile: %{"mt" => "12px"}}
    end

    # A VALUE THE AUTHOR SET IS NOT AN EXAMPLE. An empty field's placeholder is a made-up hint —
    # "any length, e.g. 2rem" — and a field inheriting from another bucket put the REAL value in the
    # same grey, so an author on Mobile read their own `1000px` as a suggestion and reported the
    # value as missing on reopen.
    test "an inherited value is marked as a value, not as a hint", %{view: view, node: node} do
      view |> element("#pb-style-form-base-width") |> render_change(%{"value" => "1000px"})

      # On base it is the author's own value, in the field itself.
      assert view
             |> element("#pb-style-base-width")
             |> render() =~ ~s(value="1000px")

      view |> element("#pb-bp-mobile") |> render_click()

      mobile = view |> element("#pb-style-mobile-width") |> render()

      assert mobile =~ ~s(placeholder="1000px"), "the inherited value is not offered at all"

      assert mobile =~ ~s(data-inherited="true"),
             "an inherited value is drawn the same as an invented example"

      refute mobile =~ ~s(value="1000px"), "it is not this bucket's own value"

      # And an untouched field still says what a value may look like, without claiming to have one.
      height = view |> element("#pb-style-mobile-height") |> render()
      assert height =~ "any length"
      refute height =~ ~s(data-inherited="true")

      assert styles_of(view, node.id) == %{base: %{"width" => "1000px"}}
    end

    test "the Typography group renders its own controls", %{view: view} do
      html = render(view)

      assert html =~ "Typography"
      assert has_element?(view, "#pb-style-form-base-font-size")
      assert has_element?(view, "#pb-style-form-base-line-height")
      assert has_element?(view, "#pb-style-form-base-letter-spacing")
      assert has_element?(view, "#pb-style-base-font-weight-font-bold")
      assert has_element?(view, "#pb-style-base-text-align-text-center")
      assert has_element?(view, "#pb-style-base-text-transform-uppercase")
    end

    # THE SIZE IS NOT A COLOUR, though Tailwind spells both `text-`. The panel writes the CSS
    # property itself for exactly this reason, and the two have to survive together.
    test "a size and a colour do not overwrite each other", %{view: view, node: node, page: page} do
      view |> element("#pb-style-form-base-font-size") |> render_change(%{"value" => "3rem"})
      view |> element("#pb-style-form-base-color") |> render_change(%{"value" => "#ff0000"})

      assert styles_of(view, node.id) == %{base: %{"font-size" => "3rem", "color" => "#ff0000"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "[font-size:3rem]"
      assert reloaded.template =~ "text-[#ff0000]"
    end

    # A PILL IS NOT A SELECT OF CLASS NAMES. `font-extrabold` and `normal-case` are Tailwind's
    # spelling, not anybody's idea of a choice, so each option carries its own words and is drawn in
    # the thing it names.
    test "an enumerated typographic value offers words, not Tailwind", %{view: view} do
      html = view |> element("#pb-style-base-font-weight-font-extrabold") |> render()

      assert html =~ "Black"
      refute html =~ ">font-extrabold<"

      assert view |> element("#pb-style-base-text-transform-normal-case") |> render() =~
               "As typed"
    end

    test "clicking a weight sets it, and clicking it again clears it", %{view: view, node: node} do
      view |> element("#pb-style-base-font-weight-font-bold") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"font-weight" => "font-bold"}}

      view |> element("#pb-style-base-font-weight-font-bold") |> render_click()

      # The whole bucket goes with the last override in it: an empty `:base` left behind would read
      # as an element that has been styled and reset rather than one nobody touched.
      assert styles_of(view, node.id) == %{}
    end

    test "and so does an alignment and a case", %{view: view, node: node} do
      view |> element("#pb-style-base-text-align-text-center") |> render_click()
      view |> element("#pb-style-base-text-transform-uppercase") |> render_click()

      assert styles_of(view, node.id) ==
               %{base: %{"text-align" => "text-center", "text-transform" => "uppercase"}}
    end

    # A BORDER COLOUR ON ITS OWN PAINTS NOTHING, which is how the panel read before: the control took
    # the colour, the element had no border, and nothing happened.
    test "a border has a width and a style beside its colour", %{view: view, node: node} do
      assert has_element?(view, "#pb-style-form-base-border-width")
      assert has_element?(view, "#pb-style-base-border-style-border-dashed")

      view |> element("#pb-style-form-base-border-width") |> render_change(%{"value" => "2px"})
      view |> element("#pb-style-base-border-style-border-dashed") |> render_click()

      assert styles_of(view, node.id) ==
               %{base: %{"border-width" => "2px", "border-style" => "border-dashed"}}
    end

    test "the column count appears on a grid and not on anything else", %{view: view} do
      refute has_element?(view, "#pb-style-cols-base-3")

      view |> element("#pb-style-pic-base-display-grid") |> render_click()

      assert has_element?(view, "#pb-style-cols-base-3")

      view |> element("#pb-style-pic-base-display-flex") |> render_click()

      refute has_element?(view, "#pb-style-cols-base-3")
    end

    test "and picking one writes Tailwind's own utility", %{view: view, node: node, page: page} do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      view |> element("#pb-style-cols-base-2") |> render_click()

      assert styles_of(view, node.id) == %{base: %{"display" => "grid", "grid-cols" => "2"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      # `grid-cols-[2]` would be `grid-template-columns: 2`, which is not a track list and lays out
      # nothing at all.
      assert reloaded.template =~ "grid-cols-2"
      refute reloaded.template =~ "grid-cols-[2]"
    end

    test "and a track list a count cannot express still goes in", %{view: view, node: node} do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      view |> element("#pb-style-form-base-grid-cols") |> render_change(%{"value" => "2fr 1fr"})

      assert styles_of(view, node.id) == %{base: %{"display" => "grid", "grid-cols" => "2fr 1fr"}}
    end

    # SIX CONTROLS, ONE PROPERTY. `box-shadow` is one string, and offering it as one text box only
    # helps somebody who already knew the answer. Which side it falls on is two numbers.
    test "the shadow editor offers the parts a shadow is made of", %{view: view} do
      for field <- ~w(x y blur spread color) do
        assert has_element?(view, "#pb-shadow-base-#{field}"), "no shadow #{field} control"
      end

      assert has_element?(view, "#pb-shadow-base-inset")
      assert has_element?(view, "#pb-shadow-preset-m")
    end

    test "a preset writes the whole shadow", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-l") |> render_click()

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert shadow =~ "24px"
    end

    # One part at a time, and the other five have to survive it — six ops would be six undo steps for
    # one decision, five of them shadows nobody chose.
    test "and changing one part leaves the others alone", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-l") |> render_click()
      %{base: %{"shadow" => before}} = styles_of(view, node.id)

      view |> element("#pb-shadow-form-base-y") |> render_change(%{"value" => "30px"})

      assert %{base: %{"shadow" => after_edit}} = styles_of(view, node.id)
      assert after_edit =~ "30px"
      assert after_edit =~ "rgba"
      refute after_edit == before
    end

    test "an element with no shadow starts from one worth seeing", %{view: view, node: node} do
      view |> element("#pb-shadow-form-base-y") |> render_change(%{"value" => "8px"})

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert shadow =~ "8px"
      # Not `8px 0 0 0 transparent`: a shadow with no blur and no colour is one you cannot see, so
      # the first nudge would look like a control that does nothing.
      assert shadow =~ "rgba"
    end

    test "and Inside turns it into an inner shadow and back", %{view: view, node: node} do
      view |> element("#pb-shadow-preset-m") |> render_click()
      view |> element("#pb-shadow-base-inset") |> render_click()

      assert %{base: %{"shadow" => shadow}} = styles_of(view, node.id)
      assert String.starts_with?(shadow, "inset ")

      view |> element("#pb-shadow-base-inset") |> render_click()

      assert %{base: %{"shadow" => plain}} = styles_of(view, node.id)
      refute plain =~ "inset"
    end

    test "and it reaches the page as a shadow utility", %{view: view, page: page} do
      view |> element("#pb-shadow-preset-s") |> render_click()
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "shadow-[0_1px_2px_0_rgba(15,23,42,0.08)]"
    end

    # A SWATCH ROW OF HARDCODED HEX IS A PALETTE WITH NOTHING TO DO WITH THE SITE. The five here are
    # the editor's own neutrals; the site's real colours were declared in its stylesheet, listed in
    # the Studio one panel away, and unreachable from the control that paints things — so a rebrand
    # meant repainting every element by hand.
    #
    # A token writes `var(--danger-light)`, which is the difference: the element resolves through the
    # same declaration every component on the site resolves through, and changing the token changes
    # them together.
    test "the site's own colours sit beside the editor's", %{conn: conn, page: page} do
      {:ok, _sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "swatch-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root {\n  --danger-light: #de1135;\n  --radius-lg: 12px;\n}\n",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      # FOLDED, BEHIND ITS COUNT. The installed kit theme declares 251 colours — every state of every
      # variant — and a row of them at the neutrals' size is a wall the Background control disappears
      # into. The five that are always open are the editor's own.
      refute has_element?(view, "#pb-token-base-background-danger-light")

      view |> element("#pb-section-site-colours") |> render_click()

      assert has_element?(view, "#pb-token-base-background-danger-light")

      # A length is not a colour. Offering `--radius-lg` as a background is a swatch that draws
      # nothing, which reads as a broken control rather than as an unsuitable token.
      refute has_element?(view, "#pb-token-base-background-radius-lg")

      view |> element("#pb-token-base-background-danger-light") |> render_click()

      assert styles_of(view, section.id) == %{base: %{"background" => "var(--danger-light)"}}
    end

    # AND THE ROW IS A CONVENIENCE, NOT A PRECONDITION. Reading the tokens means reading every
    # stylesheet the site can see and parsing them; done on the mount, a sheet that cannot be read
    # took the whole editor with it — trading something the author needs for something they would
    # merely like.
    test "an unreadable stylesheet costs the swatches, not the session", %{view: view} do
      assert has_element?(view, "#pb-swatch-violet")
      refute has_element?(view, "#pb-section-site-colours")
    end

    test "the Layout and Appearance groups render", %{view: view} do
      html = render(view)
      assert html =~ "Layout"
      assert html =~ "Appearance"
      assert html =~ "Gap"
      assert html =~ "Background"
    end

    test "a style edit lands in the base bucket and compiles to a class on save", %{
      conn: conn,
      page: page,
      view: view,
      node: node
    } do
      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "20px"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "20px"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "gap-[20px]"
      assert conn
    end

    # Firing `op` directly proves the HANDLER. This proves the CONTROL, which is a different claim:
    # the panel once offered breakpoint and state selectors that chose a bucket no widget ever wrote
    # to, and a handler-level test cannot see a hole like that.
    test "typing in a style field writes the override", %{view: view, node: node} do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}

      # No override marker at base: at Desktop/Normal the value IS the element's value, and the
      # prototype marks a field as overridden only against that baseline.
      refute has_element?(view, "#pb-style-clear-base-gap")

      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})
      assert has_element?(view, "#pb-style-clear-tablet-gap")
    end

    test "the override dot next to a set field clears just that bucket", %{
      view: view,
      node: node
    } do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})

      view |> element("#pb-style-clear-tablet-gap") |> render_click()

      # Only the tablet bucket goes; the base value it was overriding stays.
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}
    end

    # Every property the serialiser can express has to have a control, or the round trip is one-way:
    # a template with `max-w-[60ch]` on it parses into an override the panel cannot show or undo.
    # The claim is narrow and worth pinning: an editing field commits on its own debounce, so nobody
    # has to click away to make a change land. Structurally that means every field lives in a FORM
    # carrying `phx-change` and every input carries `phx-debounce` — a bare `phx-change` on an input
    # outside a form fires nothing at all, which is how these fields were dead once before.
    test "every editing field commits on debounce, with no blur required", %{
      view: view,
      node: node
    } do
      # The shape that makes a debounce commit work at all: the field is inside a form carrying the
      # change event, and the input debounces. A bare `phx-change` on an input outside a form fires
      # nothing — which is exactly how these fields were dead once before.
      assert has_element?(view, ~s(form[phx-change="op"] input[phx-debounce="350"]))

      # Nothing commits on blur any more; that is what forced the click-away.
      refute has_element?(view, "[phx-blur]")

      # And the behaviour itself, through the control rather than the handler: a change with no blur
      # of any kind reaches the tree.
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "27px"})

      assert view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.get(node.id)
             |> then(& &1.meta.styles) == %{base: %{"gap" => "27px"}}
    end

    test "every property the serialiser understands has a control", %{view: view} do
      # Direction, Spread, Align and Wrap are shown only on an element that IS a flex row, and the
      # column count only on one that is a grid — they do nothing to anything else, and an element
      # cannot be both. So the claim is that every property is REACHABLE, not that every property is
      # on screen at once: each is looked for on the display it belongs to.
      # And the axis pair is folded away under the spacing box on an element that sets neither, so it
      # is opened the way a reader opens it. Reachable, again, is the claim.
      view |> element("#pb-section-spacing-by-axis") |> render_click()

      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      as_flex = render(view)

      view |> element("#pb-style-pic-base-display-grid") |> render_click()
      as_grid = render(view)

      for prop <- Styles.properties() do
        assert control_for?(as_flex, prop) or control_for?(as_grid, prop),
               "no control for the #{prop} override"
      end

      # Background has the swatch row on top of its field, the way Gap has its presets.
      assert as_flex =~ "pb-swatch-"
    end

    # THE FIVE SHAPES A CONTROL COMES IN. A field in a form, the picture row an enumerated layout
    # property gets, the styled-label pills the typographic ones get, a cell in the spacing box, and
    # the shadow editor's own parts. What is pinned is that the property reaches the reader — not
    # which widget it arrived in, which is a design decision and moves.
    defp control_for?(html, prop) do
      String.contains?(html, "pb-style-form-base-#{prop}") or
        String.contains?(html, "pb-style-pics-base-#{prop}") or
        String.contains?(html, "pb-style-base-#{prop}-") or
        String.contains?(html, "pb-edge-form-base-#{prop}") or
        (prop == "shadow" and String.contains?(html, "pb-shadow-base-blur"))
    end

    # A SWATCH IS A PRESET, NOT THE ONLY WAY IN. The field below holds anything, and the swatch it
    # matches lights up — so a background typed by hand still reads as chosen when it is one of the
    # five, and reads as itself when it is not.
    test "the field and the swatches are one control", %{view: view, node: node} do
      view |> element("#pb-swatch-ink") |> render_click()
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="true"]))

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#dadada"})

      assert styles_of(view, node.id) == %{base: %{"background" => "#dadada"}}
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="false"]))
      assert view |> element("#pb-style-base-background") |> render() =~ "#dadada"

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#17161a"})
      assert has_element?(view, ~s(#pb-swatch-ink[aria-pressed="true"]))
    end

    # Every other preset row in the panel clears itself on a second press, and the one that did not
    # was the one whose value could not be reached any other way.
    test "pressing the chosen swatch clears it", %{view: view, node: node} do
      view |> element("#pb-swatch-violet") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"background" => "#4f4bcc"}}

      view |> element("#pb-swatch-violet") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    test "clearing a bucket drops everything written into it and nothing else", %{
      view: view,
      node: node
    } do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-bp-tablet") |> render_click()
      view |> element("#pb-style-form-tablet-gap") |> render_change(%{"value" => "10px"})
      view |> element("#pb-style-form-tablet-width") |> render_change(%{"value" => "100%"})

      view |> element("#pb-style-reset") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"gap" => "18px"}}
    end

    # A reset that would clear nothing reads as a broken button, so it is not drawn at all.
    test "an untouched bucket offers no reset", %{view: view} do
      refute has_element?(view, "#pb-style-reset")

      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      assert has_element?(view, "#pb-style-reset")
    end

    test "emptying a base field clears it", %{view: view, node: node} do
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => ""})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{}
    end

    # Display and its flex-only neighbours are pictures rather than a `<select>` of raw utilities:
    # the value still written is the bare Tailwind class, which is what makes the round trip work.
    test "picking a Layout picture writes the bare Tailwind utility", %{
      conn: conn,
      page: page,
      view: view,
      node: node
    } do
      view |> element("#pb-style-pic-base-display-grid") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"display" => "grid"}}

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "grid"
      assert conn
    end

    # §3 — the layout vocabulary as pictures. What is pinned is the behaviour a non-technical author
    # depends on, not the markup: one click sets, the same click again clears, and the controls that
    # cannot do anything are not offered.
    test "clicking the chosen picture again clears the override", %{view: view, node: node} do
      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"display" => "flex"}}

      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    test "the flex-only pictures appear only once the element is a row", %{view: view} do
      refute has_element?(view, "#pb-style-pics-base-direction")
      refute has_element?(view, "#pb-style-pics-base-justify")

      view |> element("#pb-style-pic-base-display-flex") |> render_click()

      assert has_element?(view, "#pb-style-pics-base-direction")
      assert has_element?(view, "#pb-style-pics-base-align")
      assert has_element?(view, "#pb-style-pics-base-wrap")

      # …and they go again with the row, rather than lingering as settings with no effect.
      view |> element("#pb-style-pic-base-display-block") |> render_click()
      refute has_element?(view, "#pb-style-pics-base-justify")
    end

    # A row that inherits its display from Desktop is still a row on Mobile. Reading only the open
    # bucket made these four vanish the moment the reader switched breakpoint.
    test "a narrower breakpoint still offers the flex pictures it inherits", %{view: view} do
      view |> element("#pb-style-pic-base-display-flex") |> render_click()
      view |> element("#pb-bp-mobile") |> render_click()

      assert has_element?(view, "#pb-style-pics-mobile-justify")
    end

    test "a gap preset writes the length it is named for", %{view: view, node: node} do
      view |> element("#pb-style-gap-base-L") |> render_click()
      assert styles_of(view, node.id) == %{base: %{"gap" => "16px"}}

      # The field and the presets are one override, so the field shows what the preset wrote…
      assert view |> element("#pb-style-base-gap") |> render() =~ ~s(value="16px")

      # …and pressing the lit preset takes it off.
      view |> element("#pb-style-gap-base-L") |> render_click()
      assert styles_of(view, node.id) == %{}
    end

    # §4 — the breakpoint is a tab, and the count on it is how a responsive override stays findable.
    test "each breakpoint tab counts what it sets, and only its own", %{view: view} do
      refute has_element?(view, "#pb-bp-count-base")

      view |> element("#pb-style-form-base-gap") |> render_change(%{"value" => "18px"})
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")
      refute has_element?(view, "#pb-bp-count-mobile")

      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-style-form-mobile-gap") |> render_change(%{"value" => "8px"})
      view |> element("#pb-style-pic-mobile-display-flex") |> render_click()

      assert view |> element("#pb-bp-count-mobile") |> render() =~ ~s(title="2 set here")
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")

      # A STATE SET AT A WIDTH BELONGS TO THAT WIDTH. It used to be counted nowhere — the badge
      # looked only at the plain breakpoint bucket — so a hover colour set on mobile was a change
      # with nothing on screen pointing at it, which is exactly how a responsive edit becomes
      # impossible to find again a week later.
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "4px"})

      assert view |> element("#pb-bp-count-mobile") |> render() =~ ~s(title="3 set here")
      assert view |> element("#pb-bp-count-base") |> render() =~ ~s(title="1 set here")
    end

    # THE CANVAS GOES WHERE THE PANEL GOES. Choosing Tablet says "I am working on tablet", and
    # leaving the frame at desktop width answers that with a page the override cannot be seen on:
    # the author sets a value, nothing moves, and the control reads as broken when it is the
    # viewport that is wrong.
    test "the breakpoint tab moves the canvas with it", %{view: view} do
      assert device(view) == :desktop

      view |> element("#pb-bp-mobile") |> render_click()
      assert device(view) == :mobile

      view |> element("#pb-bp-tablet") |> render_click()
      assert device(view) == :tablet

      view |> element("#pb-bp-base") |> render_click()
      assert device(view) == :desktop
    end

    # AND IT OPENS WHERE THE SESSION LEFT IT. The breakpoint survives a reload — that is what stops a
    # refresh throwing the panel's place away — but the frame did not, so an editor last used on
    # Mobile came back with the Mobile tab active over a desktop-width canvas. The first click on
    # Mobile then looked broken, because the tab it highlights was already the highlighted one.
    test "and the frame opens where the session left it", %{conn: conn, page: page, view: view} do
      view |> element("#pb-bp-mobile") |> render_click()

      assert device(view) == :mobile

      # A second mount, the way a refresh is: the session hands back the breakpoint it was left on,
      # and the frame has to come with it.
      {:ok, reopened, _html} = open_builder(conn, page)

      assert breakpoint(reopened) == :mobile, "the session did not keep the breakpoint"
      assert device(reopened) == :mobile
    end

    # AND THE OTHER WAY ROUND, which is the half that was missing. The device strip moved the frame
    # and left the breakpoint alone, so the canvas went to 390px while the Inspector kept writing the
    # `base` bucket — an author sizing something on a mobile canvas was setting it for every width.
    test "choosing a frame moves the breakpoint it shows", %{view: view} do
      render_click(view, "set_device", %{"device" => "mobile"})
      assert breakpoint(view) == :mobile

      render_click(view, "set_device", %{"device" => "tablet"})
      assert breakpoint(view) == :tablet

      render_click(view, "set_device", %{"device" => "desktop"})
      assert breakpoint(view) == :base, "the widest frame is what every width looks like"
    end

    # THE SYMPTOM AS REPORTED: the strip lit Mobile over a desktop canvas, so the first press on
    # Mobile did nothing visible — it was already the lit tab. Asserted on the two together, because
    # either one alone is only half the disagreement.
    test "so the lit tab and the canvas never disagree", %{view: view} do
      view |> element("#pb-bp-mobile") |> render_click()
      render_click(view, "set_device", %{"device" => "desktop"})

      assert {:desktop, :base} == {device(view), breakpoint(view)}

      html = render(view)
      assert html =~ ~s(id="pb-bp-base" phx-click="set_breakpoint" value="base" title)
      assert html =~ ~s(aria-pressed="true")

      refute view |> element("#pb-bp-mobile") |> render() =~ ~s(aria-pressed="true"),
             "Mobile stayed lit over a desktop canvas"
    end

    # And the round trip is stable, so neither control can drift the other off by one.
    test "and the two controls round-trip through each other", %{view: view} do
      for {frame, bp} <- [{"mobile", :mobile}, {"tablet", :tablet}, {"desktop", :base}] do
        render_click(view, "set_device", %{"device" => frame})
        assert breakpoint(view) == bp

        view |> element("#pb-bp-#{bp}") |> render_click()
        assert device(view) == String.to_existing_atom(frame)
      end
    end

    # LEAVING side by side is the one path where both controls move at once, and it is the one that
    # took longest to settle on screen — three frames come down and one goes up. Asserted here rather
    # than in the browser, where a probe can read between the two.
    test "and leaving the side-by-side view lands on the frame that was asked for", %{view: view} do
      view |> element("#pb-bp-mobile") |> render_click()
      render_click(view, "set_device", %{"device" => "frames"})

      assert {:frames, :mobile} == {device(view), breakpoint(view)},
             "every width is already on screen, so it moves nothing"

      render_click(view, "set_device", %{"device" => "desktop"})

      assert {:desktop, :base} == {device(view), breakpoint(view)}
    end

    # EXCEPT SIDE BY SIDE, where every width is already on screen and switching to one would take
    # away what the reader opened it for.
    test "but not when the frames view is showing every width at once", %{view: view} do
      render_click(view, "set_device", %{"device" => "frames"})

      view |> element("#pb-bp-mobile") |> render_click()

      assert device(view) == :frames
    end

    # THE BUG THIS MATRIX EXISTS FOR. A hover set while the panel says Mobile must not touch the
    # desktop, and the two must be able to disagree.
    test "a hover set on mobile is a mobile hover", %{view: view, node: node} do
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-hover-gap") |> render_change(%{"value" => "10px"})

      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      assert styles_of(view, node.id) == %{
               hover: %{"gap" => "10px"},
               mobile_hover: %{"gap" => "2px"}
             }
    end

    test "and it reaches the page as a query and a pseudo-class", %{view: view, page: page} do
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ "max-[560px]:hover:gap-[2px]"
    end

    # EVERY BUCKET CAN BE CLEARED, not just the plain ones. The button reads the bucket it is
    # clearing, so `mobile :hover` says so rather than offering to clear "mobile".
    test "each bucket offers its own reset, named after itself", %{view: view, node: node} do
      view |> element("#pb-bp-mobile") |> render_click()
      view |> element("#pb-state-hover") |> render_click()
      view |> element("#pb-style-form-mobile_hover-gap") |> render_change(%{"value" => "2px"})

      assert view |> element("#pb-style-reset") |> render() =~ "mobile :hover"

      view |> element("#pb-style-reset") |> render_click()

      assert styles_of(view, node.id) == %{}
    end

    test "a background swatch writes into the current bucket", %{view: view, node: node} do
      view |> element("#pb-swatch-ink") |> render_click()

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{base: %{"background" => "#17161a"}}
    end

    test "the Editing-at and State selectors each explain where an edit lands", %{view: view} do
      assert render(view) =~ "Recorded as the value for every size"

      render_click(view, "set_breakpoint", %{"value" => "tablet"})
      assert render(view) =~ "Recorded against 900px and below"

      render_click(view, "set_pseudo", %{"value" => "hover"})
      html = render(view)
      assert html =~ "Recorded against :hover"
      assert html =~ "Recorded"
    end

    # Each Behavior switch is a class the element either carries or does not, so it reports the
    # document rather than a flag kept beside it — save, reopen, and it is still on.
    test "a Behavior switch adds and removes its classes", %{view: view, node: node} do
      classes = fn ->
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> Node.attr_text("class")
      end

      view |> element("#pb-toggle-sticky") |> render_click()
      assert classes.() =~ "sticky"
      assert classes.() =~ "top-0"

      view |> element("#pb-toggle-shadow") |> render_click()
      assert classes.() =~ "shadow-lg"

      view |> element("#pb-toggle-sticky") |> render_click()
      refute classes.() =~ "sticky"
      # Turning one off leaves the other alone.
      assert classes.() =~ "shadow-lg"
    end

    # AND A SWITCH OVER A COMPUTED CLASS JOINS IT. The switch read the row as text and wrote all of
    # it back as one string, so on `class={[@variant, "lead"]}` it put the expression's own source
    # on the element as literal words: not Elixir, and a page that would no longer compile or save.
    test "a switch joins a computed class rather than writing over it", %{view: view, node: node} do
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => node.id,
        "name" => "class",
        "value" => ~S|[@variant, "lead"]|,
        "value_kind" => "expr"
      })

      view |> element("#pb-toggle-shadow") |> render_click()

      assert attr_of(view, node.id, "class") == {:expr, ~S|[@variant, "lead", "shadow-lg"]|}
      assert view |> element("#pb-toggle-shadow") |> render() =~ ~s(aria-checked="true")

      assert CodeCheck.template(Serializer.serialize(editor(view).tree)) == :ok

      view |> element("#pb-toggle-shadow") |> render_click()

      assert attr_of(view, node.id, "class") == {:expr, ~S|[@variant, "lead"]|}
    end

    test "a switch reads as on when the element already carries its classes", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section class="sticky top-0 z-10">x</section>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      view |> element("#pb-section-behavior") |> render_click()

      assert view |> element("#pb-toggle-sticky") |> render() =~ ~s(aria-checked="true")
      assert view |> element("#pb-toggle-shadow") |> render() =~ ~s(aria-checked="false")
    end

    test "the field written to follows the breakpoint selector", %{view: view, node: node} do
      render_click(view, "set_breakpoint", %{"value" => "mobile"})

      refute has_element?(view, "#pb-style-base-gap")
      view |> element("#pb-style-form-mobile-gap") |> render_change(%{"value" => "6px"})

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles) ==
               %{mobile: %{"gap" => "6px"}}
    end

    test "switching the breakpoint writes into that bucket instead", %{view: view, node: node} do
      render_click(view, "set_breakpoint", %{"value" => "mobile"})

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "mobile",
        "prop" => "py",
        "value" => "14px"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{mobile: %{"py" => "14px"}}
      # Per-field Reset only — the prototype has no group-level one.
      assert has_element?(view, "#pb-style-clear-mobile-py")
    end

    test "a state selector writes into the pseudo bucket", %{view: view, node: node} do
      render_click(view, "set_pseudo", %{"value" => "hover"})

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "hover",
        "prop" => "background",
        "value" => "#17161a"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{hover: %{"background" => "#17161a"}}
    end

    test "Reset clears only that bucket", %{view: view, node: node} do
      for {bucket, value} <- [{"base", "8px"}, {"mobile", "2px"}] do
        render_click(view, "op", %{
          "kind" => "set_style",
          "node_id" => node.id,
          "bucket" => bucket,
          "prop" => "gap",
          "value" => value
        })
      end

      render_click(view, "op", %{
        "kind" => "reset_styles",
        "node_id" => node.id,
        "bucket" => "mobile"
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{base: %{"gap" => "8px"}}
    end

    test "clearing a field removes just that property", %{view: view, node: node} do
      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => "8px"
      })

      render_click(view, "op", %{
        "kind" => "set_style",
        "node_id" => node.id,
        "bucket" => "base",
        "prop" => "gap",
        "value" => ""
      })

      styles =
        view |> editor() |> Map.fetch!(:tree) |> Tree.get(node.id) |> then(& &1.meta.styles)

      assert styles == %{}
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

  describe "the controls a node can actually take" do
    # `{@inner_content}` is the one node every layout has and the first thing anyone clicks. The
    # Inspector offered it breakpoints, states, spacing, typography and the whole Appearance section
    # — and the serializer emits an expression verbatim, with nowhere to put a class, so every one of
    # those controls recorded an override that was dropped on the way out.
    test "an expression is not offered styling that would be dropped", %{conn: conn, site: site} do
      layout =
        create_layout!(
          site_id: site.id,
          template: ~s(<main class="wrap">{@inner_content}</main>)
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/layout/#{layout.id}")

      render_click(view, "select", %{"id" => expression_node(view).id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, ~s([data-role="pb-bptabs"]))
      assert has_element?(view, "#pb-not-styleable")
      assert has_element?(view, "#pb-select-parent"), "and it says where the styling does belong"
    end

    test "nor is a run of text", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>words</p>))

      {:ok, view, _html} = open_builder(conn, page)

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      render_click(view, "select", %{"id" => text.id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      refute has_element?(view, "#pb-style-base-font-size")
      assert has_element?(view, "#pb-not-styleable")
      assert render(view) =~ "double-click it on the canvas"
    end

    # The element it sits in still gets everything, which is the half that proves the gate is about
    # the node rather than about the panel.
    test "the element around it still gets the whole surface", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>words</p>))

      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "select", %{"id" => node_with_tag(view, "p").id})
      view |> element("#pb-lefttab-inspector") |> render_click()

      assert has_element?(view, "#pb-style-base-font-size")
      refute has_element?(view, "#pb-not-styleable")
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

  describe "drag and drop" do
    test "a drop carrying a node id is a move", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})

      tree = view |> editor() |> Map.fetch!(:tree)
      assert Tree.get(tree, h1.id).parent_id == nil
      assert hd(tree.roots) == h1.id
    end

    test "a drop carrying a template is an insert", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert node_with_tag(view, "figure")
    end

    test "the drop index is honoured", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "1"
      })

      tags =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.children(section.id)
        |> Enum.map(& &1.tag)

      assert Enum.at(tags, 1) == "figure"
    end

    # The client resolves geometry; it does not get to decide legality. A payload naming an illegal
    # parent is refused as a CHILD here even though no browser would have produced it — and lands
    # beside the target instead, which is the half of the contract the drag hint promises.
    test "a tampered drop is refused as a child and relocated beside the target", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      html =
        render_click(view, "drop", %{
          "template" => "<section></section>",
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "text and inline"
      assert html =~ "Placed after"

      tree = view |> editor() |> Map.fetch!(:tree)
      inserted = Enum.find(Tree.walk(tree), &(&1.tag == "section" and &1.children == []))

      assert inserted.parent_id == h1.parent_id
      refute inserted.parent_id == h1.id

      siblings = Tree.child_ids(tree, h1.parent_id || :root)

      assert Enum.find_index(siblings, &(&1 == inserted.id)) ==
               Enum.find_index(siblings, &(&1 == h1.id)) + 1
    end

    test "a drop with nowhere legal to land is refused outright", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      # Beside the h1 is still inside the section being moved, so the retry fails too.
      html =
        render_click(view, "drop", %{
          "node_id" => section.id,
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "inside itself" or html =~ "text and inline"
      refute html =~ "Placed after"
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "dropping a node into its own descendant is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")

      html =
        render_click(view, "drop", %{
          "node_id" => section.id,
          "parent_id" => h1.id,
          "index" => "0"
        })

      assert html =~ "inside itself" or html =~ "text and inline"
      assert Tree.get(view |> editor() |> Map.fetch!(:tree), section.id).parent_id == nil
    end

    # WHAT THE RAIL OFFERS TO DROP INTO, AND HOW IT SAYS SO.
    #
    # This was a separate strip under every expanded COMPONENT — so every plain tag, the `<div>`,
    # `<main>` and `<footer>` a page is actually built out of, had no target in the tree at all, and
    # an empty `<div>` could not even be expanded to get one (`expandable?/1` is false for it on all
    # four counts). It was also permanent, standing on every expanded component whether or not
    # anything was being dragged.
    #
    # Revealing it per hover was the obvious repair and is the wrong shape: showing an in-flow box
    # only moves what is BELOW its own row, but hiding the previous one moves the row now UNDER the
    # pointer, and the strip was taller than a row. So the answer is written on the row, which
    # already has its size.
    test "a container row says so, on itself, only while it is the target", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<main><p>Words</p></main><div></div>))
      {:ok, view, _html} = open_builder(conn, page)

      for tag <- ["main", "div"] do
        row = view |> element(~s([data-layer-row="#{node_with_tag(view, tag).id}"])) |> render()

        assert row =~ ~s(data-role="pb-drop-inside"), "#{tag} can be dropped into"
        assert row =~ "drop inside"
        assert row =~ "hidden", "and says nothing until a drag makes it the target"
        assert row =~ "group-data-[drop=inside]:flex"
      end
    end

    test "a row that cannot hold children never offers to", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<p>Words</p><img src="/a.png" />))
      {:ok, view, _html} = open_builder(conn, page)

      text =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :text))

      for id <- [text.id, node_with_tag(view, "img").id] do
        row = view |> element(~s([data-layer-row="#{id}"])) |> render()

        refute row =~ ~s(data-role="pb-drop-inside")
        refute row =~ ~s(data-container="true")
      end
    end

    # The map of where this drag could land. `data-can` is written by the hook from the server's own
    # verdict; the row has to be able to DRAW it, and as an outline rather than a border or a tint
    # because both of those are already spoken for by the drop marker.
    test "a row can be drawn as somewhere this drag would go", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      row =
        view |> element(~s([data-layer-row="#{node_with_tag(view, "section").id}"])) |> render()

      assert row =~ "data-[can=true]:[outline:1px_dashed_#cfcdf0]"
      assert row =~ "data-[drop=inside]:bg-[#f2f1fc]"
      assert row =~ ~s(data-container="true")
    end

    # A SHUT BRANCH IS NOT IN THE DOCUMENT AT ALL, so a drag cannot reach into one — and
    # `default_expanded/1` opens the roots and one level below them and nothing else, so a tree of
    # any depth is mostly shut. A `<span>` inside a `<p>` inside a `<div>` had no row to aim at, and
    # the only way to reach it was to let go of what you were holding, click down to it, and pick it
    # up again. The hook springs a shut row open after a dwell; this is what tells it which rows are
    # worth waiting on.
    test "a row says whether it is shut over something", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section><div><p><span>Deep</span></p></div></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      # Open by default: `default_expanded/1` takes the roots and the branch children of the roots,
      # and stops. Two levels, however deep the document goes.
      for tag <- ["section", "div"] do
        assert view |> element(~s([data-layer-row="#{node_with_tag(view, tag).id}"])) |> render() =~
                 ~s(data-open="true")
      end

      # Shut, and worth waiting on — this is the row the drag has to open to get any further, and
      # the `<span>` under it is not in the document at all until it does.
      assert view |> element(~s([data-layer-row="#{node_with_tag(view, "p").id}"])) |> render() =~
               ~s(data-open="false")

      refute has_element?(view, ~s([data-layer-row="#{node_with_tag(view, "span").id}"]))
    end

    test "a row with nothing under it says nothing, so no drag waits on it", %{
      conn: conn,
      site: site
    } do
      page = create_page!(site_id: site.id, template: ~s(<section><hr /></section>))
      {:ok, view, _html} = open_builder(conn, page)

      row = view |> element(~s([data-layer-row="#{node_with_tag(view, "hr").id}"])) |> render()
      refute row =~ ~s(data-open=)
    end

    # The event the spring pushes is the chevron's own, which is what keeps one behaviour rather than
    # two: whatever a click opens, a dwell opens.
    test "the branch a drag opens is the branch a click opens", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section><div><p><span>Deep</span></p></div></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      paragraph = node_with_tag(view, "p")
      span = node_with_tag(view, "span")
      refute has_element?(view, ~s([data-layer-row="#{span.id}"]))

      render_click(view, "toggle_expand", %{"id" => paragraph.id})

      assert has_element?(view, ~s([data-layer-row="#{span.id}"]))

      assert view |> element(~s([data-layer-row="#{paragraph.id}"])) |> render() =~
               ~s(data-open="true")
    end

    # And it stays a window rather than becoming part of the document: no drag handle, no id a drop
    # could resolve to. Editing it here would rewrite the component under every other page silently.
    test "a component's own markup is not a drop target", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "windowed",
        template: ~s|<footer><div>a</div></footer>|,
        slots: []
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="windowed" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "markup:" <> node.id})

      rows = view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.map(& &1.id)

      # Every addressable row in the rail is a node of the PAGE's tree. The markup contributes none.
      for id <- rail_row_ids(view) do
        assert id in rows, "#{id} is drawn as a drop target but is not in the document"
      end
    end

    # `Inspector.addable_slots/1` leaves out `inner_block` — that is not a slot anybody adds, it is
    # whatever you write between the tags — so a component declaring only `inner_block` counted zero
    # and was told "this component takes no slots". That is the opposite of true, and it is the
    # commonest shape in the kit: the rail marks such a component a container and a drop into it
    # lands. The line said the one thing that would stop an author trying.
    test "a component whose only slot is inner_block is not told it takes none", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "holds-anything",
        template: ~s|<div>{render_slot(@inner_block)}</div>|,
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}]
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="holds-anything">hi</.component>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      html = render(view)
      refute html =~ "this component takes no slots"
      assert html =~ "goes straight inside"

      # And the rail really does accept a drop into it, which is what makes the old line a lie.
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~
               ~s(data-container="true")
    end

    test "a component that takes nothing inside still says so", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "holds-nothing",
        template: ~s|<hr class="r" />|,
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="holds-nothing" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert render(view) =~ "takes nothing inside"
    end

    # `+ :source` USED TO BREAK THE PAGE.
    #
    # The button wrote `<:source></:source>` and nothing else, but a slot declares attributes of its
    # own and eleven of the kit's slots declare REQUIRED ones. The component reads them directly —
    # `chelekom-video` does `src={source.src}` — so a bare slot is not an empty slot, it is a missing
    # key: "chelekom-video could not render — key :src not found", the instant the button was
    # pressed. The one control whose whole job is "add the thing this component asks for" was the one
    # that stopped the page rendering.
    test "adding a slot writes the attributes that slot cannot render without", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "mediaish",
        template: ~s|<video><source :for={s <- @source} src={s.src} type={s.type} /></video>|,
        slots: [
          %{
            "name" => "source",
            "opts" => %{},
            "attrs" => [
              %{"name" => "src", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "type", "type" => "string", "opts" => %{"required" => true}},
              %{"name" => "label", "type" => "string", "opts" => %{}}
            ]
          }
        ]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="mediaish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      ghost = view |> element("#pb-slot-add-#{node.id}-source") |> render()
      assert ghost =~ ~s(src=)
      assert ghost =~ ~s(type=)
      refute ghost =~ ~s(label=), "optional attributes are what the Inspector is for"

      # And pressing it leaves a slot the component can actually render.
      view |> element("#pb-slot-add-#{node.id}-source") |> render_click()

      slot =
        view |> editor() |> Map.fetch!(:tree) |> Tree.walk() |> Enum.find(&(&1.kind == :slot))

      assert slot, "the slot was inserted"

      written = Enum.map(slot.attrs, fn {name, _value} -> name end)
      assert "src" in written
      assert "type" in written
    end

    # A slot with nothing required stays as bare as it always was — there is nothing to seed.
    test "a slot that requires nothing is still added bare", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "looseish",
        template: ~s|<div><div :for={a <- @extra}>{render_slot(a)}</div></div>|,
        slots: [%{"name" => "extra", "opts" => %{}, "attrs" => []}]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="looseish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert view |> element("#pb-slot-add-#{node.id}-extra") |> render() =~
               ~s(phx-value-template="&lt;:extra&gt;&lt;/:extra&gt;")
    end

    # The kit declares defaults for some of them, and a default beats an empty every time: it is the
    # value the component was designed around.
    test "a required attribute with a declared default is seeded with it", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "defaultish",
        template: ~s|<div><span :for={i <- @item}>{i.kind}</span></div>|,
        slots: [
          %{
            "name" => "item",
            "opts" => %{},
            "attrs" => [
              %{
                "name" => "kind",
                "type" => "string",
                "opts" => %{"required" => true, "default" => "info"}
              }
            ]
          }
        ]
      )

      page =
        create_page!(site_id: site.id, template: ~s|<.component component_name="defaultish" />|)

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      expand!(view, node.id)
      render_click(view, "toggle_expand", %{"id" => "slots:" <> node.id})

      assert view |> element("#pb-slot-add-#{node.id}-item") |> render() =~ "info"
    end

    # The number the badge shows is the SUBTREE's, which is the whole point: a shut component says
    # something inside it is unfinished without being opened.
    test "the row counts everything unfinished under it, shut or open", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<div><.component component_name="needful" /></div>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      wrapper = node_with_tag(view, "div")
      row = view |> element(~s([data-layer-row="#{wrapper.id}"])) |> render()

      assert row =~ "needed", "the div itself needs nothing; the component inside it does"
      assert row =~ "2 needed", "one blank required property and one missing required slot"
    end

    # A count on a shut row is a riddle without it, and the two cases need different words: a row
    # whose own properties are fine and whose CHILD is unfinished must not claim the problem is here.
    test "the badge says what is behind its number, in the right number", %{
      conn: conn,
      site: site
    } do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<div><.component component_name="needful" src="/a.png" /></div>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      component = needful_node(view)
      wrapper = node_with_tag(view, "div")

      # Its own: one required slot, never added.
      assert view |> element(~s([data-layer-row="#{component.id}"])) |> render() =~
               "1 slot required here is still empty"

      # The wrapper's: nothing of its own, one thing underneath.
      assert view |> element(~s([data-layer-row="#{wrapper.id}"])) |> render() =~
               "1 required thing inside this is still empty"
    end

    test "and says nothing at all once everything is filled", %{conn: conn, site: site} do
      needy(site.id)

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s|<.component component_name="needful" src="/a.png"><:caption>hi</:caption></.component>|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      refute view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "needed"
    end

    # THE BADGE AND THE BUTTON READ THE SAME ANSWER. Two implementations of one rule drift, and a
    # badge that disagrees with the refusal beside it is worse than no badge.
    test "the badge counts exactly what publishing refuses", %{conn: conn, site: site} do
      needy(site.id)
      page = create_page!(site_id: site.id, template: ~s|<.component component_name="needful" />|)
      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "2 needed"

      html = render_click(view, "publish", %{})
      assert html =~ "needful.src"
      assert html =~ "needful.:caption"
    end

    # A kit this editor has never seen declares its requirements the same way, so nothing here is
    # keyed to a component name or an attribute name.
    test "a component nobody has heard of is marked the same way", %{conn: conn, site: site} do
      create_component!(
        site_id: site.id,
        name: "zzz-unknown-widget",
        template: ~s|<div data-x={@mandatory}></div>|,
        attrs: [%{"name" => "mandatory", "type" => "string", "opts" => %{"required" => true}}],
        slots: []
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s|<.component component_name="zzz-unknown-widget" />|
        )

      {:ok, view, _html} = open_builder(conn, page)

      node = needful_node(view)
      assert view |> element(~s([data-layer-row="#{node.id}"])) |> render() =~ "1 needed"
    end

    # THE END OF THE PAGE, which no row can stand for. A document with one root had exactly one place
    # to aim at in the rail and an EMPTY one had none at all — so the tray's whole gesture, dragging
    # a card into a page with nothing in it yet, could only be done on the canvas. It is the last
    # element in the rail, which is why it is allowed to appear and disappear when nothing else is.
    test "the rail offers the end of the page as a target", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, ~s([data-role='pb-root-drop'][data-parent-id='root']))

      tail = view |> element(~s([data-role='pb-root-drop'])) |> render()
      assert tail =~ "drop at the end of the page"
      assert tail =~ "data-[show=true]:flex"
      refute tail =~ ~s(data-show=)
    end

    # The same payload the rail's tail sends, taken at its word by the server: a template with no
    # `node_id` is an insert, and an index past the end appends.
    test "a template dropped at the end of the page becomes a new root", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      roots = length(view |> editor() |> Map.fetch!(:tree) |> Map.fetch!(:roots))

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => "root",
        "index" => "9999"
      })

      tree = view |> editor() |> Map.fetch!(:tree)
      assert length(tree.roots) == roots + 1
      assert Tree.get(tree, List.last(tree.roots)).tag == "figure"
    end

    test "a move is undoable like any other edit", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")

      render_click(view, "drop", %{"node_id" => h1.id, "parent_id" => "root", "index" => "0"})
      undo!(view)

      assert Tree.get(view |> editor() |> Map.fetch!(:tree), h1.id).parent_id != nil
    end

    # 183 components carrying their templates, attrs, slots and examples is 3.4 MB and 1.6 seconds.
    # Reading it during mount meant the editor drew nothing until it landed; it now arrives after,
    # and the panel says so rather than claiming there are no components.
    test "the palette loads after mount, showing a skeleton until it lands", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "late-arrival")

      {:ok, view, html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")

      # Before the async read returns: a skeleton, and NOT the "no components" answer — an empty
      # palette and one that has not arrived are different things to say.
      assert html =~ "pb-palette-skeleton"
      refute html =~ "No components match."

      loaded = render_async(view)

      refute loaded =~ "pb-palette-skeleton"
      assert loaded =~ "pb-comp-late-arrival"
      # It lands on the SESSION too, because the canvas binds components to a site from that list.
      assert view |> editor() |> Map.fetch!(:components) != []
    end

    test "palette cards advertise the same template click-to-place inserts", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "drag-me")
      {:ok, view, html} = open_builder(conn, page)

      assert html =~ ~s(data-template="&lt;.component component_name=&quot;drag-me&quot;)
      assert has_element?(view, "#pb-comp-drag-me[draggable]")
    end

    # The hint is what the drag paints its line from. It is asked for ONCE, at dragstart, and it has
    # to agree with the check that later admits the drop — which is why both come from the same
    # function. A hint that says yes where the drop says no is the bug this guards.
    test "dragstart answers with the whole tree's verdict for the thing being dragged", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      section = node_with_tag(view, "section")

      render_click(view, "drag_start", %{"template" => "<section></section>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: accepts})

      assert accepts[section.id] == true
      assert accepts[h1.id] == false
      assert map_size(accepts) == view |> editor() |> Map.fetch!(:tree) |> Tree.size()
    end

    # The hint is only worth having if the drop keeps its promise, so this asserts the promise on both
    # sides: where it says yes the node lands inside, where it says no the node lands beside instead.
    test "the drop keeps the promise the hint made", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "drag_start", %{"template" => "<figure></figure>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: accepts})

      tree = view |> editor() |> Map.fetch!(:tree)
      {yes, true} = Enum.find(accepts, fn {_id, allowed?} -> allowed? end)

      # A refused node whose PARENT accepts — so "beside it" is a place the retry can actually land.
      refused =
        Enum.find_value(accepts, fn
          {id, false} ->
            with %{} = node <- Tree.get(tree, id), true <- accepts[node.parent_id], do: node

          {_id, true} ->
            nil
        end)

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => yes,
        "index" => "0"
      })

      assert node_with_tag(view, "figure").parent_id == yes

      render_click(view, "drop", %{
        "template" => "<aside></aside>",
        "parent_id" => refused.id,
        "index" => "0"
      })

      assert node_with_tag(view, "aside").parent_id == refused.parent_id
    end

    test "a locked node accepts nothing, and a locked node being dragged is offered nowhere", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")

      {:ok, _locked} = EditorSession.toggle_lock(token(view), section.id)

      render_click(view, "drag_start", %{"template" => "<figure></figure>"})
      assert_push_event(view, "pb:drop-hints", %{accepts: locked_target})
      assert locked_target[section.id] == false

      render_click(view, "drag_start", %{"node_id" => section.id})
      assert_push_event(view, "pb:drop-hints", %{accepts: locked_source})
      assert Enum.all?(locked_source, fn {_id, allowed?} -> allowed? == false end)
      assert locked_source[h1.id] == false
    end

    # SELECTING FIRST IS ALREADY SAYING WHERE. Picking with something selected used to arm the palette
    # and wait for a click on the element the reader had just clicked; it places into it instead.
    test "picking with an element selected places into it at once", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "straight-in")
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick", %{"name" => "straight-in"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "straight-in"))

      assert placed, "one click on the palette should have been enough"
      assert placed.parent_id == section.id
      assert placed.id == List.last(Tree.get(editor(view).tree, section.id).children)

      # And nothing is left armed, so the next click on a row selects.
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # A BAND IS A SLICE OF THE PAGE, so it goes beside the other slices rather than into whatever was
    # selected. Every block in the library is one, which is why the whole library follows this rule
    # and a kit component, one test above, does not.
    test "picking a block with a section selected places it after that section", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      before = Tree.get(editor(view).tree, section.id).children
      block = hd(MishkaCmsCore.Runtime.PageBuilder.Blocks.all())
      render_click(view, "pick_block", %{"block" => block.id})

      tree = editor(view).tree
      assert Tree.get(tree, section.id).children == before, "the section was not opened up"

      placed = Tree.get(tree, List.last(tree.roots))
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # AND A BLOCK AN EXTENSION BROUGHT IS ONE OF THEM. The palette draws the merged library while the
    # click was resolved in the core one, so a contributed card answered "that element is no longer
    # on the page" — and dragging the identical card worked, which is what made it look like a
    # palette bug rather than a lookup that never asked the registry.
    test "and a block an extension contributed lands the same way", %{conn: conn, page: page} do
      register_plugin(BlockPlugin, "builder:blocks")

      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick_block", %{"block" => BlockPlugin.block().id})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert Serializer.serialize(tree) =~ "They loved it.", "the plugin's own template"
    end

    # AN ELEMENT RIDES THE SAME ROUTE AS A BLOCK — one armed slot, two libraries — so a `<section>`
    # arrives by exactly the mechanism a finished Hero does, and lands by the same rule.
    test "picking a structural element places an empty container beside it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-section"})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert placed.tag == "section"
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert placed.children == [], "a layout element is a hole to put things in"
      assert view |> editor() |> Map.fetch!(:picked) == nil
    end

    # THE REPORTED BUG. A call to action clicked while the page header was selected became a third
    # item in the header's flex row and rendered a quarter of the width.
    test "a band clicked into a header lands beside the header, not in it", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<header class="flex"><a href="/">Logo</a><nav></nav></header><main></main>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      header = node_with_tag(view, "header")
      before = Tree.get(editor(view).tree, header.id).children

      render_click(view, "select", %{"id" => header.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      tree = editor(view).tree
      assert Tree.get(tree, header.id).children == before, "the header was left alone"

      placed = Tree.get(tree, Enum.at(tree.roots, 1))
      assert placed.tag == "section"
      assert placed.parent_id == nil
    end

    # CLIMBING MORE THAN ONE LEVEL. Clicking the heading inside a hero has to pop the band out of the
    # heading AND out of the hero — and that landing place is one the selection ring does not explain
    # on its own, so it is the one case that says where it went.
    test "a band clicked deep inside a section climbs out of the whole branch", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      html = render_click(view, "pick_block", %{"block" => "cta-band"})

      tree = editor(view).tree
      placed = Tree.get(tree, List.last(tree.roots))

      assert placed.tag == "section"
      assert placed.parent_id == nil
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, section.id) + 1
      assert html =~ "Sections sit beside each other"
    end

    # THE CLIMB STOPS AT A WRAPPER THAT ALREADY HOLDS BANDS. A page wrapped in one div is an ordinary
    # shape, and lifting every new section out of it would put them somewhere the page does not live.
    test "a band is not lifted out of a wrapper that already holds bands", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="app"><section id="a"><p>One</p></section><section id="b"></section></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      wrapper = node_with_tag(view, "div")
      p = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => p.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      placed =
        editor(view).tree
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "section" and Node.attr(&1, "id") == nil))

      assert placed.parent_id == wrapper.id
    end

    # AN EMPTY BOX IS A HOLE TO PUT THINGS IN. It is the one container that cannot squeeze the band
    # into a narrow column, because there is nothing beside it — and it is the escape hatch that
    # keeps "make a section, then fill it" working.
    test "a band clicked into an empty section goes inside it", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section class="py-16"></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "select", %{"id" => section.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      assert Tree.get(editor(view).tree, section.id).children != []
    end

    # `<main>` is a band host by vocabulary, so a band clicked into one goes in rather than beside.
    test "a band clicked into main goes inside it", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<main><p>One</p></main>))

      {:ok, view, _html} = open_builder(conn, page)
      main = node_with_tag(view, "main")

      render_click(view, "select", %{"id" => main.id})
      render_click(view, "pick_block", %{"block" => "cta-band"})

      assert Tree.get(editor(view).tree, main.id).children |> length() == 2
    end

    # WHAT MUST NOT CHANGE. Only a band climbs. A paragraph, a heading or a kit component clicked
    # while a section is selected still goes straight inside it — the gesture this editor is built on.
    test "a leaf clicked into a section still goes inside it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-paragraph"})

      children = Tree.get(editor(view).tree, section.id).children
      assert Tree.get(editor(view).tree, List.last(children)).tag == "p"
    end

    # `header` AND `footer` ARE NOT BANDS BY TAG. The spec puts them inside `<article>` and
    # `<section>` as readily as at page level, and treating them as page slices made "give this
    # section its own header" impossible to do by clicking.
    test "a bare header element goes inside the section that was selected", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<section id="s"><p>One</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "el-header"})

      children = Tree.get(editor(view).tree, section.id).children
      assert Tree.get(editor(view).tree, List.last(children)).tag == "header"
    end

    # WHAT MAKES THE PAGE FOOTER DIFFERENT IS THE LIBRARY. `footer-columns` is rooted in a `<footer>`
    # exactly like the element above, and it still climbs — every entry in Blocks is a slice of the
    # page by construction.
    test "the footer block still lands beside, not inside", %{conn: conn, site: site} do
      page = create_page!(site_id: site.id, template: ~s(<section id="s"><p>One</p></section>))

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      before = Tree.get(editor(view).tree, section.id).children
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "pick_block", %{"block" => "footer-columns"})

      tree = editor(view).tree
      assert Tree.get(tree, section.id).children == before
      assert Tree.get(tree, List.last(tree.roots)).tag == "footer"
    end

    # THE RULE IS A CLICK-PATH POLICY. A drag names its parent with the pointer, and a deliberate one
    # must still be obeyed — every builder in the field keeps these two answers separate.
    test "a dragged band still lands exactly where it was dropped", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<header class="flex"><a>Logo</a></header>))

      {:ok, view, _html} = open_builder(conn, page)
      header = node_with_tag(view, "header")

      render_click(view, "drop", %{
        "template" => "<section></section>",
        "parent_id" => header.id,
        "index" => "0"
      })

      placed = Tree.get(editor(view).tree, hd(Tree.get(editor(view).tree, header.id).children))
      assert placed.tag == "section", "a pointer knows better than a policy"
    end

    test "the Blocks panel lists the elements alongside the sections", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      assert has_element?(view, "#pb-el-el-section")
      assert has_element?(view, "#pb-el-el-columns-3")
      assert has_element?(view, "#pb-el-el-h2")
      assert has_element?(view, "#pb-block-hero-centred"), "the sections are still there"
    end

    # The categories filter one library or the other, never a mix of both — choosing Layout should
    # not leave eight finished marketing sections underneath it.
    test "an element category hides the sections", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-lefttab-blocks") |> render_click()

      render_click(view, "block_cat", %{"cat" => "Layout"})

      assert has_element?(view, "#pb-el-el-section")
      refute has_element?(view, "#pb-block-hero-centred")
      refute has_element?(view, "#pb-el-el-h2"), "H2 is Text, not Layout"
    end

    # WITH NOTHING SELECTED IT STILL ARMS, because there is no answer yet — the canvas and the tree
    # are both waiting to give one.
    test "picking with no selection arms the palette instead", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "waits-for-a-click")
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "pick", %{"name" => "waits-for-a-click"})

      assert view |> editor() |> Map.fetch!(:picked) == "waits-for-a-click"

      refute view
             |> editor()
             |> Map.fetch!(:tree)
             |> Tree.walk()
             |> Enum.find(&(Node.component_name(&1) == "waits-for-a-click"))
    end

    # Click-to-place accepts a click on the TREE as well as on the canvas, and lands in the row that
    # was clicked — inside it when it can hold the component, immediately after it when it cannot.
    test "a picked component is placed by clicking a layer row", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "place-me")
      {:ok, view, _html} = open_builder(conn, page)

      section = node_with_tag(view, "section")
      render_click(view, "pick", %{"name" => "place-me"})
      render_click(view, "select", %{"id" => section.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "place-me"))

      assert placed.parent_id == section.id

      # The pick is spent, so the next click on a row selects again rather than placing a second one.
      assert view |> editor() |> Map.fetch!(:picked) == nil

      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      assert view |> editor() |> Map.fetch!(:selection) == h1.id
    end

    # A component row pushes `inspect` rather than `select`, so placing had to be taught there too —
    # otherwise the tree could place into a `<div>` but not into the component you meant.
    test "a picked component is placed by clicking a component row", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "demo-shell",
        slots: [%{"name" => "inner_block", "opts" => %{"required" => false}}],
        template: "<div>{render_slot(@inner_block)}</div>"
      )

      create_component!(site_id: nil, name: "goes-inside")

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="demo-shell" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      shell =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "pick", %{"name" => "goes-inside"})
      render_click(view, "inspect", %{"id" => shell.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(Node.component_name(&1) == "goes-inside"))

      assert placed.parent_id == shell.id

      # With nothing picked the same click still opens the Inspector on that component.
      render_click(view, "inspect", %{"id" => shell.id})
      assert view |> editor() |> Map.fetch!(:selection) == shell.id
      assert has_element?(view, "#pb-lefttab-inspector")
    end

    # A component that declares `id` as required raises the moment it renders without one. Generating
    # it where such nodes are created means that never has to be handled later — and it is written
    # into the template as an ordinary attribute, so it can be renamed. A node that declares no `id`
    # is left alone, plain HTML included: minting one for every `<figure>` would rewrite a document
    # nobody edited.
    test "a node that declares an id is given one", %{conn: conn, page: page, site: site} do
      create_component!(
        site_id: nil,
        name: "needs-id",
        attrs: [%{"name" => "id", "type" => "string", "opts" => %{"required" => true}}],
        template: "<div id={@id}>x</div>"
      )

      create_component!(site_id: site.id, name: "no-id-attr")
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      render_click(view, "drop", %{
        "template" => "<figure></figure>",
        "parent_id" => section.id,
        "index" => "0"
      })

      assert is_nil(Node.attr(node_with_tag(view, "figure"), "id"))

      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="needs-id" site="Global"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      declared = component_node(view, "needs-id")
      assert Node.attr_text(declared, "id") =~ ~r/\S/

      # A component that never declared `id` is not given one — an undeclared assign is noise.
      render_click(view, "drop", %{
        "template" => ~s(<.component component_name="no-id-attr" site="#{site.name}"/>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert is_nil(Node.attr(component_node(view, "no-id-attr"), "id"))

      # An empty one is no id either — a snippet shipping `id=""` is as broken as one shipping none,
      # so a DECLARING node fills it. This `<article>` declares nothing, and keeps what it was given.
      render_click(view, "drop", %{
        "template" => ~s(<article id=""></article>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert Node.attr_text(node_with_tag(view, "article"), "id") == ""

      # An expression is a VALUE — the author bound the id to their data, and it is left alone.
      render_click(view, "drop", %{
        "template" => ~s(<aside id={@row.id}></aside>),
        "parent_id" => section.id,
        "index" => "0"
      })

      assert {:expr, expr} = Node.attr(node_with_tag(view, "aside"), "id")
      assert expr =~ "@row.id"
    end

    # A raise inside the canvas takes the LiveView with it, and the reload costs the author every
    # unsaved edit. A required attribute that is empty is knowable before rendering, so it is checked
    # rather than caught — no `try` on a path that runs for every component on every diff.
    test "a component missing a required attribute renders a placeholder, not a crash", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: nil,
        name: "strict-card",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}],
        template: "<div>{@title}</div>"
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root"><.component component_name="strict-card" site="Global"/></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-incomplete="true"]))
      assert html =~ "strict-card"
      assert html =~ "needs title"

      # And it is still a node: selectable, so the missing field can be filled in the inspector.
      card = component_node(view, "strict-card")
      assert has_element?(canvas, ~s([data-node-id="#{card.id}"]))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => card.id,
        "name" => "title",
        "value" => "filled in"
      })

      refute has_element?(canvas, ~s([data-incomplete="true"]))
    end

    # THE OTHER HALF, AND THE HARDER ONE. A missing required attribute is knowable before rendering,
    # so it gets a check. Everything else a component might do — a bad value shape, an atom that does
    # not exist, an outright `raise` — is not, and it used to take the canvas LiveView with it:
    # crash, reload, and every unsaved edit in the session gone.
    #
    # It has to be a REAL compiled component. A database row whose module was never built takes the
    # runtime's "failed to render" branch and never runs at all, which is a different case and was
    # already handled — that is why this uses `MishkaCmsCore.Test.RaisingComponent`, whose one
    # attribute is declared, defaulted, and perfectly fine until it is given a value that names no
    # atom.
    test "a component that raises leaves the canvas standing", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div id="root">) <>
              ~s(<MishkaCmsCore.Test.RaisingComponent.boom tone="nope-not-an-atom" />) <>
              ~s(<p>after</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert has_element?(canvas, ~s([data-render-error="true"]))
      assert html =~ "could not render"

      # THE PAGE AROUND IT IS UNHARMED, which is the whole point — one bad component costs its own
      # box and nothing else.
      assert html =~ "after"
      assert Process.alive?(canvas.pid)

      # And it is still a node: selectable, so it can be inspected and deleted.
      node =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert has_element?(canvas, ~s([data-node-id="#{node.id}"]))

      render_click(view, "op", %{"kind" => "delete", "node_id" => node.id})

      assert Process.alive?(canvas.pid)
      refute has_element?(canvas, ~s([data-render-error="true"]))
    end

    # THE BOUND `contain/2` CANNOT GIVE. It covers every way a render can LEAVE; it cannot cover one
    # that does not leave, and a render allocating without limit takes the whole node rather than one
    # iframe. A heap ceiling is the only bound available without a second process, and a second
    # process is not available here — the sandbox does not cross one.
    test "the canvas runs under a heap ceiling, so a runaway render cannot take the node", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      {:max_heap_size, limit} = Process.info(canvas.pid, :max_heap_size)

      assert limit.size > 0, "an unbounded canvas is one component away from an unbounded node"
      assert limit.kill, "a ceiling that only logs is not a ceiling"

      # And it is nowhere near what an honest canvas uses, or it would be a new way to lose work.
      {:total_heap_size, used} = Process.info(canvas.pid, :total_heap_size)
      assert used < div(limit.size, 10)
    end

    # A `rescue` catches an exception and NOTHING ELSE. A component that throws, or that calls a
    # GenServer which is not running — an `exit`, and the likeliest of the three in a component that
    # talks to anything — went straight past the guard above and killed the canvas, which is the very
    # outcome that guard exists to prevent.
    for {function, leaving} <- [{"tossed", "throws"}, {"departed", "exits"}] do
      test "a component that #{leaving} leaves the canvas standing too", %{
        conn: conn,
        site: site
      } do
        page =
          create_page!(
            site_id: site.id,
            template:
              ~s(<div id="root">) <>
                ~s(<MishkaCmsCore.Test.RaisingComponent.#{unquote(function)} />) <>
                ~s(<p>after</p></div>)
          )

        {:ok, view, _html} = open_builder(conn, page)
        {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

        assert has_element?(canvas, ~s([data-render-error="true"]))
        assert html =~ "after", "the page around it is unharmed"
        assert Process.alive?(canvas.pid)
        assert Process.alive?(view.pid)
      end
    end

    test "layer rows are addressable as sortable items", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")

      assert has_element?(view, "#pb-layers[phx-hook='PbLayers']")
      assert has_element?(view, "[data-layer-id='#{section.id}']")
    end
  end

  # The three form blocks ship `phx-change` and `phx-submit` bound to handlers, and only a Page has
  # an `events` column to hold one.
  describe "the blocks a section can use" do
    test "a page is offered the form blocks", %{conn: _conn} do
      ids = Enum.map(Blocks.for_section("page"), & &1.id)

      assert "form-contact" in ids
      assert "form-newsletter" in ids
    end

    test "and a layout, a component and an error page are not" do
      for section <- ~w(layout component error-page) do
        ids = Enum.map(Blocks.for_section(section), & &1.id)

        refute "form-contact" in ids, section
        refute "form-fieldset" in ids, section
        refute "form-newsletter" in ids, section

        assert "hero-split" in ids or ids != [],
               "everything else still belongs everywhere"
      end
    end

    # The same rule the elements already follow, so the exception has to be declared rather than
    # inferred from a category name.
    test "a block that declares no sections belongs everywhere" do
      everywhere = Enum.reject(Blocks.all(), &Map.has_key?(&1, :sections))

      for section <- ~w(page layout component error-page) do
        ids = Enum.map(Blocks.for_section(section), & &1.id)
        assert Enum.all?(everywhere, &(&1.id in ids)), section
      end
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

    # CSS FOR ONE ELEMENT — the thing the panel above it cannot offer, because a panel can only
    # offer what somebody thought to add to it. Every builder in the field answers this with a
    # per-element CSS box; this one keys the rule on a class minted into the markup, so it survives
    # a save and travels with the node.
    test "an element can be given its own CSS", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "padding: 20px;\n\n&:hover { opacity: .8; }"
      })

      tree = editor(view).tree
      scope = Tree.scope(tree, section.id)

      assert scope =~ ~r/^pb-[a-f0-9]{8}$/, "the element was named"
      assert Serializer.serialize(tree) =~ scope, "and the name is in the markup"

      css = :sys.get_state(view.pid).socket.assigns.element_css_rules[scope]
      assert css =~ "padding: 20px;"
      assert css =~ "&:hover"
    end

    # A COMPONENT IS ONE NODE AND MANY ELEMENTS, and the rule is keyed on a class written into the
    # node — which reaches the DOM only if the component declares `class`. Offering the box anyway
    # took CSS that could never match anything, which is how this was found in the browser.
    test "a component that takes no class says so instead of taking CSS", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      html = render(view)
      assert html =~ "pb-css-unreachable"
      refute has_element?(view, "#pb-css-text")
    end

    # A DEAD END WITH A DOOR IN IT. Telling the reader to "put it inside a container" and leaving
    # them to work out how is the same as telling them no — the wrapper is an op the editor already
    # has, so it is offered rather than described.
    test "a component that takes no class is offered the wrapper that would work", %{
      conn: conn,
      site: site
    } do
      create_component!(site_id: site.id, name: "classless", template: "<b>x</b>")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="classless" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      assert has_element?(view, "#pb-css-wrap")
      render_click(view, "op", %{"kind" => "wrap", "node_id" => component.id, "tag" => "div"})

      wrapped = Tree.get(editor(view).tree, component.id)
      parent = Tree.get(editor(view).tree, wrapped.parent_id)

      assert parent.tag == "div"
      assert parent.id != component.id, "a new wrapper, not the one it was already in"

      render_click(view, "select", %{"id" => parent.id})
      assert has_element?(view, "#pb-css-text"), "and the wrapper can take CSS"
    end

    # `& > .badge` on a component aims a rule at markup the kit owns and the page does not. Not
    # refused — sometimes it is the only way — but said out loud, and named with the kit and version
    # so the reader knows what they are betting on.
    test "a rule reaching into a component's own markup says whose markup it is", %{
      conn: conn,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "badged",
        template: ~s(<div class={@class}><span class="badge">1</span></div>),
        attrs: [%{"name" => "class", "type" => "string", "opts" => %{}}],
        extra: %{"ui_kit" => "chelekom", "ui_kit_version" => "0.0.9"}
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div><.component component_name="badged" site="#{site.name}" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      component = node_with_kind(view, :component)
      render_click(view, "select", %{"id" => component.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => component.id,
        "css" => "padding: 2px;\n&:hover { opacity: .9; }"
      })

      refute has_element?(view, "#pb-css-reaching"), "its own element and its own hover are fine"

      render_click(view, "save_element_css", %{
        "node_id" => component.id,
        "css" => "& > .badge { color: red; }"
      })

      # NOT the html `render_click` returned. Applying CSS announces the tree through the session, and
      # that message reaches this LiveView after the click handler has already replied — so the
      # snapshot the click hands back predates the panel that reads it.
      html = render(view)

      assert has_element?(view, "#pb-css-reaching")
      assert html =~ "chelekom 0.0.9", "named, so the reader knows what they are betting on"
      assert html =~ "&gt; .badge", "and which selector it was"
    end

    test "a plain tag's own markup belongs to the author, so nothing is said", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "& > .badge { color: red; }"
      })

      refute has_element?(view, "#pb-css-reaching")
    end

    test "the canvas is given the rule so it paints without a recompile", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 13px;"})

      html = render(canvas)
      assert html =~ "pb-canvas-element-css"
      assert html =~ "gap: 13px;"
    end

    test "clearing the box takes the name back off", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      assert Tree.scope(editor(view).tree, section.id)

      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => ""})

      refute Tree.scope(editor(view).tree, section.id),
             "nothing is left carrying a name for a rule that no longer exists"
    end

    # The one structural rule: the text is wrapped in `.pb-xxxxxxxx { … }`, and a `}` typed at the
    # top level closes that wrapper early and puts everything after it on the whole site.
    test "CSS that would escape the element is refused", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      html =
        render_click(view, "save_element_css", %{
          "node_id" => section.id,
          "css" => "gap: 1px; } body { display: none; "
        })

      assert html =~ "unmatched"
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules == %{}
    end

    # A RULE IS KEYED ON A CLASS IN THE MARKUP, so deleting the element takes the only reference to
    # it away — and the rule stayed in the row, compiled into the site's stylesheet and served to
    # every visitor, for as long as the page existed. `live_rules/2` was written and tested for this
    # and had no caller at all.
    test "saving drops the CSS of an element that is no longer there", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => heading.id})
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, heading.id)

      # The stage says Draft, so the rule is held until a publish writes the markup carrying its
      # class. That publish is the one that puts it in the row for the delete below to take out.
      render_click(view, "publish", %{})

      assert stored_element_css(view, page)[scope] =~ "gap: 9px",
             "it was written in the first place"

      render_click(view, "op", %{"kind" => "delete", "node_id" => heading.id})
      render_click(view, "publish", %{})

      refute Map.has_key?(stored_element_css(view, page), scope), "the rule went with the element"
    end

    # THROUGH THE SAVE ITSELF. Paste styles used to carry the source's minted class onto the target,
    # which made the target answer with the source's name — and the prune then rewrote the row to
    # hold only the names the tree still answers with, so the author's CSS on the target went with
    # the paste. The unit tests for this ask `live_rules/2`; this one asks the row.
    test "styles pasted from one element leave the other's CSS alone", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      p = node_with_tag(view, "p")

      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "save_element_css", %{"node_id" => h1.id, "css" => "gap: 9px;"})
      render_click(view, "select", %{"id" => p.id})
      render_click(view, "save_element_css", %{"node_id" => p.id, "css" => "gap: 11px;"})

      source = Tree.scope(editor(view).tree, h1.id)
      target = Tree.scope(editor(view).tree, p.id)

      render_click(view, "ctx", %{"action" => "copy_styles", "node_id" => h1.id})
      render_click(view, "ctx", %{"action" => "paste_styles", "node_id" => p.id})

      assert Tree.scope(editor(view).tree, p.id) == target,
             "the target still answers to its own name"

      render_click(view, "publish", %{})

      stored = stored_element_css(view, page)
      assert stored[target] =~ "gap: 11px", "the target kept the CSS the author wrote on it"
      assert stored[source] =~ "gap: 9px", "and the source's is untouched"
    end

    # Pruning against the tree in the editor rather than the tree that was saved would drop the CSS
    # of an element the author is one ⌘Z away from bringing back.
    test "an element still in the saved page keeps its CSS", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "publish", %{})

      assert stored_element_css(view, page)[scope] =~ "gap: 9px"
    end

    # WRITTEN BY ONE SESSION, READ BY THE NEXT — and both name the row through `css_owner/1`, which
    # is `ElementScopes.owner/2`. A second spelling anywhere in the round trip is an author shown an
    # empty CSS box in front of rules the page is visibly wearing, and a next save that prunes them
    # as belonging to no element at all.
    test "and is shown them again the next time the document is opened", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 9px;"})

      scope = Tree.scope(editor(view).tree, section.id)
      render_click(view, "publish", %{})

      {:ok, reopened, _html} = open_builder(conn, page)
      rules = :sys.get_state(reopened.pid).socket.assigns.element_css_rules

      assert Map.has_key?(rules, scope),
             "the open read a different row than the save wrote"

      assert rules[scope] =~ "gap: 9px"
    end

    # A CONTROL THAT HAS BEEN OVERRULED SAYS SO. Custom CSS is emitted last and unlayered, so where
    # the two name one property the CSS wins and dragging the control moves nothing — which, unmarked,
    # reads as a control that is broken rather than one that has been overridden.
    test "a control whose property the element's own CSS also sets is marked", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      refute has_element?(view, "#pb-css-wins-padding")

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "padding: 20px;"
      })

      assert has_element?(view, "#pb-css-wins-padding"), "the control it beats outright"
      assert has_element?(view, "#pb-css-wins-pt"), "and the longhands the shorthand swallows"
      refute has_element?(view, "#pb-css-wins-gap"), "but nothing it does not set"
    end

    # A hover rule does NOT beat `hover:p-4` — that carries a pseudo-class and therefore more
    # specificity — so the mark belongs to the bucket wearing the same selector and to no other.
    test "the mark follows the bucket the declaration was written for", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "&:hover { opacity: .5; }"
      })

      refute has_element?(view, "#pb-css-wins-opacity"), "not while Normal is the open state"

      render_click(view, "set_pseudo", %{"value" => "hover"})
      assert has_element?(view, "#pb-css-wins-opacity")
    end

    test "a declaration a control could hold is offered, and one it could not is not", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "border-image: url(x);\ngap: 4px !important;\nalign-items: center;"
      })

      assert has_element?(view, "#pb-css-movable")
      assert has_element?(view, "#pb-css-move-2"), "align-items has a control"
      refute has_element?(view, "#pb-css-move-0"), "border-image has none"
      refute has_element?(view, "#pb-css-move-1"), "and !important could not survive the move"
    end

    # THE ROW HAS TO NAME ITS LINE, or "Move to controls" is a button that moves something unnamed.
    # `phx-no-curly-interpolation` on the `<code>` printed the interpolation itself, and the author
    # read the template's own source where their declaration should have been.
    test "the movable row shows the declaration, not the interpolation", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "background-color: #dadada;"
      })

      row = view |> element("#pb-css-movable") |> render()

      assert row =~ "background-color: #dadada"
      refute row =~ "declaration.text"

      assert has_element?(view, "#pb-css-wins-background"),
             "and the control it overrules says so — once, or LiveViewTest raises on the id"
    end

    # `main { … }` parses, saves and matches nothing, so the box has no reason to refuse it and the
    # page simply does not change. The advice is the only thing that names the mistake, and it was
    # reaching the code drawer alone — `inspector/1` received it and passed it no further.
    test "advice about a selector that misses is shown in the box it was typed in", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "color: red;"
      })

      refute has_element?(view, "#pb-css-advice"), "a declaration on its own aims at the element"

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "main { color: red }"
      })

      advice = view |> element("#pb-css-advice") |> render()

      assert advice =~ "INSIDE this element"
      assert advice =~ "start the selector with"
    end

    # A BODY THAT WILL NOT PARSE HAS NO AIM TO COMMENT ON. The error and the advice share the slot
    # under the box, so the one the author has to fix first is the one that gets it.
    test "a refused body shows the error there instead of advice", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "main { color: red"
      })

      assert has_element?(view, "#pb-css-error")
      refute has_element?(view, "#pb-css-advice")
    end

    # ONE LINE, MOVED: written as the override the control holds, and taken out of the text. The two
    # never competed for storage, so nothing has to be merged — and what is left is a page that looks
    # exactly the same with one fewer place to change it.
    test "moving a declaration sets the control and takes the line out", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "align-items: center;\nborder-image: url(x);"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert Tree.get(editor(view).tree, section.id).meta.styles[:base]["align"] == "items-center"

      scope = Tree.scope(editor(view).tree, section.id)
      css = :sys.get_state(view.pid).socket.assigns.element_css_rules[scope]

      refute css =~ "align-items"
      assert css =~ "border-image", "the line it could not take is left where it was"
      refute has_element?(view, "#pb-css-wins-align"), "and the mark goes with it"

      # …and the control it landed in is on screen, on a `<section>` that is not a flex row. It was
      # not: the four flex rows were drawn only for a row, so this override had nowhere to be read
      # or undone.
      assert has_element?(view, "#pb-style-pics-base-align")

      view |> element("#pb-style-pic-base-align-items-center") |> render_click()
      assert styles_of(view, section.id) == %{}
    end

    # THE LINE THAT STARTED THIS. `#dadada` is none of the five swatches, so the swatch row showed
    # nothing selected, no field held the value, and the only way to take it off again was to clear
    # the whole bucket — a control that cannot represent what was moved into it.
    test "a moved background can be seen, changed and cleared", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "background-color: #dadada;"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert styles_of(view, section.id) == %{base: %{"background" => "#dadada"}}
      assert view |> element("#pb-style-base-background") |> render() =~ "#dadada"

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => "#101010"})
      assert styles_of(view, section.id) == %{base: %{"background" => "#101010"}}

      view |> element("#pb-style-form-base-background") |> render_change(%{"value" => ""})
      assert styles_of(view, section.id) == %{}
    end

    # A DECLARATION NAMES ITS OWN BUCKET, and the panel was left wherever it happened to be. The
    # State section is folded by default and carries no count, so a `&:hover` line moved into the
    # hover bucket left the author looking at a panel that had not changed.
    test "moving a hover line puts the panel on the state that holds it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      render_click(view, "save_element_css", %{
        "node_id" => section.id,
        "css" => "&:hover { opacity: .5; }"
      })

      render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

      assert styles_of(view, section.id) == %{hover: %{"opacity" => ".5"}}
      assert has_element?(view, "#pb-state-recorded")
      assert view |> element("#pb-style-hover-opacity") |> render() =~ ~s(value=".5")
    end

    # THE AUDIT, RUN. Every line the panel offers to move has to land in a control the author can
    # then see — background landed in a swatch row with no swatch for it, and the four flex rows
    # landed on an element that drew none of them.
    test "every declaration a control can hold lands where the panel shows it", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "set_left_tab", %{"tab" => "inspector"})

      for prop <- Styles.properties() do
        {css_prop, css_value} = Styles.declaration(prop, sample_style(prop))

        # Every property meets the same plain `<section>`: one that has moved a `display: flex` a
        # moment ago is a different element, and the four flex rows would draw for that reason
        # rather than for the value they now hold.
        render_click(view, "op", %{
          "kind" => "reset_styles",
          "node_id" => section.id,
          "bucket" => "base"
        })

        render_click(view, "save_element_css", %{
          "node_id" => section.id,
          "css" => "#{css_prop}: #{css_value};"
        })

        assert has_element?(view, "#pb-css-move-0"),
               "#{css_prop} is not offered, though #{prop} is a control"

        render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "0"})

        # `render/1` and not the click's own return: the op is announced to the LiveView rather than
        # assigned inside the handler, so the reply is drawn from the tree as it was BEFORE the move
        # and every picture row would read as missing.
        html = render(view)

        assert control_for?(html, prop),
               "#{css_prop} moved into #{prop}, and nothing on screen holds it"
      end
    end

    test "a stale index moves nothing", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      render_click(view, "select", %{"id" => section.id})
      render_click(view, "save_element_css", %{"node_id" => section.id, "css" => "gap: 4px;"})

      html =
        render_click(view, "move_css_to_controls", %{"node_id" => section.id, "index" => "7"})

      assert html =~ "no longer there"
      scope = Tree.scope(editor(view).tree, section.id)
      assert :sys.get_state(view.pid).socket.assigns.element_css_rules[scope] =~ "gap: 4px"
    end

    test "the command palette opens and filters", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "toggle_command", %{})
      assert has_element?(view, "#pb-command-input")
      assert has_element?(view, "#pb-cmd-publish")

      # By the command's own id, not by its text: "Publish" is also the label on the top bar's
      # button, so a whole-page text match would pass whether the palette filtered or not.
      render_change(view, "command_query", %{"value" => "undo"})
      assert has_element?(view, "#pb-cmd-undo")
      refute has_element?(view, "#pb-cmd-publish")
    end

    # The prototype's palette is two groups, and "Go to" is the real admin menu rather than a list of
    # routes retyped here — so it can never offer a page the viewer would be refused.
    test "the palette offers Go-to targets from the real admin menu", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      html = render(view)
      assert html =~ "Actions"
      assert html =~ "Go to"
      assert has_element?(view, ~s(a[href="/admin/dashboard/runtime/pages"]))
    end

    test "a query filters both groups, and no match says so", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      render_change(view, "command_query", %{"value" => "stylesheet"})
      html = render(view)
      assert has_element?(view, ~s(a[href="/admin/dashboard/runtime/stylesheets"]))
      refute html =~ "Actions"

      render_change(view, "command_query", %{"value" => "zzzznothing"})
      assert render(view) =~ "No matches."
    end

    test "a command's hint and shortcut both render", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "toggle_command", %{})

      html = view |> element("#pb-cmd-save") |> render()
      assert html =~ "Write the draft"
      assert html =~ "⌘S"
    end

    # NOTHING SELECTED IS THE STATE THE BUILDER OPENS IN, and the palette offers "Delete selection"
    # in it — a plain button, no keyboard needed. It used to push a nil node id into the op funnel
    # and hand the author `Op.build/1`'s own complaint about the payload.
    test "a selection command with nothing selected answers in words", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)
      render_click(view, "toggle_command", %{})

      for id <- ~w(pb-cmd-delete pb-cmd-duplicate) do
        refute has_element?(clear_flashes(view), "#flash-info"), id
        view |> element("##{id}") |> render_click()

        assert flashes(view) =~ "Select an element on the page first.", id
        refute internals?(flashes(view)), id
        refute flashes(view) =~ "node_id", id
      end

      assert node_count(view) == before
    end

    test "the palette's delete removes the element that is selected", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "toggle_command", %{})

      view |> element("#pb-cmd-delete") |> render_click()
      refute node_with_tag(view, "h1")
    end

    # THE OTHER HALF OF THE SAME LEAK, and the one an author reaches by holding two elements and
    # clicking the bar above the page: the reason is a bare atom, which used to be printed as one.
    test "wrapping elements that are not side by side says so", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<header><h1>Title</h1></header><footer><a href="/x">Link</a></footer>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
      render_click(view, "mark", %{"id" => node_with_tag(view, "a").id})

      view |> element("#pb-multi-wrap") |> render_click()

      refute internals?(flashes(view))
      assert flashes(view) =~ "side by side"
    end

    # THE WHOLE TABLE, SERVER-SIDE. The hook sends a name and nothing else — it knows nothing about
    # the selection or the clipboard — so every name it can send has to be answered in the author's
    # words: never an inspected struct, and never an internal field the author has no word for.
    #
    # The names are `PB_SHORTCUTS`' own (assets/js/admin_hooks.js), which is the whole list the two
    # key handlers and the preview bar can push. `code` and `preview` are toggles, so each is
    # pressed twice and the view ends where it started.
    test "every shortcut the hook can send is answered without internals", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      before = node_count(view)

      keys = ~w(undo redo save copy cut paste duplicate delete fit code code preview preview)

      for key <- keys ++ ["nosuchkey"] do
        clear_flashes(view)
        render_click(view, "shortcut", %{"key" => key})
        refute internals?(flashes(view)), key
        refute flashes(view) =~ "node_id", key
      end

      # None of them edits the page when nothing is selected and the clipboard is empty.
      assert node_count(view) == before

      render_click(view, "shortcut", %{"key" => "command"})
      assert has_element?(view, "#pb-command-input")

      render_click(view, "shortcut", %{"key" => "escape"})
      refute has_element?(view, "#pb-command-input")
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

    # The frame matching the breakpoint being edited is ringed and names the selection, so the row
    # doubles as a reminder of where an override would land.
    test "the frame for the breakpoint being edited is marked", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      render_click(view, "set_device", %{"device" => "frames"})

      html = view |> element("#pb-framerow") |> render()
      assert html =~ "border-[#8481de]"
      assert html =~ "&lt;h1&gt;"

      render_click(view, "set_breakpoint", %{"value" => "mobile"})
      assert view |> element("#pb-framerow") |> render() =~ "border-[#8481de]"
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

    test "the mobile bar swaps the body for the panel it names", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      # Nothing is duplicated: the same panels are re-pointed by the media query, so the layers panel
      # is the one that was already there.
      assert view |> element("#pb-right") |> render() =~ "max-[900px]:hidden"

      view |> element("#pb-mobtab-layers") |> render_click()

      assert view |> element("#pb-right") |> render() =~ "max-[900px]:flex"
      assert view |> element("#pb-left") |> render() =~ "max-[900px]:hidden"
      assert has_element?(view, "#pb-layers")

      view |> element("#pb-mobtab-canvas") |> render_click()
      assert view |> element("#pb-right") |> render() =~ "max-[900px]:hidden"
    end

    test "a mobile panel tab also selects that panel's tab", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-mobtab-inspector") |> render_click()

      assert has_element?(view, "#pb-lefttab-inspector.bg-white")
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

  describe "the palette" do
    setup %{site: site} do
      %{component: create_component!(site_id: site.id, name: "hero-card")}
    end

    test "lists the site's components and filters by search", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      assert has_element?(view, "#pb-comp-hero-card")

      render_change(view, "palette_query", %{"value" => "zzzz"})
      refute has_element?(view, "#pb-comp-hero-card")

      render_change(view, "palette_query", %{"value" => "hero"})
      assert has_element?(view, "#pb-comp-hero-card")
    end

    # Every admin table links the editor as `?site_id=…`, so this is how a master actually arrives.
    # It used to hand that site to `:master_read`, whose `TenantContext` validation refuses a non-nil
    # tenant on a multitenancy-bypass action — the read errored and the palette rendered empty.
    test "a master arriving with ?site_id= still gets the site's components", %{
      conn: conn,
      page: page,
      site: site
    } do
      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{site.id}")

      assert has_element?(view, "#pb-comp-hero-card")
    end

    test "?site_id= scopes the palette to that site plus the global components", %{
      conn: conn,
      page: page,
      site: site
    } do
      other = create_site!(name: "other", host: "other.test", active: true)
      create_component!(site_id: other.id, name: "foreign-card")
      create_component!(name: "global-card")

      {:ok, view, _html} =
        live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}?site_id=#{site.id}")

      assert has_element?(view, "#pb-comp-hero-card")
      assert has_element?(view, "#pb-comp-global-card")
      refute has_element?(view, "#pb-comp-foreign-card")
    end

    # A component names its own palette glyph in `extra.icon`. Nothing else may override that — it is
    # the authored answer, and the suggestion below exists only for rows that have none.
    test "a component's own extra.icon is the glyph the palette draws", %{conn: conn, page: page} do
      create_component!(name: "kit-thing", extra: %{"icon" => "gallery"})

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-thing")) == :gallery
    end

    test "an unknown icon name falls back rather than rendering nothing", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-odd", extra: %{"icon" => "not-an-icon"})

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-odd")) == :box
    end

    # 183 components will not all be annotated by hand, so the palette suggests from the name.
    test "a component with no icon gets one suggested from its name", %{conn: conn, page: page} do
      for name <-
            ~w(kit-password-field kit-mega-menu kit-heading-two kit-image-block kit-data-table) do
        create_component!(name: name)
      end

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-password-field")) == :lock
      assert Panels.entry_icon(entry(view, "kit-mega-menu")) == :nav
      assert Panels.entry_icon(entry(view, "kit-heading-two")) == :head
      assert Panels.entry_icon(entry(view, "kit-image-block")) == :img
      assert Panels.entry_icon(entry(view, "kit-data-table")) == :table
    end

    test "a name that suggests nothing falls back to the component's category", %{
      conn: conn,
      page: page
    } do
      create_component!(name: "kit-zzz", type: "media")

      {:ok, view, _html} = open_builder(conn, page)

      assert Panels.entry_icon(entry(view, "kit-zzz")) == :image
    end

    # Every card is the same box whatever its name is; one wrapping label must not make its row grow.
    test "every palette card is the same fixed height", %{conn: conn, page: page} do
      create_component!(name: "kit-x")
      create_component!(name: "kit-with-a-very-long-name-that-wraps-twice")

      {:ok, view, _html} = open_builder(conn, page)
      html = render(view)

      [short, long] =
        for name <- ~w(kit-x kit-with-a-very-long-name-that-wraps-twice) do
          [_before, after_id] = String.split(html, ~s(id="pb-comp-#{name}"), parts: 2)
          [tag, _rest] = String.split(after_id, ">", parts: 2)
          tag =~ "h-[86px]"
        end

      assert short
      assert long
      assert html =~ "line-clamp-2"
    end

    # The kit's own name is on every one of its components, so printing it on every card spends the
    # label on the one word that never varies and pushes the part that does off the card.
    test "a kit prefix is dropped from the card label but kept everywhere else", %{
      conn: conn,
      page: page
    } do
      for name <- ~w(acme-alert acme-toast acme-banner solo-widget) do
        create_component!(name: name)
      end

      {:ok, view, _html} = open_builder(conn, page)
      entries = editor(view) |> Map.fetch!(:components)
      prefixes = Panels.kit_prefixes(entries)

      assert Panels.short_label(entry(view, "acme-alert"), prefixes) == "Alert"
      assert Panels.short_label(entry(view, "acme-banner"), prefixes) == "Banner"

      # Used three times, "acme" is a kit; "solo" is used once and stays.
      assert Panels.short_label(entry(view, "solo-widget"), prefixes) == "Solo Widget"

      # The full name is still what the card is titled with and what it inserts.
      assert view |> element("#pb-comp-acme-alert") |> render() =~ "acme-alert"
    end

    test "picking a component arms placement, and placing inserts it", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-hero-card") |> render_click()
      assert render(view) =~ "Placing hero-card"

      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      inserted =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert inserted.tag == ".component"
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Node.component_name(inserted) == "hero-card"
      refute render(view) =~ "Placing hero-card"
    end

    # The click that places happens inside the CANVAS, which is a different LiveView — so an
    # arming flag kept in the chrome's own assigns left the browser selecting elements while the hint
    # said "click the canvas". This drives the two the way a person does.
    test "arming in the chrome and clicking IN THE CANVAS places the component", %{
      conn: conn,
      page: page
    } do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-hero-card") |> render_click()
      section = node_with_tag(view, "section")
      render_click(canvas, "select", %{"id" => section.id})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      assert placed
      # Inside the clicked container, as its last child — and the arming is spent.
      assert placed.parent_id == section.id
      refute render(view) =~ "Placing hero-card"
    end

    # Clicking a component that declares no slot is someone pointing at WHERE they want the new
    # element, not a request to nest it there. The browser answered that with a red
    # "does not declare a slot" toast and placed nothing.
    test "clicking an element that cannot hold children places after it", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-leaf", nil, "<hr/>")
      create_component!(name: "pb-leaf")

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><.component component_name="pb-leaf" site="Global" /></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      leaf =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(canvas, "select", %{"id" => leaf.id})

      tree = view |> editor() |> Map.fetch!(:tree)
      placed = tree |> Tree.walk() |> Enum.find(&(Node.component_name(&1) == "hero-card"))

      assert placed
      # A sibling of the leaf, not a child of it.
      assert placed.parent_id == leaf.parent_id
      assert Tree.index_of(tree, placed.id) == Tree.index_of(tree, leaf.id) + 1
    end

    test "a canvas click with nothing armed still selects", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      section = node_with_tag(view, "section")
      before = view |> editor() |> Map.fetch!(:tree) |> Tree.size()

      render_click(canvas, "select", %{"id" => section.id})

      assert view |> editor() |> Map.fetch!(:selection) == section.id
      assert view |> editor() |> Map.fetch!(:tree) |> Tree.size() == before
    end

    test "a click on no element places at the end of the document", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(canvas, "select", %{})

      tree = view |> editor() |> Map.fetch!(:tree)
      assert tree |> Tree.get(List.last(tree.roots)) |> Map.fetch!(:kind) == :component
    end

    # Dropping a global component onto a site's page has to render it. The palette used to bind every
    # card to the page's site, which for a global component named a module nobody ever built.
    test "placing a GLOBAL component from the palette renders it on the canvas", %{
      conn: conn,
      site: site
    } do
      define_component!("pb-drop-footer", nil, "<footer>dropped global footer</footer>")
      create_component!(name: "pb-drop-footer")

      page = create_page!(site_id: site.id, template: ~s(<div id="root"></div>))
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-pb-drop-footer") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "0"})

      assert editor_html(view) =~ ~s(site="Global")

      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      assert html =~ "dropped global footer"
      refute html =~ "failed to render"
    end

    # A component that declares a property as required will not render without it, so a page missing
    # one is already broken — publishing it just puts the breakage in front of visitors. A DRAFT is
    # allowed to be half-finished; that is what a draft is.
    test "a missing required property blocks the save and names itself", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "needs-title",
        attrs: [%{"name" => "title", "type" => "string", "opts" => %{"required" => true}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-needs-title") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      html = publish!(view)
      assert html =~ "Not saved"
      assert html =~ "needs-title.title"

      # Fill it and the save goes through.
      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "title",
        "value" => "Real title"
      })

      assert save!(view) =~ "saved"
    end

    # Blurring a field you only clicked into must not wipe the component's default.
    test "leaving an untouched property alone keeps the default", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(
        site_id: site.id,
        name: "defaulted",
        attrs: [%{"name" => "message", "type" => "string", "opts" => %{"default" => "Hello"}}]
      )

      {:ok, view, _html} = open_builder(conn, page)
      view |> element("#pb-comp-defaulted") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      # What a blur with nothing typed sends.
      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "message",
        "value" => ""
      })

      # The attribute is gone, so the component renders its own default again rather than an empty
      # string that overrides it.
      node = view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id)
      assert Node.attr_text(node, "message") == nil
    end

    test "editing a prop writes the attribute and clearing it removes it", %{
      conn: conn,
      page: page,
      site: site
    } do
      create_component!(site_id: site.id, name: "plain-box")
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-plain-box") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})

      placed =
        view
        |> editor()
        |> Map.fetch!(:tree)
        |> Tree.walk()
        |> Enum.find(&(&1.kind == :component))

      render_click(view, "op", %{
        "kind" => "set_attr",
        "node_id" => placed.id,
        "name" => "variant",
        "value" => "filled"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id) |> Node.attr("variant") ==
               {:string, "filled"}

      render_click(view, "op", %{
        "kind" => "delete_attr",
        "node_id" => placed.id,
        "name" => "variant"
      })

      assert view |> editor() |> Map.fetch!(:tree) |> Tree.get(placed.id) |> Node.attr("variant") ==
               nil
    end

    test "a placed component serializes in the form the compilers read", %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      view |> element("#pb-comp-hero-card") |> render_click()
      render_click(view, "place", %{"parent_id" => "root", "index" => "1"})
      publish!(view)

      {:ok, reloaded} =
        Ash.get(MishkaCmsCore.Runtime.Page, page.id, action: :master_get, authorize?: false)

      assert reloaded.template =~ ~s(component_name="hero-card")
      assert reloaded.template =~ "<.component"
    end
  end

  # A CSS BODY IS AUTHORED TEXT, AND THE CANVAS PUTS IT IN A `<style>` TAG. `</style>` ends that tag
  # wherever it appears, so the browser stops reading CSS and starts reading markup: the rest of the
  # body becomes elements in the canvas document. Every body the canvas styles with is authored —
  # an element's own box, a site's stylesheet row — so the sequence can arrive.
  describe "a CSS body that tries to close the style tag" do
    setup %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<div id="root"><p>hello</p></div>)
        )

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      %{view: view, conn: conn, node: node}
    end

    defp canvas_html(conn, view) do
      {:ok, _canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
      html
    end

    test "cannot close it", %{conn: conn, view: view, node: node} do
      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => ~s|color: red;\n/* </style><span id="escaped">out</span> */|
      })

      html = canvas_html(conn, view)

      refute html =~ ~s(</style><span id="escaped")
      assert html =~ "<\\/style"
    end

    test "and neither can a shouted one", %{conn: conn, view: view, node: node} do
      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => ~s|color: red;\n/* </STYLE><span id="shouted">out</span> */|
      })

      refute canvas_html(conn, view) =~ ~s(</STYLE><span id="shouted")
    end

    # The escape belongs at the boundary, not in storage: the same body is served as a real
    # stylesheet, where the sequence is unremarkable and has to survive untouched.
    test "while what is stored is exactly what was written", %{view: view, node: node} do
      body = ~s|color: red;\n/* </style> */|

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => body})

      stored = :sys.get_state(view.pid).socket.assigns.element_css_rules

      assert stored |> Map.values() |> Enum.join() =~ "</style>"
    end
  end

  # The advice was computed only when Apply was pressed, so a bad selector saved yesterday was silent
  # when the panel was opened on it today — the case where an author is most likely to be wondering
  # why their CSS does nothing.
  describe "advice about a stored body" do
    test "shows when the panel is opened on CSS that was already saved", %{
      conn: conn,
      site: site
    } do
      page =
        create_page!(site_id: site.id, template: ~s(<div id="root"><p>hello</p></div>))

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      render_click(view, "save_element_css", %{
        "node_id" => node.id,
        "css" => "main { color: red }"
      })

      render_click(view, "select", %{"id" => node.id})

      assert :sys.get_state(view.pid).socket.assigns.element_css_advice =~ "INSIDE this element"
    end

    test "and says nothing about a body that is only declarations", %{conn: conn, site: site} do
      page =
        create_page!(site_id: site.id, template: ~s(<div id="root"><p>hello</p></div>))

      {:ok, view, _html} = open_builder(conn, page)

      node =
        view
        |> then(&:sys.get_state(&1.pid).socket.assigns.editor.tree)
        |> Tree.walk()
        |> Enum.find(&(&1.tag == "p"))

      render_click(view, "save_element_css", %{"node_id" => node.id, "css" => "color: red;"})
      render_click(view, "select", %{"id" => node.id})

      assert :sys.get_state(view.pid).socket.assigns.element_css_advice == nil
    end
  end

  describe "hidden from visitors" do
    test "the right-click menu hides an element; the layers chip and the Inspector say so and show it",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})
      {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      refute has_element?(canvas, "#pb-eltb-visibility"), "the element toolbar has no second eye"

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => h1.id})

      assert Visibility.hidden?(node_with_tag(view, "h1"))
      assert has_element?(canvas, ~s([data-node-id="#{h1.id}"][data-pb-hidden]))

      view |> element("#pb-layer-hidden-#{h1.id}") |> render_click()
      refute Visibility.hidden?(node_with_tag(view, "h1"))
      refute has_element?(view, "#pb-layer-hidden-#{h1.id}")

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => h1.id})
      view |> element("#pb-lefttab-inspector") |> render_click()
      assert has_element?(view, "#pb-insp-hidden")

      view |> element("#pb-insp-show") |> render_click()

      refute Visibility.hidden?(node_with_tag(view, "h1"))
      refute has_element?(view, "#pb-insp-hidden")
      refute has_element?(canvas, "[data-pb-hidden]")
    end

    test "an element inside a hidden one points at it, and is not shown on its own",
         %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template: ~s(<section data-pb-hidden><h1>Contact Us</h1></section>)
        )

      {:ok, view, _html} = open_builder(conn, page)
      section = node_with_tag(view, "section")
      h1 = node_with_tag(view, "h1")
      render_click(view, "select", %{"id" => h1.id})

      assert has_element?(view, "#pb-layer-hidden-#{section.id}")
      refute has_element?(view, "#pb-layer-hidden-#{h1.id}"), "the chip marks the one hidden"

      view |> element("#pb-lefttab-inspector") |> render_click()
      assert has_element?(view, "#pb-insp-hidden")
      refute has_element?(view, "#pb-insp-show")

      render_click(view, "toggle_visibility", %{})
      assert flashes(view) =~ "It is hidden with the element around it."
      assert Visibility.hidden_by(editor(view).tree, h1.id).id == section.id

      view |> element("#pb-insp-select-hider") |> render_click()
      assert editor(view).selection == section.id
      assert has_element?(view, "#pb-insp-show")
    end

    test "the right-click menu, the keyboard and the palette each toggle it as one undoable step",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)
      p = node_with_tag(view, "p")

      render_click(view, "shortcut", %{"key" => "visibility"})
      assert flashes(view) =~ "Select an element on the page first."

      render_click(view, "ctx", %{"action" => "visibility", "node_id" => p.id})
      assert Visibility.hidden?(node_with_tag(view, "p"))
      assert %{label: "Hidden from visitors"} = hd(editor(view).past)

      render_click(view, "select", %{"id" => p.id})
      render_click(view, "shortcut", %{"key" => "visibility"})
      refute Visibility.hidden?(node_with_tag(view, "p"))
      assert %{label: "Shown to visitors"} = hd(editor(view).past)

      render_click(view, "shortcut", %{"key" => "command"})
      view |> element("#pb-cmd-toggle_visibility") |> render_click()
      assert Visibility.hidden?(node_with_tag(view, "p"))

      undo!(view)
      refute Visibility.hidden?(node_with_tag(view, "p"))
    end

    test "preview draws nothing of a hidden element, editing draws it dimmed",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "h1").id
      })

      {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

      assert html =~ "Contact Us"
      assert canvas |> element("#pb-canvas-chrome") |> render() =~ "[data-pb-hidden]"

      view |> element("#pb-preview") |> render_click()

      refute render(canvas) =~ "Contact Us"
      assert render(canvas) =~ "Reach out any time."
    end

    test "publishing keeps it in the page, leaves it out of what visitors get, and says so",
         %{conn: conn, page: page} do
      {:ok, view, _html} = open_builder(conn, page)

      render_click(view, "ctx", %{
        "action" => "visibility",
        "node_id" => node_with_tag(view, "h1").id
      })

      publish!(view)

      assert flashes(view) =~ "Page published. 1 hidden element was left out."

      stored =
        Ash.get!(MishkaCmsCore.Runtime.Page, page.id, authorize?: false, tenant: page.site_id)

      assert stored.template =~ "<h1 data-pb-hidden>Contact Us</h1>"

      html = LiveViewCompiler.render_template(stored.template, %{})
      refute html =~ "Contact Us"
      assert html =~ "Reach out any time."
    end
  end
end
