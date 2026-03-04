defmodule MishkaCmsCore.Runtime.States.WebRunTimeMetaDataStateTest do
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  @moduletag :unit

  setup_all do
    case GenServer.whereis(WebRunTimeMetaDataState) do
      nil ->
        {:ok, _pid} = WebRunTimeMetaDataState.start_link()

      _pid ->
        :ok
    end

    Process.sleep(50)

    :ok
  end

  setup do
    WebRunTimeMetaDataState.clear()

    on_exit(fn ->
      WebRunTimeMetaDataState.clear()
    end)

    :ok
  end

  describe "save/1" do
    test "saves a page with all fields" do
      attrs = %{
        id: "page_1",
        site: "example.com",
        path: "/about",
        title: "About Us",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 80
      }

      assert :ok = WebRunTimeMetaDataState.save(attrs)
      assert {:ok, page} = WebRunTimeMetaDataState.get("page_1")
      assert page.id == "page_1"
      assert page.site == "example.com"
      assert page.path == "/about"
      assert page.title == "About Us"
      assert page.created_at == ~U[2024-01-01 10:00:00Z]
      assert page.section == "Page"
      assert page.priority == 80
    end

    test "returns error when path already exists for same site" do
      attrs1 = %{
        id: "page_1",
        site: "example.com",
        path: "/about",
        title: "About Us",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 80
      }

      attrs2 = %{
        id: "page_2",
        site: "example.com",
        path: "/about",
        title: "About Us 2",
        created_at: ~U[2024-01-01 11:00:00Z],
        section: "Page",
        priority: 70
      }

      assert :ok = WebRunTimeMetaDataState.save(attrs1)
      assert {:error, :path_already_exists} = WebRunTimeMetaDataState.save(attrs2)
    end

    test "allows same path on different sites" do
      attrs1 = %{
        id: "page_1",
        site: "example.com",
        path: "/about",
        title: "About Us",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 80
      }

      attrs2 = %{
        id: "page_2",
        site: "other.com",
        path: "/about",
        title: "About Us 2",
        created_at: ~U[2024-01-01 11:00:00Z],
        section: "Page",
        priority: 70
      }

      assert :ok = WebRunTimeMetaDataState.save(attrs1)
      assert :ok = WebRunTimeMetaDataState.save(attrs2)
    end

    test "updates existing page and cleans up old indexes" do
      attrs1 = %{
        id: "page_1",
        site: "example.com",
        path: "/about",
        title: "About Us",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 80
      }

      attrs2 = %{
        id: "page_1",
        site: "example.com",
        path: "/about-us",
        title: "About Us Updated",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "info",
        priority: 90
      }

      assert :ok = WebRunTimeMetaDataState.save(attrs1)
      assert :ok = WebRunTimeMetaDataState.save(attrs2)

      # Old path should not exist
      assert {:error, :not_found} =
               WebRunTimeMetaDataState.find_by_path_and_site("/about", "example.com")

      # New path should exist
      assert {:ok, page} =
               WebRunTimeMetaDataState.find_by_path_and_site("/about-us", "example.com")

      assert page.title == "About Us Updated"
      assert page.section == "info"
      assert page.priority == 90
    end
  end

  describe "save_batch/1" do
    test "saves multiple pages at once" do
      pages = [
        %{
          id: "page_1",
          site: "example.com",
          path: "/page1",
          title: "Page 1",
          created_at: ~U[2024-01-01 10:00:00Z],
          section: "Page",
          priority: 80
        },
        %{
          id: "page_2",
          site: "example.com",
          path: "/page2",
          title: "Page 2",
          created_at: ~U[2024-01-01 11:00:00Z],
          section: "Page",
          priority: 70
        },
        %{
          id: "page_3",
          site: "other.com",
          path: "/page3",
          title: "Page 3",
          created_at: ~U[2024-01-01 12:00:00Z],
          section: "blog",
          priority: 90
        }
      ]

      assert :ok = WebRunTimeMetaDataState.save_batch(pages)
      assert WebRunTimeMetaDataState.count() == 3
      assert WebRunTimeMetaDataState.get!("page_1").title == "Page 1"
      assert WebRunTimeMetaDataState.get!("page_2").title == "Page 2"
      assert WebRunTimeMetaDataState.get!("page_3").title == "Page 3"
    end
  end

  describe "get/1 and get!/1" do
    setup do
      attrs = %{
        id: "test_page",
        site: "example.com",
        path: "/test",
        title: "Test Page",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 50
      }

      WebRunTimeMetaDataState.save(attrs)
      :ok
    end

    test "get/1 returns {:ok, page} when page exists" do
      assert {:ok, page} = WebRunTimeMetaDataState.get("test_page")
      assert page.id == "test_page"
      assert page.title == "Test Page"
    end

    test "get/1 returns {:error, :not_found} when page doesn't exist" do
      assert {:error, :not_found} = WebRunTimeMetaDataState.get("nonexistent")
    end

    test "get!/1 returns page map when exists" do
      assert page = WebRunTimeMetaDataState.get!("test_page")
      assert page.id == "test_page"
      assert page.title == "Test Page"
    end

    test "get!/1 returns nil when page doesn't exist" do
      assert nil == WebRunTimeMetaDataState.get!("nonexistent")
    end
  end

  describe "paginate/1" do
    setup do
      # Create test data with various priorities and dates
      pages = [
        # Site: example.com, Section: blog
        %{
          id: "blog_1",
          site: "example.com",
          path: "/blog/1",
          title: "Blog Post 1",
          created_at: ~U[2024-01-01 10:00:00Z],
          section: "blog",
          priority: 90
        },
        %{
          id: "blog_2",
          site: "example.com",
          path: "/blog/2",
          title: "Blog Post 2",
          created_at: ~U[2024-01-01 11:00:00Z],
          section: "blog",
          priority: 90
        },
        %{
          id: "blog_3",
          site: "example.com",
          path: "/blog/3",
          title: "Blog Post 3",
          created_at: ~U[2024-01-01 12:00:00Z],
          section: "blog",
          priority: 80
        },
        %{
          id: "blog_4",
          site: "example.com",
          path: "/blog/4",
          title: "Blog Post 4",
          created_at: ~U[2024-01-01 09:00:00Z],
          section: "blog",
          priority: 100
        },
        # Site: example.com, Section: main
        %{
          id: "main_1",
          site: "example.com",
          path: "/about",
          title: "About",
          created_at: ~U[2024-01-01 08:00:00Z],
          section: "Page",
          priority: 95
        },
        # Site: other.com, Section: blog
        %{
          id: "other_1",
          site: "other.com",
          path: "/blog/1",
          title: "Other Blog 1",
          created_at: ~U[2024-01-01 10:00:00Z],
          section: "blog",
          priority: 85
        }
      ]

      WebRunTimeMetaDataState.save_batch(pages)
      :ok
    end

    test "paginates with site and section filter" do
      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "example.com",
          section: "blog",
          page: 1,
          limit: 10
        })

      assert result.total == 4
      assert result.total_pages == 1
      assert result.page == 1
      assert result.has_next == false
      assert result.has_prev == false
      assert length(result.data) == 4

      # Check sorting: priority DESC, created_at ASC
      ids = Enum.map(result.data, & &1.id)
      assert ids == ["blog_4", "blog_1", "blog_2", "blog_3"]
    end

    test "paginates with correct limit and offset" do
      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "example.com",
          section: "blog",
          page: 1,
          limit: 2
        })

      assert result.total == 4
      assert result.total_pages == 2
      assert result.page == 1
      assert result.has_next == true
      assert result.has_prev == false
      assert length(result.data) == 2

      ids = Enum.map(result.data, & &1.id)
      assert ids == ["blog_4", "blog_1"]

      # Page 2
      result2 =
        WebRunTimeMetaDataState.paginate(%{
          site: "example.com",
          section: "blog",
          page: 2,
          limit: 2
        })

      assert result2.page == 2
      assert result2.has_next == false
      assert result2.has_prev == true
      assert length(result2.data) == 2

      ids2 = Enum.map(result2.data, & &1.id)
      assert ids2 == ["blog_2", "blog_3"]
    end

    test "paginates with only site filter (all sections)" do
      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "example.com",
          page: 1,
          limit: 10
        })

      assert result.total == 5
      assert length(result.data) == 5
    end

    test "paginates with no filters (all pages)" do
      result =
        WebRunTimeMetaDataState.paginate(%{
          page: 1,
          limit: 10
        })

      assert result.total == 6
      assert length(result.data) == 6
    end

    test "handles empty results" do
      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "nonexistent.com",
          page: 1,
          limit: 10
        })

      assert result.total == 0
      assert result.total_pages == 0
      assert result.data == []
      assert result.has_next == false
      assert result.has_prev == false
    end
  end

  describe "stream_paginated/1" do
    setup do
      pages =
        for i <- 1..10 do
          %{
            id: "page_#{i}",
            site: "example.com",
            path: "/page/#{i}",
            title: "Page #{i}",
            created_at: ~U[2024-01-01 10:00:00Z],
            section: "Page",
            priority: i * 10
          }
        end

      WebRunTimeMetaDataState.save_batch(pages)
      :ok
    end

    test "streams all matching pages" do
      pages =
        WebRunTimeMetaDataState.stream_paginated(%{site: "example.com", section: "Page"})
        |> Enum.to_list()

      assert length(pages) == 10
      # Should be sorted by priority DESC
      assert hd(pages).priority == 100
      assert List.last(pages).priority == 10
    end

    test "can be used with Stream functions" do
      high_priority_count =
        WebRunTimeMetaDataState.stream_paginated(%{site: "example.com", section: "Page"})
        |> Stream.filter(fn page -> page.priority >= 50 end)
        |> Enum.count()

      assert high_priority_count == 6
    end
  end

  describe "find_by_path_and_site/2" do
    setup do
      attrs = %{
        id: "test_page",
        site: "example.com",
        path: "/test",
        title: "Test Page",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 50
      }

      WebRunTimeMetaDataState.save(attrs)
      :ok
    end

    test "finds page by path and site" do
      assert {:ok, page} = WebRunTimeMetaDataState.find_by_path_and_site("/test", "example.com")
      assert page.id == "test_page"
      assert page.title == "Test Page"
    end

    test "returns error when not found" do
      assert {:error, :not_found} =
               WebRunTimeMetaDataState.find_by_path_and_site("/other", "example.com")

      assert {:error, :not_found} =
               WebRunTimeMetaDataState.find_by_path_and_site("/test", "other.com")
    end
  end

  describe "exists?/1 and path_exists?/2" do
    setup do
      attrs = %{
        id: "test_page",
        site: "example.com",
        path: "/test",
        title: "Test Page",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 50
      }

      WebRunTimeMetaDataState.save(attrs)
      :ok
    end

    test "exists?/1 returns true for existing page" do
      assert WebRunTimeMetaDataState.exists?("test_page") == true
    end

    test "exists?/1 returns false for non-existing page" do
      assert WebRunTimeMetaDataState.exists?("nonexistent") == false
    end

    test "path_exists?/2 returns true for existing path" do
      assert WebRunTimeMetaDataState.path_exists?("/test", "example.com") == true
    end

    test "path_exists?/2 returns false for non-existing path" do
      assert WebRunTimeMetaDataState.path_exists?("/other", "example.com") == false
      assert WebRunTimeMetaDataState.path_exists?("/test", "other.com") == false
    end
  end

  describe "delete/1" do
    setup do
      attrs = %{
        id: "test_page",
        site: "example.com",
        path: "/test",
        title: "Test Page",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 50
      }

      WebRunTimeMetaDataState.save(attrs)
      :ok
    end

    test "deletes page and all indexes" do
      assert WebRunTimeMetaDataState.exists?("test_page") == true
      assert WebRunTimeMetaDataState.path_exists?("/test", "example.com") == true

      assert :ok = WebRunTimeMetaDataState.delete("test_page")

      assert WebRunTimeMetaDataState.exists?("test_page") == false
      assert WebRunTimeMetaDataState.path_exists?("/test", "example.com") == false
      assert {:error, :not_found} = WebRunTimeMetaDataState.get("test_page")
    end

    test "delete is idempotent" do
      assert :ok = WebRunTimeMetaDataState.delete("test_page")
      assert :ok = WebRunTimeMetaDataState.delete("test_page")
    end
  end

  describe "count functions" do
    setup do
      pages = [
        %{
          id: "page_1",
          site: "example.com",
          path: "/page1",
          title: "Page 1",
          created_at: ~U[2024-01-01 10:00:00Z],
          section: "Page",
          priority: 80
        },
        %{
          id: "page_2",
          site: "example.com",
          path: "/page2",
          title: "Page 2",
          created_at: ~U[2024-01-01 11:00:00Z],
          section: "blog",
          priority: 70
        },
        %{
          id: "page_3",
          site: "other.com",
          path: "/page3",
          title: "Page 3",
          created_at: ~U[2024-01-01 12:00:00Z],
          section: "blog",
          priority: 90
        }
      ]

      WebRunTimeMetaDataState.save_batch(pages)
      :ok
    end

    test "count/0 returns total count" do
      assert WebRunTimeMetaDataState.count() == 3
    end

    test "count_by_site/1 returns count for site" do
      assert WebRunTimeMetaDataState.count_by_site("example.com") == 2
      assert WebRunTimeMetaDataState.count_by_site("other.com") == 1
      assert WebRunTimeMetaDataState.count_by_site("nonexistent.com") == 0
    end

    test "count_by_site_and_section/2 returns count for site and section" do
      assert WebRunTimeMetaDataState.count_by_site_and_section("example.com", "Page") == 1
      assert WebRunTimeMetaDataState.count_by_site_and_section("example.com", "blog") == 1
      assert WebRunTimeMetaDataState.count_by_site_and_section("other.com", "blog") == 1
      assert WebRunTimeMetaDataState.count_by_site_and_section("example.com", "nonexistent") == 0
    end
  end

  describe "clear/0" do
    test "removes all data from all tables" do
      pages = [
        %{
          id: "page_1",
          site: "example.com",
          path: "/page1",
          title: "Page 1",
          created_at: ~U[2024-01-01 10:00:00Z],
          section: "Page",
          priority: 80
        },
        %{
          id: "page_2",
          site: "example.com",
          path: "/page2",
          title: "Page 2",
          created_at: ~U[2024-01-01 11:00:00Z],
          section: "Page",
          priority: 70
        }
      ]

      WebRunTimeMetaDataState.save_batch(pages)
      assert WebRunTimeMetaDataState.count() == 2

      assert :ok = WebRunTimeMetaDataState.clear()
      assert WebRunTimeMetaDataState.count() == 0
      assert WebRunTimeMetaDataState.get!("page_1") == nil
      assert WebRunTimeMetaDataState.get!("page_2") == nil
    end
  end

  describe "stats/0" do
    test "returns statistics about all tables" do
      pages =
        for i <- 1..5 do
          %{
            id: "page_#{i}",
            site: "example.com",
            path: "/page/#{i}",
            title: "Page #{i}",
            created_at: ~U[2024-01-01 10:00:00Z],
            section: "Page",
            priority: i * 10
          }
        end

      WebRunTimeMetaDataState.save_batch(pages)

      stats = WebRunTimeMetaDataState.stats()

      assert stats.main_table_size == 5
      assert stats.path_index_size == 5
      assert stats.site_index_size == 5
      assert stats.section_index_size == 5
      assert stats.sort_index_size == 5

      assert is_integer(stats.memory.main_table)
      assert is_integer(stats.memory.path_index)
      assert is_integer(stats.memory.site_index)
      assert is_integer(stats.memory.section_index)
      assert is_integer(stats.memory.sort_index)
    end
  end

  describe "rebuild_indexes/0" do
    test "rebuilds all indexes from main table" do
      pages = [
        %{
          id: "page_1",
          site: "example.com",
          path: "/page1",
          title: "Page 1",
          created_at: ~U[2024-01-01 10:00:00Z],
          section: "Page",
          priority: 80
        },
        %{
          id: "page_2",
          site: "example.com",
          path: "/page2",
          title: "Page 2",
          created_at: ~U[2024-01-01 11:00:00Z],
          section: "blog",
          priority: 70
        }
      ]

      WebRunTimeMetaDataState.save_batch(pages)

      # Manually corrupt an index by deleting from it
      :ets.delete(:mishka_web_run_time_meta_data_path_index, {"/page1", "example.com"})

      # Path should not be found
      assert {:error, :not_found} =
               WebRunTimeMetaDataState.find_by_path_and_site("/page1", "example.com")

      # Rebuild indexes
      WebRunTimeMetaDataState.rebuild_indexes()

      # Path should be found again
      assert {:ok, page} = WebRunTimeMetaDataState.find_by_path_and_site("/page1", "example.com")
      assert page.id == "page_1"
    end
  end

  describe "performance characteristics" do
    @tag :performance
    test "handles large datasets efficiently" do
      # Create 1000 pages
      pages =
        for i <- 1..1000 do
          %{
            id: "page_#{i}",
            site: "site_#{rem(i, 10)}",
            path: "/page/#{i}",
            title: "Page #{i}",
            created_at: DateTime.add(~U[2024-01-01 00:00:00Z], i * 60),
            section: "section_#{rem(i, 5)}",
            priority: rem(i, 100) + 1
          }
        end

      # Measure batch insert time
      {time, :ok} = :timer.tc(fn -> WebRunTimeMetaDataState.save_batch(pages) end)
      # Should complete in less than 100ms
      assert time < 100_000

      # Measure lookup time
      {time, {:ok, _page}} = :timer.tc(fn -> WebRunTimeMetaDataState.get("page_500") end)
      # Should complete in less than 1ms
      assert time < 1000

      # Measure pagination time
      {time, result} =
        :timer.tc(fn ->
          WebRunTimeMetaDataState.paginate(%{
            site: "site_1",
            section: "section_1",
            page: 1,
            limit: 20
          })
        end)

      # Should complete in less than 10ms
      assert time < 10_000
      assert length(result.data) > 0
    end
  end

  describe "paginate/1 with priority and created_at sorting" do
    test "correctly sorts 20 posts by priority DESC then created_at ASC" do
      # Create 20 posts with various priorities and timestamps
      base_time = ~U[2024-01-01 00:00:00Z]

      pages = [
        # Priority 100 (highest) - 3 posts with different times
        %{
          id: "p1",
          site: "test.com",
          path: "/p1",
          title: "P1",
          created_at: DateTime.add(base_time, 3600),
          section: "Page",
          priority: 100
        },
        %{
          id: "p2",
          site: "test.com",
          path: "/p2",
          title: "P2",
          created_at: DateTime.add(base_time, 7200),
          section: "Page",
          priority: 100
        },
        %{
          id: "p3",
          site: "test.com",
          path: "/p3",
          title: "P3",
          created_at: DateTime.add(base_time, 1800),
          section: "Page",
          priority: 100
        },

        # Priority 90 - 4 posts
        %{
          id: "p4",
          site: "test.com",
          path: "/p4",
          title: "P4",
          created_at: DateTime.add(base_time, 5000),
          section: "Page",
          priority: 90
        },
        %{
          id: "p5",
          site: "test.com",
          path: "/p5",
          title: "P5",
          created_at: DateTime.add(base_time, 4000),
          section: "Page",
          priority: 90
        },
        %{
          id: "p6",
          site: "test.com",
          path: "/p6",
          title: "P6",
          created_at: DateTime.add(base_time, 6000),
          section: "Page",
          priority: 90
        },
        %{
          id: "p7",
          site: "test.com",
          path: "/p7",
          title: "P7",
          created_at: DateTime.add(base_time, 3000),
          section: "Page",
          priority: 90
        },

        # Priority 80 - 3 posts
        %{
          id: "p8",
          site: "test.com",
          path: "/p8",
          title: "P8",
          created_at: DateTime.add(base_time, 8000),
          section: "Page",
          priority: 80
        },
        %{
          id: "p9",
          site: "test.com",
          path: "/p9",
          title: "P9",
          created_at: DateTime.add(base_time, 9000),
          section: "Page",
          priority: 80
        },
        %{
          id: "p10",
          site: "test.com",
          path: "/p10",
          title: "P10",
          created_at: DateTime.add(base_time, 7000),
          section: "Page",
          priority: 80
        },

        # Priority 70 - 3 posts
        %{
          id: "p11",
          site: "test.com",
          path: "/p11",
          title: "P11",
          created_at: DateTime.add(base_time, 10000),
          section: "Page",
          priority: 70
        },
        %{
          id: "p12",
          site: "test.com",
          path: "/p12",
          title: "P12",
          created_at: DateTime.add(base_time, 11000),
          section: "Page",
          priority: 70
        },
        %{
          id: "p13",
          site: "test.com",
          path: "/p13",
          title: "P13",
          created_at: DateTime.add(base_time, 12000),
          section: "Page",
          priority: 70
        },

        # Priority 60 - 3 posts
        %{
          id: "p14",
          site: "test.com",
          path: "/p14",
          title: "P14",
          created_at: DateTime.add(base_time, 15000),
          section: "Page",
          priority: 60
        },
        %{
          id: "p15",
          site: "test.com",
          path: "/p15",
          title: "P15",
          created_at: DateTime.add(base_time, 13000),
          section: "Page",
          priority: 60
        },
        %{
          id: "p16",
          site: "test.com",
          path: "/p16",
          title: "P16",
          created_at: DateTime.add(base_time, 14000),
          section: "Page",
          priority: 60
        },

        # Priority 50 - 4 posts
        %{
          id: "p17",
          site: "test.com",
          path: "/p17",
          title: "P17",
          created_at: DateTime.add(base_time, 18000),
          section: "Page",
          priority: 50
        },
        %{
          id: "p18",
          site: "test.com",
          path: "/p18",
          title: "P18",
          created_at: DateTime.add(base_time, 16000),
          section: "Page",
          priority: 50
        },
        %{
          id: "p19",
          site: "test.com",
          path: "/p19",
          title: "P19",
          created_at: DateTime.add(base_time, 17000),
          section: "Page",
          priority: 50
        },
        %{
          id: "p20",
          site: "test.com",
          path: "/p20",
          title: "P20",
          created_at: DateTime.add(base_time, 19000),
          section: "Page",
          priority: 50
        }
      ]

      WebRunTimeMetaDataState.save_batch(pages)

      # Get all 20 posts
      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "test.com",
          section: "Page",
          page: 1,
          limit: 20
        })

      assert length(result.data) == 20
      assert result.total == 20

      # Check that results are properly sorted
      ids = Enum.map(result.data, & &1.id)

      # Expected order: priority DESC (100->50), then created_at ASC within each priority
      expected_order = [
        # Priority 100 (sorted by created_at ASC)
        "p3",
        "p1",
        "p2",
        # Priority 90 (sorted by created_at ASC)
        "p7",
        "p5",
        "p4",
        "p6",
        # Priority 80 (sorted by created_at ASC)
        "p10",
        "p8",
        "p9",
        # Priority 70 (sorted by created_at ASC)
        "p11",
        "p12",
        "p13",
        # Priority 60 (sorted by created_at ASC)
        "p15",
        "p16",
        "p14",
        # Priority 50 (sorted by created_at ASC)
        "p18",
        "p19",
        "p17",
        "p20"
      ]

      assert ids == expected_order

      # Verify the actual priority and created_at values to ensure correct sorting
      priorities = Enum.map(result.data, & &1.priority)

      assert priorities == [
               100,
               100,
               100,
               90,
               90,
               90,
               90,
               80,
               80,
               80,
               70,
               70,
               70,
               60,
               60,
               60,
               50,
               50,
               50,
               50
             ]

      # Check that within same priority, items are sorted by created_at ASC
      priority_100_items = Enum.take(result.data, 3)
      assert Enum.map(priority_100_items, & &1.id) == ["p3", "p1", "p2"]

      # Verify timestamps are in ascending order for priority 100 group
      times = Enum.map(priority_100_items, & &1.created_at)
      assert times == Enum.sort(times, DateTime)
    end

    test "paginate with limit smaller than total shows correct order" do
      # Create posts with same priority but different created_at
      base_time = ~U[2024-01-01 00:00:00Z]

      pages =
        for i <- 1..10 do
          %{
            id: "same_priority_#{i}",
            site: "test.com",
            path: "/sp#{i}",
            title: "Same Priority #{i}",
            created_at: DateTime.add(base_time, i * 3600),
            section: "blog",
            # All same priority
            priority: 75
          }
        end

      WebRunTimeMetaDataState.save_batch(pages)

      # Get first 5
      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "test.com",
          section: "blog",
          page: 1,
          limit: 5
        })

      assert length(result.data) == 5

      # Should be sorted by created_at ASC since all have same priority
      ids = Enum.map(result.data, & &1.id)

      assert ids == [
               "same_priority_1",
               "same_priority_2",
               "same_priority_3",
               "same_priority_4",
               "same_priority_5"
             ]

      # Check page 2
      result_page2 =
        WebRunTimeMetaDataState.paginate(%{
          site: "test.com",
          section: "blog",
          page: 2,
          limit: 5
        })

      ids_page2 = Enum.map(result_page2.data, & &1.id)

      assert ids_page2 == [
               "same_priority_6",
               "same_priority_7",
               "same_priority_8",
               "same_priority_9",
               "same_priority_10"
             ]
    end
  end

  describe "concurrent save/1 for the same id (atomic mutation, #4)" do
    test "leaves exactly one sort-index row and no duplicate pagination" do
      base = %{id: "race", site: "race.com", path: "/race", title: "R", section: "Page"}

      1..50
      |> Enum.map(fn p ->
        Task.async(fn ->
          WebRunTimeMetaDataState.save(
            Map.merge(base, %{priority: p, created_at: DateTime.add(~U[2024-01-01 00:00:00Z], p)})
          )
        end)
      end)
      |> Task.await_many()

      assert WebRunTimeMetaDataState.count() == 1

      assert length(:ets.match_object(:mishka_web_run_time_meta_data_sort_index, {:_, "race"})) ==
               1

      result =
        WebRunTimeMetaDataState.paginate(%{
          site: "race.com",
          section: "Page",
          page: 1,
          limit: 100
        })

      assert Enum.map(result.data, & &1.id) == ["race"]
      assert result.total == 1
    end

    @tag malformed: %{id: "x"}
    test "a malformed map raises in the caller, never crashing the owner", %{malformed: malformed} do
      pid = GenServer.whereis(WebRunTimeMetaDataState)
      assert_raise(MatchError, fn -> WebRunTimeMetaDataState.save(malformed) end)
      assert Process.alive?(pid)
    end
  end
end
