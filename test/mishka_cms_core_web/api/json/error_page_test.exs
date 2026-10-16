# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.ErrorPageTest do
  @moduledoc """
  Comprehensive JSON API tests for ErrorPage resource.

  ErrorPage is site-specific (global? false) - no global error pages.
  Tests cover master and tenant CRUD operations, version management, and access control.
  """
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.ErrorAddress
  import MishkaCmsCore.Test.VersionHelpers
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :unit
  @moduletag :capture_log

  require Ash.Query

  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/error-page"
  @master_path "/api/json/v1/master/admin/runtime/error-page"

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

  defp create_error_page_via_ash(attrs, site_id) do
    MishkaCmsCore.Runtime.ErrorPage
    |> Ash.Changeset.for_create(:create, attrs, tenant: site_id)
    |> Ash.create!(authorize?: false)
  end

  defp sample_error_pages do
    [
      %{
        "status" => 404,
        "template" => "<h1>Not Found</h1>",
        "layout" => %{"template" => "<div><%= @inner_content %></div>"}
      },
      %{
        "status" => 500,
        "template" => "<h1>Server Error</h1>"
      }
    ]
  end

  describe "MASTER ADMIN - CREATE" do
    test "master can create error page for site1", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Site1 Error Pages",
              "path" => "/errors/*",
              "error_pages" => sample_error_pages(),
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
      assert body["data"]["attributes"]["name"] == "site1-error-pages"

      # THE PATH IS THE SITE'S, WHATEVER WAS POSTED. The JSON:API goes through the same create
      # action as the admin, and `Changes.ErrorPageAddress` writes the address there —
      # see `MishkaCmsCore.Runtime.ErrorAddress`.
      assert body["data"]["attributes"]["path"] == ErrorAddress.for_site(site.id)
      assert body["data"]["attributes"]["site_id"] == site.id
      assert length(body["data"]["attributes"]["error_pages"]) == 2
    end

    test "master can create error page for site2", %{master_user: master_user, site2: site2} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Site2 Error Pages",
              "path" => "/error",
              "error_pages" => [%{"status" => 403, "template" => "<h1>Forbidden</h1>"}],
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
            "type" => "error_page",
            "attributes" => %{
              "name" => "Missing Site",
              "path" => "/errors",
              "error_pages" => sample_error_pages()
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

    # A PATH IS NOT SOMETHING THIS ENDPOINT CAN GET WRONG ANY MORE: it is written from the site
    # rather than validated, so a posted one is ignored rather than refused.
    test "master create ignores the path it is posted", %{master_user: master_user, site: site} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Invalid Path",
              "path" => "no-slash",
              "error_pages" => sample_error_pages(),
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
      assert body["data"]["attributes"]["path"] == ErrorAddress.for_site(site.id)
    end
  end

  describe "MASTER ADMIN - READ" do
    test "master can list error pages from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      # Create error pages in both sites
      ep1 = create_error_page_via_ash(%{name: "EP Site1", path: "/e1", error_pages: []}, site.id)
      ep2 = create_error_page_via_ash(%{name: "EP Site2", path: "/e2", error_pages: []}, site2.id)

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
      assert ep1.id in ids
      assert ep2.id in ids
    end

    test "master can get error page by id from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(%{name: "EP Get Test", path: "/get", error_pages: []}, site2.id)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == ep.id
      assert body["data"]["attributes"]["name"] == "ep-get-test"
    end

    test "master get returns 404 for non-existent error page", %{master_user: master_user} do
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
    test "master can update error page from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Update Test", path: "/update", error_pages: []},
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}",
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Updated EP Name",
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
      assert body["data"]["attributes"]["name"] == "updated-ep-name"
      assert body["data"]["attributes"]["priority"] == 80
    end

    test "master update returns 404 for non-existent error page", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{"type" => "error_page", "attributes" => %{"name" => "Not Found"}},
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
    test "master can archive error page from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Archive Test", path: "/archive", error_pages: []},
          site2.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
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
      assert ep.id in ids
    end
  end

  describe "MASTER ADMIN - ARCHIVED" do
    test "master can list archived error pages from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      ep1 =
        create_error_page_via_ash(
          %{name: "EP Archived 1", path: "/arch1", error_pages: []},
          site.id
        )

      ep2 =
        create_error_page_via_ash(
          %{name: "EP Archived 2", path: "/arch2", error_pages: []},
          site2.id
        )

      # Archive both
      Ash.destroy!(ep1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(ep2, action: :destroy, tenant: site2.id, authorize?: false)

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
      assert ep1.id in ids
      assert ep2.id in ids
    end

    test "master can get archived error page by id", %{master_user: master_user, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP Archived Get", path: "/archget", error_pages: []},
          site.id
        )

      Ash.destroy!(ep, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == ep.id
    end

    test "master can unarchive error page", %{master_user: master_user, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP Unarchive", path: "/unarch", error_pages: []},
          site.id
        )

      Ash.destroy!(ep, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/unarchive",
          %{"type" => "error_page", "attributes" => %{}},
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
          "#{@master_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 200
    end
  end

  describe "MASTER ADMIN - PERMANENT DELETE" do
    test "master can permanently delete error page", %{master_user: master_user, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP Permanent Delete", path: "/perm", error_pages: []},
          site.id
        )

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@master_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert get_response.status == 404
    end
  end

  describe "TENANT ADMIN - CREATE" do
    test "tenant can create error page for their site", %{tenant_admin: tenant_admin, site: site} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Tenant Error Pages",
              "path" => "/tenant-errors",
              "error_pages" => sample_error_pages(),
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
      assert body["data"]["attributes"]["name"] == "tenant-error-pages"
      assert body["data"]["attributes"]["site_id"] == site.id
    end

    # Same for a tenant, whose site comes from the token rather than the body.
    test "tenant create ignores the path it is posted", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Invalid Path EP",
              "path" => "missing-slash",
              "error_pages" => []
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
      assert body["data"]["attributes"]["path"] == ErrorAddress.for_site(tenant_admin.site_id)
    end

    test "tenant cannot create error page with another site_id", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Trying Other Site",
              "path" => "/other-site",
              "error_pages" => sample_error_pages(),
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
            "type" => "error_page",
            "attributes" => %{
              "name" => "Cross Site Create",
              "path" => "/cross-site",
              "error_pages" => sample_error_pages()
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
    test "tenant can list error pages from their site only", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      ep1 =
        create_error_page_via_ash(
          %{name: "EP Tenant Read 1", path: "/tread1", error_pages: []},
          site.id
        )

      ep2 =
        create_error_page_via_ash(
          %{name: "EP Site2 Read", path: "/s2read", error_pages: []},
          site2.id
        )

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
      assert ep1.id in ids
      refute ep2.id in ids
    end

    test "tenant can get error page by id from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Tenant Get", path: "/tget", error_pages: []},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == ep.id
    end

    test "tenant cannot get error page from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Other Site", path: "/other", error_pages: []},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - UPDATE" do
    test "tenant can update error page from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Tenant Update", path: "/tupdate", error_pages: []},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{
            "type" => "error_page",
            "attributes" => %{
              "name" => "Updated Tenant EP",
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
      assert body["data"]["attributes"]["name"] == "updated-tenant-ep"
      assert body["data"]["attributes"]["active"] == false
    end

    test "tenant cannot update error page from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Other Update", path: "/oupdate", error_pages: []},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{"type" => "error_page", "attributes" => %{"name" => "Should Fail"}},
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
    test "tenant can archive error page from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Tenant Archive", path: "/tarchive", error_pages: []},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot archive error page from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Other Archive", path: "/oarchive", error_pages: []},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - ARCHIVED" do
    test "tenant can list archived error pages from their site only", %{
      tenant_admin: tenant_admin,
      site: site,
      site2: site2
    } do
      ep1 =
        create_error_page_via_ash(
          %{name: "EP Tenant Arch List 1", path: "/tal1", error_pages: []},
          site.id
        )

      ep2 =
        create_error_page_via_ash(
          %{name: "EP Other Arch List", path: "/oal", error_pages: []},
          site2.id
        )

      Ash.destroy!(ep1, action: :destroy, tenant: site.id, authorize?: false)
      Ash.destroy!(ep2, action: :destroy, tenant: site2.id, authorize?: false)

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
      assert ep1.id in ids
      refute ep2.id in ids
    end

    test "tenant can get archived error page by id from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Tenant Arch Get", path: "/tag", error_pages: []},
          site.id
        )

      Ash.destroy!(ep, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == ep.id
    end

    test "tenant can unarchive error page from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Tenant Unarch", path: "/tunarch", error_pages: []},
          site.id
        )

      Ash.destroy!(ep, action: :destroy, tenant: site.id, authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/unarchive",
          %{"type" => "error_page", "attributes" => %{}},
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
    test "tenant can permanently delete error page from their site", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Tenant Perm Delete", path: "/tperm", error_pages: []},
          site.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200

      # Verify it's gone
      get_response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404
    end

    test "tenant cannot permanently delete error page from another site", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Other Perm Delete", path: "/operm", error_pages: []},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - Get With Versions" do
    test "tenant can get error page with versions", %{tenant_admin: tenant_admin, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP With Versions", path: "/wv", error_pages: []},
          site.id
        )

      # Update to create version
      ep
      |> Ash.Changeset.for_update(:update, %{priority: 75}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/with-versions?fields[error_page]=name,priority,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == ep.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end

    test "master can get error page with versions from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Master With Versions", path: "/mwv", error_pages: []},
          site2.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 60}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/with-versions?fields[error_page]=name,priority,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == ep.id
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) == 2
    end
  end

  describe "VERSION MANAGEMENT - List Versions" do
    test "tenant can list versions for error page", %{tenant_admin: tenant_admin, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP List Versions", path: "/lv", error_pages: []},
          site.id
        )

      # Create 2 more versions
      ep
      |> Ash.Changeset.for_update(:update, %{priority: 30}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 40}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])
      # The response is the error page with sorted_versions loaded
    end

    test "master can list versions for error page from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Master List Versions", path: "/mlv", error_pages: []},
          site2.id
        )

      wait_for_version_count("error_versions", ep.id, 1)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Restore Version" do
    test "tenant can restore error page to previous version", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Restore", path: "/restore", priority: 10, error_pages: []},
          site.id
        )

      # Update to create a new version
      ep
      |> Ash.Changeset.for_update(:update, %{priority: 90}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      # Get the first (original) version
      version =
        MishkaCmsCore.Runtime.ErrorPage.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: ep.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/version/#{version.id}/restore",
          %{"type" => "error_page", "attributes" => %{}},
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

    test "master can restore error page version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Master Restore", path: "/mrestore", priority: 20, error_pages: []},
          site2.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 80}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      version =
        MishkaCmsCore.Runtime.ErrorPage.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: ep.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/version/#{version.id}/restore",
          %{"type" => "error_page", "attributes" => %{}},
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
    test "tenant can preview error page version without restoring", %{
      tenant_admin: tenant_admin,
      site: site
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Preview", path: "/preview", priority: 15, error_pages: []},
          site.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 95}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      version =
        MishkaCmsCore.Runtime.ErrorPage.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: ep.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}/version/#{version.id}/preview",
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
          "#{@tenant_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      get_body = Jason.decode!(get_response.resp_body)
      assert get_body["data"]["attributes"]["priority"] == 95
    end

    test "master can preview error page version from any site", %{
      master_user: master_user,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Master Preview", path: "/mpreview", priority: 25, error_pages: []},
          site2.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 85}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      version =
        MishkaCmsCore.Runtime.ErrorPage.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: ep.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{ep.id}/version/#{version.id}/preview",
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
      ep =
        create_error_page_via_ash(
          %{name: "EP Version Count", path: "/vcount", error_pages: []},
          site.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 50}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 60}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}?fields[error_page]=name,version_count",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["version_count"] == 3
    end

    test "can load latest_version calculation", %{tenant_admin: tenant_admin, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP Latest Version", path: "/latest", error_pages: []},
          site.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 70}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}?fields[error_page]=name,latest_version",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["latest_version"] != nil
    end

    test "can load recent_versions calculation", %{tenant_admin: tenant_admin, site: site} do
      ep =
        create_error_page_via_ash(
          %{name: "EP Recent Versions", path: "/recent", error_pages: []},
          site.id
        )

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 35}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      ep
      |> Ash.Changeset.for_update(:update, %{priority: 45}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("error_versions", ep.id, 3)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}?fields[error_page]=name,recent_versions",
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
      _ep =
        create_error_page_via_ash(
          %{name: "EP Auth Test", path: "/auth", error_pages: []},
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
      _ep =
        create_error_page_via_ash(
          %{name: "EP Invalid Token", path: "/invalid", error_pages: []},
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
    test "tenant from site1 cannot access site2 error pages", %{
      tenant_admin: tenant_admin,
      site2: site2
    } do
      ep =
        create_error_page_via_ash(
          %{name: "EP Site2 Isolation", path: "/isolated", error_pages: []},
          site2.id
        )

      token = sign_in_tenant(tenant_admin)

      # Try to get
      get_response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 404

      # Try to update
      update_response =
        make_api_request(
          "#{@tenant_path}/#{ep.id}",
          %{"type" => "error_page", "attributes" => %{"name" => "Hacked"}},
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
          "#{@tenant_path}/#{ep.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert delete_response.status == 404
    end

    test "master can access error pages from all sites", %{
      master_user: master_user,
      site: site,
      site2: site2
    } do
      ep_site1 =
        create_error_page_via_ash(
          %{name: "EP Site1 Master", path: "/s1m", error_pages: []},
          site.id
        )

      ep_site2 =
        create_error_page_via_ash(
          %{name: "EP Site2 Master", path: "/s2m", error_pages: []},
          site2.id
        )

      token = sign_in_master(master_user)

      # Master can list error pages from all sites
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
      # Master sees both sites' error pages
      assert ep_site1.id in ids
      assert ep_site2.id in ids
    end
  end

  # THE API HAS ITS OWN NAMES. `admin:api:runtime:error_page` writes over it; `admin:dashboard:runtime:error_page` is
  # the screens' name and does not reach it; another API area reads the list and writes nothing.
  describe "the error_page area over the API" do
    alias MishkaCmsCoreWeb.Test.AreaApi

    test "admin:api:runtime:error_page writes; admin:dashboard:runtime:error_page and another area do not",
         %{
           site: site
         } do
      api = area_token!(site, ["admin:api:runtime:error_page"])
      dashboard = area_token!(site, ["admin:dashboard:runtime:error_page"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])
      attrs = %{"name" => AreaApi.unique("errors"), "path" => "/errors/*"}

      assert area_post(site, dashboard, attrs).status == 403
      assert area_post(site, unrelated, attrs).status == 403
      assert area_post(site, api, attrs).status == 201

      assert area_list(site, unrelated).status == 200
      assert area_list(site, dashboard).status == 403
    end

    # A SITE HOLDS ONE ERROR PAGE, so each writer below writes on its own test's site.
    test "a status template typed over the API is written by the section", %{site: site} do
      area = area_token!(site, ["admin:api:runtime:error_page"])

      assert area_post(site, area, typed_error_page()).status == 201
    end

    test "a status template typed over the API is written by code, and by no other section", %{
      site: site
    } do
      code = area_token!(site, ["admin:api:code"])
      unrelated = area_token!(site, ["admin:api:runtime:media"])

      refute area_post(site, unrelated, typed_error_page()).status == 201
      assert area_post(site, code, typed_error_page()).status == 201
    end
  end

  defp typed_error_page do
    %{
      "name" => MishkaCmsCoreWeb.Test.AreaApi.unique("errors"),
      "path" => "/errors/*",
      "error_pages" => [%{"status" => 404, "template" => "<p>typed</p>"}]
    }
  end

  defp area_post(site, token, attrs) do
    make_api_request(@tenant_path, %{"type" => "error_page", "attributes" => attrs},
      method: :post,
      host: site.host,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/vnd.api+json"}
      ]
    )
  end

  defp area_list(site, token),
    do:
      make_api_request(@tenant_path, %{},
        method: :get,
        host: site.host,
        headers: [{"authorization", "Bearer #{token}"}]
      )
end
