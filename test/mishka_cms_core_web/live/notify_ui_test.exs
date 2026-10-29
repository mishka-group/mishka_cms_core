# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.NotifyUITest do
  @moduledoc """
  Phase 3 UI — the Settings → Notifications tab (admin toggles which notifications a site receives)
  and the live topbar bell badge, mounted through the real admin chrome.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Runtime.States.SiteState

  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()
    MishkaCmsCore.Settings.load_definitions()

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

    {:ok, conn: conn}
  end

  test "the settings notifications tab renders the notification toggles", %{conn: conn} do
    admin = create_admin("boss@example.com")
    conn = log_in(conn, admin)

    {:ok, view, _html} = live(conn, "/admin/dashboard/settings")

    html = render_patch(view, "/admin/dashboard/settings?tab=notifications")

    assert has_element?(view, "#settings-form")
    assert html =~ "Delete read notifications after (days)"
    # Fields are split into sub-sections; retention settings sit under a "Retention" heading.
    assert has_element?(view, "#settings-form h3", "Retention")
  end

  test "the Preferences tab holds per-user settings with a 'Just for you' badge", %{conn: conn} do
    admin = create_admin("boss@example.com")
    conn = log_in(conn, admin)

    {:ok, view, _html} = live(conn, "/admin/dashboard/settings")

    html = render_patch(view, "/admin/dashboard/settings?tab=preferences")

    assert has_element?(view, "#settings-form")
    assert html =~ "Just for you"
    assert html =~ "User permission changes"
  end

  test "the bell badge + dropdown show unread notifications with a count", %{conn: conn} do
    admin = create_admin("boss@example.com")
    Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping A"})
    Notify.deliver({:user, admin.id}, %{type: "test:y", title: "Ping B"})

    conn = log_in(conn, admin)
    {:ok, view, _html} = live(conn, "/admin/dashboard")

    # The badge + dropdown list are async-loaded after mount; re-render to observe them.
    html = render(view)
    assert html =~ "bg-[#5b57d6]"
    assert html =~ "2 unread"
    assert has_element?(view, "#topbar-notifs", "Ping A")
    assert has_element?(view, "#topbar-notifs", "Ping B")
  end

  test "'Mark all read' in the dropdown clears the unread badge and count", %{conn: conn} do
    admin = create_admin("boss@example.com")
    Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping A"})
    Notify.deliver({:user, admin.id}, %{type: "test:y", title: "Ping B"})

    conn = log_in(conn, admin)
    {:ok, view, _html} = live(conn, "/admin/dashboard")

    assert render(view) =~ "2 unread"

    view |> element("#topbar-notifs button", "Mark all read") |> render_click()

    refute has_element?(view, "span.bg-red-500")
    refute has_element?(view, "#topbar-notifs button", "Mark all read")
  end

  test "a per-notification check marks just that one read, without navigating", %{conn: conn} do
    admin = create_admin("boss@example.com")
    Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping A"})
    Notify.deliver({:user, admin.id}, %{type: "test:y", title: "Ping B"})

    conn = log_in(conn, admin)
    {:ok, view, _html} = live(conn, "/admin/dashboard")

    assert render(view) =~ "2 unread"

    id = first_unread_id(admin)
    view |> element("#bell-notif-#{id} button[phx-click='notify_read']") |> render_click()

    # Still on the dashboard, one fewer unread.
    assert render(view) =~ "1 unread"
    assert has_element?(view, "#topbar-notifs")
  end

  test "the notifications inbox renders the user's notifications via the Gervaz table", %{
    conn: conn
  } do
    admin = create_admin("boss@example.com")
    Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Hello there", severity: :info})

    conn = log_in(conn, admin)
    {:ok, view, _html} = live(conn, "/admin/dashboard/notifications")

    # The Gervaz table loads its rows asynchronously; once loaded the card shows the notification.
    assert render_async(view) =~ "Hello there"
  end

  # A NOTIFICATION CAN POINT OUTSIDE THE PAGE'S LIVE_SESSION — a mention in the visual editor points
  # into the editor's own — and LiveView refuses a live navigation across that boundary, logs
  # "unauthorized live_redirect" and falls back to a page load. `/probe-editor/…` is routed in no
  # admin session here; `/admin/dashboard/notifications` is in the admin's own.
  describe "following a notification's link" do
    setup %{conn: conn} do
      admin = create_admin("boss@example.com")
      %{admin: admin, conn: log_in(conn, admin)}
    end

    test "from the bell, a page outside the admin's session is a page load", %{
      conn: conn,
      admin: admin
    } do
      Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping", link: "/probe-editor/x"})
      {:ok, view, _html} = live(conn, "/admin/dashboard")
      _loaded = render(view)

      open =
        element(view, "#bell-notif-#{first_unread_id(admin)} button[phx-click='notify_open']")

      assert {:error, {:redirect, %{to: "/probe-editor/x"}}} = render_click(open)
    end

    test "from the bell, a page inside the admin's session stays a live navigation", %{
      conn: conn,
      admin: admin
    } do
      link = "/admin/dashboard/notifications"
      Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping", link: link})
      {:ok, view, _html} = live(conn, "/admin/dashboard")
      _loaded = render(view)

      open =
        element(view, "#bell-notif-#{first_unread_id(admin)} button[phx-click='notify_open']")

      assert {:error, {:live_redirect, %{to: ^link}}} = render_click(open)
    end

    test "from the bell, a link that is not a path of this app only marks it read", %{
      conn: conn,
      admin: admin
    } do
      Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping", link: "//elsewhere.test"})

      {:ok, view, _html} = live(conn, "/admin/dashboard")
      _loaded = render(view)

      id = first_unread_id(admin)
      view |> element("#bell-notif-#{id} button[phx-click='notify_open']") |> render_click()

      assert has_element?(view, "#topbar-notifs"), "still on the dashboard"
      assert unread(admin) == [], "and the notification is read"
    end

    # A table cell renders from the record alone, with no socket to ask the router, so the inbox's
    # link is always the plain one.
    test "from the inbox, the title is a plain link", %{conn: conn, admin: admin} do
      Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping", link: "/probe-editor/x"})
      {:ok, view, _html} = live(conn, "/admin/dashboard/notifications")

      links =
        view
        |> render_async()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(a[href="/probe-editor/x"]))

      refute Enum.empty?(links), "the title is not a link to the notification's page"
      assert LazyHTML.attribute(links, "data-phx-link") == []
    end
  end

  # ── helpers (mirrors dashboard_home_test) ───────────────────────────────────

  defp unread(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.Query.filter(is_nil(read_at))
    |> Ash.read!(actor: user, tenant: user.site_id, page: [limit: 1])
    |> Map.get(:results)
  end

  defp first_unread_id(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.Query.filter(is_nil(read_at))
    |> Ash.read!(actor: user, tenant: user.site_id, page: [limit: 1])
    |> Map.get(:results)
    |> hd()
    |> Map.get(:id)
  end

  defp create_admin(email) do
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
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
