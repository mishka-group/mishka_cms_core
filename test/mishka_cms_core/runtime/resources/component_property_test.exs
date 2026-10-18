# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.ComponentPropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.Component
  alias Phoenix.LiveView.HTMLEngine
  @moduletag :property

  property "accepts all valid input combinations" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            description <- one_of([nil, valid_description_generator()]),
            body <- one_of([nil, valid_body_generator()]),
            format <- member_of([:heex, :eex, :markdown]),
            priority <- integer(0..100),
            extra <- simple_map_generator(),
            attrs <- component_attrs_generator(),
            slots <- component_slots_generator(),
            _helpers <-
              list_of(string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 20),
                max_length: 5
              ),
            permissions <-
              list_of(string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 20),
                max_length: 10
              )
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            description: description,
            body: body,
            format: format,
            priority: priority,
            extra: extra,
            attrs: attrs,
            slots: slots,
            permissions: permissions
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, template: String.slice(template, 0, 20), format: format, priority: priority})}"
    end
  end

  property "accepts minimal valid inputs" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      # Hardcoded examples for testing
      examples = [
        "<.component_example arg=\"value1\" />",
        "<.component_example arg=\"value2\" class=\"custom\" />",
        "<.component_example><:slot>Content</:slot></.component_example>"
      ]

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            examples: examples
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Minimal valid inputs should create valid changeset: name=#{name}, template=#{String.slice(template, 0, 10)}"
    end
  end

  property "accepts maximal valid inputs" do
    check all(
            name <-
              string([?A..?Z], length: 1)
              |> bind(fn first ->
                string([?a..?z, ?A..?Z, ?0..?9, ?\s], length: 99)
                |> map(fn rest ->
                  first <> rest
                end)
              end),
            template <-
              string([?a..?z, ?A..?Z], min_length: 5, max_length: 10)
              |> bind(fn content ->
                constant("<div>#{content}</div>")
              end),
            description <- string([?a..?z, ?A..?Z, ?\s], length: 500),
            priority <- constant(100)
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            description: description,
            priority: priority
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Maximal valid inputs should create valid changeset"
    end
  end

  property "accepts global components (no site_id)" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            format <- member_of([:heex, :eex, :markdown]),
            priority <- integer(0..100)
          ) do
      # Global components must use master_create action
      changeset =
        Ash.Changeset.for_create(
          Component,
          :master_create,
          %{
            name: name,
            template: template,
            format: format,
            priority: priority,
            site_id: nil
          },
          authorize?: false
        )

      assert changeset.valid?,
             "Global components should be valid: name=#{name}, format=#{format}"
    end
  end

  property "rejects invalid names" do
    check all(
            invalid_name <- invalid_name_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: invalid_name,
            template: template
          },
          tenant: site.id,
          authorize?: false
        )

      refute changeset.valid?,
             "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid templates" do
    check all(
            name <- valid_name_generator(),
            invalid_template <- invalid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: invalid_template
          },
          tenant: site.id,
          authorize?: false
        )

      refute changeset.valid?,
             "Expected invalid changeset for template: #{inspect(invalid_template)}"
    end
  end

  property "rejects invalid priority values" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            invalid_priority <- invalid_priority_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            priority: invalid_priority
          },
          tenant: site.id,
          authorize?: false
        )

      refute changeset.valid?,
             "Expected invalid changeset for priority: #{invalid_priority}"
    end
  end

  property "rejects invalid format values" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            invalid_format <- member_of([:invalid, :html, :jsx, :vue])
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            format: invalid_format
          },
          tenant: site.id,
          authorize?: false
        )

      refute changeset.valid?,
             "Expected invalid changeset for format: #{invalid_format}"
    end
  end

  property "rejects missing required fields" do
    check all(
            include_name <- boolean(),
            include_template <- boolean(),
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            priority <- integer(0..100)
          ) do
      site = create_test_site!()

      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
      attrs = if include_template, do: Map.put(attrs, :template, template), else: attrs
      attrs = Map.put(attrs, :priority, priority)

      changeset =
        Ash.Changeset.for_create(Component, :create, attrs, tenant: site.id, authorize?: false)

      # TEMPLATE IS OPTIONAL NOW: leaving it out means an empty component, which the create action
      # fills with the starter container. Only `name` is still required.
      if include_name do
        assert changeset.valid?,
               "Expected valid changeset whenever name is present: #{inspect(attrs)}"
      else
        refute changeset.valid?,
               "Expected invalid changeset when name is missing: #{inspect(attrs)}"
      end
    end
  end

  property "handles boundary values correctly" do
    check all(
            name_length <- member_of([3, 100]),
            template_length <- member_of([3, 200]),
            priority <- member_of([0, 100])
          ) do
      site = create_test_site!()

      name = "a" <> String.duplicate("b", name_length - 1)
      # PLAIN TEXT IS A TEMPLATE, and `<ttt>` is not: an unclosed tag of the requested length was
      # never markup, it was a string that happened to start with an angle bracket. The length under
      # test is preserved exactly; what changes is that it is now a template.
      template = String.duplicate("t", template_length)

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            priority: priority
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, template_len=#{template_length}, priority=#{priority}"
    end
  end

  property "handles whitespace trimming correctly" do
    check all(
            base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 3, max_length: 90),
            # Without `?<` and `?>`: this property is about TRIMMING, and a random soup of angle
            # brackets is not a template — it only ever tested that nothing read the markup.
            base_template <-
              string([?a..?z, ?A..?Z, ?0..?9], min_length: 3, max_length: 190),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      site = create_test_site!()

      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      padded_template =
        "#{String.duplicate(" ", leading_spaces)}#{base_template}#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: padded_name,
            template: padded_template
          },
          tenant: site.id,
          authorize?: false
        )

      # Should be valid due to trimming
      assert changeset.valid?, "Should be valid after trimming whitespace"
    end
  end

  property "validates attrs structure correctly" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            attrs <- component_attrs_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            attrs: attrs
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Valid attrs structure should create valid changeset: #{inspect(attrs)}"
    end
  end

  property "validates slots structure correctly" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            slots <- component_slots_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            slots: slots
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Valid slots structure should create valid changeset: #{inspect(slots)}"
    end
  end

  property "allows same name across different sites" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator()
          ) do
      # Generate unique site names and hosts to avoid conflicts
      unique_id1 = System.unique_integer([:positive])
      unique_id2 = System.unique_integer([:positive])

      site1 = create_test_site!(name: "Site#{unique_id1}", host: "site#{unique_id1}.com")
      site2 = create_test_site!(name: "Site#{unique_id2}", host: "site#{unique_id2}.com")

      changeset1 =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template
          },
          tenant: site1.id,
          authorize?: false
        )

      changeset2 =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template
          },
          tenant: site2.id,
          authorize?: false
        )

      assert changeset1.valid?, "First component should be valid"

      assert changeset2.valid?,
             "Second component with same name on different site should be valid"
    end
  end

  property "allows same name for global and site-specific components" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      # Global components must use master_create action
      global_changeset =
        Ash.Changeset.for_create(
          Component,
          :master_create,
          %{
            name: name,
            template: template,
            site_id: nil
          },
          authorize?: false
        )

      site_changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template
          },
          tenant: site.id,
          authorize?: false
        )

      assert global_changeset.valid?, "Global component should be valid"
      assert site_changeset.valid?, "Site component with same name should be valid"
    end
  end

  property "update action accepts valid changes on non-archived components" do
    check all(
            original_name <- valid_name_generator(),
            original_template <- valid_template_generator(),
            new_name <- valid_name_generator(),
            new_priority <- integer(0..100),
            new_format <- member_of([:heex, :eex, :markdown])
          ) do
      site = create_test_site!()

      component = %Component{
        id: Ecto.UUID.generate(),
        name: original_name,
        template: original_template,
        site_id: site.id,
        format: :heex,
        priority: 0,
        extra: %{},
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          component,
          :update,
          %{
            name: new_name,
            priority: new_priority,
            format: new_format
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?, "Update should be valid for non-archived component"
    end
  end

  property "update action rejects changes on archived components" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            new_name <- valid_name_generator()
          ) do
      site = create_test_site!()

      archived_component = %Component{
        id: Ecto.UUID.generate(),
        name: name,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: 0,
        extra: %{},
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_component,
          :update,
          %{
            name: new_name
          },
          tenant: site.id,
          authorize?: false
        )

      refute changeset.valid?, "Update should be invalid for archived component"
    end
  end

  property "unarchive action works on archived components" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            priority <- integer(0..100)
          ) do
      site = create_test_site!()

      archived_component = %Component{
        id: Ecto.UUID.generate(),
        name: name,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: priority,
        extra: %{},
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_component,
          :unarchive,
          %{},
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?, "Unarchive should work on archived components"
    end
  end

  property "destroy action (archive) works on any component" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            priority <- integer(0..100),
            is_archived <- boolean()
          ) do
      site = create_test_site!()

      # Create component through Ash
      component =
        Component
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: name,
            template: template,
            format: :heex,
            priority: priority,
            extra: %{},
            attrs: [],
            slots: [],
            helpers: [],
            permissions: []
          },
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      component =
        if is_archived do
          {:ok, archived} =
            Ash.destroy(component, authorize?: false, return_destroyed?: true, tenant: site.id)

          archived
        else
          component
        end

      changeset =
        Ash.Changeset.for_destroy(component, :destroy, %{}, tenant: site.id, authorize?: false)

      if is_archived do
        refute changeset.valid?, "Should not be able to destroy already archived component"
      else
        assert changeset.valid?, "Destroy should work on non-archived component"
      end
    end
  end

  property "permanent_destroy action works on any component" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            priority <- integer(0..100),
            is_archived <- boolean()
          ) do
      site = create_test_site!()

      archived_at = if is_archived, do: ~U[2024-01-01 00:00:00Z], else: nil

      component = %Component{
        id: Ecto.UUID.generate(),
        name: name,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: priority,
        extra: %{},
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        archived_at: archived_at
      }

      changeset =
        Ash.Changeset.for_destroy(
          component,
          :permanent_destroy,
          %{},
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?, "Permanent destroy should work on any component"
    end
  end

  property "applies default values correctly" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?

      # The defaults the resource declares are on the changeset before anything is written.
      assert changeset.attributes[:format] == :heex
      assert changeset.attributes[:priority] == 0
    end
  end

  @tag :slow
  property "handles complex component configurations" do
    check all(
            name <- valid_name_generator(),
            template <- valid_template_generator(),
            description <- valid_description_generator(),
            # THROUGH `uniquely_named/1`, LIKE EVERY OTHER DECLARATION GENERATOR IN THIS FILE. A
            # component declaring two slots called `r` is refused, correctly — `attr :r` twice is
            # not a complex configuration, it is an invalid one — and these two lists were the only
            # ones left unfiltered. With a one-letter alphabet a three-element list collides often
            # enough that this property failed on roughly one seed in five, in a file whose other
            # 22 properties passed: seed-dependent, and never the same property twice.
            attrs <-
              uniquely_named(
                list_of(
                  fixed_map(%{
                    name: declarable_name(20),
                    type: member_of(["string", "integer", "boolean", "map"]),
                    opts: constant(%{default: "test"})
                  }),
                  max_length: 5
                )
              ),
            slots <-
              uniquely_named(
                list_of(
                  fixed_map(%{
                    name: declarable_name(20),
                    opts: constant(%{required: true})
                  }),
                  max_length: 3
                )
              ),
            permissions <-
              list_of(
                string([?a..?z, ?A..?Z, ?0..?9], min_length: 3, max_length: 20),
                max_length: 5
              ),
            max_runs: 10
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Component,
          :create,
          %{
            name: name,
            template: template,
            description: description,
            attrs: attrs,
            slots: slots,
            permissions: permissions
          },
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?,
             "Complex component configuration should be valid"
    end
  end

  property "archive -> unarchive -> update workflow" do
    check all(
            original_name <- valid_name_generator(),
            template <- valid_template_generator(),
            new_name <- valid_name_generator()
          ) do
      site = create_test_site!()

      component = %Component{
        id: Ecto.UUID.generate(),
        name: original_name,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: 0,
        extra: %{},
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        archived_at: nil
      }

      # Destroy (archive)
      destroy_changeset =
        Ash.Changeset.for_destroy(component, :destroy, %{}, tenant: site.id, authorize?: false)

      assert destroy_changeset.valid?, "Destroy should be valid"

      # Simulate archived state
      archived_component = %{component | archived_at: ~U[2024-01-01 00:00:00Z]}

      # Unarchive
      unarchive_changeset =
        Ash.Changeset.for_update(
          archived_component,
          :unarchive,
          %{},
          tenant: site.id,
          authorize?: false
        )

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      # Simulate unarchived state
      unarchived_component = %{archived_component | archived_at: nil}

      # Update after unarchive
      update_changeset =
        Ash.Changeset.for_update(
          unarchived_component,
          :update,
          %{name: new_name},
          tenant: site.id,
          authorize?: false
        )

      assert update_changeset.valid?, "Update after unarchive should be valid"
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  defp valid_name_generator do
    bind(string([?a..?z, ?A..?Z], length: 1), fn first_char ->
      bind(string([?a..?z, ?A..?Z, ?0..?9, ?\s], max_length: 19), fn rest ->
        name = String.trim(first_char <> rest)

        if String.length(name) >= 3 do
          constant(name)
        else
          constant(first_char <> "ab")
        end
      end)
    end)
  end

  defp valid_template_generator do
    one_of([
      constant("<div>test</div>"),
      constant("<span>content</span>"),
      constant("<p>hello world</p>"),
      constant("<section><%= @content %></section>"),
      # LOWERCASE TAGS ONLY. HEEx reads an uppercase tag as a component alias, so `<R>rpp</R>` is
      # not a valid template at all — and a property asserting the resource ACCEPTS it was asserting
      # that nothing looked at the markup.
      #
      # AND NEVER A VOID ELEMENT. `<br>` takes no content and no closing tag, so HEEx refuses
      # `<br>aaa</br>` — and a random tag is `br` often enough to fail a run now and then. The set is
      # asked of HEEx's own engine rather than listed here, so it is whatever HEEx says it is.
      bind(
        filter(string(?a..?z, min_length: 1, max_length: 5), &(not HTMLEngine.void?(&1))),
        fn tag ->
          bind(string([?a..?z, ?A..?Z, ?\s], min_length: 3, max_length: 40), fn content ->
            constant("<#{tag}>#{content}</#{tag}>")
          end)
        end
      )
    ])
  end

  defp valid_description_generator do
    string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 500)
  end

  defp valid_body_generator do
    string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 1000)
  end

  defp invalid_name_generator do
    one_of([
      string([?a..?z, ?A..?Z, ?0..?9], max_length: 2),
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 101, max_length: 150),
      constant(""),
      string([?\s], min_length: 1, max_length: 10)
    ])
  end

  # BLANK IS NO LONGER INVALID. An empty or whitespace-only template means "I will build it in the
  # editor" and is filled with the starter container by
  # `Changes.BlankTemplateStartsEmpty`, which `MishkaCmsCore.Runtime.PageTest` and
  # `MishkaCmsCore.Runtime.LayoutTest` assert against `PageStarter.blank/1`. What is still refused
  # is markup that
  # was given and is too short to be markup.
  defp invalid_template_generator do
    string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 2)
  end

  defp invalid_priority_generator do
    one_of([
      integer(-100..-1),
      integer(101..1000)
    ])
  end

  defp simple_map_generator do
    one_of([
      constant(%{}),
      constant(%{key: "value"}),
      constant(%{config: %{enabled: true}})
    ])
  end

  # ONE NAME, ONCE. `attr :j` twice is a Phoenix compile error, so a generator that collides is
  # generating exactly what `Validations.InterfaceDeclaration` is right to refuse.
  defp uniquely_named(generator) do
    map(generator, &Enum.uniq_by(&1, fn row -> row.name end))
  end

  # A NAME PHOENIX CAN DECLARE AND A TEMPLATE CAN READ. These generators drew from `?a..?z, ?A..?Z`,
  # so they produced names like "A" — and `attr :A` is declarable but `@A` is a syntax error, which
  # makes such an attribute unreadable by the component that declares it.
  # `Validations.InterfaceDeclaration` refuses them now; nothing in the kit has ever had one.
  defp declarable_name(max) do
    string([?a..?z], min_length: 1, max_length: max)
  end

  defp component_attrs_generator do
    uniquely_named(
      list_of(
        fixed_map(%{
          name: declarable_name(20),
          type: member_of(["string", "integer", "boolean", "map", "atom"]),
          struct_name: one_of([nil, string([?a..?z, ?A..?Z], min_length: 1, max_length: 30)]),
          opts: one_of([nil, constant(%{default: "test"}), constant(%{required: true})])
        }),
        max_length: 10
      )
    )
  end

  defp component_slots_generator do
    uniquely_named(
      list_of(
        fixed_map(%{
          name: declarable_name(20),
          opts: one_of([nil, constant(%{required: true}), constant(%{doc: "test slot"})]),
          # A SLOT'S OWN ATTRIBUTES NEED THE SAME UNIQUENESS THE SLOT LIST GOT. Two attributes of one
          # name are refused inside a slot exactly as they are at the top level, so without this the
          # "accepts all valid input" property drew invalid input and failed on roughly one seed in
          # eight — the same defect the outer lists were fixed for, one level down.
          attrs:
            one_of([
              nil,
              uniquely_named(
                list_of(
                  fixed_map(%{
                    name: declarable_name(15),
                    type: member_of(["string", "integer", "boolean"])
                  }),
                  max_length: 3
                )
              )
            ])
        }),
        max_length: 5
      )
    )
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

  # THE RULES ARE THE RESOURCE'S TOO. Enforced in the editor alone, the Components table form and any
  # import would have had none — so `Validations.InterfaceDeclaration` puts them at the action
  # boundary, where `CodeChange` and `TemplateCompiles` already are. `Interface.validate/2` holds the
  # rules themselves, because the editor wants them BEFORE a save as well.
  describe "a declaration that will not compile" do
    defp declaring(site, fields) do
      Ash.Changeset.for_create(
        Component,
        :create,
        Map.merge(%{name: "declared", template: "<div></div>"}, fields),
        tenant: site.id,
        authorize?: false
      )
    end

    # `attr :A` is declarable and `@A` is a syntax error, so such an attribute could never be read by
    # the component that declares it. Nothing in the kit has one — all 136 were checked.
    test "is refused for a name a template could never read" do
      site = create_test_site!()

      refute declaring(site, %{attrs: [%{name: "A", type: "string"}]}).valid?
      assert declaring(site, %{attrs: [%{name: "size", type: "string"}]}).valid?
    end

    test "is refused for the same name twice" do
      site = create_test_site!()
      rows = [%{name: "size", type: "string"}, %{name: "size", type: "integer"}]

      refute declaring(site, %{attrs: rows}).valid?
    end

    # Phoenix's own rule: "attributes should not have a default value if they are required".
    test "is refused for required together with a default" do
      site = create_test_site!()
      row = %{name: "size", type: "string", opts: %{"required" => true, "default" => "medium"}}

      refute declaring(site, %{attrs: [row]}).valid?
    end

    test "and a slot is held to the same rule" do
      site = create_test_site!()

      refute declaring(site, %{slots: [%{name: "Item"}]}).valid?
      assert declaring(site, %{slots: [%{name: "item"}]}).valid?
    end

    # Half-finished work has to be storable: whether the TEMPLATE agrees with the declaration is
    # advice the editor gives, never a write to refuse.
    test "but says nothing about an attribute the markup does not read yet" do
      site = create_test_site!()

      assert declaring(site, %{attrs: [%{name: "unused", type: "string"}]}).valid?
    end
  end
end
