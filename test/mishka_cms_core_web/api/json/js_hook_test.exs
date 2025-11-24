defmodule MishkaCmsCoreWeb.Api.Json.JsHookTest do
  @moduledoc """
  Comprehensive JSON API tests for JsHook resource.

  JsHook supports global hooks (global? true) - tenant can READ global hooks but cannot MODIFY them.
  Tests cover master and tenant CRUD operations, version management, global vs site-specific access.
  """
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :unit
  @moduletag :capture_log

  require Ash.Query

  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/js-hook"
  @master_path "/api/json/v1/master/admin/runtime/js-hook"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    Application.put_env(:ash_json_api, MishkaCmsCore.Runtime, router: MishkaCmsCore.TestRouter)

    # Create sites
    site =
      create_site!(name: "localhost", host: "localhost", active: true, priority: 50, master: true)

    site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 40)

    # Save to state
    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site2.id,
      name: site2.name,
      host: site2.host,
      priority: site2.priority,
      active: site2.active
    })

    # Create admin permission
    admin_permission = create_permission!(name: "admin:api:*")

    # Create master user (no site_id, uses x-no-tenant header)
    master_user =
      MishkaCmsCore.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "master@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })
      |> Ash.create!(authorize?: false, tenant: nil)
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [admin_permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    # Create tenant admin (has site_id)
    tenant_admin =
      create_user!(
        email: "admin@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site.id
      )
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [admin_permission.id]},
        authorize?: false,
        tenant: site.id
      )
      |> Ash.update!()

    # Create site2 admin for cross-tenant tests
    site2_admin =
      create_user!(
        email: "site2.admin@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site2.id
      )
      |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [admin_permission.id]},
        authorize?: false,
        tenant: site2.id
      )
      |> Ash.update!()

    on_exit(fn ->
      MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
      MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      MishkaCmsCore.Runtime.States.SiteState.clear()
    end)

    %{
      site: site,
      site2: site2,
      admin_permission: admin_permission,
      master_user: master_user,
      tenant_admin: tenant_admin,
      site2_admin: site2_admin
    }
  end

  defp create_js_hook_via_ash(attrs, site_id) do
    MishkaCmsCore.Runtime.JsHook
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id)
    |> Ash.create!(authorize?: false)
  end

  defp create_global_js_hook_via_ash(attrs) do
    MishkaCmsCore.Runtime.JsHook
    |> Ash.Changeset.for_create(:master_create, Map.put(attrs, :site_id, nil),
      tenant: nil,
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  describe "MASTER ADMIN - CREATE" do
    test "master can create js_hook for site1", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Site1 Hook",
              "content" => "console.log('site1');",
              "format" => "js",
              "priority" => 50,
              "site_id" => site.id
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "site1-hook"
      assert body["data"]["attributes"]["content"] == "console.log('site1');"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "master can create global js_hook (nil site_id)", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Global Hook",
              "content" => "console.log('global');",
              "format" => "js",
              "priority" => 100
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "global-hook"
      assert body["data"]["attributes"]["site_id"] == nil
    end

    test "master can create js_hook for site2", %{master_user: master_user, site2: site2} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Site2 Hook",
              "content" => "console.log('site2');",
              "format" => "ts",
              "site_id" => site2.id
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["site_id"] == site2.id
      assert body["data"]["attributes"]["format"] == "ts"
    end

    test "master create validates required fields", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Missing Content",
              "site_id" => site.id
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [400, 422]
    end
  end

  describe "MASTER ADMIN - READ" do
    test "master can list js_hooks from all sites including global", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      hook1 = create_js_hook_via_ash(%{name: "Hook Site1", content: "//1"}, site.id)
      hook2 = create_js_hook_via_ash(%{name: "Hook Site2", content: "//2"}, site2.id)
      global_hook = create_global_js_hook_via_ash(%{name: "Global Hook Read", content: "//g"})

      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert hook1.id in ids
      assert hook2.id in ids
      assert global_hook.id in ids
    end

    test "master can get js_hook by id from any site", %{master_user: master_user, site2: site2} do
      hook = create_js_hook_via_ash(%{name: "Hook Get Test", content: "//test"}, site2.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == hook.id
      assert body["data"]["attributes"]["name"] == "hook-get-test"
    end

    test "master get returns 404 for non-existent js_hook", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 404
    end
  end

  describe "MASTER ADMIN - UPDATE" do
    test "master can update js_hook from any site", %{master_user: master_user, site2: site2} do
      hook =
        create_js_hook_via_ash(
          %{name: "Hook Update Test", content: "//old", priority: 10},
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}",
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Updated Hook Name",
              "priority" => 80
            }
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "updated-hook-name"
      assert body["data"]["attributes"]["priority"] == 80
    end

    test "master can update global js_hook", %{master_user: master_user} do
      global_hook =
        create_global_js_hook_via_ash(%{name: "Global Update", content: "//g", priority: 50})

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{global_hook.id}",
          %{
            "type" => "js_hook",
            "attributes" => %{
              "content" => "// updated global content",
              "priority" => 99
            }
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["content"] == "// updated global content"
      assert body["data"]["attributes"]["priority"] == 99
    end

    test "master update returns 404 for non-existent js_hook", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{"type" => "js_hook", "attributes" => %{"name" => "Not Found"}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 404
    end
  end

  describe "MASTER ADMIN - DELETE (Archive)" do
    test "master can archive js_hook from any site", %{master_user: master_user, site2: site2} do
      hook =
        create_js_hook_via_ash(%{name: "Hook Archive Test", content: "//arch"}, site2.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200

      # Verify it's now in archived list
      archived_response =
        make_api_request(
          "#{@master_path}/archived",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert archived_response.status == 200
      body = Jason.decode!(archived_response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert hook.id in ids
    end

    test "master can archive global js_hook", %{master_user: master_user} do
      global_hook = create_global_js_hook_via_ash(%{name: "Global Archive", content: "//ga"})

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{global_hook.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
    end
  end

  describe "MASTER ADMIN - ARCHIVED" do
    test "master can list archived js_hooks from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      hook1 = create_js_hook_via_ash(%{name: "Hook Archived 1", content: "//a1"}, site.id)
      hook2 = create_js_hook_via_ash(%{name: "Hook Archived 2", content: "//a2"}, site2.id)

      # Archive both
      Ash.destroy!(hook1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(hook2, action: :destroy, tenant: site2.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert hook1.id in ids
      assert hook2.id in ids
    end

    test "master can get archived js_hook by id", %{master_user: master_user, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Archived Get", content: "//ag"}, site.id)

      Ash.destroy!(hook, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == hook.id
    end

    test "master can unarchive js_hook", %{master_user: master_user, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Unarchive", content: "//un"}, site.id)

      Ash.destroy!(hook, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/unarchive",
          %{"type" => "js_hook", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200

      # Verify it's back in active list
      get_response =
        make_api_request(
          "#{@master_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 200
    end
  end

  describe "MASTER ADMIN - PERMANENT DELETE" do
    test "master can permanently delete js_hook", %{master_user: master_user, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Permanent Delete", content: "//pd"}, site.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@master_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 404
    end

    test "master can permanently delete global js_hook", %{master_user: master_user} do
      global_hook = create_global_js_hook_via_ash(%{name: "Global Perm Delete", content: "//gpd"})

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{global_hook.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "TENANT ADMIN - CREATE" do
    test "tenant can create js_hook for their site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Tenant Hook",
              "content" => "console.log('tenant');",
              "format" => "js",
              "priority" => 50
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "tenant-hook"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "tenant create validates required fields", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Missing Content Hook"
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [400, 422]
    end

    test "tenant cannot create js_hook with another site_id", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Trying Other Site",
              "content" => "//hack",
              "site_id" => site2.id
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [400, 403, 422]
    end

    test "tenant token from site1 cannot create on site2 host", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Cross Site Create",
              "content" => "//cross"
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ],
          host: site2.host
        )

      assert response.status in [401, 403]
    end

    test "tenant cannot create global js_hook (nil site_id)", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Trying Global Hook",
              "content" => "//global-attempt",
              "site_id" => nil
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      # Tenant cannot create global hooks (site_id = nil)
      assert response.status in [400, 403, 422]
    end
  end

  describe "TENANT ADMIN - READ" do
    test "tenant can list js_hooks from their site plus global hooks", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      hook1 = create_js_hook_via_ash(%{name: "Hook Tenant Read 1", content: "//t1"}, site.id)
      hook2 = create_js_hook_via_ash(%{name: "Hook Site2 Read", content: "//s2"}, site2.id)
      global_hook = create_global_js_hook_via_ash(%{name: "Global Tenant Read", content: "//g"})

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      # Tenant sees their site's hooks and global hooks
      assert hook1.id in ids
      assert global_hook.id in ids
      # But not other site's hooks
      refute hook2.id in ids
    end

    test "tenant can get js_hook by id from their site", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Tenant Get", content: "//tg"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == hook.id
    end

    test "tenant can get global js_hook", %{tenant_admin: tenant_admin} do
      global_hook = create_global_js_hook_via_ash(%{name: "Global Get Test", content: "//ggt"})

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == global_hook.id
      assert body["data"]["attributes"]["site_id"] == nil
    end

    test "tenant cannot get js_hook from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      hook = create_js_hook_via_ash(%{name: "Hook Other Site", content: "//os"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - UPDATE" do
    test "tenant can update js_hook from their site", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Tenant Update", content: "//tu"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{
            "type" => "js_hook",
            "attributes" => %{
              "name" => "Updated Tenant Hook",
              "active" => false
            }
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "updated-tenant-hook"
      assert body["data"]["attributes"]["active"] == false
    end

    test "tenant cannot update global js_hook", %{tenant_admin: tenant_admin} do
      global_hook = create_global_js_hook_via_ash(%{name: "Global No Update", content: "//gnu"})

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}",
          %{"type" => "js_hook", "attributes" => %{"name" => "Hacked Global"}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [403, 404]
    end

    test "tenant cannot update js_hook from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      hook = create_js_hook_via_ash(%{name: "Hook Other Update", content: "//ou"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{"type" => "js_hook", "attributes" => %{"name" => "Should Fail"}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - DELETE (Archive)" do
    test "tenant can archive js_hook from their site", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Tenant Archive", content: "//ta"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot archive global js_hook", %{tenant_admin: tenant_admin} do
      global_hook = create_global_js_hook_via_ash(%{name: "Global No Archive", content: "//gna"})

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status in [403, 404]
    end

    test "tenant cannot archive js_hook from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      hook = create_js_hook_via_ash(%{name: "Hook Other Archive", content: "//oa"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - ARCHIVED" do
    test "tenant can list archived js_hooks from their site only", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      hook1 =
        create_js_hook_via_ash(%{name: "Hook Tenant Arch List 1", content: "//tal1"}, site.id)

      hook2 = create_js_hook_via_ash(%{name: "Hook Other Arch List", content: "//oal"}, site2.id)

      Ash.destroy!(hook1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(hook2, action: :destroy, tenant: site2.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert hook1.id in ids
      refute hook2.id in ids
    end

    test "tenant can get archived js_hook by id from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      hook = create_js_hook_via_ash(%{name: "Hook Tenant Arch Get", content: "//tag"}, site.id)

      Ash.destroy!(hook, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == hook.id
    end

    test "tenant can unarchive js_hook from their site", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Tenant Unarch", content: "//tunarch"}, site.id)

      Ash.destroy!(hook, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/unarchive",
          %{"type" => "js_hook", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
    end
  end

  describe "TENANT ADMIN - PERMANENT DELETE" do
    test "tenant can permanently delete js_hook from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      hook = create_js_hook_via_ash(%{name: "Hook Tenant Perm Delete", content: "//tpd"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404
    end

    test "tenant cannot permanently delete global js_hook", %{tenant_admin: tenant_admin} do
      global_hook =
        create_global_js_hook_via_ash(%{name: "Global No Perm Delete", content: "//gnpd"})

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status in [403, 404]
    end

    test "tenant cannot permanently delete js_hook from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      hook = create_js_hook_via_ash(%{name: "Hook Other Perm Delete", content: "//opd"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - Get With Versions" do
    test "tenant can get js_hook with versions", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook With Versions", content: "//v1"}, site.id)

      # Update to create version
      hook
      |> Ash.Changeset.for_update(:update, %{content: "//v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/with-versions?fields[js_hook]=name,content,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == hook.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end

    test "tenant cannot get global js_hook with versions via tenant endpoint", %{
      tenant_admin: tenant_admin
    } do
      # Note: get_with_versions action doesn't have multitenancy :bypass,
      # so tenants can only read global hooks via get_for_tenant_with_globals
      global_hook =
        create_global_js_hook_via_ash(%{name: "Global With Versions", content: "//gv1"})

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}/with-versions?fields[js_hook]=name,content,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      # Tenant endpoint's get_with_versions doesn't bypass multitenancy
      assert response.status == 404
    end

    test "master can get js_hook with versions from any site", %{
      master_user: master_user,
      site2: site2
    } do
      hook =
        create_js_hook_via_ash(%{name: "Hook Master With Versions", content: "//mwv"}, site2.id)

      hook
      |> Ash.Changeset.for_update(:update, %{priority: 60}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/with-versions?fields[js_hook]=name,priority,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == hook.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end
  end

  describe "VERSION MANAGEMENT - List Versions" do
    test "tenant can list versions for js_hook", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook List Versions", content: "//lv1"}, site.id)

      # Create 2 more versions
      hook
      |> Ash.Changeset.for_update(:update, %{content: "//lv2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//lv3"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])
    end

    test "master can list versions for js_hook from any site", %{
      master_user: master_user,
      site2: site2
    } do
      hook =
        create_js_hook_via_ash(%{name: "Hook Master List Versions", content: "//mlv"}, site2.id)

      wait_for_version_count("js_hook_versions", hook.id, 1)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Restore Version" do
    test "tenant can restore js_hook to previous version", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      hook =
        create_js_hook_via_ash(
          %{name: "Hook Restore", content: "//original", priority: 10},
          site.id
        )

      # Update to create a new version
      hook
      |> Ash.Changeset.for_update(:update, %{content: "//updated", priority: 90}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      # Get the first (original) version
      version =
        MishkaCmsCore.Runtime.JsHook.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: hook.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/version/#{version.id}/restore",
          %{"type" => "js_hook", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["priority"] == 10
    end

    test "tenant cannot restore version of global js_hook", %{tenant_admin: tenant_admin} do
      global_hook =
        create_global_js_hook_via_ash(%{name: "Global Restore", content: "//gr1", priority: 20})

      # Master update to create version (global hooks require master context)
      global_hook
      |> Ash.Changeset.for_update(:master_update, %{content: "//gr2", priority: 80},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", global_hook.id, 2)

      version =
        MishkaCmsCore.Runtime.JsHook.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: global_hook.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}/version/#{version.id}/restore",
          %{"type" => "js_hook", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [400, 403, 422]
    end

    test "master can restore js_hook version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      hook =
        create_js_hook_via_ash(
          %{name: "Hook Master Restore", content: "//mr1", priority: 20},
          site2.id
        )

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//mr2", priority: 80}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      version =
        MishkaCmsCore.Runtime.JsHook.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: hook.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/version/#{version.id}/restore",
          %{"type" => "js_hook", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["priority"] == 20
    end
  end

  describe "VERSION MANAGEMENT - Preview Version" do
    test "tenant can preview js_hook version without restoring", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      hook =
        create_js_hook_via_ash(
          %{name: "Hook Preview", content: "//preview1", priority: 15},
          site.id
        )

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//preview2", priority: 95},
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      version =
        MishkaCmsCore.Runtime.JsHook.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: hook.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      # Preview shows the old version data
      assert body["data"]["attributes"]["priority"] == 15

      # Verify original is unchanged
      get_response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      get_body = Jason.decode!(get_response.resp_body)
      assert get_body["data"]["attributes"]["priority"] == 95
    end

    test "master can preview js_hook version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      hook =
        create_js_hook_via_ash(
          %{name: "Hook Master Preview", content: "//mp1", priority: 25},
          site2.id
        )

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//mp2", priority: 85}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      version =
        MishkaCmsCore.Runtime.JsHook.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: hook.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{hook.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["priority"] == 25
    end
  end

  describe "VERSION MANAGEMENT - Calculations" do
    test "can load version_count calculation", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Version Count", content: "//vc1"}, site.id)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//vc2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//vc3"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}?fields[js_hook]=name,version_count",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["version_count"] == 3
    end

    test "can load latest_version calculation", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Latest Version", content: "//latest"}, site.id)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//latest2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}?fields[js_hook]=name,latest_version",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["latest_version"] != nil
    end

    test "can load recent_versions calculation", %{tenant_admin: tenant_admin, site: site} do
      hook = create_js_hook_via_ash(%{name: "Hook Recent Versions", content: "//recent"}, site.id)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//recent2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "//recent3"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("js_hook_versions", hook.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}?fields[js_hook]=name,recent_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"]["attributes"]["recent_versions"])
    end
  end

  describe "AUTHENTICATION" do
    test "endpoints require valid token", %{site: site} do
      _hook = create_js_hook_via_ash(%{name: "Hook Auth Test", content: "//auth"}, site.id)

      # Without token
      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: []
        )

      assert response.status in [401, 403]
    end

    test "invalid token is rejected", %{site: site} do
      _hook = create_js_hook_via_ash(%{name: "Hook Invalid Token", content: "//invalid"}, site.id)

      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer invalid_token"}]
        )

      assert response.status in [401, 403]
    end
  end

  describe "CROSS-TENANT ISOLATION" do
    test "tenant from site1 cannot access site2 js_hooks (except global)", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      hook =
        create_js_hook_via_ash(%{name: "Hook Site2 Isolation", content: "//isolated"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      # Try to get
      get_response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404

      # Try to update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}",
          %{"type" => "js_hook", "attributes" => %{"name" => "Hacked"}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert update_response.status == 404

      # Try to delete
      delete_response =
        make_api_request(
          "#{@tenant_path}/#{hook.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert delete_response.status == 404
    end

    test "master can access js_hooks from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      hook_site1 = create_js_hook_via_ash(%{name: "Hook Site1 Master", content: "//s1m"}, site.id)

      hook_site2 =
        create_js_hook_via_ash(%{name: "Hook Site2 Master", content: "//s2m"}, site2.id)

      global_hook =
        create_global_js_hook_via_ash(%{name: "Global Master Access", content: "//gma"})

      token = sign_in_master(master_user)

      # Master can list js_hooks from all sites
      list_response =
        make_api_request(
          @master_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert list_response.status == 200
      body = Jason.decode!(list_response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      # Master sees all sites' js_hooks plus global
      assert hook_site1.id in ids
      assert hook_site2.id in ids
      assert global_hook.id in ids
    end
  end

  describe "GLOBAL JS_HOOK ACCESS CONTROL" do
    test "tenant can read global js_hook but cannot modify", %{tenant_admin: tenant_admin} do
      global_hook = create_global_js_hook_via_ash(%{name: "Global Read Only", content: "//gro"})

      token = sign_in_tenant(tenant_admin)

      # Can read
      get_response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 200

      # Cannot update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}",
          %{"type" => "js_hook", "attributes" => %{"name" => "Modified"}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert update_response.status in [403, 404]

      # Cannot archive
      archive_response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert archive_response.status in [403, 404]

      # Cannot permanently delete
      perm_delete_response =
        make_api_request(
          "#{@tenant_path}/#{global_hook.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert perm_delete_response.status in [403, 404]
    end
  end

  # THE API HAS ITS OWN NAMES. `admin:api:runtime:js_hook` or `admin:api:code` writes a hook, its
  # content included; the dashboard's names do not reach the API.
  describe "the js_hook section over the API" do
    alias MishkaCmsCoreWeb.Test.AreaApi

    defp hook_attrs,
      do: %{"name" => AreaApi.unique("hook"), "content" => "console.log(1)", "format" => "js"}

    test "content is written by the section alone", %{site: site} do
      area = area_token!(site, ["admin:api:runtime:js_hook"])

      assert AreaApi.post(@tenant_path, "js_hook", area, hook_attrs()).status == 201
    end

    test "content is written by code alone", %{site: site} do
      code = area_token!(site, ["admin:api:code"])

      assert AreaApi.post(@tenant_path, "js_hook", code, hook_attrs()).status == 201
    end

    test "the dashboard's names and another section do not write", %{site: site} do
      hook = create_js_hook!(site_id: site.id)
      dashboard = area_token!(site, ["admin:dashboard:runtime:js_hook", "admin:dashboard:code"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])

      refute AreaApi.post(@tenant_path, "js_hook", dashboard, hook_attrs()).status == 201
      refute AreaApi.post(@tenant_path, "js_hook", unrelated, hook_attrs()).status == 201

      assert AreaApi.patch(@tenant_path, "js_hook", hook.id, dashboard, %{"description" => "d"}).status ==
               403

      assert AreaApi.list(@tenant_path, unrelated).status == 200
      assert AreaApi.list(@tenant_path, dashboard).status == 403
    end

    test "the section edits a hook's details; another section does not", %{site: site} do
      hook = create_js_hook!(site_id: site.id)
      area = area_token!(site, ["admin:api:runtime:js_hook"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])

      assert AreaApi.patch(@tenant_path, "js_hook", hook.id, unrelated, %{"description" => "d"}).status ==
               403

      assert AreaApi.patch(@tenant_path, "js_hook", hook.id, area, %{"description" => "d"}).status ==
               200
    end
  end
end
