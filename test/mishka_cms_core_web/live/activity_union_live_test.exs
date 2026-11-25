# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.ActivityUnionLiveTest do
  @moduledoc """
  The Activity page with a union source (`MishkaCmsCore.Activity.Behaviours.UnionSource`): a row
  draws its source's badge, a row the source announces with `changed/1` arrives without a reload
  (once for a burst, and only on the logs that may show its site), and the search keeps what the
  admin typed, tags and all, in the box, the URL and the read.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.Behaviours.UnionSource
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.ActivityUnionLive
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index
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

  describe "a union source's new rows" do
    test "arrive on the open log once the source says so, without a reload", %{
      conn: conn,
      master: master
    } do
      view = open(conn, master, @path)
      refute render(view) =~ "Order MS-9 paid"

      ActivityUnionLive.write("Order MS-9 paid")
      settle(view)
      refute render(view) =~ "Order MS-9 paid"

      UnionSource.changed(nil)
      settle(view)

      assert render(view) =~ "Order MS-9 paid"
    end

    test "a burst of them is one read, and the next change another", %{master: master} do
      socket = mounted(master)

      socket =
        Enum.reduce(1..3, socket, fn _change, acc ->
          {:noreply, next} = Index.handle_info({:activity_changed, nil}, acc)
          next
        end)

      assert_received :reread_activity
      refute_received :reread_activity

      {:noreply, read} = Index.handle_info(:reread_activity, socket)
      {:noreply, _next} = Index.handle_info({:activity_changed, nil}, read)

      assert_received :reread_activity
    end

    test "reach the logs that may show their site, and no other", %{site: site, master: master} do
      other = create_site!(name: "Shop", host: "shop.test", active: true)
      site_admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      :ok = UnionSource.subscribe(site_admin)
      UnionSource.changed(other.id)
      refute_received {:activity_changed, _site}

      UnionSource.changed(site.id)
      site_id = site.id
      assert_received {:activity_changed, ^site_id}
      refute_received {:activity_changed, _site}

      task =
        Task.async(fn ->
          :ok = UnionSource.subscribe(master)
          UnionSource.changed(other.id)
          UnionSource.changed(nil)
          collect([])
        end)

      assert Task.await(task) == [other.id, nil]
    end
  end

  describe "the search" do
    test "keeps the tags it was typed with, in the box, the URL and the read", %{
      conn: conn,
      master: master
    } do
      ActivityUnionLive.write("bold order")
      view = open(conn, master, @path)
      assert render(view) =~ "bold order"

      view |> element("form[phx-change=filter]") |> render_change(%{"search" => "<b>bold</b>"})
      path = assert_patch(view)
      settle(view)

      assert URI.decode_query(URI.parse(path).query)["activity_filter_search"] == "<b>bold</b>"
      assert search_box(view) == "<b>bold</b>"
      refute render(view) =~ "bold order"

      reloaded = open(conn, master, path)

      assert search_box(reloaded) == "<b>bold</b>"
      refute render(reloaded) =~ "bold order"
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

  defp collect(heard) do
    receive do
      {:activity_changed, site_id} -> collect([site_id | heard])
    after
      0 -> Enum.reverse(heard)
    end
  end

  defp search_box(view) do
    view
    |> element("form[phx-change=filter] input[name=search]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp mounted(user) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, current_user: user},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    {:ok, socket} = Index.mount(%{}, %{}, socket)
    socket
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

  # A change reaches the page as a message, the page asks itself for one read, and the table loads
  # it and the counts off the render path: a round trip for each, then the loads.
  defp settle(view) do
    render(view)
    render(view)
    render_async(view)
  end
end
