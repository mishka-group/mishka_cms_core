# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.SiteLookupPlugTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.EventCannotRun
  @moduletag :unit

  # Helper to create a conn with proper host header
  defp conn_with_host(method, path, host) do
    conn(method, path)
    |> Map.put(:req_headers, [{"host", host}])
  end

  defp request(path, host, session \\ %{}) do
    conn_with_host(:get, path, host)
    |> init_test_session(session)
    |> fetch_query_params()
    |> SiteLookupPlug.call(%{})
  end

  defp tenant(conn), do: Ash.PlugHelpers.get_tenant(conn)

  # The token the account was issued when it was made, carrying the site it was made in as a claim.
  defp token(user), do: user.__metadata__.token

  # The three plugs of the `:browser` pipeline that decide who is asking, on the master site.
  defp through_pipeline(path, session) do
    path
    |> request("master.example.com", session)
    |> AshAuthentication.Plug.Helpers.retrieve_from_session(:mishka_cms_core)
    |> SiteLookupPlug.confirm_tenant([])
  end

  # A user of `site_id` whose token names no site, as one issued before the account was given a site.
  defp issued_with_no_site(site_id) do
    MishkaCmsCore.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "moved-#{System.unique_integer([:positive])}@example.com",
        password: "Password123!",
        password_confirmation: "Password123!"
      },
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:site_id, site_id)
    |> Ash.create!()
  end

  defp forget_languages(site) do
    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)
  end

  defp cached_site!(host, master?) do
    site = create_site!(name: host, host: host, active: true, master: master?)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: true,
        master: master?
      })

    site
  end

  setup do
    # Ensure SiteState is running and clear any existing data
    case GenServer.whereis(SiteState) do
      nil -> {:ok, _pid} = SiteState.start_link()
      _pid -> :ok
    end

    SiteState.clear()

    on_exit(fn ->
      SiteState.clear()
    end)

    {:ok, %{}}
  end

  describe "init/1" do
    test "returns empty map for options" do
      assert SiteLookupPlug.init([]) == %{}
      assert SiteLookupPlug.init(%{option: "value"}) == %{}
    end
  end

  describe "call/2 with active site" do
    setup do
      # Create an active site
      site_attrs = %{
        id: "active-site-123",
        name: "Active Site",
        host: "active.example.com",
        priority: 100,
        active: true,
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)
      {:ok, %{site: site_attrs}}
    end

    test "assigns current_site for active site", %{site: site} do
      conn =
        conn_with_host(:get, "/", "active.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      refute result_conn.halted
      assert result_conn.assigns.current_site.id == site.id
      assert result_conn.assigns.current_site.host == "active.example.com"
      assert get_session(result_conn, :current_site).id == site.id
    end

    test "sets tenant context for active site", %{site: site} do
      conn =
        conn_with_host(:get, "/", "active.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      # Check that Ash tenant is set
      assert result_conn.private.ash.tenant == site.id
    end

    test "handles port in host header", %{site: site} do
      conn =
        conn_with_host(:get, "/", "active.example.com:4000")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      refute result_conn.halted
      assert result_conn.assigns.current_site.id == site.id
    end

    test "handles multiple host headers by using first", %{site: site} do
      # Create a conn with multiple host headers - the first should be used
      conn =
        conn(:get, "/")
        |> Map.put(:req_headers, [{"host", "active.example.com"}, {"host", "other.example.com"}])
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      refute result_conn.halted
      assert result_conn.assigns.current_site.id == site.id
    end
  end

  describe "call/2 with inactive site" do
    setup do
      # Create an inactive site
      site_attrs = %{
        id: "inactive-site-456",
        name: "Inactive Site",
        host: "inactive.example.com",
        priority: 100,
        active: false,
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)
      {:ok, %{site: site_attrs}}
    end

    test "returns 503 for inactive site", %{} do
      conn =
        conn_with_host(:get, "/", "inactive.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      assert result_conn.status == 503
      assert result_conn.resp_body =~ "This site is not available"
      refute result_conn.resp_body =~ "maintenance", "an inactive site read as the offline page"
    end

    test "does not assign current_site for inactive site", %{} do
      conn =
        conn_with_host(:get, "/", "inactive.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      refute Map.has_key?(result_conn.assigns, :current_site)
    end
  end

  describe "call/2 with api_only mode" do
    setup do
      # Create an API-only site
      site_attrs = %{
        id: "api-site-789",
        name: "API Only Site",
        host: "api.example.com",
        priority: 100,
        active: true,
        mode: :api_only,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)
      {:ok, %{site: site_attrs}}
    end

    test "returns 403 for api_only site", %{} do
      conn =
        conn_with_host(:get, "/", "api.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      assert result_conn.status == 403
      assert result_conn.resp_body =~ "Web Access Not Allowed"
      assert result_conn.resp_body =~ "API access only"
    end

    test "shows 403 error code in response", %{} do
      conn =
        conn_with_host(:get, "/", "api.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.resp_body =~ "403"
    end
  end

  describe "call/2 with phoenix_only mode" do
    setup do
      # Create a Phoenix-only site (should allow web access)
      site_attrs = %{
        id: "phoenix-site-999",
        name: "Phoenix Only Site",
        host: "phoenix.example.com",
        priority: 100,
        active: true,
        mode: :phoenix_only,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)
      {:ok, %{site: site_attrs}}
    end

    test "allows access for phoenix_only mode", %{site: site} do
      conn =
        conn_with_host(:get, "/", "phoenix.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      refute result_conn.halted
      assert result_conn.assigns.current_site.id == site.id
    end
  end

  # A SITE KNOWN ONLY BY ITS PUBLIC ADDRESS opens at localhost: the master site answers it while no
  # site claims localhost. Dev and test builds only — a release compiles no such clause.
  describe "call/2 at localhost" do
    defp cached!(host, master?) do
      :ok =
        SiteState.save(%{
          id: "site-#{host}",
          name: host,
          host: host,
          priority: 1,
          active: true,
          master: master?
        })

      "site-#{host}"
    end

    test "is the master site while no site claims localhost" do
      master = cached!("new.example.com", true)

      for host <- ["localhost", "127.0.0.1", "localhost:4000"] do
        conn = request("/", host)

        refute conn.halted
        assert conn.assigns.current_site.id == master
      end
    end

    test "is the localhost site when there is one" do
      cached!("new.example.com", true)
      local = cached!("localhost", false)

      assert request("/", "localhost").assigns.current_site.id == local
    end

    test "is still a 503 with no master site" do
      cached!("new.example.com", false)

      conn = request("/", "localhost")

      assert conn.halted
      assert conn.status == 503
    end
  end

  # A POLICY THAT ENFORCES DROPS A `<style>` WITH NO NONCE, so each page this plug answers with its
  # own styles marks them with the nonce `SecurityHeaders` minted, and carries none when it has not
  # run.
  describe "the pages it answers with" do
    setup do
      :ok =
        SiteState.save(%{
          id: "nonce-inactive",
          name: "Nonce Inactive",
          host: "nonce-inactive.example.com",
          priority: 100,
          active: false,
          mode: :hybrid,
          frontend_domain: nil,
          allowed_origins: []
        })

      :ok =
        SiteState.save(%{
          id: "nonce-api",
          name: "Nonce Api",
          host: "nonce-api.example.com",
          priority: 100,
          active: true,
          mode: :api_only,
          frontend_domain: nil,
          allowed_origins: []
        })
    end

    for {label, host} <- [
          {"an unknown host", "nonce-unknown.example.com"},
          {"an inactive site", "nonce-inactive.example.com"},
          {"an api-only site", "nonce-api.example.com"}
        ] do
      @host host

      test "#{label} draws its style with the request's nonce" do
        conn =
          conn_with_host(:get, "/", @host)
          |> init_test_session(%{})
          |> fetch_query_params()
          |> assign(:csp_nonce, "abc123+/=")

        result_conn = SiteLookupPlug.call(conn, %{})

        assert result_conn.halted
        assert result_conn.resp_body =~ ~s(<style nonce="abc123+/=">)
        refute result_conn.resp_body =~ "<style>"
      end

      test "#{label} draws a plain style when no nonce was minted" do
        conn =
          conn_with_host(:get, "/", @host)
          |> init_test_session(%{})
          |> fetch_query_params()

        result_conn = SiteLookupPlug.call(conn, %{})

        assert result_conn.halted
        assert result_conn.resp_body =~ "<style>"
      end
    end
  end

  describe "call/2 with missing site" do
    test "returns 503 for unknown host", %{} do
      conn =
        conn_with_host(:get, "/", "unknown.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      assert result_conn.status == 503
      assert result_conn.resp_body =~ "Service Unavailable"
      assert result_conn.resp_body =~ "No server available"
    end

    test "returns 503 when no host header", %{} do
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      assert result_conn.status == 503
      assert result_conn.resp_body =~ "503"
    end

    test "does not assign current_site for missing site", %{} do
      conn =
        conn_with_host(:get, "/", "nonexistent.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      refute Map.has_key?(result_conn.assigns, :current_site)
    end
  end

  # AN EVENT ONE OF WHOSE PLUGINS IS NOT LOADED answers with the conn it was handed, so the request
  # is answered as it is with no plugin listening.
  describe "call/2 and confirm_tenant/2 while their events cannot run" do
    setup do
      MishkaCmsCore.DataCase.setup_sandbox(%{async: false})
      {:ok, site: cached_site!("plugins-not-loaded.example.com", false)}
    end

    test "resolve the site and refuse ?master_user=true on it", %{site: site} do
      EventCannotRun.stub!([
        "web:request:before_site_resolve",
        "web:request:after_site_resolve",
        "web:request:master_sign_in_refused"
      ])

      result_conn = request("/?master_user=true", site.host)

      refute result_conn.halted
      assert result_conn.assigns.current_site.id == site.id
      assert get_session(result_conn, :current_site).id == site.id
      assert tenant(result_conn) == site.id
    end

    test "answer an inactive site with its 503" do
      EventCannotRun.stub!("web:request:site_unavailable")

      :ok =
        SiteState.save(%{
          id: "inactive-plugins-not-loaded",
          name: "inactive-plugins-not-loaded",
          host: "inactive-plugins-not-loaded.example.com",
          priority: 100,
          active: false
        })

      result_conn = request("/", "inactive-plugins-not-loaded.example.com")

      assert result_conn.halted
      assert result_conn.status == 503
      assert result_conn.resp_body =~ "This site is not available"
    end

    test "sign out a session the site refuses", %{site: site} do
      EventCannotRun.stub!("web:request:session_refused")

      result_conn =
        :get
        |> conn_with_host("/", site.host)
        |> init_test_session(%{"user_token" => "t"})
        |> assign(:current_site, site)
        |> assign(:current_user, %{id: "no-site-id"})
        |> SiteLookupPlug.confirm_tenant([])

      assert result_conn.assigns.current_user == nil
      assert get_session(result_conn, "user_token") == nil
      assert tenant(result_conn) == site.id
    end
  end

  # WHO IS A MASTER IS DECIDED BY THE SESSION'S TOKEN, never by a flag the address wrote. The flag
  # only picks which accounts the MASTER site's own sign-in page signs in with; every other site
  # ignores it and forgets any it finds. Real sites and real tokens, because the tenant this plug
  # chooses is the one `:load_from_session` verifies the token against next.
  describe "master mode functionality" do
    setup do
      MishkaCmsCore.DataCase.setup_sandbox(%{async: false})

      {:ok,
       master_site: cached_site!("master.example.com", true),
       tenant_site: cached_site!("tenant.example.com", false)}
    end

    test "the master site records ?master_user=true for its sign-in page", %{} do
      result_conn = request("/?master_user=true", "master.example.com")

      assert get_session(result_conn, :master_mode) == true
      refute result_conn.halted
    end

    test "the master site forgets it with ?master_user=false", %{} do
      result_conn = request("/?master_user=false", "master.example.com", %{master_mode: true})

      assert get_session(result_conn, :master_mode) == nil
      refute result_conn.halted
    end

    test "the master site keeps it without a parameter", %{} do
      result_conn = request("/", "master.example.com", %{master_mode: true})

      assert get_session(result_conn, :master_mode) == true
      refute result_conn.halted
    end

    test "on the master site, a visitor's flag unscopes the sign-in pages and nothing else", %{
      master_site: master_site
    } do
      for path <- [
            "/auth?master_user=true",
            "/auth/password-reset/token?master_user=true",
            "/api/auth/user/password/sign_in_with_token?master_user=true",
            "/en/auth?master_user=true",
            "/en/auth/register?master_user=true",
            "/en/auth/password-reset/token?master_user=true"
          ] do
        assert tenant(request(path, "master.example.com")) == nil, path
      end

      for path <- [
            "/about?master_user=true",
            "/?master_user=true",
            "/authors?master_user=true",
            "/admin/dashboard?master_user=true",
            "/en/authors?master_user=true",
            "/en/about/auth?master_user=true",
            "/xx/auth?master_user=true",
            "/en/api/auth?master_user=true"
          ] do
        assert tenant(request(path, "master.example.com")) == master_site.id, path
      end
    end

    test "a language the site does not publish in is not a sign-in page", %{
      master_site: master_site
    } do
      forget_languages(master_site)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: master_site.id)

      assert tenant(request("/fa/auth?master_user=true", "master.example.com")) == nil
      assert tenant(request("/de/auth?master_user=true", "master.example.com")) == master_site.id
    end

    test "the sign-in that follows the flag is unscoped without repeating it", %{} do
      result_conn =
        request("/api/auth/user/password/sign_in_with_token", "master.example.com", %{
          master_mode: true
        })

      assert tenant(result_conn) == nil
    end

    test "any other site ignores ?master_user=true and forgets a flag left in the session", %{
      tenant_site: tenant_site
    } do
      for path <- ["/auth?master_user=true", "/?master_user=true", "/auth", "/en/auth"] do
        result_conn = request(path, "tenant.example.com", %{master_mode: true})

        assert tenant(result_conn) == tenant_site.id, path
        assert get_session(result_conn, :master_mode) == nil, path
      end
    end

    test "a signed-in tenant user stays on their site whatever the flag says", %{
      master_site: master_site
    } do
      user = create_user!(site_id: master_site.id)

      for path <- ["/auth?master_user=true", "/"] do
        result_conn =
          request(path, "master.example.com", %{"user_token" => token(user), master_mode: true})

        assert tenant(result_conn) == master_site.id, path
      end
    end

    test "a master's session is unscoped on the master site without any flag", %{} do
      master = create_user!()

      result_conn = request("/", "master.example.com", %{"user_token" => token(master)})

      assert tenant(result_conn) == nil
    end

    test "?master_user=false does not scope a master's session, so a link signs nobody out",
         %{} do
      master = create_user!()

      result_conn =
        request("/auth?master_user=false", "master.example.com", %{
          "user_token" => token(master),
          master_mode: true
        })

      assert tenant(result_conn) == nil
      assert get_session(result_conn, :master_mode) == nil
    end

    test "a master's session is scoped on any other site, so it signs in nowhere else", %{
      tenant_site: tenant_site
    } do
      master = create_user!()

      result_conn =
        request("/?master_user=true", "tenant.example.com", %{
          "user_token" => token(master),
          master_mode: true
        })

      assert tenant(result_conn) == tenant_site.id
    end
  end

  # AN UNSCOPED REQUEST IS A MASTER'S, or a visitor's on the master site's sign-in pages. A token
  # issued with no site does not make its holder a master — an account can be given a site after it
  # signed in — so once `:load_from_session` has read the user, `confirm_tenant/2` holds the rest.
  describe "confirm_tenant/2, after the session's user is loaded" do
    setup do
      MishkaCmsCore.DataCase.setup_sandbox(%{async: false})
      {:ok, master_site: cached_site!("master.example.com", true)}
    end

    test "a master stays signed in, unscoped", %{} do
      master = create_user!()

      result_conn = through_pipeline("/", %{"user_token" => token(master)})

      assert result_conn.assigns.current_user.id == master.id
      assert tenant(result_conn) == nil
    end

    test "a site's user holding a token issued with no site is signed out, scoped", %{
      master_site: master_site
    } do
      user = issued_with_no_site(master_site.id)

      result_conn = through_pipeline("/", %{"user_token" => token(user)})

      assert result_conn.assigns.current_user == nil
      assert get_session(result_conn, "user_token") == nil
      assert tenant(result_conn) == master_site.id
    end

    # Not a site user is not a master: a user that carries no site_id at all is signed out as well.
    test "a user with no site_id at all is signed out, scoped", %{master_site: master_site} do
      result_conn =
        :get
        |> conn_with_host("/", "master.example.com")
        |> init_test_session(%{"user_token" => "t"})
        |> assign(:current_site, master_site)
        |> assign(:current_user, %{id: "no-site-id"})
        |> SiteLookupPlug.confirm_tenant([])

      assert result_conn.assigns.current_user == nil
      assert get_session(result_conn, "user_token") == nil
      assert tenant(result_conn) == master_site.id
    end

    test "a master's token that no longer verifies leaves the request scoped", %{
      master_site: master_site
    } do
      master = create_user!()
      :ok = AshAuthentication.TokenResource.revoke(MishkaCmsCore.Accounts.Token, token(master))

      result_conn = through_pipeline("/", %{"user_token" => token(master)})

      assert result_conn.assigns.current_user == nil
      assert tenant(result_conn) == master_site.id
    end

    test "a visitor who asked for the master accounts stays unscoped on the sign-in pages", %{
      master_site: master_site
    } do
      assert tenant(through_pipeline("/auth", %{master_mode: true})) == nil
      assert tenant(through_pipeline("/en/auth", %{master_mode: true})) == nil

      assert tenant(through_pipeline("/about", %{master_mode: true})) == master_site.id
      assert tenant(through_pipeline("/en/about", %{master_mode: true})) == master_site.id
    end
  end

  # ONE ANSWER FOR EVERY RULE THAT TREATS THE SIGN-IN PAGES APART: this plug's master unscoping,
  # `MaintenanceGate`, `SiteAvailability` and `RuntimeLive`'s offline assets all ask it.
  describe "sign_in_path?/2" do
    setup do
      MishkaCmsCore.DataCase.setup_sandbox(%{async: false})
      site = cached_site!("languages.example.com", false)
      forget_languages(site)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {:ok, site: site}
    end

    test "the addresses without a language, on any site or none", %{site: site} do
      for segments <- [["auth"], ["auth", "register"], ["api", "auth"], ["api", "auth", "user"]],
          on <- [site, nil] do
        assert SiteLookupPlug.sign_in_path?(segments, on), inspect({segments, on})
      end
    end

    test "an address under one of the site's languages", %{site: site} do
      for segments <- [
            ["en", "auth"],
            ["fa", "auth"],
            ["en", "auth", "register"],
            ["fa", "auth", "password-reset", "token"],
            ["en", "auth", "sign-out"]
          ] do
        assert SiteLookupPlug.sign_in_path?(segments, site), inspect(segments)
      end
    end

    test "nothing else", %{site: site} do
      for segments <- [
            [],
            ["authors"],
            ["en"],
            ["en", "authors"],
            ["de", "auth"],
            ["auth-page"],
            ["en", "about", "auth"],
            ["en", "api", "auth"],
            ["admin", "dashboard"]
          ] do
        refute SiteLookupPlug.sign_in_path?(segments, site), inspect(segments)
      end

      refute SiteLookupPlug.sign_in_path?(["en", "auth"], nil)
    end
  end

  # EVERY PLACE THAT SENDS A VISITOR TO SIGN IN asks this with the language they read pages in.
  describe "auth_address/3" do
    setup do
      MishkaCmsCore.DataCase.setup_sandbox(%{async: false})
      site = cached_site!("auth-address.example.com", false)
      forget_languages(site)
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {:ok, site: site}
    end

    test "is the sign-in page in the language asked, the first one unprefixed", %{site: site} do
      assert SiteLookupPlug.auth_address("fa", site.id) == "/fa/auth"
      assert SiteLookupPlug.auth_address("en", site.id) == "/auth"
      assert SiteLookupPlug.auth_address("fa", site.id, "/sign-out") == "/fa/auth/sign-out"
      assert SiteLookupPlug.auth_address("en", site.id, "/sign-out") == "/auth/sign-out"
    end

    test "names every language when the site prefixes them all", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert SiteLookupPlug.auth_address("en", site.id) == "/en/auth"
      assert SiteLookupPlug.auth_address("fa", site.id) == "/fa/auth"
    end

    test "is the site's first language for none, or one the site does not publish", %{
      site: site
    } do
      assert SiteLookupPlug.auth_address(nil, site.id) == "/auth"
      assert SiteLookupPlug.auth_address("de", site.id) == "/auth"

      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)

      assert SiteLookupPlug.auth_address(nil, site.id) == "/auth"
      assert SiteLookupPlug.auth_address("en", site.id) == "/en/auth"
    end
  end

  describe "HTML response content" do
    test "inactive site HTML includes proper styling", %{} do
      site_attrs = %{
        id: "html-test-inactive",
        name: "HTML Test Inactive",
        host: "htmltest.example.com",
        priority: 100,
        active: false,
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)

      conn =
        conn_with_host(:get, "/", "htmltest.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.resp_body =~ "<style>"
      assert result_conn.resp_body =~ "font-family"
      assert result_conn.resp_body =~ "#e74c3c"
      assert get_resp_header(result_conn, "content-type") == ["text/html; charset=utf-8"]
    end

    test "api_only site HTML includes 403 error code display", %{} do
      site_attrs = %{
        id: "html-test-api",
        name: "HTML Test API",
        host: "apihtmltest.example.com",
        priority: 100,
        active: true,
        mode: :api_only,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)

      conn =
        conn_with_host(:get, "/", "apihtmltest.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.resp_body =~ "error-code"
      assert result_conn.resp_body =~ "403"
      assert result_conn.resp_body =~ "Web Access Not Allowed"
    end

    test "missing site HTML includes 503 error code", %{} do
      conn =
        conn_with_host(:get, "/", "missing.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.resp_body =~ "503"
      assert result_conn.resp_body =~ "Service Unavailable"
      assert result_conn.resp_body =~ "check the domain"
    end
  end

  describe "session persistence" do
    setup do
      site_attrs = %{
        id: "session-test-site",
        name: "Session Test Site",
        host: "session.example.com",
        priority: 100,
        active: true,
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)
      {:ok, %{site: site_attrs}}
    end

    test "stores site in session for active site", %{site: site} do
      conn =
        conn_with_host(:get, "/", "session.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      session_site = get_session(result_conn, :current_site)
      assert session_site.id == site.id
      assert session_site.host == "session.example.com"
    end

    test "preserves existing session data", %{site: site} do
      conn =
        conn_with_host(:get, "/", "session.example.com")
        |> init_test_session(%{existing_key: "existing_value"})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert get_session(result_conn, :existing_key) == "existing_value"
      assert get_session(result_conn, :current_site).id == site.id
    end
  end

  describe "edge cases" do
    test "handles empty host header", %{} do
      conn =
        conn_with_host(:get, "/", "")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      assert result_conn.halted
      assert result_conn.status == 503
    end

    test "handles malformed host with multiple colons", %{} do
      site_attrs = %{
        id: "edge-case-site",
        name: "Edge Case Site",
        host: "edge.example.com",
        priority: 100,
        active: true,
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)

      conn =
        conn_with_host(:get, "/", "edge.example.com:4000:extra")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      # Should extract "edge.example.com" and find the site
      refute result_conn.halted
      assert result_conn.assigns.current_site.id == "edge-case-site"
    end

    test "handles uppercase host headers", %{} do
      site_attrs = %{
        id: "case-test-site",
        name: "Case Test Site",
        host: "case.example.com",
        priority: 100,
        active: true,
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      }

      :ok = SiteState.save(site_attrs)

      conn =
        conn_with_host(:get, "/", "CASE.EXAMPLE.COM")
        |> init_test_session(%{})
        |> fetch_query_params()

      result_conn = SiteLookupPlug.call(conn, %{})

      # Case sensitivity depends on SiteState implementation
      # This will likely return 503 unless SiteState does case-insensitive matching
      assert result_conn.status == 503
    end
  end

  describe "concurrent access" do
    test "handles multiple sites correctly" do
      # Create multiple sites
      sites = [
        %{
          id: "site-1",
          name: "Site 1",
          host: "site1.example.com",
          priority: 100,
          active: true,
          mode: :hybrid,
          frontend_domain: nil,
          allowed_origins: []
        },
        %{
          id: "site-2",
          name: "Site 2",
          host: "site2.example.com",
          priority: 100,
          active: true,
          mode: :phoenix_only,
          frontend_domain: nil,
          allowed_origins: []
        },
        %{
          id: "site-3",
          name: "Site 3",
          host: "site3.example.com",
          priority: 100,
          active: false,
          mode: :hybrid,
          frontend_domain: nil,
          allowed_origins: []
        }
      ]

      Enum.each(sites, &SiteState.save/1)

      # Test each site
      conn1 =
        conn_with_host(:get, "/", "site1.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()
        |> SiteLookupPlug.call(%{})

      refute conn1.halted
      assert conn1.assigns.current_site.id == "site-1"

      conn2 =
        conn_with_host(:get, "/", "site2.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()
        |> SiteLookupPlug.call(%{})

      refute conn2.halted
      assert conn2.assigns.current_site.id == "site-2"

      conn3 =
        conn_with_host(:get, "/", "site3.example.com")
        |> init_test_session(%{})
        |> fetch_query_params()
        |> SiteLookupPlug.call(%{})

      assert conn3.halted
      assert conn3.status == 503
    end
  end
end
