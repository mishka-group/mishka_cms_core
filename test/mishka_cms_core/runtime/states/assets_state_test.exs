defmodule MishkaCmsCore.Runtime.States.AssetsStateTest do
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.States.AssetsState
  @moduletag :unit

  setup_all do
    case GenServer.whereis(AssetsState) do
      nil ->
        {:ok, _pid} = AssetsState.start_link()

      _pid ->
        :ok
    end

    Process.sleep(50)

    :ok
  end

  setup do
    AssetsState.clear()

    on_exit(fn ->
      AssetsState.clear()
    end)

    :ok
  end

  describe "save/1" do
    test "saves an asset with all fields" do
      attrs = %{
        id: "example_site",
        type: "theme",
        value: %{css: "body { color: red; }", js: "console.log('hello');"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      assert :ok = AssetsState.save(attrs)
      assert {:ok, asset} = AssetsState.get("example_site", "theme")
      assert asset.id == "example_site"
      assert asset.type == "theme"
      assert asset.value == %{css: "body { color: red; }", js: "console.log('hello');"}
      assert asset.updated_at == ~U[2024-01-01 10:00:00Z]
    end

    test "allows same site with different types" do
      attrs1 = %{
        id: "example_site",
        type: "theme",
        value: %{css: "body { color: red; }"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      attrs2 = %{
        id: "example_site",
        type: "config",
        value: %{title: "My Site", description: "A great site"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 11:00:00Z]
      }

      assert :ok = AssetsState.save(attrs1)
      assert :ok = AssetsState.save(attrs2)

      assert {:ok, theme} = AssetsState.get("example_site", "theme")
      assert {:ok, config} = AssetsState.get("example_site", "config")
      assert theme.value == %{css: "body { color: red; }"}
      assert config.value == %{title: "My Site", description: "A great site"}
    end

    test "allows same type on different sites" do
      attrs1 = %{
        id: "site1",
        type: "theme",
        value: %{css: "body { color: red; }"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      attrs2 = %{
        id: "site2",
        type: "theme",
        value: %{css: "body { color: blue; }"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 11:00:00Z]
      }

      assert :ok = AssetsState.save(attrs1)
      assert :ok = AssetsState.save(attrs2)

      assert {:ok, site1_theme} = AssetsState.get("site1", "theme")
      assert {:ok, site2_theme} = AssetsState.get("site2", "theme")
      assert site1_theme.value == %{css: "body { color: red; }"}
      assert site2_theme.value == %{css: "body { color: blue; }"}
    end

    test "updates existing asset with same site and type (upsert behavior)" do
      attrs1 = %{
        id: "example_site",
        type: "theme",
        value: %{css: "body { color: red; }"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      attrs2 = %{
        id: "example_site",
        type: "theme",
        value: %{css: "body { color: blue; }", js: "console.log('updated');"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 12:00:00Z]
      }

      assert :ok = AssetsState.save(attrs1)
      assert {:ok, original} = AssetsState.get("example_site", "theme")
      assert original.value == %{css: "body { color: red; }"}

      assert :ok = AssetsState.save(attrs2)
      assert {:ok, updated} = AssetsState.get("example_site", "theme")
      assert updated.value == %{css: "body { color: blue; }", js: "console.log('updated');"}
      assert updated.updated_at == ~U[2024-01-01 12:00:00Z]

      # Should still only have one record
      assert AssetsState.count() == 1
    end
  end

  describe "save_batch/1" do
    test "saves multiple assets at once" do
      assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{css: "body { color: red; }"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site1",
          type: "config",
          value: %{title: "Site 1"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "site2",
          type: "theme",
          value: %{css: "body { color: blue; }"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        },
        %{
          id: "site2",
          type: "scripts",
          value: %{analytics: "ga-123"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 13:00:00Z]
        }
      ]

      assert :ok = AssetsState.save_batch(assets)
      assert AssetsState.count() == 4
      assert AssetsState.get!("site1", "theme").value == %{css: "body { color: red; }"}
      assert AssetsState.get!("site1", "config").value == %{title: "Site 1"}
      assert AssetsState.get!("site2", "theme").value == %{css: "body { color: blue; }"}
      assert AssetsState.get!("site2", "scripts").value == %{analytics: "ga-123"}
    end

    test "handles empty list" do
      assert :ok = AssetsState.save_batch([])
      assert AssetsState.count() == 0
    end
  end

  describe "get/2 and get!/2" do
    setup do
      attrs = %{
        id: "test_site",
        type: "theme",
        value: %{css: "body { color: green; }", js: "console.log('test');"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      AssetsState.save(attrs)
      :ok
    end

    test "get/2 returns {:ok, asset} when asset exists" do
      assert {:ok, asset} = AssetsState.get("test_site", "theme")
      assert asset.id == "test_site"
      assert asset.type == "theme"
      assert asset.value == %{css: "body { color: green; }", js: "console.log('test');"}
      assert asset.updated_at == ~U[2024-01-01 10:00:00Z]
    end

    test "get/2 returns {:error, :not_found} when asset doesn't exist" do
      assert {:error, :not_found} = AssetsState.get("nonexistent", "theme")
      assert {:error, :not_found} = AssetsState.get("test_site", "nonexistent")
    end

    test "get!/2 returns asset map when exists" do
      assert asset = AssetsState.get!("test_site", "theme")
      assert asset.id == "test_site"
      assert asset.type == "theme"
      assert asset.value == %{css: "body { color: green; }", js: "console.log('test');"}
    end

    test "get!/2 returns nil when asset doesn't exist" do
      assert nil == AssetsState.get!("nonexistent", "theme")
      assert nil == AssetsState.get!("test_site", "nonexistent")
    end
  end

  describe "get_value/2" do
    setup do
      attrs = %{
        id: "test_site",
        type: "config",
        value: %{site_name: "My Test Site", logo: "logo.png"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      AssetsState.save(attrs)
      :ok
    end

    test "returns value directly when asset exists" do
      value = AssetsState.get_value("test_site", "config")
      assert value == %{site_name: "My Test Site", logo: "logo.png"}
    end

    test "returns nil when asset doesn't exist" do
      assert nil == AssetsState.get_value("nonexistent", "config")
      assert nil == AssetsState.get_value("test_site", "nonexistent")
    end

    test "optimized for read performance - only returns value field" do
      # This should be faster than get!/2 since it doesn't build the full map
      value = AssetsState.get_value("test_site", "config")
      assert is_map(value)
      assert value.site_name == "My Test Site"
    end
  end

  describe "exists?/2" do
    setup do
      attrs = %{
        id: "test_site",
        type: "theme",
        value: %{css: "body { color: red; }"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      AssetsState.save(attrs)
      :ok
    end

    test "returns true for existing asset" do
      assert AssetsState.exists?("test_site", "theme") == true
    end

    test "returns false for non-existing asset" do
      assert AssetsState.exists?("nonexistent", "theme") == false
      assert AssetsState.exists?("test_site", "nonexistent") == false
    end
  end

  describe "hash/2 and updated_at/2" do
    setup do
      AssetsState.save(%{
        id: "test_site",
        type: "css",
        value: String.duplicate("a", 4096),
        hash: "abc123",
        updated_at: ~U[2024-01-01 10:00:00Z]
      })

      :ok
    end

    test "answer the field alone" do
      assert AssetsState.hash("test_site", "css") == "abc123"
      assert AssetsState.updated_at("test_site", "css") == ~U[2024-01-01 10:00:00Z]
    end

    test "answer nil for an asset that was never compiled" do
      assert AssetsState.hash("test_site", "js") == nil
      assert AssetsState.hash("nonexistent", "css") == nil
      assert AssetsState.updated_at("nonexistent", "css") == nil
    end
  end

  describe "the site bundle's address" do
    alias MishkaCmsCore.Runtime.Compilers.Shared

    test "is nil before the site's first compile, so no page links an empty hash" do
      assert Shared.site_css_href("fresh_site") == nil
      assert Shared.site_js_href("fresh_site") == nil
    end

    test "is nil for an empty hash" do
      AssetsState.save(%{id: "fresh_site", type: "css", value: "", hash: "", updated_at: nil})

      assert Shared.site_css_href("fresh_site") == nil
    end

    test "carries the hash once the bundle exists" do
      for type <- ["css", "js"] do
        AssetsState.save(%{
          id: "fresh_site",
          type: type,
          value: "",
          hash: "h#{type}",
          updated_at: nil
        })
      end

      assert Shared.site_css_href("fresh_site") == "/assets/css/fresh_site/hcss.css"
      assert Shared.site_js_href("fresh_site") == "/assets/js/fresh_site/hjs.js"
    end
  end

  describe "get_by_site/1" do
    setup do
      assets = [
        %{
          id: "example_site",
          type: "theme",
          value: %{css: "body { color: red; }"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "example_site",
          type: "config",
          value: %{title: "Example Site"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "example_site",
          type: "scripts",
          value: %{analytics: "ga-123"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        },
        %{
          id: "other_site",
          type: "theme",
          value: %{css: "body { color: blue; }"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 13:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      :ok
    end

    test "returns all assets for a specific site" do
      assets = AssetsState.get_by_site("example_site")
      assert length(assets) == 3

      types = Enum.map(assets, & &1.type) |> Enum.sort()
      assert types == ["config", "scripts", "theme"]

      # Check specific asset
      theme_asset = Enum.find(assets, &(&1.type == "theme"))
      assert theme_asset.value == %{css: "body { color: red; }"}
    end

    test "returns empty list for non-existing site" do
      assets = AssetsState.get_by_site("nonexistent")
      assert assets == []
    end

    test "does not return assets from other sites" do
      assets = AssetsState.get_by_site("example_site")
      site_ids = Enum.map(assets, & &1.id) |> Enum.uniq()
      assert site_ids == ["example_site"]
    end
  end

  describe "get_many/1" do
    setup do
      assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site1",
          type: "config",
          value: %{title: "Site 1"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "site2",
          type: "theme",
          value: %{css: "blue"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      :ok
    end

    test "returns multiple assets by their composite keys" do
      keys = [{"site1", "theme"}, {"site2", "theme"}, {"site1", "config"}]
      assets = AssetsState.get_many(keys)

      assert length(assets) == 3

      # Check each asset
      site1_theme = Enum.find(assets, &(&1.id == "site1" && &1.type == "theme"))
      site2_theme = Enum.find(assets, &(&1.id == "site2" && &1.type == "theme"))
      site1_config = Enum.find(assets, &(&1.id == "site1" && &1.type == "config"))

      assert site1_theme.value == %{css: "red"}
      assert site2_theme.value == %{css: "blue"}
      assert site1_config.value == %{title: "Site 1"}
    end

    test "skips non-existing assets" do
      keys = [{"site1", "theme"}, {"nonexistent", "theme"}, {"site1", "nonexistent"}]
      assets = AssetsState.get_many(keys)

      assert length(assets) == 1
      assert hd(assets).id == "site1"
      assert hd(assets).type == "theme"
    end

    test "handles empty key list" do
      assets = AssetsState.get_many([])
      assert assets == []
    end

    test "maintains order of found assets" do
      keys = [{"site1", "config"}, {"site1", "theme"}]
      assets = AssetsState.get_many(keys)

      assert length(assets) == 2
      assert Enum.at(assets, 0).type == "config"
      assert Enum.at(assets, 1).type == "theme"
    end
  end

  describe "get_by_type/1" do
    setup do
      assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site2",
          type: "theme",
          value: %{css: "blue"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "site3",
          type: "theme",
          value: %{css: "green"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        },
        %{
          id: "site1",
          type: "config",
          value: %{title: "Site 1"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 13:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      :ok
    end

    test "returns all assets of a specific type across all sites" do
      theme_assets = AssetsState.get_by_type("theme")
      assert length(theme_assets) == 3

      site_ids = Enum.map(theme_assets, & &1.id) |> Enum.sort()
      assert site_ids == ["site1", "site2", "site3"]

      # All should be theme type
      types = Enum.map(theme_assets, & &1.type) |> Enum.uniq()
      assert types == ["theme"]
    end

    test "returns empty list for non-existing type" do
      assets = AssetsState.get_by_type("nonexistent")
      assert assets == []
    end

    test "does not return assets of other types" do
      config_assets = AssetsState.get_by_type("config")
      assert length(config_assets) == 1
      assert hd(config_assets).id == "site1"
      assert hd(config_assets).type == "config"
    end
  end

  describe "get_all/0" do
    test "returns all assets in the table" do
      assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site1",
          type: "config",
          value: %{title: "Site 1"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "site2",
          type: "theme",
          value: %{css: "blue"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)

      all_assets = AssetsState.get_all()
      assert length(all_assets) == 3

      # Check that all assets are present
      ids_and_types =
        Enum.map(all_assets, &{&1.id, &1.type})
        |> Enum.sort()

      expected = [{"site1", "config"}, {"site1", "theme"}, {"site2", "theme"}]
      assert ids_and_types == expected
    end

    test "returns empty list when table is empty" do
      all_assets = AssetsState.get_all()
      assert all_assets == []
    end
  end

  describe "delete/2" do
    setup do
      assets = [
        %{
          id: "test_site",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "test_site",
          type: "config",
          value: %{title: "Test Site"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      :ok
    end

    test "deletes specific asset by id and type" do
      assert AssetsState.exists?("test_site", "theme") == true
      assert AssetsState.exists?("test_site", "config") == true

      assert :ok = AssetsState.delete("test_site", "theme")

      assert AssetsState.exists?("test_site", "theme") == false
      assert AssetsState.exists?("test_site", "config") == true
      assert {:error, :not_found} = AssetsState.get("test_site", "theme")
      assert {:ok, _config} = AssetsState.get("test_site", "config")
    end

    test "delete is idempotent" do
      assert :ok = AssetsState.delete("test_site", "theme")
      assert :ok = AssetsState.delete("test_site", "theme")
      assert AssetsState.exists?("test_site", "theme") == false
    end

    test "delete non-existing asset does nothing" do
      assert :ok = AssetsState.delete("nonexistent", "theme")
      assert :ok = AssetsState.delete("test_site", "nonexistent")
    end
  end

  describe "count/0" do
    test "returns correct count of assets" do
      assert AssetsState.count() == 0

      assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site1",
          type: "config",
          value: %{title: "Site 1"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "site2",
          type: "theme",
          value: %{css: "blue"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      assert AssetsState.count() == 3

      AssetsState.delete("site1", "theme")
      assert AssetsState.count() == 2
    end
  end

  describe "clear/0" do
    test "removes all data from the table" do
      assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site2",
          type: "config",
          value: %{title: "Site 2"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      assert AssetsState.count() == 2

      assert :ok = AssetsState.clear()
      assert AssetsState.count() == 0
      assert AssetsState.get!("site1", "theme") == nil
      assert AssetsState.get!("site2", "config") == nil
    end

    test "clear is idempotent" do
      assert :ok = AssetsState.clear()
      assert :ok = AssetsState.clear()
      assert AssetsState.count() == 0
    end
  end

  describe "stats/0" do
    test "returns statistics about the assets table" do
      assets =
        for i <- 1..5 do
          %{
            id: "site_#{i}",
            type: "theme",
            value: %{css: "body { color: #{i}; }"},
            hash: "hashed",
            updated_at: DateTime.utc_now()
          }
        end

      AssetsState.save_batch(assets)

      stats = AssetsState.stats()

      assert stats.table_size == 5
      assert is_integer(stats.memory)
      assert is_list(stats.table_info)
      assert stats.table_info[:type] == :set
    end
  end

  describe "update_value/3" do
    setup do
      attrs = %{
        id: "test_site",
        type: "theme",
        value: %{css: "body { color: red; }"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      AssetsState.save(attrs)
      :ok
    end

    test "updates value of existing asset" do
      new_value = %{css: "body { color: blue; }", js: "console.log('updated');"}

      assert :ok = AssetsState.update_value("test_site", "theme", new_value)
      assert {:ok, asset} = AssetsState.get("test_site", "theme")
      assert asset.value == new_value
      # updated_at should be automatically updated
      assert DateTime.compare(asset.updated_at, ~U[2024-01-01 10:00:00Z]) == :gt
    end

    test "returns error for non-existing asset" do
      new_value = %{css: "body { color: blue; }"}

      assert {:error, :not_found} =
               AssetsState.update_value("nonexistent", "theme", new_value)

      assert {:error, :not_found} =
               AssetsState.update_value("test_site", "nonexistent", new_value)
    end
  end

  describe "touch/2" do
    setup do
      attrs = %{
        id: "test_site",
        type: "config",
        value: %{title: "Test Site"},
        hash: "hashed",
        updated_at: ~U[2024-01-01 10:00:00Z]
      }

      AssetsState.save(attrs)
      :ok
    end

    test "updates updated_at timestamp without changing value" do
      original_time = ~U[2024-01-01 10:00:00Z]
      {:ok, original} = AssetsState.get("test_site", "config")
      assert original.updated_at == original_time

      # Wait a bit to ensure timestamp changes
      Process.sleep(10)

      assert :ok = AssetsState.touch("test_site", "config")
      {:ok, touched} = AssetsState.get("test_site", "config")

      # Value should be unchanged
      assert touched.value == original.value
      # But updated_at should be newer
      assert DateTime.compare(touched.updated_at, original_time) == :gt
    end

    test "returns error for non-existing asset" do
      assert {:error, :not_found} = AssetsState.touch("nonexistent", "config")
      assert {:error, :not_found} = AssetsState.touch("test_site", "nonexistent")
    end
  end

  describe "performance characteristics" do
    @tag :performance
    test "handles large datasets efficiently" do
      # Create 1000 assets across 100 sites with 10 types each
      assets =
        for site <- 1..100, type <- 1..10 do
          %{
            id: "site_#{site}",
            type: "type_#{type}",
            value: %{data: "content_#{site}_#{type}"},
            hash: "hashed",
            updated_at: DateTime.utc_now()
          }
        end

      # Measure batch insert time
      {time, :ok} = :timer.tc(fn -> AssetsState.save_batch(assets) end)
      # Should complete in less than 100ms
      assert time < 100_000

      # Measure single lookup time
      {time, {:ok, _asset}} = :timer.tc(fn -> AssetsState.get("site_50", "type_5") end)
      # Should complete in less than 1ms
      assert time < 1000

      # Measure value-only lookup time (should be faster)
      {time, _value} = :timer.tc(fn -> AssetsState.get_value("site_50", "type_5") end)
      # Should complete in less than 1ms
      assert time < 1000

      # Measure exists check time
      {time, true} = :timer.tc(fn -> AssetsState.exists?("site_50", "type_5") end)
      # Should complete in less than 1ms
      assert time < 1000

      assert AssetsState.count() == 1000
    end

    # WHAT THE TWO FUNCTIONS ACTUALLY DIFFER BY, which is their shape and not their speed.
    #
    # This asserted that `get_value/2` is faster, first in milliseconds and then in reductions, and
    # it was flaky both ways — the reduction count came back 76892 against 70644, the wrong way
    # round, with neither function changed.
    #
    # The claim is not measurable, and that is a fact about the code rather than about the
    # measurement: BOTH call the same `:ets.lookup/2`, which copies the whole row — the large value
    # included — out of the table and onto this process's heap. `get!/2` then builds a five-key map
    # around what was copied anyway. That map is a few reductions against tens of kilobytes of
    # copying and the garbage collection it provokes, so the difference sits under the noise, and
    # `:ets.lookup_element/3` would not help either: the element it would fetch IS the large value.
    #
    # So what is worth holding is the contract each one keeps.
    test "get_value/2 answers with the value itself, get!/2 with the row around it" do
      value = %{
        css: String.duplicate("body { color: red; }", 1000),
        js: String.duplicate("console.log('test');", 1000),
        meta: %{large_list: Enum.to_list(1..1000)}
      }

      AssetsState.save(%{
        id: "perf_test",
        type: "large_data",
        value: value,
        hash: "hashed",
        updated_at: DateTime.utc_now()
      })

      assert AssetsState.get_value("perf_test", "large_data") == value

      row = AssetsState.get!("perf_test", "large_data")

      assert row.value == value
      assert Map.keys(row) |> Enum.sort() == [:hash, :id, :type, :updated_at, :value]
    end

    test "and both answer nil for a row that is not there" do
      assert AssetsState.get_value("no_such_asset", "no_such_type") == nil
      assert AssetsState.get!("no_such_asset", "no_such_type") == nil
    end
  end

  describe "concurrent access" do
    @tag :concurrent
    test "handles concurrent reads and writes" do
      # Setup initial data
      assets =
        for i <- 1..10 do
          %{
            id: "concurrent_site_#{i}",
            type: "test",
            value: %{counter: 0},
            hash: "hashed",
            updated_at: DateTime.utc_now()
          }
        end

      AssetsState.save_batch(assets)

      # Spawn multiple processes to read and write concurrently
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            site_id = "concurrent_site_#{rem(i, 10) + 1}"

            # Mix of reads and writes
            for _ <- 1..100 do
              case rem(i, 3) do
                0 ->
                  # Read operations
                  AssetsState.get_value(site_id, "test")

                1 ->
                  # Existence checks
                  AssetsState.exists?(site_id, "test")

                2 ->
                  # Update operations
                  AssetsState.update_value(site_id, "test", %{counter: i})
              end
            end

            :ok
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify data integrity
      assert AssetsState.count() == 10

      for i <- 1..10 do
        assert AssetsState.exists?("concurrent_site_#{i}", "test")
      end
    end
  end

  describe "edge cases" do
    test "handles complex value structures" do
      complex_value = %{
        strings: "test",
        numbers: 42,
        floats: 3.14,
        lists: [1, 2, 3, "mixed", %{nested: true}],
        maps: %{
          nested: %{
            deep: %{
              very_deep: "value"
            }
          }
        },
        atoms: :test_atom,
        tuples: {:ok, "result"},
        nil_value: nil,
        boolean: true
      }

      attrs = %{
        id: "complex_site",
        type: "complex",
        value: complex_value,
        hash: "hashed",
        updated_at: DateTime.utc_now()
      }

      assert :ok = AssetsState.save(attrs)
      assert {:ok, asset} = AssetsState.get("complex_site", "complex")
      assert asset.value == complex_value
    end

    test "handles empty and nil values" do
      test_cases = [
        %{value: %{}, description: "empty map"},
        %{value: [], description: "empty list"},
        %{value: "", description: "empty string"},
        %{value: nil, description: "nil value"},
        %{value: %{key: nil}, description: "map with nil value"},
        %{value: %{empty_map: %{}, empty_list: []}, description: "nested empty structures"}
      ]

      Enum.each(test_cases, fn %{value: value, description: desc} ->
        attrs = %{
          id: "edge_case_site",
          type: "test_#{desc |> String.replace(" ", "_")}",
          value: value,
          hash: "hashed",
          updated_at: DateTime.utc_now()
        }

        assert :ok = AssetsState.save(attrs)
        assert {:ok, asset} = AssetsState.get("edge_case_site", attrs.type)
        assert asset.value == value
      end)
    end

    test "handles very long site names and types" do
      long_site = String.duplicate("a", 1000)
      long_type = String.duplicate("b", 1000)

      attrs = %{
        id: long_site,
        type: long_type,
        value: %{test: "long identifiers"},
        hash: "hashed",
        updated_at: DateTime.utc_now()
      }

      assert :ok = AssetsState.save(attrs)
      assert {:ok, asset} = AssetsState.get(long_site, long_type)
      assert asset.value == %{test: "long identifiers"}
    end

    test "handles special characters in site names and types" do
      special_cases = [
        {"site-with-dashes", "type_with_underscores"},
        {"site.with.dots", "type.with.dots"},
        {"site with spaces", "type with spaces"},
        {"site@with#special$chars", "type!with%special&chars"},
        # Cyrillic
        {"сайт", "тип"},
        # Chinese
        {"网站", "类型"},
        # Japanese
        {"サイト", "タイプ"}
      ]

      Enum.each(special_cases, fn {site, type} ->
        attrs = %{
          id: site,
          type: type,
          value: %{special: true},
          hash: "hashed",
          updated_at: DateTime.utc_now()
        }

        assert :ok = AssetsState.save(attrs)
        assert {:ok, asset} = AssetsState.get(site, type)
        assert asset.value == %{special: true}
        assert AssetsState.exists?(site, type) == true
      end)
    end

    test "handles large value payloads" do
      # Create a large value (several MB)
      large_content = %{
        css: String.duplicate("body { color: red; } ", 10_000),
        js: String.duplicate("console.log('test'); ", 10_000),
        data: Enum.to_list(1..10_000),
        text: String.duplicate("Lorem ipsum dolor sit amet. ", 10_000)
      }

      attrs = %{
        id: "large_payload_site",
        type: "large",
        value: large_content,
        hash: "hashed",
        updated_at: DateTime.utc_now()
      }

      # Should handle large payloads without issues
      assert :ok = AssetsState.save(attrs)
      assert {:ok, asset} = AssetsState.get("large_payload_site", "large")
      assert asset.value == large_content

      # get_value should also work with large payloads
      retrieved_value = AssetsState.get_value("large_payload_site", "large")
      assert retrieved_value == large_content
    end
  end

  describe "data integrity" do
    test "maintains data consistency across operations" do
      # Create initial assets
      initial_assets = [
        %{
          id: "site1",
          type: "theme",
          value: %{v: 1},
          hash: "hashed",
          updated_at: DateTime.utc_now()
        },
        %{
          id: "site1",
          type: "config",
          value: %{v: 2},
          hash: "hashed",
          updated_at: DateTime.utc_now()
        },
        %{
          id: "site2",
          type: "theme",
          value: %{v: 3},
          hash: "hashed",
          updated_at: DateTime.utc_now()
        }
      ]

      AssetsState.save_batch(initial_assets)
      assert AssetsState.count() == 3

      # Update one asset
      AssetsState.update_value("site1", "theme", %{v: 10})

      # Delete one asset
      AssetsState.delete("site1", "config")
      assert AssetsState.count() == 2

      # Add new asset
      AssetsState.save(%{
        id: "site3",
        type: "scripts",
        value: %{v: 4},
        hash: "hashed",
        updated_at: DateTime.utc_now()
      })

      assert AssetsState.count() == 3

      # Verify final state
      assert AssetsState.get_value("site1", "theme") == %{v: 10}
      assert AssetsState.exists?("site1", "config") == false
      assert AssetsState.get_value("site2", "theme") == %{v: 3}
      assert AssetsState.get_value("site3", "scripts") == %{v: 4}

      # Verify get_by_site works correctly
      site1_assets = AssetsState.get_by_site("site1")
      assert length(site1_assets) == 1
      assert hd(site1_assets).type == "theme"
      assert hd(site1_assets).value == %{v: 10}
    end

    test "upsert behavior preserves uniqueness" do
      # Save same asset multiple times
      base_attrs = %{
        id: "upsert_site",
        type: "upsert_type",
        hash: "hashed",
        updated_at: DateTime.utc_now()
      }

      # First save
      AssetsState.save(Map.put(base_attrs, :value, %{version: 1}))
      assert AssetsState.count() == 1

      # Second save (should update, not create new)
      AssetsState.save(Map.put(base_attrs, :value, %{version: 2}))
      assert AssetsState.count() == 1

      # Third save (should update, not create new)
      AssetsState.save(Map.put(base_attrs, :value, %{version: 3}))
      assert AssetsState.count() == 1

      # Verify final value
      assert AssetsState.get_value("upsert_site", "upsert_type") == %{version: 3}
    end
  end

  describe "error handling" do
    @tag missing_fields: %{id: "test"},
         missing_id: %{type: "test", value: %{}, updated_at: ~U[2024-01-01 00:00:00Z]}
    test "gracefully handles malformed input", %{
      missing_fields: missing_fields,
      missing_id: missing_id
    } do
      # These should not crash the system, though behavior may vary

      # Missing required fields - should raise match error
      assert_raise MatchError, fn ->
        # Missing type, value, updated_at
        AssetsState.save(missing_fields)
      end

      assert_raise MatchError, fn ->
        # Missing id
        AssetsState.save(missing_id)
      end
    end

    test "handles operations on empty table gracefully" do
      assert AssetsState.count() == 0
      assert AssetsState.get("any", "any") == {:error, :not_found}
      assert AssetsState.get!("any", "any") == nil
      assert AssetsState.get_value("any", "any") == nil
      assert AssetsState.exists?("any", "any") == false
      assert AssetsState.get_by_site("any") == []
      assert AssetsState.get_by_type("any") == []
      assert AssetsState.get_all() == []
      assert AssetsState.get_many([{"any", "any"}]) == []
      assert AssetsState.delete("any", "any") == :ok
      assert AssetsState.update_value("any", "any", %{}) == {:error, :not_found}
      assert AssetsState.touch("any", "any") == {:error, :not_found}
    end
  end

  describe "memory and cleanup" do
    test "memory usage is reasonable for moderate datasets" do
      # Create moderate dataset
      assets =
        for site <- 1..100, type <- ["theme", "config", "scripts"] do
          %{
            id: "site_#{site}",
            type: type,
            value: %{data: "content for #{site} #{type}"},
            hash: "hashed",
            updated_at: DateTime.utc_now()
          }
        end

      AssetsState.save_batch(assets)
      assert AssetsState.count() == 300

      stats = AssetsState.stats()
      memory_words = stats.memory

      # Memory should be reasonable (less than 10MB for this test dataset)
      # ETS memory is in words, 1 word = 8 bytes on 64-bit systems
      memory_bytes = memory_words * 8
      # 10MB limit
      assert memory_bytes < 10 * 1024 * 1024

      # Clear should free all memory
      AssetsState.clear()
      assert AssetsState.count() == 0

      # After clear, memory should be much smaller
      stats_after = AssetsState.stats()
      assert stats_after.memory < memory_words
    end
  end

  describe "delete_by_site/1" do
    setup do
      assets = [
        %{
          id: "site_to_delete",
          type: "theme",
          value: %{css: "red"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: "site_to_delete",
          type: "config",
          value: %{title: "Delete Me"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 11:00:00Z]
        },
        %{
          id: "site_to_delete",
          type: "scripts",
          value: %{js: "test"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 12:00:00Z]
        },
        %{
          id: "keep_this_site",
          type: "theme",
          value: %{css: "blue"},
          hash: "hashed",
          updated_at: ~U[2024-01-01 13:00:00Z]
        }
      ]

      AssetsState.save_batch(assets)
      :ok
    end

    test "deletes all assets for a specific site" do
      assert AssetsState.count() == 4
      assert length(AssetsState.get_by_site("site_to_delete")) == 3
      assert length(AssetsState.get_by_site("keep_this_site")) == 1

      deleted_count = AssetsState.delete_by_site("site_to_delete")

      assert deleted_count == 3
      assert AssetsState.count() == 1
      assert AssetsState.get_by_site("site_to_delete") == []
      assert length(AssetsState.get_by_site("keep_this_site")) == 1

      # Verify specific assets are gone
      assert AssetsState.exists?("site_to_delete", "theme") == false
      assert AssetsState.exists?("site_to_delete", "config") == false
      assert AssetsState.exists?("site_to_delete", "scripts") == false

      # Verify other site's assets remain
      assert AssetsState.exists?("keep_this_site", "theme") == true
    end

    test "returns 0 when deleting non-existing site" do
      deleted_count = AssetsState.delete_by_site("nonexistent_site")
      assert deleted_count == 0
      # Original count unchanged
      assert AssetsState.count() == 4
    end

    test "delete_by_site is idempotent" do
      first_delete = AssetsState.delete_by_site("site_to_delete")
      assert first_delete == 3

      second_delete = AssetsState.delete_by_site("site_to_delete")
      assert second_delete == 0
      assert AssetsState.count() == 1
    end

    test "handles site with single asset" do
      # Delete the site with multiple assets first
      AssetsState.delete_by_site("site_to_delete")
      assert AssetsState.count() == 1

      deleted_count = AssetsState.delete_by_site("keep_this_site")
      assert deleted_count == 1
      assert AssetsState.count() == 0
    end
  end
end
