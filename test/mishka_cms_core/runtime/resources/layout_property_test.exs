defmodule MishkaCmsCore.Runtime.Resources.LayoutPropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  import MishkaCmsCore.Test.Factory
  alias MishkaCmsCore.Runtime.Layout
  @moduletag :property

  property "accepts all valid input combinations" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 200),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 1000),
            format <- member_of([:heex, :eex, :markdown]),
            priority <- integer(0..100)
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            format: format,
            priority: priority,
            example: nil
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, path: path, template: template, format: format, priority: priority})}"
    end
  end

  property "accepts minimal valid inputs" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 3),
            path_base <- string(:alphanumeric, min_length: 1, max_length: 5),
            template <- realistic_template_generator(3, 10)
          ) do
      path = "/#{path_base}"

      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template
          },
          tenant: site.id
        )

      assert changeset.valid?
    end
  end

  property "accepts maximal valid inputs" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 200, max_length: 200),
            path_base <- string(:alphanumeric, min_length: 254, max_length: 254),
            template <- realistic_template_generator(3, 1000)
          ) do
      path = "/#{String.slice(path_base, 0, 254)}"

      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            format: :heex,
            priority: 100
          },
          tenant: site.id
        )

      if String.length(path) <= 255 do
        assert changeset.valid?
      else
        refute changeset.valid?
      end
    end
  end

  property "accepts complex valid path formats" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path_type <- member_of([:exact, :wildcard, :nested, :dynamic])
          ) do
      path =
        case path_type do
          :exact -> "/about"
          :wildcard -> "/blog/*"
          :nested -> "/admin/dashboard/users"
          :dynamic -> "/users/*/profile"
        end

      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: "<html><body><%= @content %></body></html>"
          },
          tenant: site.id
        )

      assert changeset.valid?
    end
  end

  property "master_create can create global layouts (nil site_id)" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 50),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            format <- member_of([:heex, :eex, :markdown]),
            priority <- integer(0..100)
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :master_create,
          %{
            name: name,
            path: path,
            template: template,
            format: format,
            priority: priority
          },
          authorize?: false
        )

      assert changeset.valid?,
             "master_create should create valid global layout changeset"
    end
  end

  property "rejects invalid names" do
    site = create_site!()

    check all(
            invalid_name <- invalid_name_generator(),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100)
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: invalid_name,
            path: path,
            template: template
          },
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid paths" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            invalid_path <- invalid_path_generator(),
            template <- realistic_template_generator(3, 100)
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: invalid_path,
            template: template
          },
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for path: #{inspect(invalid_path)}"
    end
  end

  property "rejects invalid templates" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            invalid_template <- invalid_template_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: invalid_template
          },
          tenant: site.id
        )

      refute changeset.valid?,
             "Expected invalid changeset for template: #{inspect(invalid_template)}"
    end
  end

  property "rejects invalid priority values" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            invalid_priority <- invalid_priority_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            priority: invalid_priority
          },
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for priority: #{invalid_priority}"
    end
  end

  property "rejects invalid format values" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            invalid_format <- invalid_format_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            format: invalid_format
          },
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for format: #{invalid_format}"
    end
  end

  property "rejects missing required fields" do
    site = create_site!()

    check all(
            include_name <- boolean(),
            include_path <- boolean(),
            include_template <- boolean(),
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            priority <- integer(0..100)
          ) do
      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
      attrs = if include_path, do: Map.put(attrs, :path, path), else: attrs
      attrs = if include_template, do: Map.put(attrs, :template, template), else: attrs
      attrs = Map.put(attrs, :priority, priority)

      changeset = Ash.Changeset.for_create(Layout, :create, attrs, tenant: site.id)

      # TEMPLATE IS OPTIONAL NOW: leaving it out means an empty layout, which the create action fills
      # with the starter container. Name and path are still how a layout is found, so they stay.
      if include_name and include_path do
        assert changeset.valid?,
               "Expected valid changeset when name and path are present: #{inspect(attrs)}"
      else
        refute changeset.valid?,
               "Expected invalid changeset when a required field is missing: #{inspect(attrs)}"
      end
    end
  end

  property "handles boundary values correctly" do
    site = create_site!()

    check all(
            name_length <- member_of([3, 200]),
            # "/a" = 2, max = 255
            path_length <- member_of([2, 255]),
            template_length <- member_of([3, 50]),
            priority <- member_of([0, 100])
          ) do
      name = String.duplicate("a", name_length)
      # -1 for the leading "/"
      path_base = String.duplicate("a", path_length - 1)
      path = "/#{path_base}"
      template = "<div>#{String.duplicate("t", template_length)}</div>"

      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            priority: priority
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, path_len=#{path_length}, template_len=#{String.length(template)}, priority=#{priority}"
    end
  end

  property "handles whitespace trimming correctly" do
    site = create_site!()

    check all(
            base_name <- string(:alphanumeric, min_length: 3, max_length: 190),
            base_path <- string(:alphanumeric, min_length: 3, max_length: 250),
            # NOT `:ascii`: this property is about TRIMMING, and a random ASCII soup — angle
            # brackets, braces, quotes — is not a template. It only ever tested that nothing read
            # the markup.
            base_template <- string(:alphanumeric, min_length: 3, max_length: 990),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      padded_path =
        "#{String.duplicate(" ", leading_spaces)}/#{base_path}#{String.duplicate(" ", trailing_spaces)}"

      padded_template =
        "#{String.duplicate(" ", leading_spaces)}<div>#{base_template}</div>#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: padded_name,
            path: padded_path,
            template: padded_template
          },
          tenant: site.id
        )

      case changeset.valid? do
        true ->
          assert true

        false ->
          trimmed_name = String.trim(padded_name)
          trimmed_path = String.trim(padded_path)
          trimmed_template = String.trim(padded_template)

          retry_changeset =
            Ash.Changeset.for_create(
              Layout,
              :create,
              %{
                name: trimmed_name,
                path: trimmed_path,
                template: trimmed_template
              },
              tenant: site.id
            )

          assert retry_changeset.valid?, "Should be valid after trimming"
      end
    end
  end

  property "valid updates preserve data integrity" do
    site = create_site!()

    check all(
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            new_priority <- integer(0..100)
          ) do
      # Create a layout first
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Fetch with master_get for master_update
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      # master_update is a standard update action
      changeset =
        Ash.Changeset.for_update(
          record,
          :master_update,
          %{
            name: new_name,
            priority: new_priority
          },
          authorize?: false
        )

      assert changeset.valid?, "Update changeset should be valid"

      # Cleanup
      Ash.destroy!(layout, action: :permanent_destroy, authorize?: false)
    end
  end

  property "validates resource_links structure correctly" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 15),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            resource_links <- valid_resource_links_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            resource_links: resource_links
          },
          tenant: site.id
        )

      assert changeset.valid?, "Valid resource_links should be accepted"
    end
  end

  property "validates seo_tags structure correctly" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 15),
            path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            seo_tags <- valid_seo_tags_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Layout,
          :create,
          %{
            name: name,
            path: path,
            template: template,
            seo_tags: seo_tags
          },
          tenant: site.id
        )

      assert changeset.valid?, "Valid seo_tags should be accepted"
    end
  end

  property "update action accepts valid changes" do
    site = create_site!()

    check all(
            new_name <- string(:alphanumeric, min_length: 3, max_length: 200),
            new_path <- valid_path_generator(),
            new_template <- realistic_template_generator(3, 1000),
            new_priority <- integer(0..100),
            new_format <- member_of([:heex, :eex, :markdown])
          ) do
      # Create a layout first
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Fetch with master_get for master_update
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      # master_update is a standard update action
      changeset =
        Ash.Changeset.for_update(
          record,
          :master_update,
          %{
            name: new_name,
            path: new_path <> "_#{uuid}",
            template: new_template,
            priority: new_priority,
            format: new_format
          },
          authorize?: false
        )

      assert changeset.valid?, "Update should be valid for non-archived layout"

      # Cleanup
      Ash.destroy!(layout, action: :permanent_destroy, authorize?: false)
    end
  end

  property "update action rejects archived layout updates" do
    site = create_site!()

    # Note: This test validates that archived layouts cannot be updated.
    # The validation is now on the changeset since master_update is a standard action.
    check all(new_name <- string(:alphanumeric, min_length: 3, max_length: 20)) do
      # Create and archive a layout
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Archive it
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      record
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Try to update the archived layout - fetch from archived
      archived_record =
        Ash.get!(Layout, layout.id, action: :master_get_archived, authorize?: false)

      # master_update should reject archived layouts
      changeset =
        Ash.Changeset.for_update(
          archived_record,
          :master_update,
          %{
            name: new_name
          },
          authorize?: false
        )

      # The changeset should be invalid due to archived_at validation
      refute changeset.valid?, "Update should fail for archived layout"

      # Cleanup
      Ash.destroy!(archived_record, action: :master_permanent_destroy, authorize?: false)
    end
  end

  property "update action validates path format on update" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            valid_path <- valid_path_generator(),
            template <- realistic_template_generator(3, 100),
            invalid_path <- invalid_path_generator()
          ) do
      # Create a real layout first, then test update with invalid path
      uuid = Ecto.UUID.generate()
      unique_name = "#{name}_#{uuid}"
      unique_path = "#{valid_path}_#{uuid}"

      layout =
        Layout
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: unique_name,
            path: unique_path,
            template: template
          },
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)

      # Now try to update with invalid path
      changeset =
        Ash.Changeset.for_update(
          layout,
          :update,
          %{
            path: invalid_path
          },
          tenant: site.id
        )

      refute changeset.valid?, "Update with invalid path should fail"

      # Cleanup
      Ash.destroy(layout, action: :permanent_destroy, authorize?: false)
    end
  end

  property "unarchive action works on archived layouts" do
    site = create_site!()

    check all(
            _priority <- integer(0..100),
            _format <- member_of([:heex, :eex, :markdown])
          ) do
      # Create and archive a layout
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Archive it
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      record
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Fetch archived record and test unarchive changeset
      archived_record =
        Ash.get!(Layout, layout.id, action: :master_get_archived, authorize?: false)

      # master_unarchive is a standard update action
      changeset =
        Ash.Changeset.for_update(archived_record, :master_unarchive, %{}, authorize?: false)

      assert changeset.valid?, "Unarchive should work on archived layouts"

      # Cleanup
      Ash.destroy!(archived_record, action: :master_permanent_destroy, authorize?: false)
    end
  end

  property "destroy action (archive) works on any layout" do
    site = create_site!()

    check all(
            _priority <- integer(0..100),
            _format <- member_of([:heex, :eex, :markdown])
          ) do
      # Create a layout
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Fetch with master_get for master_destroy
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      # master_destroy is a standard destroy action
      changeset =
        Ash.Changeset.for_destroy(record, :master_destroy, %{}, authorize?: false)

      assert changeset.valid?, "Destroy action changeset should be valid"

      # Cleanup
      Ash.destroy!(layout, action: :permanent_destroy, authorize?: false)
    end
  end

  property "permanent_destroy action works on any layout" do
    site = create_site!()

    check all(
            _priority <- integer(0..100),
            _format <- member_of([:heex, :eex, :markdown])
          ) do
      # Create a layout
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Fetch with master_get for master_permanent_destroy
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      # master_permanent_destroy is a standard destroy action
      changeset =
        Ash.Changeset.for_destroy(record, :master_permanent_destroy, %{}, authorize?: false)

      assert changeset.valid?, "Permanent destroy should work on any layout"

      # Cleanup - actually destroy
      Ash.destroy!(record, action: :permanent_destroy, authorize?: false)
    end
  end

  property "by_priority read action parameters are valid" do
    check all(
            offset <- integer(0..1000),
            limit <- integer(1..200)
          ) do
      assert offset >= 0, "Offset should be non-negative"
      assert limit > 0, "Limit should be positive"
      assert limit <= 200, "Limit should be reasonable"
    end
  end

  property "by_path read action works with valid paths" do
    check all(search_path <- valid_path_generator()) do
      # This just tests that the path format is valid for searching
      assert String.starts_with?(search_path, "/"), "Search path should start with /"
      assert String.length(search_path) <= 255, "Search path should be reasonable length"
    end
  end

  property "archive -> unarchive -> update workflow" do
    site = create_site!()

    check all(new_name <- string(:alphanumeric, min_length: 3, max_length: 20)) do
      # Create a layout
      uuid = Ecto.UUID.generate()
      layout = create_layout!(name: "test_#{uuid}", path: "/test_#{uuid}", site_id: site.id)

      # Test archive (destroy) changeset
      record = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)

      destroy_changeset =
        Ash.Changeset.for_destroy(record, :master_destroy, %{}, authorize?: false)

      assert destroy_changeset.valid?, "Destroy should be valid"

      # Actually archive it
      record
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Test unarchive changeset
      archived_record =
        Ash.get!(Layout, layout.id, action: :master_get_archived, authorize?: false)

      unarchive_changeset =
        Ash.Changeset.for_update(archived_record, :master_unarchive, %{}, authorize?: false)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      # Actually unarchive it
      unarchived =
        archived_record
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update!()

      # Test update changeset after unarchive
      update_changeset =
        Ash.Changeset.for_update(unarchived, :master_update, %{name: new_name}, authorize?: false)

      assert update_changeset.valid?, "Update after unarchive should be valid"

      # Cleanup
      Ash.destroy!(unarchived, action: :permanent_destroy, authorize?: false)
    end
  end

  @tag :slow
  property "handles large datasets efficiently" do
    site = create_site!()

    check all(
            layouts <-
              list_of(
                fixed_map(%{
                  name: string(:alphanumeric, min_length: 3, max_length: 20),
                  path: valid_path_generator(),
                  template: realistic_template_generator(3, 100),
                  format: member_of([:heex, :eex, :markdown]),
                  priority: integer(0..100)
                }),
                min_length: 10,
                max_length: 20
              ),
            max_runs: 5
          ) do
      changesets =
        Enum.map(layouts, fn layout_attrs ->
          Ash.Changeset.for_create(Layout, :create, layout_attrs, tenant: site.id)
        end)

      assert Enum.all?(changesets, & &1.valid?), "All changesets in batch should be valid"
    end
  end

  @tag :slow
  property "mixed action workflows with large datasets" do
    site = create_site!()

    check all(
            operations <-
              list_of(
                one_of([
                  {:create,
                   fixed_map(%{
                     name: string(:alphanumeric, min_length: 3, max_length: 15),
                     path: valid_path_generator(),
                     template: realistic_template_generator(3, 50),
                     format: member_of([:heex, :eex, :markdown]),
                     priority: integer(0..100)
                   })},
                  {:update,
                   fixed_map(%{
                     name: string(:alphanumeric, min_length: 3, max_length: 15),
                     priority: integer(0..100)
                   })},
                  {:unarchive, constant(%{})}
                ]),
                min_length: 5,
                max_length: 15
              ),
            max_runs: 3
          ) do
      results =
        Enum.map(operations, fn {action, attrs} ->
          case action do
            :create ->
              changeset = Ash.Changeset.for_create(Layout, :create, attrs, tenant: site.id)
              {action, changeset.valid?}

            :update ->
              mock_layout = %Layout{
                id: Ecto.UUID.generate(),
                name: "Test Layout",
                path: "/test",
                template: "<html><body>Test</body></html>",
                format: :heex,
                priority: 0,
                extra: %{},
                content: %{},
                resource_links: [],
                seo_tags: [],
                helpers: [],
                permissions: [],
                site_id: site.id,
                archived_at: nil
              }

              changeset = Ash.Changeset.for_update(mock_layout, :update, attrs, tenant: site.id)
              {action, changeset.valid?}

            :unarchive ->
              mock_archived_layout = %Layout{
                id: Ecto.UUID.generate(),
                name: "Test Layout",
                path: "/test",
                template: "<html><body>Test</body></html>",
                format: :heex,
                priority: 0,
                extra: %{},
                content: %{},
                resource_links: [],
                seo_tags: [],
                helpers: [],
                permissions: [],
                site_id: site.id,
                archived_at: ~U[2024-01-01 00:00:00Z]
              }

              changeset =
                Ash.Changeset.for_update(mock_archived_layout, :unarchive, attrs, tenant: site.id)

              {action, changeset.valid?}
          end
        end)

      invalid_operations = Enum.filter(results, fn {_action, valid?} -> not valid? end)

      assert Enum.empty?(invalid_operations),
             "All operations should be valid, but these failed: #{inspect(invalid_operations)}"
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  defp realistic_template_generator(min_len, max_len) do
    one_of([
      # HTML-like templates
      bind(string(:alphanumeric, min_length: 3, max_length: 20), fn content ->
        constant("<div>#{content}</div>")
      end),
      bind(string(:alphanumeric, min_length: 3, max_length: 20), fn content ->
        constant("<h1>#{content}</h1>")
      end),
      bind(string(:alphanumeric, min_length: 3, max_length: 15), fn content ->
        constant("<p>#{content}</p>")
      end),
      # HEEx templates with interpolation. THE ASSIGN NAME HAS TO BE AN IDENTIFIER: `:alphanumeric`
      # produces things like `@3ab`, which is not Elixir, so the "realistic" template was markup no
      # compiler would take — and the properties asserting it is ACCEPTED were asserting the resource
      # does not look.
      bind(assign_name_generator(), fn var ->
        constant("<div><%= @#{var} %></div>")
      end),
      bind(assign_name_generator(), fn var ->
        constant("<h1><%= @#{var} %></h1>")
      end),
      # Complex templates
      constant(
        "<html><head><title><%= @title %></title></head><body><%= @content %></body></html>"
      ),
      constant("<div class='container'><%= render_slot(@inner_block) %></div>"),
      # Simple text templates. NOT `:ascii` — that emits `<`, `>` and `{` into a tag body, which is
      # markup rather than text and does not parse as either.
      bind(
        string(:alphanumeric, min_length: max(3, min_len), max_length: min(50, max_len)),
        fn content ->
          constant("<div>#{content}</div>")
        end
      )
    ])
  end

  defp valid_path_generator do
    bind(string(:alphanumeric, min_length: 1, max_length: 50), fn base ->
      one_of([
        constant("/#{base}"),
        constant("/#{base}/*"),
        constant("/#{base}/nested"),
        constant("/#{base}/*/dynamic"),
        constant("/"),
        constant("/about"),
        constant("/blog/*"),
        constant("/admin/users/*")
      ])
    end)
  end

  defp invalid_name_generator do
    one_of([
      string(:alphanumeric, max_length: 2),
      string(:alphanumeric, min_length: 201, max_length: 300),
      constant(""),
      string([?\s], min_length: 1, max_length: 10)
    ])
  end

  defp invalid_path_generator do
    one_of([
      # Missing leading "/"
      string(:alphanumeric, min_length: 1, max_length: 10),
      # Too long
      string(:alphanumeric, min_length: 256, max_length: 300),
      constant(""),
      constant("no-leading-slash"),
      constant("invalid@path"),
      constant("path with spaces")
    ])
  end

  # LOWERCASE LETTERS ARE NOT ENOUGH EITHER: `@end`, `@and`, `@when` and the other reserved words do
  # not parse, so a random name was an invalid template now and then. Whether it is a name is asked of
  # the parser itself — `@name` has to read as an attribute over a plain variable — so every reserved
  # word is covered without listing one.
  defp assign_name_generator do
    filter(string(?a..?z, min_length: 3, max_length: 15), fn var ->
      match?(
        {:ok, {:@, _, [{_name, _meta, context}]}} when is_atom(context),
        Code.string_to_quoted("@" <> var)
      )
    end)
  end

  defp invalid_template_generator do
    string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 2)
  end

  defp invalid_priority_generator do
    one_of([
      integer(-100..-1),
      integer(101..1000)
    ])
  end

  defp invalid_format_generator do
    one_of([
      :invalid_format,
      :html,
      :jsx,
      :liquid,
      :mustache,
      :erb
    ])
  end

  defp valid_resource_links_generator do
    list_of(
      fixed_map(%{
        type: member_of(["stylesheet", "script", "preload", "icon", "preconnect"]),
        href:
          bind(string(:alphanumeric, min_length: 5, max_length: 20), fn base ->
            one_of([
              constant("https://#{base}.com/asset.css"),
              constant("/assets/#{base}.js"),
              constant("https://fonts.googleapis.com")
            ])
          end),
        rel: one_of([constant(nil), member_of(["stylesheet", "preload", "icon"])]),
        media: one_of([constant(nil), member_of(["screen", "print", "all"])]),
        integrity: one_of([constant(nil), constant("sha384-test")]),
        crossorigin: one_of([constant(nil), member_of(["anonymous", "use-credentials"])]),
        attrs: one_of([constant(nil), constant(%{defer: true})])
      }),
      max_length: 5
    )
  end

  defp valid_seo_tags_generator do
    list_of(
      fixed_map(%{
        tag: member_of(["meta", "link", "script", "title"]),
        attrs:
          bind(member_of(["meta", "link", "script"]), fn tag ->
            case tag do
              "meta" ->
                one_of([
                  constant(%{name: "description"}),
                  constant(%{property: "og:title"}),
                  constant(%{charset: "UTF-8"})
                ])

              "link" ->
                constant(%{rel: "canonical", href: "https://example.com"})

              "script" ->
                constant(%{type: "application/ld+json"})
            end
          end),
        content:
          one_of([
            constant(nil),
            string(:ascii, min_length: 1, max_length: 100)
          ])
      }),
      max_length: 5
    )
  end
end
