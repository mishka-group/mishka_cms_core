defmodule MishkaCmsCoreWeb.Test.EditorToolsTest do
  @moduledoc """
  The panels an author reaches for — the palettes, the pickers, the Studio and the bulk bar — asked
  of all four sections rather than of a page.

  The `MishkaCmsCoreWeb.Test.BuilderLive.*` tests cover every one of these in depth, and cover them
  on a PAGE. That is the shape of every bug the section matrix has found so far: a feature that
  works, and works in one column. These are the tools whose scope is a SITE — a class, a snippet, a
  preset, the media library — which is exactly the axis a global layout or component changes,
  because such a document belongs to no site at all.

  The second describe is that case on its own: a master editing a shared document, where
  `editor.site_id` is nil and every site-scoped read has to mean "the shared ones" rather than
  "none". `MishkaCmsCoreWeb.Test.EditorTenancyTest` covers who may open such a document; this covers
  whether the tools work once they have.
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
  @body ~s(<section id="root"><h1>Title</h1><p>Body text</p></section>)
  @decoy ~s(<section id="root"><h2>The entry nobody opened</h2></section>)
  @layout_body ~s(<body class="page"><main>{@inner_content}</main><section id="root"><h1>Title</h1><p>Body text</p></section></body>)

  @sections [:page, :layout, :error_page, :component]

  setup %{conn: conn} do
    SiteState.clear()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: log_in(conn, admin!("boss@example.com")), site: site}
  end

  defp permission! do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp admin!(email) do
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
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp record!(:page, site_id), do: create_page!(site_id: site_id, template: @body)
  defp record!(:layout, site_id), do: create_layout!(site_id: site_id, template: @layout_body)

  # TWO ENTRIES, AND THE COLUMN OPENS ON THE SECOND. An error page keeps a template per status and
  # every tool below is asked of the one that is OPEN; with a single 404 that entry IS the default,
  # so a tool reading the default read the right row by accident and the column proved nothing about
  # the status. The 500 carries the body every assertion here is written against and the 404 carries
  # something else, so a read of the wrong entry is a missing element rather than a silent pass.
  defp record!(:error_page, site_id),
    do:
      create_error_page!(
        site_id: site_id,
        error_pages: [
          %{"status" => 404, "template" => @decoy, "layout" => %{}},
          %{"status" => 500, "template" => @body, "layout" => %{}}
        ]
      )

  defp record!(:component, site_id),
    do:
      create_component!(
        site_id: site_id,
        name: "tools-#{System.unique_integer([:positive])}",
        template: @body
      )

  defp path(:error_page), do: "error-page"
  defp path(section), do: to_string(section)

  # The entry `record!/2` hid the hazard behind. Every other section has one template and names none.
  defp query(:error_page), do: "?status=500"
  defp query(_section), do: ""

  defp open(conn, section, site_id) do
    record = record!(section, site_id)

    {:ok, view, _html} =
      live(
        conn,
        "/admin/dashboard/runtime/builder/#{path(section)}/#{record.id}" <> query(section)
      )

    {view, record}
  end

  defp token(view), do: :sys.get_state(view.pid).socket.assigns.token
  defp editor(view), do: elem(EditorSession.fetch(token(view)), 1)
  defp tree(view), do: editor(view) |> Map.fetch!(:tree)
  defp nodes(view), do: view |> tree() |> Tree.walk()
  defp node_with_tag(view, tag), do: Enum.find(nodes(view), &(&1.tag == tag))

  defp source(view),
    do: view |> tree() |> MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize()

  defp form_node?(%Node{tag: tag}), do: tag in ~w(form .form)
  defp form_node?(_node), do: false

  # `Review.list/1` is keyed by the section as an ATOM, which is the one place a URL's `error-page`
  # and a record's `error_page` are not interchangeable.
  defp notes(site, section, document) do
    MishkaCmsCore.Runtime.PageBuilder.Review.list(%{
      site_id: site.id,
      section: section,
      document_id: document.id
    })
  end

  defp place!(view, parent) do
    render_click(view, "place", %{"parent_id" => parent, "index" => "0"})
  end

  for section <- @sections do
    describe "#{section}: the Blocks palette" do
      test "places a block into the document", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "pick_block", %{"block" => "el-section"})
        place!(view, node_with_tag(view, "section").id)

        assert Enum.count(nodes(view), &(&1.tag == "section")) >= 2,
               "the block was not placed"
      end

      # A FORM BLOCK IS THE ONE THAT DIFFERS. Only `LiveViewCompiler` emits `__page_forms__/0` and
      # the `form_validate`/`form_submit` handlers a page form needs, so the wiring that makes a form
      # work belongs to a page and nowhere else — but the BLOCK is placeable everywhere, because a
      # layout may legitimately carry a search box that posts to a route.
      test "and a form block places without inventing page handlers", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "pick_block", %{"block" => "el-form"})
        place!(view, node_with_tag(view, "section").id)

        assert Enum.any?(nodes(view), &form_node?/1), "the form block was not placed"

        # And the fields it brought are inside it, rather than beside it — `FormPlacement.wrap/3`
        # only wraps a BARE field, and it only does that on a page.
        assert Enum.any?(nodes(view), &(&1.tag in ~w(input .input)))
      end
    end

    describe "#{section}: the Elements palette" do
      test "places a plain element", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "pick_block", %{"block" => "el-paragraph"})
        place!(view, node_with_tag(view, "section").id)

        assert Enum.count(nodes(view), &(&1.tag == "p")) >= 2
      end
    end

    describe "#{section}: the icon picker" do
      test "writes the icon it was opened for", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        target = node_with_tag(view, "p")

        render_click(view, "icon_picked", %{
          "node_id" => target.id,
          "name" => "class",
          "value" => "hero-star"
        })

        assert view |> tree() |> Tree.get(target.id) |> Node.attr_text("class") == "hero-star"
        assert :sys.get_state(view.pid).socket.assigns.icon_picker == nil
      end
    end

    describe "#{section}: the media library" do
      test "writes the file it was asked to choose", %{conn: conn, site: site} do
        media =
          create_media!(site_id: site.id, name: "tools-shot", relative_path: "/uploads/tools.png")

        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        target = node_with_tag(view, "p")

        render_click(view, "pick_media", %{"node_id" => target.id, "name" => "data-src"})
        _loaded = render_async(view)

        assert render(view) =~ "Choosing for"

        send(view.pid, {:row_action, "use_media", %{"id" => media.id}})
        _written = render(view)

        assert view |> tree() |> Tree.get(target.id) |> Node.attr_text("data-src") ==
                 "/uploads/tools.png"
      end
    end

    describe "#{section}: holding several elements" do
      test "bulk delete takes them all and lets go of them", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        h1 = node_with_tag(view, "h1")
        p = node_with_tag(view, "p")

        render_click(view, "select", %{"id" => h1.id})
        render_click(view, "mark", %{"id" => p.id})

        render_click(view, "bulk", %{"action" => "delete"})

        refute source(view) =~ "Title"
        refute source(view) =~ "Body text"
        assert EditorSession.chosen(editor(view)) == []
      end

      test "and a right-click action runs against the node it names", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        before = Enum.count(nodes(view), &(&1.tag == "p"))

        render_click(view, "ctx", %{
          "action" => "duplicate",
          "node_id" => node_with_tag(view, "p").id
        })

        assert Enum.count(nodes(view), &(&1.tag == "p")) == before + 1
      end
    end

    describe "#{section}: reusable classes" do
      test "a saved class can be put on an element", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "save_class", %{"name" => "tools-card", "utilities" => "p-6 bg-white"})

        target = node_with_tag(view, "h1")
        render_click(view, "select", %{"id" => target.id})
        render_click(view, "apply_class", %{"name" => "tools-card"})

        assert view |> tree() |> Tree.get(target.id) |> Node.attr_text("class") =~ "tools-card"
      end
    end

    describe "#{section}: the history sheet" do
      # A REVERT POINT IS THE ONE HISTORY CONTROL THAT REWRITES THE DOCUMENT. Undo walks the session's
      # own stack; this reaches back into a recorded entry and replaces the whole tree from it, which
      # is a different code path and the one `put_tree/3` re-homes every id across.
      test "a recorded step can be reverted into", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "op", %{"kind" => "delete", "node_id" => node_with_tag(view, "p").id})
        refute source(view) =~ "Body text"

        index = Enum.find_index(editor(view).past, &(&1.label =~ "Deleted"))
        assert index, "the delete was not recorded as a revert point"

        render_click(view, "revert", %{"index" => to_string(index)})

        assert source(view) =~ "Body text", "reverting did not restore the document"
      end

      test "and a revert point that is gone is refused rather than blanking the page", %{
        conn: conn,
        site: site
      } do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        before = source(view)
        render_click(view, "revert", %{"index" => "99"})

        assert source(view) == before
      end
    end

    describe "#{section}: snippets" do
      # A SNIPPET IS MARKUP KEPT BY NAME, and the Studio's form is the only way one is made. The
      # scope radio decides who it is for; "This page" needs a document to be about, which every
      # section has and the create flow does not.
      test "saves what is on the document and puts it back", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
        render_click(view, "open_sheet", %{"sheet" => "studio"})
        _studio = render_async(view, 5_000)
        view |> element("#pb-studio-snippets") |> render_click()

        view
        |> element("#pb-snippet-form")
        |> render_submit(%{
          "form" => %{
            "name" => "Kept heading",
            "source" => ~s(<h2 id="from-snippet">Kept</h2>),
            "visibility" => "page"
          }
        })

        assert render(view) =~ "Kept heading"

        snippet =
          MishkaCmsCore.Runtime.Snippet
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(name == "Kept heading")
          |> Ash.read!(page: false)
          |> List.first()

        assert snippet, "the snippet was not written"
        assert snippet.document_id == record.id, "it was not anchored to the open document"

        render_click(view, "select", %{"id" => node_with_tag(view, "section").id})
        view |> element("#pb-snippet-insert-#{snippet.id}") |> render_click()

        assert source(view) =~ "from-snippet", "the snippet did not come back"
      end
    end

    describe "#{section}: dragging" do
      # DRAG AND DROP IS TWO HALVES AND A CONTRACT BETWEEN THEM. The browser answers geometry — where
      # the line goes — and the SERVER answers legality, once, at `dragstart`, as the map of parents
      # that will take this node. A hint that disagrees with the refusal is worse than no hint, so
      # both come from `Containment` through `EditorSession`.
      test "dragstart answers which parents will take the node", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        p = node_with_tag(view, "p")
        render_click(view, "drag_start", %{"node_id" => p.id})

        {:ok, hints} = EditorSession.drop_hints(token(view), %{"node_id" => p.id})

        assert is_map(hints) and hints != %{}, "no hints were computed for the drag"

        assert hints[node_with_tag(view, "section").id] == true,
               "the section it already lives in was said to refuse it"

        assert hints[p.id] == false, "an element was offered as a place to drop itself"
      end

      test "a drop carrying a node id moves it", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        h1 = node_with_tag(view, "h1")
        wrapper = node_with_tag(view, "section")

        render_click(view, "op", %{
          "kind" => "insert",
          "parent_id" => wrapper.id,
          "index" => "0",
          "template" => ~s(<aside id="landing"></aside>)
        })

        landing = node_with_tag(view, "aside")

        render_click(view, "drop", %{
          "node_id" => h1.id,
          "parent_id" => landing.id,
          "index" => "0"
        })

        assert view |> tree() |> Tree.get(h1.id) |> Map.fetch!(:parent_id) == landing.id,
               "the drop did not move the element"
      end

      test "a drop carrying a template inserts it", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "drop", %{
          "template" => ~s(<figure id="dropped"></figure>),
          "parent_id" => node_with_tag(view, "section").id,
          "index" => "0"
        })

        assert node_with_tag(view, "figure"), "the dropped template did not land"
      end

      # A REFUSED DROP RELOCATES RATHER THAN DISAPPEARING. Dropping into something that cannot hold
      # children used to be answered with an error and nothing placed, which reads as the drag having
      # been lost. It lands beside the target instead, and says so.
      test "a drop into something that cannot hold it lands beside it", %{conn: conn, site: site} do
        {view, _record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "op", %{
          "kind" => "insert",
          "parent_id" => node_with_tag(view, "section").id,
          "index" => "0",
          "template" => ~s(<img src="/x.png" />)
        })

        void = node_with_tag(view, "img")

        render_click(view, "drop", %{
          "template" => ~s(<figure id="beside"></figure>),
          "parent_id" => void.id,
          "index" => "0"
        })

        placed = node_with_tag(view, "figure")
        assert placed, "the refused drop was discarded instead of relocated"

        assert placed.parent_id == void.parent_id,
               "it did not land beside the element that refused it"

        assert render(view) =~ "Placed after", "nothing said where it went"
      end
    end

    describe "#{section}: review notes" do
      # A NOTE IS ABOUT A DOCUMENT AND USUALLY ABOUT ONE ELEMENT OF IT, and both halves are stored:
      # `section` + `document_id` say which document, `node_id` + `node_label` say which element and
      # what it was called when the note was written — so a thread still reads a week later after the
      # element it points at has been renamed or removed.
      test "a note is anchored to the element it was written about", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site.id)
        render_async(view)

        h1 = node_with_tag(view, "h1")
        render_click(view, "select", %{"id" => h1.id})
        render_click(view, "open_sheet", %{"sheet" => "review"})
        render_async(view)

        view
        |> element("#pb-comment-form")
        |> render_submit(%{"form" => %{"body" => "Tighten this heading", "type" => "bug"}})

        render_async(view)

        assert [note] = notes(site, unquote(section), record)
        assert note.body == "Tighten this heading"
        assert note.node_id == h1.id
        assert note.node_label == "h1"
        assert note.type == :bug
        assert note.status == :open
      end

      test "and one written with nothing selected is about the whole document", %{
        conn: conn,
        site: site
      } do
        {view, record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "open_sheet", %{"sheet" => "review"})
        render_async(view)

        view
        |> element("#pb-comment-form")
        |> render_submit(%{"form" => %{"body" => "Reads oddly overall", "type" => "suggestion"}})

        render_async(view)

        assert [note] = notes(site, unquote(section), record)
        assert is_nil(note.node_id), "it was anchored to an element nobody had selected"
      end

      test "resolving and reopening move it between the two states", %{conn: conn, site: site} do
        {view, record} = open(conn, unquote(section), site.id)
        render_async(view)

        render_click(view, "open_sheet", %{"sheet" => "review"})
        render_async(view)

        view
        |> element("#pb-comment-form")
        |> render_submit(%{"form" => %{"body" => "Broken on mobile", "type" => "bug"}})

        render_async(view)
        assert [note] = notes(site, unquote(section), record)

        render_click(view, "resolve_comment", %{"id" => note.id})
        assert [resolved] = notes(site, unquote(section), record)
        assert resolved.status == :resolved

        render_click(view, "reopen_comment", %{"id" => note.id})
        assert [reopened] = notes(site, unquote(section), record)
        assert reopened.status == :open

        render_click(view, "delete_comment", %{"id" => note.id})
        assert notes(site, unquote(section), record) == []
      end
    end

    describe "#{section}: two people" do
      # ONE DOCUMENT, TWO BROWSERS. `?session=<token>` is the invitation, and what makes co-editing
      # real rather than two private trees: without it presence shows nobody and the avatars are
      # decoration. The session is shared state in ETS, so an edit in one is the other's immediately.
      test "a second editor joining by token sees the first one's edit", %{
        conn: conn,
        site: site
      } do
        {first, record} = open(conn, unquote(section), site.id)
        render_async(first)

        {:ok, second, _html} =
          live(
            conn,
            "/admin/dashboard/runtime/builder/#{path(unquote(section))}/#{record.id}?session=#{token(first)}"
          )

        assert token(second) == token(first), "the invitation opened a session of its own"

        render_click(first, "op", %{
          "kind" => "set_text",
          "node_id" => hd(node_with_tag(first, "h1").children),
          "text" => "Written by the first"
        })

        assert source(second) =~ "Written by the first",
               "the second editor did not see the first one's change"
      end

      test "and its own edit reaches the first", %{conn: conn, site: site} do
        {first, record} = open(conn, unquote(section), site.id)
        render_async(first)

        {:ok, second, _html} =
          live(
            conn,
            "/admin/dashboard/runtime/builder/#{path(unquote(section))}/#{record.id}?session=#{token(first)}"
          )

        render_click(second, "op", %{
          "kind" => "delete",
          "node_id" => node_with_tag(second, "p").id
        })

        refute source(first) =~ "Body text",
               "the first editor did not see the second one's change"
      end
    end
  end

  # A SHARED DOCUMENT BELONGS TO NO SITE, so every site-scoped tool in the editor is being asked a
  # question whose answer is nil. That is the axis a global layout and a global component change, and
  # the one the rest of this file cannot reach — `EditorTenancyTest` establishes that only a master
  # gets here at all.
  describe "a global document" do
    for section <- [:layout, :component] do
      test "opens with its site unset, and the palette still fills for a #{section}", %{
        conn: conn
      } do
        {view, _record} = open(conn, unquote(section), nil)
        render_async(view)

        assert editor(view).site_id == nil
        assert has_element?(view, "#pb-root")
      end

      test "and a class saved on it is a shared class, on a #{section}", %{conn: conn} do
        {view, _record} = open(conn, unquote(section), nil)
        render_async(view)

        render_click(view, "save_class", %{"name" => "shared-card", "utilities" => "p-6"})

        target = node_with_tag(view, "h1")
        render_click(view, "select", %{"id" => target.id})
        render_click(view, "apply_class", %{"name" => "shared-card"})

        assert view |> tree() |> Tree.get(target.id) |> Node.attr_text("class") =~ "shared-card"

        classes =
          MishkaCmsCore.Runtime.PageBuilder.Classes.all(
            :sys.get_state(view.pid).socket.assigns.current_user,
            nil
          )

        assert Enum.any?(classes, &(&1.name == "shared-card")),
               "the class was written somewhere a shared document cannot read it back"
      end

      test "and the elements palette still places into it, on a #{section}", %{conn: conn} do
        {view, _record} = open(conn, unquote(section), nil)
        render_async(view)

        render_click(view, "pick_block", %{"block" => "el-paragraph"})
        place!(view, node_with_tag(view, "section").id)

        assert Enum.count(nodes(view), &(&1.tag == "p")) >= 2
      end

      test "and holding two elements still deletes both, on a #{section}", %{conn: conn} do
        {view, _record} = open(conn, unquote(section), nil)
        render_async(view)

        render_click(view, "select", %{"id" => node_with_tag(view, "h1").id})
        render_click(view, "mark", %{"id" => node_with_tag(view, "p").id})
        render_click(view, "bulk", %{"action" => "delete"})

        refute source(view) =~ "Title"
        refute source(view) =~ "Body text"
      end
    end
  end
end
