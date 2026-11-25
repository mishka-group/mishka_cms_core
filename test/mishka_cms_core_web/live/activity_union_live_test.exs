# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.ActivityUnionLiveTest do
  @moduledoc """
  The Activity page with a union source (`MishkaCmsCore.Activity.Behaviours.UnionSource`): a row
  draws its source's badge.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.ActivityUnionLive
  alias MishkaInstaller.Event.{Event, EventHandler}

  @path "/admin/dashboard/runtime/activity"
  @event "activity:sources"

  setup do
    SiteState.clear()

    site =
      save_site!(create_site!(name: "localhost", host: "localhost", active: true, master: true))

    :persistent_term.put(:mishka_installed, true)

    {:ok, _} =
      Event.write(%{
        name: ActivityUnionLive,
        event: @event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(@event, :start, false)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      ActivityUnionLive.write(nil)
      Event.unregister(:name, ActivityUnionLive, false)
    end)

    {:ok, site: site, master: create_user_with_permissions!(["*"])}
  end

  describe "a union source's badge" do
    test "is drawn on its row, in its own words", %{conn: conn, master: master} do
      ActivityUnionLive.write("Order MS-9 paid")

      view = open(conn, master, @path)

      assert has_element?(view, "[data-role=entry-badge]", "MONEY")
    end
  end

  defp save_site!(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    site
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
