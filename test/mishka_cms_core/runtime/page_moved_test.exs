# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageMovedTest do
  @moduledoc """
  `runtime:page:moved`: an address no redirect rule names, resolved to a page whose kind of record
  moves, is asked of the plugins, and an answer is served as a stored rule's: a 301 with its
  `location` from `SiteLookupPlug`, the same answer from `Redirects.lookup/3` for a live navigation,
  and `web:request:redirected` heard first. A page of a kind that does not move never asks.
  """
  use MishkaCmsCore.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Runtime.{Redirect, Redirects}
  alias MishkaCmsCore.Runtime.States.{RedirectsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Test.Plugins.{MovingRecords, PageMoved, WebRedirected}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "moving-#{n}", host: "moving-#{n}.test", active: true)

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    Process.register(self(), :__plugin_hook_probe__)
    start_plugin!(MovingRecords, "runtime:page:records")
    start_plugin!(PageMoved, Redirects.moved_event())

    on_exit(fn ->
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.delete(site.id)
    end)

    {:ok, site: site}
  end

  defp start_plugin!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp page!(site, id, path, record) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: id,
        site: site.name,
        path: path,
        title: id,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0,
        record: record
      })
  end

  defp request(path, host) do
    conn(:get, path)
    |> Map.put(:req_headers, [{"host", host}])
    |> init_test_session(%{})
    |> fetch_query_params()
    |> SiteLookupPlug.call(SiteLookupPlug.init([]))
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  test "a plugin's answer is a real redirect from the plug, with the request's query", %{
    site: site
  } do
    page!(site, "post", "/posts/:slug", "test:moving")

    conn = request("/posts/old-post?ref=mail", site.host)

    assert conn.halted
    assert conn.status == 301
    assert location(conn) == "/posts/new-post?ref=mail"
    assert get_session(conn, :current_site) == nil

    assert_receive {:moved, "test:moving", %{"slug" => "old-post"}, "/posts/old-post"}
    assert request("/posts/temporary", site.host).status == 302
  end

  test "a live navigation is answered the same way", %{site: site} do
    page!(site, "post", "/posts/:slug", "test:moving")

    assert Redirects.lookup(site.id, "/posts/old-post", "") == {:redirect, "/posts/new-post", 301}
    assert Redirects.lookup(site.id, "/posts/kept", "") == nil
  end

  test "a record that stays, an answer at its own address and an unsafe one let the page answer",
       %{site: site} do
    page!(site, "post", "/posts/:slug", "test:moving")

    for path <- ["/posts/kept", "/posts/same", "/posts/elsewhere"] do
      conn = request(path, site.host)
      refute conn.halted, "#{path} was redirected"
    end
  end

  test "a page whose kind does not move, or that shows no record, never asks", %{site: site} do
    page!(site, "still", "/still/:slug", "test:still")
    page!(site, "plain", "/plain/:slug", nil)

    refute request("/still/old-post", site.host).halted
    refute request("/plain/old-post", site.host).halted
    refute_received {:moved, _record, _params, _path}
  end

  test "an address no page answers asks nothing, and a stored rule answers first", %{site: site} do
    page!(site, "post", "/posts/:slug", "test:moving")

    refute request("/nowhere/old-post", site.host).halted
    refute_received {:records, _site_id}

    Ash.create!(Redirect, %{from_path: "/posts/old-post", to: "/rule"},
      action: :create,
      tenant: site.id,
      authorize?: false
    )

    _handled = :sys.get_state(RedirectsState)

    assert location(request("/posts/old-post", site.host)) == "/rule"
    refute_received {:moved, _record, _params, _path}
  end

  test "the kinds are asked with no site, so no provider reads its samples", %{site: site} do
    page!(site, "post", "/posts/:slug", "test:moving")

    request("/posts/old-post", site.host)

    assert_receive {:records, nil}
    refute_received {:records, _site_id}
  end

  test "web:request:redirected hears the answer first", %{site: site} do
    start_plugin!(WebRedirected, "web:request:redirected")
    page!(site, "post", "/posts/:slug", "test:moving")

    assert location(request("/posts/old-post", site.host)) == "/chosen-by-a-plugin"
    assert_receive {:redirected, _site_id, "/posts/old-post", {:redirect, "/posts/new-post", 301}}
  end

  test "costs no query", %{site: site} do
    page!(site, "post", "/posts/:slug", "test:moving")
    page!(site, "still", "/still/:slug", "test:still")

    handler = "page-moved-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:mishka_cms_core, :repo, :query],
      fn _event, _measurements, meta, _config -> send(test, {handler, meta[:query]}) end,
      nil
    )

    try do
      assert {:redirect, _to, 301} = Redirects.lookup(site.id, "/posts/old-post", "")
      assert Redirects.lookup(site.id, "/still/old-post", "") == nil
    after
      :telemetry.detach(handler)
    end

    refute_received {^handler, _query}
  end
end
