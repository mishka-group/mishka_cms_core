defmodule MishkaCmsCore.TestRouter do
  @moduledoc """
  The routes this library's tests drive, mirroring the two scopes the CMS puts it in.

  `/api/json` is the CMS's `:api` pipeline — the tenant lookup that resolves a request's site from
  its host, CORS, then the bearer token and the actor it names. Dropping any of them changes
  what the API does, since tenancy and authorization are enforced through them.

  See `MishkaCmsCore.TestJsonApiRouter` for which domains the API mounts.
  """

  use Phoenix.Router

  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, only: [confirm_bearer_tenant: 2]

  pipeline :api do
    plug :accepts, ["json"]
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
    plug :load_from_bearer
    plug :confirm_bearer_tenant
    plug :set_actor, :user
  end

  pipeline :browser do
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/", MishkaCmsCore.TestJsonApiRouter
  end
end
