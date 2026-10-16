# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.SiteTest do
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  @password "Password123!"
  @api_user_path "/api/json/v1/auth/user"
  @api_master_path "/api/json/v1/master/admin/runtime/site"
  @api_tenant_path "/api/json/v1/tenant/admin/runtime/site"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    Application.put_env(:ash_json_api, MishkaCmsCore.Runtime, router: MishkaCmsCore.TestRouter)

    # Create admin permission
    admin_permission = create_permission!(name: "admin:api:*")

    # Create master user (no site_id) with admin permissions
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

    # Create first site (must be localhost for authentication to work)
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

    # Create second site for cross-tenant testing
    site2 =
      create_site!(name: "TestSite2", host: "test2.example.com", active: true, priority: 60)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site2.id,
      name: site2.name,
      host: site2.host,
      priority: site2.priority,
      active: site2.active
    })

    # Create tenant admin for site1
    tenant_admin =
      create_user!(
        email: "site1.admin@example.com",
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

    # Create regular tenant user for site1 (without admin permission)
    tenant_user =
      create_user!(
        email: "site1.user@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site.id
      )

    # Create tenant admin for site2
    site2_admin =
      create_user!(
        email: "site2.admin@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site2.id
      )
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [admin_permission.id]},
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
      tenant_user: tenant_user,
      site2_admin: site2_admin
    }
  end

  # Helper functions
  defp sign_in_master(master_user) do
    sign_in_response =
      make_api_request(
        "#{@api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{
            "email" => to_string(master_user.email),
            "password" => @password
          }
        },
        headers: [{"x-no-tenant", "true"}],
        host: "localhost"
      )

    assert sign_in_response.status == 201
    %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
    token
  end

  defp sign_in_tenant(tenant_user, site) do
    sign_in_response =
      make_api_request(
        "#{@api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{
            "email" => to_string(tenant_user.email),
            "password" => @password
          }
        },
        host: site.host
      )

    assert sign_in_response.status == 201
    %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
    token
  end

  describe "CREATE - POST /master/admin/runtime/site" do
    test "master admin can create site", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "NewSite",
              "host" => "newsite.example.com",
              "active" => true,
              "priority" => 100
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "newsite"
      assert body["data"]["attributes"]["host"] == "newsite.example.com"
      assert body["data"]["attributes"]["active"] == true
      assert body["data"]["attributes"]["priority"] == 100
    end

    # There is always a master site, since masters sign in on it; set-master is what moves the flag.
    test "master admin cannot create a second master site", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "MasterSite",
              "host" => "master.example.com",
              "active" => true,
              "priority" => 10,
              "master" => true
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 400

      assert response.resp_body =~
               "Another site is the master site. Use Set Master to move it to this one."

      assert Ash.get!(MishkaCmsCore.Runtime.Site, site.id, action: :get_any, authorize?: false).master
    end

    test "tenant admin cannot create site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "UnauthorizedSite",
              "host" => "unauthorized.example.com",
              "active" => true,
              "priority" => 50
            }
          },
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Tenant users cannot access master endpoints
      assert response.status == 400
    end

    test "validates required fields", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Missing name
      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "host" => "incomplete.example.com"
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end

    test "validates host uniqueness", %{master_user: master_user, site: existing_site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "DuplicateHost",
              "host" => existing_site.host,
              "active" => true,
              "priority" => 50
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end
  end

  describe "READ - GET /master/admin/runtime/site (master_read)" do
    test "master admin can list all sites", %{master_user: master_user, site: site, site2: site2} do
      token = sign_in_master(master_user)

      # Create additional site
      site3 =
        create_site!(name: "TestSite3", host: "test3.example.com", active: false, priority: 30)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site3.id,
        name: site3.name,
        host: site3.host,
        priority: site3.priority,
        active: site3.active
      })

      response =
        make_api_request(
          @api_master_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])

      ids = Enum.map(body["data"], & &1["id"])
      assert site.id in ids
      assert site2.id in ids
      assert site3.id in ids
    end

    test "master admin can get specific site by id", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == site.id
      assert body["data"]["attributes"]["name"] == site.name
      assert body["data"]["attributes"]["host"] == site.host
    end

    test "master admin can list archived sites", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Create and archive a site
      archived_site =
        create_site!(name: "ArchivedSite", host: "archived.example.com", active: true)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: archived_site.id,
        name: archived_site.name,
        host: archived_site.host,
        priority: archived_site.priority,
        active: archived_site.active
      })

      # Archive it
      Ash.destroy!(archived_site, action: :destroy, authorize?: false)

      response =
        make_api_request(
          "#{@api_master_path}/archived",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])

      ids = Enum.map(body["data"], & &1["id"])
      assert archived_site.id in ids
    end

    test "master admin can get specific archived site", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Create and archive a site
      archived_site =
        create_site!(name: "GetArchivedSite", host: "getarchived.example.com", active: true)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: archived_site.id,
        name: archived_site.name,
        host: archived_site.host,
        priority: archived_site.priority,
        active: archived_site.active
      })

      # Archive it
      Ash.destroy!(archived_site, action: :destroy, authorize?: false)

      response =
        make_api_request(
          "#{@api_master_path}/archived/#{archived_site.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == archived_site.id
      assert body["data"]["attributes"]["name"] == "getarchivedsite"
    end

    test "tenant admin cannot access master list endpoint", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          @api_master_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Tenant users cannot access master endpoints
      assert response.status == 400
    end
  end

  describe "READ - GET /tenant/admin/runtime/site (tenant read)" do
    test "tenant admin can list their own site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          @api_tenant_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])

      # Should only see their own site
      ids = Enum.map(body["data"], & &1["id"])
      assert site.id in ids
      assert length(body["data"]) == 1
    end

    test "tenant admin can get their own site by id", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_tenant_path}/#{site.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == site.id
      assert body["data"]["attributes"]["name"] == site.name
    end

    test "tenant admin cannot get other site by id", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_tenant_path}/#{site2.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Cannot access other tenant's site
      assert response.status in [401, 403, 404]
    end

    test "tenant user without admin permission cannot access tenant endpoints", %{
      tenant_user: tenant_user,
      site: site
    } do
      token = sign_in_tenant(tenant_user, site)

      response =
        make_api_request(
          @api_tenant_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Regular users without admin permission should be denied
      assert response.status in [401, 403]
    end

    test "cross-tenant isolation - site2 admin cannot see site1", %{
      site2_admin: site2_admin,
      site: site,
      site2: site2
    } do
      token = sign_in_tenant(site2_admin, site2)

      response =
        make_api_request(
          @api_tenant_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site2.host
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      ids = Enum.map(body["data"], & &1["id"])
      # Should only see site2, not site1
      assert site2.id in ids
      refute site.id in ids
    end
  end

  describe "UPDATE - PATCH /master/admin/runtime/site/:id" do
    test "master admin can update site", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}",
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "UpdatedSiteName",
              "priority" => 99
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "updatedsitename"
      assert body["data"]["attributes"]["priority"] == 99
    end

    test "master admin can update any site", %{
      master_user: master_user,
      site2: site2
    } do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@api_master_path}/#{site2.id}",
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "Site2Updated"
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["name"] == "site2updated"
    end

    test "tenant admin cannot update site via master endpoint", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}",
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "UnauthorizedUpdate"
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Tenant users cannot access master endpoints
      assert response.status == 400
    end

    test "validates host uniqueness on update", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      token = sign_in_master(master_user)

      # Try to update site to use site2's host
      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}",
          %{
            "type" => "site",
            "attributes" => %{
              "host" => site2.host
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end
  end

  describe "ACTIVATE - PATCH /master/admin/runtime/site/:id/activate" do
    test "master admin can activate site", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Create inactive site
      inactive_site =
        create_site!(name: "InactiveSite", host: "inactive.example.com", active: false)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: inactive_site.id,
        name: inactive_site.name,
        host: inactive_site.host,
        priority: inactive_site.priority,
        active: inactive_site.active
      })

      response =
        make_api_request(
          "#{@api_master_path}/#{inactive_site.id}/activate",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["active"] == true
    end

    test "tenant admin cannot activate site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/activate",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "DEACTIVATE - PATCH /master/admin/runtime/site/:id/deactivate" do
    test "master admin can deactivate site", %{master_user: master_user, site2: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/deactivate",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["active"] == false
    end

    test "tenant admin cannot deactivate site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/deactivate",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "SET_AS_MASTER - PATCH /master/admin/runtime/site/:id/set-master" do
    test "master admin can set site as master", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/set-master",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["master"] == true
    end

    test "only one site can be master at a time", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      token = sign_in_master(master_user)

      # Set site as master
      response1 =
        make_api_request(
          "#{@api_master_path}/#{site.id}/set-master",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response1.status == 200

      # Try to set site2 as master - should unset site
      response2 =
        make_api_request(
          "#{@api_master_path}/#{site2.id}/set-master",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response2.status == 200
      body2 = Jason.decode!(response2.resp_body)
      assert body2["data"]["attributes"]["master"] == true

      # Verify site is no longer master: masters now sign in on site2's address, and the old one
      # no longer knows them
      read_site = fn host ->
        make_api_request(
          "#{@api_master_path}/#{site.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: host
        )
      end

      body3 = Jason.decode!(read_site.(site2.host).resp_body)
      assert body3["data"]["attributes"]["master"] == false
      old_address = read_site.("localhost")
      assert old_address.status == 400
      assert %{"errors" => [_ | _]} = Jason.decode!(old_address.resp_body)
    end

    test "tenant admin cannot set site as master", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/set-master",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "UNSET_AS_MASTER - PATCH /master/admin/runtime/site/:id/unset-master" do
    # The master site keeps its flag: every master signs in through it. Setting another site master
    # is how the flag moves.
    test "master admin is refused unsetting the master site", %{
      master_user: master_user,
      site: site
    } do
      token = sign_in_master(master_user)

      # First set as master
      make_api_request(
        "#{@api_master_path}/#{site.id}/set-master",
        %{"type" => "site"},
        method: "PATCH",
        headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
        host: "localhost"
      )

      # Now unset
      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/unset-master",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 400
      assert response.resp_body =~ "Make another site master first"

      assert Ash.get!(MishkaCmsCore.Runtime.Site, site.id, action: :get_any, authorize?: false).master
    end

    test "tenant admin cannot unset site as master", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/unset-master",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "ARCHIVE - DELETE /master/admin/runtime/site/:id/archive" do
    test "master admin can archive site", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Create site to archive
      site_to_archive =
        create_site!(name: "ToArchive", host: "toarchive.example.com", active: true)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site_to_archive.id,
        name: site_to_archive.name,
        host: site_to_archive.host,
        priority: site_to_archive.priority,
        active: site_to_archive.active
      })

      response =
        make_api_request(
          "#{@api_master_path}/#{site_to_archive.id}/archive",
          %{},
          method: "DELETE",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [200, 204]

      # Verify site is archived (should appear in archived list)
      archived_response =
        make_api_request(
          "#{@api_master_path}/archived",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      body = Jason.decode!(archived_response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert site_to_archive.id in ids
    end

    test "tenant admin cannot archive site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/archive",
          %{},
          method: "DELETE",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "UNARCHIVE - PATCH /master/admin/runtime/site/:id/unarchive" do
    test "master admin can unarchive site", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Create and archive a site
      archived_site =
        create_site!(name: "ToUnarchive", host: "tounarchive.example.com", active: true)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: archived_site.id,
        name: archived_site.name,
        host: archived_site.host,
        priority: archived_site.priority,
        active: archived_site.active
      })

      # Archive it
      Ash.destroy!(archived_site, action: :destroy, authorize?: false)

      # Unarchive it
      response =
        make_api_request(
          "#{@api_master_path}/#{archived_site.id}/unarchive",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 200

      # Verify site is back in active list
      active_response =
        make_api_request(
          @api_master_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      body = Jason.decode!(active_response.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert archived_site.id in ids
    end

    test "tenant admin cannot unarchive site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      # Create and archive a site
      archived_site =
        create_site!(name: "TenantUnarchive", host: "tenantunarchive.example.com", active: true)

      Ash.destroy!(archived_site, action: :destroy, authorize?: false)

      response =
        make_api_request(
          "#{@api_master_path}/#{archived_site.id}/unarchive",
          %{"type" => "site"},
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "PERMANENT_DESTROY - DELETE /master/admin/runtime/site/:id/permanent" do
    test "master admin can permanently delete site", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Create site to permanently delete
      site_to_delete =
        create_site!(name: "ToDelete", host: "todelete.example.com", active: true)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site_to_delete.id,
        name: site_to_delete.name,
        host: site_to_delete.host,
        priority: site_to_delete.priority,
        active: site_to_delete.active
      })

      response =
        make_api_request(
          "#{@api_master_path}/#{site_to_delete.id}/permanent",
          %{},
          method: "DELETE",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [200, 204]

      # Verify site is gone from both active and archived lists
      active_response =
        make_api_request(
          @api_master_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      active_body = Jason.decode!(active_response.resp_body)
      active_ids = Enum.map(active_body["data"], & &1["id"])
      refute site_to_delete.id in active_ids

      archived_response =
        make_api_request(
          "#{@api_master_path}/archived",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      archived_body = Jason.decode!(archived_response.resp_body)
      archived_ids = Enum.map(archived_body["data"], & &1["id"])
      refute site_to_delete.id in archived_ids
    end

    test "tenant admin cannot permanently delete site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_master_path}/#{site.id}/permanent",
          %{},
          method: "DELETE",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      assert response.status == 400
    end
  end

  describe "Authorization and Authentication" do
    test "unauthenticated request is denied for master endpoints" do
      response =
        make_api_request(
          @api_master_path,
          %{},
          method: "GET"
        )

      assert response.status in [400, 401, 403]
    end

    test "unauthenticated request is denied for tenant endpoints" do
      response =
        make_api_request(
          @api_tenant_path,
          %{},
          method: "GET"
        )

      assert response.status in [401, 403]
    end

    test "invalid token is rejected for master endpoints" do
      response =
        make_api_request(
          @api_master_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer invalid_token"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [401, 403]
    end

    test "invalid token is rejected for tenant endpoints" do
      response =
        make_api_request(
          @api_tenant_path,
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer invalid_token"}]
        )

      assert response.status in [401, 403]
    end
  end

  describe "Edge Cases and Error Handling" do
    test "master admin cannot get non-existent site", %{master_user: master_user} do
      token = sign_in_master(master_user)
      non_existent_id = Ash.UUID.generate()

      response =
        make_api_request(
          "#{@api_master_path}/#{non_existent_id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 404
    end

    test "master admin cannot update non-existent site", %{master_user: master_user} do
      token = sign_in_master(master_user)
      non_existent_id = Ash.UUID.generate()

      response =
        make_api_request(
          "#{@api_master_path}/#{non_existent_id}",
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "NonExistent"
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 404
    end

    test "validates priority is a number", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "InvalidPriority",
              "host" => "invalid.example.com",
              "priority" => "not_a_number"
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end

    test "validates active is a boolean", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "InvalidActive",
              "host" => "invalid2.example.com",
              "active" => "yes"
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end
  end

  describe "Cross-Tenant Isolation" do
    test "site2 admin cannot access site1 data via tenant endpoint", %{
      site2_admin: site2_admin,
      site: site,
      site2: site2
    } do
      token = sign_in_tenant(site2_admin, site2)

      response =
        make_api_request(
          "#{@api_tenant_path}/#{site.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site2.host
        )

      assert response.status in [401, 403, 404]
    end

    test "tenant cannot impersonate master by manipulating headers", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin, site)

      # Try to access site2 (from different tenant) using master endpoint with x-no-tenant
      response =
        make_api_request(
          "#{@api_master_path}/#{site2.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: site.host
        )

      # Should be denied - tenant token cannot access master endpoints
      assert response.status in [400, 403]
    end

    test "master admin can see all sites regardless of tenant context", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      token = sign_in_master(master_user)

      # Get site1
      response1 =
        make_api_request(
          "#{@api_master_path}/#{site.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response1.status == 200

      # Get site2
      response2 =
        make_api_request(
          "#{@api_master_path}/#{site2.id}",
          %{},
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response2.status == 200
    end
  end

  describe "Data Integrity and Validation" do
    test "host must be unique across all sites", %{master_user: master_user, site: existing_site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "DuplicateHost",
              "host" => existing_site.host,
              "active" => true,
              "priority" => 100
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end

    test "name must be unique across all sites", %{master_user: master_user, site: existing_site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => existing_site.name,
              "host" => "unique.example.com",
              "active" => true,
              "priority" => 100
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status in [400, 422]
    end

    test "priority must be between 0 and 100", %{master_user: master_user} do
      token = sign_in_master(master_user)

      # Priority 0 should be valid
      response1 =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "ZeroPriority",
              "host" => "zero.example.com",
              "priority" => 0
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response1.status == 201

      # Priority too high
      response2 =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "HighPriority",
              "host" => "high.example.com",
              "priority" => 101
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response2.status in [400, 422]
    end

    test "can create site with minimum valid priority", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "MinPriority",
              "host" => "min.example.com",
              "priority" => 1
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["priority"] == 1
    end

    test "can create site with maximum valid priority", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @api_master_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "MaxPriority",
              "host" => "max.example.com",
              "priority" => 100
            }
          },
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}],
          host: "localhost"
        )

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["priority"] == 100
    end
  end

  describe "Tenant Endpoint - Read-Only Verification" do
    test "tenant admin cannot create via tenant endpoint", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          @api_tenant_path,
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "Unauthorized",
              "host" => "unauth.example.com"
            }
          },
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Tenant endpoint doesn't support POST
      assert response.status in [404, 405]
    end

    test "tenant admin cannot update via tenant endpoint", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_tenant_path}/#{site.id}",
          %{
            "type" => "site",
            "attributes" => %{
              "name" => "UpdatedName"
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Tenant endpoint doesn't support PATCH
      assert response.status in [404, 405]
    end

    test "tenant admin cannot delete via tenant endpoint", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin, site)

      response =
        make_api_request(
          "#{@api_tenant_path}/#{site.id}",
          %{},
          method: "DELETE",
          headers: [{"authorization", "Bearer #{token}"}],
          host: site.host
        )

      # Tenant endpoint doesn't support DELETE
      assert response.status in [404, 405]
    end
  end
end
