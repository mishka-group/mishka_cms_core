# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.LayoutTest do
  @moduledoc """
  Comprehensive JSON API tests for Layout resource.

  Layout supports global layouts (global? true) - tenant can READ global layouts but cannot MODIFY them.
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
  @tenant_path "/api/json/v1/tenant/admin/runtime/layout"
  @master_path "/api/json/v1/master/admin/runtime/layout"

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

  defp create_layout_via_ash(attrs, site_id) do
    MishkaCmsCore.Runtime.Layout
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id)
    |> Ash.create!(authorize?: false)
  end

  defp create_global_layout_via_ash(attrs) do
    MishkaCmsCore.Runtime.Layout
    |> Ash.Changeset.for_create(:master_create, Map.put(attrs, :site_id, nil),
      tenant: nil,
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp sample_template do
    """
    <!DOCTYPE html>
    <html>
      <head><title><%= @title %></title></head>
      <body><%= @inner_content %></body>
    </html>
    """
  end

  describe "MASTER ADMIN - CREATE" do
    test "master can create layout for site1", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Site1 Layout",
              "path" => "/site1/*",
              "template" => sample_template(),
              "format" => "heex",
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
      assert body["data"]["attributes"]["name"] == "site1-layout"
      assert body["data"]["attributes"]["path"] == "/site1/*"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "master can create global layout (nil site_id)", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Global Layout",
              "path" => "/global/*",
              "template" => sample_template(),
              "format" => "heex",
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
      assert body["data"]["attributes"]["name"] == "global-layout"
      assert body["data"]["attributes"]["site_id"] == nil
    end

    test "master can create layout for site2", %{master_user: master_user, site2: site2} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Site2 Layout",
              "path" => "/site2/*",
              "template" => sample_template(),
              "format" => "eex",
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
      assert body["data"]["attributes"]["format"] == "eex"
    end

    test "master create validates required fields", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Missing Template",
              "path" => "/test",
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

    test "master create validates path must start with /", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Invalid Path",
              "path" => "no-slash",
              "template" => sample_template(),
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
    test "master can list layouts from all sites including global", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      layout1 =
        create_layout_via_ash(
          %{name: "Layout Site1", path: "/read1", template: "<div>1</div>"},
          site.id
        )

      layout2 =
        create_layout_via_ash(
          %{name: "Layout Site2", path: "/read2", template: "<div>2</div>"},
          site2.id
        )

      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Layout Read",
          path: "/global-read",
          template: "<div>g</div>"
        })

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
      assert layout1.id in ids
      assert layout2.id in ids
      assert global_layout.id in ids
    end

    test "master can get layout by id from any site", %{master_user: master_user, site2: site2} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Get Test", path: "/get-test", template: "<div>test</div>"},
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == layout.id
      assert body["data"]["attributes"]["name"] == "layout-get-test"
    end

    test "master get returns 404 for non-existent layout", %{master_user: master_user} do
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
    test "master can update layout from any site", %{master_user: master_user, site2: site2} do
      layout =
        create_layout_via_ash(
          %{
            name: "Layout Update Test",
            path: "/update-test",
            template: "<div>old</div>",
            priority: 10
          },
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}",
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Updated Layout Name",
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
      assert body["data"]["attributes"]["name"] == "updated-layout-name"
      assert body["data"]["attributes"]["priority"] == 80
    end

    test "master can update global layout", %{master_user: master_user} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Update",
          path: "/global-update",
          template: "<div>g</div>",
          priority: 50
        })

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{global_layout.id}",
          %{
            "type" => "layout",
            "attributes" => %{
              "template" => "<div>updated global content</div>",
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
      assert body["data"]["attributes"]["template"] == "<div>updated global content</div>"
      assert body["data"]["attributes"]["priority"] == 99
    end

    test "master update returns 404 for non-existent layout", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{"type" => "layout", "attributes" => %{"name" => "Not Found"}},
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
    test "master can archive layout from any site", %{master_user: master_user, site2: site2} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Archive Test", path: "/arch-test", template: "<div>arch</div>"},
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/archive",
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
      assert layout.id in ids
    end

    test "master can archive global layout", %{master_user: master_user} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Archive",
          path: "/global-arch",
          template: "<div>ga</div>"
        })

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{global_layout.id}/archive",
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
    test "master can list archived layouts from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      layout1 =
        create_layout_via_ash(
          %{name: "Layout Archived 1", path: "/archived1", template: "<div>a1</div>"},
          site.id
        )

      layout2 =
        create_layout_via_ash(
          %{name: "Layout Archived 2", path: "/archived2", template: "<div>a2</div>"},
          site2.id
        )

      # Archive both
      Ash.destroy!(layout1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(layout2, action: :destroy, tenant: site2.id, authorize?: false)

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
      assert layout1.id in ids
      assert layout2.id in ids
    end

    test "master can get archived layout by id", %{master_user: master_user, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Archived Get", path: "/archived-get", template: "<div>ag</div>"},
          site.id
        )

      Ash.destroy!(layout, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == layout.id
    end

    test "master can unarchive layout", %{master_user: master_user, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Unarchive", path: "/unarchive", template: "<div>un</div>"},
          site.id
        )

      Ash.destroy!(layout, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/unarchive",
          %{"type" => "layout", "attributes" => %{}},
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
          "#{@master_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 200
    end
  end

  describe "MASTER ADMIN - PERMANENT DELETE" do
    test "master can permanently delete layout", %{master_user: master_user, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Permanent Delete", path: "/perm-del", template: "<div>pd</div>"},
          site.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@master_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 404
    end

    test "master can permanently delete global layout", %{master_user: master_user} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Perm Delete",
          path: "/global-perm",
          template: "<div>gpd</div>"
        })

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{global_layout.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "TENANT ADMIN - CREATE" do
    test "tenant can create layout for their site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Tenant Layout",
              "path" => "/tenant/*",
              "template" => sample_template(),
              "format" => "heex",
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
      assert body["data"]["attributes"]["name"] == "tenant-layout"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "tenant create validates required fields", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Missing Template Layout",
              "path" => "/test"
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

    test "tenant cannot create layout with another site_id", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Trying Other Site",
              "path" => "/other-site",
              "template" => sample_template(),
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
            "type" => "layout",
            "attributes" => %{
              "name" => "Cross Site Create",
              "path" => "/cross-site",
              "template" => sample_template()
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

    test "tenant cannot create global layout (nil site_id)", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Trying Global Layout",
              "path" => "/global-attempt",
              "template" => sample_template(),
              "site_id" => nil
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      # Tenant cannot create global layouts (site_id = nil)
      assert response.status in [400, 403, 422]
    end
  end

  describe "TENANT ADMIN - READ" do
    test "tenant can list layouts from their site plus global layouts", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      layout1 =
        create_layout_via_ash(
          %{name: "Layout Tenant Read 1", path: "/tenant-read1", template: "<div>t1</div>"},
          site.id
        )

      layout2 =
        create_layout_via_ash(
          %{name: "Layout Site2 Read", path: "/site2-read", template: "<div>s2</div>"},
          site2.id
        )

      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Tenant Read",
          path: "/global-tenant",
          template: "<div>g</div>"
        })

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
      # Tenant sees their site's layouts and global layouts
      assert layout1.id in ids
      assert global_layout.id in ids
      # But not other site's layouts
      refute layout2.id in ids
    end

    test "tenant can get layout by id from their site", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Tenant Get", path: "/tenant-get", template: "<div>tg</div>"},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == layout.id
    end

    test "tenant can get global layout", %{tenant_admin: tenant_admin} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Get Test",
          path: "/global-get-test",
          template: "<div>ggt</div>"
        })

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == global_layout.id
      assert body["data"]["attributes"]["site_id"] == nil
    end

    test "tenant cannot get layout from another site", %{tenant_admin: tenant_admin, site2: site2} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Other Site", path: "/other-site", template: "<div>os</div>"},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - UPDATE" do
    test "tenant can update layout from their site", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Tenant Update", path: "/tenant-update", template: "<div>tu</div>"},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{
            "type" => "layout",
            "attributes" => %{
              "name" => "Updated Tenant Layout",
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
      assert body["data"]["attributes"]["name"] == "updated-tenant-layout"
      assert body["data"]["attributes"]["active"] == false
    end

    test "tenant cannot update global layout", %{tenant_admin: tenant_admin} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global No Update",
          path: "/global-no-update",
          template: "<div>gnu</div>"
        })

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}",
          %{"type" => "layout", "attributes" => %{"name" => "Hacked Global"}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [403, 404]
    end

    test "tenant cannot update layout from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Other Update", path: "/other-update", template: "<div>ou</div>"},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{"type" => "layout", "attributes" => %{"name" => "Should Fail"}},
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
    test "tenant can archive layout from their site", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Tenant Archive", path: "/tenant-archive", template: "<div>ta</div>"},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot archive global layout", %{tenant_admin: tenant_admin} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global No Archive",
          path: "/global-no-archive",
          template: "<div>gna</div>"
        })

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status in [403, 404]
    end

    test "tenant cannot archive layout from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Other Archive", path: "/other-archive", template: "<div>oa</div>"},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - ARCHIVED" do
    test "tenant can list archived layouts from their site only", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      layout1 =
        create_layout_via_ash(
          %{name: "Layout Tenant Arch List 1", path: "/tal1", template: "<div>tal1</div>"},
          site.id
        )

      layout2 =
        create_layout_via_ash(
          %{name: "Layout Other Arch List", path: "/oal", template: "<div>oal</div>"},
          site2.id
        )

      Ash.destroy!(layout1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(layout2, action: :destroy, tenant: site2.id, authorize?: false)

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
      assert layout1.id in ids
      refute layout2.id in ids
    end

    test "tenant can get archived layout by id from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Tenant Arch Get", path: "/tag", template: "<div>tag</div>"},
          site.id
        )

      Ash.destroy!(layout, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == layout.id
    end

    test "tenant can unarchive layout from their site", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Tenant Unarch", path: "/tunarch", template: "<div>tunarch</div>"},
          site.id
        )

      Ash.destroy!(layout, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/unarchive",
          %{"type" => "layout", "attributes" => %{}},
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
    test "tenant can permanently delete layout from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Tenant Perm Delete", path: "/tpd", template: "<div>tpd</div>"},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404
    end

    test "tenant cannot permanently delete global layout", %{tenant_admin: tenant_admin} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global No Perm Delete",
          path: "/gnpd",
          template: "<div>gnpd</div>"
        })

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status in [403, 404]
    end

    test "tenant cannot permanently delete layout from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Other Perm Delete", path: "/opd", template: "<div>opd</div>"},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - Get With Versions" do
    test "tenant can get layout with versions", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout With Versions", path: "/with-versions", template: "<div>v1</div>"},
          site.id
        )

      # Update to create version
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>v2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/with-versions?fields[layout]=name,template,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == layout.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end

    test "tenant cannot get global layout with versions via tenant endpoint", %{
      tenant_admin: tenant_admin
    } do
      # Note: get_with_versions action doesn't have multitenancy :bypass,
      # so tenants can only read global layouts via get_for_tenant_with_globals
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global With Versions",
          path: "/global-versions",
          template: "<div>gv1</div>"
        })

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}/with-versions?fields[layout]=name,template,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      # Tenant endpoint's get_with_versions doesn't bypass multitenancy
      assert response.status == 404
    end

    test "master can get layout with versions from any site", %{
      master_user: master_user,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Master With Versions", path: "/mwv", template: "<div>mwv</div>"},
          site2.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{priority: 60}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/with-versions?fields[layout]=name,priority,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == layout.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end
  end

  describe "VERSION MANAGEMENT - List Versions" do
    test "tenant can list versions for layout", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout List Versions", path: "/lv1", template: "<div>lv1</div>"},
          site.id
        )

      # Create 2 more versions
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>lv2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>lv3</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])
    end

    test "master can list versions for layout from any site", %{
      master_user: master_user,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Master List Versions", path: "/mlv", template: "<div>mlv</div>"},
          site2.id
        )

      wait_for_version_count("layout_versions", layout.id, 1)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Restore Version" do
    test "tenant can restore layout to previous version", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      layout =
        create_layout_via_ash(
          %{
            name: "Layout Restore",
            path: "/restore",
            template: "<div>original</div>",
            priority: 10
          },
          site.id
        )

      # Update to create a new version
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>updated</div>", priority: 90},
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      # Get the first (original) version
      version =
        MishkaCmsCore.Runtime.Layout.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: layout.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/version/#{version.id}/restore",
          %{"type" => "layout", "attributes" => %{}},
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

    test "tenant cannot restore version of global layout", %{tenant_admin: tenant_admin} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Restore",
          path: "/gr1",
          template: "<div>gr1</div>",
          priority: 20
        })

      # Master update to create version (global layouts require master context)
      global_layout
      |> Ash.Changeset.for_update(:master_update, %{template: "<div>gr2</div>", priority: 80},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", global_layout.id, 2)

      version =
        MishkaCmsCore.Runtime.Layout.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: global_layout.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}/version/#{version.id}/restore",
          %{"type" => "layout", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [400, 403, 422]
    end

    test "master can restore layout version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{
            name: "Layout Master Restore",
            path: "/mr1",
            template: "<div>mr1</div>",
            priority: 20
          },
          site2.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>mr2</div>", priority: 80},
        tenant: site2.id
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      version =
        MishkaCmsCore.Runtime.Layout.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: layout.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/version/#{version.id}/restore",
          %{"type" => "layout", "attributes" => %{}},
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
    test "tenant can preview layout version without restoring", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      layout =
        create_layout_via_ash(
          %{
            name: "Layout Preview",
            path: "/preview1",
            template: "<div>preview1</div>",
            priority: 15
          },
          site.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>preview2</div>", priority: 95},
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      version =
        MishkaCmsCore.Runtime.Layout.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: layout.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}/version/#{version.id}/preview",
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
          "#{@tenant_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      get_body = Jason.decode!(get_response.resp_body)
      assert get_body["data"]["attributes"]["priority"] == 95
    end

    test "master can preview layout version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{
            name: "Layout Master Preview",
            path: "/mp1",
            template: "<div>mp1</div>",
            priority: 25
          },
          site2.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>mp2</div>", priority: 85},
        tenant: site2.id
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      version =
        MishkaCmsCore.Runtime.Layout.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: layout.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{layout.id}/version/#{version.id}/preview",
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
      layout =
        create_layout_via_ash(
          %{name: "Layout Version Count", path: "/vc1", template: "<div>vc1</div>"},
          site.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>vc2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>vc3</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}?fields[layout]=name,version_count",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["version_count"] == 3
    end

    test "can load latest_version calculation", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Latest Version", path: "/latest", template: "<div>latest</div>"},
          site.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>latest2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}?fields[layout]=name,latest_version",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["latest_version"] != nil
    end

    test "can load recent_versions calculation", %{tenant_admin: tenant_admin, site: site} do
      layout =
        create_layout_via_ash(
          %{name: "Layout Recent Versions", path: "/recent", template: "<div>recent</div>"},
          site.id
        )

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>recent2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>recent3</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("layout_versions", layout.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}?fields[layout]=name,recent_versions",
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
      _layout =
        create_layout_via_ash(
          %{name: "Layout Auth Test", path: "/auth", template: "<div>auth</div>"},
          site.id
        )

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
      _layout =
        create_layout_via_ash(
          %{name: "Layout Invalid Token", path: "/invalid", template: "<div>invalid</div>"},
          site.id
        )

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
    test "tenant from site1 cannot access site2 layouts (except global)", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      layout =
        create_layout_via_ash(
          %{name: "Layout Site2 Isolation", path: "/isolated", template: "<div>isolated</div>"},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      # Try to get
      get_response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404

      # Try to update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{layout.id}",
          %{"type" => "layout", "attributes" => %{"name" => "Hacked"}},
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
          "#{@tenant_path}/#{layout.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert delete_response.status == 404
    end

    test "master can access layouts from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      layout_site1 =
        create_layout_via_ash(
          %{name: "Layout Site1 Master", path: "/s1m", template: "<div>s1m</div>"},
          site.id
        )

      layout_site2 =
        create_layout_via_ash(
          %{name: "Layout Site2 Master", path: "/s2m", template: "<div>s2m</div>"},
          site2.id
        )

      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Master Access",
          path: "/gma",
          template: "<div>gma</div>"
        })

      token = sign_in_master(master_user)

      # Master can list layouts from all sites
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
      # Master sees all sites' layouts plus global
      assert layout_site1.id in ids
      assert layout_site2.id in ids
      assert global_layout.id in ids
    end
  end

  describe "GLOBAL LAYOUT ACCESS CONTROL" do
    test "tenant can read global layout but cannot modify", %{tenant_admin: tenant_admin} do
      global_layout =
        create_global_layout_via_ash(%{
          name: "Global Read Only",
          path: "/gro",
          template: "<div>gro</div>"
        })

      token = sign_in_tenant(tenant_admin)

      # Can read
      get_response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 200

      # Cannot update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}",
          %{"type" => "layout", "attributes" => %{"name" => "Modified"}},
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
          "#{@tenant_path}/#{global_layout.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert archive_response.status in [403, 404]

      # Cannot permanently delete
      perm_delete_response =
        make_api_request(
          "#{@tenant_path}/#{global_layout.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert perm_delete_response.status in [403, 404]
    end
  end

  # THE API HAS ITS OWN NAMES. `admin:api:runtime:layout` writes over it; `admin:dashboard:runtime:layout` is the
  # screens' name and does not reach it; another API area reads the list and writes nothing.
  describe "the layout area over the API" do
    alias MishkaCmsCoreWeb.Test.AreaApi

    test "admin:api:runtime:layout writes; admin:dashboard:runtime:layout and another area do not",
         %{site: site} do
      api = area_token!(site, ["admin:api:runtime:layout"])
      dashboard = area_token!(site, ["admin:dashboard:runtime:layout"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])

      assert AreaApi.post(@tenant_path, "layout", dashboard, %{
               "name" => AreaApi.unique("layout"),
               "path" => "/" <> AreaApi.unique("layout"),
               "template" => ""
             }).status == 403

      assert AreaApi.post(@tenant_path, "layout", unrelated, %{
               "name" => AreaApi.unique("layout"),
               "path" => "/" <> AreaApi.unique("layout"),
               "template" => ""
             }).status == 403

      assert AreaApi.post(@tenant_path, "layout", api, %{
               "name" => AreaApi.unique("layout"),
               "path" => "/" <> AreaApi.unique("layout"),
               "template" => ""
             }).status == 201

      assert AreaApi.list(@tenant_path, unrelated).status == 200
      assert AreaApi.list(@tenant_path, dashboard).status == 403
    end

    test "markup typed over the API is written by the section or by code", %{site: site} do
      area = area_token!(site, ["admin:api:runtime:layout"])
      code = area_token!(site, ["admin:api:code"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])

      typed = fn ->
        %{
          "name" => AreaApi.unique("layout"),
          "path" => "/" <> AreaApi.unique("layout"),
          "template" => "<main>{@inner_content}</main>"
        }
      end

      assert AreaApi.post(@tenant_path, "layout", code, typed.()).status == 201
      refute AreaApi.post(@tenant_path, "layout", unrelated, typed.()).status == 201
      assert AreaApi.post(@tenant_path, "layout", area, typed.()).status == 201
    end
  end
end
