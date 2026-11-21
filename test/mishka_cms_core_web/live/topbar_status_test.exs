# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TopbarStatusTest do
  @moduledoc """
  The status chip of the admin top bar on the `topbar:status` event
  (`MishkaCmsCore.Layouts.TopbarStatus`): no chip while no plugin answers, else one chip whose dot is
  the worst line's level and whose panel lists every line the viewer may see, worst first, each
  with its sentence and a link only when it stays in the app. Also the phone's search: an icon that
  opens a sheet over the screen with its own input, the same results, and a back arrow.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.TopbarStatus
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.TopbarStatusProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @event "topbar:status"

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

  test "the worst level of lines" do
    assert TopbarStatus.level([]) == nil
    assert TopbarStatus.level([%{level: :ok}, %{level: :warn}]) == :warn
    assert TopbarStatus.level([%{level: :warn}, %{level: :error}, %{level: :ok}]) == :error
  end

  describe "with no plugin answering" do
    test "no chip is drawn", %{conn: conn, admin: admin} do
      assert TopbarStatus.collect(context(admin)) == []
      refute has_element?(open(conn, admin), "#topbar-status")
    end
  end

  describe "with a plugin answering" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: TopbarStatusProbe,
          event: @event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(@event, :start, false)
      on_exit(fn -> Event.unregister(:name, TopbarStatusProbe, false) end)
    end

    test "collects the lines the viewer may see, worst first, a leaving link dropped", %{
      admin: admin
    } do
      lines = TopbarStatus.collect(context(admin))

      assert Enum.map(lines, & &1.id) == ["probe-warn", "probe-away", "probe-ok"]
      assert Enum.find(lines, &(&1.id == "probe-away")).link == nil
      assert Enum.find(lines, &(&1.id == "probe-warn")).link == @settings
    end

    test "refresh asks again from a page's socket, and leaves a socket of no admin page alone", %{
      admin: admin
    } do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: admin, current_path: @settings}
      }

      assert [%{id: "probe-warn"} | _rest] = TopbarStatus.refresh(socket).assigns.topbar_status

      bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assert TopbarStatus.refresh(bare) == bare
    end

    test "draws one chip with the worst dot and a panel of every line", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin)

      assert has_element?(view, "#topbar-status[data-level=warn]")
      assert has_element?(view, "#topbar-status-panel #topbar-status-line-probe-warn", "Sandbox")

      assert has_element?(
               view,
               "#topbar-status-line-probe-warn a[href='#{@settings}']",
               "Open"
             )

      refute has_element?(view, "#topbar-status-line-probe-away a")
      refute has_element?(view, "#topbar-status-line-probe-gated")
    end
  end

  describe "the phone's search" do
    test "is an icon that opens a sheet with its own input and a back arrow", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin)

      assert has_element?(
               view,
               "#admin-topbar-search-phone.size-11[aria-controls=admin-topbar-search-sheet]"
             )

      assert has_element?(
               view,
               "#admin-topbar-search-sheet[role=dialog] #admin-topbar-search-sheet-input"
             )

      assert has_element?(view, "#admin-topbar-search-sheet-close")

      view
      |> form("#admin-topbar-search-sheet-form", %{"q" => "zzz-nothing"})
      |> render_change()

      render_async(view)

      assert has_element?(
               view,
               "#admin-topbar-search-sheet-results #admin-topbar-search-sheet-empty"
             )
    end
  end

  defp context(user),
    do: %{current_user: user, current_site: nil, current_path: @settings, view: nil}

  defp open(conn, user) do
    session =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    {:ok, view, _html} = live(session, @settings)
    render_async(view)
    view
  end
end
