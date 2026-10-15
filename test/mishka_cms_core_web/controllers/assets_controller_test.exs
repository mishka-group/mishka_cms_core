defmodule MishkaCmsCoreWeb.AssetsControllerTest do
  @moduledoc """
  A site's compiled bundle at `/assets/css/<site>/<hash>.css`, as `MishkaCmsCoreWeb.AssetsController`
  serves it through this library's test router while the events it fires cannot run — one of their
  plugins is not loaded — so it is served, or refused, as it is with no plugin listening.

  `async: false` — `SiteState`, `AssetsState` and the compiled events are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Test.EventCannotRun

  @css "body{color:red}"

  setup do
    host = "assets-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    :ok =
      AssetsState.save(%{
        id: site.name,
        type: "css",
        value: @css,
        hash: "current",
        updated_at: DateTime.utc_now()
      })

    on_exit(fn ->
      SiteState.delete(site.id)
      AssetsState.delete(site.name, "css")
    end)

    %{site: site}
  end

  defp fetch(site, path) do
    build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])
    |> get(path)
  end

  test "a site's bundle is served while the Serve events cannot run", %{site: site} do
    EventCannotRun.stub!([
      "AssetsController.Serve.BeforeServe",
      "AssetsController.Serve.BeforeAssetLookup",
      "AssetsController.Serve.AfterAssetLookup",
      "AssetsController.Serve.BeforeResponse"
    ])

    conn = fetch(site, "/assets/css/#{site.name}/current.css")

    assert conn.status == 200
    assert conn.resp_body == @css
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/css"
  end

  test "a site's bundle is kept a year by any cache, and sends no session cookie", %{site: site} do
    conn = fetch(site, "/assets/css/#{site.name}/current.css")

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "set-cookie") == []

    refused = fetch(site, "/assets/css/#{site.name}/stale.css")

    assert refused.status == 404
    assert get_resp_header(refused, "set-cookie") == []
  end

  test "a hash that is not the bundle's is refused while web:request:asset_unavailable cannot run",
       %{site: site} do
    EventCannotRun.stub!("web:request:asset_unavailable")

    conn = fetch(site, "/assets/css/#{site.name}/stale.css")

    assert conn.status == 404
    assert conn.resp_body == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
