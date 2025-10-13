defmodule MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug do
  @moduledoc """
  Multi-tenant API plug for domain-based tenant resolution and context management.

  The `ApiTenantLookupPlug` provides sophisticated tenant identification for REST APIs
  in multi-tenant MishkaCms applications. It automatically resolves the current tenant
  based on request domain and integrates with Ash resource authorization. It never widens what a
  caller may reach: a request is scoped to the site its host names, and only a master (a user whose
  `site_id` is nil) is recognised on a request left unscoped.

  ## Features

  * **Domain-based Tenant Resolution**: Automatically identifies tenants from request Host header
  * **Ash Framework Integration**: Sets tenant context for Ash resource authorization
  * **Master Accounts**: On the master site's address, `x-no-tenant` leaves a request unscoped
  * **Site State Caching**: Leverages efficient SiteState cache for tenant lookups
  * **Comprehensive Error Handling**: Provides detailed API error responses for tenant issues
  * **Test Environment Support**: Includes test-friendly host extraction for development
  * **Production Optimization**: Optimized performance for high-throughput API endpoints

  ## Multi-Tenant Architecture

  The plug operates within MishkaCms's multi-tenant architecture:

  ```
  API Request → Domain Resolution → Site Lookup → Tenant Context
  ├── Host Header Extraction
  ├── SiteState Cache Lookup
  ├── Site Activation Check
  ├── Tenant Context Setting (Ash)
  └── Response Headers & Assigns
  ```

  ## Basic Usage

      # Add to your API pipeline
      defmodule MyAppWeb.Router do
        use Phoenix.Router

        pipeline :api do
          plug :accepts, ["json"]
          plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
          plug :fetch_query_params
        end

        scope "/api/v1", MyAppWeb.Api do
          pipe_through :api

          resources "/posts", PostController
          resources "/users", UserController
        end
      end

      # In your API controller
      defmodule MyAppWeb.Api.PostController do
        use MyAppWeb, :controller

        def index(conn, _params) do
          # Tenant context automatically set
          site = conn.assigns.current_site

          posts = MyApp.Blog.list_posts!(tenant: site.id)
          render(conn, :index, posts: posts)
        end
      end

  ## Advanced Configuration

      # Router with custom options
      pipeline :unscoped_api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug,
          allow_no_tenant: true  # A request from no known host goes on unscoped
      end

      pipeline :tenant_api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug,
          allow_no_tenant: false  # Strict tenant enforcement
      end

  ## The Master Accounts

  A master is a user with no site, and their token is issued with no site. On the master site's
  address — the site whose record has `master: true` — `x-no-tenant: true` or `?no_tenant=true`
  leaves the request unscoped, so `:load_from_bearer` recognises that token:

      # Via HTTP header, on the master site's address
      curl -H "Host: master.example.com" \
           -H "x-no-tenant: true" \
           http://localhost:4000/api/json/v1/master/admin/runtime/site

      # Via query parameter
      GET /api/json/v1/master/admin/runtime/site?no_tenant=true
      Host: master.example.com

  Every other site ignores the switch and scopes the request to itself, so a master's email and
  password are wrong there and a master's token names nobody. `confirm_bearer_tenant/2`, straight
  after `:load_from_bearer`, holds the rest: an unscoped request carries a master or nobody.

  An unscoped request reads and writes through the master routes. A route that works on one site —
  the public `/v1/user/…` ones and the tenant admin ones — answers it `400` with the code
  `tenant_required` (`_tenant_required_errors.ex`):

      {"errors": [{"status": "400", "code": "tenant_required", "title": "Tenant required",
                   "detail": "Tenant context is required for this action. Use the master action instead."}]}

  ## Error Handling and API Responses

      # Missing Host header
      # Status: 400 Bad Request
      {
        "error": {
          "code": "missing_host",
          "message": "Host header is required",
          "status": 400,
          "timestamp": "2024-01-15T10:30:45Z"
        }
      }

      # Domain not found
      # Status: 404 Not Found
      {
        "error": {
          "code": "domain_not_found",
          "message": "Domain not found",
          "status": 404,
          "timestamp": "2024-01-15T10:30:45Z"
        }
      }

      # Site inactive
      # Status: 503 Service Unavailable
      {
        "error": {
          "code": "website_unavailable",
          "message": "This website is currently unavailable",
          "status": 503,
          "timestamp": "2024-01-15T10:30:45Z"
        }
      }

  The inactive refusal is answered for the site's CORS first — see
  `MishkaCmsCore.Runtime.Plugs.ApiCorsPlug` — so a frontend on an origin the site allows gets its
  preflight answered and can read the `503`. It is sent with `cache-control: no-store`.

  An offline site passes this plug: who may reach it depends on the caller, who is known only once the
  bearer token is loaded. `MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug` answers that.

  ## Events

  - `api:request:site_unavailable` — the conn of a switched-off site about to be refused, with
    `%{state: :inactive, site: site}` as its meta. A plugin may answer instead by halting the conn.
  - `api:request:no_tenant_refused` — the conn of a site that is not the master site, asked for
    `x-no-tenant` or `?no_tenant=true` and scoped to itself anyway, with `%{site: site}` as its meta.
  - `api:request:token_refused` — the conn of an unscoped request whose token named a user with a
    site, who is dropped, with `%{site: site, user_id: id}` as its meta.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn
  require Logger

  alias MishkaCmsCore.Accounts.AuthGate
  alias MishkaCmsCore.Runtime.Plugs.ApiCorsPlug

  @default_opts [
    allow_no_tenant: false
  ]

  @doc """
  Initializes the plug with configuration options.

  This function merges user-provided options with default settings to configure
  the plug's behavior. It's called once when the plug is compiled into the
  router pipeline, not on each request.

  ## Parameters

  * `opts` - Keyword list of configuration options:
    * `:allow_no_tenant` - Boolean, lets a request from a missing or unknown host go on with no
      tenant, where only a master is recognised (defaults to `false`)

  ## Return Value

  Returns merged configuration that will be passed to `call/2` function.

  ## Examples

      # Default configuration
      plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
      # Equivalent to: plug ..., allow_no_tenant: false

      # Let a request from a missing or unknown host go on unscoped
      plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, allow_no_tenant: true

  ## Configuration Options

  ### `:allow_no_tenant`

  When `true`:
  * Missing host headers result in `current_site: nil`
  * Unknown domains result in `current_site: nil`
  * Such a request goes on unscoped, with no tenant

  It gives nobody more reach. On an unscoped request `confirm_bearer_tenant/2` drops every user
  with a site, so only a master (a user whose `site_id` is nil) is recognised there — and a master's
  token then works from any unknown host, not only from the master site's address. It passes over
  that master-site-only rule, so leave it off unless an endpoint needs exactly that.

  When `false` (default):
  * Missing host headers return 400 "missing_host" error
  * Unknown domains return 404 "domain_not_found" error
  * Requests are halted with detailed error responses
  * Enforces strict tenant isolation

  ## Use Cases by Configuration

      # Every request scoped to the site its host names
      pipeline :tenant_api do
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug  # allow_no_tenant: false
      end

      # A request from no known host goes on unscoped; only a master is recognised on it
      pipeline :unscoped_api do
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, allow_no_tenant: true
      end
  """
  def init(opts) do
    Keyword.merge(@default_opts, opts)
  end

  @doc """
  Processes the request to identify and set the tenant context.

  This is the main plug function that executes for each request. It implements
  a comprehensive tenant resolution pipeline including domain extraction, site
  lookup, validation, and context setting for downstream processing.

  ## Parameters

  * `conn` - Plug.Conn struct representing the HTTP request/response
  * `opts` - Configuration options from `init/1`

  ## Return Value

  * `Plug.Conn` - Updated connection with tenant context or error response

  ## Processing Pipeline

  1. **Host Extraction**: Extracts domain from Host header or conn.host (tests)
  2. **Site Lookup**: Queries SiteState cache for site configuration
  3. **Site Validation**: Ensures site is active and available
  4. **Tenant Override Check**: Handles explicit no-tenant requests
  5. **Context Setting**: Configures Ash tenant context and response headers
  6. **Assignment**: Sets `current_site` assign for controller access

  ## Successful Flow

      # Request: GET /api/posts
      # Header: Host: blog.example.com

      # 1. Extract host: "blog.example.com"
      # 2. Lookup site: %Site{id: 42, host: "blog.example.com", active: true}
      # 3. Validate: site active ✓
      # 4. Check override: no x-no-tenant header ✓
      # 5. Set tenant context: Ash.set_tenant(42)
      # 6. Add headers: x-tenant-id: "42"
      # 7. Assign: conn.assigns.current_site = %Site{...}

  ## Error Handling

  The function handles multiple error scenarios:

      # Missing Host header
      # Result: 400 with detailed JSON error (if allow_no_tenant: false)
      # Result: current_site: nil (if allow_no_tenant: true)

      # Unknown domain
      # Result: 404 with detailed JSON error (if allow_no_tenant: false)
      # Result: current_site: nil (if allow_no_tenant: true)

      # Inactive site
      # Result: 503 with "website_unavailable" error (always)

  ## Examples

      # Standard tenant request
      conn = %Plug.Conn{
        req_headers: [$("host", "mysite.com")]
      }

      updated_conn = ApiTenantLookupPlug.call(conn, allow_no_tenant: false)
      # Result: conn.assigns.current_site = %Site{id: 123, host: "mysite.com"}
      # Headers: x-tenant-id: "123"

      # The master accounts' switch, on the master site's address
      conn = %Plug.Conn{
        req_headers: [
          $("host", "master.example.com"),
          $("x-no-tenant", "true")
        ]
      }

      updated_conn = ApiTenantLookupPlug.call(conn, [])
      # Result: conn.assigns.current_site = %Site{master: true, ...}
      # Headers: x-tenant-id: "none"
      # Ash tenant context: nil
      # On any other site's address: x-tenant-id is the site's id, and so is the tenant

  ## Integration with Controllers

      defmodule MyAppWeb.Api.PostController do
        def index(conn, _params) do
          site = conn.assigns.current_site

          if site do
            # Tenant-specific posts (Ash context set automatically)
            posts = MyApp.Blog.list_posts!()
            render(conn, :index, posts: posts)
          else
            # Global posts (no tenant context)
            posts = MyApp.Blog.list_all_posts!()
            render(conn, :global_index, posts: posts)
          end
        end
      end

  ## Monitoring and Debugging

      # Add custom telemetry
      defmodule TenantLookupTelemetry do
        def track_tenant_resolution(conn, result) do
          :telemetry.execute(
            [:api, :tenant_lookup],
            %{duration: processing_time},
            %{
              host: get_req_header(conn, "host") |> List.first(),
              result: result,
              tenant_id: conn.assigns[:current_site] && conn.assigns.current_site.id
            }
          )
        end
      end

  ## Security Considerations

      # The plug automatically prevents:
      # - Cross-tenant data access (via Ash context)
      # - Inactive site access (503 responses)
      # - Malformed host header attacks (validation)

      # Additional security can be layered:
      plug ApiTenantLookupPlug
      plug TenantRateLimitPlug
      plug TenantPermissionPlug
  """
  def call(conn, opts) do
    :telemetry.span(
      [:mishka_cms, :runtime, :plugs, :api_tenant_lookup],
      %{path: conn.request_path, method: conn.method},
      fn ->
        conn = MishkaInstaller.Event.Hook.call("api:request:before_tenant_resolve", conn)

        result =
          with {:ok, host} <- extract_host(conn),
               {:ok, site} <- lookup_site(host),
               :ok <- validate_site_active(site),
               :ok <- validate_api_access(site) do
            conn
            |> scope(site)
            |> assign(:current_site, site)
          else
            {:error, :no_host} ->
              if opts[:allow_no_tenant],
                do: assign(conn, :current_site, nil),
                else:
                  send_api_error(conn, 400, "missing_host", gettext("Host header is required"))

            {:error, :site_not_found} ->
              if opts[:allow_no_tenant],
                do: assign(conn, :current_site, nil),
                else: send_api_error(conn, 404, "domain_not_found", gettext("Domain not found"))

            {:error, {:site_inactive, site}} ->
              site_inactive(conn, site)

            {:error, :api_not_allowed} ->
              send_api_error(
                conn,
                403,
                "api_access_denied",
                gettext("API access is not allowed for this site")
              )
          end

        host =
          case extract_host(conn) do
            {:ok, h} -> h
            _ -> nil
          end

        result =
          result
          |> then(
            &MishkaInstaller.Event.Hook.call("api:request:after_tenant_resolve", &1,
              meta: %{host: host}
            )
          )

        site = result.assigns[:current_site]

        {result, %{host: host, site: site && site.name, tenant_id: site && site.id}}
      end
    )
  end

  @doc """
  Confirms the tenant `call/2` chose, once `:load_from_bearer` has read the token's user.

  Plug it in straight after `:load_from_bearer`, imported from this module:

  ```elixir
  import MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, only: [confirm_bearer_tenant: 2]

  pipeline :api do
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    # ...
    plug :load_from_bearer
    plug :confirm_bearer_tenant
    plug :set_actor, :user
  end
  ```

  An unscoped request is a master's, a user whose `site_id` is nil, or nobody's. Anyone else on an
  unscoped request — a user with a site holding a token issued with no site, or an actor that
  carries no `site_id` at all — is nobody: `:current_user` becomes `nil`, and a plugin on
  `api:request:token_refused` hears it with `%{site: site, user_id: id}`.

  A user the site's closed sign-in signs out (`MishkaCmsCore.Accounts.AuthGate.signs_out?/2`) is
  signed out everywhere and is nobody too.
  """
  @spec confirm_bearer_tenant(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def confirm_bearer_tenant(conn, _opts) do
    case {Ash.PlugHelpers.get_tenant(conn), conn.assigns[:current_user]} do
      {nil, %{site_id: nil}} ->
        conn

      {nil, nil} ->
        conn

      {nil, user} ->
        conn
        |> assign(:current_user, nil)
        |> then(
          &MishkaInstaller.Event.Hook.call("api:request:token_refused", &1,
            meta: %{site: conn.assigns[:current_site], user_id: Map.get(user, :id)}
          )
        )

      {site_id, %{} = user} ->
        if AuthGate.signs_out?(site_id, user) do
          AuthGate.sign_out(user, site_id)
          assign(conn, :current_user, nil)
        else
          conn
        end

      _scoped ->
        conn
    end
  end

  # THE MASTER ACCOUNTS ANSWER ON THE MASTER SITE'S ADDRESS ALONE. There `x-no-tenant: true` or
  # `?no_tenant=true` leaves the request unscoped, which is how a master's token, issued with no
  # site, is recognised by `:load_from_bearer`. Any other site ignores the switch, scopes the request
  # to itself, and a plugin hears the refusal.
  defp scope(conn, %{master: true} = site) do
    if check_explicit_no_tenant(conn),
      do: set_tenant(conn, nil, "none"),
      else: set_tenant(conn, site.id, site.id)
  end

  defp scope(conn, site) do
    conn
    |> refuse_no_tenant(site)
    |> set_tenant(site.id, site.id)
  end

  defp refuse_no_tenant(conn, site) do
    if check_explicit_no_tenant(conn),
      do:
        MishkaInstaller.Event.Hook.call("api:request:no_tenant_refused", conn,
          meta: %{site: site}
        ),
      else: conn
  end

  defp set_tenant(conn, tenant, x_tenant) do
    conn
    |> Ash.PlugHelpers.set_tenant(tenant)
    |> put_resp_header("x-tenant-id", x_tenant)
  end

  defp check_explicit_no_tenant(conn) do
    header_flag = get_req_header(conn, "x-no-tenant") == ["true"]

    param_flag =
      case conn.params do
        %{"no_tenant" => "true"} -> true
        %{"no_tenant" => true} -> true
        _ -> false
      end

    header_flag || param_flag
  end

  defp extract_host(conn) do
    if Application.get_env(:mishka_cms_core, :env_test?, false) do
      if conn.host, do: {:ok, conn.host}, else: {:error, :no_host}
    else
      case get_req_header(conn, "host") do
        [host | _] ->
          clean_host = host |> String.split(":") |> List.first()
          {:ok, clean_host}

        [] ->
          {:error, :no_host}
      end
    end
  end

  defp lookup_site(host) do
    case MishkaCmsCore.Runtime.States.SiteState.get_by_host(host) do
      {:ok, site} ->
        {:ok, site}

      {:error, :not_found} ->
        Logger.debug("Site not found for host: #{host}")
        {:error, :site_not_found}
    end
  end

  defp validate_site_active(site) do
    if site.active do
      :ok
    else
      {:error, {:site_inactive, site}}
    end
  end

  # CORS FIRST, because the pipeline's own CORS plug never runs after a halt: without it a preflight
  # got this 503 and the request behind it could not be read by the frontend it was meant for.
  defp site_inactive(conn, site) do
    case ApiCorsPlug.call(conn, site: site) do
      %Plug.Conn{halted: true} = preflight ->
        preflight

      conn ->
        conn =
          MishkaInstaller.Event.Hook.call("api:request:site_unavailable", conn,
            meta: %{state: :inactive, site: site}
          )

        if conn.halted,
          do: conn,
          else:
            conn
            |> put_resp_header("cache-control", "no-store")
            |> send_api_error(
              503,
              "website_unavailable",
              gettext("This website is currently unavailable")
            )
    end
  end

  defp validate_api_access(site) do
    if phoenix_only?(site) do
      Logger.info("API access denied for phoenix_only site: #{site.host}")
      {:error, :api_not_allowed}
    else
      :ok
    end
  end

  defp send_api_error(conn, status, code, message) do
    body =
      Jason.encode!(%{
        error: %{
          code: code,
          message: message,
          status: status,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })

    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> put_resp_header("x-error-code", code)
    |> send_resp(status, body)
    |> halt()
  end

  # `Site.mode` is an atom on the resource and `SiteState` normalises to the same, so this compares
  # atoms. Written against the string `"phoenix_only"` it was silently never true, and the switch an
  # owner flips to close a site's API did nothing at all.
  defp phoenix_only?(%{mode: :phoenix_only}), do: true
  defp phoenix_only?(_site), do: false
end
