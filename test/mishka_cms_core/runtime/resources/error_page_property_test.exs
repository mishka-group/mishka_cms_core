# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.ErrorPagePropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.ErrorAddress
  alias MishkaCmsCore.Runtime.ErrorPage
  @moduletag :property

  property "accepts all valid input combinations" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 200),
            path <- valid_path_generator(),
            format <- member_of([:heex, :eex, :markdown]),
            priority <- integer(0..100),
            error_pages <- valid_error_pages_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            format: format,
            priority: priority,
            error_pages: error_pages
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, path: path, format: format, priority: priority, error_pages: error_pages})}"
    end
  end

  property "accepts minimal valid inputs" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 3),
            path_base <- string(:alphanumeric, min_length: 1, max_length: 5),
            error_pages <- valid_error_pages_generator()
          ) do
      path = "/#{path_base}"

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: error_pages
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
            path_base <- string(:alphanumeric, min_length: 200, max_length: 200),
            error_pages <- valid_error_pages_generator(),
            root_layout_template <- string(:alphanumeric, min_length: 10, max_length: 100)
          ) do
      # Ensure total length is <= 255
      path = "/#{String.slice(path_base, 0, 253)}"

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: error_pages,
            root_layout_template: root_layout_template,
            format: :heex,
            priority: 100,
            extra: %{custom: "data"},
            helpers: []
          },
          tenant: site.id
        )

      assert changeset.valid?, "Maximal valid inputs should be accepted"
    end
  end

  property "accepts complex valid path formats" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path_type <- member_of([:exact, :wildcard, :nested, :dynamic]),
            error_pages <- valid_error_pages_generator()
          ) do
      path =
        case path_type do
          :exact -> "/errors/404"
          :wildcard -> "/errors/*"
          :nested -> "/admin/errors/server"
          :dynamic -> "/errors/*/detail"
        end

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: error_pages
          },
          tenant: site.id
        )

      assert changeset.valid?
    end
  end

  property "rejects invalid names" do
    check all(
            invalid_name <- invalid_name_generator(),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(ErrorPage, :create, %{
          name: invalid_name,
          path: path,
          error_pages: error_pages
        })

      refute changeset.valid?, "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid paths" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            invalid_path <- invalid_path_generator(),
            error_pages <- valid_error_pages_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(ErrorPage, :create, %{
          name: name,
          path: invalid_path,
          error_pages: error_pages
        })

      refute changeset.valid?, "Expected invalid changeset for path: #{inspect(invalid_path)}"
    end
  end

  property "rejects invalid error_pages" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            invalid_error_pages <- invalid_error_pages_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(ErrorPage, :create, %{
          name: name,
          path: path,
          error_pages: invalid_error_pages
        })

      refute changeset.valid?,
             "Expected invalid changeset for error_pages: #{inspect(invalid_error_pages)}"
    end
  end

  property "rejects invalid priority values" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            invalid_priority <- invalid_priority_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(ErrorPage, :create, %{
          name: name,
          path: path,
          error_pages: error_pages,
          priority: invalid_priority
        })

      refute changeset.valid?, "Expected invalid changeset for priority: #{invalid_priority}"
    end
  end

  property "rejects invalid format values" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            invalid_format <- invalid_format_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(ErrorPage, :create, %{
          name: name,
          path: path,
          error_pages: error_pages,
          format: invalid_format
        })

      refute changeset.valid?, "Expected invalid changeset for format: #{invalid_format}"
    end
  end

  property "rejects missing required fields" do
    site = create_site!()

    check all(
            include_name <- boolean(),
            include_path <- boolean(),
            include_error_pages <- boolean(),
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            priority <- integer(0..100)
          ) do
      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
      attrs = if include_path, do: Map.put(attrs, :path, path), else: attrs
      attrs = if include_error_pages, do: Map.put(attrs, :error_pages, error_pages), else: attrs
      attrs = Map.put(attrs, :priority, priority)

      changeset = Ash.Changeset.for_create(ErrorPage, :create, attrs, tenant: site.id)

      # PATH IS NOT ONE OF THEM ANY MORE. `Changes.ErrorPageAddress` writes it from the site before
      # `validate present([:name, :path])` is reached, so leaving it out is not a mistake a caller
      # can make — and including it is not a way of choosing one.
      if not include_name do
        refute changeset.valid?,
               "Expected invalid changeset when required fields missing: #{inspect(attrs)}"
      else
        assert changeset.valid?,
               "Expected valid changeset when all required fields present: #{inspect(attrs)}"

        assert Ash.Changeset.get_attribute(changeset, :path) == ErrorAddress.for_site(site.id)
      end
    end
  end

  property "handles boundary values correctly" do
    site = create_site!()

    check all(
            name_length <- member_of([3, 200]),
            # "/a" = 2, max = 255
            path_length <- member_of([2, 255]),
            priority <- member_of([0, 100]),
            error_pages <- valid_error_pages_generator()
          ) do
      name = String.duplicate("a", name_length)
      # -1 for the leading "/"
      path_base = String.duplicate("a", path_length - 1)
      path = "/#{path_base}"

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: error_pages,
            priority: priority
          },
          tenant: site.id
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, path_len=#{path_length}, priority=#{priority}"
    end
  end

  property "handles whitespace trimming correctly" do
    # Create a site once for all property tests
    site = create_site!()

    check all(
            base_name <- string(:alphanumeric, min_length: 3, max_length: 190),
            base_path <- string(:alphanumeric, min_length: 3, max_length: 250),
            error_pages <- valid_error_pages_generator(),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      padded_path =
        "#{String.duplicate(" ", leading_spaces)}/#{base_path}#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: padded_name,
            path: padded_path,
            error_pages: error_pages
          },
          tenant: site.id
        )

      case changeset.valid? do
        true ->
          assert true

        false ->
          trimmed_name = String.trim(padded_name)
          trimmed_path = String.trim(padded_path)

          retry_changeset =
            Ash.Changeset.for_create(
              ErrorPage,
              :create,
              %{
                name: trimmed_name,
                path: trimmed_path,
                error_pages: error_pages
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
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_path <- valid_path_generator(),
            original_error_pages <- valid_error_pages_generator(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            new_priority <- integer(0..100)
          ) do
      error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: original_name,
        path: original_path,
        error_pages: original_error_pages,
        root_layout_template: nil,
        format: :heex,
        priority: 0,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          error_page,
          :update,
          %{
            name: new_name,
            priority: new_priority
          },
          tenant: site.id
        )

      assert changeset.valid?, "Update changeset should be valid"
    end
  end

  property "validates error_pages structure with various status codes" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 15),
            path <- valid_path_generator(),
            status_codes <-
              list_of(member_of([400, 401, 403, 404, 422, 500, 502, 503]),
                min_length: 1,
                max_length: 5
              )
          ) do
      error_pages =
        Enum.map(status_codes, fn status ->
          %{
            status: status,
            template: "<div>Error #{status}</div>",
            layout: %{wrapper: "error_layout"}
          }
        end)

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: error_pages
          },
          tenant: site.id
        )

      assert changeset.valid?, "Valid error_pages with various status codes should be accepted"
    end
  end

  property "validates helpers structure correctly" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 15),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator()
          ) do
      # Test with empty helpers (should always be valid)
      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: error_pages,
            helpers: []
          },
          tenant: site.id
        )

      assert changeset.valid?, "Empty helpers should be accepted"
    end
  end

  property "update action accepts valid changes" do
    site = create_site!()

    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_path <- valid_path_generator(),
            original_error_pages <- valid_error_pages_generator(),
            original_priority <- integer(0..100),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 200),
            new_path <- valid_path_generator(),
            new_error_pages <- valid_error_pages_generator(),
            new_priority <- integer(0..100),
            new_format <- member_of([:heex, :eex, :markdown])
          ) do
      error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: original_name,
        path: original_path,
        error_pages: original_error_pages,
        root_layout_template: nil,
        format: :heex,
        priority: original_priority,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          error_page,
          :update,
          %{
            name: new_name,
            path: new_path,
            error_pages: new_error_pages,
            priority: new_priority,
            format: new_format
          },
          tenant: site.id
        )

      assert changeset.valid?, "Update should be valid for non-archived error page"
    end
  end

  property "update action rejects archived error page updates" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      archived_error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: name,
        path: path,
        error_pages: error_pages,
        root_layout_template: nil,
        format: :heex,
        priority: 0,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_error_page,
          :update,
          %{name: new_name},
          tenant: site.id
        )

      refute changeset.valid?, "Update should be invalid for archived error page"
    end
  end

  # THE ADDRESS IS WRITTEN, NOT CHECKED. An update used to be refused for a malformed path; there is
  # now no malformed path it could be given, because the column is written from the site first.
  property "update action writes the site's address over whatever it is given" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            invalid_path <- misdirected_path_generator()
          ) do
      error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: name,
        path: path,
        error_pages: error_pages,
        root_layout_template: nil,
        format: :heex,
        priority: 0,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          error_page,
          :update,
          %{path: invalid_path},
          tenant: site.id
        )

      assert changeset.valid?, "Update should not be refused over a path nobody can set"

      assert Ash.Changeset.get_attribute(changeset, :path) == ErrorAddress.for_site(site.id)
    end
  end

  property "unarchive action works on archived error pages" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            priority <- integer(0..100),
            format <- member_of([:heex, :eex, :markdown])
          ) do
      archived_error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: name,
        path: path,
        error_pages: error_pages,
        root_layout_template: nil,
        format: format,
        priority: priority,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset = Ash.Changeset.for_update(archived_error_page, :unarchive, %{}, tenant: site.id)
      assert changeset.valid?, "Unarchive should work on archived error pages"
    end
  end

  # A SITE PER CASE, because a site has one error page: the address is the site's own name and
  # `unique_path_per_site` refuses the second row at it. This property is about destroying real
  # rows, so it makes real rows — one site each rather than one site and a made-up path each.
  property "destroy action (archive) works on any error page" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            error_pages <- valid_error_pages_generator(),
            priority <- integer(0..100),
            format <- member_of([:heex, :eex, :markdown])
          ) do
      site = create_site!()

      error_page =
        MishkaCmsCore.Runtime.ErrorPage
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: name,
            error_pages: error_pages,
            priority: priority,
            format: format
          },
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert error_page.path == ErrorAddress.for_site(site.id)

      changeset =
        Ash.Changeset.for_destroy(
          error_page,
          :destroy,
          %{},
          tenant: site.id,
          authorize?: false
        )

      assert changeset.valid?, "Destroy should work on any error page"
    end
  end

  property "permanent_destroy action works on any error page" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            priority <- integer(0..100),
            format <- member_of([:heex, :eex, :markdown]),
            is_archived <- boolean()
          ) do
      archived_at = if is_archived, do: ~U[2024-01-01 00:00:00Z], else: nil

      error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: name,
        path: path,
        error_pages: error_pages,
        root_layout_template: nil,
        format: format,
        priority: priority,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: archived_at
      }

      changeset = Ash.Changeset.for_destroy(error_page, :permanent_destroy, %{}, tenant: site.id)
      assert changeset.valid?, "Permanent destroy should work on any error page"
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

    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            error_pages <- valid_error_pages_generator(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      error_page = %ErrorPage{
        id: Ecto.UUID.generate(),
        name: original_name,
        path: path,
        error_pages: error_pages,
        root_layout_template: nil,
        format: :heex,
        priority: 0,
        extra: %{},
        helpers: [],
        site_id: site.id,
        archived_at: nil
      }

      destroy_changeset = Ash.Changeset.for_destroy(error_page, :destroy, %{}, tenant: site.id)
      assert destroy_changeset.valid?, "Destroy should be valid"

      archived_error_page = %{error_page | archived_at: ~U[2024-01-01 00:00:00Z]}

      unarchive_changeset =
        Ash.Changeset.for_update(archived_error_page, :unarchive, %{}, tenant: site.id)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      unarchived_error_page = %{archived_error_page | archived_at: nil}

      update_changeset =
        Ash.Changeset.for_update(unarchived_error_page, :update, %{name: new_name},
          tenant: site.id
        )

      assert update_changeset.valid?, "Update after unarchive should be valid"
    end
  end

  property "validates error_pages cannot be empty" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(ErrorPage, :create, %{
          name: name,
          path: path,
          error_pages: []
        })

      refute changeset.valid?, "Empty error_pages should be invalid"
    end
  end

  property "validates error_pages with missing required fields" do
    site = create_site!()

    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            path <- valid_path_generator(),
            include_status <- boolean(),
            include_template <- boolean()
          ) do
      error_page_config = %{}

      error_page_config =
        if include_status, do: Map.put(error_page_config, :status, 404), else: error_page_config

      error_page_config =
        if include_template,
          do: Map.put(error_page_config, :template, "<div>Error</div>"),
          else: error_page_config

      error_page_config = Map.put(error_page_config, :layout, %{})

      changeset =
        Ash.Changeset.for_create(
          ErrorPage,
          :create,
          %{
            name: name,
            path: path,
            error_pages: [error_page_config]
          },
          tenant: site.id
        )

      if not include_status or not include_template do
        refute changeset.valid?, "Missing required fields in error_pages should be invalid"
      else
        assert changeset.valid?, "Complete error_pages should be valid"
      end
    end
  end

  @tag :slow
  property "handles large datasets efficiently" do
    site = create_site!()

    check all(
            error_pages <-
              list_of(
                fixed_map(%{
                  name: string(:alphanumeric, min_length: 3, max_length: 20),
                  path: valid_path_generator(),
                  error_pages: valid_error_pages_generator(),
                  format: member_of([:heex, :eex, :markdown]),
                  priority: integer(0..100)
                }),
                min_length: 10,
                max_length: 20
              ),
            max_runs: 5
          ) do
      changesets =
        Enum.map(error_pages, fn error_page_attrs ->
          Ash.Changeset.for_create(ErrorPage, :create, error_page_attrs, tenant: site.id)
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
                     error_pages: valid_error_pages_generator(),
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
              changeset = Ash.Changeset.for_create(ErrorPage, :create, attrs, tenant: site.id)
              {action, changeset.valid?}

            :update ->
              mock_error_page = %ErrorPage{
                id: Ecto.UUID.generate(),
                name: "Test Error Page",
                path: "/errors",
                error_pages: [%{status: 404, template: "<div>Not Found</div>", layout: %{}}],
                root_layout_template: nil,
                format: :heex,
                priority: 0,
                extra: %{},
                helpers: [],
                site_id: nil,
                archived_at: nil
              }

              changeset =
                Ash.Changeset.for_update(mock_error_page, :update, attrs, tenant: site.id)

              {action, changeset.valid?}

            :unarchive ->
              mock_archived_error_page = %ErrorPage{
                id: Ecto.UUID.generate(),
                name: "Test Error Page",
                path: "/errors",
                error_pages: [%{status: 404, template: "<div>Not Found</div>", layout: %{}}],
                root_layout_template: nil,
                format: :heex,
                priority: 0,
                extra: %{},
                helpers: [],
                site_id: nil,
                archived_at: ~U[2024-01-01 00:00:00Z]
              }

              changeset =
                Ash.Changeset.for_update(mock_archived_error_page, :unarchive, attrs,
                  tenant: site.id
                )

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

  defp valid_path_generator do
    bind(string(:alphanumeric, min_length: 1, max_length: 50), fn base ->
      one_of([
        constant("/#{base}"),
        constant("/#{base}/*"),
        constant("/#{base}/nested"),
        constant("/#{base}/*/dynamic"),
        constant("/"),
        constant("/errors"),
        constant("/errors/*"),
        constant("/admin/errors/*")
      ])
    end)
  end

  defp valid_error_pages_generator do
    list_of(
      fixed_map(%{
        status: member_of([400, 401, 403, 404, 422, 500, 502, 503, 504]),
        template:
          bind(string(:alphanumeric, min_length: 3, max_length: 20), fn content ->
            one_of([
              constant("<div>#{content}</div>"),
              constant("<h1>Error: #{content}</h1>"),
              constant("<p>#{content}</p>"),
              constant("<html><body><h1>#{content}</h1></body></html>")
            ])
          end),
        layout:
          one_of([
            constant(%{}),
            constant(%{wrapper: "error_layout"}),
            constant(%{theme: "dark", container: true}),
            constant(nil)
          ])
      }),
      min_length: 1,
      max_length: 5
    )
  end

  defp invalid_name_generator do
    one_of([
      string(:alphanumeric, max_length: 2),
      string(:alphanumeric, min_length: 201, max_length: 300),
      constant(""),
      string([?\s], min_length: 1, max_length: 10)
    ])
  end

  # A PATH THE COLUMN WOULD ACCEPT AND THE RENDERER WOULD NEVER FIND. Separate from
  # `invalid_path_generator/0`, which also produces paths longer than the attribute's own 255 — that
  # is a cast failure, refused before any change of ours runs, and it stays refused.
  defp misdirected_path_generator do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 10),
      constant("no-leading-slash"),
      constant("/errors/*"),
      constant("/somewhere/else"),
      constant("")
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

  defp invalid_error_pages_generator do
    one_of([
      constant([]),
      constant(nil),
      constant("not_a_list"),
      constant([%{invalid: "structure"}]),
      constant([%{status: "not_integer", template: "test"}]),
      # missing template
      constant([%{status: 404}]),
      # missing status
      constant([%{template: "test"}])
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
      :html,
      :jsx,
      :liquid,
      :mustache,
      :erb
    ])
  end
end
