# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.AssetsControllerTest do
  @moduledoc """
  A site's compiled bundle at `/assets/css/<site>/<hash>.css`, and a lazy JS hook's module beside its
  script, as `MishkaCmsCoreWeb.AssetsController` serves them through this library's test router while the events it fires cannot run — one of their
  plugins is not loaded — so it is served, or refused, as it is with no plugin listening.

  `async: false` — `SiteState`, `AssetsState` and the compiled events are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
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

  defp fetch(site, path), do: fetch_from(build_conn(), site, path)

  defp fetch_from(conn, site, path) do
    conn
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

  describe "a lazy JS hook's module" do
    setup %{site: site} do
      other = create_site!(name: "other-#{site.name}", host: "other-#{site.host}", active: true)

      records =
        for {id, type, value, hash} <- [
              {site.name, "js", "BUNDLE", "current"},
              {site.name, JavaScriptCompiler.lazy_type("abc123"), "MODULE", "abc123"},
              {site.name, "brotli_" <> JavaScriptCompiler.lazy_type("abc123"), "BR", "abc123"},
              {site.name, "gzip_" <> JavaScriptCompiler.lazy_type("abc123"), "GZ", "abc123"},
              {other.name, "js", "OTHER_BUNDLE", "current"},
              {other.name, JavaScriptCompiler.lazy_type("def456"), "OTHER", "def456"}
            ],
            do: %{id: id, type: type, value: value, hash: hash, updated_at: DateTime.utc_now()}

      :ok = AssetsState.save_batch(records)

      on_exit(fn ->
        Enum.each(records, &AssetsState.delete(&1.id, &1.type))
      end)

      %{other: other}
    end

    test "is served beside the bundle, by its own hash, with the bundle's headers", %{site: site} do
      for {encoding, body, content_encoding} <- [
            {"br, gzip", "BR", ["br"]},
            {"gzip", "GZ", ["gzip"]},
            {"identity", "MODULE", []}
          ] do
        conn =
          build_conn()
          |> put_req_header("accept-encoding", encoding)
          |> fetch_from(site, "/assets/js/#{site.name}/abc123.js")

        assert conn.status == 200
        assert conn.resp_body == body
        assert get_resp_header(conn, "content-encoding") == content_encoding
        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "text/javascript"
        assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
        assert get_resp_header(conn, "set-cookie") == []
      end
    end

    test "is refused once its bundle no longer loads it, or when it is another site's", %{
      site: site,
      other: other
    } do
      for path <- [
            "/assets/js/#{site.name}/stale.js",
            "/assets/js/#{site.name}/def456.js",
            "/assets/js/#{other.name}/def456.js",
            "/assets/css/#{site.name}/abc123.css"
          ] do
        conn = fetch(site, path)

        assert conn.status == 404, path
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end
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
