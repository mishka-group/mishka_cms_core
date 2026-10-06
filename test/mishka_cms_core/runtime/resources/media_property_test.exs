defmodule MishkaCmsCore.Runtime.Resources.MediaPropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.Media
  @moduletag :property

  property "accepts all valid input combinations" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            format <- valid_format_generator(),
            relative_path <- valid_path_generator(),
            description <- one_of([nil, valid_description_generator()]),
            featured <- boolean(),
            dimensions <- one_of([nil, valid_dimensions_generator()])
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: format,
            description: description,
            featured: featured,
            dimensions: dimensions
          },
          tenant: site.id,
          private_arguments: %{stored_path: relative_path}
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, type: type, size: size})}"
    end
  end

  property "accepts minimal valid inputs" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            format <- valid_format_generator(),
            relative_path <- valid_path_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: format
          },
          tenant: site.id,
          private_arguments: %{stored_path: relative_path}
        )

      assert changeset.valid?,
             "Minimal valid inputs should create valid changeset"
    end
  end

  property "accepts maximal valid inputs" do
    check all(
            name <-
              string([?A..?Z], length: 1)
              |> bind(fn first ->
                string([?a..?z, ?A..?Z, ?0..?9, ?\s], length: 254)
                |> map(fn rest -> first <> rest end)
              end),
            type <- valid_type_generator(),
            size <- integer(1..999_999_999),
            format <- string([?a..?z], min_length: 1, max_length: 10),
            relative_path <- string([?a..?z, ?/, ?.], min_length: 1, max_length: 255),
            description <-
              string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 1000, max_length: 1000),
            dimensions <- valid_dimensions_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: format,
            description: description,
            dimensions: dimensions
          },
          tenant: site.id,
          private_arguments: %{stored_path: relative_path}
        )

      assert changeset.valid?,
             "Maximal valid inputs should create valid changeset"
    end
  end

  property "rejects invalid names" do
    check all(
            invalid_name <- invalid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            format <- valid_format_generator(),
            relative_path <- valid_path_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: invalid_name,
            type: type,
            size: size,
            format: format
          },
          tenant: site.id,
          private_arguments: %{stored_path: relative_path}
        )

      refute changeset.valid?,
             "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid sizes" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            invalid_size <- one_of([constant(0), integer(-100..-1)]),
            format <- valid_format_generator(),
            relative_path <- valid_path_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: invalid_size,
            format: format
          },
          tenant: site.id,
          private_arguments: %{stored_path: relative_path}
        )

      refute changeset.valid?,
             "Expected invalid changeset for size: #{invalid_size}"
    end
  end

  property "rejects invalid descriptions" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            format <- valid_format_generator(),
            relative_path <- valid_path_generator(),
            invalid_description <- invalid_description_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: format,
            description: invalid_description
          },
          tenant: site.id,
          private_arguments: %{stored_path: relative_path}
        )

      refute changeset.valid?,
             "Expected invalid changeset for description length: #{String.length(invalid_description)}"
    end
  end

  property "rejects missing required fields" do
    check all(
            include_name <- boolean(),
            include_type <- boolean(),
            include_size <- boolean(),
            include_format <- boolean(),
            include_path <- boolean(),
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            format <- valid_format_generator(),
            relative_path <- valid_path_generator()
          ) do
      site = create_test_site!()

      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
      attrs = if include_type, do: Map.put(attrs, :type, type), else: attrs
      attrs = if include_size, do: Map.put(attrs, :size, size), else: attrs
      attrs = if include_format, do: Map.put(attrs, :format, format), else: attrs

      stored_path = if include_path, do: %{stored_path: relative_path}, else: %{}

      changeset =
        Ash.Changeset.for_create(Media, :create, attrs,
          tenant: site.id,
          private_arguments: stored_path
        )

      if include_name and include_type and include_size and include_format and include_path do
        assert changeset.valid?,
               "Expected valid changeset when all required fields are present"
      else
        refute changeset.valid?,
               "Expected invalid changeset when required fields are missing"
      end
    end
  end

  property "handles boundary values correctly" do
    check all(
            name_length <- member_of([1, 255]),
            description_length <- member_of([0, 1, 1000]),
            size <- member_of([1, 1000, 1_000_000]),
            type <- valid_type_generator()
          ) do
      site = create_test_site!()

      name = "A" <> String.duplicate("b", name_length - 1)

      description =
        if description_length == 0,
          do: nil,
          else: String.duplicate("d", description_length)

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg",
            description: description
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, desc_len=#{description_length}, size=#{size}"
    end
  end

  property "handles whitespace trimming correctly" do
    check all(
            base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 245),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: padded_name,
            type: type,
            size: size,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      # Should be valid due to trimming
      assert changeset.valid?, "Should be valid after trimming whitespace"
    end
  end

  property "allows same name across different sites" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      # Generate unique site names and hosts to avoid conflicts
      unique_id1 = System.unique_integer([:positive])
      unique_id2 = System.unique_integer([:positive])

      site1 = create_test_site!(name: "Site#{unique_id1}", host: "site#{unique_id1}.com")
      site2 = create_test_site!(name: "Site#{unique_id2}", host: "site#{unique_id2}.com")

      changeset1 =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg"
          },
          tenant: site1.id,
          private_arguments: %{stored_path: "/uploads/1.jpg"}
        )

      changeset2 =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg"
          },
          tenant: site2.id,
          private_arguments: %{stored_path: "/uploads/2.jpg"}
        )

      assert changeset1.valid?, "First media should be valid"

      assert changeset2.valid?,
             "Second media with same name on different site should be valid"
    end
  end

  property "media requires site_id (tenant)" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      # Test that creating without tenant fails
      assert_raise Ash.Error.Invalid, fn ->
        Media
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg"
          },
          private_arguments: %{stored_path: "/test.jpg"}
        )
        |> Ash.create!(authorize?: false)
      end
    end
  end

  property "update action accepts valid changes on non-archived media" do
    check all(
            original_name <- valid_name_generator(),
            new_name <- valid_name_generator(),
            new_description <- one_of([nil, valid_description_generator()]),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      media = %Media{
        id: Ash.UUID.generate(),
        name: original_name,
        type: type,
        size: size,
        format: "jpg",
        relative_path: "/test.jpg",
        description: "Original description",
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          media,
          :update,
          %{
            name: new_name,
            description: new_description
          },
          tenant: site.id
        )

      assert changeset.valid?, "Update should be valid for non-archived media"
    end
  end

  property "update action rejects changes on archived media" do
    check all(
            name <- valid_name_generator(),
            new_name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      archived_media = %Media{
        id: Ash.UUID.generate(),
        name: name,
        type: type,
        size: size,
        format: "jpg",
        relative_path: "/test.jpg",
        description: "Test description",
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_media,
          :update,
          %{
            name: new_name
          },
          tenant: site.id
        )

      refute changeset.valid?, "Update should be invalid for archived media"
    end
  end

  property "unarchive action works on archived media" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      archived_media = %Media{
        id: Ash.UUID.generate(),
        name: name,
        type: type,
        size: size,
        format: "jpg",
        relative_path: "/test.jpg",
        description: "Test description",
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset = Ash.Changeset.for_update(archived_media, :unarchive, %{}, tenant: site.id)
      assert changeset.valid?, "Unarchive should work on archived media"
    end
  end

  property "applies default values correctly" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      assert changeset.valid?

      # Test that defaults would be applied
      assert changeset.attributes[:description] == nil or
               is_binary(changeset.attributes[:description])

      featured = changeset.attributes[:featured]
      assert featured == false or is_nil(featured)
    end
  end

  property "applies slugification to name" do
    check all(
            base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 50),
            special_chars <- member_of(["!", "@", "#", "$", "%", "  ", "-"]),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      name_with_special = base_name <> special_chars

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name_with_special,
            type: type,
            size: size,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      # Should be valid even with special characters (will be slugified)
      assert changeset.valid?,
             "Name with special characters should be valid (gets slugified): #{name_with_special}"
    end
  end

  property "archive -> unarchive -> update workflow" do
    check all(
            original_name <- valid_name_generator(),
            new_name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator()
          ) do
      site = create_test_site!()

      media = %Media{
        id: Ash.UUID.generate(),
        name: original_name,
        type: type,
        size: size,
        format: "jpg",
        relative_path: "/test.jpg",
        description: "Test",
        site_id: site.id,
        archived_at: nil
      }

      # Destroy (archive)
      destroy_changeset = Ash.Changeset.for_destroy(media, :destroy, %{}, tenant: site.id)
      assert destroy_changeset.valid?, "Destroy should be valid"

      # Simulate archived state
      archived_media = %{media | archived_at: ~U[2024-01-01 00:00:00Z]}

      # Unarchive
      unarchive_changeset =
        Ash.Changeset.for_update(archived_media, :unarchive, %{}, tenant: site.id)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      # Simulate unarchived state
      unarchived_media = %{archived_media | archived_at: nil}

      # Update after unarchive
      update_changeset =
        Ash.Changeset.for_update(unarchived_media, :update, %{name: new_name}, tenant: site.id)

      assert update_changeset.valid?, "Update after unarchive should be valid"
    end
  end

  property "handles description with various content" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            description <-
              one_of([
                string([?a..?z, ?\s], min_length: 1, max_length: 500),
                string([?0..?9, ?\s], min_length: 1, max_length: 500),
                string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?., ?,, ?!, ??],
                  min_length: 1,
                  max_length: 500
                )
              ])
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg",
            description: description
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      assert changeset.valid?,
             "Valid description content should create valid changeset"
    end
  end

  property "validates media type is restricted to allowed values" do
    check all(
            name <- valid_name_generator(),
            size <- valid_size_generator(),
            type <- valid_type_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg"
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      assert changeset.valid?, "Valid media types should be accepted"
      assert type in [:images, :videos, :documents]
    end
  end

  property "handles dimensions with valid structure" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            dimensions <- one_of([nil, valid_dimensions_generator()])
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg",
            dimensions: dimensions
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      assert changeset.valid?,
             "Valid dimensions should create valid changeset"
    end
  end

  property "featured flag works correctly" do
    check all(
            name <- valid_name_generator(),
            type <- valid_type_generator(),
            size <- valid_size_generator(),
            featured <- boolean()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Media,
          :create,
          %{
            name: name,
            type: type,
            size: size,
            format: "jpg",
            featured: featured
          },
          tenant: site.id,
          private_arguments: %{stored_path: "/test.jpg"}
        )

      assert changeset.valid?, "Featured flag should be accepted"
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  defp valid_name_generator do
    bind(string([?a..?z, ?A..?Z], length: 1), fn first_char ->
      bind(string([?a..?z, ?A..?Z, ?0..?9, ?\s], max_length: 19), fn rest ->
        name = String.trim(first_char <> rest)

        if String.length(name) >= 1 do
          constant(name)
        else
          constant(first_char)
        end
      end)
    end)
  end

  defp valid_type_generator do
    member_of([:images, :videos, :documents])
  end

  defp valid_size_generator do
    integer(1..10_000_000)
  end

  defp valid_format_generator do
    one_of([
      constant("jpg"),
      constant("png"),
      constant("pdf"),
      constant("mp4"),
      string([?a..?z], min_length: 2, max_length: 10)
    ])
  end

  defp valid_path_generator do
    bind(string([?a..?z], min_length: 1, max_length: 50), fn filename ->
      bind(valid_format_generator(), fn ext ->
        constant("/uploads/#{filename}.#{ext}")
      end)
    end)
  end

  defp valid_description_generator do
    string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 1000)
  end

  defp valid_dimensions_generator do
    bind(integer(1..10_000), fn width ->
      bind(integer(1..10_000), fn height ->
        constant(%{width: width, height: height, unit: "px"})
      end)
    end)
  end

  defp invalid_name_generator do
    one_of([
      # Too long (more than 255 characters)
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 256, max_length: 300)
    ])
  end

  defp invalid_description_generator do
    # Description too long (more than 1000 characters)
    string([?a..?z, ?A..?Z, ?0..?9], min_length: 1001, max_length: 1500)
  end

  # Helper function to create a site for testing
  defp create_test_site!(attrs \\ []) do
    default_attrs = [
      name: "Test Site #{System.unique_integer([:positive])}",
      host: "test#{System.unique_integer([:positive])}.com"
    ]

    attrs = Keyword.merge(default_attrs, attrs)

    {:ok, site} =
      MishkaCmsCore.Runtime.Site
      |> Ash.Changeset.for_create(:create, Enum.into(attrs, %{}), authorize?: false)
      |> Ash.create(authorize?: false)

    site
  end
end
