# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug do
  @moduledoc """
  Closes a site's API while the site is offline, to everyone but its own API admins and the masters
  (users whose `site_id` is nil) who are API admins: who holds anything under `admin:api`
  (`MishkaCmsCore.Accounts.Helper.master_admin?/2` and `site_admin?/3` on the `:api` surface). A
  dashboard-only admin reaches the site's screens, not its API, and is refused like anyone.

  `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug` refuses a switched-off site before anybody is
  known. This plug runs after `:load_from_bearer` and `:set_actor`, once the bearer token has named
  the caller, and answers the offline switch — the site's own or the global one — by the rule
  `MishkaCmsCore.Runtime.SiteAvailability.allowed_in?/4` gives on the `:api` surface. A token of another site is not loaded
  for this one, so its holder counts as a visitor.

  Per request this is ETS reads only: the site cache, the settings cache and the permissions the
  bearer token's user was loaded with.

      pipeline :api do
        plug :accepts, ["json"]
        plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
        plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
        plug :load_from_bearer
        plug :confirm_bearer_tenant
        plug :set_actor, :user
        plug MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug, api: :json_api
      end

  ## Options

    * `:api` — `:json_api` or `:graphql`, the API whose error shape the refusal is written in.
    * `:at` — where the JSON:API router is mounted, `"/api/json"` by default.

  ## Signing in while offline

  An admin has no token yet when the site is already offline, so these routes of
  `MishkaCmsCore.Accounts.User` stay open to everyone on a JSON:API pipeline: sign-in
  (`sign_in_with_password`), the password reset request and the reset itself
  (`request_password_reset_token`, `reset_password_api`), `me` and `logout`. They are read from
  `MishkaCmsCore.Accounts`' own routes, whole path and method, so a route renamed there follows and
  one removed closes. Registering stays closed, and
  `MishkaCmsCore.Accounts.Checks.RegistrationOpen` refuses it at the resource as well.

  ## The refusal

  A `503` with `x-error-code: site_offline` and `cache-control: no-store`, in the API's own error
  shape. The message is the site's `cms.maintenance_message`, or the global one. `ApiCorsPlug` runs
  first, so a frontend on an origin the site allows can read it; it answers a preflight by itself.

  JSON:API, as `application/vnd.api+json`:

      {"errors": [{"status": "503", "code": "site_offline", "title": "Site offline",
                   "detail": "We are currently undergoing maintenance. Please check back soon."}],
       "jsonapi": {"version": "1.0"}}

  GraphQL:

      {"errors": [{"message": "We are currently undergoing maintenance. Please check back soon.",
                   "extensions": {"code": "site_offline", "status": 503}}]}

  A site that is switched off between the tenant lookup and this plug is refused here as well, to
  everyone and masters included, as the tenant lookup refuses it, with `website_unavailable`, the
  code the tenant lookup uses for it.

  ## Events

  - `api:request:site_unavailable` — the conn about to be refused, with `%{state: :offline | :inactive,
    site: site}` as its meta. A plugin may answer instead by halting the conn.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn

  alias MishkaCmsCore.Runtime.SiteAvailability
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook

  @open_actions [
    :sign_in_with_password,
    :request_password_reset_token,
    :reset_password_api,
    :me,
    :logout
  ]

  def init(opts) do
    api = Keyword.fetch!(opts, :api)
    %{api: api, open: open_routes(api, Keyword.get(opts, :at, "/api/json"))}
  end

  def call(conn, %{api: api, open: open}) do
    site = conn.assigns[:current_site]
    state = state(site)

    cond do
      state == :open ->
        conn

      # AS ApiTenantLookupPlug: a switched-off site is closed to everyone, masters included.
      state == :inactive ->
        refuse(conn, state, site, api)

      state == :offline and {conn.method, conn.path_info} in open ->
        conn

      SiteAvailability.allowed_in?(state, site_id(site), conn.assigns[:current_user], :api) ->
        conn

      true ->
        refuse(conn, state, site, api)
    end
  end

  # WITHOUT A SITE only the global switch applies. The tenant lookup always resolves one on the
  # pipelines the CMS mounts; this is for a pipeline that lets a request through without one.
  defp state(%{id: site_id}), do: SiteAvailability.state(site_id)
  defp state(_no_site), do: if(Settings.offline?(nil), do: :offline, else: :open)

  defp site_id(%{id: site_id}), do: site_id
  defp site_id(_no_site), do: nil

  defp refuse(conn, state, site, api) do
    conn =
      Hook.call("api:request:site_unavailable", conn, meta: %{state: state, site: site})

    if conn.halted, do: conn, else: conn |> send_refusal(state, site, api) |> halt()
  end

  @doc """
  Sends the refusal of `site` in `state` — `:offline` or `:inactive` — in `api`'s error shape, as
  `call/2` does, with no event and no halt. `site` is `nil` for the global switch.

  `MishkaCmsWeb.GraphqlSocket` answers a refused `/ws/gql` connect with it.

      ApiAvailabilityPlug.send_refusal(conn, :offline, site, :graphql)
  """
  @spec send_refusal(Plug.Conn.t(), :offline | :inactive, map() | nil, :json_api | :graphql) ::
          Plug.Conn.t()
  def send_refusal(conn, state, site, api) do
    {code, title, message} = reason(state, site)

    conn
    |> put_resp_header("x-error-code", code)
    |> put_resp_header("cache-control", "no-store")
    |> put_content_type(api)
    |> send_resp(503, body(api, code, title, message))
  end

  defp reason(:offline, site) do
    message =
      Settings.get(
        "cms.maintenance_message",
        gettext("We are currently undergoing maintenance. Please check back soon."),
        site_id(site)
      )

    {"site_offline", gettext("Site offline"), message}
  end

  defp reason(:inactive, _site),
    do:
      {"website_unavailable", gettext("Website unavailable"),
       gettext("This website is currently unavailable")}

  # JSON:API forbids parameters on its media type, the charset included.
  defp put_content_type(conn, :json_api),
    do: put_resp_content_type(conn, "application/vnd.api+json", nil)

  defp put_content_type(conn, :graphql), do: put_resp_content_type(conn, "application/json")

  defp body(:json_api, code, title, message) do
    Jason.encode!(%{
      errors: [%{status: "503", code: code, title: title, detail: message}],
      jsonapi: %{version: "1.0"}
    })
  end

  defp body(:graphql, code, _title, message) do
    Jason.encode!(%{errors: [%{message: message, extensions: %{code: code, status: 503}}]})
  end

  defp open_routes(:json_api, at) do
    for route <- AshJsonApi.Domain.Info.routes(MishkaCmsCore.Accounts),
        route.resource == MishkaCmsCore.Accounts.User and route.action in @open_actions,
        do: {route.method |> Atom.to_string() |> String.upcase(), segments(at <> route.route)}
  end

  defp open_routes(:graphql, _at), do: []

  defp segments(path), do: String.split(path, "/", trim: true)
end
