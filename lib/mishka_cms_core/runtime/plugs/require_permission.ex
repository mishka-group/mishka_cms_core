# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsWeb.Runtime.Plugs.RequirePermission do
  @moduledoc """
  Refuses a request whose user holds none of the permissions a route requires.

  The required list is any-of: holding one entry is enough. An entry is a permission name, which a
  held wildcard covers (`admin:dashboard:*` covers `admin:dashboard:runtime:page`), or `{:under, prefix}` for
  anyone holding anything under `prefix` — `MishkaCmsCore.Accounts.Checks.AccessPermissions`
  answers, with the conn's Ash context: behind
  `MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug, surface: :api` an `admin:api:…` name counts and an
  `admin:dashboard:…` one does not, and elsewhere the reverse. An empty list admits nobody.

      # The admin API's docs: anyone holding anything under admin:api
      plug MishkaCmsWeb.Runtime.Plugs.RequirePermission,
        permissions: [{:under, "admin:api"}],
        on_denied: :json

      # One area on the screens
      plug MishkaCmsWeb.Runtime.Plugs.RequirePermission,
        permissions: ["admin:dashboard:runtime:media"]

  ## Options

    * `:permissions` — the required list.
    * `:on_denied` — `:redirect` (the default) flashes "You don't have permission to access this
      page" and redirects to `/`; `:json` answers a JSON:API `403`, for the `/api/json` and `/gql`
      pipelines, which fetch no flash.

  ## Events

  - `web:request:before_permission_gate` — the conn, before it is asked.
  - `web:request:permission_gate` — the conn it answered with, with `%{authorized: boolean}` as its
    meta.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn
  import Phoenix.Controller
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaInstaller.Event.Hook

  @doc "The required list and how a refusal is answered, from `:permissions` and `:on_denied`."
  def init(opts) do
    case Keyword.get(opts, :on_denied, :redirect) do
      :json -> {Keyword.get(opts, :permissions, []), :json}
      :redirect -> Keyword.get(opts, :permissions, [])
    end
  end

  @doc "Passes the conn when its `:current_user` holds any required permission, else refuses it."
  def call(conn, {permissions, mode}), do: enforce(conn, permissions, mode)
  def call(conn, permissions), do: enforce(conn, permissions, :redirect)

  defp enforce(conn, permissions, mode) do
    :telemetry.span(
      [:mishka_cms, :runtime, :plugs, :require_permission],
      %{path: conn.request_path, method: conn.method, permissions: permissions},
      fn ->
        conn = Hook.call("web:request:before_permission_gate", conn)
        current_user = conn.assigns[:current_user]
        context = Ash.PlugHelpers.get_context(conn) || %{}
        authorized = AccessPermissions.match?(current_user, context, permissions: permissions)

        result =
          if(authorized, do: conn, else: refuse(conn, mode))
          |> then(&Hook.call("web:request:permission_gate", &1, meta: %{authorized: authorized}))

        {result, %{user_id: current_user && current_user.id, authorized: authorized}}
      end
    )
  end

  # How a denial is DELIVERED is declared by the route, not guessed from the conn. `:redirect` (the
  # default) is the browser answer. `:json` is for the `/api/json` and `/gql` pipelines, which never
  # run `fetch_flash` — `put_flash/3` RAISES there, turning a refusal into a 500 that merely looks
  # like a crash. Guessing from the conn was worse: a browser conn that happens not to have fetched
  # a flash yet would silently start answering JSON.
  defp refuse(conn, :json) do
    conn
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(
      403,
      Jason.encode!(%{
        errors: [
          %{
            status: "403",
            code: "forbidden",
            title: gettext("Forbidden"),
            detail: gettext("You don't have permission to access this resource")
          }
        ]
      })
    )
    |> halt()
  end

  defp refuse(conn, :redirect) do
    conn
    |> put_flash(:error, gettext("You don't have permission to access this page"))
    |> redirect(to: "/")
    |> halt()
  end
end
