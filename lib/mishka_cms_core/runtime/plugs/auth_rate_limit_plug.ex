defmodule MishkaCmsCore.Runtime.Plugs.AuthRateLimitPlug do
  @moduledoc """
  The JSON:API side of `MishkaCmsCore.Accounts.AuthRateLimit`: hands every action the address
  `conn.remote_ip` names (the endpoint's `plug RemoteIp` has read it) as the
  `ash_authentication_request` context, marked `api?: true` so the actions ask no captcha
  (`MishkaCmsCore.Accounts.CaptchaCheck`), and gives a `429` AshJsonApi wrote for a refused sign-in
  or request its headers.

      pipeline :api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
        plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
        plug MishkaCmsCore.Runtime.Plugs.AuthRateLimitPlug
        ...
      end

  ## The refusal

  `retry-after` in seconds, `x-error-code: rate_limited` and `cache-control: no-store`, both headers
  exposed to a frontend on an origin `ApiCorsPlug` allowed, on the JSON:API errors document:

      {"errors": [{"status": "429", "code": "rate_limited", "title": "Too many sign-in attempts",
                   "detail": "Too many sign-in attempts. Try again in 15 minutes.",
                   "meta": {"retry_after": 900, "action": "sign_in", "limited_by": "account"}}],
       "jsonapi": {"version": "1.0"}}

  ## Events

  - `auth:request:rate_limited` — the refused conn, with `%{action: action, key: :ip | :account,
    retry_after: seconds, site: site}` as its meta. The response is written by then: a plugin may
    change it with `Plug.Conn.resp/3` and its headers, not send one. `MishkaCmsCoreWeb.AuthController`
    fires it for the browser's routes, before anything is sent.
  """
  import Plug.Conn

  alias MishkaCmsCore.Accounts.AuthRateLimit
  alias MishkaCmsCore.PluginEvent

  def init(opts), do: opts

  def call(conn, _opts) do
    # `api?: true` — this request is the JSON:API's, which asks no captcha
    # (`MishkaCmsCore.Accounts.CaptchaCheck`).
    request = %{remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string(), api?: true}

    conn
    |> Ash.PlugHelpers.update_context(&Map.put(&1 || %{}, :ash_authentication_request, request))
    |> register_before_send(&refused/1)
  end

  defp refused(%Plug.Conn{status: 429, resp_body: body} = conn)
       when is_binary(body) or is_list(body) do
    with {:ok, document} <- body |> IO.iodata_to_binary() |> Jason.decode(),
         %{} = limited <- AuthRateLimit.limited(document) do
      conn
      |> put_refusal_headers(limited.retry_after)
      |> then(
        &PluginEvent.call("auth:request:rate_limited", &1,
          meta: Map.put(limited, :site, conn.assigns[:current_site])
        )
      )
    else
      _not_ours -> conn
    end
  end

  defp refused(conn), do: conn

  @doc """
  Puts the headers of a refusal that says to wait `seconds` on `conn`.
  """
  @spec put_refusal_headers(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def put_refusal_headers(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_resp_header("x-error-code", "rate_limited")
    |> put_resp_header("cache-control", "no-store")
    |> expose_headers()
  end

  defp expose_headers(conn) do
    case get_resp_header(conn, "access-control-allow-origin") do
      [] ->
        conn

      _allowed ->
        put_resp_header(conn, "access-control-expose-headers", "retry-after, x-error-code")
    end
  end
end
