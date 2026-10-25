# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.SiteLookupPlug do
  @moduledoc """
  Site lookup plug for multi-site applications with host-based site resolution.

  This plug identifies the current site based on the incoming HTTP Host header and stores
  site information in both connection assigns and session for use throughout the request
  lifecycle in controllers and LiveViews.

  ## Features

  - Host-based site resolution with port normalization
  - Automatic site state caching and retrieval via SiteState
  - Master sessions: a master's own token leaves the master site's requests unscoped
  - Tenant isolation using Ash framework integration
  - Graceful error handling with custom 503 pages
  - Session persistence for site information

  ## Workflow

  1. **Host Extraction**: Extracts and normalizes host from request headers
  2. **Site Lookup**: Queries SiteState cache for host-to-site mapping
  3. **Site Validation**: Checks site active status
  4. **Redirects**: An address one of the site's redirect rules names is answered with that redirect
     and halted, before the session is touched — see `MishkaCmsCore.Runtime.Redirects`
  5. **Sign-in Pool**: On the master site, `?master_user=` picks the accounts its sign-in page uses
  6. **Tenant Assignment**: Sets Ash tenant context from the session's token
  7. **State Storage**: Persists site data in assigns and session

  ## Usage

  Add it to the browser pipeline after the session is fetched and before `:load_from_session`, with
  `confirm_tenant/2` straight after `:load_from_session`. The order is the rule: `:load_from_session`
  verifies the session's token against the tenant this plug chose, and `confirm_tenant/2` checks the
  user that verification loaded.

  ```elixir
  import AshAuthentication.Plug.Helpers
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
  end

  scope "/", MyAppWeb do
    pipe_through :browser
    # Your routes here
  end
  ```

  ## Masters

  A master is a user with no site. Whether a request belongs to one is read from the signed-in
  user's own token, never from the address: a master's token is issued with no site, and
  `:load_from_session` recognises it only on a request this plug left unscoped. The master site —
  the one whose record has `master: true` — leaves a request unscoped for such a token; every other
  site scopes every request to itself, so a master signs in on the master site's address and
  nowhere else.

  Before anyone is signed in, the master site's sign-in page is told which accounts to use:

  ```elixir
  # The master accounts
  "/auth?master_user=true"

  # The site's own accounts
  "/auth?master_user=false"
  ```

  The choice is kept in the session as `:master_mode` and unscopes only the sign-in pages of a
  visitor with no token — the addresses `sign_in_path?/2` names. It grants no access, a signed-in
  user's token outranks it, and every other site ignores it and forgets any it finds, telling a
  plugin on `web:request:master_sign_in_refused` with `%{site: site}`.

  `confirm_tenant/2` runs after `:load_from_session` and holds the rest of the rule: an unscoped
  request is a master's, or a visitor's on that sign-in page.

  ## Site Resolution Examples

  ```elixir
  # Request: example.com -> Looks up site by "example.com"
  # Request: example.com:4000 -> Normalizes to "example.com"
  # Request: subdomain.example.com -> Looks up site by "subdomain.example.com"
  ```

  ## Error Handling

  - **Site Not Found**: Returns 503 with "Service Unavailable" page
  - **Inactive Site**: Returns 503 with "Site Temporarily Unavailable" page
  - **Missing Host**: Treated as site not found scenario

  ## Integration with Other Components

  - **SiteState**: Leverages runtime state management for fast site lookups
  - **Ash Framework**: Automatic tenant context setting for multi-tenant data isolation
  - **Session Management**: Persists site information across requests
  - **LiveView**: Site information available in LiveView assigns

  ## Production Considerations

  - Host header validation should be handled at load balancer level
  - Site state caching reduces database queries for each request
  - The master site's address should be known only to its masters: no other site links to it
  - Error pages are cached and served efficiently
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Plug.Conn

  alias MishkaCmsCore.Accounts.AuthGate
  alias MishkaCmsCore.Runtime.{Languages, Redirects}
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.Hook

  # Where `AshAuthentication` keeps the signed-in user's token in the session.
  @session_token "user_token"

  # The pages a sign-in happens on, as whole path segments: `/authors` is a page like any other.
  @sign_in_paths [["auth"], ["api", "auth"]]

  # Where the site's sign-in pages are stored — `MishkaCmsCore.Install.StarterContent.ensure_auth!/1`.
  @sign_in_page "/:lang/auth"

  @doc """
  Initializes the plug with configuration options.

  Currently accepts no specific configuration options and returns an empty map.
  This allows for future extensibility without breaking existing implementations.

  ## Parameters

  - `opts` - Plug initialization options (currently unused)

  ## Returns

  Empty map `%{}` for plug state

  ## Examples

  ```elixir
  # Standard usage in router
  plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug

  # With explicit options (currently unused)
  plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, %{}
  ```
  """
  def init(_opts) do
    %{}
  end

  @doc """
  Performs site lookup based on Host header and manages site context.

  This is the main plug function that orchestrates the entire site resolution workflow:
  1. Extracts and normalizes the host from request headers
  2. Queries SiteState for site information by host
  3. Validates site status and manages tenant context
  4. Stores site information in connection assigns and session

  The options `init/1` returns are not used.

  ## Returns

  Modified `Plug.Conn` with:
  - `:current_site` assign containing site data (if found and active)
  - `:current_site` session data for persistence
  - Ash tenant context set for multi-tenant data isolation
  - HTTP 503 response for inactive or missing sites

  ## Examples

  ```elixir
  # Successful site lookup
  conn = SiteLookupPlug.call(conn, %{})
  site = conn.assigns[:current_site]
  # => %MishkaCms.Content.Site{host: "example.com", active: true, ...}

  # Access in controller
  def index(conn, _params) do
    site = conn.assigns[:current_site]
    render(conn, "index.html", site: site)
  end

  # Access in LiveView
  def mount(_params, session, socket) do
    site = session["current_site"]
    {:ok, assign(socket, :site, site)}
  end
  ```

  ## Response Scenarios

  - **Active Site Found**: Connection continues with site context
  - **Redirected Address**: The rule's status and `location`, halted, with `:current_site` assigned
  - **Inactive Site**: 503 "Site Temporarily Unavailable" response
  - **Site Not Found**: 503 "Service Unavailable" response
  - **Master session on the master site**: Site context set, no tenant
  """

  def call(conn, opts) do
    :telemetry.span(
      [:mishka_cms, :runtime, :plugs, :site_lookup],
      %{path: conn.request_path, method: conn.method},
      fn ->
        conn = Hook.call("web:request:before_site_resolve", conn)
        host = get_host(conn, opts)

        result =
          case site_for(host) do
            {:ok, site} ->
              handle_site_found(conn, site)

            {:error, :not_found} ->
              handle_site_not_found(conn)
          end
          # request-lifecycle seam: a plugin may transform the conn (redirect / maintenance mode /
          # geo-block / inject assigns) or `Plug.Conn.halt/1` it. No plugin -> conn unchanged.
          |> then(&Hook.call("web:request:after_site_resolve", &1, meta: %{host: host}))

        site = result.assigns[:current_site]

        {result,
         %{host: host, site: site && site.name, site_id: site && site.id, found: !is_nil(site)}}
      end
    )
  end

  @doc """
  Confirms the tenant `call/2` chose, once `:load_from_session` has read the session's user.

  Plug it in straight after `:load_from_session`, imported from this module:

  ```elixir
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]

  pipeline :browser do
    # ...
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
  end
  ```

  A request stays unscoped only for a master, a user whose `site_id` is nil, or for a visitor on the
  master site's sign-in pages who asked for the master accounts. Anyone else on an unscoped request —
  a user with a site, or one that carries no `site_id` at all — is signed out of it: `:current_user` becomes `nil`, the token leaves the session, the request is
  scoped to the site, and a plugin on `web:request:session_refused` hears it with
  `%{site: site, user_id: id}`. An unscoped request whose token did not verify is scoped to the site.

  A user the site's closed sign-in signs out (`MishkaCmsCore.Accounts.AuthGate.signs_out?/2`) is
  signed out everywhere, their session cleared, and sent to the front page with the reason.
  """
  @spec confirm_tenant(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def confirm_tenant(%Plug.Conn{assigns: %{current_site: %{id: site_id} = site}} = conn, _opts) do
    case {Ash.PlugHelpers.get_tenant(conn), conn.assigns[:current_user]} do
      {nil, %{site_id: nil}} ->
        conn

      {nil, nil} ->
        if master_sign_in?(conn, site), do: conn, else: Ash.PlugHelpers.set_tenant(conn, site_id)

      {nil, user} ->
        refuse_session(conn, site, user)

      {site_id, %{} = user} ->
        if AuthGate.signs_out?(site_id, user), do: sign_out(conn, site_id, user), else: conn

      _scoped ->
        conn
    end
  end

  def confirm_tenant(conn, _opts), do: conn

  @doc """
  Whether `segments` — a request path split into its segments, as `conn.path_info` holds it — is an
  address a sign-in happens on for `site`: `/auth`, `/api/auth` and every address under them, and
  `/<language>/auth` and every address under it when `<language>` is one of the site's languages
  (`MishkaCmsCore.Runtime.Languages.site/1`). Whole segments only, so `/authors` is a page like any
  other. `nil` for `site` recognises only the addresses without a language.

  Every rule that treats the sign-in pages apart asks this: the master accounts' unscoped sign-in
  here, `MishkaCms.Plugs.MaintenanceGate` and `MishkaCmsCore.Runtime.SiteAvailability` keeping them
  open on an offline site, and `MishkaCmsWeb.RuntimeLive` loading the app's own client on them.

      SiteLookupPlug.sign_in_path?(["en", "auth", "register"], site) #=> true
      SiteLookupPlug.sign_in_path?(["api", "auth", "user"], site)    #=> true
      SiteLookupPlug.sign_in_path?(["xx", "auth"], site)             #=> false
      SiteLookupPlug.sign_in_path?(["authors"], site)                #=> false
  """
  @spec sign_in_path?(
          [String.t()],
          %{required(:id) => String.t(), optional(atom()) => term()} | nil
        ) ::
          boolean()
  def sign_in_path?(segments, site) do
    Enum.any?(@sign_in_paths, &List.starts_with?(segments, &1)) or
      language_sign_in_path?(segments, site)
  end

  defp language_sign_in_path?([language, "auth" | _rest], %{id: site_id}),
    do: language in Languages.site(site_id)

  defp language_sign_in_path?(_segments, _site), do: false

  @doc """
  The address of the site's sign-in page in `language`, or of the page `under` it — `/:lang/auth`
  as `MishkaCmsCore.Runtime.Languages.url/3` builds it, so a visitor sent to sign in, or to sign
  out, lands on the page in the language they were reading. A language the site does not publish
  in, and `nil`, are the site's first.

  Every place that sends a visitor to sign in asks this, with the language they read pages in: the
  socket's for a runtime page, the session's (`MishkaCmsCore.Runtime.Languages.session/0`) anywhere
  else.

      # site.languages ["en", "fa"], site.language_urls "prefix_others"
      SiteLookupPlug.auth_address("fa", site.id)                #=> "/fa/auth"
      SiteLookupPlug.auth_address(nil, site.id)                 #=> "/auth"
      SiteLookupPlug.auth_address("en", site.id, "/sign-out")   #=> "/auth/sign-out"
  """
  @spec auth_address(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def auth_address(language, site_id, under \\ "") do
    language = Languages.remembered(language, site_id) || Languages.primary(site_id)
    Languages.url(@sign_in_page <> under, %{Languages.capture() => language}, site_id)
  end

  @doc """
  The site a request's `host` names — the `Host` header without its port, as
  `MishkaCmsCore.Runtime.OriginValidator.host_name/1` reads it — as
  `MishkaCmsCore.Runtime.States.SiteState.get_by_host/1` answers.

  In a build whose config sets `:env_dev?` or `:env_test?`, `localhost` and `127.0.0.1` are the
  master site while no site has that host. A release has no such clause: there they name the site
  that has them, as every other host does, or none.

  This plug and `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug` both resolve a request's site
  through it, so a page and an API call on the same address reach the same site.

      SiteLookupPlug.site_for("blog.example.com")  #=> {:ok, %{host: "blog.example.com", ...}}
      SiteLookupPlug.site_for("localhost")         #=> {:ok, %{master: true, ...}} in dev and test
      SiteLookupPlug.site_for("unknown.example")   #=> {:error, :not_found}
  """
  @spec site_for(String.t() | nil) :: {:ok, map()} | {:error, :not_found}

  # LOCALHOST IS THE MASTER SITE while no site claims it, so a site whose database knows it only by
  # its public address opens locally with nothing to configure. Compiled only where the app's config
  # sets `:env_dev?` or `:env_test?`, so a release has no such clause. Not `Mix.env/0`: a dependency
  # is compiled in `:prod` whatever the app runs in.
  if Application.compile_env(:mishka_cms_core, :env_dev?, false) or
       Application.compile_env(:mishka_cms_core, :env_test?, false) do
    def site_for(host) when host in ["localhost", "127.0.0.1"] do
      with {:error, :not_found} <- SiteState.get_by_host(host), do: SiteState.get_by_master()
    end
  end

  def site_for(host), do: SiteState.get_by_host(host)

  # Private functions

  @doc false
  @spec get_host(Plug.Conn.t(), map()) :: String.t() | nil
  defp get_host(conn, _opts) do
    case get_req_header(conn, "host") do
      [host | _] ->
        # Remove port if present (e.g., "example.com:4000" -> "example.com")
        # This ensures consistent host matching regardless of development ports
        MishkaCmsCore.Runtime.OriginValidator.host_name(host)

      [] ->
        # No host header found - this can happen in certain test scenarios
        # or malformed requests
        nil
    end
  end

  @doc false
  @spec handle_site_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  # sobelow_skip ["XSS.SendResp"]
  # A fixed page: it interpolates only this library's compiled gettext messages and an escaped CSP
  # nonce.
  defp handle_site_found(conn, site) do
    cond do
      not site.active ->
        site_inactive(conn, site)

      api_only?(site) ->
        # Site is API-only - show error page for web access
        conn
        |> put_status(403)
        |> put_resp_content_type("text/html")
        |> send_resp(403, """
          <!DOCTYPE html>
          <html>
            <head>
              <title>#{gettext("Access Not Allowed")}</title>
              <style#{nonce_attr(conn)}>
                body {
                  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                  text-align: center;
                  padding: 50px;
                  background-color: #f5f5f5;
                  color: #333;
                }
                .container {
                  max-width: 600px;
                  margin: 0 auto;
                  background: white;
                  padding: 40px;
                  border-radius: 8px;
                  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                }
                h1 {
                  color: #e74c3c;
                  margin-bottom: 20px;
                }
                p {
                  color: #666;
                  line-height: 1.6;
                }
                .error-code {
                  font-size: 72px;
                  font-weight: bold;
                  color: #ddd;
                  margin-bottom: 20px;
                }
              </style>
            </head>
            <body>
              <div class="container">
                <div class="error-code">403</div>
                <h1>#{gettext("Web Access Not Allowed")}</h1>
                <p>#{gettext("This site is configured for API access only.")}</p>
                <p>#{gettext("Web interface access is not permitted.")}</p>
              </div>
            </body>
          </html>
        """)
        |> halt()

      true ->
        conn
        |> assign(:current_site, site)
        |> Redirects.redirect(site)
        |> serve(site)
    end
  end

  # A REDIRECTED REQUEST IS ANSWERED ALREADY: the address it asked for is none of this site's pages, so
  # nothing is written to its session.
  defp serve(%Plug.Conn{halted: true} = conn, _site), do: conn

  defp serve(conn, site) do
    conn
    |> put_session(:current_site, site)
    |> sign_in_pool(site)
    |> scope(site)
  end

  # The page's own `<style>` is marked with the request's CSP nonce when `SecurityHeaders` has minted
  # one, so a policy that enforces still lets this page draw.
  defp nonce_attr(conn) do
    case SecurityHeaders.nonce(conn) do
      nonce when is_binary(nonce) -> ~s( nonce="#{Plug.HTML.html_escape(nonce)}")
      _no_nonce -> ""
    end
  end

  @doc false
  @spec handle_site_not_found(Plug.Conn.t()) :: Plug.Conn.t()
  # sobelow_skip ["XSS.SendResp"]
  # A fixed page: it interpolates only this library's compiled gettext messages and an escaped CSP
  # nonce.
  defp handle_site_not_found(conn) do
    # No site found for the requested host - return service unavailable
    # This could indicate:
    # - Host not registered in the system
    # - Typo in domain name
    # - Site configuration issue
    conn
    |> put_status(503)
    |> put_resp_content_type("text/html")
    |> send_resp(503, """
      <!DOCTYPE html>
      <html>
        <head>
          <title>#{gettext("Service Unavailable")}</title>
          <style#{nonce_attr(conn)}>
            body {
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
              text-align: center;
              padding: 50px;
              background-color: #f5f5f5;
              color: #333;
            }
            .container {
              max-width: 600px;
              margin: 0 auto;
              background: white;
              padding: 40px;
              border-radius: 8px;
              box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }
            h1 {
              color: #666;
              margin-bottom: 20px;
            }
            p {
              color: #777;
              line-height: 1.6;
            }
            .error-code {
              font-size: 72px;
              font-weight: bold;
              color: #ddd;
              margin-bottom: 20px;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <div class="error-code">503</div>
            <h1>#{gettext("Service Unavailable")}</h1>
            <p>#{gettext("No server available for this domain.")}</p>
            <p>#{gettext("Please check the domain name and try again.")}</p>
          </div>
        </body>
      </html>
    """)
    |> halt()
  end

  # A plugin on `web:request:site_unavailable` may answer with a page of its own by halting the conn;
  # otherwise the built-in one is sent.
  defp site_inactive(conn, site) do
    conn =
      Hook.call("web:request:site_unavailable", conn, meta: %{state: :inactive, site: site})

    if conn.halted, do: conn, else: send_inactive_page(conn)
  end

  # BUILT IN, NOT AN ERROR PAGE. A switched-off site's own pages are not served, and an address can
  # reach here whose site is gone from the database altogether, so this page needs nothing loaded.
  # It is not the offline page: that one is the site's own, under its admin's control.
  # sobelow_skip ["XSS.SendResp"]
  # A fixed page: it interpolates only this library's compiled gettext messages and an escaped CSP
  # nonce.
  defp send_inactive_page(conn) do
    conn
    |> put_status(503)
    |> put_resp_content_type("text/html")
    |> send_resp(503, """
      <!DOCTYPE html>
      <html>
        <head>
          <title>#{gettext("Site Not Available")}</title>
          <style#{nonce_attr(conn)}>
            body {
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
              text-align: center;
              padding: 50px;
              background-color: #f5f5f5;
              color: #333;
            }
            .container {
              max-width: 600px;
              margin: 0 auto;
              background: white;
              padding: 40px;
              border-radius: 8px;
              box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }
            h1 {
              color: #e74c3c;
              margin-bottom: 20px;
            }
            p {
              color: #666;
              line-height: 1.6;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>#{gettext("This site is not available")}</h1>
            <p>#{gettext("Please check back later.")}</p>
          </div>
        </body>
      </html>
    """)
    |> halt()
  end

  # WHICH ACCOUNTS THE SIGN-IN PAGE SIGNS IN WITH, and nothing more. On the master site
  # `?master_user=true` picks its masters and `?master_user=false` its own accounts, kept for the
  # requests that sign-in goes on to make. Any other site signs in only its own accounts: the flag is
  # ignored, one left in the session is forgotten, and a plugin hears the refusal.
  defp sign_in_pool(%Plug.Conn{params: %{"master_user" => "true"}} = conn, %{master: true}),
    do: put_session(conn, :master_mode, true)

  defp sign_in_pool(%Plug.Conn{params: %{"master_user" => "false"}} = conn, %{master: true}),
    do: delete_session(conn, :master_mode)

  defp sign_in_pool(conn, %{master: true}), do: conn

  defp sign_in_pool(conn, site) do
    conn
    |> delete_session(:master_mode)
    |> refuse_master_sign_in(site)
  end

  defp refuse_master_sign_in(%Plug.Conn{params: %{"master_user" => "true"}} = conn, site) do
    Hook.call("web:request:master_sign_in_refused", conn, meta: %{site: site})
  end

  defp refuse_master_sign_in(conn, _site), do: conn

  # THE TENANT IS THE SIGNED-IN USER'S, read from the token the session holds. `:load_from_session`
  # verifies that token against the tenant set here, so a master's — issued with no site — is
  # recognised only on a request left unscoped, and a site user's only on one scoped to their site.
  # The token is only peeked at: the next plug verifies it, and the session cookie that carries it is
  # signed by this application.
  defp scope(conn, %{master: true} = site) do
    if unscoped?(conn, site), do: conn, else: Ash.PlugHelpers.set_tenant(conn, site.id)
  end

  defp scope(conn, site), do: Ash.PlugHelpers.set_tenant(conn, site.id)

  defp unscoped?(conn, site) do
    case get_session(conn, @session_token) do
      token when is_binary(token) -> master_token?(token)
      _no_token -> master_sign_in?(conn, site)
    end
  end

  # A token issued with no site carries `"tenant": null`, which reads back as `:null`.
  defp master_token?(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, %{"tenant" => tenant}} -> tenant in [nil, :null]
      _no_site_claim_or_not_a_token -> false
    end
  end

  # A visitor who asked the master site's sign-in page for the master accounts, on that page or on
  # the requests it makes to sign in.
  defp master_sign_in?(%Plug.Conn{path_info: path} = conn, site) do
    get_session(conn, :master_mode) == true and sign_in_path?(path, site)
  end

  defp sign_out(conn, site_id, user) do
    AuthGate.sign_out(user, site_id)
    %{title: title, text: text} = AuthGate.describe(:sign_in)

    conn
    |> assign(:current_user, nil)
    |> clear_session()
    |> Phoenix.Controller.put_flash(:error, "#{title}. #{text}")
    |> Phoenix.Controller.redirect(to: MishkaCmsCore.Helpers.path(conn, "/"))
    |> halt()
  end

  defp refuse_session(conn, site, user) do
    conn
    |> assign(:current_user, nil)
    |> delete_session(@session_token)
    |> Ash.PlugHelpers.set_tenant(site.id)
    |> then(
      &Hook.call("web:request:session_refused", &1,
        meta: %{site: site, user_id: Map.get(user, :id)}
      )
    )
  end

  # `Site.mode` is an atom on the resource and `SiteState` normalises to the same, so this compares
  # atoms. Written against the string `"api_only"` it was silently never true, and an API-only site
  # served the web pages it exists to refuse.
  defp api_only?(%{mode: :api_only}), do: true
  defp api_only?(_site), do: false
end
