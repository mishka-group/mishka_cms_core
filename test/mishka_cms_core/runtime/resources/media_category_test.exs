# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.MediaCategoryTest do
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  alias MishkaCmsCore.Runtime.MediaCategory
  require Ash.Query
  @moduletag :unit

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its media categories" do
      site = create_site!()
      create_media_category!(site_id: site.id)

      count = fn ->
        MediaCategory |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false) |> length()
      end

      assert count.() == 1
      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
      assert count.() == 0
    end
  end

  describe "configuration" do
    test "resource has correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(MediaCategory) == "media_categories"
      assert AshPostgres.DataLayer.Info.repo(MediaCategory) == @repo
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(MediaCategory)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(MediaCategory) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(MediaCategory) == :site_id
      assert Ash.Resource.Info.multitenancy_global?(MediaCategory) == false
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      category = create_media_category!(site_id: site.id)

      categories =
        MediaCategory
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped category in categories

      archived_category = Ash.destroy!(category, authorize?: false)

      categories =
        MediaCategory
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived_category not in categories
    end
  end

  describe "create action" do
    test "creates a media category with valid attributes" do
      site = create_site!()

      attrs = %{
        name: "Image Gallery",
        description: "Gallery for images"
      }

      assert {:ok, category} =
               MediaCategory
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.create(authorize?: false)

      assert category.name == "image-gallery"
      assert category.description == "Gallery for images"
      assert category.site_id == site.id
    end

    test "validates required fields" do
      site = create_site!()

      changeset =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :name
      end)
    end

    test "validates name length constraints" do
      site = create_site!()

      # Name too short (less than 2 characters)
      changeset =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "A"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :name
      end)

      # Name too long (more than 200 characters)
      long_name = String.duplicate("a", 201)

      changeset2 =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: long_name}, tenant: site.id)

      assert_has_error(changeset2, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :name
      end)
    end

    test "enforces unique name per site constraint" do
      site = create_site!()

      # Create first category
      create_media_category!(name: "Images", site_id: site.id)

      # Try to create another with same name for same site
      changeset =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "Images"}, tenant: site.id)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute and
                 e.field == :name
             end)
    end

    test "allows same name across different sites" do
      site1 = create_site!()
      site2 = create_site!()

      # Create category with same name on site1
      category1 =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "Shared Name"}, tenant: site1.id)
        |> Ash.create!(authorize?: false)

      # Should succeed with same name on site2
      category2 =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "Shared Name"}, tenant: site2.id)
        |> Ash.create!(authorize?: false)

      assert category1.name == category2.name
      assert category1.site_id != category2.site_id
    end

    test "applies slugification to name" do
      site = create_site!()

      category =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "My Special Category!"}, tenant: site.id)
        |> Ash.create!(authorize?: false)

      assert category.name == "my-special-category"
    end

    test "description is optional" do
      site = create_site!()

      # Create without description
      category =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "No Description"}, tenant: site.id)
        |> Ash.create!(authorize?: false)

      assert category.description == nil
    end

    test "validates description max length (1000 characters)" do
      site = create_site!()

      # Description too long (more than 1000 characters)
      long_description = String.duplicate("a", 1001)

      changeset =
        MediaCategory
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Long Description",
            description: long_description
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :description
      end)

      # Description with exactly 1000 characters should succeed
      exact_description = String.duplicate("b", 1000)

      category =
        MediaCategory
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Exact Description",
            description: exact_description
          },
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)

      assert String.length(category.description) == 1000
    end
  end

  describe "update action" do
    test "updates a non-archived media category successfully" do
      site = create_site!()
      category = create_media_category!(name: "Original", site_id: site.id)

      assert {:ok, updated} =
               category
               |> Ash.Changeset.for_update(
                 :update,
                 %{
                   name: "Updated Category",
                   description: "New description"
                 },
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)

      assert updated.name == "updated-category"
      assert updated.description == "New description"
    end

    test "prevents updating archived media categories" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      # Archive it
      {:ok, archived} = Ash.destroy(category, authorize?: false, return_destroyed?: true)

      # Try to update archived category
      changeset =
        archived
        |> Ash.Changeset.for_update(:update, %{name: "New Name"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          :archived_at in error.fields
      end)
    end

    test "validates name length on update" do
      site = create_site!()
      category = create_media_category!(name: "Original", site_id: site.id)

      # Try to update with too short name
      changeset =
        category
        |> Ash.Changeset.for_update(:update, %{name: "A"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :name
      end)
    end

    test "enforces unique name constraint on update" do
      site = create_site!()
      _category1 = create_media_category!(name: "Category One", site_id: site.id)
      category2 = create_media_category!(name: "Category Two", site_id: site.id)

      # Try to update category2 to have same name as category1
      changeset =
        category2
        |> Ash.Changeset.for_update(:update, %{name: "Category One"}, tenant: site.id)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.update(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute and
                 e.field == :name
             end)
    end
  end

  describe "read actions with multitenancy" do
    setup do
      site1 = create_site!(name: "site1", host: "site1.com")
      site2 = create_site!(name: "site2", host: "site2.com")

      %{site1: site1, site2: site2}
    end

    test "default read with tenant shows only site-specific categories", context do
      %{site1: site1, site2: site2} = context

      cat1 = create_media_category!(name: "Site1 Category", site_id: site1.id)
      cat2 = create_media_category!(name: "Site2 Category", site_id: site2.id)

      # Query with site1 tenant
      site1_categories =
        MediaCategory
        |> Ash.Query.set_tenant(site1.id)
        |> Ash.read!(authorize?: false)

      assert_stripped cat1 in site1_categories
      assert_stripped cat2 not in site1_categories

      # Query with site2 tenant
      site2_categories =
        MediaCategory
        |> Ash.Query.set_tenant(site2.id)
        |> Ash.read!(authorize?: false)

      assert_stripped cat2 in site2_categories
      assert_stripped cat1 not in site2_categories
    end

    test "master_read bypasses multitenancy", context do
      %{site1: site1, site2: site2} = context

      cat1 = create_media_category!(name: "Site1 Category", site_id: site1.id)
      cat2 = create_media_category!(name: "Site2 Category", site_id: site2.id)

      %{results: all_categories} =
        MediaCategory
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      assert_stripped cat1 in all_categories
      assert_stripped cat2 in all_categories
    end

    test "archived action filters archived categories", context do
      %{site1: site1} = context

      active = create_media_category!(name: "Active", site_id: site1.id)
      to_archive = create_media_category!(name: "To Archive", site_id: site1.id)

      {:ok, archived} = Ash.destroy(to_archive, authorize?: false, return_destroyed?: true)

      %{results: archived_categories} =
        MediaCategory
        |> Ash.Query.for_read(:archived, %{}, tenant: site1.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived in archived_categories
      assert_stripped active not in archived_categories
    end

    test "read_any bypasses multitenancy (internal use)", context do
      %{site1: site1, site2: site2} = context

      cat1 = create_media_category!(name: "Site1 Category", site_id: site1.id)
      cat2 = create_media_category!(name: "Site2 Category", site_id: site2.id)

      %{results: all_categories} =
        MediaCategory
        |> Ash.Query.for_read(:read_any)
        |> Ash.read!(authorize?: false, page: [limit: 100])

      assert_stripped cat1 in all_categories
      assert_stripped cat2 in all_categories
    end

    test "get_archived retrieves archived category by id", context do
      %{site1: site1} = context

      category = create_media_category!(name: "To Archive", site_id: site1.id)
      {:ok, archived} = Ash.destroy(category, authorize?: false, return_destroyed?: true)

      result =
        MediaCategory
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.Query.for_read(:get_archived, %{}, tenant: site1.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == archived.id
      assert result.archived_at != nil
    end

    test "get_any bypasses multitenancy", context do
      %{site1: site1, site2: site2} = context

      cat1 = create_media_category!(name: "Site1 Category", site_id: site1.id)
      cat2 = create_media_category!(name: "Site2 Category", site_id: site2.id)

      # Should be able to get cat1 from site2 context (bypasses multitenancy)
      result = Ash.get!(MediaCategory, cat1.id, action: :get_any, authorize?: false)
      assert result.id == cat1.id

      # Should be able to get cat2 from site1 context
      result2 = Ash.get!(MediaCategory, cat2.id, action: :get_any, authorize?: false)
      assert result2.id == cat2.id
    end
  end

  describe "archive/unarchive actions" do
    test "destroy archives a media category (sets archived_at)" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      assert category.archived_at == nil

      {:ok, archived} =
        category
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      assert archived.archived_at != nil
    end

    test "unarchive restores a media category" do
      site = create_site!()
      category = create_media_category!(name: "To Restore", site_id: site.id)

      # Archive it
      {:ok, archived} =
        category
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      assert archived.archived_at != nil

      # Unarchive it
      {:ok, restored} =
        archived
        |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id)
        |> Ash.update(authorize?: false)

      assert restored.archived_at == nil
    end

    test "permanent_destroy actually deletes the record" do
      site = create_site!()
      category = create_media_category!(name: "To Delete", site_id: site.id)
      category_id = category.id

      # Permanent destroy
      :ok =
        category
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id)
        |> Ash.destroy!(authorize?: false)

      # Verify it's gone
      result = Ash.get(MediaCategory, category_id, action: :get_any, authorize?: false)
      assert match?({:error, _}, result)
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()

      # Test name_length_check (name must be 2-200 characters)
      assert_raise Ecto.ConstraintError, fn ->
        %MishkaCmsCore.Runtime.MediaCategory{}
        |> Ecto.Changeset.change(%{
          id: Ash.UUID.generate(),
          name: "A",
          site_id: site.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })
        |> @repo.insert()
      end

      # Test no_empty_name constraint
      assert_raise Ecto.ConstraintError, fn ->
        %MishkaCmsCore.Runtime.MediaCategory{}
        |> Ecto.Changeset.change(%{
          id: Ash.UUID.generate(),
          name: "",
          site_id: site.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })
        |> @repo.insert()
      end
    end
  end

  describe "attribute defaults" do
    test "sets default values correctly" do
      site = create_site!()

      category =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "Test Category"}, tenant: site.id)
        |> Ash.create!(authorize?: false)

      assert category.description == nil
      assert category.archived_at == nil
      assert category.inserted_at != nil
      assert category.updated_at != nil
    end
  end

  describe "complex scenarios" do
    test "handles media category with full attributes" do
      site = create_site!()

      attrs = %{
        name: "Full Featured Category",
        description: "A comprehensive test category with all options"
      }

      category =
        MediaCategory
        |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
        |> Ash.create!(authorize?: false)

      assert category.name == "full-featured-category"
      assert category.description == "A comprehensive test category with all options"
      assert category.site_id == site.id
    end

    test "allows same name for archived and active categories within same site" do
      site = create_site!()

      # Create and archive a category
      category1 = create_media_category!(name: "Duplicate Name", site_id: site.id)

      category1
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      # Should be able to create another with same name since first is archived
      category2 =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "Duplicate Name"}, tenant: site.id)
        |> Ash.create!(authorize?: false)

      assert category2.name == "duplicate-name"
    end

    test "prevents unarchiving when active category with same name exists" do
      site = create_site!()

      # Create and archive category
      category1 = create_media_category!(name: "Conflict Name", site_id: site.id)

      {:ok, archived} =
        category1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      # Create new active category with same name
      _category2 = create_media_category!(name: "Conflict Name", site_id: site.id)

      # Try to unarchive - should fail due to unique constraint
      changeset = Ash.Changeset.for_update(archived, :unarchive, %{}, tenant: site.id)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.update(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute
             end)
    end
  end

  describe "relationships" do
    test "belongs_to site relationship" do
      site = create_site!()
      category = create_media_category!(name: "Test Category", site_id: site.id)

      loaded_category =
        MediaCategory
        |> Ash.Query.filter(id == ^category.id)
        |> Ash.Query.load(:site)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert loaded_category.site.id == site.id
      assert loaded_category.site.name == site.name
    end

    test "has_many media relationship" do
      site = create_site!()
      category = create_media_category!(name: "Images", site_id: site.id)

      # Create media files in this category
      media1 =
        MishkaCmsCore.Runtime.Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Photo 1",
            type: :images,
            size: 1024,
            format: "jpg",
            media_category_id: category.id
          },
          tenant: site.id,
          authorize?: false,
          private_arguments: %{stored_path: "/uploads/photo1.jpg"}
        )
        |> Ash.create!()

      media2 =
        MishkaCmsCore.Runtime.Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Photo 2",
            type: :images,
            size: 2048,
            format: "png",
            media_category_id: category.id
          },
          tenant: site.id,
          authorize?: false,
          private_arguments: %{stored_path: "/uploads/photo2.png"}
        )
        |> Ash.create!()

      # Load media for category
      loaded_category =
        MediaCategory
        |> Ash.Query.filter(id == ^category.id)
        |> Ash.Query.load(:media)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert length(loaded_category.media) == 2
      media_ids = Enum.map(loaded_category.media, & &1.id)
      assert media1.id in media_ids
      assert media2.id in media_ids
    end
  end

  describe "identities" do
    test "unique_name_per_site identity enforces uniqueness" do
      site = create_site!()

      create_media_category!(name: "Unique Category", site_id: site.id)

      # Try to create duplicate
      changeset =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "Unique Category"}, tenant: site.id)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute and
                 e.field == :name
             end)
    end
  end

  describe "JSON API configuration" do
    test "has correct JSON API type" do
      assert AshJsonApi.Resource.Info.type(MediaCategory) == "media_category"
    end
  end

  describe "master_create action" do
    test "master_create requires site_id and creates category" do
      site = create_site!()

      {:ok, category} =
        MediaCategory
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "Master Category",
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      assert category.name == "master-category"
      assert category.site_id == site.id
    end
  end

  describe "master read actions" do
    test "master_get returns any category by id" do
      site = create_site!()
      category = create_media_category!(name: "Test Category", site_id: site.id)

      result = Ash.get!(MediaCategory, category.id, action: :master_get, authorize?: false)
      assert result.id == category.id
    end

    test "master_archived returns all archived categories system-wide" do
      site1 = create_site!()
      site2 = create_site!()

      cat1 = create_media_category!(name: "Site1 Cat", site_id: site1.id)
      cat2 = create_media_category!(name: "Site2 Cat", site_id: site2.id)

      cat1
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site1.id)
      |> Ash.destroy!(authorize?: false)

      cat2
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id)
      |> Ash.destroy!(authorize?: false)

      %{results: archived} =
        MediaCategory
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      archived_ids = Enum.map(archived, & &1.id)
      assert cat1.id in archived_ids
      assert cat2.id in archived_ids
    end

    test "master_get_archived returns specific archived category" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      {:ok, archived} =
        category
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      result =
        MediaCategory
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.read_one!(authorize?: false)

      assert result.id == archived.id
      assert result.archived_at != nil
    end
  end

  describe "master update/unarchive actions" do
    test "master_update can update any category" do
      site = create_site!()
      category = create_media_category!(name: "Original", site_id: site.id)

      {:ok, updated} =
        category
        |> Ash.Changeset.for_update(:master_update, %{name: "Updated Name"}, authorize?: false)
        |> Ash.update()

      assert updated.name == "updated-name"
    end

    test "master_update fails with tenant context" do
      site = create_site!()
      category = create_media_category!(name: "Original", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               category
               |> Ash.Changeset.for_update(:master_update, %{name: "Updated Name"},
                 tenant: site.id
               )
               |> Ash.update()
    end

    test "master_unarchive can unarchive any category" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      {:ok, archived} =
        category
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      # Fetch the archived record using master_get_archived
      archived_record =
        MediaCategory
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.read_one!(authorize?: false)

      {:ok, restored} =
        archived_record
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update()

      assert restored.archived_at == nil
    end

    test "master_unarchive fails with tenant context" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      {:ok, archived} =
        category
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      # Fetch the archived record using master_get_archived
      archived_record =
        MediaCategory
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.read_one!(authorize?: false)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               archived_record
               |> Ash.Changeset.for_update(:master_unarchive, %{}, tenant: site.id)
               |> Ash.update()
    end
  end

  describe "master destroy actions" do
    test "master_destroy archives any category" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      {:ok, destroyed} =
        category
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      assert destroyed.archived_at != nil
    end

    test "master_destroy fails with tenant context" do
      site = create_site!()
      category = create_media_category!(name: "To Archive", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               category
               |> Ash.Changeset.for_destroy(:master_destroy, %{}, tenant: site.id)
               |> Ash.destroy(return_destroyed?: true)
    end

    test "master_permanent_destroy permanently deletes any category" do
      site = create_site!()
      category = create_media_category!(name: "To Delete", site_id: site.id)
      category_id = category.id

      :ok =
        category
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

      result = Ash.get(MediaCategory, category_id, action: :get_any, authorize?: false)
      assert match?({:error, _}, result)
    end

    test "master_permanent_destroy fails with tenant context" do
      site = create_site!()
      category = create_media_category!(name: "To Delete", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               category
               |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, tenant: site.id)
               |> Ash.destroy()
    end
  end

  describe "version actions" do
    test "get_with_versions returns category with paginated versions" do
      site = create_site!()
      category = create_media_category!(name: "Versioned Category", site_id: site.id)

      # Update to create versions
      {:ok, _} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated V1"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      result =
        MediaCategory
        |> Ash.Query.filter(id == ^category.id)
        |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == category.id
      assert is_list(result.sorted_versions)
    end

    test "master_get_with_versions returns category with versions for any site" do
      site = create_site!()
      category = create_media_category!(name: "Versioned Category", site_id: site.id)

      {:ok, _} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated V1"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      result =
        MediaCategory
        |> Ash.Query.filter(id == ^category.id)
        |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10}, authorize?: false)
        |> Ash.read_one!(authorize?: false)

      assert result.id == category.id
      assert is_list(result.sorted_versions)
    end

    test "list_versions returns paginated versions for a category" do
      site = create_site!()
      category = create_media_category!(name: "Versioned Category", site_id: site.id)

      {:ok, _} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "V2"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      %{results: results} =
        MediaCategory
        |> Ash.Query.for_read(:list_versions, %{category_id: category.id}, tenant: site.id)
        |> Ash.read!(authorize?: false)

      assert length(results) >= 1
    end

    test "master_list_versions returns versions for any category" do
      site = create_site!()
      category = create_media_category!(name: "Versioned Category", site_id: site.id)

      {:ok, _} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "V2"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      %{results: results} =
        MediaCategory
        |> Ash.Query.for_read(:master_list_versions, %{category_id: category.id},
          authorize?: false
        )
        |> Ash.read!(authorize?: false)

      assert length(results) >= 1
    end
  end

  describe "restore_version action" do
    test "restore_version restores category to a previous version" do
      site = create_site!()
      category = create_media_category!(name: "Original Name", site_id: site.id)

      # Update to create version
      {:ok, updated} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      # Get versions
      versions =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^updated.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      original_version = List.first(versions)

      {:ok, restored} =
        updated
        |> Ash.Changeset.for_update(:restore_version, %{version_id: original_version.id},
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      assert restored.name == "original-name"
    end
  end

  describe "restore_version_api action (generic action)" do
    test "restore_version_api restores category from specific version" do
      site = create_site!()
      category = create_media_category!(name: "Original Name", site_id: site.id)

      {:ok, updated} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      versions =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^updated.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      original_version = List.first(versions)

      {:ok, restored} =
        MediaCategory
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{
            id: updated.id,
            version_id: original_version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.name == "original-name"
    end
  end

  describe "master_restore_version action (generic action)" do
    test "master_restore_version restores any category from specific version" do
      site = create_site!()
      category = create_media_category!(name: "Original Name", site_id: site.id)

      {:ok, updated} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      versions =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^updated.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      original_version = List.first(versions)

      {:ok, restored} =
        MediaCategory
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: updated.id,
            version_id: original_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert restored.name == "original-name"
    end
  end

  describe "preview_version action (generic action)" do
    test "preview_version shows category as it would be at a specific version" do
      site = create_site!()
      category = create_media_category!(name: "Original Name", site_id: site.id)

      {:ok, updated} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      versions =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^updated.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      original_version = List.first(versions)

      {:ok, preview} =
        MediaCategory
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            category_id: updated.id,
            version_id: original_version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert preview.name == "original-name"
      # Original in database should be unchanged
      current = Ash.get!(MediaCategory, updated.id, action: :get_any, authorize?: false)
      assert current.name == "updated-name"
    end
  end

  describe "master_preview_version action (generic action)" do
    test "master_preview_version shows any category at a specific version" do
      site = create_site!()
      category = create_media_category!(name: "Original Name", site_id: site.id)

      {:ok, updated} =
        category
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      versions =
        MishkaCmsCore.Runtime.MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^updated.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      original_version = List.first(versions)

      {:ok, preview} =
        MediaCategory
        |> Ash.ActionInput.for_action(
          :master_preview_version,
          %{
            category_id: updated.id,
            version_id: original_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert preview.name == "original-name"
    end
  end
end
