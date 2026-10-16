# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.MediaCategoryTest do
  @moduledoc """
  Comprehensive JSON API tests for MediaCategory resource.

  MediaCategory does NOT support global items (global? false) - all categories are site-specific.
  Tests cover master and tenant CRUD operations, version management, and cross-tenant isolation.
  """
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :unit
  @moduletag :capture_log

  require Ash.Query

  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/media-category"
  @master_path "/api/json/v1/master/admin/runtime/media-category"

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

  defp create_media_category_via_ash(attrs, site_id) do
    MishkaCmsCore.Runtime.MediaCategory
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id)
    |> Ash.create!(authorize?: false)
  end

  describe "MASTER ADMIN - CREATE" do
    test "master can create media category for site1", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "Images Category",
              "description" => "All image files",
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
      assert body["data"]["attributes"]["name"] == "images-category"
      assert body["data"]["attributes"]["description"] == "All image files"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "master can create media category for site2", %{master_user: master_user, site2: site2} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "Videos Category",
              "description" => "All video files",
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
    end

    test "master create requires site_id", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "No Site Category"
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

    test "master create validates required fields", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "description" => "Missing name",
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
    test "master can list media categories from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      category1 = create_media_category_via_ash(%{name: "Category Site1"}, site.id)
      category2 = create_media_category_via_ash(%{name: "Category Site2"}, site2.id)

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
      assert category1.id in ids
      assert category2.id in ids
    end

    test "master can get media category by id from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Category Get Test"}, site2.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == category.id
      assert body["data"]["attributes"]["name"] == "category-get-test"
    end

    test "master get returns 404 for non-existent media category", %{master_user: master_user} do
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
    test "master can update media category from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category =
        create_media_category_via_ash(
          %{name: "Category Update Test", description: "Old description"},
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}",
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "Updated Category Name",
              "description" => "New description"
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
      assert body["data"]["attributes"]["name"] == "updated-category-name"
      assert body["data"]["attributes"]["description"] == "New description"
    end

    test "master update returns 404 for non-existent media category", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{"type" => "media_category", "attributes" => %{"name" => "Not Found"}},
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
    test "master can archive media category from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Category Archive Test"}, site2.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/archive",
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
      assert category.id in ids
    end
  end

  describe "MASTER ADMIN - ARCHIVED" do
    test "master can list archived media categories from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      category1 = create_media_category_via_ash(%{name: "Category Archived 1"}, site.id)
      category2 = create_media_category_via_ash(%{name: "Category Archived 2"}, site2.id)

      # Archive both
      Ash.destroy!(category1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(category2, action: :destroy, tenant: site2.id, authorize?: false)

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
      assert category1.id in ids
      assert category2.id in ids
    end

    test "master can get archived media category by id", %{master_user: master_user, site: site} do
      category = create_media_category_via_ash(%{name: "Category Archived Get"}, site.id)
      Ash.destroy!(category, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == category.id
    end

    test "master can unarchive media category", %{master_user: master_user, site: site} do
      category = create_media_category_via_ash(%{name: "Category Unarchive"}, site.id)
      Ash.destroy!(category, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/unarchive",
          %{"type" => "media_category", "attributes" => %{}},
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
          "#{@master_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 200
    end
  end

  describe "MASTER ADMIN - PERMANENT DELETE" do
    test "master can permanently delete media category", %{master_user: master_user, site: site} do
      category = create_media_category_via_ash(%{name: "Category Perm Delete"}, site.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@master_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 404
    end
  end

  describe "TENANT ADMIN - CREATE" do
    test "tenant can create media category for their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "Tenant Category",
              "description" => "My category"
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
      assert body["data"]["attributes"]["name"] == "tenant-category"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    test "tenant create validates required fields", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "description" => "Missing name"
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

    test "tenant cannot create media category with another site_id", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "Trying Other Site",
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
            "type" => "media_category",
            "attributes" => %{
              "name" => "Cross Site Create"
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
  end

  describe "TENANT ADMIN - READ" do
    test "tenant can list media categories from their site only", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      category1 = create_media_category_via_ash(%{name: "Tenant Category 1"}, site.id)
      category2 = create_media_category_via_ash(%{name: "Site2 Category"}, site2.id)

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
      # Tenant sees only their site's categories
      assert category1.id in ids
      # But not other site's categories
      refute category2.id in ids
    end

    test "tenant can get media category by id from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category = create_media_category_via_ash(%{name: "Tenant Get Test"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == category.id
    end

    test "tenant cannot get media category from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Other Site Category"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - UPDATE" do
    test "tenant can update media category from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category = create_media_category_via_ash(%{name: "Tenant Update Test"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{
            "type" => "media_category",
            "attributes" => %{
              "name" => "Updated Tenant Category",
              "description" => "Updated description"
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
      assert body["data"]["attributes"]["name"] == "updated-tenant-category"
      assert body["data"]["attributes"]["description"] == "Updated description"
    end

    test "tenant cannot update media category from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Other Update"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{"type" => "media_category", "attributes" => %{"name" => "Should Fail"}},
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
    test "tenant can archive media category from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category = create_media_category_via_ash(%{name: "Tenant Archive"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot archive media category from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Other Archive"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - ARCHIVED" do
    test "tenant can list archived media categories from their site only", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      category1 = create_media_category_via_ash(%{name: "Tenant Arch List 1"}, site.id)
      category2 = create_media_category_via_ash(%{name: "Other Arch List"}, site2.id)

      Ash.destroy!(category1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(category2, action: :destroy, tenant: site2.id, authorize?: false)

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
      assert category1.id in ids
      refute category2.id in ids
    end

    test "tenant can get archived media category by id from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category = create_media_category_via_ash(%{name: "Tenant Arch Get"}, site.id)
      Ash.destroy!(category, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == category.id
    end

    test "tenant can unarchive media category from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category = create_media_category_via_ash(%{name: "Tenant Unarch"}, site.id)
      Ash.destroy!(category, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/unarchive",
          %{"type" => "media_category", "attributes" => %{}},
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
    test "tenant can permanently delete media category from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category = create_media_category_via_ash(%{name: "Tenant Perm Delete"}, site.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404
    end

    test "tenant cannot permanently delete media category from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Other Perm Delete"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - Get With Versions" do
    test "tenant can get media category with versions", %{tenant_admin: tenant_admin, site: site} do
      category = create_media_category_via_ash(%{name: "Category With Versions"}, site.id)

      # Update to create version
      category
      |> Ash.Changeset.for_update(:update, %{description: "Version 2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/with-versions?fields[media_category]=name,description,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == category.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end

    test "master can get media category with versions from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Master With Versions"}, site2.id)

      category
      |> Ash.Changeset.for_update(:update, %{description: "Master v2"}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/with-versions?fields[media_category]=name,description,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == category.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end
  end

  describe "VERSION MANAGEMENT - List Versions" do
    test "tenant can list versions for media category", %{tenant_admin: tenant_admin, site: site} do
      category = create_media_category_via_ash(%{name: "Category List Versions"}, site.id)

      # Create 2 more versions
      category
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      category
      |> Ash.Changeset.for_update(:update, %{description: "v3"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])
    end

    test "master can list versions for media category from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Master List Versions"}, site2.id)

      wait_for_version_count("media_category_versions", category.id, 1)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Restore Version" do
    test "tenant can restore media category to previous version", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category =
        create_media_category_via_ash(
          %{name: "Category Restore", description: "Original desc"},
          site.id
        )

      # Update to create a new version
      category
      |> Ash.Changeset.for_update(:update, %{description: "Updated desc"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      # Get the first (original) version
      version =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: category.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/version/#{version.id}/restore",
          %{"type" => "media_category", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["description"] == "Original desc"
    end

    test "master can restore media category version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category =
        create_media_category_via_ash(
          %{name: "Master Restore", description: "Master original"},
          site2.id
        )

      category
      |> Ash.Changeset.for_update(:update, %{description: "Master updated"}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      version =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: category.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/version/#{version.id}/restore",
          %{"type" => "media_category", "attributes" => %{}},
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["description"] == "Master original"
    end
  end

  describe "VERSION MANAGEMENT - Preview Version" do
    test "tenant can preview media category version without restoring", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      category =
        create_media_category_via_ash(
          %{name: "Category Preview", description: "Preview original"},
          site.id
        )

      category
      |> Ash.Changeset.for_update(:update, %{description: "Preview updated"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      version =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: category.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      # Preview shows the old version data
      assert body["data"]["attributes"]["description"] == "Preview original"

      # Verify original is unchanged
      get_response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      get_body = Jason.decode!(get_response.resp_body)
      assert get_body["data"]["attributes"]["description"] == "Preview updated"
    end

    test "master can preview media category version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      category =
        create_media_category_via_ash(
          %{name: "Master Preview", description: "Master preview original"},
          site2.id
        )

      category
      |> Ash.Changeset.for_update(:update, %{description: "Master preview updated"},
        tenant: site2.id
      )
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      version =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: category.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{category.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["description"] == "Master preview original"
    end
  end

  describe "VERSION MANAGEMENT - Calculations" do
    test "can load version_count calculation", %{tenant_admin: tenant_admin, site: site} do
      category = create_media_category_via_ash(%{name: "Version Count"}, site.id)

      category
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      category
      |> Ash.Changeset.for_update(:update, %{description: "v3"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}?fields[media_category]=name,version_count",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["version_count"] == 3
    end

    test "can load latest_version calculation", %{tenant_admin: tenant_admin, site: site} do
      category = create_media_category_via_ash(%{name: "Latest Version"}, site.id)

      category
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}?fields[media_category]=name,latest_version",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["latest_version"] != nil
    end

    test "can load recent_versions calculation", %{tenant_admin: tenant_admin, site: site} do
      category = create_media_category_via_ash(%{name: "Recent Versions"}, site.id)

      category
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      category
      |> Ash.Changeset.for_update(:update, %{description: "v3"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_category_versions", category.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{category.id}?fields[media_category]=name,recent_versions",
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
      _category = create_media_category_via_ash(%{name: "Auth Test"}, site.id)

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
      _category = create_media_category_via_ash(%{name: "Invalid Token"}, site.id)

      response =
        make_api_request(
          @tenant_path,
          %{},
          method: :get,
          headers: [{"authorization", "Bearer invalid_token"}]
        )

      assert response.status in [401, 403]
    end

    # An unscoped request on a route that works on one site is told so, not "something went wrong".
    test "the tenant route asked unscoped answers tenant_required", %{master_user: master_user} do
      token = sign_in_master(master_user)

      for headers <- [[{"authorization", "Bearer #{token}"}], []] do
        response =
          make_api_request(@tenant_path, %{},
            method: :get,
            headers: [{"x-no-tenant", "true"} | headers]
          )

        assert response.status == 400

        assert [%{"code" => "tenant_required", "title" => "Tenant required", "detail" => detail}] =
                 Jason.decode!(response.resp_body)["errors"]

        assert detail ==
                 "Tenant context is required for this action. Use the master action instead."
      end
    end
  end

  describe "CROSS-TENANT ISOLATION" do
    test "tenant from site1 cannot access site2 media categories", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      category = create_media_category_via_ash(%{name: "Site2 Isolated"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      # Try to get
      get_response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404

      # Try to update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{category.id}",
          %{"type" => "media_category", "attributes" => %{"name" => "Hacked"}},
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
          "#{@tenant_path}/#{category.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert delete_response.status == 404
    end

    test "master can access media categories from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      category_site1 = create_media_category_via_ash(%{name: "Site1 Master"}, site.id)
      category_site2 = create_media_category_via_ash(%{name: "Site2 Master"}, site2.id)

      token = sign_in_master(master_user)

      # Master can list media categories from all sites
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
      # Master sees all sites' media categories
      assert category_site1.id in ids
      assert category_site2.id in ids
    end
  end
end
