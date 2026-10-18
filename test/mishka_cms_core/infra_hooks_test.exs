# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.InfraHooksTest do
  @moduledoc """
  Confirms the plugin system reaches the INFRASTRUCTURE layer (not just Ash resources): a plugin
  registered for an infra request seam dispatches when the real plug runs.
  """
  use MishkaCmsCore.DataCase, async: false

  import Plug.Conn

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Plugs.{ApiTenantLookupPlug, SiteLookupPlug}

  alias MishkaCmsCore.Test.Plugins.{
    MasterSignInRefused,
    NoTenantRefused,
    SessionRefused,
    SiteUnavailablePage,
    TokenRefused,
    WebAfterSiteResolve
  }

  setup do
    Process.register(self(), :__plugin_hook_probe__)
    :ok
  end

  test "infra: the site-lookup plug dispatches web:request:after_site_resolve to a plugin" do
    {:ok, _} =
      Event.write(%{
        name: WebAfterSiteResolve,
        event: "web:request:after_site_resolve",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("web:request:after_site_resolve", :start, false)

    conn = Plug.Test.conn(:get, "/") |> fetch_query_params()

    MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.call(
      conn,
      MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.init([])
    )

    assert_receive {:web_after_site_resolve}

    Event.unregister(:name, WebAfterSiteResolve, false)
  end

  # A PLUGIN MAY ANSWER A SITE THAT IS DOWN WITH A PAGE OF ITS OWN. It hears the refusal first, told
  # which state the site is in, and a conn it halts is sent as it is.
  test "infra: an inactive site's refusal is heard on web:request:site_unavailable, and a plugin may answer it" do
    {:ok, _} =
      Event.write(%{
        name: SiteUnavailablePage,
        event: "web:request:site_unavailable",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("web:request:site_unavailable", :start, false)
    on_exit(fn -> Event.unregister(:name, SiteUnavailablePage, false) end)

    n = System.unique_integer([:positive])
    host = "switched-off-#{n}.test"
    id = Ecto.UUID.generate()

    :ok =
      SiteState.save(%{id: id, name: "switched-off-#{n}", host: host, priority: 0, active: false})

    on_exit(fn -> SiteState.delete(id) end)

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.update!(:req_headers, &[{"host", host} | &1])
      |> fetch_query_params()
      |> MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.call(
        MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.init([])
      )

    assert conn.halted
    assert conn.resp_body == "A plugin's own page"
    assert_receive {:site_unavailable, :inactive}
  end

  # A MASTER SIGNS IN ON THE MASTER SITE ALONE. Another site asked for the master accounts refuses,
  # and a session that is not a master's on an unscoped request is ended; a plugin hears both.
  describe "master sign-in refusals" do
    setup do
      n = System.unique_integer([:positive])
      site = create_site!(name: "refusing-#{n}", host: "refusing-#{n}.test", active: true)
      master_site = create_site!(name: "master-#{n}", host: "master-#{n}.test", master: true)

      for {cached, master?} <- [{site, false}, {master_site, true}] do
        :ok =
          SiteState.save(%{
            id: cached.id,
            name: cached.name,
            host: cached.host,
            priority: 0,
            active: true,
            master: master?
          })
      end

      on_exit(fn ->
        SiteState.delete(site.id)
        SiteState.delete(master_site.id)
      end)

      {:ok, site: site, master_site: master_site}
    end

    test "?master_user=true on any other site is heard on web:request:master_sign_in_refused", %{
      site: site
    } do
      register!(MasterSignInRefused, "web:request:master_sign_in_refused")
      site_id = site.id

      "/auth?master_user=true"
      |> browser_request(site.host)
      |> SiteLookupPlug.call(SiteLookupPlug.init([]))

      assert_receive {:master_sign_in_refused, ^site_id}

      "/auth?master_user=false"
      |> browser_request(site.host)
      |> SiteLookupPlug.call(SiteLookupPlug.init([]))

      refute_receive {:master_sign_in_refused, _site_id}, 200
    end

    test "a session ended on an unscoped request is heard on web:request:session_refused", %{
      master_site: master_site
    } do
      register!(SessionRefused, "web:request:session_refused")

      master = create_user!()
      assert signed_in(master, master_site.host).assigns.current_user.id == master.id
      refute_receive {:session_refused, _user_id, _site_id}, 200

      {:ok, moved} =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "moved@example.com",
            password: "Password123!",
            password_confirmation: "Password123!"
          },
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:site_id, master_site.id)
        |> Ash.create()

      {user_id, site_id} = {moved.id, master_site.id}

      assert signed_in(moved, master_site.host).assigns.current_user == nil
      assert_receive {:session_refused, ^user_id, ^site_id}
    end

    test "the API's master switch on any other site is heard on api:request:no_tenant_refused", %{
      site: site,
      master_site: master_site
    } do
      register!(NoTenantRefused, "api:request:no_tenant_refused")
      site_id = site.id

      api_request(site.host, [{"x-no-tenant", "true"}])
      assert_receive {:no_tenant_refused, ^site_id}

      api_request(site.host, [])
      api_request(master_site.host, [{"x-no-tenant", "true"}])
      refute_receive {:no_tenant_refused, _site_id}, 200
    end

    test "a site's user on an unscoped API request is heard on api:request:token_refused", %{
      site: site,
      master_site: master_site
    } do
      register!(TokenRefused, "api:request:token_refused")

      master = create_user!()
      assert api_signed_in(master, master_site.host).assigns.current_user.id == master.id
      refute_receive {:token_refused, _user_id, _site_id}, 200

      moved =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "moved.api@example.com",
            password: "Password123!",
            password_confirmation: "Password123!"
          },
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:site_id, site.id)
        |> Ash.create!()

      {user_id, site_id} = {moved.id, master_site.id}

      assert api_signed_in(moved, master_site.host).assigns.current_user == nil
      assert_receive {:token_refused, ^user_id, ^site_id}
    end
  end

  # The plugs of the `:api` pipeline that decide who is asking, with the master accounts' switch on.
  defp api_signed_in(user, host) do
    host
    |> api_request([
      {"x-no-tenant", "true"},
      {"authorization", "Bearer " <> user.__metadata__.token}
    ])
    |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(:mishka_cms_core)
    |> ApiTenantLookupPlug.confirm_bearer_tenant([])
  end

  defp api_request(host, headers) do
    headers
    |> Enum.reduce(Plug.Test.conn(:get, "/api/json/v1/auth/user/me"), fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
    |> Map.put(:host, host)
    |> fetch_query_params()
    |> ApiTenantLookupPlug.call(ApiTenantLookupPlug.init([]))
  end

  # The three plugs of the `:browser` pipeline that decide who is asking.
  defp signed_in(user, host) do
    "/"
    |> browser_request(host, %{"user_token" => user.__metadata__.token})
    |> SiteLookupPlug.call(SiteLookupPlug.init([]))
    |> AshAuthentication.Plug.Helpers.retrieve_from_session(:mishka_cms_core)
    |> SiteLookupPlug.confirm_tenant([])
  end

  defp browser_request(path, host, session \\ %{}) do
    Plug.Test.conn(:get, path)
    |> Map.update!(:req_headers, &[{"host", host} | &1])
    |> Plug.Test.init_test_session(session)
    |> fetch_query_params()
  end

  defp register!(module, event) do
    {:ok, _} =
      Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, module, false) end)
  end
end
