# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TopbarItemsTest do
  @moduledoc """
  The items an extension adds to the admin top bar on the `topbar:items` event
  (`MishkaCmsCore.Layouts.TopbarItems`): drawn only while a plugin answers, in priority order, each
  one the viewer may see; a plugin that raises leaves the top bar without items and the page open;
  and the plugins are asked when the page's path changes, not on every patch.
  """
  use MishkaCmsCore.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.TopbarItems
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.{TopbarItemsBroken, TopbarItemsProbe}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @event "topbar:items"

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
    {:ok, conn: conn, admin: admin, site: site}
  end

  describe "with no plugin answering" do
    test "the top bar is drawn as before, with no item slot", %{conn: conn, admin: admin} do
      assert TopbarItems.collect(context(admin)) == []

      view = open(conn, admin, @settings)
      assert has_element?(view, "header input[type=text]")
      refute has_element?(view, "#admin-topbar-items")
    end
  end

  describe "with a plugin answering" do
    setup do
      register(TopbarItemsProbe)

      handler = "topbar-items-probe-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        TopbarItemsProbe.called(),
        &__MODULE__.forward_call/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "collects the drawable items the viewer may see, low priority first", %{admin: admin} do
      assert ["probe-component", "probe-function"] ==
               admin |> context() |> TopbarItems.collect() |> Enum.map(& &1.id)
    end

    test "draws each item in the top bar with the page's context", %{
      conn: conn,
      admin: admin,
      site: site
    } do
      view = open(conn, admin, @settings)

      assert has_element?(
               view,
               "header #admin-topbar-items #probe-function-body",
               "Function item on #{@settings}"
             )

      assert has_element?(view, "header #admin-topbar-items #probe-component-body", site.name)

      assert has_element?(
               view,
               "#probe-component-body",
               inspect(MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive)
             )

      refute has_element?(view, "#topbar-item-probe-gated")
      refute has_element?(view, "#topbar-item-probe-bare")
    end

    test "the items are drawn in priority order", %{conn: conn, admin: admin} do
      view = open(conn, admin, @settings)

      ids =
        view
        |> element("#admin-topbar-items")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#admin-topbar-items > div")
        |> LazyHTML.attribute("id")

      assert ids == ["topbar-item-probe-component", "topbar-item-probe-function"]
    end

    test "a patch that keeps the path asks no plugin; a new page asks again", %{
      conn: conn,
      admin: admin
    } do
      view = open(conn, admin, @settings)
      assert_received {:topbar_items_called, @settings}
      flush_calls()

      render_patch(view, @settings <> "?tab=general")
      refute_received {:topbar_items_called, _path}

      {:ok, _home, _html} = live(build_session(conn, admin), "/admin/dashboard")
      assert_received {:topbar_items_called, "/admin/dashboard"}
    end
  end

  describe "with a plugin that raises" do
    setup do
      register(TopbarItemsBroken)
      :ok
    end

    test "the page opens and the top bar has no items", %{conn: conn, admin: admin} do
      log =
        capture_log(fn ->
          assert TopbarItems.collect(context(admin)) == []

          view = open(conn, admin, @settings)
          assert has_element?(view, "header input[type=text]")
          assert has_element?(view, "#settings-form")
          refute has_element?(view, "#admin-topbar-items")
        end)

      assert log =~ "topbar plugin is broken"
    end
  end

  @doc false
  def forward_call(_event, _measurements, %{path: path}, test_pid),
    do: send(test_pid, {:topbar_items_called, path})

  defp flush_calls do
    receive do
      {:topbar_items_called, _path} -> flush_calls()
    after
      0 -> :ok
    end
  end

  defp register(plugin) do
    {:ok, _} =
      Event.write(%{name: plugin, event: @event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(@event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp context(user),
    do: %{current_user: user, current_site: nil, current_path: @settings, view: nil}

  defp build_session(conn, user) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open(conn, user, path) do
    {:ok, view, _html} = conn |> build_session(user) |> live(path)
    render_async(view)
    view
  end
end
