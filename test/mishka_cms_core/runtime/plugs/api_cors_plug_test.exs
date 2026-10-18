# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ApiCorsPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
  @moduletag :unit

  describe "init/1" do
    test "returns the given options" do
      opts = [some: :option]
      assert ApiCorsPlug.init(opts) == opts
    end

    test "returns empty list when no options given" do
      assert ApiCorsPlug.init([]) == []
    end
  end

  describe "call/2 without origin header" do
    test "passes through connection unchanged when no origin header" do
      conn = conn(:get, "/api/test")

      result_conn = ApiCorsPlug.call(conn, [])

      assert result_conn == conn
      refute get_resp_header(result_conn, "access-control-allow-origin") != []
    end
  end

  describe "call/2 with OPTIONS preflight requests" do
    test "sets CORS headers for allowed origin on preflight request" do
      conn =
        conn(:options, "/api/test")
        |> put_req_header("origin", "https://example.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert result_conn.halted
      assert result_conn.status == 204

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://example.com"
             ]

      assert get_resp_header(result_conn, "access-control-allow-methods") == [
               "GET, POST, PUT, PATCH, DELETE, OPTIONS"
             ]

      assert get_resp_header(result_conn, "access-control-allow-headers") == [
               "Accept, Authorization, Content-Type, X-Requested-With, x-no-tenant"
             ]

      assert get_resp_header(result_conn, "access-control-max-age") == ["86400"]
      assert get_resp_header(result_conn, "access-control-allow-credentials") == ["true"]
    end

    test "denies preflight request for non-allowed origin" do
      conn =
        conn(:options, "/api/test")
        |> put_req_header("origin", "https://evil.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert result_conn.halted
      assert result_conn.status == 204
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "denies preflight when no current_site assigned" do
      conn =
        conn(:options, "/api/test")
        |> put_req_header("origin", "https://example.com")

      result_conn = ApiCorsPlug.call(conn, [])

      assert result_conn.halted
      assert result_conn.status == 204
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "denies preflight for phoenix_only mode" do
      conn =
        conn(:options, "/api/test")
        |> put_req_header("origin", "https://example.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :phoenix_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert result_conn.halted
      assert result_conn.status == 204
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end
  end

  describe "call/2 with regular requests" do
    test "sets CORS headers for allowed same-origin request" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://example.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://example.com"
             ]

      assert get_resp_header(result_conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "sets CORS headers for frontend_domain match" do
      conn =
        conn(:post, "/api/test")
        |> put_req_header("origin", "https://frontend.example.com")
        |> assign(:current_site, %{
          host: "api.example.com",
          mode: :hybrid,
          frontend_domain: "frontend.example.com",
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://frontend.example.com"
             ]
    end

    test "sets CORS headers for allowed_origins list match" do
      conn =
        conn(:put, "/api/test")
        |> put_req_header("origin", "https://partner.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: ["https://partner.com", "https://other.com"]
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://partner.com"
             ]
    end

    test "does not accept another port of the site's host" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "http://localhost:3000")
        |> assign(:current_site, %{
          host: "localhost",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "access-control-allow-credentials") == []
    end

    test "compares the port of an allowed origin" do
      site = %{
        host: "example.com",
        mode: :api_only,
        frontend_domain: nil,
        allowed_origins: ["http://localhost:4000"]
      }

      denied =
        conn(:get, "/api/test")
        |> put_req_header("origin", "http://localhost:3000")
        |> assign(:current_site, site)
        |> ApiCorsPlug.call([])

      assert get_resp_header(denied, "access-control-allow-origin") == []

      allowed =
        conn(:get, "/api/test")
        |> put_req_header("origin", "http://localhost:4000")
        |> assign(:current_site, site)
        |> ApiCorsPlug.call([])

      assert get_resp_header(allowed, "access-control-allow-origin") == ["http://localhost:4000"]
    end

    test "does not set CORS headers for non-allowed origin" do
      conn =
        conn(:delete, "/api/test")
        |> put_req_header("origin", "https://evil.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: "frontend.example.com",
          allowed_origins: ["https://partner.com"]
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "does not set CORS headers when no current_site" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://example.com")

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "does not set CORS headers for phoenix_only mode" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://example.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :phoenix_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end
  end

  describe "frontend_domain variations" do
    test "matches frontend_domain stored with protocol prefix" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://frontend.com")
        |> assign(:current_site, %{
          host: "api.com",
          mode: :api_only,
          # Frontend domain should be stored without protocol
          frontend_domain: "frontend.com",
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://frontend.com"
             ]
    end

    test "matches frontend_domain without protocol" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://frontend.com")
        |> assign(:current_site, %{
          host: "api.com",
          mode: :api_only,
          frontend_domain: "frontend.com",
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://frontend.com"
             ]
    end

    test "matches the port a bare frontend_domain writes, and no other" do
      site = %{
        host: "api.com",
        mode: :api_only,
        frontend_domain: "frontend.com:3000",
        allowed_origins: []
      }

      for {origin, allowed?} <- [
            {"https://frontend.com:3000", true},
            {"http://frontend.com:3000", false},
            {"http://frontend.com:8080", false},
            {"https://frontend.com", false}
          ] do
        conn =
          conn(:get, "/api/test")
          |> put_req_header("origin", origin)
          |> assign(:current_site, site)
          |> ApiCorsPlug.call([])

        assert get_resp_header(conn, "access-control-allow-origin") ==
                 if(allowed?, do: [origin], else: []),
               origin
      end
    end
  end

  describe "edge cases" do
    test "handles malformed origin gracefully" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "not-a-valid-origin")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "handles empty allowed_origins list" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://some-site.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "handles nil allowed_origins" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://some-site.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: nil
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "handles nil frontend_domain" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://frontend.com")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end
  end

  # THE ANSWER CARRIES `access-control-allow-credentials: true`, and a cookie is kept apart by neither
  # scheme nor port, so an origin is all three and has to match exactly.
  describe "an origin is a scheme, a host and a port" do
    defp answer(site, origin, method) do
      site = Map.merge(%{mode: :api_only, frontend_domain: nil, allowed_origins: []}, site)

      conn(method, "/api/test")
      |> put_req_header("origin", origin)
      |> assign(:current_site, site)
      |> ApiCorsPlug.call([])
    end

    defp allowed_header(site, origin, method \\ :get),
      do: site |> answer(origin, method) |> get_resp_header("access-control-allow-origin")

    test "the site's own host is allowed over https on the default port, and no other way" do
      site = %{host: "site.com"}

      assert allowed_header(site, "https://site.com") == ["https://site.com"]
      assert allowed_header(site, "https://site.com:443") == ["https://site.com"]

      for origin <- [
            "http://site.com",
            "https://site.com:9999",
            "http://site.com:9999",
            "https://site.com:80",
            "http://site.com:443",
            "https://sub.site.com",
            "https://evilsite.com",
            "https://site.com.evil.com"
          ] do
        assert allowed_header(site, origin) == [], "#{origin} was allowed for site.com"
      end
    end

    test "a refused origin gets no credentials header, on a preflight either" do
      site = %{host: "site.com"}

      for method <- [:get, :options] do
        conn = answer(site, "http://site.com:9999", method)

        assert get_resp_header(conn, "access-control-allow-origin") == []
        assert get_resp_header(conn, "access-control-allow-credentials") == []
        assert get_resp_header(conn, "access-control-allow-methods") == []
      end
    end

    test "a preflight from the wrong port is answered 204 without the CORS headers" do
      conn = answer(%{host: "site.com"}, "https://site.com:9999", :options)

      assert conn.halted
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "a loopback host is also allowed over plain http, which is how a site is developed" do
      for host <- ["localhost", "127.0.0.1"] do
        site = %{host: host}

        assert allowed_header(site, "http://#{host}") == ["http://#{host}"]
        assert allowed_header(site, "https://#{host}") == ["https://#{host}"]
        assert allowed_header(site, "http://#{host}:3000") == []
      end

      assert allowed_header(%{host: "site.com"}, "http://site.com") == []
    end

    test "an IPv6 loopback origin keeps its brackets" do
      site = %{host: "example.com", allowed_origins: ["http://[::1]:3000"]}

      assert allowed_header(site, "http://[::1]:3000") == ["http://[::1]:3000"]
      assert allowed_header(site, "http://[::1]:3001") == []
      assert allowed_header(site, "http://[::1]") == []
    end

    test "a frontend_domain written as an origin is compared as written" do
      site = %{host: "api.com", frontend_domain: "https://app.example.com:8443"}

      assert allowed_header(site, "https://app.example.com:8443") == [
               "https://app.example.com:8443"
             ]

      for origin <- [
            "https://app.example.com",
            "http://app.example.com:8443",
            "https://app.example.com:8444"
          ] do
        assert allowed_header(site, origin) == [], origin
      end
    end

    test "a bare frontend_domain is that domain over https on its default port" do
      site = %{host: "api.com", frontend_domain: "app.example.com"}

      assert allowed_header(site, "https://app.example.com") == ["https://app.example.com"]
      assert allowed_header(site, "http://app.example.com") == []
      assert allowed_header(site, "https://app.example.com:3000") == []
    end

    test "an allowed_origins entry is compared as written, its port being the scheme's own when not written" do
      site = %{host: "api.com", allowed_origins: ["https://partner.com", "http://other.com:8080"]}

      assert allowed_header(site, "https://partner.com") == ["https://partner.com"]
      assert allowed_header(site, "https://partner.com:443") == ["https://partner.com"]
      assert allowed_header(site, "http://other.com:8080") == ["http://other.com:8080"]

      for origin <- [
            "http://partner.com",
            "https://partner.com:8443",
            "https://other.com:8080",
            "http://other.com",
            "http://other.com:8081"
          ] do
        assert allowed_header(site, origin) == [], origin
      end
    end

    test "an entry with a trailing slash still allows its origin" do
      site = %{host: "api.com", allowed_origins: ["https://partner.com/"]}

      assert allowed_header(site, "https://partner.com") == ["https://partner.com"]
    end

    test "only a bare origin is read: no path, credentials, query or junk" do
      site = %{host: "site.com", allowed_origins: ["https://partner.com"]}

      for origin <- [
            "null",
            "",
            "   ",
            "https://site.com/",
            "https://site.com/path",
            "https://site.com?x=1",
            "https://site.com#x",
            "https://user@site.com",
            "https://user:pw@site.com",
            "https://site.com:abc",
            "https://site.com:",
            "https://site.com\n",
            "site.com",
            "//site.com",
            "ftp://site.com",
            "javascript://site.com",
            "https://",
            "https://partner.com/x"
          ] do
        assert allowed_header(site, origin) == [], inspect(origin)
      end
    end

    test "the answer is the origin as a browser writes it" do
      site = %{host: "site.com"}

      assert allowed_header(site, "HTTPS://SITE.COM") == ["https://site.com"]
      assert allowed_header(site, "https://site.com:443") == ["https://site.com"]
    end

    test "phoenix_only and a missing site stay closed whatever the origin" do
      assert allowed_header(%{host: "site.com", mode: :phoenix_only}, "https://site.com") == []

      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://site.com")
        |> ApiCorsPlug.call([])

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "a site with only the keys SiteState keeps is answered" do
      site = %{id: "x", name: "x", host: "site.com", mode: :hybrid}

      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "https://site.com")
        |> assign(:current_site, site)
        |> ApiCorsPlug.call([])

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://site.com"]
    end
  end
end
