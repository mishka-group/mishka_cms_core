# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.MediaCategoriesTest do
  @moduledoc """
  The media library's category rail, through the buttons a master admin presses and the broadcasts
  everybody else's writes publish.

  Its Archive, Restore and Delete permanently are hand-written twins of a Gervaz table's row
  actions, and they call `Ash.destroy(record, action: ...)` the same way — so they carry the same
  `authorize?: true` the handler now does, and this is what says the three of them still work with
  authorization on.

  The rest is what the rail does with a notification somebody else's write publishes: the row one
  carries is the bare row that write returned, and the clause that takes it has to be the clause for
  the action that ran.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.MediaCategory
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/runtime/medias"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

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
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  defp star_permission do
    Permission
    |> Ash.Query.filter(name == "*")
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_permission!(name: "*")
      permission -> permission
    end
  end

  defp create_admin(email, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # `:master_get` is outside the archive's read filter, so it answers for a row in either state;
  # `:master_get_archived` answers only while the row is archived.
  defp category_row(id), do: Ash.get(MediaCategory, id, action: :master_get, authorize?: false)

  defp archived_category_row(id),
    do: Ash.get(MediaCategory, id, action: :master_get_archived, authorize?: false)

  defp button(view, event, id),
    do: element(view, "button[phx-click='#{event}'][phx-value-id='#{id}']")

  # THE WRITES BELOW ARE SOMEBODY ELSE'S, and each hands back the notification Ash would have
  # dispatched for it instead of sending it — `return_notifications?: true` — so the rail can be
  # given the very message that write publishes, in the order the test chooses. Ash dispatches
  # asynchronously, and waiting for one is what made the crash these cover show up in two full suite
  # runs out of seven.
  defp created_elsewhere!(site) do
    {:ok, category, notifications} =
      MediaCategory
      |> Ash.Changeset.for_create(
        :master_create,
        %{name: "Videos", site_id: site.id},
        authorize?: false
      )
      |> Ash.create(return_notifications?: true)

    {category, broadcast!(notifications, :master_create, "created")}
  end

  # `:master_update` slugifies the name into itself, so the rail draws "screens", not "Screens".
  defp renamed_elsewhere!(category) do
    {:ok, _renamed, notifications} =
      Ash.update(category, %{name: "Screens"},
        action: :master_update,
        authorize?: false,
        return_notifications?: true
      )

    broadcast!(notifications, :master_update, "updated")
  end

  defp destroyed_elsewhere!(category, action) do
    {:ok, _destroyed, notifications} =
      Ash.destroy(category,
        action: action,
        authorize?: false,
        return_destroyed?: true,
        return_notifications?: true
      )

    broadcast!(notifications, action, "destroyed")
  end

  defp restored_elsewhere!(archived) do
    {:ok, _restored, notifications} =
      Ash.update(archived,
        action: :master_unarchive,
        authorize?: false,
        return_notifications?: true
      )

    broadcast!(notifications, :master_unarchive, "updated")
  end

  # Every one of them carries the bare row the write returned — which is what these tests are about
  # — and `media_category`'s `pub_sub` block publishes it on the topic the rail subscribes to.
  defp broadcast!(notifications, action, event) do
    notification =
      Enum.find(notifications, &match?(%{resource: MediaCategory, action: %{name: ^action}}, &1))

    assert match?(%Ash.NotLoaded{}, notification.data.site),
           "the premise of these tests: a notification carries the bare row the write returned"

    %Phoenix.Socket.Broadcast{
      topic: "media_category:#{event}",
      event: event,
      payload: notification
    }
  end

  test "a holder of the media area gets the upload form and the category controls", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("uploader@example.com"))
    create_media_category!(site_id: site.id, name: "Photos")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    assert has_element?(view, "#media-upload-card")
    assert has_element?(view, "#media-add-category")
  end

  # The admin session here still asks for `admin:dashboard:*`, which holds the media area, so the
  # page's own mount is asked what it offers an admin of another area.
  test "an admin of another area is offered neither the upload form nor the category controls",
       %{site: site} do
    offered? = fn permissions ->
      user = create_user_with_permissions!(permissions, site_id: site.id)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
        assigns: %{__changed__: %{}, flash: %{}, current_user: user}
      }

      {:ok, socket} =
        MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Media.Index.mount(%{}, %{}, socket)

      socket.assigns.media_writer?
    end

    refute offered?.(["admin:dashboard:runtime:page"])
    assert offered?.(["admin:dashboard:runtime:media"])
  end

  test "a master archives a category from the rail", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    assert has_element?(button(view, "delete_category", category.id))
    render_click(button(view, "delete_category", category.id))

    assert {:ok, archived} = archived_category_row(category.id)
    refute is_nil(archived.archived_at)
  end

  test "a master deletes an archived category permanently", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, _} =
      Ash.destroy(category,
        action: :master_destroy,
        authorize?: false,
        return_destroyed?: true
      )

    {:ok, view, _html} = live(conn, @path)
    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    assert has_element?(button(view, "permanent_delete_category", category.id))
    render_click(button(view, "permanent_delete_category", category.id))

    assert {:error, _} = category_row(category.id)
  end

  # The rail hands the archived list what its own read hands it, or the list draws a row that knows
  # nothing about its site.
  test "a category archived while the archive panel is open brings its site with it", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    assert has_element?(view, "#category-site-#{category.id}"),
           "the active rail is naming no site, and a master's read of it loads one"

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    send(view.pid, destroyed_elsewhere!(category, :master_destroy))
    render(view)

    assert has_element?(view, "#archived-category-site-#{category.id}"),
           "the row went in as the notification carried it, with no site on it to name"
  end

  # The other half: a tenant's rail asks for no site — it has one — so the row a notification carries
  # reaches the template exactly as it arrived, and the guard over the site name is all that stands
  # between `%Ash.NotLoaded{}` and a read of `.name` on it.
  test "a tenant's archive panel draws a row whose site was never loaded", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("tenant@example.com", site.id))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    send(view.pid, destroyed_elsewhere!(category, :master_destroy))
    render(view)

    assert has_element?(button(view, "permanent_delete_category", category.id)),
           "the archived row is in the rail, which means the rail survived drawing it"

    refute has_element?(view, "#archived-category-site-#{category.id}"),
           "an unloaded site is not a site to name"
  end

  # A permanent delete is a destroy action like archiving is, and the master's is named
  # `:master_permanent_destroy` — so the archive clause took it and put a row nobody can restore
  # back into the archived rail.
  test "a permanent delete elsewhere does not put the row back in the archive rail", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    send(view.pid, destroyed_elsewhere!(category, :master_destroy))
    render(view)
    assert has_element?(button(view, "permanent_delete_category", category.id))

    {:ok, archived} = archived_category_row(category.id)
    send(view.pid, destroyed_elsewhere!(archived, :master_permanent_destroy))
    render(view)

    refute has_element?(button(view, "permanent_delete_category", category.id)),
           "the row is gone for good, so the rail has nothing left to offer for it"
  end

  # A row can be gone by the time the rail asks for it: archived, then deleted for good, with the
  # archive's own notification still in flight. Nothing to draw is a row to leave out, not a page to
  # lose.
  test "an archive whose row is already deleted leaves the rail alone", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    archived_elsewhere = destroyed_elsewhere!(category, :master_destroy)
    {:ok, archived} = archived_category_row(category.id)

    # The delete's own notification is kept back: this is the archive arriving after it.
    destroyed_elsewhere!(archived, :master_permanent_destroy)

    send(view.pid, archived_elsewhere)
    render(view)

    refute has_element?(button(view, "permanent_delete_category", category.id)),
           "there is no row left to read, and the rail is still up to say so"
  end

  # The master's restore is `:master_unarchive`, which the unarchive clause has to take as well:
  # left to the `:update` clause it puts the row back in the active list without taking it out of
  # the archived one.
  test "a restore elsewhere takes the row out of the archive rail", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    send(view.pid, destroyed_elsewhere!(category, :master_destroy))
    render(view)
    assert has_element?(button(view, "permanent_delete_category", category.id))

    {:ok, archived} = archived_category_row(category.id)
    send(view.pid, restored_elsewhere!(archived))
    render(view)

    refute has_element?(button(view, "permanent_delete_category", category.id)),
           "the row is active again, so the archive rail has to let it go"
  end

  # Archiving a folder takes nothing with it: one that still holds a file is refused, so the row
  # stays in the active rail still counting the file, and the archive button is a bang no more — the
  # refusal is the reader's to read, not a crash that takes the page with it.
  test "archiving a folder that still holds a file is refused, and the row keeps its count", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com"))
    category = create_media_category!(site_id: site.id, name: "Screenshots")
    create_media!(site_id: site.id, media_category_id: category.id)

    {:ok, view, _html} = live(conn, @path)
    render_async(view)
    assert has_element?(view, "#category-count-#{category.id}", "1")

    render_click(button(view, "delete_category", category.id))

    assert has_element?(view, "#category-count-#{category.id}", "1"),
           "the refused folder is still in the rail, counting the file it holds"

    assert {:ok, %{archived_at: nil}} = category_row(category.id)
  end

  # `:master_get`, which is how a master's rail reads a notified row back, is one of the archive's
  # `exclude_read_actions` — it answers for an archived row as readily as a live one, and the rail's
  # own list actions do not. Two writers publish in no fixed order between them, so the update has
  # to arrive behind the archive at some point.
  test "an update that arrives after the archive stays out of the active rail", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com"))

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    # The create's notification and the archive's are both kept back, so the rail has never seen
    # this row: what reaches it is the rename alone, behind the archive that overtook it.
    {category, _created} = created_elsewhere!(site)
    renamed = renamed_elsewhere!(category)

    {:ok, current} = category_row(category.id)
    destroyed_elsewhere!(current, :master_destroy)

    send(view.pid, renamed)
    render(view)

    refute has_element?(view, "#category-name-#{category.id}"),
           "the row is archived, and the active rail draws no row its own list cannot return"
  end

  # The rail draws a site name on the active list too, and a create and an update arrive on the same
  # kind of bare row.
  test "a category created and renamed elsewhere joins the rail with its site", %{
    conn: conn,
    site: site
  } do
    conn = log_in(conn, create_admin("boss@example.com"))

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    {category, created} = created_elsewhere!(site)
    send(view.pid, created)
    render(view)

    assert has_element?(view, "#category-site-#{category.id}"),
           "the created row went into the rail as the notification carried it"

    send(view.pid, renamed_elsewhere!(category))
    render(view)

    assert has_element?(view, "#category-name-#{category.id}", "screens"),
           "and so did the renamed one, which is the same row read a second time"
  end

  # The tenant half of the same re-read: another pair of actions, and a tenant carried alongside
  # them against a resource that is never global. A row the read cannot answer for is dropped
  # without a word, so a mis-wiring here shows up as nothing at all — the row arriving is the only
  # thing that says the pair is right.
  test "a tenant's rail takes a category created and renamed elsewhere", %{conn: conn, site: site} do
    conn = log_in(conn, create_admin("tenant@example.com", site.id))

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    {category, created} = created_elsewhere!(site)
    send(view.pid, created)
    render(view)

    assert has_element?(view, "#category-count-#{category.id}", "0"),
           "the created row went into the tenant's rail, counted by the tenant's own read"

    refute has_element?(view, "#category-site-#{category.id}"),
           "a tenant's rail loads no site, so it has none to name"

    send(view.pid, renamed_elsewhere!(category))
    render(view)

    assert has_element?(view, "#category-name-#{category.id}", "screens"),
           "and the rename reached it through the same pair a second time"
  end

  # The rail's other half. A tenant takes the tenant actions, which are the branches that carry a
  # tenant alongside `authorize?: true` — and both are bang calls, so a mismatch between the action
  # and the context it is handed arrives as a crash rather than as a flash.
  test "a tenant archives and permanently deletes on their own site", %{conn: conn, site: site} do
    tenant = create_admin("tenant@example.com", site.id)
    assert tenant.site_id == site.id, "a master here would take the other branch of every case"

    conn = log_in(conn, tenant)
    category = create_media_category!(site_id: site.id, name: "Screenshots")

    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    render_click(button(view, "delete_category", category.id))
    assert {:ok, archived} = archived_category_row(category.id)
    refute is_nil(archived.archived_at)

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)

    render_click(button(view, "restore_category", category.id))
    assert {:ok, %{archived_at: nil}} = category_row(category.id)

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)
    render_click(button(view, "delete_category", category.id))

    render_click(view, "toggle_category_archive_view", %{})
    render_async(view)
    render_click(button(view, "permanent_delete_category", category.id))

    assert {:error, _} = category_row(category.id)
  end
end
