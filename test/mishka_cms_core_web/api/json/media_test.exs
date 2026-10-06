defmodule MishkaCmsCoreWeb.Api.Json.MediaTest do
  use MishkaCmsCore.ConnCase

  import MishkaCmsCore.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers
  import MishkaCmsCoreWeb.Test.AuthTestHelpers

  @moduletag :unit
  @moduletag :capture_log

  require Ash.Query
  @password "Password123!"
  @tenant_path "/api/json/v1/tenant/admin/runtime/media"
  @master_path "/api/json/v1/master/admin/runtime/media"

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

  # The path goes in as the private `stored_path`, the way an upload hands it over: no create takes
  # it as input.
  defp create_media_via_ash(attrs, site_id) do
    default_attrs = %{
      name: "Test Media #{System.unique_integer([:positive])}",
      type: :images,
      size: 1024,
      format: "png"
    }

    MishkaCmsCore.Runtime.Media
    |> Ash.Changeset.for_create(:create, Map.merge(default_attrs, attrs),
      tenant: site_id,
      private_arguments: %{
        stored_path: "/uploads/images/test-#{System.unique_integer([:positive])}.png"
      }
    )
    |> Ash.create!(authorize?: false)
  end

  # Each error of the response as `{pointer, code}` — what was refused, and why. An input the action
  # does not take at all comes back without a pointer.
  defp refusals(response) do
    response.resp_body
    |> Jason.decode!()
    |> Map.fetch!("errors")
    |> Enum.map(&{get_in(&1, ["source", "pointer"]), &1["code"]})
  end

  defp media_named?(name) do
    MishkaCmsCore.Runtime.Media
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(page: [limit: 1])
    |> Map.fetch!(:results)
    |> Enum.any?()
  end

  # WHERE A MEDIA FILE LIVES IS THE SERVER'S TO SAY. A row is made by an upload, which stores the
  # file and hands its path to the create privately; the JSON:API create takes no path at all, so a
  # POST naming one is refused, and a POST without one has no file to make a row for.
  describe "MASTER ADMIN - CREATE" do
    test "a master's create naming where the file is is refused", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media",
            "attributes" => %{
              "name" => "Site1 Image",
              "type" => "images",
              "size" => 2048,
              "format" => "jpg",
              "relative_path" => "/uploads/#{site2.id}/media/uncategorized/theirs.jpg",
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

      assert response.status == 400

      assert {"/data/attributes/relative_path", "invalid_body"} in refusals(response),
             inspect(refusals(response))

      refute media_named?("site1-image")
    end

    test "a master's create without a file makes no row", %{
      site2: site2,
      master_user: master_user
    } do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media",
            "attributes" => %{
              "name" => "Site2 Video",
              "type" => "videos",
              "size" => 10_000_000,
              "format" => "mp4",
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

      assert response.status == 400
      refute media_named?("site2-video")
    end

    test "master create requires site_id", %{master_user: master_user} do
      token = sign_in_master(master_user)

      response =
        make_api_request(
          @master_path,
          %{
            "type" => "media",
            "attributes" => %{
              "name" => "No Site Media",
              "type" => "documents",
              "size" => 512,
              "format" => "pdf"
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
            "type" => "media",
            "attributes" => %{
              "name" => "Incomplete Media",
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
    test "master can list media from all sites", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      media1 = create_media_via_ash(%{name: "Site1 Media"}, site.id)
      media2 = create_media_via_ash(%{name: "Site2 Media"}, site2.id)

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
      assert media1.id in ids
      assert media2.id in ids
    end

    test "master can get media by id from any site", %{site: site, master_user: master_user} do
      media = create_media_via_ash(%{name: "Master Get Test"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == media.id
    end

    test "master get returns 404 for non-existent media", %{master_user: master_user} do
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
    test "master can update media from any site", %{site: site, master_user: master_user} do
      media = create_media_via_ash(%{name: "Before Update", description: "old"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}",
          %{
            "type" => "media",
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

    test "master update returns 404 for non-existent media", %{master_user: master_user} do
      token = sign_in_master(master_user)
      fake_id = Ash.UUIDv7.generate()

      response =
        make_api_request(
          "#{@master_path}/#{fake_id}",
          %{
            "type" => "media",
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
    test "master can archive media from any site", %{site: site, master_user: master_user} do
      media = create_media_via_ash(%{name: "To Archive"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/archive",
          %{},
          method: :delete,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-no-tenant", "true"}
          ]
        )

      assert response.status == 200
    end
  end

  describe "MASTER ADMIN - ARCHIVED" do
    test "master can list archived media from all sites", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      media1 = create_media_via_ash(%{name: "Archived1"}, site.id)
      media2 = create_media_via_ash(%{name: "Archived2"}, site2.id)

      Ash.Changeset.for_destroy(media1, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      Ash.Changeset.for_destroy(media2, :destroy, %{}, tenant: site2.id)
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
      assert media1.id in ids
      assert media2.id in ids
    end

    test "master can get archived media by id", %{site: site, master_user: master_user} do
      media = create_media_via_ash(%{name: "Get Archived"}, site.id)

      Ash.Changeset.for_destroy(media, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/archived/#{media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == media.id
    end

    test "master can unarchive media", %{site: site, master_user: master_user} do
      media = create_media_via_ash(%{name: "To Unarchive"}, site.id)

      Ash.Changeset.for_destroy(media, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/unarchive",
          %{
            "type" => "media",
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

  describe "MASTER ADMIN - PERMANENT DELETE" do
    test "master can permanently delete media", %{site: site, master_user: master_user} do
      media = create_media_via_ash(%{name: "To Delete Permanently"}, site.id)
      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "TENANT ADMIN - CREATE" do
    test "a site admin's create naming where the file is is refused", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      token = sign_in_tenant(tenant_admin)
      own = create_media_via_ash(%{name: "Own Picture"}, site.id)

      # Another site's file, and the admin's own under a second spelling of its path — named as the
      # attribute, or as the private argument the server hands it over in.
      for path <- [
            "/uploads/#{site2.id}/media/uncategorized/theirs.png",
            String.replace(own.relative_path, "/uploads/", "/uploads/./")
          ],
          {attribute, refusal} <- [
            {"relative_path", {"/data/attributes/relative_path", "invalid_body"}},
            {"stored_path", {nil, "no_such_input"}}
          ] do
        response =
          make_api_request(
            @tenant_path,
            %{
              "type" => "media",
              "attributes" => %{
                "name" => "Tenant Media",
                "type" => "images",
                "size" => 4096,
                "format" => "png",
                attribute => path,
                "description" => "A test image"
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status in [400, 422], "#{path} was accepted as #{attribute}"

        assert refusal in refusals(response),
               "#{attribute}: #{inspect(refusals(response))}"

        refute media_named?("tenant-media")
      end
    end

    test "tenant create validates required fields", %{tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          @tenant_path,
          %{
            "type" => "media",
            "attributes" => %{
              "name" => "Incomplete Media"
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

    test "tenant cannot create media with another site_id", %{
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
            "type" => "media",
            "attributes" => %{
              "name" => "Wrong Site Media",
              "type" => "documents",
              "size" => 1024,
              "format" => "pdf",
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

    # A create names no file, so it cannot succeed on any host; the token is tried on a write that
    # can — site2's own row, edited on site2's host.
    test "tenant token from site1 cannot write on site2 host", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Cross Site Media"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
            "attributes" => %{"description" => "Written from site1"}
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ],
          host: site2.host
        )

      assert response.status in [401, 403]

      assert MishkaCmsCore.Runtime.Media
             |> Ash.get!(media.id, tenant: site2.id, authorize?: false)
             |> Map.fetch!(:description) == media.description
    end
  end

  describe "TENANT ADMIN - READ" do
    test "tenant can list media from their site only", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media1 = create_media_via_ash(%{name: "Site1 Media Read"}, site.id)
      media2 = create_media_via_ash(%{name: "Site2 Media Read"}, site2.id)

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
      assert media1.id in ids
      refute media2.id in ids
    end

    test "tenant can get media by id from their site", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Tenant Get Test"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == media.id
    end

    test "tenant cannot get media from another site", %{site2: site2, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Other Site Media"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - UPDATE" do
    test "tenant can update media from their site", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Before Tenant Update"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
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

    # Every file operation of the row — archive, restore, replace, delete for good — acts on the file
    # `relative_path` names, so an update may not repoint it at another site's file.
    test "tenant cannot point media at another site's file", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Pointed Elsewhere"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
            "attributes" => %{
              "relative_path" => "/uploads/#{site2.id}/media/uncategorized/theirs.png"
            }
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 400

      assert MishkaCmsCore.Runtime.Media
             |> Ash.get!(media.id, tenant: site.id, authorize?: false)
             |> Map.fetch!(:relative_path) == media.relative_path
    end

    # `media_files` is the form's upload argument, and the file its `path` names is copied into the
    # site's folder and then deleted — so a PATCH naming another site's file there is refused, and
    # that file, and the row's own, are left as they were.
    test "tenant cannot hand in another site's file as an upload", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      dir = Path.join(System.tmp_dir!(), "json_media_#{System.unique_integer([:positive])}")
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf(dir)
      end)

      theirs = Path.join([dir, "uploads", site2.id, "media", "uncategorized", "theirs.png"])
      File.mkdir_p!(Path.dirname(theirs))
      File.write!(theirs, "their bytes")

      media = create_media_via_ash(%{name: "Handed Their File"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
            "attributes" => %{
              "media_files" => [%{"path" => theirs, "client_name" => "x.png"}]
            }
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 400

      assert {"/data/attributes/media_files", "invalid_attribute"} in refusals(response),
             inspect(refusals(response))

      assert File.read!(theirs) == "their bytes"
      refute File.exists?(Path.join([dir, "uploads", site.id]))

      assert MishkaCmsCore.Runtime.Media
             |> Ash.get!(media.id, tenant: site.id, authorize?: false)
             |> Map.fetch!(:relative_path) == media.relative_path
    end

    test "tenant cannot update media from another site", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Other Site Update"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
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
    test "tenant can archive media from their site", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Tenant Archive"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot archive media from another site", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Other Site Archive"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/archive",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "TENANT ADMIN - ARCHIVED" do
    test "tenant can list archived media from their site only", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media1 = create_media_via_ash(%{name: "Site1 Archived"}, site.id)
      media2 = create_media_via_ash(%{name: "Site2 Archived"}, site2.id)

      Ash.Changeset.for_destroy(media1, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      Ash.Changeset.for_destroy(media2, :destroy, %{}, tenant: site2.id)
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
      assert media1.id in ids
      refute media2.id in ids
    end

    test "tenant can get archived media by id from their site", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Get Archived Tenant"}, site.id)

      Ash.Changeset.for_destroy(media, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/archived/#{media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["id"] == media.id
    end

    test "tenant can unarchive media from their site", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Tenant Unarchive"}, site.id)

      Ash.Changeset.for_destroy(media, :destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/unarchive",
          %{
            "type" => "media",
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
    test "tenant can permanently delete media from their site", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Tenant Permanent Delete"}, site.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
    end

    test "tenant cannot permanently delete media from another site", %{
      site2: site2,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Other Site Permanent"}, site2.id)
      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/permanent",
          %{},
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 404
    end
  end

  describe "VERSION MANAGEMENT - Get With Versions" do
    test "tenant can get media with versions", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Media With Versions", description: "v1"}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/with-versions?fields[media]=name,description,sorted_versions",
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

    test "master can get media with versions from any site", %{
      site: site,
      master_user: master_user
    } do
      media = create_media_via_ash(%{name: "Master Versions Test", description: "v1"}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "v2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/with-versions?fields[media]=name,description,sorted_versions",
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
    test "tenant can list versions for media", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "List Versions Test", featured: false}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{featured: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_list(body["data"])
    end

    test "master can list versions for media from any site", %{
      site: site,
      master_user: master_user
    } do
      media = create_media_via_ash(%{name: "Master List Versions", featured: false}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{featured: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/versions",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Restore Version" do
    test "tenant can restore media to previous version", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Restore Test", description: "original"}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version =
        MishkaCmsCore.Runtime.Media.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: media.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/version/#{version.id}/restore",
          %{
            "type" => "media",
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

    test "master can restore media version from any site", %{site: site, master_user: master_user} do
      media =
        create_media_via_ash(%{name: "Master Restore Test", description: "original"}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version =
        MishkaCmsCore.Runtime.Media.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: media.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/version/#{version.id}/restore",
          %{
            "type" => "media",
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
    test "tenant can preview media version without restoring", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      media = create_media_via_ash(%{name: "Preview Test", description: "original"}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version =
        MishkaCmsCore.Runtime.Media.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: media.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200

      reloaded =
        MishkaCmsCore.Runtime.Media
        |> Ash.get!(media.id, tenant: site.id, authorize?: false)

      assert reloaded.description == "modified"
    end

    test "master can preview media version from any site", %{site: site, master_user: master_user} do
      media =
        create_media_via_ash(%{name: "Master Preview Test", description: "original"}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "modified"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version =
        MishkaCmsCore.Runtime.Media.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: media.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      token = sign_in_master(master_user)

      response =
        make_api_request(
          "#{@master_path}/#{media.id}/version/#{version.id}/preview",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response.status == 200
    end
  end

  describe "VERSION MANAGEMENT - Calculations" do
    test "can load version_count calculation", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Version Count Test", featured: false}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{featured: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}?fields[media]=name,version_count",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["version_count"] == 2
    end

    test "can load latest_version calculation", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Latest Version Test", featured: false}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{featured: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}?fields[media]=name,latest_version",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["latest_version"] != nil
    end

    test "can load recent_versions calculation", %{site: site, tenant_admin: tenant_admin} do
      media = create_media_via_ash(%{name: "Recent Versions Test", featured: false}, site.id)

      media
      |> Ash.Changeset.for_update(:update, %{featured: true}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      token = sign_in_tenant(tenant_admin)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}?fields[media]=name,recent_versions",
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
      media = create_media_via_ash(%{name: "Auth Test"}, site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{},
          method: :get,
          headers: []
        )

      assert response.status in [401, 403]
    end

    test "invalid token is rejected", %{site: site} do
      media = create_media_via_ash(%{name: "Invalid Token Test"}, site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer invalid_token_here"}]
        )

      assert response.status in [401, 403]
    end
  end

  describe "CROSS-TENANT ISOLATION" do
    test "tenant from site1 cannot access site2 media", %{
      site: site,
      site2: site2,
      tenant_admin: tenant_admin
    } do
      site1_media = create_media_via_ash(%{name: "Site1 Isolated"}, site.id)
      site2_media = create_media_via_ash(%{name: "Site2 Isolated"}, site2.id)

      token = sign_in_tenant(tenant_admin)

      response1 =
        make_api_request(
          "#{@tenant_path}/#{site1_media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response1.status == 200

      response2 =
        make_api_request(
          "#{@tenant_path}/#{site2_media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response2.status == 404
    end

    test "master can access media from all sites", %{
      site: site,
      site2: site2,
      master_user: master_user
    } do
      site1_media = create_media_via_ash(%{name: "Site1 Master Access"}, site.id)
      site2_media = create_media_via_ash(%{name: "Site2 Master Access"}, site2.id)

      token = sign_in_master(master_user)

      response1 =
        make_api_request(
          "#{@master_path}/#{site1_media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response1.status == 200

      response2 =
        make_api_request(
          "#{@master_path}/#{site2_media.id}",
          %{},
          method: :get,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

      assert response2.status == 200
    end
  end

  # A row is made by an upload, not by the JSON:API; what it says about its file is edited here.
  describe "MEDIA-SPECIFIC - Type and Format" do
    test "can set each media type", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)

      for {media_type, format} <- [{"images", "png"}, {"videos", "mp4"}, {"documents", "pdf"}] do
        media = create_media_via_ash(%{name: "Test #{media_type}"}, site.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{media.id}",
            %{
              "type" => "media",
              "attributes" => %{"type" => media_type, "format" => format}
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["type"] == media_type
        assert body["data"]["attributes"]["format"] == format
      end
    end

    test "can set featured flag on media", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)
      media = create_media_via_ash(%{name: "Featured Media"}, site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
            "attributes" => %{"featured" => true}
          },
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/vnd.api+json"}
          ]
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"]["featured"] == true
    end

    test "can set dimensions on media", %{site: site, tenant_admin: tenant_admin} do
      token = sign_in_tenant(tenant_admin)
      media = create_media_via_ash(%{name: "Dimensioned Media"}, site.id)

      response =
        make_api_request(
          "#{@tenant_path}/#{media.id}",
          %{
            "type" => "media",
            "attributes" => %{
              "dimensions" => %{
                "width" => 1920,
                "height" => 1080,
                "unit" => "px"
              }
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
      dimensions = body["data"]["attributes"]["dimensions"]
      assert dimensions["width"] == 1920
      assert dimensions["height"] == 1080
    end
  end
end
