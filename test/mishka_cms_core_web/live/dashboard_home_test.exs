# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.DashboardHomeTest do
  @moduledoc """
  Renders the admin dashboard home as a logged-in master admin — the page-level guard the per-widget
  unit tests can't give: it mounts the real LiveView (dead + connected render + the layout), so a
  reserved-assign clash or a broken widget grid surfaces here.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard"

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

    {:ok, conn: conn}
  end

  test "a master admin sees the dashboard with the widget grid", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com"))

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Dashboard"
    assert has_element?(view, "#dash-site-overview")
    assert has_element?(view, "button", "Customize")
  end

  describe "the door" do
    test "an admin of a single dashboard area is let in", %{conn: conn} do
      conn = log_in(conn, create_user_with_permissions!(["admin:dashboard:blog:post"]))

      assert {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#admin-sidebar a[href='#{@path}']", "Home")
    end

    test "an API admin is refused the screens and sent to the site root", %{conn: conn} do
      conn = log_in(conn, create_user_with_permissions!(["admin:api:*"]))

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, @path)
    end

    test "a user holding nothing is refused", %{conn: conn} do
      conn = log_in(conn, create_user!())

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, @path)
    end
  end

  # A CARD LINKS ONLY WHERE ITS VIEWER MAY GO: CMS status is open to every dashboard admin, and its
  # "View more info" leads to Sites, which is the site area's.
  describe "a widget's footer link" do
    defp cms_status(user),
      do: Enum.find(MishkaCmsCore.Dashboard.Widget.collect(user), &(&1.id == "cms-status"))

    test "is kept for a viewer who may open the page it leads to" do
      user =
        create_user_with_permissions!([
          "admin:dashboard:runtime:page",
          "admin:dashboard:runtime:site"
        ])

      assert cms_status(user).link == "/admin/dashboard/runtime/sites"
    end

    test "is dropped for a viewer who may not, so the card draws no footer" do
      user = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      assert %{link: nil} = cms_status(user)
    end
  end

  test "the admin chrome wraps the page — sidebar nav, topbar, and active item", %{conn: conn} do
    conn = log_in(conn, create_admin("boss@example.com"))

    {:ok, view, html} = live(conn, @path)

    # Sidebar: logo + a nav link into the runtime pages.
    assert html =~ "MishkaCMS"
    assert has_element?(view, "a[href='/admin/dashboard/runtime/sites']", "Sites")
    # Topbar: the signed-in user's email + a logout link.
    assert html =~ "boss@example.com"
    assert has_element?(view, "a[href='/auth/sign-out']")
    # The Home item is highlighted active for `/admin/dashboard`.
    assert html =~ "bg-[#f2f1fc]"
  end

  test "drag reorder from the grid hook persists the new order", %{conn: conn} do
    user = create_admin("boss@example.com")
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, @path)
    view |> element("button", "Customize") |> render_click()

    ids =
      MishkaCmsCore.Dashboard.Widget.collect(user)
      |> MishkaCmsCore.Dashboard.Widget.arrange(%{})
      |> Enum.map(& &1.id)

    reversed = Enum.reverse(ids)
    view |> element("#dash-grid") |> render_hook("reorder", %{"ids" => reversed})

    assert MishkaCmsCore.Settings.get("dashboard.layout.#{user.id}")["order"] == reversed
    assert view |> render() |> widget_dom_order() == reversed
  end

  test "a width preset click persists the span and widens the card", %{conn: conn} do
    user = create_admin("boss@example.com")
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, @path)
    view |> element("button", "Customize") |> render_click()

    view
    |> element("#dash-users-summary button[phx-value-span='4']")
    |> render_click()

    assert MishkaCmsCore.Settings.get("dashboard.layout.#{user.id}")["spans"]["users-summary"] ==
             4

    assert has_element?(view, "#dash-users-summary.col-span-4")
  end

  test "a library chip dropped on the grid lands at the drop slot", %{conn: conn} do
    user = create_admin("boss@example.com")
    conn = log_in(conn, user)

    {:ok, view, _html} = live(conn, @path)
    view |> element("button", "Customize") |> render_click()
    view |> element("#dash-site-overview button", "Hide") |> render_click()
    assert has_element?(view, "#tray-site-overview")

    view
    |> element("#dash-grid")
    |> render_hook("add_at", %{"id" => "site-overview", "index" => 0})

    refute has_element?(view, "#tray-site-overview")
    assert view |> render() |> widget_dom_order() |> hd() == "site-overview"
  end

  defp widget_dom_order(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#dash-grid > [data-id]")
    |> LazyHTML.attribute("data-id")
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

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  describe "realtime" do
    test "an open board refreshes a widget when its data changes elsewhere", %{conn: conn} do
      conn = log_in(conn, create_admin("boss@example.com"))
      page = create_page!(title: "Realtime Archive Probe")

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      before_archive = activity(view)

      # Archive it the way the app does — Ash publishes the resource's destroy topic, which the board
      # subscribed to on mount. Nothing here touches the view.
      page
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!(authorize?: false)

      render_async(view)

      # Same mounted view: never re-navigated, never re-mounted — it re-loaded itself. Creating the
      # page is itself an activity entry, so the title alone proves nothing; what proves the
      # reload is that the feed MOVED and now carries the archive.
      after_archive = activity(view)

      refute after_archive == before_archive
      assert after_archive =~ "Realtime Archive Probe"
    end
  end

  defp activity(view), do: view |> element("#dash-recent-activity") |> render()
end
