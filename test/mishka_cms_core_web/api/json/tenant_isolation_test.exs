# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.TenantIsolationTest do
  @moduledoc """
  Regression test for API tenant isolation (the "B1 cross-tenant IDOR" the audit flagged). It is
  already enforced by Ash multitenancy + AshAuthentication's tenant-bound bearer token (no custom
  plug): a Site-A user's real token is rejected the moment it is used against another site's `Host`
  (or to drop the tenant), while legitimate same-site access still works. Hits the real `/me`
  endpoint through the full `:api` pipeline — this guards against a future change that weakens it.
  """
  use MishkaCmsCore.ConnCase

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :unit
  @moduletag :capture_log

  @password "Password123!"
  @me "/api/json/v1/auth/user/me?fields[user]=id,email,site_id"

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsCore.TestRouter)

    site_a = create_site!(name: "site-a", host: "a.localhost", active: true)
    site_b = create_site!(name: "site-b", host: "b.localhost", active: true)
    cache_site(site_a)
    cache_site(site_b)

    user_a =
      create_user!(
        email: "a@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site_a.id
      )

    {:ok, site_a: site_a, site_b: site_b, user_a: user_a}
  end

  defp cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  defp sign_in(email, host) do
    response =
      make_api_request(
        "/api/json/v1/auth/user/sign-in",
        %{"type" => "user", "attributes" => %{"email" => email, "password" => @password}},
        headers: [{"x-no-tenant", "false"}],
        host: host
      )

    assert response.status == 201
    Jason.decode!(response.resp_body)["meta"]["token"]
  end

  defp get_me(token, host, no_tenant) do
    make_api_request(@me, nil,
      method: "GET",
      headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", no_tenant}],
      host: host
    )
  end

  test "a Site-A token is denied against Site-B's host, but works on Site-A", ctx do
    token = sign_in("a@example.com", ctx.site_a.host)

    # 🔴 Attack: Site-A token + Site-B host → cross-tenant access is denied.
    assert get_me(token, ctx.site_b.host, "false").status == 403

    # ✅ Legitimate: Site-A token + Site-A host → works.
    assert get_me(token, ctx.site_a.host, "false").status == 200
  end

  # Only the master site's address takes `x-no-tenant`, and there a Site-A token names nobody; Site-A's
  # own address ignores it and the request stays Site-A's.
  test "a Site-A token cannot drop the tenant to global via x-no-tenant", ctx do
    master_site =
      create_site!(name: "master", host: "master.localhost", active: true, master: true)

    cache_site(master_site)
    token = sign_in("a@example.com", ctx.site_a.host)

    assert get_me(token, master_site.host, "true").status == 403

    own = get_me(token, ctx.site_a.host, "true")
    assert own.status == 200
    assert get_resp_header(own, "x-tenant-id") == [ctx.site_a.id]
  end

  # LOCALHOST IS THE MASTER SITE'S ADDRESS in dev and test while no site has that host, as it is in
  # the browser, so every request there is answered as it is on the master site's own address.
  describe "at localhost, while no site has that host" do
    setup do
      master_site =
        create_site!(name: "master", host: "master.localhost", active: true, master: true)

      cache_site(master_site)

      create_user!(
        email: "own@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: master_site.id
      )

      create_user!(
        email: "master@example.com",
        password: @password,
        password_confirmation: @password
      )

      {:ok, master_site: master_site}
    end

    test "a token of the master site works there as on its own address", ctx do
      for sign_in_host <- ["localhost", ctx.master_site.host],
          host <- ["localhost", "127.0.0.1", ctx.master_site.host] do
        me = "own@example.com" |> sign_in(sign_in_host) |> get_me(host, "false")

        assert me.status == 200
        assert get_resp_header(me, "x-tenant-id") == [ctx.master_site.id]
        assert Jason.decode!(me.resp_body)["data"]["attributes"]["site_id"] == ctx.master_site.id
      end
    end

    test "a token of another site is refused there as on the master site's address", ctx do
      token = sign_in("a@example.com", ctx.site_a.host)

      for host <- ["localhost", "127.0.0.1", ctx.master_site.host],
          no_tenant <- ["false", "true"] do
        assert get_me(token, host, no_tenant).status == 403
      end
    end

    test "a master signs in and is recognised there with x-no-tenant, as on the master site's address",
         ctx do
      for host <- ["localhost", "127.0.0.1", ctx.master_site.host] do
        token = master_sign_in(host)

        me = get_me(token, host, "true")
        assert me.status == 200
        assert get_resp_header(me, "x-tenant-id") == ["none"]
        assert Jason.decode!(me.resp_body)["data"]["attributes"]["site_id"] == nil

        scoped = get_me(token, host, "false")
        assert scoped.status == 403
        assert get_resp_header(scoped, "x-tenant-id") == [ctx.master_site.id]
      end
    end

    test "any other host still has no site" do
      for host <- ["unknown.example", "localhost.example", "c.localhost", "::1"] do
        response = make_api_request(@me, nil, method: "GET", host: host)

        assert response.status == 404
        assert Jason.decode!(response.resp_body)["error"]["code"] == "domain_not_found"
      end
    end
  end

  defp master_sign_in(host) do
    response =
      make_api_request(
        "/api/json/v1/auth/user/sign-in",
        %{
          "type" => "user",
          "attributes" => %{"email" => "master@example.com", "password" => @password}
        },
        headers: [{"x-no-tenant", "true"}],
        host: host
      )

    assert response.status == 201
    Jason.decode!(response.resp_body)["meta"]["token"]
  end
end
