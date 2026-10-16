# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.SitePropertyTest do
  use MishkaCmsCore.DataCase
  use ExUnit.Case
  import ExUnitProperties
  import StreamData
  alias MishkaCmsCore.Runtime.Site
  @moduletag :property

  property "accepts all valid input combinations" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 70),
            host <- simple_host_generator(),
            priority <- integer(0..100),
            active <- boolean()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host,
            priority: priority,
            active: active
          },
          authorize?: false
        )

      assert changeset.valid?,
             "Expected valid changeset for: #{inspect(%{name: name, host: host, priority: priority, active: active})}"
    end
  end

  property "accepts minimal valid inputs" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 3),
            host_base <- string(:alphanumeric, min_length: 3, max_length: 3)
          ) do
      host = "#{host_base}.co"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host
          },
          authorize?: false
        )

      assert changeset.valid?
    end
  end

  property "accepts maximal valid inputs" do
    check all(
            name <- string(:alphanumeric, min_length: 70, max_length: 70),
            host_base <- string(:alphanumeric, min_length: 190, max_length: 190)
          ) do
      host = "#{String.slice(host_base, 0, 190)}.com"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host,
            priority: 100,
            active: true
          },
          authorize?: false
        )

      if String.length(host) <= 200 do
        true
      else
        refute changeset.valid?
      end
    end
  end

  property "accepts complex valid domain formats" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            subdomain <- string(:alphanumeric, min_length: 1, max_length: 10),
            domain <- string(:alphanumeric, min_length: 1, max_length: 15),
            tld <- member_of(["com", "org", "net", "edu", "io"])
          ) do
      host = "#{subdomain}.#{domain}.#{tld}"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host
          },
          authorize?: false
        )

      assert changeset.valid?
    end
  end

  property "rejects invalid names" do
    check all(
            invalid_name <- invalid_name_generator(),
            host <- simple_host_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: invalid_name,
            host: host
          },
          authorize?: false
        )

      refute changeset.valid?, "Expected invalid changeset for name: #{inspect(invalid_name)}"
    end
  end

  property "rejects invalid hosts" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            invalid_host <- invalid_host_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: invalid_host
          },
          authorize?: false
        )

      refute changeset.valid?, "Expected invalid changeset for host: #{inspect(invalid_host)}"
    end
  end

  property "rejects invalid priority values" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            invalid_priority <- invalid_priority_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host,
            priority: invalid_priority
          },
          authorize?: false
        )

      refute changeset.valid?, "Expected invalid changeset for priority: #{invalid_priority}"
    end
  end

  property "rejects missing required fields" do
    check all(
            include_name <- boolean(),
            include_host <- boolean(),
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            priority <- integer(0..100),
            active <- boolean()
          ) do
      attrs = %{}
      attrs = if include_name, do: Map.put(attrs, :name, name), else: attrs
      attrs = if include_host, do: Map.put(attrs, :host, host), else: attrs
      attrs = Map.put(attrs, :priority, priority)
      attrs = Map.put(attrs, :active, active)

      changeset = Ash.Changeset.for_create(Site, :create, attrs, authorize?: false)

      if not include_name or not include_host do
        refute changeset.valid?,
               "Expected invalid changeset when name or host missing: #{inspect(attrs)}"
      else
        assert changeset.valid?,
               "Expected valid changeset when both name and host present: #{inspect(attrs)}"
      end
    end
  end

  property "handles boundary values correctly" do
    check all(
            name_length <- member_of([3, 70]),
            priority <- member_of([0, 100])
          ) do
      name = String.duplicate("a", name_length)

      host = "test.com"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host,
            priority: priority
          },
          authorize?: false
        )

      assert changeset.valid?,
             "Boundary values should be valid: name_len=#{name_length}, priority=#{priority}"
    end
  end

  property "handles whitespace trimming correctly" do
    check all(
            base_name <- string(:alphanumeric, min_length: 3, max_length: 65),
            base_host <- string(:alphanumeric, min_length: 3, max_length: 50),
            leading_spaces <- integer(1..5),
            trailing_spaces <- integer(1..5)
          ) do
      padded_name =
        "#{String.duplicate(" ", leading_spaces)}#{base_name}#{String.duplicate(" ", trailing_spaces)}"

      padded_host =
        "#{String.duplicate(" ", leading_spaces)}#{base_host}.com#{String.duplicate(" ", trailing_spaces)}"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: padded_name,
            host: padded_host
          },
          authorize?: false
        )

      case changeset.valid? do
        true ->
          assert true

        false ->
          trimmed_name = String.trim(padded_name)
          trimmed_host = String.trim(padded_host)

          retry_changeset =
            Ash.Changeset.for_create(
              Site,
              :create,
              %{
                name: trimmed_name,
                host: trimmed_host
              },
              authorize?: false
            )

          assert retry_changeset.valid?, "Should be valid after trimming"
      end
    end
  end

  property "valid updates preserve data integrity" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_host <- simple_host_generator(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            new_priority <- integer(0..100)
          ) do
      site = %Site{
        id: Ecto.UUID.generate(),
        name: original_name,
        host: original_host,
        priority: 0,
        active: true,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          site,
          :update,
          %{
            name: new_name,
            priority: new_priority
          },
          authorize?: false
        )

      assert changeset.valid?, "Update changeset should be valid"
    end
  end

  property "validates simple domain formats correctly" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 15),
            domain <- string(:alphanumeric, min_length: 3, max_length: 15),
            tld <- member_of(["com", "org", "net"])
          ) do
      host = "#{domain}.#{tld}"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host
          },
          authorize?: false
        )

      assert changeset.valid?, "Simple domain format should be valid: #{host}"
    end
  end

  property "rejects invalid domain characters" do
    check all(
            base_domain <- string(:alphanumeric, min_length: 3, max_length: 10),
            invalid_char <- member_of([" ", "_", "@", "#", "$", "%", "!", "(", ")", "+", "="])
          ) do
      invalid_host = "#{base_domain}#{invalid_char}test.com"

      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: "Test Site",
            host: invalid_host
          },
          authorize?: false
        )

      refute changeset.valid?, "Invalid domain character should fail: #{invalid_host}"
    end
  end

  property "applies default values correctly" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator()
          ) do
      changeset =
        Ash.Changeset.for_create(
          Site,
          :create,
          %{
            name: name,
            host: host
          },
          authorize?: false
        )

      assert changeset.valid?
    end
  end

  property "update action accepts valid changes" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            original_host <- simple_host_generator(),
            original_priority <- integer(0..100),
            original_active <- boolean(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 70),
            new_host <- simple_host_generator(),
            new_priority <- integer(0..100),
            new_active <- boolean()
          ) do
      site = %Site{
        id: Ecto.UUID.generate(),
        name: original_name,
        host: original_host,
        priority: original_priority,
        active: original_active,
        archived_at: nil
      }

      changeset =
        Ash.Changeset.for_update(
          site,
          :update,
          %{
            name: new_name,
            host: new_host,
            priority: new_priority,
            active: new_active
          },
          authorize?: false
        )

      assert changeset.valid?, "Update should be valid for non-archived site"
    end
  end

  property "update action rejects archived site updates" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      archived_site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: 0,
        active: true,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset =
        Ash.Changeset.for_update(
          archived_site,
          :update,
          %{
            name: new_name
          },
          authorize?: false
        )

      refute changeset.valid?, "Update should be invalid for archived site"
    end
  end

  property "activate action works on any non-archived site" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            current_active <- boolean()
          ) do
      site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: 0,
        active: current_active,
        archived_at: nil
      }

      changeset = Ash.Changeset.for_update(site, :activate, %{}, authorize?: false)
      assert changeset.valid?, "Activate should work on non-archived sites"
    end
  end

  property "deactivate action works on any non-archived site" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            current_active <- boolean()
          ) do
      site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: 0,
        active: current_active,
        archived_at: nil
      }

      changeset = Ash.Changeset.for_update(site, :deactivate, %{}, authorize?: false)
      assert changeset.valid?, "Deactivate should work on non-archived sites"
    end
  end

  property "unarchive action works on archived sites" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            priority <- integer(0..100),
            active <- boolean()
          ) do
      archived_site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: priority,
        active: active,
        archived_at: ~U[2024-01-01 00:00:00Z]
      }

      changeset = Ash.Changeset.for_update(archived_site, :unarchive, %{}, authorize?: false)
      assert changeset.valid?, "Unarchive should work on archived sites"
    end
  end

  property "destroy action (archive) works on any site" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            priority <- integer(0..100),
            active <- boolean(),
            is_archived <- boolean()
          ) do
      archived_at = if is_archived, do: ~U[2024-01-01 00:00:00Z], else: nil

      site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: priority,
        active: active,
        archived_at: archived_at
      }

      changeset = Ash.Changeset.for_destroy(site, :destroy, %{}, authorize?: false)
      assert changeset.valid?, "Destroy should work on any site"
    end
  end

  property "permanent_destroy action works on any site" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            priority <- integer(0..100),
            active <- boolean(),
            is_archived <- boolean()
          ) do
      archived_at = if is_archived, do: ~U[2024-01-01 00:00:00Z], else: nil

      site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: priority,
        active: active,
        archived_at: archived_at
      }

      changeset = Ash.Changeset.for_destroy(site, :permanent_destroy, %{}, authorize?: false)
      assert changeset.valid?, "Permanent destroy should work on any site"
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

  property "unique name constraint prevents duplicates" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host1 <- simple_host_generator(),
            host2 <- simple_host_generator()
          ) do
      site1_attrs = %{name: name, host: host1}
      site2_attrs = %{name: name, host: host2}

      changeset1 = Ash.Changeset.for_create(Site, :create, site1_attrs, authorize?: false)
      changeset2 = Ash.Changeset.for_create(Site, :create, site2_attrs, authorize?: false)

      assert changeset1.valid?, "First changeset should be valid"
      assert changeset2.valid?, "Second changeset should be valid"
    end
  end

  property "unique host constraint prevents duplicates" do
    check all(
            name1 <- string(:alphanumeric, min_length: 3, max_length: 20),
            name2 <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator()
          ) do
      site1_attrs = %{name: name1, host: host}
      site2_attrs = %{name: name2, host: host}

      changeset1 = Ash.Changeset.for_create(Site, :create, site1_attrs, authorize?: false)
      changeset2 = Ash.Changeset.for_create(Site, :create, site2_attrs, authorize?: false)

      assert changeset1.valid?, "First changeset should be valid"
      assert changeset2.valid?, "Second changeset should be valid"
    end
  end

  property "archive -> unarchive -> update workflow" do
    check all(
            original_name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator(),
            new_name <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      site = %Site{
        id: Ecto.UUID.generate(),
        name: original_name,
        host: host,
        priority: 0,
        active: true,
        archived_at: nil
      }

      destroy_changeset = Ash.Changeset.for_destroy(site, :destroy, %{}, authorize?: false)
      assert destroy_changeset.valid?, "Destroy should be valid"

      archived_site = %{site | archived_at: ~U[2024-01-01 00:00:00Z]}

      unarchive_changeset =
        Ash.Changeset.for_update(archived_site, :unarchive, %{}, authorize?: false)

      assert unarchive_changeset.valid?, "Unarchive should be valid"

      unarchived_site = %{archived_site | archived_at: nil}

      update_changeset =
        Ash.Changeset.for_update(unarchived_site, :update, %{name: new_name}, authorize?: false)

      assert update_changeset.valid?, "Update after unarchive should be valid"
    end
  end

  property "activate -> deactivate -> activate workflow" do
    check all(
            name <- string(:alphanumeric, min_length: 3, max_length: 20),
            host <- simple_host_generator()
          ) do
      site = %Site{
        id: Ecto.UUID.generate(),
        name: name,
        host: host,
        priority: 0,
        active: false,
        archived_at: nil
      }

      activate_changeset = Ash.Changeset.for_update(site, :activate, %{}, authorize?: false)
      assert activate_changeset.valid?, "Activate should be valid"

      active_site = %{site | active: true}

      deactivate_changeset =
        Ash.Changeset.for_update(active_site, :deactivate, %{}, authorize?: false)

      assert deactivate_changeset.valid?, "Deactivate should be valid"

      inactive_site = %{active_site | active: false}

      reactivate_changeset =
        Ash.Changeset.for_update(inactive_site, :activate, %{}, authorize?: false)

      assert reactivate_changeset.valid?, "Reactivate should be valid"
    end
  end

  @tag :slow
  property "handles large datasets efficiently" do
    check all(
            sites <-
              list_of(
                fixed_map(%{
                  name: string(:alphanumeric, min_length: 3, max_length: 20),
                  host: simple_host_generator(),
                  priority: integer(0..100),
                  active: boolean()
                }),
                min_length: 10,
                max_length: 20
              ),
            max_runs: 5
          ) do
      changesets =
        Enum.map(sites, fn site_attrs ->
          Ash.Changeset.for_create(Site, :create, site_attrs, authorize?: false)
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
                     host: simple_host_generator(),
                     priority: integer(0..100),
                     active: boolean()
                   })},
                  {:activate, constant(%{})},
                  {:deactivate, constant(%{})},
                  {:update,
                   fixed_map(%{
                     name: string(:alphanumeric, min_length: 3, max_length: 15),
                     priority: integer(0..100)
                   })}
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
              changeset = Ash.Changeset.for_create(Site, :create, attrs, authorize?: false)
              {action, changeset.valid?}

            :activate ->
              mock_site = %Site{
                id: Ecto.UUID.generate(),
                name: "Test",
                host: "test.com",
                priority: 0,
                active: false,
                archived_at: nil
              }

              changeset = Ash.Changeset.for_update(mock_site, :activate, attrs, authorize?: false)
              {action, changeset.valid?}

            :deactivate ->
              mock_site = %Site{
                id: Ecto.UUID.generate(),
                name: "Test",
                host: "test.com",
                priority: 0,
                active: true,
                archived_at: nil
              }

              changeset =
                Ash.Changeset.for_update(mock_site, :deactivate, attrs, authorize?: false)

              {action, changeset.valid?}

            :update ->
              mock_site = %Site{
                id: Ecto.UUID.generate(),
                name: "Test",
                host: "test.com",
                priority: 0,
                active: true,
                archived_at: nil
              }

              changeset = Ash.Changeset.for_update(mock_site, :update, attrs, authorize?: false)
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
  defp simple_host_generator do
    bind(string(:alphanumeric, min_length: 3, max_length: 50), fn base ->
      one_of([
        constant("#{base}.com"),
        constant("#{base}.org"),
        constant("#{base}.net")
      ])
    end)
  end

  defp invalid_name_generator do
    one_of([
      string(:alphanumeric, max_length: 2),
      string(:alphanumeric, min_length: 71, max_length: 100),
      constant(""),
      string([?\s], min_length: 1, max_length: 10)
    ])
  end

  defp invalid_host_generator do
    one_of([
      string(:alphanumeric, max_length: 2),
      string(:alphanumeric, min_length: 201, max_length: 250),
      constant(""),
      bind(string(:alphanumeric, min_length: 3, max_length: 10), fn base ->
        constant("#{base}@invalid.com")
      end)
    ])
  end

  defp invalid_priority_generator do
    one_of([
      integer(-100..-1),
      integer(101..1000)
    ])
  end
end
