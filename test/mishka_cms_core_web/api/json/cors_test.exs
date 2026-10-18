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
  `SiteState` as the CMS holds it. A site created, edited or archived through
  `MishkaCmsCore.Runtime.Site` reaches `SiteState` the way it does while the CMS runs, and is answered
  for what it allows now.
  """
  use MishkaCmsCore.ConnCase

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.OriginValidator
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
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "varies by Origin on an allowed, a refused and a preflight answer", %{site: site} do
    for {method, origin} <- [
          {"GET", "https://partner.example.test"},
          {"GET", "https://evil.example.test"},
          {"OPTIONS", "https://partner.example.test"},
          {"OPTIONS", "https://evil.example.test"}
        ] do
      conn =
        make_api_request(@path, nil,
          method: method,
          host: site.host,
          headers: [{"origin", origin}]
        )

      assert get_resp_header(conn, "vary") == ["Origin"], "#{method} #{origin}"
    end
  end

  describe "a site changed while the server runs" do
    setup do
      %{master: create_user_with_permissions!(["admin:dashboard:runtime:site"])}
    end

    defp site_update!(site, action, params, master) do
      site
      |> Ash.Changeset.for_update(action, params, actor: master)
      |> Ash.update!()
    end

    test "a site created through the resource answers its allowed origin at once" do
      site =
        create_site!(
          name: "runtime-cors",
          host: "runtime-cors.example.test",
          frontend_domain: "app.runtime-cors.example.test",
          allowed_origins: ["https://partner.runtime-cors.example.test"]
        )

      for origin <- [
            "https://runtime-cors.example.test",
            "https://app.runtime-cors.example.test",
            "https://partner.runtime-cors.example.test"
          ] do
        conn = get_with_origin(site, origin)

        assert allow_origin(conn) == [origin], origin
        assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      end

      assert get_with_origin(site, "http://partner.runtime-cors.example.test") |> allow_origin() ==
               []
    end

    test "after its allowed_origins are edited, the old origin is refused and the new one allowed",
         %{master: master} do
      site =
        create_site!(
          name: "edited-cors",
          host: "edited-cors.example.test",
          allowed_origins: ["https://old.edited-cors.example.test"]
        )

      assert get_with_origin(site, "https://old.edited-cors.example.test") |> allow_origin() ==
               ["https://old.edited-cors.example.test"]

      site =
        site_update!(
          site,
          :update,
          %{allowed_origins: ["https://new.edited-cors.example.test"]},
          master
        )

      assert get_with_origin(site, "https://old.edited-cors.example.test") |> allow_origin() == []

      assert get_with_origin(site, "https://new.edited-cors.example.test") |> allow_origin() ==
               ["https://new.edited-cors.example.test"]

      preflight =
        make_api_request(@path, nil,
          method: "OPTIONS",
          host: site.host,
          headers: [{"origin", "https://old.edited-cors.example.test"}]
        )

      assert preflight.status == 204
      assert allow_origin(preflight) == []
    end

    test "a switched-off site still answers its allowed origin on the refusal", %{master: master} do
      site =
        create_site!(
          name: "off-cors",
          host: "off-cors.example.test",
          allowed_origins: ["https://app.off-cors.example.test"]
        )

      site_update!(site, :deactivate, %{}, master)

      conn = get_with_origin(site, "https://app.off-cors.example.test")

      assert conn.status == 503
      assert allow_origin(conn) == ["https://app.off-cors.example.test"]
      assert get_resp_header(conn, "vary") == ["Origin"]

      assert get_with_origin(site, "https://evil.example.test") |> allow_origin() == []
    end

    test "an archived site's origins are gone", %{master: master} do
      site =
        create_site!(
          name: "archived-cors",
          host: "archived-cors.example.test",
          allowed_origins: ["https://app.archived-cors.example.test"]
        )

      {:ok, origin} = OriginValidator.request_origin("https://app.archived-cors.example.test")
      assert SiteState.allows_origin?(site.id, origin)

      :ok = site |> Ash.Changeset.for_destroy(:destroy, %{}, actor: master) |> Ash.destroy!()

      refute SiteState.allows_origin?(site.id, origin)

      conn = get_with_origin(site, "https://app.archived-cors.example.test")

      assert conn.status == 404
      assert allow_origin(conn) == []
    end
  end
end
