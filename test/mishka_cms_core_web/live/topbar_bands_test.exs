# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TopbarBandsTest do
  @moduledoc """
  The bands an extension draws under the admin top bar on the `topbar:bands` event
  (`MishkaCmsCore.Layouts.TopbarBands`): drawn only while a plugin answers, full width between the
  top bar and the page, in priority order, each one the viewer may see.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.TopbarBands
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.TopbarBandsProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @event "topbar:bands"

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
    test "nothing is drawn under the top bar", %{conn: conn, admin: admin} do
      assert TopbarBands.collect(context(admin)) == []

      view = open(conn, admin)
      refute has_element?(view, "#admin-topbar-bands")
    end
  end

  describe "with a plugin answering" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: TopbarBandsProbe,
          event: @event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(@event, :start, false)
      on_exit(fn -> Event.unregister(:name, TopbarBandsProbe, false) end)
    end

    test "collects the drawable bands the viewer may see, low priority first", %{admin: admin} do
      assert ["probe-component", "probe-function"] ==
               admin |> context() |> TopbarBands.collect() |> Enum.map(& &1.id)
    end

    test "draws them under the top bar and above the page, in priority order", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin)

      assert has_element?(view, "#admin-topbar-bands #probe-band-component")
      assert has_element?(view, "#admin-topbar-bands #probe-band-function", @settings)
      refute has_element?(view, "#topbar-band-probe-gated")
      refute has_element?(view, "#topbar-band-probe-bare")

      html = render(view)
      {header_at, _length} = :binary.match(html, "</header>")
      {band_at, _length} = :binary.match(html, ~s(id="admin-topbar-bands"))
      {main_at, _length} = :binary.match(html, "<main")
      assert header_at < band_at and band_at < main_at

      ids =
        view
        |> element("#admin-topbar-bands")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#admin-topbar-bands > div")
        |> LazyHTML.attribute("id")

      assert ids == ["topbar-band-probe-component", "topbar-band-probe-function"]
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
