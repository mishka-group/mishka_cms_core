defmodule MishkaCmsCore.TestRouter do
  @moduledoc """
  The routes this library's tests drive, mirroring the two scopes the CMS puts it in.

  `/api/json` is the CMS's `:api` pipeline — the tenant lookup that resolves a request's site from
  its host, CORS, the address the sign-in limit counts, then the bearer token and the actor it
  names, and the admin surface (the API's, so an area is held by its `admin:api:` name).
  Dropping any of them changes what the API does, since tenancy and authorization are
  enforced through them.

  `/admin/dashboard` is the CMS's `:browser` pipeline, and mounts this library's own admin LiveViews
  through `extension_routes(:admin)` — the same macro the CMS uses, reading
  `config :mishka_cms_core, :extensions`, which here lists only `MishkaCmsCoreWeb`. The `on_mount`
  hooks are `MishkaCmsCore.LiveUserAuth`, standing in for the host's.

  See `MishkaCmsCore.TestJsonApiRouter` for which domains the API mounts.
  """

  use Phoenix.Router

  # `extension_routes/1` expands to `live/3` calls; `use MishkaCmsWeb, :router` gives the CMS these.
  import Phoenix.LiveView.Router
  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.ExtensionRouter
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]
  import MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, only: [confirm_bearer_tenant: 2]

  pipeline :api do
    plug :accepts, ["json"]
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
    plug MishkaCmsCore.Runtime.Plugs.AuthRateLimitPlug
    plug :load_from_bearer
    plug :confirm_bearer_tenant
    plug :set_actor, :user
    plug MishkaCmsCore.Runtime.Plugs.AdminSurfacePlug, surface: :api
  end

  pipeline :browser do
    plug :route_accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaCmsCore.TestLayouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
    plug :set_actor, :user
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/", MishkaCmsCore.TestJsonApiRouter
  end

  # The /auth routes this library owns, mounted exactly as the CMS mounts them: the
  # AshAuthentication controller routes and the DELETE the sign-out page posts to. The sign-in pages
  # are the CMS's runtime pages, which this harness has no catch-all to serve.
  scope "/" do
    pipe_through [:browser]

    auth_routes MishkaCmsCoreWeb.AuthController, MishkaCmsCore.Accounts.User, path: "/api/auth"

    delete "/auth/sign-out", MishkaCmsCoreWeb.AuthController, :sign_out, as: :auth
  end

  scope "/admin/dashboard" do
    pipe_through [:browser]

    ash_authentication_live_session :test_authenticated_routes,
      on_mount: [
        {MishkaCmsCore.LiveUserAuth, :live_user_required},
        {MishkaCmsCore.LiveUserAuth, {:require_permission, [{:under, "admin:dashboard"}]}}
      ] do
      extension_routes(:admin)
    end
  end
end
