# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TopbarSearchTest do
  @moduledoc """
  The top bar's search (`MishkaCmsCore.Layouts.TopbarSearch`): what extensions find on
  `topbar:search`, grouped, each group the viewer may see, every row a path of the app; and the box
  that lists them, walked with the arrow keys, opened with Enter and closed with Escape.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.TopbarSearch
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.TopbarSearchProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @box "#admin-topbar-search"

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
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    {:ok, conn: conn, admin: admin}
  end

  describe "with no plugin answering" do
    test "the box says nothing matches", %{conn: conn, admin: admin} do
      assert TopbarSearch.collect("aurora", context(admin)) == []

      view = open(conn, admin)
      search(view, "aurora")
      assert has_element?(view, "#{@box}-empty", "Nothing matches")
    end

    test "the box keeps the core's placeholder", %{conn: conn, admin: admin} do
      assert TopbarSearch.placeholder(context(admin)) == nil

      view = open(conn, admin)
      assert has_element?(view, "#{@box} input[placeholder='Search pages, posts, people…']")
    end
  end

  describe "with a plugin answering" do
    setup do
      register(TopbarSearchProbe)
      _ref = :telemetry_test.attach_event_handlers(self(), [TopbarSearchProbe.called()])
      :ok
    end

    test "a page the plugin is at home on gets its placeholder, another page the core's", %{
      conn: conn,
      admin: admin
    } do
      assert TopbarSearch.placeholder(context(admin)) == "Search the probe shop…"
      assert TopbarSearch.placeholder(%{context(admin) | current_path: "/admin/dashboard"}) == nil

      view = open(conn, admin)
      assert has_element?(view, "#{@box} input[placeholder='Search the probe shop…']")

      {:ok, home, _html} = live(build_conn_for(conn, admin), "/admin/dashboard")
      assert has_element?(home, "#{@box} input[placeholder='Search pages, posts, people…']")
    end

    test "an empty query asks no plugin", %{admin: admin} do
      assert TopbarSearch.collect("   ", context(admin)) == []
      refute_received {_event, _ref, _measurements, %{query: _query}}
    end

    test "groups the rows the viewer may see, low priority first", %{admin: admin} do
      assert [products, customers] = TopbarSearch.collect("  aurora ", context(admin))
      assert_received {_event, _ref, _measurements, %{query: "aurora"}}

      assert %{id: "probe-products", label: "Products", rows: [aurora, atlas]} = products

      assert %{title: "Aurora UI kit aurora", icon: "hero-cube", detail: "180 components"} =
               aurora

      assert %{icon: "hero-document-text", detail: nil} = atlas
      assert %{id: "probe-customers", rows: [%{title: "Amelia Brooks"}]} = customers
    end

    test "the box lists the groups and walks them with the arrow keys", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin)
      search(view, "aurora")

      assert has_element?(view, "#{@box}-group-probe-products", "Products")
      assert has_element?(view, "#{@box}-group-probe-customers", "Amelia Brooks")
      refute has_element?(view, "#{@box}-group-probe-gated")
      refute has_element?(view, "#{@box}-group-probe-away")
      refute has_element?(view, "#{@box}-group-probe-empty")
      assert has_element?(view, "#{@box}-row-0[href='/admin/dashboard/settings?tab=general']")
      assert selected(view) == "#{@box}-row-0"

      assert has_element?(
               view,
               "#{@box} input[aria-activedescendant='#{@box |> String.trim_leading("#")}-row-0']"
             )

      view |> element("#{@box}-down") |> render_keydown(%{"key" => "ArrowDown"})
      assert selected(view) == "#{@box}-row-1"

      view |> element("#{@box}-up") |> render_keydown(%{"key" => "ArrowUp"})
      view |> element("#{@box}-up") |> render_keydown(%{"key" => "ArrowUp"})
      assert selected(view) == "#{@box}-row-2"

      view |> element("#{@box}-form") |> render_submit(%{"q" => "aurora"})
      assert {"/admin/dashboard", _flash} = assert_redirect(view)
    end

    test "Enter opens the first row, the one highlighted", %{conn: conn, admin: admin} do
      view = open(conn, admin)
      search(view, "aurora")

      view |> element("#{@box}-form") |> render_submit(%{"q" => "aurora"})
      assert {"/admin/dashboard/settings?tab=general", _flash} = assert_redirect(view)
    end

    test "Escape closes the list, and a query that finds nothing says so", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin)
      search(view, "aurora")
      assert has_element?(view, "#{@box}-results")

      view |> element("#{@box}-escape") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#{@box}-results")
      refute has_element?(view, "#{@box}-down")

      search(view, "none")
      assert has_element?(view, "#{@box}-empty", "none")
      refute has_element?(view, "#{@box}-down")
    end
  end

  describe "the phone's sheet" do
    setup do
      register(TopbarSearchProbe)
      :ok
    end

    test "is drawn through a portal outside the blurred top bar and lists what typing finds", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin)

      assert has_element?(view, "#admin-portals")
      refute has_element?(view, "header #admin-portals")
      refute has_element?(view, "#admin-portals[class*=backdrop]")

      assert has_element?(
               view,
               "header template#admin-topbar-search-sheet-portal[data-phx-portal='#admin-portals']"
             )

      sheet = view |> element("#{@box}-sheet-portal") |> render()
      assert sheet =~ ~s(id="admin-topbar-search-sheet")
      assert sheet =~ "fixed inset-0"
      refute sheet =~ "Aurora UI kit"

      view
      |> with_target(@box)
      |> render_change("search", %{"q" => "aurora"})

      render_async(view)

      sheet = view |> element("#{@box}-sheet-portal") |> render()
      assert sheet =~ ~s(id="admin-topbar-search-sheet-results")
      assert sheet =~ "Aurora UI kit"
      assert sheet =~ "Amelia Brooks"
      assert sheet =~ ~s(href="/admin/dashboard/settings?tab=general")
    end
  end

  defp search(view, query) do
    view |> element("#{@box}-form") |> render_change(%{"q" => query})
    render_async(view)
  end

  defp selected(view) do
    view
    |> element("#{@box}-results")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[aria-selected='true']")
    |> LazyHTML.attribute("id")
    |> then(fn [id] -> "#" <> id end)
  end

  defp register(plugin) do
    {:ok, _} =
      Event.write(%{
        name: plugin,
        event: "topbar:search",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("topbar:search", :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp context(user),
    do: %{current_user: user, current_site: nil, current_path: @settings, view: nil}

  defp build_conn_for(conn, user) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open(conn, user) do
    {:ok, view, _html} = conn |> build_conn_for(user) |> live(@settings)

    render_async(view)
    view
  end
end
