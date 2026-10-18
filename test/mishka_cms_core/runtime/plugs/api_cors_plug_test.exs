# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ApiCorsPlugTest do
  # `SiteState` is one set of tables for the whole node: the sites these tests answer for are held
  # there, the way the tenant lookup finds them, and put back as they were afterwards.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
  alias MishkaCmsCore.Runtime.States.SiteState
  @moduletag :unit

  setup do
    snapshot = SiteState.snapshot()
    SiteState.clear()
    on_exit(fn -> SiteState.restore(snapshot) end)
    :ok
  end

  # A site saved to `SiteState`, returned as `SiteState` hands it to the tenant lookup.
  defp site!(attrs) do
    id = "cors-#{System.unique_integer([:positive])}"

    attrs =
      Map.merge(
        %{
          id: id,
          name: id,
          priority: 0,
          active: true,
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        },
        Map.new(attrs)
      )

    :ok = SiteState.save(attrs)
    SiteState.get!(attrs.id)
  end

  defp request(method, origin, site) do
    conn = conn(method, "/api/test")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    conn = if site, do: assign(conn, :current_site, site), else: conn
    ApiCorsPlug.call(conn, [])
  end

  defp answer(site, origin, method \\ :get), do: request(method, origin, site!(site))

  defp allowed_header(site, origin, method \\ :get),
    do: site |> answer(origin, method) |> get_resp_header("access-control-allow-origin")

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
    test "sets no CORS headers, and still varies by Origin" do
      conn = conn(:get, "/api/test")

      result_conn = ApiCorsPlug.call(conn, [])

      refute result_conn.halted
      assert result_conn.status == nil
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "access-control-allow-credentials") == []
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "leaves an OPTIONS without an Origin to the router: it is not a preflight" do
      result_conn = request(:options, nil, site!(%{host: "example.com"}))

      refute result_conn.halted
      assert result_conn.status == nil
      assert get_resp_header(result_conn, "access-control-allow-methods") == []
    end
  end

  describe "call/2 with OPTIONS preflight requests" do
    test "sets CORS headers for allowed origin on preflight request" do
      result_conn = answer(%{host: "example.com"}, "https://example.com", :options)

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
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "denies preflight request for non-allowed origin" do
      result_conn = answer(%{host: "example.com"}, "https://evil.com", :options)

      assert result_conn.halted
      assert result_conn.status == 204
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "access-control-allow-methods") == []
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "denies preflight when no current_site assigned" do
      result_conn = request(:options, "https://example.com", nil)

      assert result_conn.halted
      assert result_conn.status == 204
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "denies preflight for phoenix_only mode" do
      result_conn =
        answer(%{host: "example.com", mode: :phoenix_only}, "https://example.com", :options)

      assert result_conn.halted
      assert result_conn.status == 204
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "access-control-allow-methods") == []
    end
  end

  describe "call/2 with regular requests" do
    test "sets CORS headers for allowed same-origin request" do
      result_conn = answer(%{host: "example.com"}, "https://example.com")

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://example.com"
             ]

      assert get_resp_header(result_conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "sets CORS headers for frontend_domain match" do
      site = %{host: "api.example.com", mode: :hybrid, frontend_domain: "frontend.example.com"}

      result_conn = answer(site, "https://frontend.example.com", :post)

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://frontend.example.com"
             ]
    end

    test "sets CORS headers for allowed_origins list match" do
      site = %{host: "example.com", allowed_origins: ["https://partner.com", "https://other.com"]}

      result_conn = answer(site, "https://partner.com", :put)

      refute result_conn.halted

      assert get_resp_header(result_conn, "access-control-allow-origin") == [
               "https://partner.com"
             ]
    end

    test "does not accept another port of the site's host" do
      result_conn = answer(%{host: "localhost"}, "http://localhost:3000")

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "access-control-allow-credentials") == []
    end

    test "compares the port of an allowed origin" do
      site = site!(%{host: "example.com", allowed_origins: ["http://localhost:4000"]})

      denied = request(:get, "http://localhost:3000", site)
      assert get_resp_header(denied, "access-control-allow-origin") == []

      allowed = request(:get, "http://localhost:4000", site)
      assert get_resp_header(allowed, "access-control-allow-origin") == ["http://localhost:4000"]
    end

    test "does not set CORS headers for non-allowed origin, and varies by Origin" do
      site = %{
        host: "example.com",
        frontend_domain: "frontend.example.com",
        allowed_origins: ["https://partner.com"]
      }

      result_conn = answer(site, "https://evil.com", :delete)

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "does not set CORS headers when no current_site" do
      result_conn = request(:get, "https://example.com", nil)

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
      assert get_resp_header(result_conn, "vary") == ["Origin"]
    end

    test "does not set CORS headers for phoenix_only mode" do
      result_conn = answer(%{host: "example.com", mode: :phoenix_only}, "https://example.com")

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end
  end

  describe "frontend_domain variations" do
    test "matches frontend_domain without protocol" do
      site = %{host: "api.com", frontend_domain: "frontend.com"}

      assert allowed_header(site, "https://frontend.com") == ["https://frontend.com"]
    end

    test "matches the port a bare frontend_domain writes, and no other" do
      site = site!(%{host: "api.com", frontend_domain: "frontend.com:3000"})

      for {origin, allowed?} <- [
            {"https://frontend.com:3000", true},
            {"http://frontend.com:3000", false},
            {"http://frontend.com:8080", false},
            {"https://frontend.com", false}
          ] do
        conn = request(:get, origin, site)

        assert get_resp_header(conn, "access-control-allow-origin") ==
                 if(allowed?, do: [origin], else: []),
               origin
      end
    end
  end

  describe "edge cases" do
    test "handles malformed origin gracefully" do
      result_conn = answer(%{host: "example.com"}, "not-a-valid-origin")

      refute result_conn.halted
      assert get_resp_header(result_conn, "access-control-allow-origin") == []
    end

    test "handles empty allowed_origins list" do
      assert allowed_header(%{host: "example.com"}, "https://some-site.com") == []
    end

    test "handles nil allowed_origins" do
      assert allowed_header(%{host: "example.com", allowed_origins: nil}, "https://some-site.com") ==
               []
    end

    test "handles nil frontend_domain" do
      assert allowed_header(%{host: "example.com"}, "https://frontend.com") == []
    end
  end

  # THE ANSWER CARRIES `access-control-allow-credentials: true`, and a cookie is kept apart by neither
  # scheme nor port, so an origin is all three and has to match exactly.
  describe "an origin is a scheme, a host and a port" do
    test "the site's own host is allowed over https on the default port, and no other way" do
      site = site!(%{host: "site.com"})

      assert get_resp_header(
               request(:get, "https://site.com", site),
               "access-control-allow-origin"
             ) ==
               ["https://site.com"]

      assert get_resp_header(
               request(:get, "https://site.com:443", site),
               "access-control-allow-origin"
             ) == ["https://site.com"]

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
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [],
               "#{origin} was allowed for site.com"
      end
    end

    test "a refused origin gets no credentials header, on a preflight either" do
      site = site!(%{host: "site.com"})

      for method <- [:get, :options] do
        conn = request(method, "http://site.com:9999", site)

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
        site = site!(%{host: host})

        assert get_resp_header(
                 request(:get, "http://#{host}", site),
                 "access-control-allow-origin"
               ) ==
                 ["http://#{host}"]

        assert get_resp_header(
                 request(:get, "https://#{host}", site),
                 "access-control-allow-origin"
               ) == ["https://#{host}"]

        assert get_resp_header(
                 request(:get, "http://#{host}:3000", site),
                 "access-control-allow-origin"
               ) == []
      end

      assert allowed_header(%{host: "site.com"}, "http://site.com") == []
    end

    # RFC 6761 reserves `.localhost` for this machine; the dev seed sites are `site-a.localhost` and
    # `site-b.localhost`.
    test "a name under .localhost is loopback too, and a name that only contains it is not" do
      for host <- ["site-a.localhost", "site-b.localhost"] do
        site = site!(%{host: host})

        for {origin, answer} <- [
              {"http://#{host}", ["http://#{host}"]},
              {"https://#{host}", ["https://#{host}"]},
              {"http://#{host}:3000", []}
            ] do
          assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") ==
                   answer,
                 origin
        end
      end

      for host <- ["evil-localhost.com", "localhost.evil.com"] do
        site = site!(%{host: host})
        fronted = site!(%{host: "api." <> host, frontend_domain: host})

        assert get_resp_header(
                 request(:get, "http://#{host}", site),
                 "access-control-allow-origin"
               ) ==
                 [],
               host

        assert get_resp_header(
                 request(:get, "https://#{host}", site),
                 "access-control-allow-origin"
               ) == ["https://#{host}"],
               host

        assert get_resp_header(
                 request(:get, "http://#{host}", fronted),
                 "access-control-allow-origin"
               ) == [],
               host
      end
    end

    test "a bare loopback frontend_domain allows http on the port it writes" do
      site = site!(%{host: "api.com", frontend_domain: "localhost:5173"})

      for origin <- ["http://localhost:5173", "https://localhost:5173"] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [
                 origin
               ]
      end

      assert get_resp_header(
               request(:get, "http://localhost:5174", site),
               "access-control-allow-origin"
             ) == []
    end

    # Compiled only with `:env_dev?`; the suite sets `:env_test?` alone and sees the strict rules.
    test "no loopback origin is allowed beyond what the site writes, outside development" do
      site = site!(%{host: "new.mishka.tools", mode: :hybrid})

      for origin <- [
            "http://localhost:3000",
            "http://localhost:5173",
            "https://localhost:4000",
            "http://site-a.localhost:4000",
            "http://127.0.0.1:3000",
            "http://[::1]:3000"
          ] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [],
               origin
      end
    end

    test "an IPv6 loopback origin keeps its brackets" do
      site = site!(%{host: "example.com", allowed_origins: ["http://[::1]:3000"]})

      assert get_resp_header(
               request(:get, "http://[::1]:3000", site),
               "access-control-allow-origin"
             ) == ["http://[::1]:3000"]

      for origin <- ["http://[::1]:3001", "http://[::1]"] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == []
      end
    end

    test "a frontend_domain written as an origin is compared as written" do
      site = site!(%{host: "api.com", frontend_domain: "https://app.example.com:8443"})

      assert get_resp_header(
               request(:get, "https://app.example.com:8443", site),
               "access-control-allow-origin"
             ) == ["https://app.example.com:8443"]

      for origin <- [
            "https://app.example.com",
            "http://app.example.com:8443",
            "https://app.example.com:8444"
          ] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [],
               origin
      end
    end

    test "a bare frontend_domain is that domain over https on its default port" do
      site = site!(%{host: "api.com", frontend_domain: "app.example.com"})

      assert get_resp_header(
               request(:get, "https://app.example.com", site),
               "access-control-allow-origin"
             ) == ["https://app.example.com"]

      for origin <- ["http://app.example.com", "https://app.example.com:3000"] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == []
      end
    end

    test "an allowed_origins entry is compared as written, its port being the scheme's own when not written" do
      site =
        site!(%{
          host: "api.com",
          allowed_origins: ["https://partner.com", "http://other.com:8080"]
        })

      for {origin, answer} <- [
            {"https://partner.com", "https://partner.com"},
            {"https://partner.com:443", "https://partner.com"},
            {"http://other.com:8080", "http://other.com:8080"}
          ] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [
                 answer
               ]
      end

      for origin <- [
            "http://partner.com",
            "https://partner.com:8443",
            "https://other.com:8080",
            "http://other.com",
            "http://other.com:8081"
          ] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [],
               origin
      end
    end

    test "an entry with a trailing slash still allows its origin" do
      site = %{host: "api.com", allowed_origins: ["https://partner.com/"]}

      assert allowed_header(site, "https://partner.com") == ["https://partner.com"]
    end

    test "only a bare origin is read: no path, credentials, query or junk" do
      site = site!(%{host: "site.com", allowed_origins: ["https://partner.com"]})

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
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [],
               inspect(origin)
      end
    end

    test "the answer is the origin as a browser writes it" do
      site = site!(%{host: "site.com"})

      for origin <- ["HTTPS://SITE.COM", "https://site.com:443", "https://Site.Com"] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [
                 "https://site.com"
               ]
      end
    end

    # Plug refuses a header value with a line break in it, so what is echoed must be no more than
    # the origin the site wrote, read the same way.
    test "a host no host name can hold is never echoed, even when the site wrote it" do
      site = site!(%{host: "api.com", allowed_origins: ["https://a b.com", "https://%61.com"]})

      for origin <- ["https://a b.com", "https://%61.com"] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == [],
               origin
      end
    end

    test "a request with more than one Origin header is no browser's and gets nothing" do
      site = site!(%{host: "site.com"})

      for method <- [:get, :options] do
        conn =
          conn(method, "/api/test")
          |> Map.update!(:req_headers, fn headers ->
            [{"origin", "https://site.com"}, {"origin", "https://evil.com"} | headers]
          end)
          |> assign(:current_site, site)
          |> ApiCorsPlug.call([])

        assert get_resp_header(conn, "access-control-allow-origin") == []
        assert get_resp_header(conn, "access-control-allow-credentials") == []
        assert get_resp_header(conn, "vary") == ["Origin"]
      end
    end

    test "phoenix_only and a missing site stay closed whatever the origin" do
      assert allowed_header(%{host: "site.com", mode: :phoenix_only}, "https://site.com") == []

      assert request(:get, "https://site.com", nil)
             |> get_resp_header("access-control-allow-origin") == []
    end

    test "a site that SiteState does not hold answers nothing" do
      unsaved = %{id: "never-saved", name: "x", host: "site.com", mode: :hybrid}
      no_id = %{name: "x", host: "site.com", mode: :hybrid}

      for site <- [unsaved, no_id] do
        conn = request(:get, "https://site.com", site)
        assert get_resp_header(conn, "access-control-allow-origin") == [], inspect(site)
      end
    end

    test "the :site option answers for the site it names" do
      site = site!(%{host: "site.com"})

      conn =
        conn(:options, "/api/test")
        |> put_req_header("origin", "https://site.com")
        |> ApiCorsPlug.call(site: site)

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://site.com"]
    end
  end

  # A SITE IS EDITED WHILE THE SERVER RUNS: what it allows is read from `SiteState` on each request,
  # not from the copy of the site a request holds.
  describe "a site changed at runtime" do
    test "after an edit the old origin is refused and the new one allowed" do
      site = site!(%{host: "api.com", allowed_origins: ["https://old.example.com"]})

      assert get_resp_header(
               request(:get, "https://old.example.com", site),
               "access-control-allow-origin"
             ) == ["https://old.example.com"]

      :ok = SiteState.save(%{site | allowed_origins: ["https://new.example.com"]})

      assert get_resp_header(
               request(:get, "https://old.example.com", site),
               "access-control-allow-origin"
             ) == []

      assert get_resp_header(
               request(:get, "https://new.example.com", site),
               "access-control-allow-origin"
             ) == ["https://new.example.com"]
    end

    test "a deleted site answers no origin, even to a request that still holds it" do
      site = site!(%{host: "api.com", allowed_origins: ["https://partner.com"]})
      :ok = SiteState.delete(site.id)

      for origin <- ["https://api.com", "https://partner.com"] do
        assert get_resp_header(request(:get, origin, site), "access-control-allow-origin") == []
      end
    end
  end

  # A CACHE KEEPS ONE ANSWER PER `vary`: an answer for one origin, or for none, served to another
  # carries the wrong `access-control-allow-origin`.
  describe "vary" do
    defp with_vary(method, origin, site, values) do
      conn(method, "/api/test")
      |> put_req_header("origin", origin)
      |> Map.update!(:resp_headers, &(Enum.map(values, fn value -> {"vary", value} end) ++ &1))
      |> assign(:current_site, site)
      |> ApiCorsPlug.call([])
    end

    test "Origin is merged into the vary already set, on an allowed, a refused and a preflight answer" do
      site = site!(%{host: "site.com"})

      for {method, origin} <- [
            {:get, "https://site.com"},
            {:get, "https://evil.com"},
            {:options, "https://site.com"},
            {:options, "https://evil.com"}
          ] do
        conn = with_vary(method, origin, site, ["Accept-Encoding"])

        assert get_resp_header(conn, "vary") == ["Accept-Encoding, Origin"], "#{method} #{origin}"
      end
    end

    test "Origin is written once, whatever its case, and several vary headers become one" do
      site = site!(%{host: "site.com"})

      assert with_vary(:get, "https://site.com", site, ["origin"]) |> get_resp_header("vary") ==
               ["origin"]

      assert with_vary(:get, "https://site.com", site, ["Accept, ORIGIN", "Accept-Encoding"])
             |> get_resp_header("vary") == ["Accept, ORIGIN, Accept-Encoding"]

      assert with_vary(:get, "https://site.com", site, ["Accept", "Accept-Encoding"])
             |> get_resp_header("vary") == ["Accept, Accept-Encoding, Origin"]
    end

    test "a vary of * stays *" do
      site = site!(%{host: "site.com"})

      assert with_vary(:get, "https://site.com", site, ["*"]) |> get_resp_header("vary") == ["*"]
    end

    test "a vary a later plug sets still carries Origin when the response is sent" do
      site = site!(%{host: "site.com"})

      for origin <- ["https://site.com", "https://evil.com"] do
        conn =
          request(:get, origin, site)
          |> put_resp_header("vary", "Accept-Encoding")
          |> send_resp(200, "")

        assert get_resp_header(conn, "vary") == ["Accept-Encoding, Origin"], origin
      end
    end
  end
end
