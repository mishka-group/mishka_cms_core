# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.StalePanelWriteTest do
  @moduledoc """
  A panel a broadcast behind the document.

  The chrome and the canvas are two processes, and each learns about the other's edits by handling
  a broadcast. A condition, a hook, a click action and an element's CSS were written by building a
  whole tree from the chrome's own copy and replacing the stored one with it, and the canvas's
  starter did the same with the canvas's copy. A click that arrived before the broadcast of an edit
  made elsewhere put back the document as it was before that edit: the author's words gone from the
  canvas and from the next autosave, under a flash saying the setting was applied.

  A race is a matter of timing, so these do not wait for one. The edit made elsewhere is stored
  without being announced, which is exactly what it looks like from a LiveView that has not handled
  its broadcast yet.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.PageBuilder.Conditions
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.PageStarter
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :integration

  @password "Password123!"
  @template ~s(<section id="hero"><h1>Contact Us</h1><p>Reach out any time.</p></section>)

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

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    page = create_page!(site_id: site.id, template: @template)

    {:ok, conn: log_in(conn, admin("stale-panel@example.com")), site: site, page: page}
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

  defp stored_tree(view) do
    {:ok, session} = EditorSession.fetch(token(view))
    session.tree
  end

  defp node_with_tag(view, tag),
    do: view |> stored_tree() |> Tree.walk() |> Enum.find(&(&1.tag == tag))

  # STORED AND NOT ANNOUNCED — an edit the canvas made, as the chrome sees it before handling the
  # broadcast that says so.
  defp edited_elsewhere(view, params) do
    {:ok, _session} = EditorSession.apply_op(token(view), params, silent: true)
  end

  defp landed(view, node_id),
    do: view |> stored_tree() |> Tree.get(node_id) |> Node.attr("data-landed")

  describe "a chrome write that arrives before the chrome heard of an edit" do
    setup %{conn: conn, site: site, page: page} do
      create_js_hook!(site_id: site.id, name: "collapse")
      view = open_builder(conn, page)
      heading = node_with_tag(view, "h1")
      paragraph = node_with_tag(view, "p")

      edited_elsewhere(view, %{
        kind: :set_attr,
        node_id: paragraph.id,
        name: "data-landed",
        value: "1"
      })

      %{view: view, heading: heading, paragraph: paragraph}
    end

    test "a condition keeps it", %{view: view, heading: heading, paragraph: paragraph} do
      render_change(view, "save_condition", %{"node_id" => heading.id, "rule" => "signed_in"})

      assert landed(view, paragraph.id) == {:string, "1"}, "the edit made elsewhere was put back"

      assert view |> stored_tree() |> Tree.get(heading.id) |> Node.attr(Conditions.attribute())
    end

    test "a hook keeps it", %{view: view, heading: heading, paragraph: paragraph} do
      [hook] = :sys.get_state(view.pid).socket.assigns.js_hooks

      render_click(view, "save_hook", %{"node_id" => heading.id, "hook" => hook.name})

      assert landed(view, paragraph.id) == {:string, "1"}, "the edit made elsewhere was put back"

      assert view |> stored_tree() |> Tree.get(heading.id) |> Node.attr("phx-hook") ==
               {:string, hook.name}
    end

    test "a click action keeps it", %{view: view, heading: heading, paragraph: paragraph} do
      render_click(view, "save_interaction", %{
        "node_id" => heading.id,
        "action" => "toggle_class",
        "class" => "is-open"
      })

      assert landed(view, paragraph.id) == {:string, "1"}, "the edit made elsewhere was put back"
      assert view |> stored_tree() |> Tree.get(heading.id) |> Node.attr("phx-click")
    end

    test "an element's CSS keeps it", %{view: view, heading: heading, paragraph: paragraph} do
      render_click(view, "save_element_css", %{"node_id" => heading.id, "css" => "gap: 7px;"})

      assert landed(view, paragraph.id) == {:string, "1"}, "the edit made elsewhere was put back"
      assert Tree.scope(stored_tree(view), heading.id)
    end
  end

  # THE SAME COPY, AND A NODE IT STILL HOLDS. Written from the chrome's copy, taking a click action
  # off an element deleted elsewhere put the element back.
  test "a click action taken off an element deleted elsewhere does not bring it back", %{
    conn: conn,
    page: page
  } do
    view = open_builder(conn, page)
    paragraph = node_with_tag(view, "p")

    edited_elsewhere(view, %{kind: :delete, node_id: paragraph.id})

    render_click(view, "save_interaction", %{
      "node_id" => paragraph.id,
      "action" => "",
      "class" => ""
    })

    refute Tree.get(stored_tree(view), paragraph.id), "the deleted element came back"
    assert has_element?(view, "#pb-root"), "the editor did not survive the gesture"
  end

  # THE CANVAS'S COPY. A starter replaces a page with nothing on it — and a page that has had
  # something put on it since the canvas last drew is not that page.
  test "a starter picked on a page filled elsewhere is inserted, not put over it", %{
    conn: conn,
    site: site
  } do
    empty = create_page!(site_id: site.id, template: PageStarter.blank())
    view = open_builder(conn, empty)

    {:ok, canvas, _html} = live(conn, "/admin/dashboard/runtime/builder-canvas/#{token(view)}")

    edited_elsewhere(view, %{
      kind: :insert,
      parent_id: nil,
      index: 1,
      template: "<p>Written elsewhere</p>"
    })

    render_click(canvas, "page_starter", %{"structure" => "two"})

    source = view |> stored_tree() |> Serializer.serialize()

    assert source =~ "Written elsewhere", "the starter replaced what was put on the page"
    assert source =~ "grid-cols-2", "the starter was not placed"
  end
end
