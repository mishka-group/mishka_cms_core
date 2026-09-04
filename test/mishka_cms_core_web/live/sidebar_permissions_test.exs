defmodule MishkaCmsCoreWeb.Test.SidebarPermissionsTest do
  @moduledoc """
  The nav, driven through the real chrome: it shows a signed-in admin exactly the links their
  permissions allow, and nothing else.

  And the other half: `MishkaCmsCore.Sidebar.PageGuard` refuses the page itself, so a link a viewer
  was never shown is a URL they cannot open either. The guard reads `socket.view`, never the URL —
  which is why the doubled-slash spelling below cannot buy anyone a weaker gate.

  `MishkaCmsCore.SidebarTest` covers the registry itself.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Sidebar

  @home "/admin/dashboard"
  @users "/admin/dashboard/account/users"
  @permissions "/admin/dashboard/account/permissions"
  @sites "/admin/dashboard/runtime/sites"
  @activity "/admin/dashboard/runtime/activity"

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

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp sign_in(conn, permissions, overrides \\ []),
    do: log_in(conn, create_user_with_permissions!(permissions, overrides))

  # The dashboard subscribes to PubSub and re-loads widgets when it hears a broadcast. Left running,
  # a view outlives its test and the NEXT test's inserts reach it after this one's sandbox owner is
  # gone. Drain the async loads, then shut it down while its connection is still valid.
  defp close(view) do
    # Wait for completion, not a fixed guess — the default 100ms is shorter than the dashboard's
    # widget loads take, and a half-drained view raises on the way down.
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  describe "the rendered nav" do
    test "a master holding everything gets the whole console", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(["*"]) |> live(@home)
      render_async(view)

      assert has_element?(view, "#admin-sidebar a[href='#{@sites}']", "Sites")
      assert has_element?(view, "#admin-sidebar a[href='#{@users}']", "Users")
      assert has_element?(view, "#admin-sidebar a[href='#{@permissions}']", "Permissions")
      assert has_element?(view, "#admin-sidebar a[href='/admin/dashboard/settings']", "Settings")
      close(view)
    end

    test "an admin without the user and permission areas is never shown Account", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(["admin:dashboard:runtime:site"]) |> live(@home)
      render_async(view)

      assert has_element?(view, "#admin-sidebar a[href='#{@sites}']", "Sites")
      refute has_element?(view, "#admin-sidebar a[href='#{@users}']")
      refute has_element?(view, "#admin-sidebar a[href='#{@permissions}']")
      close(view)
    end

    test "an admin of one unrelated area keeps Home, Settings and the content lists, and loses the rest",
         %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(["admin:dashboard:blog:post"]) |> live(@home)
      render_async(view)

      assert has_element?(view, "#admin-sidebar a[href='#{@home}']", "Home")
      # Settings stays: the page filters its own tabs, and one of them is the user's preferences.
      assert has_element?(view, "#admin-sidebar a[href='/admin/dashboard/settings']", "Settings")

      assert has_element?(
               view,
               "#admin-sidebar a[href='/admin/dashboard/runtime/pages']",
               "Pages"
             )

      refute has_element?(view, "#admin-sidebar a[href='#{@sites}']")
      refute has_element?(view, "#admin-sidebar a[href='#{@users}']")
      close(view)
    end

    # The nav is replaced on every live navigation; `SidebarScroll` (assets/js/admin_hooks.js) puts
    # it back where the reader left it, and with nothing remembered scrolls to the current page's link.
    test "the nav keeps its scroll position and marks the current page's link", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(["*"]) |> live(@sites)
      render_async(view)

      assert has_element?(view, "#admin-sidebar nav#admin-sidebar-nav[phx-hook='SidebarScroll']")

      assert has_element?(
               view,
               "#admin-sidebar-nav a[href='#{@sites}'][aria-current='page']",
               "Sites"
             )

      assert [_only_one] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#admin-sidebar [aria-current]")
               |> Enum.to_list()

      close(view)
    end

    test "hiding an entry in Settings takes the link out of the nav", %{conn: conn} do
      SettingsState.put(nil, Sidebar.visible_key("runtime.sites"), false)
      on_exit(fn -> SettingsState.delete(nil, Sidebar.visible_key("runtime.sites")) end)

      {:ok, view, _html} = conn |> sign_in(["*"]) |> live(@home)
      render_async(view)

      refute has_element?(view, "#admin-sidebar a[href='#{@sites}']")
      assert has_element?(view, "#admin-sidebar a[href='/admin/dashboard/runtime/pages']")
      close(view)
    end
  end

  describe "PageGuard — typing the URL" do
    test "refuses a page the viewer's permissions do not cover", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:runtime:site"])

      assert {:error, {:redirect, %{to: @home, flash: flash}}} = live(conn, @permissions)
      assert flash["error"] =~ "permission"
    end

    test "allows the page the same permissions do cover", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:runtime:site"])

      assert {:ok, view, _html} = live(conn, @sites)
      close(view)
    end

    test "a user admin is refused Sites and Permissions, and allowed Users", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:user"])

      assert {:error, {:redirect, %{to: @home}}} = live(conn, @sites)
      assert {:error, {:redirect, %{to: @home}}} = live(conn, @permissions)
      assert {:ok, view, _html} = live(conn, @users)
      close(view)
    end

    test "a permission admin is refused Users and allowed Permissions", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:permission"])

      assert {:error, {:redirect, %{to: @home}}} = live(conn, @users)
      assert {:ok, view, _html} = live(conn, @permissions)
      close(view)
    end

    test "Activity opens to its own area and not to the site area", %{conn: conn} do
      assert {:error, {:redirect, %{to: @home}}} =
               conn |> sign_in(["admin:dashboard:runtime:site"]) |> live(@activity)

      assert {:ok, view, _html} =
               conn |> sign_in(["admin:dashboard:runtime:activity"]) |> live(@activity)

      close(view)
    end

    test "someone with no console access at all is sent to the site root, not bounced" do
      # A user who cannot satisfy Home's own gate must not be redirected TO Home.
      assert MishkaCmsCore.Sidebar.home().permissions == [{:under, "admin:dashboard"}]
    end

    test "the dashboard stays reachable, so the redirect can never loop", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:blog:comment"])

      assert {:ok, view, _html} = live(conn, @home)
      close(view)
    end

    test "a doubled slash cannot buy a weaker gate — the guard never reads the URL", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:runtime:site"])

      # Phoenix drops empty segments from path_info, so this really does route to Permissions.
      assert {:error, {:redirect, %{to: @home}}} =
               live(conn, "/admin/dashboard//account/permissions")
    end

    test "nor does a trailing slash or an interior run of slashes", %{conn: conn} do
      conn = sign_in(conn, ["admin:dashboard:runtime:site"])

      # Both reach the same LiveView — Phoenix drops empty segments from path_info. A LEADING "//"
      # is deliberately not tested: that is a protocol-relative URL, so the host becomes "admin"
      # and it 404s before routing, which is a different thing entirely.
      for spelling <- [
            "/admin/dashboard/account/permissions/",
            "/admin/dashboard//account/users"
          ] do
        assert {:error, {:redirect, %{to: @home}}} = live(conn, spelling),
               "#{spelling} escaped its gate"
      end
    end

    test "hiding a link in Settings does not lock the page — permissions do", %{conn: conn} do
      SettingsState.put(nil, Sidebar.visible_key("runtime.sites"), false)
      on_exit(fn -> SettingsState.delete(nil, Sidebar.visible_key("runtime.sites")) end)

      conn = sign_in(conn, ["*"])

      assert {:ok, view, _html} = live(conn, @sites)
      close(view)
    end
  end
end
