defmodule MishkaCmsCore.Runtime.Plugs.ApiCorsPlug do
  @moduledoc """
  CORS (Cross-Origin Resource Sharing) plug for API endpoints with fast allowed origins lookup.

  This plug handles CORS headers for API requests, using the optimized SiteState allowed_origins
  index for O(1) origin validation. It supports both preflight (OPTIONS) requests and regular
  API requests, automatically setting the appropriate CORS headers based on the site configuration.

  **Considerations**: We do not calculate port, the only option checked is `host`

  ## Usage

      pipeline :api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
        plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
      end

  ## CORS Header Flow

  1. Extract Origin header from request
  2. Check if origin is allowed using fast ETS lookup
  3. If allowed, set Access-Control-Allow-Origin header
  4. Handle preflight requests with appropriate headers
  5. Continue processing for regular requests

  ## Options

    * `:site` — the site to answer for, in place of `conn.assigns[:current_site]`.
      `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug` passes the switched-off site it refuses, so
      that site's preflight is answered and its `503` carries the headers an allowed origin needs to
      read it.
  """
  import Plug.Conn
  require Logger

  alias MishkaCmsCore.PluginEvent

  @default_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @default_headers "Accept, Authorization, Content-Type, X-Requested-With, x-no-tenant"
  # 24 hours in seconds
  @max_age "86400"

  def init(opts), do: opts

  def call(conn, opts) do
    :telemetry.span(
      [:mishka_cms, :runtime, :plugs, :api_cors],
      %{path: conn.request_path, method: conn.method},
      fn ->
        conn = PluginEvent.call("api:request:before_cors", conn)
        site = Keyword.get(opts, :site, conn.assigns[:current_site])
        origin = get_req_header(conn, "origin") |> List.first()
        Logger.debug("CORS Plug - Origin header: #{inspect(origin)}")
        Logger.debug("CORS Plug - Current site: #{inspect(site)}")

        result =
          if(origin, do: handle_cors(conn, origin, site), else: conn)
          |> then(&PluginEvent.call("api:request:cors_headers", &1, meta: %{origin: origin}))

        site_name =
          case site do
            %{name: name} -> name
            _ -> nil
          end

        {result, %{origin: origin, site: site_name}}
      end
    )
  end

  defp handle_cors(%{method: "OPTIONS"} = conn, origin, site) do
    # Preflight request
    Logger.debug("CORS: Handling OPTIONS preflight request")

    if is_origin_allowed?(origin, site) do
      Logger.debug("CORS: Setting preflight headers for allowed origin")

      conn
      |> put_cors_headers(origin)
      |> put_resp_header("access-control-allow-methods", @default_methods)
      |> put_resp_header("access-control-allow-headers", @default_headers)
      |> put_resp_header("access-control-max-age", @max_age)
      |> send_resp(204, "")
      |> halt()
    else
      Logger.debug("CORS: Denying preflight - origin not allowed")
      # Origin not allowed - continue without CORS headers
      # The browser will block the request
      conn
      |> send_resp(204, "")
      |> halt()
    end
  end

  # Regular request with Origin header
  # Origin not allowed - continue without CORS headers
  # The browser will block the response
  defp handle_cors(conn, origin, site) do
    if is_origin_allowed?(origin, site) do
      Logger.debug("CORS: Setting headers for regular request")
      put_cors_headers(conn, origin)
    else
      Logger.debug("CORS: Not setting headers - origin not allowed")
      conn
    end
  end

  defp is_origin_allowed?(origin, current_site) do
    result =
      cond do
        # No site context - this means no site was found for the host
        # This should be denied for security
        is_nil(current_site) ->
          Logger.debug("CORS: No current_site in assigns - denying for security")
          false

        # Phoenix-only mode: NO external API access allowed
        # We prevent inside the api_tenant_lookup_plug, but i think it is better to have it here too
        phoenix_only?(current_site) ->
          Logger.debug("CORS: Site mode is phoenix_only - denying")
          false

        # Check if origin matches the current site's host (same-origin)
        current_site.host == extract_host_from_origin(origin) ->
          Logger.debug("CORS: Origin matches site host - allowing")
          true

        # API-only or hybrid modes: check frontend_domain
        current_site.frontend_domain &&
            is_frontend_domain_match?(origin, current_site.frontend_domain) ->
          Logger.debug("CORS: Origin matches frontend_domain - allowing")
          true

        # Check allowed_origins list (compare hosts only, ignore ports)
        origin_in_allowed_list?(origin, current_site.allowed_origins || []) ->
          Logger.debug("CORS: Origin found in allowed_origins list - allowing")
          true

        true ->
          Logger.debug("CORS: Origin not allowed - denying")
          Logger.debug("  Origin: #{origin}")
          Logger.debug("  Frontend domain: #{inspect(current_site.frontend_domain)}")
          Logger.debug("  Allowed origins: #{inspect(current_site.allowed_origins)}")
          false
      end

    Logger.debug("CORS: Final decision for #{origin}: #{result}")
    result
  end

  # frontend_domain can be stored as either full origin or just domain
  defp is_frontend_domain_match?(origin, frontend_domain) do
    # Just compare hosts, ignore ports
    origin_host = extract_host_from_origin(origin)
    frontend_host = extract_host_from_origin("http://#{frontend_domain}")

    origin_host == frontend_host
  end

  # Check if origin is in allowed list (comparing hosts only, ignoring ports)
  defp origin_in_allowed_list?(origin, allowed_origins) do
    origin_host = extract_host_from_origin(origin)

    Enum.any?(allowed_origins, fn allowed ->
      allowed_host = extract_host_from_origin(allowed)
      origin_host == allowed_host
    end)
  end

  defp put_cors_headers(conn, origin) do
    Logger.debug("CORS: Adding headers - Origin: #{origin}")

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("vary", "Origin")
  end

  defp extract_host_from_origin(origin) do
    case URI.parse(origin) do
      %{host: host} when not is_nil(host) -> host
      _ -> nil
    end
  end

  # `Site.mode` is an atom on the resource and `SiteState` normalises to the same, so this compares
  # atoms. Written against the string `"phoenix_only"` it was silently never true.
  defp phoenix_only?(%{mode: :phoenix_only}), do: true
  defp phoenix_only?(_site), do: false
end
