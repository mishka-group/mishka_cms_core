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
  `Origin` is read by `MishkaCmsCore.Runtime.OriginValidator.request_origin/1` and must be nothing
  but those three.

  ## What a site allows

  Worked out by `MishkaCmsCore.Runtime.OriginValidator.site_origins/1` when the site is saved, and
  looked up in `MishkaCmsCore.Runtime.States.SiteState` (`allows_origin?/2`) for each request, so a
  site created or edited while the server runs is answered for what it allows now. A loopback host is
  `localhost`, a name under `.localhost`, `127.0.0.1` or `::1`.

  | The site has | Allowed | Not allowed |
  | --- | --- | --- |
  | `host: "site.com"` | `https://site.com` | `http://site.com`, `https://site.com:8443`, `https://sub.site.com` |
  | `host: "site-a.localhost"` (loopback) | `https://site-a.localhost`, `http://site-a.localhost` | `http://site-a.localhost:3000` |
  | `frontend_domain: "app.example.com"` | `https://app.example.com` | `http://app.example.com`, `https://app.example.com:3000` |
  | `frontend_domain: "app.example.com:3000"` | `https://app.example.com:3000` | `http://app.example.com:3000`, `https://app.example.com` |
  | `frontend_domain: "localhost:5173"` (loopback) | `https://localhost:5173`, `http://localhost:5173` | `http://localhost:5174` |
  | `frontend_domain: "https://app.example.com:8443"` | `https://app.example.com:8443` | `http://app.example.com:8443`, `https://app.example.com` |
  | `allowed_origins: ["https://partner.com"]` | `https://partner.com`, `https://partner.com:443` | `http://partner.com`, `https://partner.com:8443` |
  | `allowed_origins: ["http://other.com:8080/"]` | `http://other.com:8080` | `https://other.com:8080`, `http://other.com` |

  Never allowed: a missing site, a `phoenix_only` site, more than one `Origin` header, `null`, and an
  `Origin` with a path, a query, a fragment, credentials or a port that is not a number.

  ## Development

  Compiled only where the app's config sets `:env_dev?`, a loopback origin on any port, over `http`
  or `https`, is allowed for any site the rules above let answer at all — so a frontend on
  `http://localhost:5173` reads the API of a site the database knows only by its public address. A
  release has no such clause, and neither do the tests, which set `:env_test?` alone. Not
  `Mix.env/0`: a dependency is compiled in `:prod` whatever the app runs in.

  ## The answer

  An allowed origin gets `access-control-allow-origin` with the origin as a browser writes it,
  never the request's own text, and `access-control-allow-credentials: true`; a preflight from it
  gets the methods, headers and max age too and is answered `204`. A preflight from any other origin
  is answered `204` with none of them. Every response that comes through here varies by `Origin`:
  `Origin` is merged into the `vary` header already set or set later, once, whatever its case.

  ## Usage

      pipeline :api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
        plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
      end

  ## Options

    * `:site` — the site to answer for, in place of `conn.assigns[:current_site]`.
      `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug` passes the switched-off site it refuses, so
      that site's preflight is answered and its `503` carries the headers an allowed origin needs to
      read it.
  """
  import Plug.Conn
  require Logger

  alias MishkaCmsCore.Runtime.OriginValidator
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.Hook

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
        conn = Hook.call("api:request:before_cors", conn)
        site = Keyword.get(opts, :site, conn.assigns[:current_site])
        origins = get_req_header(conn, "origin")
        origin = List.first(origins)

        result =
          conn
          |> vary_by_origin()
          |> handle_cors(origins, site)
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

  # No `Origin`: not a CORS request, and an `OPTIONS` without one is not a preflight.
  defp handle_cors(conn, [], _site), do: conn

  defp handle_cors(%{method: "OPTIONS"} = conn, origins, site) do
    case allowed_origin(origins, site) do
      {:ok, allowed} ->
        conn
        |> put_cors_headers(allowed)
        |> put_resp_header("access-control-allow-methods", @default_methods)
        |> put_resp_header("access-control-allow-headers", @default_headers)
        |> put_resp_header("access-control-max-age", @max_age)
        |> send_resp(204, "")
        |> halt()

      :error ->
        # The browser blocks the request the preflight was for.
        conn
        |> send_resp(204, "")
        |> halt()
    end
  end

  # An origin that is not allowed gets no CORS headers, and the browser keeps the response from it.
  defp handle_cors(conn, origins, site) do
    case allowed_origin(origins, site) do
      {:ok, allowed} -> put_cors_headers(conn, allowed)
      :error -> conn
    end
  end

  # `{:ok, origin}` with the origin written the way a browser writes it, or `:error`. A browser sends
  # one `Origin`; a request with several is no browser's and gets nothing.
  defp allowed_origin(_origins, nil), do: :error
  defp allowed_origin(_origins, %{mode: :phoenix_only}), do: :error

  defp allowed_origin([origin], %{id: site_id}) do
    with {:ok, requested} <- OriginValidator.request_origin(origin),
         true <- allowed?(site_id, requested) do
      {:ok, OriginValidator.serialize(requested)}
    else
      _denied ->
        Logger.debug(
          "CORS: origin #{inspect(origin)} is not allowed for site #{inspect(site_id)}"
        )

        :error
    end
  end

  defp allowed_origin(_origins, _site), do: :error

  # A LOOPBACK FRONTEND READS ANY SITE'S API IN DEVELOPMENT, the way `SiteLookupPlug` opens
  # `localhost` as the master site: the database is often a copy of production's, which knows each
  # site only by its public address. Compiled only where the app's config sets `:env_dev?`, so a
  # release — and the test suite, which sets `:env_test?` — has no such clause.
  if Application.compile_env(:mishka_cms_core, :env_dev?, false) do
    require OriginValidator

    defp allowed?(_site_id, {_scheme, host, _port}) when OriginValidator.is_loopback_host(host),
      do: true
  end

  defp allowed?(site_id, requested), do: SiteState.allows_origin?(site_id, requested)

  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
  end

  # THE ANSWER DEPENDS ON THE `Origin`, so a cache has to keep one answer per origin — a response
  # cached for one origin, or for none, is otherwise served to another. Merged now, and again just
  # before the response is sent, so a `vary` set by a later plug keeps `Origin` too.
  defp vary_by_origin(conn), do: conn |> merge_vary() |> register_before_send(&merge_vary/1)

  defp merge_vary(conn) do
    {vary, others} = Enum.split_with(conn.resp_headers, &match?({"vary", _value}, &1))

    values =
      vary
      |> Enum.flat_map(fn {"vary", value} -> String.split(value, ",") end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    merged =
      case "*" in values do
        true -> "*"
        false -> (values ++ ["Origin"]) |> Enum.uniq_by(&String.downcase/1) |> Enum.join(", ")
      end

    %{conn | resp_headers: [{"vary", merged} | others]}
  end
end
