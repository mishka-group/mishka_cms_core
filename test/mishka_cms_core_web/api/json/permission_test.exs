# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Api.Json.PermissionTest do
  use MishkaCmsCore.ConnCase
  import MishkaCmsCore.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  @password "Password123!"
  @api_user_path "/api/json/v1/auth/user"
  @api_permission_master_path "/api/json/v1/master/admin/permissions"
  @api_permission_tenant_path "/api/json/v1/tenant/admin/permissions"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()

    :ok = Swoosh.TestAssertions.set_swoosh_global()

    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsCore.TestRouter)

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

    # Create admin permission
    admin_permission = create_permission!(name: "admin:api:*")

    # Create master user with admin permissions
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

    # Clean up after ALL tests are done
    on_exit(fn ->
      MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
      MishkaCmsCore.Runtime.States.SiteState.clear()
    end)

    # Create tenant user with admin permissions (for their site)
    tenant_user =
      create_user!(
        email: "tenant@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site.id
      )
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [admin_permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    # This context will be available to all tests
    %{
      site: site,
      admin_permission: admin_permission,
      master_user: master_user,
      tenant_user: tenant_user
    }
  end

  describe "GET /master/admin/permissions (index :master_read)" do
    test "successfully returns permissions list for master admin", %{
      master_user: master_user,
      admin_permission: admin_permission
    } do
      # Create additional test permissions
      perm1 =
        create_permission!(name: "admin:dashboard:blog:post", description: "Create blog posts")

      perm2 =
        create_permission!(name: "admin:dashboard:blog:comment", description: "Edit blog posts")

      perm3 = create_permission!(name: "pages:view", description: "View pages")

      # Sign in as master admin
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get permissions list
      response =
        make_api_request(
          @api_permission_master_path,
          nil,
          method: "GET",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)

      assert %{
               "data" => permissions,
               "jsonapi" => %{"version" => "1.0"}
             } = result

      # Should return all permissions (admin_permission + 3 new ones)
      assert length(permissions) >= 4

      # Verify the response includes all created permissions
      permission_names = Enum.map(permissions, fn perm -> perm["attributes"]["name"] end)
      assert admin_permission.name in permission_names
      assert perm1.name in permission_names
      assert perm2.name in permission_names
      assert perm3.name in permission_names
    end

    test "returns proper JSON:API structure with all default fields", %{
      master_user: master_user
    } do
      # Sign in as master admin
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get permissions list
      response =
        make_api_request(
          @api_permission_master_path,
          nil,
          method: "GET",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)

      # Verify JSON:API structure
      assert %{
               "data" => data,
               "jsonapi" => %{"version" => "1.0"}
             } = result

      assert is_list(data)

      # Check first permission has proper structure with default fields
      if length(data) > 0 do
        [first_permission | _] = data

        assert %{
                 "type" => "permission",
                 "id" => id,
                 "attributes" => attributes
               } = first_permission

        # Verify id is at top level and is a UUID
        assert {:ok, _uuid} = Ecto.UUID.cast(id)

        # Verify expected attributes
        assert Map.has_key?(attributes, "name")
        assert is_binary(attributes["name"])
      end
    end

    test "supports pagination with limit and offset", %{master_user: master_user} do
      # Create multiple permissions
      for i <- 1..15 do
        create_permission!(name: "test:perm:#{i}", description: "Test permission #{i}")
      end

      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get first page with limit 5
      response =
        make_api_request(
          "#{@api_permission_master_path}?page[limit]=5&page[offset]=0",
          nil,
          method: "GET",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)
      assert %{"data" => data} = result
      assert length(data) == 5
    end
  end

  describe "POST /master/admin/permissions (create)" do
    test "successfully creates a new permission", %{master_user: master_user} do
      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Create new permission
      response =
        make_api_request(
          @api_permission_master_path,
          %{
            "type" => "permission",
            "attributes" => %{
              "name" => "content:delete",
              "description" => "Delete content items"
            }
          },
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 201
      result = Jason.decode!(response.resp_body)

      assert %{
               "data" => %{
                 "type" => "permission",
                 "id" => id,
                 "attributes" => %{
                   "name" => "content:delete",
                   "description" => "Delete content items"
                 }
               }
             } = result

      assert {:ok, _uuid} = Ecto.UUID.cast(id)
    end

    test "fails to create permission with duplicate name", %{master_user: master_user} do
      existing_perm = create_permission!(name: "duplicate:test")

      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to create permission with same name
      response =
        make_api_request(
          @api_permission_master_path,
          %{
            "type" => "permission",
            "attributes" => %{
              "name" => existing_perm.name,
              "description" => "Duplicate name"
            }
          },
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 400
    end
  end

  describe "GET /master/admin/permissions/:id (master_get)" do
    test "successfully retrieves a single permission", %{master_user: master_user} do
      permission = create_permission!(name: "test:read:single", description: "Test single read")

      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get single permission
      response =
        make_api_request(
          "#{@api_permission_master_path}/#{permission.id}",
          nil,
          method: "GET",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)

      assert %{
               "data" => %{
                 "type" => "permission",
                 "id" => id,
                 "attributes" => %{
                   "name" => "test:read:single",
                   "description" => "Test single read"
                 }
               }
             } = result

      assert id == permission.id
    end

    test "returns 404 for non-existent permission", %{master_user: master_user} do
      non_existent_id = Ash.UUID.generate()

      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to get non-existent permission
      response =
        make_api_request(
          "#{@api_permission_master_path}/#{non_existent_id}",
          nil,
          method: "GET",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 404
    end
  end

  describe "PATCH /master/admin/permissions/:id (update)" do
    test "successfully updates a permission", %{master_user: master_user} do
      permission = create_permission!(name: "test:update", description: "Original description")

      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Update permission
      response =
        make_api_request(
          "#{@api_permission_master_path}/#{permission.id}",
          %{
            "type" => "permission",
            "attributes" => %{
              "description" => "Updated description"
            }
          },
          method: "PATCH",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)

      assert %{
               "data" => %{
                 "attributes" => %{
                   "name" => "test:update",
                   "description" => "Updated description"
                 }
               }
             } = result
    end
  end

  describe "DELETE /master/admin/permissions/:id (destroy)" do
    test "successfully deletes a permission within what the master holds", %{
      master_user: master_user
    } do
      permission = create_permission!(name: "admin:api:test_delete", description: "To be deleted")

      # Sign in
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
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Delete permission
      response =
        make_api_request(
          "#{@api_permission_master_path}/#{permission.id}",
          nil,
          method: "DELETE",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status in [200, 204]

      # Verify permission is deleted
      get_response =
        make_api_request(
          "#{@api_permission_master_path}/#{permission.id}",
          nil,
          method: "GET",
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert get_response.status == 404
    end
  end

  # ============================================================================
  # TENANT ENDPOINT TESTS
  # ============================================================================

  describe "GET /tenant/admin/permissions (index :tenant_read)" do
    test "tenant user can read permissions list", %{
      tenant_user: tenant_user,
      admin_permission: admin_permission
    } do
      # Create additional test permissions
      perm1 = create_permission!(name: "tenant:test:perm1", description: "Test permission 1")

      # Sign in as tenant user - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get permissions list via tenant endpoint - just authorization header
      response =
        make_api_request(
          @api_permission_tenant_path,
          nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)

      assert %{
               "data" => permissions,
               "jsonapi" => %{"version" => "1.0"}
             } = result

      # Should return all permissions
      assert length(permissions) >= 2

      # Verify the response includes created permissions
      permission_names = Enum.map(permissions, fn perm -> perm["attributes"]["name"] end)
      assert admin_permission.name in permission_names
      assert perm1.name in permission_names
    end

    test "tenant endpoint supports pagination", %{tenant_user: tenant_user} do
      # Create multiple permissions
      for i <- 1..10 do
        create_permission!(name: "tenant:paginate:#{i}", description: "Paginate test #{i}")
      end

      # Sign in as tenant - NO special headers
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get first page with limit 5
      response =
        make_api_request(
          "#{@api_permission_tenant_path}?page[limit]=5&page[offset]=0",
          nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)
      assert %{"data" => data} = result
      assert length(data) == 5
    end
  end

  describe "GET /tenant/admin/permissions/:id (tenant_get)" do
    test "tenant user can get a single permission", %{tenant_user: tenant_user} do
      permission = create_permission!(name: "tenant:single:read", description: "Single read test")

      # Sign in as tenant - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Get single permission - just authorization header
      response =
        make_api_request(
          "#{@api_permission_tenant_path}/#{permission.id}",
          nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      result = Jason.decode!(response.resp_body)

      assert %{
               "data" => %{
                 "type" => "permission",
                 "id" => id,
                 "attributes" => %{
                   "name" => "tenant:single:read",
                   "description" => "Single read test"
                 }
               }
             } = result

      assert id == permission.id
    end

    test "tenant user gets 404 for non-existent permission", %{tenant_user: tenant_user} do
      non_existent_id = Ash.UUID.generate()

      # Sign in as tenant - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to get non-existent permission - just authorization header
      response =
        make_api_request(
          "#{@api_permission_tenant_path}/#{non_existent_id}",
          nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "Tenant users cannot perform write operations" do
    test "tenant user cannot create permissions (no route exists)", %{
      tenant_user: tenant_user
    } do
      # Sign in as tenant - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to create permission via tenant path (should fail - no route)
      response =
        make_api_request(
          @api_permission_tenant_path,
          %{
            "type" => "permission",
            "attributes" => %{
              "name" => "tenant:cannot:create",
              "description" => "Should not be created"
            }
          },
          headers: [{"authorization", "Bearer #{token}"}]
        )

      # Should return 404 (no route) or 405 (method not allowed)
      assert response.status in [404, 405]
    end

    test "tenant user cannot create permissions via master path", %{
      tenant_user: tenant_user
    } do
      # Sign in as tenant - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to create permission via master path (should fail - not a master user)
      response =
        make_api_request(
          @api_permission_master_path,
          %{
            "type" => "permission",
            "attributes" => %{
              "name" => "tenant:cannot:create:master",
              "description" => "Should not be created"
            }
          },
          headers: [{"authorization", "Bearer #{token}"}]
        )

      # Should be forbidden (403) or bad request (400)
      assert response.status in [400, 403]
    end

    test "tenant user cannot update permissions via master path", %{
      tenant_user: tenant_user
    } do
      permission = create_permission!(name: "tenant:cannot:update", description: "Original")

      # Sign in as tenant - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to update permission via master path
      response =
        make_api_request(
          "#{@api_permission_master_path}/#{permission.id}",
          %{
            "type" => "permission",
            "attributes" => %{
              "description" => "Updated by tenant - should fail"
            }
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      # Should be forbidden
      assert response.status in [400, 403]
    end

    test "tenant user cannot delete permissions via master path", %{
      tenant_user: tenant_user
    } do
      permission =
        create_permission!(name: "tenant:cannot:delete", description: "Should not delete")

      # Sign in as tenant - NO special headers needed
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

      # Try to delete permission via master path
      response =
        make_api_request(
          "#{@api_permission_master_path}/#{permission.id}",
          nil,
          method: "DELETE",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      # TenantContext validation with require_master: true blocks tenant users
      # Should return 400 (validation error) or 403 (forbidden)
      assert response.status in [400, 403]

      # Verify the permission still exists (was not deleted)
      get_response =
        make_api_request(
          "#{@api_permission_tenant_path}/#{permission.id}",
          nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert get_response.status == 200
    end
  end
end
