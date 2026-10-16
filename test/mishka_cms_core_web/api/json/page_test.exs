# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.PageTest do
  use MishkaCmsCore.ConnCase

  import MishkaCmsCore.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :unit
  @moduletag :capture_log

  require Ash.Query

  alias MishkaCmsCore.Runtime.Page

  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/page"
  @master_path "/api/json/v1/master/admin/runtime/page"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    Application.put_env(:ash_json_api, MishkaCmsCore.Runtime, router: MishkaCmsCore.TestRouter)

    site =
      create_site!(name: "localhost", host: "localhost", active: true, priority: 50, master: true)

    site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 40)

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

    admin_permission = create_permission!(name: "admin:api:*")

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

    site2_admin =
      create_user!(
        email: "admin@site2.com",
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
      site2_admin: site2_admin
    }
  end

  defp create_page_via_ash(attrs, site_id) do
    default_attrs = %{
      name: "Test Page #{System.unique_integer([:positive])}",
      title: "Test Page #{System.unique_integer([:positive])}",
      path: "/test-page-#{System.unique_integer([:positive])}",
      template: "<div>Test Content</div>"
    }

    MishkaCmsCore.Runtime.Page
    |> Ash.Changeset.for_create(:create, Map.merge(default_attrs, attrs), tenant: site_id)
    |> Ash.create!(authorize?: false)
  end

  @refused "This is the original English version. Its Persian translation is still live, so it " <>
             "can't be deleted yet. Archive or delete that translation first, then this one."

  # The refusal as the API returns it: the detail of its one invalid-attribute error.
  defp refusal(response) do
    %{"errors" => errors} = Jason.decode!(response.resp_body)

    Enum.find_value(errors, fn
      %{"code" => "invalid_attribute", "detail" => detail} -> detail
      _other -> nil
    end)
  end

  defp translate_via_ash(page, language) do
    create_page_via_ash(
      %{
        name: "#{page.name} #{language}",
        path: "/#{language}#{page.path}",
        language: language,
        language_group_id: page.id
      },
      page.site_id
    )
  end

  describe "MASTER ADMIN - CREATE" do
    test "master can create page for site1", %{site: site, master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Site1 Home Page",
              "title" => "Site1 Home Page",
              "path" => "/home",
              "template" => "<h1>Welcome</h1>",
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
      assert body["data"]["attributes"]["name"] == "site1-home-page"
      assert body["data"]["attributes"]["path"] == "/home"
    end

    test "master can create page for site2", %{site2: site2, master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Site2 About Page",
              "title" => "Site2 About Page",
              "path" => "/about",
              "template" => "<h1>About Us</h1>",
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
      assert body["data"]["attributes"]["name"] == "site2-about-page"
    end

    test "master create requires site_id", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "No Site Page",
              "title" => "No Site Page",
              "path" => "/no-site",
              "template" => "<div>Content</div>"
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

    test "master create validates required fields", %{site: site, master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Incomplete Page",
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

    test "master create validates path format", %{site: site, master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Invalid Path Page",
              "title" => "Invalid Path Page",
              "path" => "no-leading-slash",
              "template" => "<div>Content</div>",
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
    test "master can list pages from all sites", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      page1 = create_page_via_ash(%{name: "Site1 Page"}, site.id)
      page2 = create_page_via_ash(%{name: "Site2 Page"}, site2.id)

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
      assert page1.id in ids
      assert page2.id in ids
    end

    test "master can get page by id from any site", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "Master Get Test"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == page.id
    end

    test "master get returns 404 for non-existent page", %{master_user: master_user} do
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
    test "master can update page from any site", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "Before Update", description: "old"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}",
          %{
            "type" => "page",
            "attributes" => %{
              "description" => "Updated by master"
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
      assert body["data"]["attributes"]["description"] == "Updated by master"
    end

    test "master update returns 404 for non-existent page", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{
            "type" => "page",
            "attributes" => %{
              "description" => "Should fail"
            }
          },
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
    test "master can archive page from any site", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "To Archive"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
    end

    test "master cannot archive a page while a translation of it exists", %{
      site: site,
      master_user: master_user
    } do
      page = create_page_via_ash(%{name: "Translated Master"}, site.id)
      translate_via_ash(page, "fa")
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 400
      assert refusal(response) == @refused
      assert Ash.get!(Page, page.id, action: :master_get, authorize?: false).archived_at == nil
    end
  end

  describe "MASTER ADMIN - ARCHIVED" do
    test "master can list archived pages from all sites", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      page1 = create_page_via_ash(%{name: "Archived1"}, site.id)
      page2 = create_page_via_ash(%{name: "Archived2"}, site2.id)

      Ash.Changeset.for_destroy(page1, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      Ash.Changeset.for_destroy(page2, :destroy, %{}, tenant: site2.id)
      |> Ash.destroy!(authorize?: false)

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
      assert page1.id in ids
      assert page2.id in ids
    end

    test "master can get archived page by id", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "Get Archived"}, site.id)

      Ash.Changeset.for_destroy(page, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived/#{page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == page.id
    end

    test "master can unarchive page", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "To Unarchive"}, site.id)

      Ash.Changeset.for_destroy(page, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/unarchive",
          %{
            "type" => "page",
            "attributes" => %{}
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
    end

    test "master cannot unarchive a translation while its master is archived", %{
      site: site,
      master_user: master_user
    } do
      page = create_page_via_ash(%{name: "Archived Group"}, site.id)
      fa = translate_via_ash(page, "fa")

      Enum.each([fa, page], fn row ->
        row
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy!(authorize?: false)
      end)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{fa.id}/unarchive",
          %{
            "type" => "page",
            "attributes" => %{}
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 400

      assert refusal(response) ==
               "This is the Persian translation. Its original English version is archived, so " <>
                 "it can't be restored yet. Restore the original first, then this one."

      assert Ash.get!(Page, fa.id, action: :master_get_archived, authorize?: false).archived_at
    end
  end

  describe "MASTER ADMIN - PERMANENT DELETE" do
    test "master can permanently delete page", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "To Delete Permanently"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end

    test "master cannot permanently delete a page while a translation of it exists", %{
      site: site,
      master_user: master_user
    } do
      page = create_page_via_ash(%{name: "Translated For Good"}, site.id)
      translate_via_ash(page, "fa")
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 400
      assert refusal(response) == @refused
      assert {:ok, _still_there} = Ash.get(Page, page.id, action: :master_get, authorize?: false)
    end
  end

  describe "TENANT ADMIN - CREATE" do
    test "tenant can create page for their site", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Tenant Page",
              "title" => "Tenant Page",
              "path" => "/tenant-page",
              "template" => "<h1>Tenant Content</h1>",
              "description" => "A test page"
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
      assert body["data"]["attributes"]["name"] == "tenant-page"
      assert body["data"]["attributes"]["path"] == "/tenant-page"
    end

    test "tenant create validates required fields", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Incomplete Page"
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

    test "tenant create validates path format", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Bad Path Page",
              "title" => "Bad Path Page",
              "path" => "no-slash",
              "template" => "<div>Content</div>"
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

    test "tenant cannot create page with another site_id", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      # Note: The tenant create action doesn't accept site_id parameter
      # (it's force-set from tenant context), so passing it returns 400
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Wrong Site Page",
              "title" => "Wrong Site Page",
              "path" => "/wrong-site",
              "template" => "<div>Content</div>",
              "site_id" => site2.id
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      # site_id is not accepted by tenant create action, so it returns 400
      assert response.status in [400, 422]
    end

    test "tenant token from site1 cannot create on site2 host", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Cross Site Page",
              "title" => "Cross Site Page",
              "path" => "/cross-site",
              "template" => "<div>Content</div>"
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
    test "tenant can list pages from their site only", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      page1 = create_page_via_ash(%{name: "Site1 Page Read"}, site.id)
      page2 = create_page_via_ash(%{name: "Site2 Page Read"}, site2.id)

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
      assert page1.id in ids
      refute page2.id in ids
    end

    test "tenant can get page by id from their site", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Tenant Get Test"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == page.id
    end

    test "tenant cannot get page from another site", %{site2: site2, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Other Site Page"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - UPDATE" do
    test "tenant can update page from their site", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Before Tenant Update"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}",
          %{
            "type" => "page",
            "attributes" => %{
              "description" => "Updated by tenant"
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
      assert body["data"]["attributes"]["description"] == "Updated by tenant"
    end

    test "tenant cannot update page from another site", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Other Site Update"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}",
          %{
            "type" => "page",
            "attributes" => %{
              "description" => "Should fail"
            }
          },
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
    test "tenant can archive page from their site", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Tenant Archive"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot archive a page while a translation of it exists", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Tenant Translated Master"}, site.id)
      translate_via_ash(page, "fa")
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 400
      assert refusal(response) == @refused
      assert Ash.get!(Page, page.id, action: :master_get, authorize?: false).archived_at == nil
    end

    test "tenant cannot archive page from another site", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Other Site Archive"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - ARCHIVED" do
    test "tenant can list archived pages from their site only", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      page1 = create_page_via_ash(%{name: "Site1 Archived"}, site.id)
      page2 = create_page_via_ash(%{name: "Site2 Archived"}, site2.id)

      Ash.Changeset.for_destroy(page1, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      Ash.Changeset.for_destroy(page2, :destroy, %{}, tenant: site2.id)
      |> Ash.destroy!(authorize?: false)

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
      assert page1.id in ids
      refute page2.id in ids
    end

    test "tenant can get archived page by id from their site", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Get Archived Tenant"}, site.id)

      Ash.Changeset.for_destroy(page, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == page.id
    end

    test "tenant can unarchive page from their site", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Tenant Unarchive"}, site.id)

      Ash.Changeset.for_destroy(page, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/unarchive",
          %{
            "type" => "page",
            "attributes" => %{}
          },
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
    test "tenant can permanently delete page from their site", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Tenant Permanent Delete"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot permanently delete page from another site", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Other Site Permanent"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - Get With Versions" do
    test "tenant can get page with versions", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Page With Versions", description: "v1"}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/with-versions?fields[page]=name,description,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
      assert length(sorted_versions) >= 2
    end

    test "master can get page with versions from any site", %{
      site: site,
      master_user: master_user
    } do
      page = create_page_via_ash(%{name: "Master Versions Test", description: "v1"}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/with-versions?fields[page]=name,description,sorted_versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      sorted_versions = body["data"]["attributes"]["sorted_versions"]
      assert is_list(sorted_versions)
    end
  end

  describe "VERSION MANAGEMENT - List Versions" do
    test "tenant can list versions for page", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "List Versions Test", active: false}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])
    end

    test "master can list versions for page from any site", %{
      site: site,
      master_user: master_user
    } do
      page = create_page_via_ash(%{name: "Master List Versions", active: false}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Restore Version" do
    test "tenant can restore page to previous version", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Restore Test", description: "original"}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version =
        MishkaCmsCore.Runtime.Page.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: page.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/version/#{version.id}/restore",
          %{
            "type" => "page",
            "attributes" => %{}
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["description"] == "original"
    end

    test "master can restore page version from any site", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "Master Restore Test", description: "original"}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version =
        MishkaCmsCore.Runtime.Page.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: page.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/version/#{version.id}/restore",
          %{
            "type" => "page",
            "attributes" => %{}
          },
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

  describe "VERSION MANAGEMENT - Preview Version" do
    test "tenant can preview page version without restoring", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      page = create_page_via_ash(%{name: "Preview Test", description: "original"}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version =
        MishkaCmsCore.Runtime.Page.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: page.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200

      reloaded =
        MishkaCmsCore.Runtime.Page
        |> Ash.get!(page.id, tenant: site.id, authorize?: false)

      assert reloaded.description == "modified"
    end

    test "master can preview page version from any site", %{site: site, master_user: master_user} do
      page = create_page_via_ash(%{name: "Master Preview Test", description: "original"}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version =
        MishkaCmsCore.Runtime.Page.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: page.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{page.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Calculations" do
    test "can load version_count calculation", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Version Count Test", active: false}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}?fields[page]=name,version_count",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["version_count"] == 2
    end

    test "can load latest_version calculation", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Latest Version Test", active: false}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}?fields[page]=name,latest_version",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["latest_version"] != nil
    end

    test "can load recent_versions calculation", %{site: site, tenant_admin: tenant_admin} do
      page = create_page_via_ash(%{name: "Recent Versions Test", active: false}, site.id)

      page
      |> Ash.Changeset.for_update(:update, %{active: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}?fields[page]=name,recent_versions",
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
      page = create_page_via_ash(%{name: "Auth Test"}, site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}",
          %{},
          method: :get,
          headers: []
        )

      assert response.status in [401, 403]
    end

    test "invalid token is rejected", %{site: site} do
      page = create_page_via_ash(%{name: "Invalid Token Test"}, site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer invalid_token_here"}]
        )

      assert response.status in [401, 403]
    end
  end

  describe "CROSS-TENANT ISOLATION" do
    test "tenant from site1 cannot access site2 page", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      site1_page = create_page_via_ash(%{name: "Site1 Isolated"}, site.id)
      site2_page = create_page_via_ash(%{name: "Site2 Isolated"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response1 =
        make_api_request(
          "#{@tenant_path}/#{site1_page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response1.status == 200

      response2 =
        make_api_request(
          "#{@tenant_path}/#{site2_page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response2.status == 404
    end

    test "master can access pages from all sites", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      site1_page = create_page_via_ash(%{name: "Site1 Master Access"}, site.id)
      site2_page = create_page_via_ash(%{name: "Site2 Master Access"}, site2.id)

      token = sign_in_master(master_user)

      response1 =
        make_api_request(
          "#{@master_path}/#{site1_page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response1.status == 200

      response2 =
        make_api_request(
          "#{@master_path}/#{site2_page.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response2.status == 200
    end
  end

  defp post_page(token, attributes) do
    make_api_request(
      @tenant_path,
      %{
        "type" => "page",
        "attributes" =>
          Map.merge(
            %{
              "name" => "Area #{System.unique_integer([:positive])}",
              "title" => "Area",
              "path" => "/area-#{System.unique_integer([:positive])}",
              # BLANK, so the page starts from the empty starter: markup typed here is code.
              "template" => ""
            },
            attributes
          )
      },
      method: :post,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/vnd.api+json"}
      ]
    )
  end

  defp list_pages(token),
    do:
      make_api_request(@tenant_path, %{},
        method: :get,
        headers: [{"authorization", "Bearer #{token}"}]
      )

  # THE API HAS ITS OWN NAMES. `admin:api:runtime:page` writes pages over it; `admin:dashboard:runtime:page` is the
  # screens' name and does not reach it; another API area reads the list and writes nothing.
  describe "the page area over the API" do
    test "admin:api:runtime:page writes; admin:dashboard:runtime:page and another area do not", %{
      site: site
    } do
      api = area_token!(site, ["admin:api:runtime:page"])
      dashboard = area_token!(site, ["admin:dashboard:runtime:page"])
      unrelated = area_token!(site, ["admin:api:runtime:layout"])

      assert post_page(api, %{}).status == 201
      assert post_page(dashboard, %{}).status == 403
      assert post_page(unrelated, %{}).status == 403

      assert list_pages(unrelated).status == 200
      assert list_pages(dashboard).status == 403
    end

    test "a template typed over the API is written by the section or by code", %{site: site} do
      area = area_token!(site, ["admin:api:runtime:page"])
      code = area_token!(site, ["admin:api:code"])
      dashboard = area_token!(site, ["admin:dashboard:runtime:page", "admin:dashboard:code"])
      unrelated = area_token!(site, ["admin:api:runtime:layout"])

      assert post_page(code, %{"template" => "<div>typed</div>"}).status == 201
      refute post_page(dashboard, %{"template" => "<div>typed</div>"}).status == 201
      refute post_page(unrelated, %{"template" => "<div>typed</div>"}).status == 201
      assert post_page(area, %{"template" => "<div>typed</div>"}).status == 201
    end
  end

  describe "PAGE-SPECIFIC - Format and Priority" do
    test "can create page with different formats", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      formats = [
        %{"format" => "heex", "name" => "HEEx Page", "path" => "/heex-page"},
        %{"format" => "eex", "name" => "EEx Page", "path" => "/eex-page"},
        %{"format" => "markdown", "name" => "Markdown Page", "path" => "/md-page"}
      ]

      for %{"format" => format, "name" => name, "path" => path} <- formats do
        response =
          make_api_request(
            @tenant_path,
            %{
              "type" => "page",
              "attributes" => %{
                "name" => name,
                "title" => name,
                "path" => path,
                "template" => "<div>Content</div>",
                "format" => format
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
        assert body["data"]["attributes"]["format"] == format
      end
    end

    test "can set priority on page", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Priority Page",
              "title" => "Priority Page",
              "path" => "/priority-page",
              "template" => "<div>Priority content</div>",
              "priority" => 75
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
      assert body["data"]["attributes"]["priority"] == 75
    end

    test "can set SEO tags on page", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "SEO Page",
              "title" => "SEO Page",
              "path" => "/seo-page",
              "template" => "<div>SEO content</div>",
              "seo_tags" => [
                %{
                  "tag" => "meta",
                  "attrs" => %{"name" => "description"},
                  "content" => "Page description"
                }
              ]
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
      seo_tags = body["data"]["attributes"]["seo_tags"]
      assert is_list(seo_tags)
      assert length(seo_tags) == 1
    end

    # THE PAGE SECTION WRITES A PAGE'S ELIXIR. `admin:api:runtime:page` stores a handler over the API;
    # another section is refused, below.
    test "can set events on page", %{site: site} do
      token = area_token!(site, ["admin:api:runtime:page"])

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Events Page",
              "title" => "Events Page",
              "path" => "/events-page",
              "template" => "<div>Events content</div>",
              # THE BODY, NOT THE CLAUSE. The compiler wraps this in
              # `def handle_event(name, params, socket) do … end`, so a whole `def` here becomes a
              # definition inside a definition and the page will not compile. This fixture used to
              # carry one, and nothing noticed until the code check existed.
              "events" => [
                %{"name" => "handle_click", "code" => "{:noreply, socket}"}
              ]
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
      events = body["data"]["attributes"]["events"]
      assert is_list(events)
      assert length(events) == 1
    end

    # THE GATE REACHES THE API, which is the half that matters: the editor can hide a tab, and a
    # bearer token does not care what the editor drew. Same request, another section.
    test "cannot set events as another section", %{site: site} do
      token = area_token!(site, ["admin:api:runtime:layout"])

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "page",
            "attributes" => %{
              "name" => "Refused Events Page",
              "title" => "Refused Events Page",
              "path" => "/refused-events-page",
              "template" => "<div>x</div>",
              "events" => [%{"name" => "handle_click", "code" => "{:noreply, socket}"}]
            }
          },
          method: :post,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      refute response.status == 201
    end
  end
end
