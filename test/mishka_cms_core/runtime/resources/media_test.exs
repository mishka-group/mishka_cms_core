# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.MediaTest do
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  alias MishkaCmsCore.Runtime.Media
  require Ash.Query
  @moduletag :unit

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its media" do
      site = create_site!()
      create_media!(site_id: site.id)

      count = fn ->
        Media |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false) |> length()
      end

      assert count.() == 1
      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
      assert count.() == 0
    end
  end

  describe "configuration" do
    test "resource has correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(Media) == "media"
      assert AshPostgres.DataLayer.Info.repo(Media) == @repo
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(Media)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(Media) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(Media) == :site_id
      assert Ash.Resource.Info.multitenancy_global?(Media) == false
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      media = create_media!(site_id: site.id) |> Ash.reload!(authorize?: false)

      media_list =
        Media
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped media in media_list

      archived_media = Ash.destroy!(media, authorize?: false)

      media_list =
        Media
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived_media not in media_list
    end
  end

  describe "create action" do
    test "creates a media with valid attributes" do
      site = create_site!()

      attrs = %{
        name: "Photo Album",
        type: :images,
        size: 1024,
        format: "jpg"
      }

      assert {:ok, media} =
               Media
               |> Ash.Changeset.for_create(:create, attrs,
                 tenant: site.id,
                 private_arguments: %{stored_path: "/uploads/photo.jpg"}
               )
               |> Ash.create(authorize?: false)

      assert media.name == "photo-album"
      assert media.type == :images
      assert media.size == 1024
      assert media.format == "jpg"
      assert media.relative_path == "/uploads/photo.jpg"
      assert media.site_id == site.id
    end

    # NOTHING WAS GIVEN, SO NOTHING IS NAMED. `Ash.Changeset.add_error/2` hands `:value` on whether
    # or not it was given one, so the keyword form printed "Value: nil" under every upload refusal —
    # a line that says nothing here and, where there IS an upload, describes it as nil. The struct
    # form leaves the line out, which is the honest answer when the value is a temporary path
    # nobody reading the refusal can use.
    test "an upload with no file is refused without a value line" do
      site = create_site!()

      assert {:error, refused} =
               Media
               |> Ash.Changeset.for_create(:form_upload, %{}, tenant: site.id)
               |> Ash.create(authorize?: false)

      message = Exception.message(refused)

      assert message =~ "Please select a file to upload"
      refute message =~ "Value: nil"
    end

    test "validates required fields" do
      site = create_site!()

      changeset =
        Media
        |> Ash.Changeset.for_create(:create, %{}, tenant: site.id)

      # Media also requires name, type, size and format via present validation
      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          [:name, :type, :size, :format] -- error.fields == []
      end)

      # and the path, which only the code that stored the file gives
      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.Required and error.field == :stored_path
      end)
    end

    test "validates name length constraints" do
      site = create_site!()

      # Name too long (more than 255 characters)
      long_name = String.duplicate("a", 256)

      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: long_name,
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/test.jpg"}
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :name
      end)
    end

    test "enforces unique name per site constraint" do
      site = create_site!()

      # Create first media
      create_media!(name: "UniquePhoto", site_id: site.id)

      # Try to create another with same name for same site
      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "UniquePhoto",
            type: :images,
            size: 2048,
            format: "png"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/unique2.png"}
        )

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

      # Create media with same name on site1
      media1 =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Shared Name",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site1.id,
          private_arguments: %{stored_path: "/uploads/shared1.jpg"}
        )
        |> Ash.create!(authorize?: false)

      # Should succeed with same name on site2
      media2 =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Shared Name",
            type: :images,
            size: 2048,
            format: "png"
          },
          tenant: site2.id,
          private_arguments: %{stored_path: "/uploads/shared2.png"}
        )
        |> Ash.create!(authorize?: false)

      assert media1.name == media2.name
      assert media1.site_id != media2.site_id
    end

    test "applies slugification to name" do
      site = create_site!()

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "My Special Media!",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/special.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.name == "my-special-media"
    end

    test "description is optional" do
      site = create_site!()

      # Create without description
      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "No Description",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/nodesc.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.description == nil
    end

    test "validates description max length (1000 characters)" do
      site = create_site!()

      # Description too long (more than 1000 characters)
      long_description = String.duplicate("a", 1001)

      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Long Description",
            type: :images,
            size: 1024,
            format: "jpg",
            description: long_description
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/long.jpg"}
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :description
      end)

      # Description with exactly 1000 characters should succeed
      exact_description = String.duplicate("b", 1000)

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Exact Description",
            type: :images,
            size: 1024,
            format: "jpg",
            description: exact_description
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/exact.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert String.length(media.description) == 1000
    end

    test "validates media type is one of allowed values" do
      site = create_site!()

      # Valid types
      for type <- [:images, :videos, :documents] do
        media =
          Media
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test #{type}",
              type: type,
              size: 1024,
              format: "test"
            },
            tenant: site.id,
            private_arguments: %{stored_path: "/uploads/#{type}.test"}
          )
          |> Ash.create!(authorize?: false)

        assert media.type == type
      end
    end

    test "validates size is positive" do
      site = create_site!()

      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Invalid Size",
            type: :images,
            size: 0,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/invalid.jpg"}
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :size
      end)
    end

    test "dimensions is optional" do
      site = create_site!()

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "No Dimensions",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/nodim.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.dimensions == %{}
    end

    test "accepts valid dimensions map" do
      site = create_site!()

      dimensions = %{width: 1920, height: 1080, unit: "px"}

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "With Dimensions",
            type: :images,
            size: 1024,
            format: "jpg",
            dimensions: dimensions
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/withdim.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.dimensions.width == 1920
      assert media.dimensions.height == 1080
      assert media.dimensions.unit == "px"
    end

    test "featured defaults to false" do
      site = create_site!()

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Not Featured",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/notfeatured.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.featured == false
    end

    test "can set featured to true" do
      site = create_site!()

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Featured",
            type: :images,
            size: 1024,
            format: "jpg",
            featured: true
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/featured.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.featured == true
    end

    test "enforces unique path per site constraint" do
      site = create_site!()

      # Create first media
      create_media!(
        name: "First",
        relative_path: "/uploads/unique.jpg",
        site_id: site.id
      )

      # Try to create another with same path for same site
      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Second",
            type: :images,
            size: 2048,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/unique.jpg"}
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute and
                 e.field == :relative_path
             end)
    end
  end

  describe "update action" do
    test "updates a non-archived media successfully" do
      site = create_site!()
      media = create_media!(name: "Original", site_id: site.id)

      assert {:ok, updated} =
               media
               |> Ash.Changeset.for_update(:update, %{
                 name: "Updated Media",
                 description: "New description"
               })
               |> Ash.update(authorize?: false)

      assert updated.name == "updated-media"
      assert updated.description == "New description"
    end

    test "prevents updating archived media" do
      site = create_site!()
      media = create_media!(name: "To Archive", site_id: site.id)

      # Archive it
      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      # Try to update archived media
      changeset =
        archived
        |> Ash.Changeset.for_update(:update, %{name: "New Name"})

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          :archived_at in error.fields
      end)
    end

    test "validates name length on update" do
      site = create_site!()
      media = create_media!(name: "Original", site_id: site.id)

      # Try to update with too long name
      long_name = String.duplicate("a", 256)

      changeset =
        media
        |> Ash.Changeset.for_update(:update, %{name: long_name})

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :name
      end)
    end

    test "enforces unique name constraint on update" do
      site = create_site!()
      _media1 = create_media!(name: "Media One", site_id: site.id)
      media2 = create_media!(name: "Media Two", site_id: site.id)

      # Try to update media2 to have same name as media1
      changeset =
        media2
        |> Ash.Changeset.for_update(:update, %{name: "Media One"})

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

    test "default read with tenant shows only site-specific media", context do
      %{site1: site1, site2: site2} = context

      media1 =
        create_media!(name: "Site1 Media", site_id: site1.id) |> Ash.reload!(authorize?: false)

      media2 =
        create_media!(name: "Site2 Media", site_id: site2.id) |> Ash.reload!(authorize?: false)

      # Query with site1 tenant
      site1_media =
        Media
        |> Ash.Query.set_tenant(site1.id)
        |> Ash.read!(authorize?: false)

      assert_stripped media1 in site1_media
      assert_stripped media2 not in site1_media

      # Query with site2 tenant
      site2_media =
        Media
        |> Ash.Query.set_tenant(site2.id)
        |> Ash.read!(authorize?: false)

      assert_stripped media2 in site2_media
      assert_stripped media1 not in site2_media
    end

    test "archived action filters archived media", context do
      %{site1: site1} = context

      active = create_media!(name: "Active", site_id: site1.id) |> Ash.reload!(authorize?: false)
      to_archive = create_media!(name: "To Archive", site_id: site1.id)

      {:ok, archived} = Ash.destroy(to_archive, authorize?: false, return_destroyed?: true)
      # Reload archived using master_get which bypasses archival filter
      archived = Ash.get!(Media, archived.id, action: :master_get, authorize?: false)

      %{results: archived_media} =
        Media
        |> Ash.Query.for_read(:archived, %{}, tenant: site1.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived in archived_media
      assert_stripped active not in archived_media
    end

    test "get_archived retrieves archived media by id", context do
      %{site1: site1} = context

      media = create_media!(name: "To Archive", site_id: site1.id)
      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      result =
        Media
        |> Ash.Query.for_read(:get_archived, %{}, tenant: site1.id)
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == archived.id
      assert result.archived_at != nil
    end

    test "get_any bypasses multitenancy" do
      site1 = create_site!()
      site2 = create_site!()

      media1 =
        create_media!(name: "Site1 Media", site_id: site1.id) |> Ash.reload!(authorize?: false)

      media2 =
        create_media!(name: "Site2 Media", site_id: site2.id) |> Ash.reload!(authorize?: false)

      # Should be able to get media1 without tenant context
      result = Ash.get!(Media, media1.id, action: :get_any, authorize?: false)
      assert result.id == media1.id

      # Should be able to get media2 without tenant context
      result2 = Ash.get!(Media, media2.id, action: :get_any, authorize?: false)
      assert result2.id == media2.id
    end

    test "master_get bypasses multitenancy and archival filters" do
      site = create_site!()
      media = create_media!(name: "To Archive", site_id: site.id)

      # Archive it
      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      # master_get should be able to get archived media
      result = Ash.get!(Media, archived.id, action: :master_get, authorize?: false)
      assert result.id == archived.id
      assert result.archived_at != nil
    end

    test "by_type filters media by type", context do
      %{site1: site1} = context

      image =
        create_media!(name: "Image", type: :images, site_id: site1.id)
        |> Ash.reload!(authorize?: false)

      video =
        create_media!(name: "Video", type: :videos, site_id: site1.id)
        |> Ash.reload!(authorize?: false)

      document =
        create_media!(name: "Document", type: :documents, site_id: site1.id)
        |> Ash.reload!(authorize?: false)

      images =
        Media
        |> Ash.Query.for_read(:by_type, %{type: :images})
        |> Ash.Query.set_tenant(site1.id)
        |> Ash.read!(authorize?: false)

      assert_stripped image in images
      assert_stripped video not in images
      assert_stripped document not in images
    end
  end

  describe "archive/unarchive actions" do
    test "destroy archives a media (sets archived_at)" do
      site = create_site!()
      media = create_media!(name: "To Archive", site_id: site.id)

      assert media.archived_at == nil

      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      assert archived.archived_at != nil
    end

    test "unarchive restores a media" do
      site = create_site!()
      media = create_media!(name: "To Restore", site_id: site.id)

      # Archive it
      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)
      assert archived.archived_at != nil

      # Unarchive it
      {:ok, restored} =
        archived
        |> Ash.Changeset.for_update(:unarchive, %{})
        |> Ash.update(authorize?: false)

      assert restored.archived_at == nil
    end

    test "permanent_destroy actually deletes the record" do
      site = create_site!()
      media = create_media!(name: "To Delete", site_id: site.id)
      media_id = media.id

      # Permanent destroy
      :ok =
        media
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{})
        |> Ash.destroy!(authorize?: false)

      # Verify it's gone
      result = Ash.get(Media, media_id, action: :get_any, authorize?: false)
      assert match?({:error, _}, result)
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()

      # Test name_length_check (name must be 1-255 characters)
      assert_raise Ecto.ConstraintError, fn ->
        %MishkaCmsCore.Runtime.Media{}
        |> Ecto.Changeset.change(%{
          id: Ash.UUID.generate(),
          name: "",
          type: :images,
          size: 1024,
          format: "jpg",
          relative_path: "/uploads/test.jpg",
          site_id: site.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })
        |> @repo.insert()
      end

      # Test size_positive_check
      assert_raise Ecto.ConstraintError, fn ->
        %MishkaCmsCore.Runtime.Media{}
        |> Ecto.Changeset.change(%{
          id: Ash.UUID.generate(),
          name: "test",
          type: :images,
          size: 0,
          format: "jpg",
          relative_path: "/uploads/test.jpg",
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

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Media",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/test.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media.description == nil
      assert media.featured == false
      assert media.dimensions == %{}
      assert media.archived_at == nil
      assert media.inserted_at != nil
      assert media.updated_at != nil
    end
  end

  describe "complex scenarios" do
    test "handles media with full attributes" do
      site = create_site!()
      category = create_media_category!(site_id: site.id)

      attrs = %{
        name: "Full Featured Media",
        type: :images,
        size: 2048,
        format: "png",
        featured: true,
        dimensions: %{width: 1920, height: 1080, unit: "px"},
        description: "A comprehensive test media with all options",
        media_category_id: category.id
      }

      media =
        Media
        |> Ash.Changeset.for_create(:create, attrs,
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/full.png"}
        )
        |> Ash.create!(authorize?: false)

      assert media.name == "full-featured-media"
      assert media.type == :images
      assert media.size == 2048
      assert media.format == "png"
      assert media.featured == true
      assert media.dimensions.width == 1920
      assert media.relative_path == "/uploads/full.png"
      assert media.description == "A comprehensive test media with all options"
      assert media.site_id == site.id
      assert media.media_category_id == category.id
    end

    test "allows same name for archived and active media within same site" do
      site = create_site!()

      # Create and archive a media
      media1 = create_media!(name: "Duplicate Name", site_id: site.id)
      Ash.destroy!(media1, authorize?: false)

      # Should be able to create another with same name since first is archived
      media2 =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Duplicate Name",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/duplicate2.jpg"}
        )
        |> Ash.create!(authorize?: false)

      assert media2.name == "duplicate-name"
    end

    test "prevents unarchiving when active media with same name exists" do
      site = create_site!()

      # Create and archive media
      media1 = create_media!(name: "Conflict Name", site_id: site.id)
      {:ok, archived} = Ash.destroy(media1, authorize?: false, return_destroyed?: true)

      # Create new active media with same name
      _media2 = create_media!(name: "Conflict Name", site_id: site.id)

      # Try to unarchive - should fail due to unique constraint
      changeset = Ash.Changeset.for_update(archived, :unarchive, %{})

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
      media = create_media!(name: "Test Media", site_id: site.id)

      loaded_media =
        Media
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.Query.load(:site)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert loaded_media.site.id == site.id
      assert loaded_media.site.name == site.name
    end

    test "belongs_to media_category relationship" do
      site = create_site!()
      category = create_media_category!(name: "Images", site_id: site.id)

      media =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Photo",
            type: :images,
            size: 1024,
            format: "jpg",
            media_category_id: category.id
          },
          tenant: site.id,
          authorize?: false,
          private_arguments: %{stored_path: "/uploads/photo.jpg"}
        )
        |> Ash.create!()

      loaded_media =
        Media
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.Query.load(:media_category)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert loaded_media.media_category.id == category.id
      assert loaded_media.media_category.name == category.name
    end
  end

  describe "identities" do
    test "unique_name_per_site identity enforces uniqueness" do
      site = create_site!()

      create_media!(name: "Unique Media", site_id: site.id)

      # Try to create duplicate
      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Unique Media",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/unique2.jpg"}
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute and
                 e.field == :name
             end)
    end

    test "unique_path_per_site identity enforces uniqueness" do
      site = create_site!()

      create_media!(
        name: "First Media",
        relative_path: "/uploads/unique-path.jpg",
        site_id: site.id
      )

      # Try to create duplicate with same path
      changeset =
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Second Media",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/unique-path.jpg"}
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(changeset, authorize?: false)

      assert Enum.any?(errors, fn e ->
               e.__struct__ == Ash.Error.Changes.InvalidAttribute and
                 e.field == :relative_path
             end)
    end
  end

  describe "JSON API configuration" do
    test "has correct JSON API type" do
      assert AshJsonApi.Resource.Info.type(Media) == "media"
    end
  end

  describe "master_create action" do
    test "creates media with explicit site_id (no tenant context)" do
      site = create_site!()

      attrs = %{
        name: "Master Media",
        type: :images,
        size: 1024,
        format: "jpg",
        site_id: site.id
      }

      assert {:ok, media} =
               Media
               |> Ash.Changeset.for_create(:master_create, attrs,
                 private_arguments: %{stored_path: "/uploads/master.jpg"},
                 authorize?: false
               )
               |> Ash.create(authorize?: false)

      assert media.name == "master-media"
      assert media.site_id == site.id
    end

    test "requires site_id in attributes" do
      changeset =
        Media
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "No Site",
            type: :images,
            size: 1024,
            format: "jpg"
          },
          private_arguments: %{stored_path: "/uploads/nosite.jpg"},
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges
      end)
    end

    test "fails when tenant is provided" do
      site = create_site!()

      attrs = %{
        name: "With Tenant",
        type: :images,
        size: 1024,
        format: "jpg",
        site_id: site.id
      }

      changeset =
        Media
        |> Ash.Changeset.for_create(:master_create, attrs,
          tenant: site.id,
          private_arguments: %{stored_path: "/uploads/tenant.jpg"}
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges
      end)
    end
  end

  describe "master_read action" do
    test "reads all media bypassing multitenancy" do
      site1 = create_site!()
      site2 = create_site!()

      media1 =
        create_media!(name: "Site1 Media", site_id: site1.id) |> Ash.reload!(authorize?: false)

      media2 =
        create_media!(name: "Site2 Media", site_id: site2.id) |> Ash.reload!(authorize?: false)

      %{results: all_media} =
        Media
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      assert_stripped media1 in all_media
      assert_stripped media2 in all_media
    end

    test "fails when tenant is provided" do
      site = create_site!()

      # Validation happens during for_read when tenant is passed
      query =
        Media
        |> Ash.Query.for_read(:master_read, %{}, tenant: site.id)

      assert_has_error(query, fn error ->
        error.__struct__ == Ash.Error.Query.InvalidQuery
      end)
    end
  end

  describe "master_get action" do
    test "gets media by ID bypassing multitenancy" do
      site = create_site!()
      media = create_media!(name: "Get Test", site_id: site.id)

      result = Ash.get!(Media, media.id, action: :master_get, authorize?: false)
      assert result.id == media.id
    end

    test "gets archived media" do
      site = create_site!()
      media = create_media!(name: "To Archive", site_id: site.id)
      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      result = Ash.get!(Media, archived.id, action: :master_get, authorize?: false)
      assert result.id == archived.id
      assert result.archived_at != nil
    end
  end

  describe "master_archived action" do
    test "lists all archived media bypassing multitenancy" do
      site1 = create_site!()
      site2 = create_site!()

      media1 = create_media!(name: "Site1 To Archive", site_id: site1.id)
      media2 = create_media!(name: "Site2 To Archive", site_id: site2.id)

      {:ok, archived1} = Ash.destroy(media1, authorize?: false, return_destroyed?: true)
      {:ok, archived2} = Ash.destroy(media2, authorize?: false, return_destroyed?: true)

      # Use master_get which bypasses archival filter
      archived1 = Ash.get!(Media, archived1.id, action: :master_get, authorize?: false)
      archived2 = Ash.get!(Media, archived2.id, action: :master_get, authorize?: false)

      %{results: all_archived} =
        Media
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      assert_stripped archived1 in all_archived
      assert_stripped archived2 in all_archived
    end
  end

  describe "master_get_archived action" do
    test "gets single archived media bypassing multitenancy" do
      site = create_site!()
      media = create_media!(name: "To Get Archived", site_id: site.id)
      {:ok, archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      result =
        Media
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == archived.id
      assert result.archived_at != nil
    end
  end

  describe "by_category action" do
    test "filters media by category" do
      site = create_site!()
      category1 = create_media_category!(name: "Images", site_id: site.id)
      category2 = create_media_category!(name: "Videos", site_id: site.id)

      media1 =
        create_media!(name: "In Category1", media_category_id: category1.id, site_id: site.id)
        |> Ash.reload!(authorize?: false)

      media2 =
        create_media!(name: "In Category2", media_category_id: category2.id, site_id: site.id)
        |> Ash.reload!(authorize?: false)

      category1_media =
        Media
        |> Ash.Query.for_read(:by_category, %{media_category_id: category1.id}, authorize?: false)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped media1 in category1_media
      assert_stripped media2 not in category1_media
    end
  end

  describe "read_any action" do
    test "reads all media bypassing multitenancy (internal)" do
      site1 = create_site!()
      site2 = create_site!()

      media1 = create_media!(name: "Site1", site_id: site1.id) |> Ash.reload!(authorize?: false)
      media2 = create_media!(name: "Site2", site_id: site2.id) |> Ash.reload!(authorize?: false)

      %{results: all_media} =
        Media
        |> Ash.Query.for_read(:read_any)
        |> Ash.read!(authorize?: false)

      assert_stripped media1 in all_media
      assert_stripped media2 in all_media
    end
  end

  describe "master_update action" do
    test "updates media bypassing tenant context" do
      site = create_site!()
      media = create_media!(name: "To Update", site_id: site.id)

      updated =
        media
        |> Ash.Changeset.for_update(:master_update, %{name: "Master Updated"}, authorize?: false)
        |> Ash.update!()

      assert updated.name == "master-updated"
    end

    test "fails with tenant context" do
      site = create_site!()
      media = create_media!(name: "To Update", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      result =
        media
        |> Ash.Changeset.for_update(:master_update, %{name: "With Tenant"}, tenant: site.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "master_destroy action" do
    test "archives media bypassing tenant context" do
      site = create_site!()
      media = create_media!(name: "To Destroy", site_id: site.id)

      {:ok, destroyed} =
        media
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      assert destroyed.archived_at != nil
    end

    test "fails with tenant context" do
      site = create_site!()
      media = create_media!(name: "To Destroy", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      result =
        media
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, tenant: site.id)
        |> Ash.destroy(return_destroyed?: true)

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "master_unarchive action" do
    test "unarchives media bypassing tenant context" do
      site = create_site!()
      media = create_media!(name: "To Unarchive", site_id: site.id)
      {:ok, _archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      # Get the archived record using master_get_archived
      archived_record =
        Media
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.read_one!(authorize?: false)

      {:ok, restored} =
        archived_record
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update()

      assert restored.archived_at == nil
    end

    test "fails for non-archived media" do
      site = create_site!()
      media = create_media!(name: "Not Archived", site_id: site.id)

      changeset =
        media
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)

      assert {:error, _} = Ash.update(changeset)
    end

    test "fails with tenant context" do
      site = create_site!()
      media = create_media!(name: "To Unarchive", site_id: site.id)
      {:ok, _archived} = Ash.destroy(media, authorize?: false, return_destroyed?: true)

      # Get the archived record using master_get_archived
      archived_record =
        Media
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.read_one!(authorize?: false)

      # Note: authorize? must not be false for TenantContext validation to trigger
      result =
        archived_record
        |> Ash.Changeset.for_update(:master_unarchive, %{}, tenant: site.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "master_permanent_destroy action" do
    test "permanently deletes media bypassing tenant context" do
      site = create_site!()
      media = create_media!(name: "To Permanently Delete", site_id: site.id)
      media_id = media.id

      :ok =
        media
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

      assert {:error, _} = Ash.get(Media, media_id, action: :get_any, authorize?: false)
    end

    test "fails with tenant context" do
      site = create_site!()
      media = create_media!(name: "To Permanently Delete", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      result =
        media
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, tenant: site.id)
        |> Ash.destroy()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "version actions" do
    import MishkaCmsCore.Test.VersionHelpers

    test "get_with_versions loads sorted versions (tenant)" do
      site = create_site!()
      media = create_media!(name: "With Versions", site_id: site.id)

      # Update to create versions
      media
      |> Ash.Changeset.for_update(:update, %{description: "First update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Second update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 3)

      result =
        Media
        |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == media.id
      assert length(result.sorted_versions) >= 1
    end

    test "master_get_with_versions loads versions bypassing tenant" do
      site = create_site!()
      media = create_media!(name: "Master Versions", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      result =
        Media
        |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10}, authorize?: false)
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == media.id
      assert length(result.sorted_versions) >= 1
    end

    test "list_versions lists versions for a media (tenant)" do
      site = create_site!()
      media = create_media!(name: "List Versions", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      %{results: results} =
        Media
        |> Ash.Query.for_read(:list_versions, %{media_id: media.id}, tenant: site.id)
        |> Ash.read!(authorize?: false)

      assert length(results) == 1
      assert hd(results).id == media.id
    end

    test "master_list_versions lists versions bypassing tenant" do
      site = create_site!()
      media = create_media!(name: "Master List Versions", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      %{results: results} =
        Media
        |> Ash.Query.for_read(:master_list_versions, %{media_id: media.id}, authorize?: false)
        |> Ash.read!(authorize?: false)

      assert length(results) == 1
    end

    test "restore_version restores media to a previous version (tenant)" do
      site = create_site!()
      media = create_media!(name: "Restore Test", description: "Original", site_id: site.id)
      original_description = media.description

      # Update to create a version
      updated =
        media
        |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      # Get the first version (create version)
      version = first_version(MishkaCmsCore.Runtime.Media.Version, media.id)

      # Restore to original version
      {:ok, restored} =
        updated
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id}, tenant: site.id)
        |> Ash.update(authorize?: false)

      assert restored.description == original_description
    end

    test "restore_version_api restores via API (tenant)" do
      site = create_site!()
      media = create_media!(name: "API Restore", description: "Original", site_id: site.id)

      updated =
        media
        |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Media.Version, media.id)

      {:ok, restored} =
        Media
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{
            id: updated.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.description == media.description
    end

    test "master_restore_version restores bypassing tenant" do
      site = create_site!()
      media = create_media!(name: "Master Restore", description: "Original", site_id: site.id)

      updated =
        media
        |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Media.Version, media.id)

      {:ok, restored} =
        Media
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: updated.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert restored.description == media.description
    end

    test "preview_version previews a version without restoring (tenant)" do
      site = create_site!()
      media = create_media!(name: "Preview Test", description: "Original", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Media.Version, media.id)

      {:ok, preview} =
        Media
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            media_id: media.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert preview.description == "Original"

      # Verify original wasn't changed
      current = Ash.get!(Media, media.id, action: :get_any, authorize?: false)
      assert current.description == "Changed"
    end

    test "master_preview_version previews bypassing tenant" do
      site = create_site!()
      media = create_media!(name: "Master Preview", description: "Original", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Media.Version, media.id)

      {:ok, preview} =
        Media
        |> Ash.ActionInput.for_action(
          :master_preview_version,
          %{
            media_id: media.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert preview.description == "Original"
    end
  end

  describe "calculations" do
    import MishkaCmsCore.Test.VersionHelpers

    test "version_count returns number of versions" do
      site = create_site!()
      media = create_media!(name: "Count Test", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Update 1"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Update 2"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 3)

      loaded =
        Media
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.Query.load(:version_count)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert loaded.version_count == 3
    end

    test "latest_version returns most recent version" do
      site = create_site!()
      media = create_media!(name: "Latest Test", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Final"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      loaded =
        Media
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.Query.load(:latest_version)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert loaded.latest_version != nil
      assert loaded.latest_version.changes["description"] == "Final"
    end

    test "recent_versions returns up to 10 most recent versions" do
      site = create_site!()
      media = create_media!(name: "Recent Test", site_id: site.id)

      media
      |> Ash.Changeset.for_update(:update, %{description: "Update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("media_versions", media.id, 2)

      loaded =
        Media
        |> Ash.Query.filter(id == ^media.id)
        |> Ash.Query.load(:recent_versions)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read_one!(authorize?: false)

      assert is_list(loaded.recent_versions)
      assert length(loaded.recent_versions) >= 1
    end
  end
end
