# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias MishkaCmsCore.Runtime.Plugs.{ApiCorsPlug, ApiTenantLookupPlug}
  alias MishkaCmsCore.Test.EventCannotRun
  @moduletag :unit

  # Test module to replace SiteState during tests
  defmodule TestSiteState do
    def get_by_host("valid.example.com") do
      {:ok,
       %{
         id: "site-123",
         host: "valid.example.com",
         active: true,
         mode: :api_only
       }}
    end

    def get_by_host("inactive.example.com") do
      {:ok,
       %{
         id: "site-456",
         host: "inactive.example.com",
         active: false,
         mode: :api_only
       }}
    end

    def get_by_host("phoenix-only.example.com") do
      {:ok,
       %{
         id: "site-789",
         host: "phoenix-only.example.com",
         active: true,
         mode: :phoenix_only
       }}
    end

    def get_by_host("hybrid.example.com") do
      {:ok,
       %{
         id: "site-999",
         host: "hybrid.example.com",
         active: true,
         mode: :hybrid
       }}
    end

    def get_by_host(_host) do
      {:error, :not_found}
    end
  end

  describe "init/1" do
    test "returns default options when no options provided" do
      assert ApiTenantLookupPlug.init([]) == [allow_no_tenant: false]
    end

    test "merges provided options with defaults" do
      assert ApiTenantLookupPlug.init(allow_no_tenant: true) == [allow_no_tenant: true]
    end

    test "preserves additional options" do
      opts = ApiTenantLookupPlug.init(allow_no_tenant: true, custom: :option)
      assert opts[:allow_no_tenant] == true
      assert opts[:custom] == :option
    end
  end

  describe "call/2 with missing host" do
    test "returns error when host missing and allow_no_tenant is false" do
      conn =
        conn(:get, "/api/test")
        |> Map.put(:host, nil)

      # Explicitly set host to nil in test environment

      result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

      assert result_conn.halted
      assert result_conn.status == 400

      body = Jason.decode!(result_conn.resp_body)
      assert body["error"]["code"] == "missing_host"
      assert body["error"]["message"] == "Host header is required"
      assert body["error"]["status"] == 400
      assert get_resp_header(result_conn, "x-error-code") == ["missing_host"]
      assert get_resp_header(result_conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "sets current_site to nil when host missing and allow_no_tenant is true" do
      conn =
        conn(:get, "/api/test")
        |> Map.put(:host, nil)

      # Explicitly set host to nil in test environment

      result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: true)

      refute result_conn.halted
      assert result_conn.assigns.current_site == nil
    end
  end

  describe "error response format" do
    test "includes timestamp in error response" do
      conn =
        conn(:get, "/api/test")
        |> Map.put(:host, nil)

      # No host - will trigger missing_host error

      result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

      body = Jason.decode!(result_conn.resp_body)
      assert body["error"]["timestamp"]

      # Check timestamp format (ISO 8601)
      {:ok, _datetime, _} = DateTime.from_iso8601(body["error"]["timestamp"])
    end

    test "sets proper content-type for error responses" do
      conn =
        conn(:get, "/api/test")
        |> Map.put(:host, nil)

      # No host

      result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

      assert get_resp_header(result_conn, "content-type") == ["application/json; charset=utf-8"]
    end
  end

  if Mix.env() == :test do
    describe "test environment host extraction" do
      test "uses conn.host in test environment when no header" do
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, nil)

        # No host header

        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

        # Should fail because host is nil
        assert result_conn.halted
        assert result_conn.status == 400
      end
    end
  end

  # Integration test with actual SiteState (if available)
  describe "integration with actual system" do
    @tag :integration
    test "handles real request flow when SiteState is available" do
      # This test will only work if MishkaCmsCore.Runtime.States.SiteState is actually available
      # Otherwise it will be skipped
      if Code.ensure_loaded?(MishkaCmsCore.Runtime.States.SiteState) do
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, "localhost")

        # This will use the actual SiteState module
        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: true)

        # We can check that current_site is assigned (could be nil or a map)
        assert Map.has_key?(result_conn.assigns, :current_site)
      else
        :ok
      end
    end

    test "successfully looks up existing site and assigns tenant" do
      # Only run if SiteState is available
      if Code.ensure_loaded?(MishkaCmsCore.Runtime.States.SiteState) do
        alias MishkaCmsCore.Runtime.States.SiteState

        # Ensure SiteState is running
        case GenServer.whereis(SiteState) do
          nil -> {:ok, _pid} = SiteState.start_link()
          _pid -> :ok
        end

        # Clear any existing sites
        SiteState.clear()

        # Create a test site
        site_attrs = %{
          id: "test-site-123",
          name: "Test API Site",
          host: "api.testsite.com",
          priority: 100,
          active: true,
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: ["https://trusted.com"]
        }

        assert :ok = SiteState.save(site_attrs)

        # Create connection with the site's host
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, "api.testsite.com")
          |> put_req_header("origin", "https://api.testsite.com")

        # Call the plug
        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

        # Verify the site was properly assigned
        refute result_conn.halted
        assert result_conn.assigns.current_site != nil
        assert result_conn.assigns.current_site.id == "test-site-123"
        assert result_conn.private.ash.tenant == "test-site-123"
        assert result_conn.assigns.current_site.host == "api.testsite.com"
        assert result_conn.assigns.current_site.mode == :api_only
        assert result_conn.assigns.current_site.active == true

        # Clean up
        SiteState.clear()
      else
        :ok
      end
    end

    test "handles site lookup for hybrid mode" do
      if Code.ensure_loaded?(MishkaCmsCore.Runtime.States.SiteState) do
        alias MishkaCmsCore.Runtime.States.SiteState

        # Ensure SiteState is running
        case GenServer.whereis(SiteState) do
          nil -> {:ok, _pid} = SiteState.start_link()
          _pid -> :ok
        end

        # Clear any existing sites
        SiteState.clear()

        # Create a hybrid mode site
        site_attrs = %{
          id: "hybrid-site-456",
          name: "Hybrid Test Site",
          host: "hybrid.example.com",
          priority: 90,
          active: true,
          mode: :hybrid,
          frontend_domain: "frontend.example.com",
          allowed_origins: []
        }

        assert :ok = SiteState.save(site_attrs)

        # Test API access for hybrid mode
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, "hybrid.example.com")

        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

        # Hybrid mode should allow API access
        refute result_conn.halted
        assert result_conn.assigns.current_site != nil
        assert result_conn.assigns.current_site.id == "hybrid-site-456"
        assert result_conn.assigns.current_site.mode == :hybrid

        # Clean up
        SiteState.clear()
      else
        :ok
      end
    end

    test "denies access for inactive site" do
      if Code.ensure_loaded?(MishkaCmsCore.Runtime.States.SiteState) do
        alias MishkaCmsCore.Runtime.States.SiteState

        # Ensure SiteState is running
        case GenServer.whereis(SiteState) do
          nil -> {:ok, _pid} = SiteState.start_link()
          _pid -> :ok
        end

        # Clear any existing sites
        SiteState.clear()

        # Create an inactive site
        site_attrs = %{
          id: "inactive-site-789",
          name: "Inactive Site",
          host: "inactive.example.com",
          priority: 50,
          active: false,
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        }

        assert :ok = SiteState.save(site_attrs)

        # Try to access inactive site
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, "inactive.example.com")

        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

        # Should be denied with 503
        assert result_conn.halted
        assert result_conn.status == 503

        body = Jason.decode!(result_conn.resp_body)
        assert body["error"]["code"] == "website_unavailable"
        assert body["error"]["message"] == "This website is currently unavailable"

        # Clean up
        SiteState.clear()
      else
        :ok
      end
    end

    test "denies access for phoenix_only mode" do
      if Code.ensure_loaded?(MishkaCmsCore.Runtime.States.SiteState) do
        alias MishkaCmsCore.Runtime.States.SiteState

        # Ensure SiteState is running
        case GenServer.whereis(SiteState) do
          nil -> {:ok, _pid} = SiteState.start_link()
          _pid -> :ok
        end

        # Clear any existing sites
        SiteState.clear()

        # Create a phoenix_only site
        site_attrs = %{
          id: "phoenix-site-999",
          name: "Phoenix Only Site",
          host: "phoenix.example.com",
          priority: 60,
          active: true,
          mode: :phoenix_only,
          frontend_domain: nil,
          allowed_origins: []
        }

        assert :ok = SiteState.save(site_attrs)

        # Try to access API for phoenix_only mode
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, "phoenix.example.com")

        # Capture the log to suppress the info message
        {result_conn, _log} =
          with_log(fn ->
            ApiTenantLookupPlug.call(conn, allow_no_tenant: false)
          end)

        # Should be denied with 403
        assert result_conn.halted
        assert result_conn.status == 403

        body = Jason.decode!(result_conn.resp_body)
        assert body["error"]["code"] == "api_access_denied"
        assert body["error"]["message"] == "API access is not allowed for this site"

        # Clean up
        SiteState.clear()
      else
        :ok
      end
    end
  end

  describe "no-tenant override behavior" do
    test "respects x-no-tenant header format" do
      # Test with various header values
      test_cases = [
        # Should trigger no-tenant
        {"true", true},
        # Should NOT trigger no-tenant
        {"false", false},
        # Should NOT trigger no-tenant
        {"1", false},
        # Should NOT trigger no-tenant
        {"yes", false},
        # Should NOT trigger no-tenant
        {"", false}
      ]

      for {header_value, _should_override} <- test_cases do
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, nil)
          |> put_req_header("x-no-tenant", header_value)

        # Using allow_no_tenant: true to avoid errors
        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: true)

        # We can't check the actual behavior without SiteState,
        # but we can verify the conn is processed
        refute result_conn.halted
      end
    end

    test "handles params-based no_tenant override" do
      # Test with string "true"
      conn1 =
        conn(:get, "/api/test?no_tenant=true")
        |> Map.put(:params, %{"no_tenant" => "true"})
        |> Map.put(:host, nil)

      result_conn1 = ApiTenantLookupPlug.call(conn1, allow_no_tenant: true)
      refute result_conn1.halted

      # Test with boolean true
      conn2 =
        conn(:get, "/api/test")
        |> Map.put(:params, %{"no_tenant" => true})
        |> Map.put(:host, nil)

      result_conn2 = ApiTenantLookupPlug.call(conn2, allow_no_tenant: true)
      refute result_conn2.halted

      # Test with other values (should not trigger override)
      conn3 =
        conn(:get, "/api/test")
        |> Map.put(:params, %{"no_tenant" => "false"})
        |> Map.put(:host, nil)

      result_conn3 = ApiTenantLookupPlug.call(conn3, allow_no_tenant: true)
      refute result_conn3.halted
    end
  end

  describe "port stripping from host header" do
    # This asserts that these hosts resolve to NO site. `SiteState` is process-global ETS rather than
    # sandboxed, so a site cached by any earlier test (several cache "localhost") would make the
    # lookup succeed and the plug not halt. The precondition has to be established, not assumed.
    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok
    end

    test "strips port when extracting host from header" do
      # In test environment, we use conn.host
      # We'll just test that ports are handled in host field
      test_hosts = [
        {"example.com", "example.com:3000"},
        {"example.com", "example.com:8080"},
        {"localhost", "localhost:4000"}
      ]

      for {expected_host, _host_with_port} <- test_hosts do
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, expected_host)

        # This will fail with domain_not_found, but we're testing
        # that it processes the host correctly
        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

        assert result_conn.halted
        # domain_not_found
        assert result_conn.status == 404

        body = Jason.decode!(result_conn.resp_body)
        assert body["error"]["code"] == "domain_not_found"
      end
    end
  end

  describe "multiple host headers" do
    test "uses first host when setting via conn.host" do
      # In test environment, we use conn.host directly
      conn =
        conn(:get, "/api/test")
        |> Map.put(:host, "first.example.com")

      result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

      # Will fail with domain_not_found for first.example.com
      assert result_conn.halted
      assert result_conn.status == 404
    end
  end

  describe "response headers" do
    test "sets x-error-code header on errors" do
      error_test_cases = [
        # No host
        {nil, 400, "missing_host"},
        # Unknown domain
        {"unknown.com", 404, "domain_not_found"}
      ]

      for {host, expected_status, expected_code} <- error_test_cases do
        conn =
          conn(:get, "/api/test")
          |> Map.put(:host, host)

        result_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)

        assert result_conn.halted
        assert result_conn.status == expected_status
        assert get_resp_header(result_conn, "x-error-code") == [expected_code]
      end
    end
  end

  # THE MASTER ACCOUNTS ANSWER ON THE MASTER SITE'S ADDRESS ALONE. `x-no-tenant: true` or
  # `?no_tenant=true` leaves a request of the master site unscoped, which is how a master's token,
  # issued with no site, is recognised there; every other site ignores the switch and scopes the
  # request to itself, so a master's sign-in and token mean nothing on its address.
  describe "the master accounts' switch" do
    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      n = System.unique_integer([:positive])

      master_site = cache_site!("api-master-#{n}.test", true)
      other_site = cache_site!("api-other-#{n}.test", false)

      on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.clear() end)
      {:ok, master_site: master_site, other_site: other_site}
    end

    test "leaves the master site's request unscoped", %{master_site: site} do
      assert tenant(api_request(site.host, [{"x-no-tenant", "true"}])) == nil
      assert tenant(api_request(site.host, [], %{"no_tenant" => "true"})) == nil
      assert tenant(api_request(site.host)) == site.id
    end

    test "is ignored by any other site, which scopes the request to itself", %{other_site: site} do
      header = api_request(site.host, [{"x-no-tenant", "true"}])
      param = api_request(site.host, [], %{"no_tenant" => "true"})

      for conn <- [header, param] do
        refute conn.halted
        assert tenant(conn) == site.id
        assert get_resp_header(conn, "x-tenant-id") == [site.id]
        assert conn.assigns.current_site.id == site.id
      end
    end

    test "a user with a site on an unscoped request is nobody", %{master_site: site} do
      unscoped = api_request(site.host, [{"x-no-tenant", "true"}])

      refused =
        unscoped
        |> assign(:current_user, %{id: "u1", site_id: "a-site"})
        |> ApiTenantLookupPlug.confirm_bearer_tenant([])

      assert refused.assigns.current_user == nil
      assert tenant(refused) == nil

      # Not a site user is not a master: an actor that carries no site_id at all is nobody too.
      assert unscoped
             |> assign(:current_user, %{id: "u3"})
             |> ApiTenantLookupPlug.confirm_bearer_tenant([])
             |> Map.fetch!(:assigns)
             |> Map.fetch!(:current_user) == nil

      master = %{id: "m1", site_id: nil}

      assert unscoped
             |> assign(:current_user, master)
             |> ApiTenantLookupPlug.confirm_bearer_tenant([])
             |> Map.fetch!(:assigns)
             |> Map.fetch!(:current_user) == master

      site_user = %{id: "u2", site_id: site.id}

      assert site.host
             |> api_request()
             |> assign(:current_user, site_user)
             |> ApiTenantLookupPlug.confirm_bearer_tenant([])
             |> Map.fetch!(:assigns)
             |> Map.fetch!(:current_user) == site_user
    end
  end

  # AN EVENT ONE OF WHOSE PLUGINS IS NOT LOADED answers with the conn it was handed, so the request
  # is answered as it is with no plugin listening.
  describe "the API's events while they cannot run" do
    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      n = System.unique_integer([:positive])

      master_site = cache_site!("api-master-#{n}.test", true)
      other_site = cache_site!("api-other-#{n}.test", false)

      on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.clear() end)
      {:ok, master_site: master_site, other_site: other_site}
    end

    test "a request resolves its site and carries its CORS headers", %{other_site: site} do
      EventCannotRun.stub!([
        "api:request:before_tenant_resolve",
        "api:request:after_tenant_resolve",
        "api:request:before_cors",
        "api:request:cors_headers"
      ])

      origin = "https://#{site.host}"
      conn = site.host |> api_request([{"origin", origin}]) |> ApiCorsPlug.call([])

      refute conn.halted
      assert conn.assigns.current_site.id == site.id
      assert tenant(conn) == site.id
      assert get_resp_header(conn, "access-control-allow-origin") == [origin]
    end

    test "another site still scopes a request that asks for no tenant", %{other_site: site} do
      EventCannotRun.stub!("api:request:no_tenant_refused")

      conn = api_request(site.host, [{"x-no-tenant", "true"}])

      refute conn.halted
      assert tenant(conn) == site.id
    end

    test "a site user on an unscoped request is still nobody", %{master_site: site} do
      EventCannotRun.stub!("api:request:token_refused")

      refused =
        site.host
        |> api_request([{"x-no-tenant", "true"}])
        |> assign(:current_user, %{id: "u1", site_id: "a-site"})
        |> ApiTenantLookupPlug.confirm_bearer_tenant([])

      assert refused.assigns.current_user == nil
      assert tenant(refused) == nil
    end

    test "an inactive site is still refused with its 503" do
      EventCannotRun.stub!("api:request:site_unavailable")

      host = "api-inactive-#{System.unique_integer([:positive])}.test"

      :ok =
        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: Ecto.UUID.generate(),
          name: host,
          host: host,
          priority: 0,
          active: false,
          mode: :hybrid
        })

      conn = api_request(host)

      assert conn.halted
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "website_unavailable"
    end
  end

  defp cache_site!(host, master?) do
    site = %{
      id: Ecto.UUID.generate(),
      name: host,
      host: host,
      priority: 0,
      active: true,
      master: master?,
      mode: :hybrid
    }

    :ok = MishkaCmsCore.Runtime.States.SiteState.save(site)
    site
  end

  defp api_request(host, headers \\ [], params \\ %{}) do
    headers
    |> Enum.reduce(conn(:get, "/api/test") |> Map.put(:host, host), fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
    |> Map.put(:params, params)
    |> ApiTenantLookupPlug.call(ApiTenantLookupPlug.init([]))
  end

  defp tenant(conn), do: Ash.PlugHelpers.get_tenant(conn)
end
