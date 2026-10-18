# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ApiCorsPlug do
  @moduledoc """
  CORS (Cross-Origin Resource Sharing) plug for API endpoints.

  This plug handles CORS headers for API requests, comparing the request's `Origin` with the origins
  the current site allows. It supports both preflight (OPTIONS) requests and regular API requests,
  automatically setting the appropriate CORS headers based on the site configuration.

  ## What an origin is

  An origin is a scheme, a host and a port, and all three have to be the same: `https://site.com`
  does not allow `http://site.com` or `https://site.com:9999`, because a cookie is not kept apart by
  scheme or port and the answer carries `access-control-allow-credentials: true`. The request's
  `Origin` is read with `URI.parse/1` and must be nothing but those three; a missing or malformed one,
  `null`, or one with a path, a query or credentials is never allowed.

  A site allows:

    * its own `host`, as `https://<host>`. A loopback host (`localhost`, `127.0.0.1`, `[::1]`) is also
      allowed as `http://<host>`, which is how a site is developed;
    * its `frontend_domain`. Written as an origin (`https://app.example.com:8443`) it is compared as
      written. Written as a bare domain (`app.example.com` or `app.example.com:3000`) it is that
      domain over `https` (and `http` for a loopback one), on the port written, or the scheme's own;
    * every entry of `allowed_origins`, compared as written. A port that is not written is the
      scheme's own, so `https://partner.com` is `https://partner.com:443`.

  ## Usage

      pipeline :api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
        plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
      end

  ## CORS Header Flow

  1. Extract Origin header from request
  2. Check if origin is one the current site allows
  3. If allowed, set Access-Control-Allow-Origin header to that origin
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

  alias MishkaInstaller.Event.Hook

  @default_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @default_headers "Accept, Authorization, Content-Type, X-Requested-With, x-no-tenant"
  # 24 hours in seconds
  @max_age "86400"

  @loopback ["localhost", "127.0.0.1", "::1"]

  def init(opts), do: opts

  def call(conn, opts) do
    :telemetry.span(
      [:mishka_cms, :runtime, :plugs, :api_cors],
      %{path: conn.request_path, method: conn.method},
      fn ->
        conn = Hook.call("api:request:before_cors", conn)
        site = Keyword.get(opts, :site, conn.assigns[:current_site])
        origin = get_req_header(conn, "origin") |> List.first()
        Logger.debug("CORS Plug - Origin header: #{inspect(origin)}")
        Logger.debug("CORS Plug - Current site: #{inspect(site)}")

        result =
          if(origin, do: handle_cors(conn, origin, site), else: conn)
          |> then(&Hook.call("api:request:cors_headers", &1, meta: %{origin: origin}))

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

    case allowed_origin(origin, site) do
      {:ok, allowed} ->
        Logger.debug("CORS: Setting preflight headers for allowed origin")

        conn
        |> put_cors_headers(allowed)
        |> put_resp_header("access-control-allow-methods", @default_methods)
        |> put_resp_header("access-control-allow-headers", @default_headers)
        |> put_resp_header("access-control-max-age", @max_age)
        |> send_resp(204, "")
        |> halt()

      :error ->
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
    case allowed_origin(origin, site) do
      {:ok, allowed} ->
        Logger.debug("CORS: Setting headers for regular request")
        put_cors_headers(conn, allowed)

      :error ->
        Logger.debug("CORS: Not setting headers - origin not allowed")
        conn
    end
  end

  # `{:ok, origin}` with the origin written the way a browser writes it, or `:error`.
  defp allowed_origin(_origin, nil) do
    # No site context - this means no site was found for the host
    # This should be denied for security
    Logger.debug("CORS: No current_site in assigns - denying for security")
    :error
  end

  defp allowed_origin(origin, site) do
    # Phoenix-only mode: NO external API access allowed
    # We prevent inside the api_tenant_lookup_plug, but i think it is better to have it here too
    with false <- phoenix_only?(site),
         {:ok, requested} <- request_origin(origin),
         true <- MapSet.member?(site_origins(site), requested) do
      Logger.debug("CORS: Origin found among the site's origins - allowing")
      {:ok, serialize(requested)}
    else
      _denied ->
        Logger.debug("CORS: Origin not allowed - denying")
        Logger.debug("  Origin: #{inspect(origin)}")
        Logger.debug("  Frontend domain: #{inspect(Map.get(site, :frontend_domain))}")
        Logger.debug("  Allowed origins: #{inspect(Map.get(site, :allowed_origins))}")
        :error
    end
  end

  # Every origin the site allows, as `{scheme, host, port}`: its own host, its frontend domain and
  # its `allowed_origins` list.
  defp site_origins(site) do
    declared =
      site |> Map.get(:allowed_origins) |> List.wrap() |> Enum.flat_map(&written_origin/1)

    MapSet.new(
      bare_domain(Map.get(site, :host)) ++
        bare_domain(Map.get(site, :frontend_domain)) ++ declared
    )
  end

  # `frontend_domain` is a domain, `domain:port` or a full origin; `host` is a domain.
  defp bare_domain(domain) when is_binary(domain) do
    case String.contains?(domain, "://") do
      true -> written_origin(domain)
      false -> domain |> String.trim() |> then(&URI.parse("//" <> &1)) |> over_schemes()
    end
  end

  defp bare_domain(_domain), do: []

  defp over_schemes(%URI{host: host, port: port}) when is_binary(host) and host != "" do
    host = String.downcase(host)
    schemes = if(host in @loopback, do: ["https", "http"], else: ["https"])

    Enum.map(schemes, &origin(&1, host, port))
  end

  defp over_schemes(_uri), do: []

  defp origin(scheme, host, nil), do: origin(scheme, host, default_port(scheme))
  defp origin(scheme, host, port) when is_integer(port), do: {scheme, host, port}

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80

  # An entry of `allowed_origins`, or a `frontend_domain` written as an origin. Whatever follows the
  # port is ignored: the list accepts a trailing slash.
  defp written_origin(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        [origin(scheme, String.downcase(host), port)]

      _not_an_origin ->
        []
    end
  end

  defp written_origin(_value), do: []

  # What a browser sends: a scheme, a host and a port, and nothing after them. `URI.parse/1` falls
  # back to the scheme's port for text it cannot read as one (`:abc`), so the authority has to be
  # exactly the host and port it was read as.
  defp request_origin(value) when is_binary(value) do
    with %URI{scheme: scheme, host: host, port: port, authority: authority} = uri
         when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) <-
           URI.parse(value),
         %URI{userinfo: nil, query: nil, fragment: nil, path: path} when path in [nil, ""] <- uri,
         host = String.downcase(host),
         true <- String.downcase(authority) in [bracket(host), bracket(host) <> ":#{port}"] do
      {:ok, origin(scheme, host, port)}
    else
      _not_an_origin -> :error
    end
  end

  defp request_origin(_value), do: :error

  defp serialize({scheme, host, port}) do
    case port == default_port(scheme) do
      true -> "#{scheme}://#{bracket(host)}"
      false -> "#{scheme}://#{bracket(host)}:#{port}"
    end
  end

  defp bracket(host), do: if(String.contains?(host, ":"), do: "[" <> host <> "]", else: host)

  defp put_cors_headers(conn, origin) do
    Logger.debug("CORS: Adding headers - Origin: #{origin}")

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("vary", "Origin")
  end

  # `Site.mode` is an atom on the resource and `SiteState` normalises to the same, so this compares
  # atoms. Written against the string `"phoenix_only"` it was silently never true.
  defp phoenix_only?(%{mode: :phoenix_only}), do: true
  defp phoenix_only?(_site), do: false
end
