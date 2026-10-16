# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug do
  @moduledoc """
  Names the admin surface a pipeline's requests come from, so that a policy listing both surfaces'
  names counts only this surface's: `permissions: ["admin:dashboard:runtime:page", "admin:api:runtime:page"]` on
  `MishkaCmsCore.Accounts.Checks.AccessPermissions` takes `admin:api:runtime:page` on the API and
  `admin:dashboard:runtime:page` on the dashboard.

      pipeline :api do
        plug :accepts, ["json"]
        ...
        plug :set_actor, :user
        plug MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug, surface: :api
      end

  The surface goes into the `:shared` map of the Ash context (`Ash.PlugHelpers.update_context/2`).
  AshJsonApi and `AshGraphql.Plug` hand that context to every action, and `:shared` reaches the loads
  an action makes. Whatever else the context holds is kept. A request no pipeline named is the
  dashboard's.

  For `AshGraphql.Plug` to carry it, this plug runs before that one.

  A socket has no conn: `put/2` merges the surface into a context map instead.

      Absinthe.Phoenix.Socket.put_options(socket,
        context: %{actor: actor, tenant: tenant, context: AdminSurfacePlug.put(%{}, :api)}
      )
  """
  @behaviour Plug

  @surfaces [:dashboard, :api]

  @impl Plug
  def init(opts) do
    surface = Keyword.get(opts, :surface)

    if surface in @surfaces,
      do: surface,
      else: raise(ArgumentError, "surface: must be one of #{inspect(@surfaces)}")
  end

  @impl Plug
  def call(conn, surface), do: Ash.PlugHelpers.update_context(conn, &put(&1, surface))

  @doc """
  `context` with `surface` as its `admin_surface`, the rest of it kept. `nil` is an empty context.

      AdminSurfacePlug.put(%{shared: %{locale: "en"}}, :api)
      #=> %{shared: %{locale: "en", admin_surface: :api}}
  """
  @spec put(map() | nil, :dashboard | :api) :: map()
  def put(context, surface) do
    Map.update(context || %{}, :shared, %{admin_surface: surface}, fn shared ->
      Map.put(shared || %{}, :admin_surface, surface)
    end)
  end
end
