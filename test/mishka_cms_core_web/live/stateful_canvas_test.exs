# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.StatefulCanvasTest do
  @moduledoc """
  A live component on the builder's canvas: drawn as its own markup, cold, without taking the
  editor with it.

  ## The obstacle, and which side of it has to win

  `CanvasLive.contain/3` forces every node's render to iodata on purpose, so a component's raise,
  throw or exit lands inside a rescue the editor owns rather than costing an author their unsaved
  session. `Phoenix.LiveView.Engine` implements `Phoenix.HTML.Safe` for
  `%Phoenix.LiveView.Component{}` only to raise. The two are irreconcilable and `contain/3` is the
  one that must win, so the canvas renders through `LiveViewHelpers.static_component/1` — `mount/1`,
  then the compiler's `update_many/1`, then `render/1` as the ordinary arity-1 function it is.

  ## What the author gets, and what they are told

  Real markup, real size, real styling, and `@myself` nil — so `phx-target` renders away and nothing
  in the frame responds to a click. That is the honest picture rather than a lie that resets on
  reload, and the Inspector says so beside the selection instead of leaving the reader to conclude
  they built it wrong.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

  @counter """
  <div id={@id} {@rest} data-role="counter">
    <span data-role="label">{@label}</span>
    <span data-role="count">{@count}</span>
    <button type="button" phx-click="bump" phx-target={@myself}>more</button>
  </div>
  """

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    component =
      create_component!(
        name: "live-counter",
        site_id: site.id,
        stateful: true,
        template: @counter,
        attrs: [
          %{"name" => "label", "type" => "string", "opts" => %{"default" => "Clicks"}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ],
        helpers: [
          %{
            "name" => "mount",
            "args" => "socket",
            "code" => "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
          },
          %{
            "name" => "handle_event",
            "args" => ~s|"bump", _params, socket|,
            "code" =>
              "{:noreply, Phoenix.Component.assign(socket, :count, socket.assigns.count + 1)}"
          }
        ]
      )

    page =
      create_page!(
        site_id: site.id,
        template:
          ~s(<section id="hero"><.component component_name="live-counter" site="localhost" id="c1" label="Presses" /></section>)
      )

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok,
     conn: log_in(conn, admin("canvas-live@example.com")),
     site: site,
     page: page,
     component: component}
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

  defp admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open_builder(conn, page) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/page/#{page.id}")
    _settled = render_async(view)
    view
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token

  # THE INSPECTOR IS A TAB, and a selection made through the event leaves whichever one was showing.
  defp inspect_counter(view) do
    {:ok, editor} = EditorSession.fetch(token(view))

    node =
      editor.tree
      |> Tree.walk()
      |> Enum.find(&(Node.component_name(&1) == "live-counter"))

    render_click(view, "select", %{"id" => node.id})
    render_click(view, "set_left_tab", %{"tab" => "inspector"})
    node
  end

  defp canvas(conn, view) do
    {:ok, canvas, html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")
    {canvas, html}
  end

  # The heading is selected BEFORE preview, so a `toolbar` delete that got through has something to
  # delete and a `select` that got through has something to move away from.
  defp preview(conn, page) do
    view = open_builder(conn, page)
    {canvas, _html} = canvas(conn, view)
    {:ok, editor} = EditorSession.fetch(token(view))
    heading = editor.tree |> Tree.walk() |> Enum.find(&(&1.tag == "h1"))

    {:ok, _session} = EditorSession.select(token(view), heading.id)
    {:ok, _session} = EditorSession.set_preview(token(view), true)
    render(canvas)

    {view, canvas, heading}
  end

  defp document(view) do
    {:ok, editor} = EditorSession.fetch(token(view))
    Map.take(editor, [:tree, :selection, :marked, :revision])
  end

  describe "a live component in the frame" do
    test "draws its own markup rather than a placeholder or a crash", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      assert html =~ ~s(data-role="counter"), "the component's own markup is not in the frame"
      assert html =~ "Presses", "the attribute the page set did not reach it"
      assert html =~ ~s(data-role="count"), "the lifecycle's own assign did not reach render/1"

      refute html =~ "failed to render",
             "the canvas fell back to the placeholder for a live component"
    end

    # THE WHOLE REASON THE STATIC PATH EXISTS. `contain/3` forces iodata and a `%Component{}` raises
    # when asked for any, so before this the frame drew the editor's red refusal chip over a
    # component the author had done nothing wrong with.
    test "and the editor's containment is not triggered", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      refute html =~ "could not be drawn"
      refute html =~ "raised"
    end

    # COLD, AND SAYING SO. `@myself` is nil on the canvas, so the component's own `phx-target`
    # renders away — nothing in the frame answers a click, which is the truth rather than a
    # simulation that resets on reload.
    test "is drawn cold, with no target for its own events", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      assert html =~ ~s(phx-click="bump"), "the component's own button is drawn"
      refute html =~ "phx-target=", "a cid that does not exist was rendered into the frame"
    end

    # AND PREVIEW IS THE SAME PICTURE. Preview used to take the LIVE dispatch, on the reasoning that
    # a preview is the real page and the canvas is a LiveView that could host the real thing — but
    # `contain/3` forces iodata to draw anything inside the frame, and a `%Component{}` raises when
    # asked for any. So the one surface an author uses to check their work drew a red box over every
    # live component on the page, and so did the wizard and example previews, which are read while
    # CONFIGURING a kit component before there is a page to preview.
    test "and preview draws it too, rather than a red box", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {canvas, _html} = canvas(conn, view)

      {:ok, _session} =
        MishkaCmsCore.Runtime.PageBuilder.EditorSession.set_preview(token(view), true)

      html = render(canvas)

      assert html =~ ~s(data-preview="true"), "the canvas did not enter preview at all"
      assert html =~ ~s(data-role="counter"), "preview did not draw the component's own markup"
      assert html =~ "Presses", "the attribute the page set did not reach it in preview"

      refute html =~ "could not render", "preview raised on the component token"
      refute html =~ "cannot convert component", "the iodata forcing reached a live component"
      refute html =~ "needs an id", "the id the tag carries did not reach the dispatch"
    end

    test "the wrapper says which kind it is", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {_canvas, html} = canvas(conn, view)

      assert html =~ ~s(data-stateful="true")
    end

    # THE CUE THE CANVAS DRAWS. `data-stateful` was rendered and read by nothing, so a live list
    # looked like any other markup. The chip is drawn off `data-pb-live`, editing only.
    test "and the wrapper carries the live chip's label while editing", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      {canvas, _html} = canvas(conn, view)

      assert has_element?(canvas, ~s(div[data-node-id][data-pb-live="live-counter"]))

      # The attribute is only the label. The chip is these two rules, and nothing else draws it.
      chrome = canvas |> element("#pb-canvas-chrome") |> render()

      assert chrome =~ "[data-pb-live] { position: relative; }"

      assert chrome =~
               ~r/:is\(\[data-pb-live\]:hover, \[data-pb-live\]\[data-selected="true"\]\)::after \{\s+content: "Live [^"]*" attr\(data-pb-live\)/

      {:ok, _session} = EditorSession.set_preview(token(view), true)
      render(canvas)

      assert has_element?(canvas, ~s([data-role="counter"]))
      refute has_element?(canvas, "[data-pb-live]"), "preview drew the editor's live chip"

      refute has_element?(canvas, "#pb-canvas-chrome"),
             "preview kept the rules that draw the chip"
    end

    # ONE `::after` PER ELEMENT. The media well's sentence is keyed on the same wrapper by a rule that
    # outranks the chip's, so the two used to merge into one violet box saying neither thing.
    test "but not over a live component still waiting for its picture", %{conn: conn, site: site} do
      create_component!(
        name: "live-hero",
        site_id: site.id,
        stateful: true,
        template:
          ~s(<div id={@id} {@rest} data-role="hero"><img :if={@image} src={@image} /></div>),
        attrs: [
          %{"name" => "image", "type" => "string", "opts" => %{"default" => nil}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      blank =
        create_page!(
          site_id: site.id,
          template: ~s(<.component component_name="live-hero" site="localhost" id="h1" />)
        )

      {canvas, _html} = canvas(conn, open_builder(conn, blank))

      assert has_element?(
               canvas,
               ~s(div[data-node-id][data-stateful="true"][data-wants-media="image"])
             ),
             "the wrapper does not want a picture, so this proves nothing about the media well"

      refute has_element?(canvas, "[data-pb-live]")

      chosen =
        create_page!(
          site_id: site.id,
          template:
            ~s(<.component component_name="live-hero" site="localhost" id="h2" image="/hero.png" />)
        )

      {canvas, _html} = canvas(conn, open_builder(conn, chosen))

      refute has_element?(canvas, "[data-wants-media]")
      assert has_element?(canvas, ~s(div[data-node-id][data-pb-live="live-hero"]))
    end

    # AND THE EMPTY OVERLAY'S, the other `::after` a wrapper can carry.
    test "nor over a live overlay with nothing in it", %{conn: conn, site: site} do
      create_component!(
        name: "live-drawer",
        site_id: site.id,
        stateful: true,
        template: ~s(<div id={@id} {@rest} role="dialog" class="hidden">{@label}</div>),
        attrs: [
          %{"name" => "label", "type" => "string", "opts" => %{"default" => "Drawer"}},
          %{"name" => "rest", "type" => "global", "opts" => %{}}
        ]
      )

      page =
        create_page!(
          site_id: site.id,
          template: ~s(<.component component_name="live-drawer" site="localhost" id="d1" />)
        )

      {canvas, _html} = canvas(conn, open_builder(conn, page))

      assert has_element?(canvas, ~s(div[data-node-id][data-stateful="true"][data-pb-hollow])),
             "the wrapper is not an empty overlay, so this proves nothing about its label"

      refute has_element?(canvas, "[data-pb-live]")
    end

    # NOT ON A STAMPED ROOT. A parent that joins what is immediately inside it gets the component's
    # own root stamped with the node's markers, so `data-stateful` lands on the component's element —
    # and a `position` and a pseudo-element put there would land inside its layout.
    test "but a stamped root is not given it", %{conn: conn, site: site} do
      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<div class="[&>*]:rounded-none"><.component component_name="live-counter" site="localhost" id="c2" /></div>)
        )

      view = open_builder(conn, page)
      {canvas, _html} = canvas(conn, view)

      assert has_element?(canvas, ~s([data-role="counter"][data-node-id][data-stateful="true"])),
             "the component's root was not stamped, so this proves nothing about stamped roots"

      refute has_element?(canvas, "[data-pb-live]")
    end
  end

  # PREVIEW IS A PICTURE OF THE UNSAVED PAGE, NOT A RUNNING ONE. A live component is drawn cold
  # there as it is while editing, its own `phx-click` keeps no target, and so its click reaches the
  # canvas under the component's own event name. A kit button named like a canvas operation would
  # have edited the document with editing off.
  describe "Preview in the frame" do
    setup %{site: site} do
      create_component!(
        name: "live-remover",
        site_id: site.id,
        stateful: true,
        template: """
        <div id={@id} {@rest} data-role="remover">
          <button type="button" phx-click="toolbar" phx-value-action="delete" phx-target={@myself}>
            remove
          </button>
        </div>
        """,
        attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}]
      )

      page =
        create_page!(
          site_id: site.id,
          template:
            ~s(<section id="hero"><h1>Title</h1><.component component_name="live-remover" site="localhost" id="r1" /></section>)
        )

      %{previewed: page}
    end

    test "a live component's own click does not reach the document", %{
      conn: conn,
      previewed: page
    } do
      {view, canvas, _heading} = preview(conn, page)
      before = document(view)

      canvas |> element(~s([data-role="remover"] button)) |> render_click()

      assert document(view) == before
    end

    test "answers no editing event, whatever sends it", %{conn: conn, previewed: page} do
      {view, canvas, heading} = preview(conn, page)
      before = document(view)

      text =
        heading.children |> Enum.map(&Tree.get(before.tree, &1)) |> Enum.find(&(&1.kind == :text))

      # Selection-bound ones first: a `select` that got through would leave them nothing to act on.
      for {event, params} <- [
            {"toolbar", %{"action" => "duplicate"}},
            {"set_cols", %{"name" => "cols", "value" => "2"}},
            {"set_style_prop", %{"prop" => "display", "value" => "flex"}},
            {"set_text", %{"id" => text.id, "text" => "Rewritten"}},
            {"mark", %{"id" => text.id}},
            {"drop",
             %{"template" => "<figure></figure>", "parent_id" => heading.id, "index" => "0"}},
            {"starter_scratch", %{}},
            {"page_starter", %{"structure" => "single"}},
            {"select", %{"id" => text.id}},
            {"select", %{}}
          ] do
        render_click(canvas, event, params)

        assert document(view) == before, "#{event} changed the document in preview"
      end
    end

    test "still answers the way out, and says what it is", %{conn: conn, previewed: page} do
      {_view, canvas, _heading} = preview(conn, page)

      assert has_element?(canvas, "#pb-preview-bar-text", "your unsaved page")
      assert has_element?(canvas, "#pb-preview-bar-text", "Open in a new tab")

      canvas |> element("#pb-preview-bar-edit") |> render_click()

      assert_push_event(canvas, "pb:leave-preview", %{})
    end

    # A LAYOUT, AN ERROR PAGE AND A COMPONENT ARE NOT PAGES, and the new-tab entry the bar points to
    # exists only over a section that keeps drafts — a component keeps none. Emptied first, so the
    # well that stands in for the document is read under the same name.
    test "names the document it shows, and the new tab only where there is one", %{
      conn: conn,
      site: site,
      previewed: page,
      component: component
    } do
      layout =
        create_layout!(
          name: "shell",
          site_id: site.id,
          template: ~s(<div id="shell">{@inner_content}</div>)
        )

      error_page =
        create_error_page!(
          name: "missing",
          site_id: site.id,
          error_pages: [%{"status" => 404, "template" => ~s(<div id="gone">gone</div>)}]
        )

      for {address, noun, new_tab?} <- [
            {"page/#{page.id}", "page", true},
            {"layout/#{layout.id}", "layout", true},
            {"error-page/#{error_page.id}", "error page", true},
            {"component/#{component.id}", "component", false}
          ] do
        {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/builder/#{address}")
        _settled = render_async(view)
        {canvas, _html} = canvas(conn, view)

        {:ok, _session} = EditorSession.put_tree(token(view), Tree.new())
        {:ok, _session} = EditorSession.set_preview(token(view), true)
        render(canvas)

        assert has_element?(canvas, "#pb-preview-bar-text", "your unsaved #{noun} as it looks"),
               "#{address} is not called a #{noun}"

        assert has_element?(canvas, "#pb-canvas-empty-title", "This #{noun} is empty")

        assert has_element?(canvas, "#pb-preview-bar-text", "Open in a new tab") == new_tab?,
               "#{address} names the new tab: expected #{new_tab?}"
      end
    end
  end

  describe "the Inspector over a live component" do
    # IT USED TO SAY PREVIEW WAS WHERE IT RUNS, and Preview draws it cold like the canvas does.
    test "does not send the author to Preview to see it run", %{conn: conn, page: page} do
      view = open_builder(conn, page)
      inspect_counter(view)

      assert has_element?(view, ~s([data-role="pb-insp-cold"]))
      refute has_element?(view, ~s([data-role="pb-insp-cold"]), "Preview")
    end

    test "opens the component's own editor, carrying the way back to this page", %{
      conn: conn,
      page: page,
      component: component
    } do
      view = open_builder(conn, page)
      inspect_counter(view)

      back =
        URI.encode_query(%{"return_to" => "/admin/dashboard/runtime/builder/page/#{page.id}"})

      assert has_element?(
               view,
               ~s(#pb-insp-edit-component[href="/admin/dashboard/runtime/builder/component/#{component.id}?#{back}"])
             )

      assert has_element?(view, ~s(#pb-insp-edit-component[title*="changes every page using it"]))
    end
  end
end
