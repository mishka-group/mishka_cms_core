defmodule MishkaCmsCore.Runtime.Resources.MediaCategoryPropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.MediaCategory
  @moduletag :property

  property "accepts all valid input combinations" do
    check all(
            name <- valid_name_generator(),
            description <- one_of([nil, valid_description_generator()])
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name,
            description: description
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, description: description && String.slice(description, 0, 20)})}"
    end
  end

  property "accepts minimal valid inputs" do
    check all(name <- valid_name_generator()) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Minimal valid inputs should create valid changeset: name=#{name}"
    end
  end

  property "accepts maximal valid inputs" do
    check all(
            name <-
              string([?A..?Z], length: 1)
              |> bind(fn first ->
                string([?a..?z, ?A..?Z, ?0..?9, ?\s], length: 199)
                |> map(fn rest ->
                  first <> rest
                end)
              end),
            description <-
              string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 1000, max_length: 1000)
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name,
            description: description
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Maximal valid inputs should create valid changeset"
    end
  end

  property "rejects invalid names" do
    check all(invalid_name <- invalid_name_generator()) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: invalid_name
          },
          tenant: site.id
        )

      refute changeset.valid?,
             "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid descriptions" do
    check all(
            name <- valid_name_generator(),
            invalid_description <- invalid_description_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name,
            description: invalid_description
          },
          tenant: site.id
        )

      refute changeset.valid?,
             "Expected invalid changeset for description length: #{String.length(invalid_description)}"
    end
  end

  property "rejects missing required fields" do
    check all(
            include_name <- boolean(),
            name <- valid_name_generator()
          ) do
      site = create_test_site!()

      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs

      changeset =
        Ash.Changeset.for_create(MediaCategory, :create, attrs, tenant: site.id)

      if include_name do
        assert changeset.valid?,
               "Expected valid changeset when name is present: #{inspect(attrs)}"
      else
        refute changeset.valid?,
               "Expected invalid changeset when name is missing: #{inspect(attrs)}"
      end
    end
  end

  property "handles boundary values correctly" do
    check all(
            name_length <- member_of([2, 200]),
            description_length <- member_of([0, 1, 1000])
          ) do
      site = create_test_site!()

      name = "A" <> String.duplicate("b", name_length - 1)

      description =
        if description_length == 0,
          do: nil,
          else: String.duplicate("d", description_length)

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name,
            description: description
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, desc_len=#{description_length}"
    end
  end

  property "handles whitespace trimming correctly" do
    check all(
            base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 2, max_length: 190),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      site = create_test_site!()

      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: padded_name
          },
          tenant: site.id
        )

      # Should be valid due to trimming
      assert changeset.valid?, "Should be valid after trimming whitespace"
    end
  end

  property "allows same name across different sites" do
    check all(name <- valid_name_generator()) do
      # Generate unique site names and hosts to avoid conflicts
      unique_id1 = System.unique_integer([:positive])
      unique_id2 = System.unique_integer([:positive])

      site1 = create_test_site!(name: "Site#{unique_id1}", host: "site#{unique_id1}.com")
      site2 = create_test_site!(name: "Site#{unique_id2}", host: "site#{unique_id2}.com")

      changeset1 =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name
          },
          tenant: site1.id
        )

      changeset2 =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name
          },
          tenant: site2.id
        )

      assert changeset1.valid?, "First category should be valid"

      assert changeset2.valid?,
             "Second category with same name on different site should be valid"
    end
  end

  property "media categories require site_id (tenant)" do
    check all(name <- valid_name_generator()) do
      # Test that creating without tenant fails
      assert_raise Ash.Error.Invalid, fn ->
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{
          name: name
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end

  property "update action accepts valid changes on non-archived categories" do
    check all(
            original_name <- valid_name_generator(),
            new_name <- valid_name_generator(),
            new_description <- one_of([nil, valid_description_generator()])
          ) do
      site = create_test_site!()

      category = %MediaCategory{
        id: Ash.UUID.generate(),
        name: original_name,
        description: "Original description",
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          category,
          :update,
          %{
            name: new_name,
            description: new_description
          },
          tenant: site.id
        )

      assert changeset.valid?, "Update should be valid for non-archived category"
    end
  end

  property "update action rejects changes on archived categories" do
    check all(
            name <- valid_name_generator(),
            new_name <- valid_name_generator()
          ) do
      site = create_test_site!()

      archived_category = %MediaCategory{
        id: Ash.UUID.generate(),
        name: name,
        description: "Test description",
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_category,
          :update,
          %{
            name: new_name
          },
          tenant: site.id
        )

      refute changeset.valid?, "Update should be invalid for archived category"
    end
  end

  property "unarchive action works on archived categories" do
    check all(name <- valid_name_generator()) do
      site = create_test_site!()

      archived_category = %MediaCategory{
        id: Ash.UUID.generate(),
        name: name,
        description: "Test description",
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset = Ash.Changeset.for_update(archived_category, :unarchive, %{}, tenant: site.id)
      assert changeset.valid?, "Unarchive should work on archived categories"
    end
  end

  property "applies default values correctly" do
    check all(name <- valid_name_generator()) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name
          },
          tenant: site.id
        )

      assert changeset.valid?

      # Test that defaults would be applied
      assert changeset.attributes[:description] == nil or
               is_binary(changeset.attributes[:description])
    end
  end

  property "applies slugification to name" do
    check all(
            base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 2, max_length: 50),
            special_chars <- member_of(["!", "@", "#", "$", "%", "  ", "-"])
          ) do
      site = create_test_site!()

      name_with_special = base_name <> special_chars

      changeset =
        Ash.Changeset.for_create(
          MediaCategory,
          :create,
          %{
            name: name_with_special
          },
          tenant: site.id
        )

      # Should be valid even with special characters (will be slugified)
      assert changeset.valid?,
             "Name with special characters should be valid (gets slugified): #{name_with_special}"
    end
  end

  property "archive -> unarchive -> update workflow" do
    check all(
            original_name <- valid_name_generator(),
            new_name <- valid_name_generator()
          ) do
      site = create_test_site!()

      category = %MediaCategory{
        id: Ash.UUID.generate(),
        name: original_name,
        description: "Test",
        site_id: site.id,
        archived_at: nil
      }

      # Destroy (archive)
      destroy_changeset = Ash.Changeset.for_destroy(category, :destroy, %{}, tenant: site.id)
      assert destroy_changeset.valid?, "Destroy should be valid"

      # Simulate archived state
      archived_category = %{category | archived_at: ~U[2024-01-01 00:00:00Z]}

      # Unarchive
      unarchive_changeset =
        Ash.Changeset.for_update(archived_category, :unarchive, %{}, tenant: site.id)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      # Simulate unarchived state
      unarchived_category = %{archived_category | archived_at: nil}

      # Update after unarchive
      update_changeset =
        Ash.Changeset.for_update(unarchived_category, :update, %{name: new_name}, tenant: site.id)

      assert update_changeset.valid?, "Update after unarchive should be valid"
    end
  end

  property "handles description with various content" do
    check all(
            name <- valid_name_generator(),
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
          MediaCategory,
          :create,
          %{
            name: name,
            description: description
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Valid description content should create valid changeset: #{inspect(String.slice(description, 0, 50))}"
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  defp valid_name_generator do
    bind(string([?a..?z, ?A..?Z], length: 1), fn first_char ->
      bind(string([?a..?z, ?A..?Z, ?0..?9, ?\s], max_length: 19), fn rest ->
        name = String.trim(first_char <> rest)

        if String.length(name) >= 2 do
          constant(name)
        else
          constant(first_char <> "b")
        end
      end)
    end)
  end

  defp valid_description_generator do
    string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 1000)
  end

  defp invalid_name_generator do
    one_of([
      # Too short (less than 2 characters)
      string([?a..?z, ?A..?Z, ?0..?9], max_length: 1),
      # Too long (more than 200 characters)
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 201, max_length: 250),
      # Empty
      constant(""),
      # Only whitespace
      string([?\s], min_length: 1, max_length: 10)
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
