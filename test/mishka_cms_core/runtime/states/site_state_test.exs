defmodule MishkaCmsCore.Runtime.States.SiteStateTest do
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.States.SiteState
  @moduletag :unit

  setup_all do
    # Stop the boot handler if it's running in test environment
    case GenServer.whereis(MishkaCmsCore.Runtime.Handlers.BootHandler) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    case GenServer.whereis(SiteState) do
      nil ->
        {:ok, _pid} = SiteState.start_link()

      _pid ->
        :ok
    end

    Process.sleep(50)

    :ok
  end

  setup do
    SiteState.clear()

    on_exit(fn ->
      SiteState.clear()
    end)

    :ok
  end

  describe "save/1" do
    test "saves a site with all fields" do
      attrs = %{
        id: "site_1",
        name: "Example Site",
        host: "example.com",
        priority: 80,
        active: true
      }

      assert :ok = SiteState.save(attrs)
      assert {:ok, site} = SiteState.get("site_1")
      assert site.id == "site_1"
      assert site.name == "Example Site"
      assert site.host == "example.com"
      assert site.priority == 80
      assert site.active == true
      assert site.master == false
    end

    test "returns error when host already exists" do
      attrs1 = %{
        id: "site_1",
        name: "Site One",
        host: "example.com",
        priority: 80,
        active: true
      }

      attrs2 = %{
        id: "site_2",
        name: "Site Two",
        host: "example.com",
        priority: 70,
        active: true
      }

      assert :ok = SiteState.save(attrs1)
      assert {:error, :host_already_exists} = SiteState.save(attrs2)
    end

    test "returns error when name already exists" do
      attrs1 = %{
        id: "site_1",
        name: "My Site",
        host: "example1.com",
        priority: 80,
        active: true
      }

      attrs2 = %{
        id: "site_2",
        name: "My Site",
        host: "example2.com",
        priority: 70,
        active: true
      }

      assert :ok = SiteState.save(attrs1)
      assert {:error, :name_already_exists} = SiteState.save(attrs2)
    end

    test "updates existing site and cleans up old indexes" do
      attrs1 = %{
        id: "site_1",
        name: "Old Name",
        host: "old.com",
        priority: 80,
        active: true
      }

      attrs2 = %{
        id: "site_1",
        name: "New Name",
        host: "new.com",
        priority: 90,
        active: false
      }

      assert :ok = SiteState.save(attrs1)
      assert :ok = SiteState.save(attrs2)

      # Old host should not exist
      assert {:error, :not_found} = SiteState.get_by_host("old.com")
      # Old name should not exist
      assert {:error, :not_found} = SiteState.get_by_name("Old Name")

      # New host should exist
      assert {:ok, site} = SiteState.get_by_host("new.com")
      assert site.name == "New Name"
      assert site.priority == 90
      assert site.active == false
    end
  end

  describe "save_batch/1" do
    test "saves multiple sites at once" do
      sites = [
        %{
          id: "site_1",
          name: "Site One",
          host: "one.com",
          priority: 90,
          active: true
        },
        %{
          id: "site_2",
          name: "Site Two",
          host: "two.com",
          priority: 80,
          active: true
        },
        %{
          id: "site_3",
          name: "Site Three",
          host: "three.com",
          priority: 70,
          active: false
        }
      ]

      assert :ok = SiteState.save_batch(sites)
      assert SiteState.count() == 3
      assert SiteState.get!("site_1").name == "Site One"
      assert SiteState.get!("site_2").name == "Site Two"
      assert SiteState.get!("site_3").name == "Site Three"
    end

    test "handles empty list" do
      assert :ok = SiteState.save_batch([])
      assert SiteState.count() == 0
    end

    test "batch save skips conflict checking (use with caution)" do
      sites = [
        %{
          id: "site_1",
          name: "Same Name",
          host: "one.com",
          priority: 90,
          active: true
        },
        %{
          id: "site_2",
          # Duplicate name - batch save allows this
          name: "Same Name",
          host: "two.com",
          priority: 80,
          active: true
        }
      ]

      # Batch save doesn't check conflicts
      assert :ok = SiteState.save_batch(sites)
      assert SiteState.count() == 2
    end
  end

  describe "get_by_host/1 and get_by_host!/1" do
    setup do
      attrs = %{
        id: "test_site",
        name: "Test Site",
        host: "test.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)
      :ok
    end

    test "get_by_host/1 returns {:ok, site} when host exists" do
      assert {:ok, site} = SiteState.get_by_host("test.com")
      assert site.id == "test_site"
      assert site.name == "Test Site"
    end

    test "get_by_host/1 returns {:error, :not_found} when host doesn't exist" do
      assert {:error, :not_found} = SiteState.get_by_host("nonexistent.com")
    end

    test "get_by_host!/1 returns site map when exists" do
      assert site = SiteState.get_by_host!("test.com")
      assert site.id == "test_site"
      assert site.name == "Test Site"
    end

    test "get_by_host!/1 returns nil when host doesn't exist" do
      assert nil == SiteState.get_by_host!("nonexistent.com")
    end
  end

  describe "get_by_name/1" do
    setup do
      attrs = %{
        id: "test_site",
        name: "Test Site",
        host: "test.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)
      :ok
    end

    test "returns {:ok, site} when name exists" do
      assert {:ok, site} = SiteState.get_by_name("Test Site")
      assert site.id == "test_site"
      assert site.host == "test.com"
    end

    test "returns {:error, :not_found} when name doesn't exist" do
      assert {:error, :not_found} = SiteState.get_by_name("Nonexistent Site")
    end
  end

  describe "get/1 and get!/1" do
    setup do
      attrs = %{
        id: "test_site",
        name: "Test Site",
        host: "test.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)
      :ok
    end

    test "get/1 returns {:ok, site} when site exists" do
      assert {:ok, site} = SiteState.get("test_site")
      assert site.id == "test_site"
      assert site.name == "Test Site"
      assert site.host == "test.com"
      assert site.priority == 50
      assert site.active == true
    end

    test "get/1 returns {:error, :not_found} when site doesn't exist" do
      assert {:error, :not_found} = SiteState.get("nonexistent")
    end

    test "get!/1 returns site map when exists" do
      assert site = SiteState.get!("test_site")
      assert site.id == "test_site"
      assert site.name == "Test Site"
    end

    test "get!/1 returns nil when site doesn't exist" do
      assert nil == SiteState.get!("nonexistent")
    end
  end

  describe "get_active_sites/0" do
    setup do
      sites = [
        %{
          id: "active_1",
          name: "Active One",
          host: "active1.com",
          priority: 90,
          active: true
        },
        %{
          id: "active_2",
          name: "Active Two",
          host: "active2.com",
          priority: 80,
          active: true
        },
        %{
          id: "inactive_1",
          name: "Inactive One",
          host: "inactive1.com",
          # High priority but inactive
          priority: 100,
          active: false
        },
        %{
          id: "active_3",
          name: "Active Three",
          host: "active3.com",
          priority: 85,
          active: true
        }
      ]

      SiteState.save_batch(sites)
      :ok
    end

    test "returns only active sites sorted by priority DESC" do
      active_sites = SiteState.get_active_sites()

      assert length(active_sites) == 3

      # Check that all returned sites are active
      assert Enum.all?(active_sites, & &1.active)

      # Check sorting by priority DESC
      priorities = Enum.map(active_sites, & &1.priority)
      assert priorities == [90, 85, 80]

      # Check correct sites are returned
      ids = Enum.map(active_sites, & &1.id)
      assert ids == ["active_1", "active_3", "active_2"]
    end

    test "returns empty list when no active sites" do
      SiteState.clear()

      SiteState.save(%{
        id: "inactive",
        name: "Inactive",
        host: "inactive.com",
        priority: 100,
        active: false
      })

      assert SiteState.get_active_sites() == []
    end
  end

  describe "paginate/1" do
    setup do
      # Create test data with various priorities and active status
      sites =
        for i <- 1..25 do
          %{
            id: "site_#{i}",
            name: "Site #{i}",
            host: "site#{i}.com",
            # Priorities: 0, 10, 20, ..., 90
            priority: rem(i, 10) * 10,
            # Every 3rd site is inactive
            active: rem(i, 3) != 0
          }
        end

      SiteState.save_batch(sites)
      :ok
    end

    test "paginates with default options" do
      result = SiteState.paginate()

      assert result.page == 1
      assert result.limit == 20
      assert result.total == 25
      assert result.total_pages == 2
      assert result.has_next == true
      assert result.has_prev == false
      assert length(result.data) == 20
    end

    test "paginates with custom limit and page" do
      result = SiteState.paginate(%{page: 2, limit: 10})

      assert result.page == 2
      assert result.limit == 10
      assert result.total == 25
      assert result.total_pages == 3
      assert result.has_next == true
      assert result.has_prev == true
      assert length(result.data) == 10
    end

    test "filters by active status" do
      # 25 total sites, every 3rd is inactive, so 17 active sites
      result = SiteState.paginate(%{active: true, limit: 20})

      assert result.total == 17
      assert Enum.all?(result.data, & &1.active)

      # Test inactive
      inactive_result = SiteState.paginate(%{active: false, limit: 20})
      assert inactive_result.total == 8
      assert Enum.all?(inactive_result.data, &(!&1.active))
    end

    test "sorts by priority DESC by default" do
      result = SiteState.paginate(%{limit: 10})

      priorities = Enum.map(result.data, & &1.priority)
      # Should be sorted DESC
      assert priorities == Enum.sort(priorities, :desc)
    end

    test "sorts by name with custom order" do
      result = SiteState.paginate(%{sort: :name, order: :asc, limit: 5})

      names = Enum.map(result.data, & &1.name)
      assert names == ["Site 1", "Site 10", "Site 11", "Site 12", "Site 13"]

      # Test DESC
      desc_result = SiteState.paginate(%{sort: :name, order: :desc, limit: 5})
      desc_names = Enum.map(desc_result.data, & &1.name)
      assert hd(desc_names) == "Site 9"
    end

    test "handles empty results" do
      SiteState.clear()

      result = SiteState.paginate()

      assert result.total == 0
      assert result.total_pages == 0
      assert result.data == []
      assert result.has_next == false
      assert result.has_prev == false
    end

    test "handles last page correctly" do
      result = SiteState.paginate(%{page: 2, limit: 20})

      assert result.page == 2
      # 25 - 20 = 5
      assert length(result.data) == 5
      assert result.has_next == false
      assert result.has_prev == true
    end
  end

  describe "stream/1" do
    setup do
      sites =
        for i <- 1..10 do
          %{
            id: "site_#{i}",
            name: "Site #{String.pad_leading(Integer.to_string(i), 2, "0")}",
            host: "site#{i}.com",
            priority: i * 10,
            # Even numbers are active
            active: rem(i, 2) == 0
          }
        end

      SiteState.save_batch(sites)
      :ok
    end

    test "streams all sites" do
      sites =
        SiteState.stream()
        |> Enum.to_list()

      assert length(sites) == 10
    end

    test "streams with active filter" do
      active_sites =
        SiteState.stream(%{active: true})
        |> Enum.to_list()

      assert length(active_sites) == 5
      assert Enum.all?(active_sites, & &1.active)
    end

    test "streams with sorting by priority DESC" do
      sites =
        SiteState.stream(%{sort: :priority, order: :desc})
        |> Enum.to_list()

      priorities = Enum.map(sites, & &1.priority)
      assert priorities == [100, 90, 80, 70, 60, 50, 40, 30, 20, 10]
    end

    test "streams with custom chunk size" do
      # This is more about internal behavior, but we can verify it works
      sites =
        SiteState.stream(%{chunk_size: 3})
        |> Enum.to_list()

      assert length(sites) == 10
    end

    test "can be used with Stream functions" do
      high_priority_count =
        SiteState.stream()
        |> Stream.filter(fn site -> site.priority >= 50 end)
        |> Enum.count()

      # Sites 5-10 have priority >= 50
      assert high_priority_count == 6
    end
  end

  describe "get_by_priority_range/2" do
    setup do
      sites = [
        %{id: "site_1", name: "Site 1", host: "site1.com", priority: 10, active: true},
        %{id: "site_2", name: "Site 2", host: "site2.com", priority: 25, active: true},
        %{id: "site_3", name: "Site 3", host: "site3.com", priority: 50, active: true},
        %{id: "site_4", name: "Site 4", host: "site4.com", priority: 75, active: true},
        %{id: "site_5", name: "Site 5", host: "site5.com", priority: 90, active: true}
      ]

      SiteState.save_batch(sites)
      :ok
    end

    test "returns sites within priority range sorted DESC" do
      sites = SiteState.get_by_priority_range(25, 75)

      assert length(sites) == 3

      ids = Enum.map(sites, & &1.id)
      assert ids == ["site_4", "site_3", "site_2"]

      priorities = Enum.map(sites, & &1.priority)
      assert priorities == [75, 50, 25]
    end

    test "handles empty range" do
      sites = SiteState.get_by_priority_range(91, 100)
      assert sites == []
    end

    test "includes boundaries" do
      sites = SiteState.get_by_priority_range(10, 90)
      assert length(sites) == 5
    end
  end

  describe "host_exists?/1" do
    setup do
      attrs = %{
        id: "test_site",
        name: "Test Site",
        host: "test.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)
      :ok
    end

    test "returns true for existing host" do
      assert SiteState.host_exists?("test.com") == true
    end

    test "returns false for non-existing host" do
      assert SiteState.host_exists?("nonexistent.com") == false
    end
  end

  describe "exists?/1" do
    setup do
      attrs = %{
        id: "test_site",
        name: "Test Site",
        host: "test.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)
      :ok
    end

    test "returns true for existing site" do
      assert SiteState.exists?("test_site") == true
    end

    test "returns false for non-existing site" do
      assert SiteState.exists?("nonexistent") == false
    end
  end

  describe "delete/1" do
    setup do
      attrs = %{
        id: "test_site",
        name: "Test Site",
        host: "test.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)
      :ok
    end

    test "deletes site and all indexes" do
      assert SiteState.exists?("test_site") == true
      assert SiteState.host_exists?("test.com") == true

      assert :ok = SiteState.delete("test_site")

      assert SiteState.exists?("test_site") == false
      assert SiteState.host_exists?("test.com") == false
      assert {:error, :not_found} = SiteState.get("test_site")
      assert {:error, :not_found} = SiteState.get_by_host("test.com")
      assert {:error, :not_found} = SiteState.get_by_name("Test Site")
    end

    test "delete is idempotent" do
      assert :ok = SiteState.delete("test_site")
      assert :ok = SiteState.delete("test_site")
      assert SiteState.exists?("test_site") == false
    end
  end

  describe "count/0" do
    test "returns correct count of sites" do
      assert SiteState.count() == 0

      sites = [
        %{id: "site_1", name: "Site 1", host: "site1.com", priority: 80, active: true},
        %{id: "site_2", name: "Site 2", host: "site2.com", priority: 70, active: true},
        %{id: "site_3", name: "Site 3", host: "site3.com", priority: 60, active: false}
      ]

      SiteState.save_batch(sites)
      assert SiteState.count() == 3

      SiteState.delete("site_1")
      assert SiteState.count() == 2
    end
  end

  describe "clear/0" do
    test "removes all data from all tables" do
      sites = [
        %{id: "site_1", name: "Site 1", host: "site1.com", priority: 80, active: true},
        %{id: "site_2", name: "Site 2", host: "site2.com", priority: 70, active: true}
      ]

      SiteState.save_batch(sites)
      assert SiteState.count() == 2

      assert :ok = SiteState.clear()
      assert SiteState.count() == 0
      assert SiteState.get!("site_1") == nil
      assert SiteState.get!("site_2") == nil
      assert {:error, :not_found} = SiteState.get_by_host("site1.com")
    end

    test "clear is idempotent" do
      assert :ok = SiteState.clear()
      assert :ok = SiteState.clear()
      assert SiteState.count() == 0
    end
  end

  describe "performance characteristics" do
    @tag :performance
    test "handles large datasets efficiently" do
      # Create 3000 sites (as mentioned in requirements)
      sites =
        for i <- 1..3000 do
          %{
            id: "site_#{i}",
            name: "Site #{i}",
            host: "site#{i}.com",
            priority: rem(i, 100) + 1,
            active: rem(i, 10) != 0
          }
        end

      # Measure batch insert time
      {time, :ok} = :timer.tc(fn -> SiteState.save_batch(sites) end)
      # Should complete in less than 200ms for 3k records
      assert time < 200_000

      # Measure host lookup time
      {time, {:ok, _site}} = :timer.tc(fn -> SiteState.get_by_host("site1500.com") end)
      # Should complete in less than 1ms
      assert time < 1000

      # Measure name lookup time
      {time, {:ok, _site}} = :timer.tc(fn -> SiteState.get_by_name("Site 1500") end)
      # Should complete in less than 1ms
      assert time < 1000

      # Measure exists check time
      {time, true} = :timer.tc(fn -> SiteState.exists?("site_1500") end)
      # Should complete in less than 1ms
      assert time < 1000

      # Measure host exists check time
      {time, true} = :timer.tc(fn -> SiteState.host_exists?("site1500.com") end)
      # Should complete in less than 1ms
      assert time < 1000

      assert SiteState.count() == 3000
    end

    @tag :performance
    test "pagination performance with large dataset" do
      # Create 1000 sites
      sites =
        for i <- 1..1000 do
          %{
            id: "site_#{i}",
            name: "Site #{String.pad_leading(Integer.to_string(i), 4, "0")}",
            host: "site#{i}.com",
            priority: rem(i, 100) + 1,
            active: true
          }
        end

      SiteState.save_batch(sites)

      # Measure pagination time
      {time, result} = :timer.tc(fn -> SiteState.paginate(%{page: 1, limit: 20}) end)

      # Should complete in less than 50ms even with sorting
      assert time < 50_000
      assert length(result.data) == 20
      assert result.total == 1000
    end
  end

  describe "concurrent access" do
    @tag :concurrent
    test "handles concurrent reads and writes" do
      # Setup initial sites
      sites =
        for i <- 1..10 do
          %{
            id: "concurrent_#{i}",
            name: "Concurrent #{i}",
            host: "concurrent#{i}.com",
            priority: i * 10,
            active: true
          }
        end

      SiteState.save_batch(sites)

      # Spawn multiple processes to read and write concurrently
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            site_num = rem(i, 10) + 1

            # Mix of operations
            for _ <- 1..50 do
              case rem(i, 4) do
                0 ->
                  # Read by host
                  SiteState.get_by_host!("concurrent#{site_num}.com")

                1 ->
                  # Read by name
                  SiteState.get_by_name("Concurrent #{site_num}")

                2 ->
                  # Existence checks
                  SiteState.exists?("concurrent_#{site_num}")
                  SiteState.host_exists?("concurrent#{site_num}.com")

                3 ->
                  # Update operations
                  attrs = %{
                    id: "concurrent_#{site_num}",
                    name: "Concurrent #{site_num}",
                    host: "concurrent#{site_num}.com",
                    priority: i * 10,
                    active: rem(i, 2) == 0
                  }

                  SiteState.save(attrs)
              end
            end

            :ok
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify data integrity
      assert SiteState.count() == 10

      for i <- 1..10 do
        assert SiteState.exists?("concurrent_#{i}")
        assert SiteState.host_exists?("concurrent#{i}.com")
      end
    end
  end

  describe "edge cases" do
    test "handles special characters in names and hosts" do
      special_cases = [
        {"Site with Spaces", "site-with-dashes.com"},
        {"Site.with.Dots", "site.with.dots.com"},
        {"Site@Special#Chars", "sub.domain.example.com"},
        # Cyrillic
        {"Сайт", "example.ru"},
        # Chinese
        {"网站", "example.cn"},
        # Japanese
        {"サイト", "example.jp"}
      ]

      special_cases
      |> Enum.with_index()
      |> Enum.each(fn {{name, host}, index} ->
        attrs = %{
          id: "special_#{index}",
          name: name,
          host: host,
          priority: 50,
          active: true
        }

        assert :ok = SiteState.save(attrs)
        assert {:ok, site} = SiteState.get_by_name(name)
        assert site.host == host
        assert {:ok, site} = SiteState.get_by_host(host)
        assert site.name == name
      end)
    end

    test "handles empty table operations gracefully" do
      assert SiteState.count() == 0
      assert SiteState.get("any") == {:error, :not_found}
      assert SiteState.get!("any") == nil
      assert SiteState.get_by_host("any.com") == {:error, :not_found}
      assert SiteState.get_by_host!("any.com") == nil
      assert SiteState.get_by_name("any") == {:error, :not_found}
      assert SiteState.exists?("any") == false
      assert SiteState.host_exists?("any.com") == false
      assert SiteState.get_active_sites() == []
      assert SiteState.delete("any") == :ok

      result = SiteState.paginate()
      assert result.data == []
      assert result.total == 0
    end

    test "handles priority boundaries" do
      sites = [
        %{id: "min_priority", name: "Min", host: "min.com", priority: 0, active: true},
        %{id: "max_priority", name: "Max", host: "max.com", priority: 100, active: true}
      ]

      SiteState.save_batch(sites)

      all_sites = SiteState.get_active_sites()
      assert hd(all_sites).priority == 100
      assert List.last(all_sites).priority == 0
    end
  end

  describe "data integrity" do
    test "maintains uniqueness constraints properly" do
      # Save initial site
      attrs1 = %{
        id: "site_1",
        name: "Unique Name",
        host: "unique.com",
        priority: 50,
        active: true
      }

      assert :ok = SiteState.save(attrs1)

      # Try to save another site with same host
      attrs2 = %{
        id: "site_2",
        name: "Different Name",
        # Same host
        host: "unique.com",
        priority: 60,
        active: true
      }

      assert {:error, :host_already_exists} = SiteState.save(attrs2)

      # Try to save another site with same name
      attrs3 = %{
        id: "site_3",
        # Same name
        name: "Unique Name",
        host: "different.com",
        priority: 70,
        active: true
      }

      assert {:error, :name_already_exists} = SiteState.save(attrs3)

      # Verify only original site exists
      assert SiteState.count() == 1
      assert SiteState.get!("site_1").name == "Unique Name"
    end

    test "update maintains index consistency" do
      # Create initial site
      attrs = %{
        id: "update_test",
        name: "Original Name",
        host: "original.com",
        priority: 50,
        active: true
      }

      SiteState.save(attrs)

      # Update with new host and name
      updated_attrs = %{
        id: "update_test",
        name: "Updated Name",
        host: "updated.com",
        priority: 60,
        active: false
      }

      SiteState.save(updated_attrs)

      # Old indexes should not exist
      assert {:error, :not_found} = SiteState.get_by_host("original.com")
      assert {:error, :not_found} = SiteState.get_by_name("Original Name")

      # New indexes should work
      assert {:ok, site} = SiteState.get_by_host("updated.com")
      assert site.name == "Updated Name"
      assert site.priority == 60
      assert site.active == false

      assert {:ok, site} = SiteState.get_by_name("Updated Name")
      assert site.host == "updated.com"
    end
  end

  describe "error handling" do
    test "gracefully handles malformed input" do
      # Missing required fields - should raise match error
      assert_raise MatchError, fn ->
        # Missing name, host, priority, active
        SiteState.save(%{id: "test"})
      end

      assert_raise MatchError, fn ->
        # Missing id
        SiteState.save(%{name: "Test", host: "test.com"})
      end
    end
  end

  describe "master site functionality" do
    test "get_by_master returns error when no master site exists" do
      # Create sites without master
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "site1.com",
          priority: 80,
          active: true,
          master: false
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "site2.com",
          priority: 70,
          active: true,
          master: false
        }
      ]

      SiteState.save_batch(sites)

      assert {:error, :not_found} = SiteState.get_by_master()
      assert nil == SiteState.get_by_master!()
    end

    test "get_by_master returns the master site when it exists" do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "site1.com",
          priority: 80,
          active: true,
          master: false
        },
        %{
          id: "master_site",
          name: "Master Site",
          host: "master.com",
          priority: 100,
          active: true,
          master: true
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "site2.com",
          priority: 70,
          active: true,
          master: false
        }
      ]

      SiteState.save_batch(sites)

      assert {:ok, master} = SiteState.get_by_master()
      assert master.id == "master_site"
      assert master.name == "Master Site"
      assert master.master == true

      # Test bang version
      master_bang = SiteState.get_by_master!()
      assert master_bang.id == "master_site"
      assert master_bang.master == true
    end

    test "set_master sets a site as master and unsets previous master" do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "site1.com",
          priority: 80,
          active: true,
          master: false
        },
        %{
          id: "old_master",
          name: "Old Master",
          host: "oldmaster.com",
          priority: 100,
          active: true,
          master: true
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "site2.com",
          priority: 70,
          active: true,
          master: false
        }
      ]

      SiteState.save_batch(sites)

      # Verify old master exists
      assert {:ok, old_master} = SiteState.get_by_master()
      assert old_master.id == "old_master"

      # Set site_1 as new master
      assert {:ok, new_master} = SiteState.set_master("site_1")
      assert new_master.id == "site_1"
      assert new_master.master == true

      # Verify only one master exists
      assert {:ok, current_master} = SiteState.get_by_master()
      assert current_master.id == "site_1"

      # Verify old master is no longer master
      assert {:ok, old_site} = SiteState.get("old_master")
      assert old_site.master == false
    end

    test "set_master returns error for non-existent site" do
      assert {:error, :not_found} = SiteState.set_master("non_existent")
    end

    test "set_master works when no previous master exists" do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "site1.com",
          priority: 80,
          active: true,
          master: false
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "site2.com",
          priority: 70,
          active: true,
          master: false
        }
      ]

      SiteState.save_batch(sites)

      # No master initially
      assert {:error, :not_found} = SiteState.get_by_master()

      # Set site_1 as master
      assert {:ok, master} = SiteState.set_master("site_1")
      assert master.master == true

      # Verify it's now the master
      assert {:ok, current_master} = SiteState.get_by_master()
      assert current_master.id == "site_1"
    end

    test "unset_master removes master status from current master" do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "site1.com",
          priority: 80,
          active: true,
          master: false
        },
        %{
          id: "master_site",
          name: "Master Site",
          host: "master.com",
          priority: 100,
          active: true,
          master: true
        }
      ]

      SiteState.save_batch(sites)

      # Verify master exists
      assert {:ok, master} = SiteState.get_by_master()
      assert master.id == "master_site"

      # Unset master
      assert {:ok, unset_site} = SiteState.unset_master()
      assert unset_site.id == "master_site"
      assert unset_site.master == false

      # Verify no master exists now
      assert {:error, :not_found} = SiteState.get_by_master()
      assert nil == SiteState.get_by_master!()

      # Verify the site still exists but not as master
      assert {:ok, site} = SiteState.get("master_site")
      assert site.master == false
    end

    test "unset_master returns error when no master exists" do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "site1.com",
          priority: 80,
          active: true,
          master: false
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "site2.com",
          priority: 70,
          active: true,
          master: false
        }
      ]

      SiteState.save_batch(sites)

      assert {:error, :not_found} = SiteState.unset_master()
    end

    test "save preserves master field when updating site" do
      # Initial site with master = true
      attrs1 = %{
        id: "master_site",
        name: "Master Site",
        host: "master.com",
        priority: 100,
        active: true,
        master: true
      }

      SiteState.save(attrs1)

      # Verify it's master
      assert {:ok, site} = SiteState.get("master_site")
      assert site.master == true

      # Update other fields without changing master
      attrs2 = %{
        id: "master_site",
        name: "Updated Master",
        host: "newmaster.com",
        priority: 90,
        active: true,
        master: true
      }

      SiteState.save(attrs2)

      # Verify master is still true
      assert {:ok, updated} = SiteState.get("master_site")
      assert updated.master == true
      assert updated.name == "Updated Master"
      assert updated.host == "newmaster.com"
    end

    test "multiple masters can exist if added via batch (edge case - should be prevented at DB level)" do
      # This tests that batch save bypasses the single-master logic
      # In production, the database constraints should prevent this
      sites = [
        %{
          id: "master_1",
          name: "Master 1",
          host: "master1.com",
          priority: 100,
          active: true,
          master: true
        },
        %{
          id: "master_2",
          name: "Master 2",
          host: "master2.com",
          priority: 90,
          active: true,
          master: true
        }
      ]

      SiteState.save_batch(sites)

      # Both sites have master = true in state
      assert {:ok, site1} = SiteState.get("master_1")
      assert site1.master == true

      assert {:ok, site2} = SiteState.get("master_2")
      assert site2.master == true

      # get_by_master will return the first one it finds
      assert {:ok, master} = SiteState.get_by_master()
      assert master.id in ["master_1", "master_2"]

      # set_master should clean this up
      assert {:ok, _} = SiteState.set_master("master_1")

      # Now only master_1 should be master
      assert {:ok, site1} = SiteState.get("master_1")
      assert site1.master == true

      assert {:ok, site2} = SiteState.get("master_2")
      assert site2.master == false
    end
  end

  describe "sorting behavior" do
    test "paginate correctly sorts by priority DESC then maintains stable order" do
      # Create sites with same priority to test stable sorting
      sites = [
        %{id: "a1", name: "A1", host: "a1.com", priority: 50, active: true},
        %{id: "b1", name: "B1", host: "b1.com", priority: 50, active: true},
        %{id: "c1", name: "C1", host: "c1.com", priority: 50, active: true},
        %{id: "d1", name: "D1", host: "d1.com", priority: 80, active: true},
        %{id: "e1", name: "E1", host: "e1.com", priority: 80, active: true},
        %{id: "f1", name: "F1", host: "f1.com", priority: 20, active: true}
      ]

      SiteState.save_batch(sites)

      result = SiteState.paginate(%{limit: 10})

      priorities = Enum.map(result.data, & &1.priority)
      assert priorities == [80, 80, 50, 50, 50, 20]

      # Within same priority, order should be stable (though not guaranteed which order)
      priority_80_sites = result.data |> Enum.filter(&(&1.priority == 80)) |> Enum.map(& &1.id)
      assert length(priority_80_sites) == 2
      assert "d1" in priority_80_sites
      assert "e1" in priority_80_sites
    end

    test "paginate correctly sorts by name ASC/DESC" do
      sites = [
        %{id: "1", name: "Zebra Site", host: "z.com", priority: 50, active: true},
        %{id: "2", name: "Alpha Site", host: "a.com", priority: 50, active: true},
        %{id: "3", name: "Beta Site", host: "b.com", priority: 50, active: true},
        %{id: "4", name: "Gamma Site", host: "g.com", priority: 50, active: true}
      ]

      SiteState.save_batch(sites)

      # Test ASC
      asc_result = SiteState.paginate(%{sort: :name, order: :asc})
      names = Enum.map(asc_result.data, & &1.name)
      assert names == ["Alpha Site", "Beta Site", "Gamma Site", "Zebra Site"]

      # Test DESC
      desc_result = SiteState.paginate(%{sort: :name, order: :desc})
      names = Enum.map(desc_result.data, & &1.name)
      assert names == ["Zebra Site", "Gamma Site", "Beta Site", "Alpha Site"]
    end
  end

  # THESE TABLES ARE PER NODE, THE CLUSTER IS NOT. A site created, renamed or destroyed on one node
  # left every other one resolving hosts against a stale table — the wrong site answering a request,
  # or a 404 for a site that exists. There is no second node in a test, so these deliver the
  # broadcast the resource already publishes to a cache that did not do the writing.
  describe "a site written on another node" do
    defp site_broadcast(site, event) do
      topic = "site:#{event}"

      Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, topic, %Phoenix.Socket.Broadcast{
        topic: topic,
        event: event,
        payload: %Ash.Notifier.Notification{
          resource: MishkaCmsCore.Runtime.Site,
          data: site
        }
      })

      # Handled in the cache's own process; sync on a call so the assertion is not a race.
      :sys.get_state(SiteState)
    end

    defp remote_site(overrides \\ %{}) do
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "remote-#{System.unique_integer([:positive])}",
          host: "remote-#{System.unique_integer([:positive])}.test",
          priority: 1,
          active: true,
          master: false,
          mode: "hybrid",
          frontend_domain: nil,
          allowed_origins: []
        },
        overrides
      )
    end

    test "a create elsewhere becomes resolvable here" do
      site = remote_site()
      assert SiteState.get_by_host(site.host) == {:error, :not_found}

      site_broadcast(site, "created")

      assert {:ok, found} = SiteState.get_by_host(site.host)
      assert found.id == site.id
    end

    test "an update elsewhere moves the host index with it" do
      site = remote_site()
      site_broadcast(site, "created")
      assert {:ok, _} = SiteState.get_by_host(site.host)

      moved = %{site | host: "moved-#{System.unique_integer([:positive])}.test"}
      site_broadcast(moved, "updated")

      assert {:ok, found} = SiteState.get_by_host(moved.host)
      assert found.id == site.id

      assert SiteState.get_by_host(site.host) == {:error, :not_found},
             "the old host must stop resolving"
    end

    # The writing node hears its own broadcast too, and it has already applied the write inside the
    # action. Applying it again is harmless in ETS but fires `runtime:state:site:changed` a second
    # time, and a plugin registered on that event cannot tell the two apart.
    test "a broadcast from this node is ignored — the local write already applied it" do
      site = remote_site()
      site_broadcast(site, "created")
      assert {:ok, _} = SiteState.get_by_host(site.host)

      # `from: self()` is what a local write looks like; the earlier tests leave it nil, which is
      # how a notification arriving from another node reads here.
      topic = "site:destroyed"

      Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, topic, %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "destroyed",
        payload: %Ash.Notifier.Notification{
          resource: MishkaCmsCore.Runtime.Site,
          data: site,
          from: self()
        }
      })

      :sys.get_state(SiteState)

      assert {:ok, _} = SiteState.get_by_host(site.host),
             "a local echo must not be applied a second time"
    end

    test "a destroy elsewhere stops it resolving here" do
      site = remote_site()
      site_broadcast(site, "created")
      assert {:ok, _} = SiteState.get_by_host(site.host)

      site_broadcast(site, "destroyed")

      assert SiteState.get_by_host(site.host) == {:error, :not_found}
      refute SiteState.exists?(site.id)
    end
  end
end
