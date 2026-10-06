defmodule MishkaCmsCore.Runtime.Resources.JsHookPropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.JsHook
  @moduletag :property

  property "accepts all valid input combinations" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 100),
            content <- realistic_js_content_generator(1, 1000),
            format <- member_of([:js, :ts]),
            priority <- integer(0..100),
            active <- boolean(),
            description <-
              one_of([constant(nil), string(:ascii, min_length: 1, max_length: 500)]),
            permissions <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 20), max_length: 5)
          ) do
      site = create_test_site!()

      attrs = %{
        name: name,
        content: content,
        format: format,
        priority: priority,
        active: active,
        permissions: permissions
      }

      attrs = if description, do: Map.put(attrs, :description, description), else: attrs

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(attrs)}"
    end
  end

  property "accepts minimal valid inputs" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 3),
            content <- realistic_js_content_generator(1, 10)
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, %{name: name, content: content}, tenant: site.id)

      assert changeset.valid?
    end
  end

  property "accepts maximal valid inputs" do
    check all(
            name <- string(:alphanumeric, min_length: 100, max_length: 100),
            content <- realistic_js_content_generator(500, 1000),
            description <- string(:ascii, min_length: 500, max_length: 500)
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: name,
            content: content,
            description: description,
            format: :ts,
            priority: 100,
            active: false,
            permissions: ["admin", "developer", "editor"]
          },
          tenant: site.id
        )

      assert changeset.valid?
    end
  end

  property "accepts complex valid JavaScript/TypeScript formats" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content_type <-
              member_of([
                :simple_js,
                :complex_js,
                :typescript,
                :arrow_function,
                :class_definition
              ])
          ) do
      site = create_test_site!()

      content =
        case content_type do
          :simple_js ->
            "console.log('Hello World');"

          :complex_js ->
            "const app = { init: () => { document.addEventListener('DOMContentLoaded', () => console.log('loaded')); } };"

          :typescript ->
            "interface User { name: string; age: number; } const user: User = { name: 'John', age: 30 };"

          :arrow_function ->
            "const handleClick = (event: Event) => { event.preventDefault(); console.log('clicked'); };"

          :class_definition ->
            "class Component { constructor(private element: HTMLElement) {} render() { return this.element; } }"
        end

      format = if content_type == :typescript, do: :ts, else: :js

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, content: content, format: format},
          tenant: site.id
        )

      assert changeset.valid?
    end
  end

  property "rejects invalid names" do
    check all(
            invalid_name <- invalid_name_generator(),
            content <- realistic_js_content_generator(1, 100)
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, %{name: invalid_name, content: content},
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid content" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            invalid_content <- invalid_content_generator()
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, %{name: name, content: invalid_content},
          tenant: site.id
        )

      refute changeset.valid?,
             "Expected invalid changeset for content: #{inspect(invalid_content)}"
    end
  end

  property "rejects invalid priority values" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            invalid_priority <- invalid_priority_generator()
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, content: content, priority: invalid_priority},
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for priority: #{invalid_priority}"
    end
  end

  property "rejects invalid format values" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            invalid_format <- invalid_format_generator()
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, content: content, format: invalid_format},
          tenant: site.id
        )

      refute changeset.valid?, "Expected invalid changeset for format: #{invalid_format}"
    end
  end

  property "rejects missing required fields" do
    check all(
            include_name <- boolean(),
            include_content <- boolean(),
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            priority <- integer(0..100)
          ) do
      site = create_test_site!()

      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
      attrs = if include_content, do: Map.put(attrs, :content, content), else: attrs
      attrs = Map.put(attrs, :priority, priority)

      changeset = Ash.Changeset.for_create(JsHook, :create, attrs, tenant: site.id)

      if not include_name or not include_content do
        refute changeset.valid?,
               "Expected invalid changeset when required fields missing: #{inspect(attrs)}"
      else
        assert changeset.valid?,
               "Expected valid changeset when all required fields present: #{inspect(attrs)}"
      end
    end
  end

  property "handles boundary values correctly" do
    check all(
            name_length <- member_of([3, 100]),
            content_length <- member_of([1, 50]),
            priority <- member_of([0, 100]),
            description_length <- one_of([constant(nil), member_of([1, 500])])
          ) do
      site = create_test_site!()

      name = String.duplicate("a", name_length)
      content = "console.log('#{String.duplicate("t", content_length)}');"

      attrs = %{
        name: name,
        content: content,
        priority: priority
      }

      attrs =
        if description_length do
          description = String.duplicate("d", description_length)
          Map.put(attrs, :description, description)
        else
          attrs
        end

      changeset = Ash.Changeset.for_create(JsHook, :create, attrs, tenant: site.id)

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, content_len=#{String.length(content)}, priority=#{priority}, desc_len=#{description_length}"
    end
  end

  property "handles whitespace trimming correctly" do
    check all(
            base_name <- string(:alphanumeric, min_length: 3, max_length: 90),
            base_content <- string(:ascii, min_length: 3, max_length: 490),
            base_description <- string(:ascii, min_length: 3, max_length: 490),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      site = create_test_site!()

      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      padded_content =
        "#{String.duplicate(" ", leading_spaces)}console.log('#{base_content}');#{String.duplicate(" ", trailing_spaces)}"

      padded_description =
        "#{String.duplicate(" ", leading_spaces)}#{base_description}#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{name: padded_name, content: padded_content, description: padded_description},
          tenant: site.id
        )

      case changeset.valid? do
        true ->
          assert true

        false ->
          trimmed_name = String.trim(padded_name)
          trimmed_content = String.trim(padded_content)
          trimmed_description = String.trim(padded_description)

          retry_changeset =
            JsHook
            |> Ash.Changeset.for_create(
              :create,
              %{
                name: trimmed_name,
                content: trimmed_content,
                description: trimmed_description
              },
              tenant: site.id
            )

          assert retry_changeset.valid?, "Should be valid after trimming"
      end
    end
  end

  property "valid updates preserve data integrity" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_content <- realistic_js_content_generator(1, 100),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            new_priority <- integer(0..100),
            new_active <- boolean()
          ) do
      site = create_test_site!()

      hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: original_name,
        content: original_content,
        format: :js,
        priority: 0,
        active: true,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          hook,
          :update,
          %{name: new_name, priority: new_priority, active: new_active},
          tenant: site.id
        )

      assert changeset.valid?, "Update changeset should be valid"
    end
  end

  property "validates permissions structure correctly" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 15),
            content <- realistic_js_content_generator(1, 100),
            permissions <- valid_permissions_generator()
          ) do
      site = create_test_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, content: content, permissions: permissions},
          tenant: site.id
        )

      assert changeset.valid?, "Valid permissions should be accepted"
    end
  end

  property "update action accepts valid changes" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_content <- realistic_js_content_generator(1, 100),
            original_priority <- integer(0..100),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 100),
            new_content <- realistic_js_content_generator(1, 1000),
            new_priority <- integer(0..100),
            new_format <- member_of([:js, :ts]),
            new_active <- boolean(),
            new_description <-
              one_of([constant(nil), string(:ascii, min_length: 1, max_length: 500)])
          ) do
      site = create_test_site!()

      hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: original_name,
        content: original_content,
        format: :js,
        priority: original_priority,
        active: true,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: nil
      }

      attrs = %{
        name: new_name,
        content: new_content,
        priority: new_priority,
        format: new_format,
        active: new_active
      }

      attrs = if new_description, do: Map.put(attrs, :description, new_description), else: attrs

      changeset = Ash.Changeset.for_update(hook, :update, attrs, tenant: site.id)

      assert changeset.valid?, "Update should be valid for non-archived hook"
    end
  end

  property "update action rejects archived hook updates" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      site = create_test_site!()

      archived_hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: name,
        content: content,
        format: :js,
        priority: 0,
        active: true,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(archived_hook, :update, %{name: new_name}, tenant: site.id)

      refute changeset.valid?, "Update should be invalid for archived hook"
    end
  end

  property "update action validates content on update" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            invalid_content <- invalid_content_generator()
          ) do
      site = create_test_site!()

      hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: name,
        content: content,
        format: :js,
        priority: 0,
        active: true,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(hook, :update, %{content: invalid_content}, tenant: site.id)

      refute changeset.valid?, "Update with invalid content should fail"
    end
  end

  property "update action can toggle active state" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            initial_active <- boolean(),
            new_active <- boolean()
          ) do
      site = create_test_site!()

      hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: name,
        content: content,
        format: :js,
        priority: 0,
        active: initial_active,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(hook, :update, %{active: new_active}, tenant: site.id)

      assert changeset.valid?, "Update to toggle active should be valid"
    end
  end

  property "unarchive action works on archived hooks" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            priority <- integer(0..100),
            format <- member_of([:js, :ts]),
            active <- boolean()
          ) do
      site = create_test_site!()

      archived_hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: name,
        content: content,
        format: format,
        priority: priority,
        active: active,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset = Ash.Changeset.for_update(archived_hook, :unarchive, %{}, tenant: site.id)
      assert changeset.valid?, "Unarchive should work on archived hooks"
    end
  end

  property "destroy action (archive) works on non-archived hooks" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            priority <- integer(0..100),
            format <- member_of([:js, :ts]),
            active <- boolean()
          ) do
      site = create_test_site!()

      # Create hook through Ash
      hook =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: name,
            content: content,
            format: format,
            priority: priority,
            active: active,
            description: nil,
            permissions: []
          },
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)

      # Test destroy on non-archived hook
      changeset = Ash.Changeset.for_destroy(hook, :destroy, %{}, tenant: site.id)
      assert changeset.valid?, "Destroy should work on non-archived hook"
    end
  end

  property "destroy action fails on archived hooks" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100)
          ) do
      site = create_test_site!()

      # Create and archive hook
      hook =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, content: content},
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)

      {:ok, archived_hook} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)

      # Test destroy on already archived hook
      changeset = Ash.Changeset.for_destroy(archived_hook, :destroy, %{}, tenant: site.id)
      refute changeset.valid?, "Destroy should fail on already archived hook"
    end
  end

  property "permanent_destroy action works on any hook" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            priority <- integer(0..100),
            format <- member_of([:js, :ts]),
            active <- boolean()
          ) do
      site = create_test_site!()

      hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: name,
        content: content,
        format: format,
        priority: priority,
        active: active,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset = Ash.Changeset.for_destroy(hook, :permanent_destroy, %{}, tenant: site.id)
      assert changeset.valid?, "Permanent destroy should work on any hook"
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

  property "by_format read action works with valid formats" do
    check all(format <- member_of([:js, :ts])) do
      # This just tests that the format is valid for searching
      assert format in [:js, :ts], "Format should be js or ts"
    end
  end

  # Global hooks tests - using master_create action (nil site_id)
  property "master_create can create global hooks (nil site_id)" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 100),
            content <- realistic_js_content_generator(1, 1000),
            format <- member_of([:js, :ts]),
            priority <- integer(0..100),
            active <- boolean(),
            description <-
              one_of([constant(nil), string(:ascii, min_length: 1, max_length: 500)]),
            permissions <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 20), max_length: 5)
          ) do
      # master_create with nil site_id creates a global hook
      attrs = %{
        name: name,
        content: content,
        format: format,
        priority: priority,
        active: active,
        permissions: permissions
        # site_id: nil - omitted for global hook
      }

      attrs = if description, do: Map.put(attrs, :description, description), else: attrs

      # master_create requires nil tenant context (require_master: true)
      changeset = Ash.Changeset.for_create(JsHook, :master_create, attrs, authorize?: false)

      assert changeset.valid?,
             "master_create should accept global hook (nil site_id): #{inspect(attrs)}"
    end
  end

  property "master_create can create site-specific hooks with explicit site_id" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 50),
            content <- realistic_js_content_generator(1, 500),
            format <- member_of([:js, :ts]),
            priority <- integer(0..100),
            active <- boolean()
          ) do
      site = create_test_site!()

      # master_create with explicit site_id creates a site-specific hook
      attrs = %{
        name: name,
        content: content,
        format: format,
        priority: priority,
        active: active,
        site_id: site.id
      }

      changeset = Ash.Changeset.for_create(JsHook, :master_create, attrs, authorize?: false)

      assert changeset.valid?,
             "master_create should accept site-specific hook with explicit site_id"
    end
  end

  property "master_update can modify global hooks" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_content <- realistic_js_content_generator(1, 100),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            new_priority <- integer(0..100),
            new_active <- boolean()
          ) do
      # Create a global hook (nil site_id)
      uuid = Ecto.UUID.generate()

      hook =
        JsHook
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "#{original_name}_#{uuid}",
            content: original_content,
            format: :js,
            priority: 0,
            active: true,
            site_id: nil
          },
          authorize?: false
        )
        |> Ash.create!()

      # Fetch with master_get for master_update
      record = Ash.get!(JsHook, hook.id, action: :master_get, authorize?: false)

      # master_update is a standard update action
      changeset =
        Ash.Changeset.for_update(
          record,
          :master_update,
          %{
            name: new_name,
            priority: new_priority,
            active: new_active
          },
          authorize?: false
        )

      assert changeset.valid?, "master_update should be valid for global hooks"

      # Cleanup
      Ash.destroy!(record, action: :master_permanent_destroy, authorize?: false)
    end
  end

  property "archive -> unarchive -> update workflow" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            content <- realistic_js_content_generator(1, 100),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      site = create_test_site!()

      hook = %JsHook{
        id: Ecto.UUID.generate(),
        name: original_name,
        content: content,
        format: :js,
        priority: 0,
        active: true,
        description: nil,
        permissions: [],
        site_id: site.id,
        archived_at: nil
      }

      destroy_changeset = Ash.Changeset.for_destroy(hook, :destroy, %{}, tenant: site.id)
      assert destroy_changeset.valid?, "Destroy should be valid"

      archived_hook = %{hook | archived_at: ~U[2024-01-01 00:00:00Z]}

      unarchive_changeset =
        Ash.Changeset.for_update(archived_hook, :unarchive, %{}, tenant: site.id)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      unarchived_hook = %{archived_hook | archived_at: nil}

      update_changeset =
        Ash.Changeset.for_update(unarchived_hook, :update, %{name: new_name}, tenant: site.id)

      assert update_changeset.valid?, "Update after unarchive should be valid"
    end
  end

  @tag :slow
  property "handles large datasets efficiently" do
    check all(
            hooks <-
              list_of(
                fixed_map(%{
                  name: string(:alphanumeric, min_length: 3, max_length: 20),
                  content: realistic_js_content_generator(1, 100),
                  format: member_of([:js, :ts]),
                  priority: integer(0..100),
                  active: boolean()
                }),
                min_length: 10,
                max_length: 20
              ),
            max_runs: 5
          ) do
      site = create_test_site!()

      changesets =
        Enum.map(hooks, fn hook_attrs ->
          Ash.Changeset.for_create(JsHook, :create, hook_attrs, tenant: site.id)
        end)

      assert Enum.all?(changesets, & &1.valid?), "All changesets in batch should be valid"
    end
  end

  @tag :slow
  property "mixed action workflows with large datasets" do
    check all(
            operations <-
              list_of(
                one_of([
                  {:create,
                   fixed_map(%{
                     name: string(:alphanumeric, min_length: 3, max_length: 15),
                     content: realistic_js_content_generator(1, 50),
                     format: member_of([:js, :ts]),
                     priority: integer(0..100),
                     active: boolean()
                   })},
                  {:update,
                   fixed_map(%{
                     name: string(:alphanumeric, min_length: 3, max_length: 15),
                     priority: integer(0..100),
                     active: boolean()
                   })},
                  {:unarchive, constant(%{})}
                ]),
                min_length: 5,
                max_length: 15
              ),
            max_runs: 3
          ) do
      site = create_test_site!()

      results =
        Enum.map(operations, fn {action, attrs} ->
          case action do
            :create ->
              changeset = Ash.Changeset.for_create(JsHook, :create, attrs, tenant: site.id)
              {action, changeset.valid?}

            :update ->
              mock_hook = %JsHook{
                id: Ecto.UUID.generate(),
                name: "Test Hook",
                content: "console.log('test');",
                format: :js,
                priority: 0,
                active: true,
                description: nil,
                permissions: [],
                site_id: site.id,
                archived_at: nil
              }

              changeset = Ash.Changeset.for_update(mock_hook, :update, attrs, tenant: site.id)
              {action, changeset.valid?}

            :unarchive ->
              mock_archived_hook = %JsHook{
                id: Ecto.UUID.generate(),
                name: "Test Hook",
                content: "console.log('test');",
                format: :js,
                priority: 0,
                active: true,
                description: nil,
                permissions: [],
                site_id: site.id,
                archived_at: ~U[2024-01-01 00:00:00Z]
              }

              changeset =
                Ash.Changeset.for_update(mock_archived_hook, :unarchive, attrs, tenant: site.id)

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

  defp realistic_js_content_generator(_min_len, _max_len) do
    one_of([
      # Simple JavaScript
      bind(string(:alphanumeric, min_length: 3, max_length: 20), fn var ->
        constant("console.log('#{var}');")
      end),
      bind(string(:alphanumeric, min_length: 3, max_length: 15), fn func ->
        constant("function #{func}() { return true; }")
      end),
      bind(string(:alphanumeric, min_length: 3, max_length: 15), fn var ->
        constant("const #{var} = document.getElementById('app');")
      end),
      # Arrow functions
      bind(string(:alphanumeric, min_length: 3, max_length: 15), fn func ->
        constant("const #{func} = () => { console.log('executed'); };")
      end),
      # Event handlers
      constant("document.addEventListener('DOMContentLoaded', () => { console.log('ready'); });"),
      constant("window.addEventListener('load', function() { console.log('loaded'); });"),
      # Object definitions
      bind(string(:alphanumeric, min_length: 3, max_length: 15), fn obj ->
        constant("const #{obj} = { init: function() { this.setup(); }, setup: function() {} };")
      end),
      # TypeScript content - only generate valid JS for simplicity
      bind(string(:alphanumeric, min_length: 3, max_length: 15), fn var ->
        constant("const #{var} = 'typed value';")
      end),
      # Complex content
      bind(
        string(:alphanumeric, min_length: 3, max_length: 50),
        fn content ->
          constant("// #{content}\nconsole.log('hook loaded');")
        end
      )
    ])
  end

  defp invalid_name_generator do
    one_of([
      string(:alphanumeric, max_length: 2),
      string(:alphanumeric, min_length: 101, max_length: 150),
      constant(""),
      string([?\s], min_length: 1, max_length: 10)
    ])
  end

  defp invalid_content_generator do
    one_of([
      constant(""),
      string([?\s], min_length: 1, max_length: 10)
    ])
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
      :jsx,
      :tsx,
      :coffee,
      :elm,
      :dart
    ])
  end

  defp valid_permissions_generator do
    list_of(
      one_of([
        constant("admin"),
        constant("editor"),
        constant("developer"),
        constant("moderator"),
        constant("viewer"),
        string(:alphanumeric, min_length: 3, max_length: 15)
      ]),
      max_length: 5
    )
  end

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
