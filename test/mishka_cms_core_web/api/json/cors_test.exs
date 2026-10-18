# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.CorsTest do
  @moduledoc """
  Which pages may read the JSON:API with the visitor's cookies, driven through the whole stack.

  A browser sends an `Origin` and the API answers `access-control-allow-origin` with
  `access-control-allow-credentials: true` for the ones it allows. An origin is a scheme, a host and
  a port, and the three have to match one the site allows: a page on another port or over plain
  `http` of an allowed host is not that site, and a cookie is kept apart by neither.

  The request goes through `MishkaCmsCore.TestEndpoint` and the `:api` pipeline of the test router —
  tenant lookup by `Host`, then `MishkaCmsCore.Runtime.Plugs.ApiCorsPlug` — against a site held in
  `SiteState` as the CMS holds it.
  """
  use MishkaCmsCore.ConnCase

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :integration
  @path "/api/json/v1/auth/user/me"

  setup do
    SiteState.clear()
    on_exit(fn -> SiteState.clear() end)

    site = create_site!(name: "cors-site", host: "cors.example.test", active: true, master: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master,
        mode: :hybrid,
        frontend_domain: "app.example.test:5173",
        allowed_origins: ["https://partner.example.test", "http://localhost:3000"]
      })

    %{site: site}
  end

  defp get_with_origin(site, origin) do
    make_api_request(@path, nil, method: "GET", host: site.host, headers: [{"origin", origin}])
  end

  defp allow_origin(conn), do: get_resp_header(conn, "access-control-allow-origin")

  test "answers an origin the site allows, with credentials", %{site: site} do
    for origin <- [
          "https://cors.example.test",
          "https://app.example.test:5173",
          "https://partner.example.test",
          "http://localhost:3000"
        ] do
      conn = get_with_origin(site, origin)

      assert allow_origin(conn) == [origin], origin
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end
  end

  test "answers a preflight from an allowed origin", %{site: site} do
    conn =
      make_api_request(@path, nil,
        method: "OPTIONS",
        host: site.host,
        headers: [{"origin", "https://partner.example.test"}]
      )

    assert conn.status == 204
    assert allow_origin(conn) == ["https://partner.example.test"]
    assert get_resp_header(conn, "access-control-allow-methods") != []
  end

  # THE FINDING: `http://site.com:9999` was answered for a site on `https://site.com`.
  test "gives another port or scheme of an allowed host nothing to read with", %{site: site} do
    for origin <- [
          "https://cors.example.test:9999",
          "http://cors.example.test",
          "http://cors.example.test:443",
          "https://app.example.test",
          "https://app.example.test:5174",
          "http://app.example.test:5173",
          "http://partner.example.test",
          "https://partner.example.test:8443",
          "http://localhost:3001",
          "https://localhost:3000",
          "null"
        ] do
      conn = get_with_origin(site, origin)

      assert allow_origin(conn) == [], "#{origin} was allowed"
      assert get_resp_header(conn, "access-control-allow-credentials") == [], origin
    end
  end

  test "answers a preflight from another port of an allowed host without the CORS headers", %{
    site: site
  } do
    conn =
      make_api_request(@path, nil,
        method: "OPTIONS",
        host: site.host,
        headers: [{"origin", "https://cors.example.test:9999"}]
      )

    assert conn.status == 204
    assert allow_origin(conn) == []
    assert get_resp_header(conn, "access-control-allow-methods") == []
  end
end
