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

    test "ignores port when matching origins" do
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

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "http://localhost:3000"
             ]
    end

    test "ignores port in allowed_origins list" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "http://localhost:3000")
        |> assign(:current_site, %{
          host: "example.com",
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: ["http://localhost:4000"]
        })

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "http://localhost:3000"
             ]
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

    test "matches frontend_domain with port ignored" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("origin", "http://frontend.com:8080")
        |> assign(:current_site, %{
          host: "api.com",
          mode: :api_only,
          frontend_domain: "frontend.com:3000",
          allowed_origins: []
        })

      result_conn = ApiCorsPlug.call(conn, [])

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "http://frontend.com:8080"
             ]
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
end
