# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.ComponentTest do
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :unit
  @moduletag :capture_log

  require Ash.Query
  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/component"
  @master_path "/api/json/v1/master/admin/runtime/component"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    Application.put_env(:ash_json_api, MishkaCmsCore, router: MishkaCmsCore.TestRouter)

    # Create initial site for testing
    site =
      create_site!(name: "localhost", host: "localhost", active: true, priority: 50, master: true)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    # Create a second site for cross-tenant testing
    site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 40)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site2.id,
      name: site2.name,
      host: site2.host,
      priority: site2.priority,
      active: site2.active
    })

    # Create admin permission
    admin_permission = create_permission!(name: "admin:api:*")

    # Create master user with admin permissions (no site_id)
    master_user =
      MishkaCmsCore.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "master@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })
      |> Ash.create!(authorize?: false, tenant: nil)
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [admin_permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    # Create tenant admin user for site1
    tenant_admin =
      create_user!(
        email: "admin@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site.id
      )
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [admin_permission.id]},
        authorize?: false,
        tenant: site.id
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
      tenant_admin: tenant_admin
    }
  end

  describe "MASTER ADMIN - CREATE - POST #{@master_path}" do
    test "master admin can create component for any site", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      token = sign_in_master(master_user)

      # Create component for site1
      response =
        make_api_request(
          @master_path,
          %{
            "type" => "component",
            "attributes" => %{
              "name" => "Site1 Component",
              "template" => "<div>Site 1</div>",
              "description" => "Site 1 component",
              "format" => "heex",
              "priority" => 10,
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
      assert body["data"]["attributes"]["name"] == "site1-component"
      assert body["data"]["attributes"]["site_id"] == site.id

      # Create component for site2
      response2 =
        make_api_request(
          @master_path,
          %{
            "type" => "component",
            "attributes" => %{
              "name" => "Site2 Component",
              "template" => "<div>Site 2</div>",
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

      assert response2.status == 201
      body2 = Jason.decode!(response2.resp_body)
      assert body2["data"]["attributes"]["site_id"] == site2.id
    end

    test "master admin can create global component with nil site_id", %{
      master_user: master_user
    } do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "component",
            "attributes" => %{
              "name" => "Global Component",
              "template" => "<div>Global</div>",
              "description" => "Available to all sites"
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
      assert body["data"]["attributes"]["name"] == "global-component"
      assert body["data"]["attributes"]["site_id"] == nil
    end
  end

  describe "MASTER ADMIN - READ - GET #{@master_path}" do
    test "master admin can list components from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      token = sign_in_master(master_user)

      comp1 = create_component!(site_id: site.id, name: "Site1 Comp")
      comp2 = create_component!(site_id: site2.id, name: "Site2 Comp")
      global = create_component!(site_id: nil, name: "Global Comp")

      response =
        make_api_request(
          @master_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])

      ids = Enum.map(body["data"], & &1["id"])
      assert comp1.id in ids
      assert comp2.id in ids
      assert global.id in ids
    end

    test "master admin can get any component by id", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id, name: "Test Component")

      response =
        make_api_request(
          "#{@master_path}/#{component.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == component.id
      assert body["data"]["attributes"]["name"] == "test-component"
    end
  end

  describe "MASTER ADMIN - UPDATE - PATCH #{@master_path}/:id" do
    test "master admin can update any component", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id, name: "Original", priority: 0)

      response =
        make_api_request(
          "#{@master_path}/#{component.id}",
          %{
            "type" => "component",
            "attributes" => %{
              "name" => "Updated",
              "priority" => 50
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
      assert body["data"]["attributes"]["name"] == "updated"
      assert body["data"]["attributes"]["priority"] == 50
    end

    test "master admin can update global component", %{
      master_user: master_user
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: nil, name: "Global Original")

      response =
        make_api_request(
          "#{@master_path}/#{component.id}",
          %{
            "type" => "component",
            "attributes" => %{
              "description" => "Updated global"
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
      assert body["data"]["attributes"]["description"] == "Updated global"
    end
  end

  describe "MASTER ADMIN - DELETE - Soft delete (archive)" do
    test "master admin can archive any component", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id, name: "To Archive")

      response =
        make_api_request(
          "#{@master_path}/#{component.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify archived (not in regular list)
      list_response =
        make_api_request(
          @master_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      list_body = Jason.decode!(list_response.resp_body)
      ids = Enum.map(list_body["data"], & &1["id"])
      refute component.id in ids
    end

    test "master admin can archive global component", %{
      master_user: master_user
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: nil, name: "Global To Archive")

      response =
        make_api_request(
          "#{@master_path}/#{component.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "MASTER ADMIN - ARCHIVED - Working with archived records" do
    test "master admin can list archived components from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      token = sign_in_master(master_user)

      comp1 = create_component!(site_id: site.id)
      comp2 = create_component!(site_id: site2.id)
      global = create_component!(site_id: nil)

      # Archive them
      comp1
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      comp2
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
      |> Ash.destroy!()

      # Archive global using master action
      global
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

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
      assert comp1.id in ids
      assert comp2.id in ids
      assert global.id in ids
    end

    test "master admin can get archived component by id", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id)

      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      response =
        make_api_request(
          "#{@master_path}/archived/#{component.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == component.id
    end

    test "master admin can unarchive any component", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id)

      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      response =
        make_api_request(
          "#{@master_path}/#{component.id}/unarchive",
          %{"type" => "component", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
    end
  end

  describe "MASTER ADMIN - DELETE - Permanent deletion" do
    test "master admin can permanently delete any component", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id)
      component_id = component.id

      response =
        make_api_request(
          "#{@master_path}/#{component_id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify completely gone
      archived_response =
        make_api_request(
          "#{@master_path}/archived",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      archived_body = Jason.decode!(archived_response.resp_body)
      archived_ids = Enum.map(archived_body["data"], & &1["id"])
      refute component_id in archived_ids
    end

    test "master admin can permanently delete global component", %{
      master_user: master_user
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: nil, name: "Global To Delete")
      component_id = component.id

      response =
        make_api_request(
          "#{@master_path}/#{component_id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify completely gone
      archived_response =
        make_api_request(
          "#{@master_path}/archived",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      archived_body = Jason.decode!(archived_response.resp_body)
      archived_ids = Enum.map(archived_body["data"], & &1["id"])
      refute component_id in archived_ids
    end
  end

  describe "TENANT ADMIN - POST #{@tenant_path} (create)" do
    test "creates new component for tenant", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      params = %{
        "type" => "component",
        "attributes" => %{
          "name" => "My Component",
          "template" => "<div>Hello <%= @name %></div>",
          "description" => "A simple greeting component",
          "format" => "heex",
          "priority" => 5
        }
      }

      response =
        make_api_request(
          @tenant_path,
          params,
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)

      assert body["data"]["type"] == "component"
      assert body["data"]["attributes"]["name"] == "my-component"
      assert body["data"]["attributes"]["format"] == "heex"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "auto-slugifies component name", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      params = %{
        "type" => "component",
        "attributes" => %{
          "name" => "My Test Component Name",
          "template" => "<div>Test</div>"
        }
      }

      response =
        make_api_request(
          @tenant_path,
          params,
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "my-test-component-name"
    end

    test "validates required fields", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      params = %{
        "type" => "component",
        "attributes" => %{
          "name" => "Missing Template"
        }
      }

      response =
        make_api_request(
          @tenant_path,
          params,
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [400, 422]
    end

    test "requires authentication", %{site: site} do
      params = %{
        "type" => "component",
        "attributes" => %{
          "name" => "Unauthorized",
          "template" => "<div>No auth</div>"
        }
      }

      response =
        make_api_request(
          @tenant_path,
          params,
          method: :post,
          headers: [
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [401, 403]
    end
  end

  describe "TENANT ADMIN - GET #{@tenant_path} (index with globals)" do
    test "lists tenant components AND global components", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      # Create components
      tenant_comp = create_component!(site_id: site.id, name: "Tenant Comp")
      global_comp = create_component!(site_id: nil, name: "Global Comp")
      other_site_comp = create_component!(site_id: site2.id, name: "Other Site")

      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      ids = Enum.map(body["data"], & &1["id"])
      # Should see tenant and global
      assert tenant_comp.id in ids
      assert global_comp.id in ids
      # Should NOT see other site
      refute other_site_comp.id in ids
    end

    test "excludes archived components", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      active = create_component!(site_id: site.id, name: "Active")
      archived = create_component!(site_id: site.id, name: "Archived")

      # Archive one
      archived
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      ids = Enum.map(body["data"], & &1["id"])
      assert active.id in ids
      refute archived.id in ids
    end

    test "requires authentication", %{site: site} do
      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [{"x-site-id", site.id}]
        )

      assert response.status in [401, 403]
    end
  end

  describe "TENANT ADMIN - GET #{@tenant_path}/:id (show with globals)" do
    test "retrieves tenant's own component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(name: "My Component", site_id: site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == component.id
      assert body["data"]["attributes"]["name"] == "my-component"
    end

    test "can retrieve global component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      global = create_component!(name: "Global Comp", site_id: nil)

      response =
        make_api_request(
          "#{@tenant_path}/#{global.id}",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == global.id
    end

    test "cannot retrieve other site's component", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      other_comp = create_component!(site_id: site2.id, name: "Other Site")

      response =
        make_api_request(
          "#{@tenant_path}/#{other_comp.id}",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 404
    end

    test "returns 404 for non-existent component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)
      fake_id = Ash.UUID.generate()

      response =
        make_api_request(
          "#{@tenant_path}/#{fake_id}",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - PATCH #{@tenant_path}/:id (update)" do
    test "updates tenant's own component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site.id, name: "Original", priority: 0)

      params = %{
        "type" => "component",
        "attributes" => %{
          "name" => "Updated",
          "priority" => 25
        }
      }

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}",
          params,
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "updated"
      assert body["data"]["attributes"]["priority"] == 25
    end

    test "cannot update global component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      global = create_component!(site_id: nil, name: "Global")

      params = %{
        "type" => "component",
        "attributes" => %{
          "description" => "Attempted update"
        }
      }

      response =
        make_api_request(
          "#{@tenant_path}/#{global.id}",
          params,
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      # Should fail - tenant cannot modify global components
      assert response.status in [400, 403, 404, 422]
    end

    test "cannot update other site's component", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      other_comp = create_component!(site_id: site2.id, name: "Other Site")

      params = %{
        "type" => "component",
        "attributes" => %{
          "description" => "Attempted update"
        }
      }

      response =
        make_api_request(
          "#{@tenant_path}/#{other_comp.id}",
          params,
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 404
    end

    test "requires authentication", %{site: site} do
      component = create_component!(site_id: site.id)

      params = %{
        "type" => "component",
        "attributes" => %{
          "description" => "No auth"
        }
      }

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}",
          params,
          method: :patch,
          headers: [
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status in [401, 403]
    end
  end

  describe "TENANT ADMIN - DELETE #{@tenant_path}/:id/archive (destroy)" do
    test "archives tenant's own component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site.id, name: "To Archive")

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200

      # Verify not in regular list
      list_response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      list_body = Jason.decode!(list_response.resp_body)
      ids = Enum.map(list_body["data"], & &1["id"])
      refute component.id in ids
    end

    test "cannot archive global component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      global = create_component!(site_id: nil, name: "Global")

      response =
        make_api_request(
          "#{@tenant_path}/#{global.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      # Should fail - tenant cannot modify global components
      assert response.status in [400, 403, 404, 422]
    end

    test "cannot archive other site's component", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      other_comp = create_component!(site_id: site2.id, name: "Other Site")

      response =
        make_api_request(
          "#{@tenant_path}/#{other_comp.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 404
    end

    test "returns 404 for non-existent component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)
      fake_id = Ash.UUID.generate()

      response =
        make_api_request(
          "#{@tenant_path}/#{fake_id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - Archived components" do
    test "lists archived components", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      active = create_component!(site_id: site.id, name: "Active")
      to_archive = create_component!(site_id: site.id, name: "To Archive")

      # Archive one
      to_archive
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      response =
        make_api_request(
          "#{@tenant_path}/archived",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      ids = Enum.map(body["data"], & &1["id"])
      assert to_archive.id in ids
      refute active.id in ids
    end

    test "gets archived component by id", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site.id)

      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{component.id}",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == component.id
    end

    test "can unarchive tenant's own component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site.id)

      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/unarchive",
          %{"type" => "component", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200

      # Verify it's back in regular list
      list_response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      list_body = Jason.decode!(list_response.resp_body)
      ids = Enum.map(list_body["data"], & &1["id"])
      assert component.id in ids
    end
  end

  describe "TENANT ADMIN - DELETE #{@tenant_path}/:id/permanent (permanent destroy)" do
    test "permanently deletes tenant's own component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site.id)
      component_id = component.id

      response =
        make_api_request(
          "#{@tenant_path}/#{component_id}/permanent",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response.status == 200

      # Verify completely gone
      archived_response =
        make_api_request(
          "#{@tenant_path}/archived",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      archived_body = Jason.decode!(archived_response.resp_body)
      archived_ids = Enum.map(archived_body["data"], & &1["id"])
      refute component_id in archived_ids
    end

    test "cannot permanently delete global component", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      global = create_component!(site_id: nil, name: "Global")

      response =
        make_api_request(
          "#{@tenant_path}/#{global.id}/permanent",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      # Should fail - tenant cannot modify global components
      assert response.status in [404]
    end

    test "cannot permanently delete other site's component", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      other_comp = create_component!(site_id: site2.id, name: "Other Site")

      response =
        make_api_request(
          "#{@tenant_path}/#{other_comp.id}/permanent",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      # Should fail - tenant cannot modify other site's components
      assert response.status == 404
    end
  end

  describe "CALCULATIONS - is_global and component_module" do
    test "tenant admin can get is_global calculation", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      tenant_comp = create_component!(site_id: site.id, name: "Tenant")
      global_comp = create_component!(site_id: nil, name: "Global")

      # Get tenant component
      response1 =
        make_api_request(
          "#{@tenant_path}/#{tenant_comp.id}?fields[component]=name,is_global",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response1.status == 200
      body1 = Jason.decode!(response1.resp_body)
      assert body1["data"]["attributes"]["is_global"] == false

      # Get global component
      response2 =
        make_api_request(
          "#{@tenant_path}/#{global_comp.id}?fields[component]=name,is_global",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert response2.status == 200
      body2 = Jason.decode!(response2.resp_body)
      assert body2["data"]["attributes"]["is_global"] == true
    end

    test "master admin can get component_module calculation", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id, name: "Test Module")

      response =
        make_api_request(
          "#{@master_path}/#{component.id}?fields[component]=name,component_module",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["component_module"] != nil
    end
  end

  describe "VERSION MANAGEMENT - GET /component/:id/with-versions" do
    test "tenant admin can get component with paginated versions", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      component =
        create_component!(
          site_id: site.id,
          name: "Original",
          description: "Original desc"
        )

      # Update to create versions
      component
      |> Ash.Changeset.for_update(:update, %{description: "Version 1"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      component
      |> Ash.Changeset.for_update(:update, %{description: "Version 2"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Wait for versions
      wait_for_version_count("component_versions", component.id, 3)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/with-versions?fields[component]=name,description,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == component.id

      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 3
    end

    test "tenant admin cannot get other site's component with versions", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site2.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/with-versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end

    test "master admin can get any component with versions", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{description: "Updated"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      response =
        make_api_request(
          "#{@master_path}/#{component.id}/with-versions?fields[component]=name,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end

    test "master admin can list versions for any component", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id)

      # Create versions
      component
      |> Ash.Changeset.for_update(:update, %{name: "Version1"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      component
      |> Ash.Changeset.for_update(:update, %{name: "Version2"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 3)

      response =
        make_api_request(
          "#{@master_path}/#{component.id}/versions?fields[component]=name,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      assert is_list(body["data"])
      assert length(body["data"]) == 1

      component_data = List.first(body["data"])
      sorted_versions = component_data["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 3
    end
  end

  describe "VERSION MANAGEMENT - Calculations (version_count, latest_version, recent_versions)" do
    test "tenant admin can get version calculations", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      component =
        create_component!(
          site_id: site.id,
          name: "Original",
          description: "Desc 1"
        )

      # Create multiple versions
      updated1 =
        component
        |> Ash.Changeset.for_update(:update, %{description: "Desc 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      updated2 =
        updated1
        |> Ash.Changeset.for_update(:update, %{description: "Desc 3"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      _updated3 =
        updated2
        |> Ash.Changeset.for_update(:update, %{description: "Desc 4"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      # Wait for versions
      wait_for_version_count("component_versions", component.id, 4)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}?fields[component]=name,version_count,latest_version,recent_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      # Check version_count
      assert body["data"]["attributes"]["version_count"] == 4

      # Check latest_version
      latest = body["data"]["attributes"]["latest_version"]
      assert is_map(latest)
      assert latest["changes"]["description"] == "Desc 4"

      # Check recent_versions
      recent = body["data"]["attributes"]["recent_versions"]
      assert is_list(recent)
      assert length(recent) == 4

      # Verify sorted descending
      descriptions = Enum.map(recent, & &1["changes"]["description"])
      assert Enum.at(descriptions, 0) == "Desc 4"
      assert Enum.at(descriptions, 3) == "Desc 1"
    end
  end

  describe "VERSION MANAGEMENT - GET /component/:id/versions" do
    test "tenant admin can list versions for their component", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site.id)

      # Create versions
      component
      |> Ash.Changeset.for_update(:update, %{name: "Version1"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      component
      |> Ash.Changeset.for_update(:update, %{name: "Version2"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 3)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/versions?fields[component]=name,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      assert is_list(body["data"])
      assert length(body["data"]) == 1

      component_data = List.first(body["data"])
      sorted_versions = component_data["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 3
    end

    test "tenant admin cannot list versions from other site's component", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site2.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - PATCH /component/:id/version/:version_id/restore" do
    test "tenant admin can restore their component version", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      component =
        create_component!(
          site_id: site.id,
          name: "Original",
          description: "Original desc"
        )

      # Create version
      updated =
        component
        |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      # Get first version
      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@tenant_path}/#{updated.id}/version/#{version.id}/restore",
          %{"type" => "component", "attributes" => %{}},
          method: :patch,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "original"
      assert body["data"]["attributes"]["description"] == "Original desc"
    end

    test "tenant admin cannot restore other site's component version", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site2.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{name: "Updated"},
        tenant: site2.id,
        authorize?: false
      )
      |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/version/#{version.id}/restore",
          %{"type" => "component", "attributes" => %{}},
          method: :patch,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end

    test "tenant admin cannot restore global component version", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      # Create global component
      global = create_component!(site_id: nil, name: "Global Original")

      # Create version using master action
      global
      |> Ash.Changeset.for_update(:master_update, %{name: "Global Updated"}, authorize?: false)
      |> Ash.update!()

      wait_for_version_count("component_versions", global.id, 2)

      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: global.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@tenant_path}/#{global.id}/version/#{version.id}/restore",
          %{"type" => "component", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      # Should fail - tenant cannot modify global components
      assert response.status in [400, 403, 404, 422]
    end

    test "master admin can restore any component version", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id, name: "Original")

      # Create version
      updated =
        component
        |> Ash.Changeset.for_update(:update, %{name: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@master_path}/#{updated.id}/version/#{version.id}/restore",
          %{"type" => "component", "attributes" => %{}},
          method: :patch,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "original"
    end
  end

  describe "VERSION MANAGEMENT - GET /component/:id/version/:version_id/preview" do
    test "tenant admin can preview version without restoring", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      component =
        create_component!(
          site_id: site.id,
          name: "Original",
          description: "Original desc"
        )

      # Create version
      updated =
        component
        |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "original"
      assert body["data"]["attributes"]["description"] == "Original desc"

      # Verify actual component is unchanged
      current_response =
        make_api_request(
          "#{@tenant_path}/#{updated.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      current_body = Jason.decode!(current_response.resp_body)
      assert current_body["data"]["attributes"]["name"] == "updated"
    end

    test "tenant admin cannot preview version from other site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      component = create_component!(site_id: site2.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{name: "Updated"},
        tenant: site2.id,
        authorize?: false
      )
      |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@tenant_path}/#{component.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end

    test "master admin can preview any component version", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      component = create_component!(site_id: site.id, name: "Original")

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{name: "Updated"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      wait_for_version_count("component_versions", component.id, 2)

      version =
        MishkaCmsCore.Runtime.Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      response =
        make_api_request(
          "#{@master_path}/#{component.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "original"
    end
  end

  describe "TENANT ADMIN - Global component restrictions" do
    test "can read global component but cannot update", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      global = create_component!(site_id: nil, name: "Global Read Only")

      # Can read
      get_response =
        make_api_request(
          "#{@tenant_path}/#{global.id}",
          %{},
          method: :get,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

      assert get_response.status == 200

      # Cannot update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{global.id}",
          %{
            "type" => "component",
            "attributes" => %{"description" => "Attempted update"}
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert update_response.status in [400, 403, 404, 422]
    end
  end

  # THE API HAS ITS OWN NAMES. `admin:api:runtime:component` writes over it; `admin:dashboard:runtime:component` is the
  # screens' name and does not reach it; another API area reads the list and writes nothing.
  describe "the component area over the API" do
    alias MishkaCmsCoreWeb.Test.AreaApi

    test "admin:api:runtime:component writes; admin:dashboard:runtime:component and another area do not",
         %{
           site: site
         } do
      api = area_token!(site, ["admin:api:runtime:component"])
      dashboard = area_token!(site, ["admin:dashboard:runtime:component"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])

      assert AreaApi.post(@tenant_path, "component", dashboard, %{
               "name" => AreaApi.unique("component"),
               "template" => ""
             }).status == 403

      assert AreaApi.post(@tenant_path, "component", unrelated, %{
               "name" => AreaApi.unique("component"),
               "template" => ""
             }).status == 403

      assert AreaApi.post(@tenant_path, "component", api, %{
               "name" => AreaApi.unique("component"),
               "template" => ""
             }).status == 201

      assert AreaApi.list(@tenant_path, unrelated).status == 200
      assert AreaApi.list(@tenant_path, dashboard).status == 403
    end

    test "markup typed over the API is written by the section or by code", %{site: site} do
      area = area_token!(site, ["admin:api:runtime:component"])
      code = area_token!(site, ["admin:api:code"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])
      typed = fn -> %{"name" => AreaApi.unique("component"), "template" => "<b>typed</b>"} end

      assert AreaApi.post(@tenant_path, "component", code, typed.()).status == 201
      refute AreaApi.post(@tenant_path, "component", unrelated, typed.()).status == 201
      assert AreaApi.post(@tenant_path, "component", area, typed.()).status == 201
    end
  end
end
