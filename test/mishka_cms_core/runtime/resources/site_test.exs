# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.SiteTest do
  @moduledoc """
  Comprehensive tests for Site resource.

  Site is the tenant entity in the multi-tenant architecture.
  Most actions are master-only except read/get which allow tenant users to see their own site.
  """
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  require Ash.Query
  alias MishkaCmsCore.Runtime.Site
  @moduletag :unit

  defp set_as_master!(site) do
    site
    |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp master?(site), do: Ash.get!(Site, site.id, action: :get_any, authorize?: false).master

  defp archived_site!(name) do
    [name: name]
    |> create_site!()
    |> archive!()
  end

  defp archived_master!(name) do
    [name: name]
    |> create_site!()
    |> set_as_master!()
    |> archive_as_before!()
  end

  # AN ARCHIVED MASTER, AS ONE ARCHIVED BEFORE THE MASTER SITE COULD NO LONGER BE: straight in the
  # database, since `:destroy` now refuses the master site. Restoring such a site still has to work.
  defp archive_as_before!(site) do
    import Ecto.Query

    {1, _} =
      MishkaCmsCore.Repo.update_all(
        from(s in "sites", where: s.id == type(^site.id, :binary_id)),
        set: [archived_at: DateTime.utc_now()]
      )

    Ash.get!(Site, site.id, action: :get_archived, authorize?: false)
  end

  defp archive!(site) do
    Ash.destroy!(site, action: :destroy, authorize?: false)
    Ash.get!(Site, site.id, action: :get_archived, authorize?: false)
  end

  describe "resource configuration" do
    test "uses correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(Site) == "sites"
      assert AshPostgres.DataLayer.Info.repo(Site) == @repo
    end

    test "has required extensions enabled" do
      assert AshArchival.Resource in Spark.extensions(Site)
      assert AshJsonApi.Resource in Spark.extensions(Site)
    end

    test "has no multitenancy (Site IS the tenant)" do
      assert Ash.Resource.Info.multitenancy_strategy(Site) == nil
    end

    test "uses UUID for primary keys" do
      site = create_site!()
      assert is_binary(site.id)
      assert String.length(site.id) == 36
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      site_id = site.id
      sites = Ash.read!(Site, action: :master_read, authorize?: false)

      assert site_id in Enum.map(sites.results, & &1.id)

      # Destroy returns :ok by default (not the record)
      :ok = Ash.destroy!(site, action: :destroy, authorize?: false)
      sites = Ash.read!(Site, action: :master_read, authorize?: false)

      refute site_id in Enum.map(sites.results, & &1.id)
    end
  end

  describe "master create action" do
    test "master user creates site with valid attributes" do
      attrs = %{name: "Test Site", host: "test.com", mode: :hybrid}

      assert {:ok, site} =
               Site
               |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
               |> Ash.create()

      assert site.name == "test-site"
      assert site.host == "test.com"
      assert site.mode == :hybrid
      assert site.active == true
      assert site.priority == 0
    end

    test "auto-generates slug from name" do
      site = create_site!(name: "My Awesome Site")
      assert site.name == "my-awesome-site"
    end

    test "requires name and host" do
      assert_raise Ash.Error.Invalid, fn ->
        Site
        |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
        |> Ash.create!()
      end
    end

    test "validates name length constraints" do
      # Too short
      changeset =
        Ash.Changeset.for_create(Site, :create, %{name: "ab", host: "test.com"},
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Too long
      long_name = String.duplicate("a", 71)

      changeset =
        Ash.Changeset.for_create(Site, :create, %{name: long_name, host: "test.com"},
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Valid
      changeset =
        Ash.Changeset.for_create(Site, :create, %{name: "Valid Name", host: "test.com"},
          authorize?: false
        )

      assert changeset.valid?
    end

    test "validates host length and format" do
      # Too short
      changeset =
        Ash.Changeset.for_create(Site, :create, %{name: "Test", host: "ab"}, authorize?: false)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Invalid format
      changeset =
        Ash.Changeset.for_create(Site, :create, %{name: "Test", host: "-invalid-.com"},
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Valid
      changeset =
        Ash.Changeset.for_create(Site, :create, %{name: "Test", host: "valid-site.com"},
          authorize?: false
        )

      assert changeset.valid?
    end

    test "validates mode is one of allowed values" do
      valid_modes = [:api_only, :phoenix_only, :hybrid]

      for {mode, idx} <- Enum.with_index(valid_modes) do
        site =
          Site
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test Site #{idx}",
              host: "test#{idx}.com",
              mode: mode
            },
            authorize?: false
          )
          |> Ash.create!()

        assert site.mode == mode
      end

      assert_raise Ash.Error.Invalid, fn ->
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Invalid",
            host: "invalid.com",
            mode: "invalid_mode"
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)
      end
    end

    test "validates priority range" do
      # Below minimum
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: "Test",
            host: "test.com",
            priority: -1
          },
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Above maximum
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: "Test",
            host: "test.com",
            priority: 101
          },
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Valid
      site = create_site!(priority: 50)
      assert site.priority == 50
    end

    test "enforces unique name constraint" do
      create_site!(name: "Unique Site")

      assert_raise Ash.Error.Invalid, fn ->
        create_site!(name: "Unique Site", host: "different.com")
      end
    end

    test "enforces unique host constraint" do
      create_site!(host: "unique.com")

      assert_raise Ash.Error.Invalid, fn ->
        create_site!(name: "Different Name", host: "unique.com")
      end
    end

    test "sets default values correctly" do
      # Create site without mode to test actual default
      site =
        Site
        |> Ash.Changeset.for_create(:create, %{name: "Default Test", host: "default.com"},
          authorize?: false
        )
        |> Ash.create!()

      assert site.priority == 0
      assert site.active == true
      assert site.master == false
      assert site.mode == :hybrid
      assert site.allowed_origins == []
      assert site.inserted_at != nil
      assert site.updated_at != nil
    end
  end

  describe "master update action" do
    test "master user updates site successfully" do
      site = create_site!(name: "Original")

      updated =
        site
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, authorize?: false)
        |> Ash.update!()

      assert updated.name == "updated-name"
    end

    test "updates multiple attributes" do
      site = create_site!()

      updated =
        site
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "New Name",
            priority: 75,
            active: false,
            mode: :api_only
          },
          authorize?: false
        )
        |> Ash.update!()

      assert updated.name == "new-name"
      assert updated.priority == 75
      assert updated.active == false
      assert updated.mode == :api_only
    end

    test "prevents updating archived sites" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      changeset =
        Ash.Changeset.for_update(archived, :update, %{name: "Should Fail"}, authorize?: false)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          error.fields == [:archived_at]
      end)
    end

    test "validates constraints on update" do
      site = create_site!()

      # Name too short
      changeset = Ash.Changeset.for_update(site, :update, %{name: "ab"}, authorize?: false)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      # Priority out of range
      changeset = Ash.Changeset.for_update(site, :update, %{priority: -5}, authorize?: false)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end
  end

  describe "master activate/deactivate actions" do
    test "activate sets active to true" do
      site = create_site!(active: false)

      activated =
        site
        |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
        |> Ash.update!()

      assert activated.active == true
    end

    test "deactivate sets active to false" do
      site = create_site!(active: true)

      deactivated =
        site
        |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
        |> Ash.update!()

      assert deactivated.active == false
    end

    test "cannot activate archived sites - must unarchive first" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      fresh_archived =
        Site
        |> Ash.get!(archived.id, action: :get_archived, authorize?: false)

      assert {:error, _error} =
               fresh_archived
               |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
               |> Ash.update()

      # Unarchive first
      unarchived =
        fresh_archived
        |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
        |> Ash.update!()

      # Then activate
      activated =
        unarchived
        |> Ash.Changeset.for_update(:activate, %{}, authorize?: false)
        |> Ash.update!()

      assert activated.active == true
    end
  end

  describe "master destroy actions (soft delete)" do
    test "destroy archives site by setting archived_at" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      assert archived.archived_at != nil

      # Should not appear in regular read
      result = Ash.read!(Site, action: :master_read, authorize?: false)
      refute archived.id in Enum.map(result.results, & &1.id)

      # Should appear in archived
      archived_result = Ash.read!(Site, action: :archived, authorize?: false)
      assert archived.id in Enum.map(archived_result.results, & &1.id)
    end

    test "prevents archiving already archived site" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Database trigger prevents this (raises Postgrex.Error wrapped in Ash.Error.Unknown)
      assert_raise Ash.Error.Unknown, fn ->
        archived
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()
      end
    end
  end

  describe "master unarchive action" do
    test "restores archived site" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      unarchived =
        archived
        |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
        |> Ash.update!()

      assert unarchived.archived_at == nil

      # Should appear in regular read again
      result = Ash.read!(Site, action: :master_read, authorize?: false)
      assert site.id in Enum.map(result.results, & &1.id)
    end

    # AN ARCHIVED SITE KEEPS THE FLAG IT WAS ARCHIVED WITH, and the database allows one live master.
    test "restores a master replaced while it was archived, as a site that is not master" do
      old = archived_master!("Old Master")
      new = set_as_master!(create_site!(name: "New Master"))

      assert {:ok, restored} =
               old
               |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
               |> Ash.update()

      refute restored.master
      assert master?(new)
    end

    test "and restores it together with other sites" do
      old = archived_master!("Old Master")
      other = archived_site!("Other Site")
      new = set_as_master!(create_site!(name: "New Master"))

      result =
        Site
        |> Ash.Query.for_read(:archived, %{}, authorize?: false)
        |> Ash.Query.filter(id in ^[old.id, other.id])
        |> Ash.bulk_update(:unarchive, %{},
          authorize?: false,
          strategy: [:atomic, :atomic_batches, :stream],
          allow_stream_with: :full_read,
          return_errors?: true
        )

      assert result.status == :success
      refute master?(old)
      assert master?(new)
    end

    test "restores a master nobody replaced as the master" do
      old = archived_master!("Only Master")

      assert {:ok, %{master: true}} =
               old
               |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
               |> Ash.update()
    end
  end

  describe "master permanent_destroy action" do
    test "permanently deletes site from database" do
      site = create_site!()
      site_id = site.id

      :ok =
        site
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy()

      # Should not exist anywhere
      active_result = Ash.read!(Site, action: :master_read, authorize?: false)
      archived_result = Ash.read!(Site, action: :archived, authorize?: false)

      refute site_id in Enum.map(active_result.results, & &1.id)
      refute site_id in Enum.map(archived_result.results, & &1.id)
    end
  end

  describe "master set_as_master/unset_as_master actions" do
    test "set_as_master sets site as master and unsets others" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      # Set site1 as master
      site1
      |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
      |> Ash.update!()

      # Verify site1 is master
      refreshed1 = Ash.get!(Site, site1.id, action: :master_get, authorize?: false)
      assert refreshed1.master == true

      # Set site2 as master
      site2
      |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
      |> Ash.update!()

      # Verify site2 is master and site1 is not
      refreshed1 = Ash.get!(Site, site1.id, action: :master_get, authorize?: false)
      refreshed2 = Ash.get!(Site, site2.id, action: :master_get, authorize?: false)

      assert refreshed2.master == true
      refute refreshed1.master
    end

    # AN ARCHIVED SITE KEEPS THE FLAG IT WAS ARCHIVED WITH, and the database refuses every write to
    # an archived site but the one that restores it.
    test "set_as_master goes ahead while an archived site still holds the flag" do
      old = create_site!(name: "Old Master")
      new = create_site!(name: "New Master")

      old
      |> set_as_master!()
      |> archive_as_before!()

      assert {:ok, %{master: true}} =
               new
               |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
               |> Ash.update()
    end

    # THE OTHER SITE LOSES ITS FLAG ONLY IN THE WRITE THAT GIVES IT AWAY, so a refused one leaves it.
    test "a set_as_master refused for an archived site leaves the master its flag" do
      master = set_as_master!(create_site!(name: "Kept Master"))

      assert {:error, %Ash.Error.Invalid{}} =
               "Archived Site"
               |> archived_site!()
               |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
               |> Ash.update()

      assert master?(master)
    end

    test "and so does one refused to a tenant, on its own site" do
      master = set_as_master!(create_site!(name: "Kept Master"))
      site = create_site!(name: "Tenant Site")
      tenant = create_user_with_permissions!(["*"], site_id: site.id)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(site, %{}, action: :set_as_master, actor: tenant)

      assert master?(master)
    end

    test "and one refused to a master user without the permission" do
      master = set_as_master!(create_site!(name: "Kept Master"))
      site = create_site!(name: "Other Site")
      user = create_user!(site_id: nil, email: "no-permission@example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(site, %{}, action: :set_as_master, actor: user)

      assert master?(master)
    end

    test "cannot set archived site as master" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      fresh_archived = Ash.get!(Site, archived.id, action: :get_archived, authorize?: false)

      assert_raise Ash.Error.Invalid, fn ->
        fresh_archived
        |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
        |> Ash.update!()
      end
    end

    # THE MASTER SITE IS NEVER LEFT WITHOUT ITS FLAG: every master signs in through it. Making another
    # site master is how the flag moves.
    test "unset_as_master is refused on the master site" do
      master = set_as_master!(create_site!())

      assert {:error, %Ash.Error.Invalid{} = error} =
               master
               |> Ash.Changeset.for_update(:unset_as_master, %{}, authorize?: false)
               |> Ash.update()

      assert Exception.message(error) =~ "Make another site master first"
      assert master?(master)
    end
  end

  describe "tenant read actions - allowed" do
    test "tenant user can read their own site with :tenant_read action" do
      site = create_site!()

      # Simulate tenant user with site_id
      result =
        Site
        |> Ash.Query.for_read(:tenant_read, %{},
          actor: %{site_id: site.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.read!()

      # Tenant sees only their site
      assert length(result.results) == 1
      assert List.first(result.results).id == site.id
    end

    test "tenant user can get their own site with :get action" do
      site = create_site!()

      result =
        Site
        |> Ash.get(site.id,
          action: :get,
          actor: %{tenant_id: site.id},
          authorize?: false
        )

      assert {:ok, fetched} = result
      assert fetched.id == site.id
    end

    test "tenant user cannot see other sites" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      # Tenant for site1 tries to read using tenant_read action
      result =
        Site
        |> Ash.Query.for_read(:tenant_read, %{},
          actor: %{site_id: site1.id},
          tenant: site1.id,
          authorize?: false
        )
        |> Ash.read!()

      site_ids = Enum.map(result.results, & &1.id)

      # Should only see site1
      assert site1.id in site_ids
      refute site2.id in site_ids
      assert length(site_ids) == 1
    end

    test "tenant user cannot get other sites" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      # Tenant for site1 tries to get site2 using tenant_get action
      result =
        Site
        |> Ash.get(site2.id,
          action: :tenant_get,
          actor: %{site_id: site1.id},
          tenant: site1.id,
          authorize?: false
        )

      # Should return nothing (filtered out)
      assert {:error, _} = result
    end
  end

  describe "tenant write restrictions - authorization enforcement" do
    setup do
      # Create admin permission
      admin_permission = create_permission!(name: "admin:*")

      # Create site
      site = create_site!()

      # Create master user (site_id = nil) with admin permissions
      master_user =
        create_user!(site_id: nil, email: "master@example.com")
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      # Create tenant user (site_id = site.id) WITH admin permissions
      # This tests that TenantContext validation blocks them, not lack of permissions
      tenant_user =
        create_user!(site_id: site.id, email: "tenant@example.com")
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      %{
        site: site,
        master_user: master_user,
        tenant_user: tenant_user
      }
    end

    test "tenant user cannot update their site (TenantContext blocks non-master)", %{
      site: site,
      tenant_user: tenant_user
    } do
      result =
        site
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Attempted Update"},
          actor: tenant_user,
          tenant: tenant_user.site_id,
          authorize?: true
        )
        |> Ash.update()

      assert {:error, error} = result
      error_message = Exception.message(error)
      assert error_message =~ "Tenant context must be nil" or error_message =~ "forbidden"
    end

    test "tenant user cannot create sites (TenantContext blocks non-master)", %{
      tenant_user: tenant_user
    } do
      result =
        Site
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Tenant Site", host: "tenant.com"},
          actor: tenant_user,
          tenant: tenant_user.site_id,
          authorize?: true
        )
        |> Ash.create()

      # Should fail - TenantContext validation requires tenant to be nil for create action
      assert {:error, error} = result
      error_message = Exception.message(error)
      assert error_message =~ "Tenant context must be nil" or error_message =~ "forbidden"
    end
  end

  describe "master read actions" do
    test "master_read lists all sites" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")
      site3 = create_site!(name: "Site 3")

      result = Ash.read!(Site, action: :master_read, authorize?: false)

      site_ids = Enum.map(result.results, & &1.id)

      assert site1.id in site_ids
      assert site2.id in site_ids
      assert site3.id in site_ids
    end

    test "master_get retrieves any site by ID" do
      site = create_site!()

      fetched = Ash.get!(Site, site.id, action: :master_get, authorize?: false)

      assert fetched.id == site.id
    end

    test "get_any includes both active and archived sites" do
      active_site = create_site!(name: "Active")
      archived_site = create_site!(name: "Archived")

      archived_site
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # get_any can get active
      active_result = Ash.get!(Site, active_site.id, action: :get_any, authorize?: false)
      assert active_result.id == active_site.id

      # get_any can get archived
      archived_result = Ash.get!(Site, archived_site.id, action: :get_any, authorize?: false)
      assert archived_result.id == archived_site.id
    end

    test "get_archived retrieves archived sites only" do
      active_site = create_site!(name: "Active")
      archived_site = create_site!(name: "Archived")

      archived_site
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Can get archived site
      result = Ash.get!(Site, archived_site.id, action: :get_archived, authorize?: false)
      assert result.id == archived_site.id

      # Cannot get active site with get_archived (error is wrapped in Ash.Error.Invalid)
      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(Site, active_site.id, action: :get_archived, authorize?: false)
      end
    end

    test "archived action lists only archived sites" do
      active = create_site!(name: "Active")
      archived = create_site!(name: "Archived")

      archived
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      result = Ash.read!(Site, action: :archived, authorize?: false)

      archived_ids = Enum.map(result.results, & &1.id)

      assert archived.id in archived_ids
      refute active.id in archived_ids
    end
  end

  describe "identities" do
    test "allows same name for archived and active sites" do
      site1 = create_site!(name: "Same Name")

      site1
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      site2 = create_site!(name: "Same Name", host: "different.com")
      assert site2.name == "same-name"
    end

    test "allows same host for archived and active sites" do
      site1 = create_site!(host: "same.com")

      site1
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      site2 = create_site!(name: "Different Name", host: "same.com")
      assert site2.host == "same.com"
    end

    test "cannot unarchive if name conflicts with active site" do
      site1 = create_site!(name: "Conflict Name")

      archived =
        site1
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      _site2 = create_site!(name: "Conflict Name", host: "different.com")

      # Try to unarchive - should fail due to name conflict
      assert {:error, _error} =
               archived
               |> Ash.Changeset.for_update(:unarchive, %{}, authorize?: false)
               |> Ash.update()
    end
  end

  describe "database constraints" do
    test "database enforces check constraints on name" do
      site = create_site!()
      binary_id = Ecto.UUID.dump!(site.id)

      # Try to set empty name directly in database
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE sites SET name = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database enforces check constraints on host" do
      site = create_site!()
      binary_id = Ecto.UUID.dump!(site.id)

      # Try to set empty host directly in database
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE sites SET host = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database enforces priority range constraint" do
      site = create_site!()
      binary_id = Ecto.UUID.dump!(site.id)

      # Try to set priority out of range
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE sites SET priority = 150 WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger prevents archived updates" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      binary_id = Ecto.UUID.dump!(archived.id)

      # Try to directly update archived record in database
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE sites SET name = 'Should Fail' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger allows unarchiving" do
      site = create_site!()

      archived =
        site
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      binary_id = Ecto.UUID.dump!(archived.id)

      # Setting archived_at to NULL should work (unarchive)
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          @repo,
          "UPDATE sites SET archived_at = NULL WHERE id = $1",
          [binary_id]
        )
    end

    test "database enforces only one master site" do
      site1 = create_site!(name: "Site 1")

      # Set site1 as master
      site1
      |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
      |> Ash.update!()

      site2 = create_site!(name: "Site 2")
      binary_id = Ecto.UUID.dump!(site2.id)

      # Try to set site2 as master directly in database (should fail)
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE sites SET master = true WHERE id = $1",
          [binary_id]
        )
      end
    end
  end

  # NO READ OF ANY SITE'S BUILDER RESOURCES BY AN ID IN INPUT. The raw action took a `site_id` and
  # answered that site's row, components and layouts to anybody holding a dashboard permission,
  # whatever their own site; nothing called it. The builder reads its palette through
  # `:for_tenant_with_globals`, which decides the site from who is asking.
  describe "no raw read of a site's builder resources" do
    test "the Site resource has no such action and the domain no such function" do
      assert is_nil(Ash.Resource.Info.action(Site, :load_page_builder_resources_raw))

      Code.ensure_loaded!(MishkaCmsCore.Runtime)
      refute function_exported?(MishkaCmsCore.Runtime, :builder_raw, 2)
      refute function_exported?(MishkaCmsCore.Runtime, :builder_raw!, 2)
    end

    # What that read fed: an AST built from every row it returned, each page wrapped in whatever
    # layout its id named, and a cache for it. Nothing calls either.
    test "nor the AST it was encoded into, nor the cache that held it" do
      Code.ensure_loaded!(MishkaCmsCore.Runtime.PageBuilder.Helpers)

      for arity <- [2, 3] do
        refute function_exported?(
                 MishkaCmsCore.Runtime.PageBuilder.Helpers,
                 :builder_encoded_ast,
                 arity
               )
      end

      refute Code.ensure_loaded?(MishkaCmsCore.Runtime.States.PageBuilderAstState)
    end
  end

  # THE BYPASS READS ARE A MASTER'S. `:read_any` and `:get_any` skip tenancy so a master, and the
  # system, reach every site; every `belongs_to :site` reads through `:read_any`, so a site user's own
  # records still load their own site. Another site is out of reach whatever the user holds.
  describe "the bypass reads" do
    setup do
      site_a = create_site!()
      site_b = create_site!()

      %{
        site_a: site_a,
        site_b: site_b,
        star_a: create_user_with_permissions!(["*"], site_id: site_a.id),
        master: create_user_with_permissions!(["*"])
      }
    end

    defp site_ids(opts) do
      Site
      |> Ash.Query.for_read(:read_any, %{}, opts)
      |> Ash.read!(opts)
      |> MapSet.new(& &1.id)
    end

    test "a site user holding every permission reads its own site alone", context do
      ids = site_ids(actor: context.star_a)

      assert MapSet.member?(ids, context.site_a.id)
      refute MapSet.member?(ids, context.site_b.id)

      assert {:error, _gone} =
               Ash.get(Site, context.site_b.id, action: :get_any, actor: context.star_a)
    end

    test "a master and the system read every site", context do
      for ids <- [site_ids(actor: context.master), site_ids(authorize?: false)] do
        assert MapSet.member?(ids, context.site_a.id)
        assert MapSet.member?(ids, context.site_b.id)
      end
    end

    test "a site user's own record still loads its site", context do
      page = create_page!(site_id: context.site_a.id)

      assert {:ok, %{site: %{id: id}}} =
               Ash.load(page, [:site], actor: context.star_a, tenant: context.site_a.id)

      assert id == context.site_a.id
    end

    test "a site user reads its own site alone through the primary reads too", context do
      ids =
        Site
        |> Ash.Query.for_read(:read, %{}, actor: context.star_a)
        |> Ash.read!(actor: context.star_a)
        |> MapSet.new(& &1.id)

      assert MapSet.member?(ids, context.site_a.id)
      refute MapSet.member?(ids, context.site_b.id)
    end
  end

  # ONE CLICK MUST NEVER LOCK EVERY MASTER OUT. The master site cannot be switched off, archived,
  # deleted or unset while it is the master site; once another site is master, it can.
  describe "the master site stays" do
    setup do
      %{master: set_as_master!(create_site!())}
    end

    defp refused?({:error, error}),
      do: Exception.message(error) =~ "This is the master site. Make another site master first."

    defp refused?(_ok), do: false

    defp fresh(site), do: Ash.get!(Site, site.id, action: :get_any, authorize?: false)

    test "cannot be deactivated", %{master: master} do
      assert master
             |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
             |> Ash.update()
             |> refused?()

      assert fresh(master).active
    end

    test "cannot be switched off or unset through an edit, and other edits still save", %{
      master: master
    } do
      assert master
             |> Ash.update(%{active: false}, action: :update, authorize?: false)
             |> refused?()

      assert fresh(master)
             |> Ash.update(%{master: false}, action: :update, authorize?: false)
             |> refused?()

      assert {:ok, %{priority: 7}} =
               fresh(master) |> Ash.update(%{priority: 7}, action: :update, authorize?: false)
    end

    test "cannot be archived or deleted for good", %{master: master} do
      assert master |> Ash.destroy(action: :destroy, authorize?: false) |> refused?()
      assert master |> Ash.destroy(action: :permanent_destroy, authorize?: false) |> refused?()

      assert is_nil(fresh(master).archived_at)
    end

    test "can be, once another site is master", %{master: master} do
      set_as_master!(create_site!())

      assert {:ok, %{active: false}} =
               master
               |> fresh()
               |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
               |> Ash.update()
    end

    # MASTERS SIGN IN ON THE MASTER SITE'S WEB PAGES AND NOWHERE ELSE, so the flag never moves to a
    # site a browser cannot sign in on, and the master site never stops taking web visits.
    test "is not moved to a site that is switched off or takes no web visits", %{master: master} do
      for attrs <- [%{active: false}, %{mode: :api_only}] do
        assert {:error, error} =
                 attrs
                 |> Keyword.new()
                 |> create_site!()
                 |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
                 |> Ash.update()

        assert Exception.message(error) =~
                 "Masters sign in on the master site's web pages, so it must be switched on and take web visits."
      end

      assert {:ok, %{master: true}} =
               [mode: :phoenix_only]
               |> create_site!()
               |> Ash.Changeset.for_update(:set_as_master, %{}, authorize?: false)
               |> Ash.update()

      refute master?(master)
    end

    test "keeps taking web visits through an edit", %{master: master} do
      assert {:error, error} =
               Ash.update(master, %{mode: :api_only}, action: :update, authorize?: false)

      assert Exception.message(error) =~
               "Masters sign in on the master site's web pages, so it must be switched on and take web visits."

      assert fresh(master).mode == :hybrid

      assert {:ok, %{mode: :phoenix_only}} =
               Ash.update(fresh(master), %{mode: :phoenix_only},
                 action: :update,
                 authorize?: false
               )
    end

    test "is not doubled by creating or editing another site as master", %{master: master} do
      assert {:error, created} =
               Site
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "second-master", host: "second-master.test", master: true},
                 authorize?: false
               )
               |> Ash.create()

      assert {:error, edited} =
               Ash.update(create_site!(), %{master: true}, action: :update, authorize?: false)

      for error <- [created, edited] do
        assert Exception.message(error) =~
                 "Another site is the master site. Use Set Master to move it to this one."
      end

      assert master?(master)
    end

    test "is the one the site cache names master once the flag moves" do
      alias MishkaCmsCore.Runtime.States.SiteState

      [from, to] =
        for _site <- 1..2 do
          n = System.unique_integer([:positive])
          site = create_site!(name: "cached-#{n}", host: "cached-#{n}.test")
          on_exit(fn -> SiteState.delete(site.id) end)
          site
        end

      set_as_master!(from)
      assert {:ok, %{master: true}} = SiteState.get(from.id)

      set_as_master!(to)

      assert {:ok, %{master: false}} = SiteState.get(from.id)
      assert {:ok, %{master: true}} = SiteState.get(to.id)
      assert {:ok, %{id: master_id}} = SiteState.get_by_master()
      assert master_id == to.id
    end
  end
end
