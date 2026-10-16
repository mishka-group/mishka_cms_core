# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.PagePropertyTest do
  @moduledoc """
  Property tests for the Page resource.

  These generate documents carrying `events`, `infos` and `helpers`, which
  `MishkaCmsCore.Runtime.Resources.Validations.CodeChange` refuses from a write that names no actor.
  They declare themselves the way a seed does — `context: %{page_code: :package}` — because that is
  what they are: fixture generation, not somebody typing Elixir into the admin console. What they
  are testing is the SHAPE the resource accepts, and adding a real user per generated case would
  cost a database round trip per iteration to test something these do not claim to cover.

  Who writes a page's code is covered against the real path in
  `MishkaCmsCore.Runtime.RuntimeSectionRulesTest`.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.Page
  @moduletag :property

  property "accepts all valid input combinations" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            section <- one_of([nil, valid_section_generator()]),
            template <- valid_template_generator(),
            description <- one_of([nil, valid_description_generator()]),
            format <- member_of([:heex, :eex, :markdown]),
            priority <- integer(0..100),
            extra <- simple_map_generator(),
            content <- simple_map_generator(),
            seo_tags <- seo_tags_generator(),
            schema <- schema_generator(),
            events <- events_generator(),
            infos <- infos_generator(),
            resource_links <- resource_links_generator(),
            permissions <-
              list_of(string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 20),
                max_length: 10
              )
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            section: section,
            template: template,
            description: description,
            format: format,
            priority: priority,
            extra: extra,
            content: content,
            seo_tags: seo_tags,
            schema: schema,
            events: events,
            infos: infos,
            resource_links: resource_links,
            permissions: permissions
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, path: path, template: String.slice(template, 0, 20), format: format, priority: priority})}"
    end
  end

  property "accepts minimal valid inputs" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Minimal valid inputs should create valid changeset: name=#{name}, path=#{path}, template=#{String.slice(template, 0, 10)}"
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
            path_part <- string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_], length: 254),
            template <-
              map(
                string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 200, max_length: 200),
                &"<section>#{&1}</section>"
              ),
            description <-
              string([?\s, ?a..?z, ?A..?Z, ?0..?9], min_length: 500, max_length: 500),
            priority <- constant(100)
          ) do
      site = create_test_site!()

      # Ensure path starts with /
      valid_path = "/" <> path_part

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: valid_path,
            template: template,
            description: description,
            priority: priority
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Maximal valid inputs should create valid changeset"
    end
  end

  property "rejects invalid names" do
    check all(
            invalid_name <- invalid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: invalid_name,
            title: "Page Title",
            path: path,
            template: template
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      refute changeset.valid?,
             "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid paths" do
    check all(
            name <- valid_name_generator(),
            invalid_path <- invalid_path_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: invalid_path,
            template: template
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      refute changeset.valid?,
             "Expected invalid changeset for path: #{inspect(invalid_path)}"
    end
  end

  property "rejects invalid templates" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            invalid_template <- invalid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: invalid_template
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      refute changeset.valid?,
             "Expected invalid changeset for template: #{inspect(invalid_template)}"
    end
  end

  property "rejects invalid priority values" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            invalid_priority <- invalid_priority_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            priority: invalid_priority
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      refute changeset.valid?,
             "Expected invalid changeset for priority: #{invalid_priority}"
    end
  end

  property "rejects invalid format values" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            invalid_format <- member_of([:invalid, :html, :jsx, :vue])
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            format: invalid_format
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      refute changeset.valid?,
             "Expected invalid changeset for format: #{invalid_format}"
    end
  end

  property "rejects missing required fields" do
    check all(
            include_title <- boolean(),
            include_path <- boolean(),
            include_template <- boolean(),
            title <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            priority <- integer(0..100)
          ) do
      site = create_test_site!()

      attrs = %{}
      attrs = if include_title, do: Map.put(attrs, :title, title), else: attrs
      attrs = if include_path, do: Map.put(attrs, :path, path), else: attrs
      attrs = if include_template, do: Map.put(attrs, :template, template), else: attrs
      attrs = Map.put(attrs, :priority, priority)

      changeset =
        Ash.Changeset.for_create(Page, :create, attrs,
          tenant: site.id,
          context: %{page_code: :package}
        )

      # TEMPLATE IS OPTIONAL NOW: leaving it out means an empty page, which the create action fills
      # with the starter container. NAME IS NOT ASKED FOR AT ALL: `Changes.NameFromTitle` derives
      # it from the title on create. What a page cannot be written without is a title and a path.
      if include_title and include_path do
        assert changeset.valid?,
               "Expected valid changeset when title and path are present: #{inspect(attrs)}"
      else
        refute changeset.valid?,
               "Expected invalid changeset when required field missing: #{inspect(attrs)}"
      end
    end
  end

  property "handles boundary values correctly" do
    check all(
            name_length <- member_of([3, 200]),
            # 2 because we need "/" + 1 char minimum
            path_length <- member_of([2, 255]),
            template_length <- member_of([3, 200]),
            priority <- member_of([0, 100])
          ) do
      site = create_test_site!()

      name = "a" <> String.duplicate("b", name_length - 1)
      path = "/" <> String.duplicate("p", path_length - 1)
      # Text, not `<ttt>`: an unclosed tag is not a template of any length, and the property is
      # about the length boundary rather than about markup.
      template = String.duplicate("t", template_length)

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            priority: priority
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, path_len=#{path_length}, template_len=#{template_length}, priority=#{priority}"
    end
  end

  property "handles whitespace trimming correctly" do
    check all(
            base_name <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 3, max_length: 190),
            base_path <- string([?a..?z, ?A..?Z, ?0..?9, ?/], min_length: 2, max_length: 245),
            base_template <-
              map(
                string([?a..?z, ?A..?Z, ?0..?9], min_length: 3, max_length: 190),
                &"<div>#{&1}</div>"
              ),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      site = create_test_site!()

      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      clean_path = "/" <> String.trim_leading(String.replace(base_path, ~r{/+}, "/"), "/")

      padded_path =
        "#{String.duplicate(" ", leading_spaces)}#{clean_path}#{String.duplicate(" ", trailing_spaces)}"

      padded_template =
        "#{String.duplicate(" ", leading_spaces)}#{base_template}#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: padded_name,
            title: padded_name,
            path: padded_path,
            template: padded_template
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      # Should be valid due to trimming
      assert changeset.valid?, "Should be valid after trimming whitespace"
    end
  end

  property "validates seo_tags structure correctly" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            seo_tags <- seo_tags_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            seo_tags: seo_tags
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Valid seo_tags structure should create valid changeset: #{inspect(seo_tags)}"
    end
  end

  property "validates events structure correctly" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            events <- events_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            events: events
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Valid events structure should create valid changeset: #{inspect(events)}"
    end
  end

  property "validates infos structure correctly" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            infos <- infos_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            infos: infos
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Valid infos structure should create valid changeset: #{inspect(infos)}"
    end
  end

  property "validates resource_links structure correctly" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            resource_links <- resource_links_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            resource_links: resource_links
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?,
             "Valid resource_links structure should create valid changeset: #{inspect(resource_links)}"
    end
  end

  property "allows same name and path across different sites" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator()
          ) do
      # Generate unique site names and hosts to avoid conflicts
      unique_id1 = System.unique_integer([:positive])
      unique_id2 = System.unique_integer([:positive])

      site1 = create_test_site!(name: "Site#{unique_id1}", host: "site#{unique_id1}.com")
      site2 = create_test_site!(name: "Site#{unique_id2}", host: "site#{unique_id2}.com")

      changeset1 =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template
          },
          tenant: site1.id
        )

      changeset2 =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template
          },
          tenant: site2.id
        )

      assert changeset1.valid?, "First page should be valid"

      assert changeset2.valid?,
             "Second page with same name/path on different site should be valid"
    end
  end

  property "pages require site_id (tenant)" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator()
          ) do
      # Test that creating without tenant fails
      assert_raise Ash.Error.Invalid, fn ->
        Page
        |> Ash.Changeset.for_create(:create, %{
          name: name,
          title: name,
          path: path,
          template: template
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end

  property "update action accepts valid changes on non-archived pages" do
    check all(
            original_name <- valid_name_generator(),
            original_path <- valid_path_generator(),
            original_template <- valid_template_generator(),
            new_name <- valid_name_generator(),
            new_section <- valid_section_generator(),
            new_priority <- integer(0..100),
            new_format <- member_of([:heex, :eex, :markdown])
          ) do
      site = create_test_site!()

      page = %Page{
        id: Ecto.UUID.generate(),
        name: original_name,
        title: original_name,
        path: original_path,
        template: original_template,
        site_id: site.id,
        format: :heex,
        priority: 0,
        extra: %{},
        content: %{},
        seo_tags: [],
        schema: [],
        events: [],
        infos: [],
        resource_links: [],
        helpers: [],
        permissions: [],
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          page,
          :update,
          %{
            name: new_name,
            section: new_section,
            priority: new_priority,
            format: new_format
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?, "Update should be valid for non-archived page"
    end
  end

  property "update action rejects changes on archived pages" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            new_name <- valid_name_generator()
          ) do
      site = create_test_site!()

      archived_page = %Page{
        id: Ecto.UUID.generate(),
        name: name,
        title: name,
        path: path,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: 0,
        extra: %{},
        content: %{},
        seo_tags: [],
        schema: [],
        events: [],
        infos: [],
        resource_links: [],
        helpers: [],
        permissions: [],
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_page,
          :update,
          %{
            name: new_name
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      refute changeset.valid?, "Update should be invalid for archived page"
    end
  end

  property "unarchive action works on archived pages" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            priority <- integer(0..100)
          ) do
      site = create_test_site!()

      archived_page = %Page{
        id: Ecto.UUID.generate(),
        name: name,
        title: name,
        path: path,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: priority,
        extra: %{},
        content: %{},
        seo_tags: [],
        schema: [],
        events: [],
        infos: [],
        resource_links: [],
        helpers: [],
        permissions: [],
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset = Ash.Changeset.for_update(archived_page, :unarchive, %{}, tenant: site.id)
      assert changeset.valid?, "Unarchive should work on archived pages"
    end
  end

  property "applies default values correctly" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator()
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?

      # Test that defaults would be applied (we can't test the actual values without creating)
      assert changeset.attributes[:format] == nil or changeset.attributes[:format] == :heex
      assert changeset.attributes[:priority] == nil or changeset.attributes[:priority] == 0
      assert changeset.attributes[:extra] == nil or changeset.attributes[:extra] == %{}
      assert changeset.attributes[:content] == nil or changeset.attributes[:content] == %{}
    end
  end

  @tag :slow
  property "handles complex page configurations" do
    check all(
            name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            description <- valid_description_generator(),
            seo_tags <- seo_tags_generator(),
            schema <- schema_generator(),
            events <- events_generator(),
            infos <- infos_generator(),
            resource_links <- resource_links_generator(),
            permissions <-
              list_of(string([?a..?z, ?A..?Z, ?0..?9], min_length: 3, max_length: 20),
                max_length: 5
              ),
            max_runs: 10
          ) do
      site = create_test_site!()

      changeset =
        Ash.Changeset.for_create(
          Page,
          :create,
          %{
            name: name,
            title: name,
            path: path,
            template: template,
            description: description,
            seo_tags: seo_tags,
            schema: schema,
            events: events,
            infos: infos,
            resource_links: resource_links,
            permissions: permissions
          },
          tenant: site.id,
          context: %{page_code: :package}
        )

      assert changeset.valid?, "Complex page configuration should be valid"
    end
  end

  property "archive -> unarchive -> update workflow" do
    check all(
            original_name <- valid_name_generator(),
            path <- valid_path_generator(),
            template <- valid_template_generator(),
            new_name <- valid_name_generator()
          ) do
      site = create_test_site!()

      page = %Page{
        id: Ecto.UUID.generate(),
        name: original_name,
        title: original_name,
        path: path,
        template: template,
        site_id: site.id,
        format: :heex,
        priority: 0,
        extra: %{},
        content: %{},
        seo_tags: [],
        schema: [],
        events: [],
        infos: [],
        resource_links: [],
        helpers: [],
        permissions: [],
        archived_at: nil
      }

      # Destroy (archive)
      destroy_changeset = Ash.Changeset.for_destroy(page, :destroy, %{}, tenant: site.id)
      assert destroy_changeset.valid?, "Destroy should be valid"

      # Simulate archived state
      archived_page = %{page | archived_at: ~U[2024-01-01 00:00:00Z]}

      # Unarchive
      unarchive_changeset =
        Ash.Changeset.for_update(archived_page, :unarchive, %{}, tenant: site.id)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      # Simulate unarchived state
      unarchived_page = %{archived_page | archived_at: nil}

      # Update after unarchive
      update_changeset =
        Ash.Changeset.for_update(unarchived_page, :update, %{name: new_name}, tenant: site.id)

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

  defp valid_path_generator do
    bind(string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_], min_length: 1, max_length: 254), fn path_part ->
      constant("/" <> path_part)
    end)
  end

  defp valid_section_generator do
    string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?-, ?_], min_length: 1, max_length: 50)
  end

  # VALID MEANS THE COMPILER CAN READ IT. The random branch here used to draw from an alphabet that
  # included `<`, `>`, `%` and `@`, so it produced strings like `5s<` and `a"<@%/` — markup-shaped
  # noise that no HEEx engine could parse and that no page could ever have rendered. It only ever
  # passed because nothing checked; `Validations.PageCodeCompiles` checks now, and a generator whose
  # name says "valid" has to mean it.
  #
  # Varied is still the point, so the text and the tag both vary — just inside markup that parses.
  defp valid_template_generator do
    one_of([
      constant("<div>test</div>"),
      constant("<section><%= @content %></section>"),
      constant("<article><h1><%= @title %></h1><%= @body %></article>"),
      constant("<main><%= @children %></main>"),
      bind(
        member_of(~w(div section article main p span header footer)),
        fn tag ->
          bind(
            string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?-, ?_, ?., ?,], min_length: 1, max_length: 40),
            fn text -> constant("<#{tag}>#{text}</#{tag}>") end
          )
        end
      )
    ])
  end

  defp valid_description_generator do
    string([?\s, ?a..?z, ?A..?Z, ?0..?9, ?., ?,, ?!, ??], max_length: 500)
  end

  # BLANK IS NO LONGER A NAME AT ALL. An empty or whitespace-only name is read as "no name given",
  # and `Changes.NameFromTitle` derives one from the title, so the two blank branches this used to
  # draw describe a page that is now created rather than refused. What is still refused is a name
  # the writer did give at a length the attribute does not allow.
  defp invalid_name_generator do
    one_of([
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 2),
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 201, max_length: 250)
    ])
  end

  defp invalid_path_generator do
    one_of([
      # No leading slash
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 20),
      constant(""),
      string([?\s], min_length: 1, max_length: 10),
      # Too long
      string([?a..?z, ?A..?Z, ?0..?9], min_length: 256, max_length: 300)
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
      constant(%{config: %{enabled: true}}),
      constant(%{title: "Test", body: "Content"})
    ])
  end

  defp seo_tags_generator do
    list_of(
      fixed_map(%{
        tag: member_of(["meta", "title", "link"]),
        attrs:
          one_of([
            constant(%{name: "description", content: "test"}),
            constant(%{property: "og:title", content: "test"}),
            constant(%{rel: "canonical", href: "http://example.com"})
          ]),
        content: one_of([nil, string([?a..?z, ?A..?Z, ?\s], min_length: 1, max_length: 100)])
      }),
      max_length: 5
    )
  end

  defp schema_generator do
    list_of(
      one_of([
        constant(%{
          "@context" => "https://schema.org",
          "@type" => "WebPage",
          "name" => "Test Page"
        }),
        constant(%{
          "@context" => "https://schema.org",
          "@type" => "Article",
          "headline" => "Test Article",
          "author" => %{"@type" => "Person", "name" => "Test Author"}
        }),
        simple_map_generator()
      ]),
      max_length: 3
    )
  end

  # A HANDLER'S CODE IS ELIXIR. Two of the three bodies here were not: `console.log('clicked')` is
  # JavaScript, which is how easy it is for this to go unnoticed when nothing reads the field, and
  # the charlist in the PubSub line has been deprecated for years. Both compile into the page's
  # LiveView module, so both would have broken the page for a real author.
  defp events_generator do
    list_of(
      fixed_map(%{
        name: member_of(["click", "submit", "change", "focus", "blur"]),
        code:
          member_of([
            "{:noreply, socket}",
            ~S|{:noreply, assign(socket, :clicked, true)}|,
            ~S|{:noreply, push_event(socket, "custom", %{})}|
          ])
      }),
      max_length: 5
    )
  end

  defp infos_generator do
    list_of(
      fixed_map(%{
        name: member_of(["timer", "broadcast", "notification"]),
        code:
          member_of([
            "{:noreply, socket}",
            ~S|Process.send_after(self(), :tick, 1000)
               {:noreply, socket}|,
            ~S|{:noreply, assign(socket, :seen, true)}|
          ])
      }),
      max_length: 3
    )
  end

  defp resource_links_generator do
    list_of(
      fixed_map(%{
        type: member_of(["stylesheet", "script", "font", "icon"]),
        href:
          member_of([
            "/css/app.css",
            "/js/app.js",
            "https://fonts.googleapis.com/css2?family=Inter",
            "/favicon.ico"
          ]),
        rel: one_of([nil, member_of(["stylesheet", "preload", "icon"])]),
        media: one_of([nil, constant("screen")]),
        integrity: one_of([nil, constant("sha384-example")]),
        crossorigin: one_of([nil, constant("anonymous")]),
        attrs: one_of([nil, constant(%{defer: true}), constant(%{async: true})])
      }),
      max_length: 5
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
end
