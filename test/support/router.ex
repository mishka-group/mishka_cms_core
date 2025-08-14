defmodule MishkaCmsCore.TestRouter do
  @moduledoc """
  The routes this library's tests drive, mirroring the two scopes the CMS puts it in.

  `/api/json` is the CMS's `:api` pipeline — the tenant lookup that resolves a request's site from
  its host, and CORS. Dropping any of them changes what the API does, since tenancy and
  authorization are enforced through them.

  See `MishkaCmsCore.TestJsonApiRouter` for which domains the API mounts.
  """

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
  end

  pipeline :browser do
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/", MishkaCmsCore.TestJsonApiRouter
  end
end
