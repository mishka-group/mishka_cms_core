# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SettingsPanelsTest do
  @moduledoc """
  The tabs an extension adds to the settings page on the `settings:panels` event
  (`MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels`): drawn only while a plugin answers,
  each in place of the settings form, and a panel that cannot be drawn or reuses a category's id
  is dropped.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.SettingsPanelsProbe
  alias MishkaCmsCoreWeb.Live.Admin.Components.SettingsPanels
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"

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
    test "no extension tab is drawn", %{conn: conn, admin: admin} do
      assert SettingsPanels.collect(admin) == []

      view = open(conn, admin, @settings)
      refute has_element?(view, "#tab-probe-component")
      assert has_element?(view, "#settings-form")
    end
  end

  describe "with a plugin answering" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: SettingsPanelsProbe,
          event: "settings:panels",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("settings:panels", :start, false)
      on_exit(fn -> Event.unregister(:name, SettingsPanelsProbe, false) end)
      :ok
    end

    test "collects the drawable panels, low priority first", %{admin: admin} do
      assert ["email", "probe-function", "probe-component"] ==
               Enum.map(SettingsPanels.collect(admin), & &1.id)

      assert ["probe-function", "probe-component"] ==
               admin |> SettingsPanels.collect(["email"]) |> Enum.map(& &1.id)
    end

    test "draws a function panel in place of the settings form", %{conn: conn, admin: admin} do
      view = open(conn, admin, @settings <> "?tab=probe-function")

      assert has_element?(view, "#tab-probe-function", "Probe function")
      assert has_element?(view, "#probe-function-body", admin.email |> to_string())
      refute has_element?(view, "#settings-form")
      refute has_element?(view, "#settings-save")
      refute has_element?(view, "#tab-probe-bare")
    end

    test "draws a LiveComponent panel", %{conn: conn, admin: admin} do
      view = open(conn, admin, @settings <> "?tab=probe-component")

      assert has_element?(view, "#probe-component-body")
      refute has_element?(view, "#settings-form")
    end

    test "a settings tab still shows its form, and the tab links switch", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin, @settings <> "?tab=probe-component")

      view |> element("#tab-probe-function") |> render_click()
      assert has_element?(view, "#probe-function-body")
      refute has_element?(view, "#probe-component-body")

      view = open(conn, admin, @settings)
      assert has_element?(view, "#tab-probe-component")
    end
  end

  defp open(conn, user, path) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(path)

    render_async(view)
    view
  end
end
