defmodule MishkaCmsCore.Runtime.States.SiteStateAllowedOriginsTest do
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

  describe "allowed_origins indexing" do
    test "saves site with mode, frontend_domain, and allowed_origins" do
      attrs = %{
        id: "api_site",
        name: "API Site",
        host: "api.example.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "app.example.com",
        allowed_origins: ["https://admin.example.com", "https://partner.example.com"]
      }

      assert :ok = SiteState.save(attrs)
      assert {:ok, site} = SiteState.get("api_site")
      assert site.mode == :api_only
      assert site.frontend_domain == "app.example.com"
      assert site.allowed_origins == ["https://admin.example.com", "https://partner.example.com"]
    end

    test "defaults mode to hybrid and allowed_origins to empty list" do
      attrs = %{
        id: "default_site",
        name: "Default Site",
        host: "default.com",
        priority: 50,
        active: true
      }

      assert :ok = SiteState.save(attrs)
      assert {:ok, site} = SiteState.get("default_site")
      assert site.mode == :hybrid
      assert site.frontend_domain == nil
      assert site.allowed_origins == []
    end
  end

  describe "get_by_allowed_origin/1" do
    setup do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "api1.com",
          priority: 100,
          active: true,
          mode: "api_only",
          frontend_domain: "app1.com",
          allowed_origins: ["https://admin1.com", "https://partner1.com"]
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "api2.com",
          priority: 90,
          active: true,
          mode: "hybrid",
          frontend_domain: "https://app2.com",
          allowed_origins: ["https://admin2.com"]
        },
        %{
          id: "site_3",
          name: "Site 3",
          host: "api3.com",
          priority: 80,
          active: false,
          mode: "phoenix_only",
          frontend_domain: nil,
          allowed_origins: []
        }
      ]

      SiteState.save_batch(sites)
      :ok
    end

    test "finds site by allowed origin" do
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://admin1.com")
      assert site.id == "site_1"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://partner1.com")
      assert site.id == "site_1"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://admin2.com")
      assert site.id == "site_2"
    end

    test "finds site by frontend_domain when it's a full origin" do
      # site_2 has frontend_domain as full origin
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://app2.com")
      assert site.id == "site_2"
    end

    test "finds site by frontend_domain when it's just a domain" do
      # site_1 has frontend_domain as just domain, should match both http and https
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://app1.com")
      assert site.id == "site_1"

      assert {:ok, site} = SiteState.get_by_allowed_origin("http://app1.com")
      assert site.id == "site_1"
    end

    test "returns not found for unknown origin" do
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://unknown.com")
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("http://notallowed.com")
    end
  end

  describe "is_allowed_origin?/1" do
    setup do
      sites = [
        %{
          id: "active_site",
          name: "Active Site",
          host: "api.active.com",
          priority: 100,
          active: true,
          mode: "api_only",
          frontend_domain: "app.active.com",
          allowed_origins: ["https://admin.active.com"]
        },
        %{
          id: "inactive_site",
          name: "Inactive Site",
          host: "api.inactive.com",
          priority: 90,
          active: false,
          mode: "api_only",
          frontend_domain: "app.inactive.com",
          allowed_origins: ["https://admin.inactive.com"]
        }
      ]

      SiteState.save_batch(sites)
      :ok
    end

    test "returns {true, site} for allowed origin of active site" do
      assert {true, site} = SiteState.is_allowed_origin?("https://admin.active.com")
      assert site.id == "active_site"

      # Frontend domain also works
      assert {true, site} = SiteState.is_allowed_origin?("https://app.active.com")
      assert site.id == "active_site"
    end

    test "returns false for allowed origin of inactive site" do
      assert false == SiteState.is_allowed_origin?("https://admin.inactive.com")
      assert false == SiteState.is_allowed_origin?("https://app.inactive.com")
    end

    test "returns false for unknown origin" do
      assert false == SiteState.is_allowed_origin?("https://unknown.com")
    end
  end

  describe "batch save with allowed_origins" do
    test "correctly indexes all allowed_origins and frontend_domains in batch" do
      sites = [
        %{
          id: "site_a",
          name: "Site A",
          host: "api-a.com",
          priority: 100,
          active: true,
          mode: "api_only",
          # Just domain
          frontend_domain: "app-a.com",
          allowed_origins: ["https://admin-a.com", "https://partner-a.com"]
        },
        %{
          id: "site_b",
          name: "Site B",
          host: "api-b.com",
          priority: 90,
          active: true,
          mode: "hybrid",
          # Full origin
          frontend_domain: "https://app-b.com",
          allowed_origins: ["https://admin-b.com"]
        },
        %{
          id: "site_c",
          name: "Site C",
          host: "api-c.com",
          priority: 80,
          active: true,
          mode: "phoenix_only",
          frontend_domain: nil,
          allowed_origins: []
        }
      ]

      SiteState.save_batch(sites)

      # Check site_a origins
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://app-a.com")
      assert site.id == "site_a"

      assert {:ok, site} = SiteState.get_by_allowed_origin("http://app-a.com")
      assert site.id == "site_a"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://admin-a.com")
      assert site.id == "site_a"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://partner-a.com")
      assert site.id == "site_a"

      # Check site_b origins
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://app-b.com")
      assert site.id == "site_b"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://admin-b.com")
      assert site.id == "site_b"

      # Site_c has no allowed origins
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://app-c.com")
    end
  end

  describe "updating site with allowed_origins" do
    test "properly updates allowed_origins index when site is updated" do
      # Initial save
      attrs1 = %{
        id: "update_test",
        name: "Update Test",
        host: "api.test.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "old-app.test.com",
        allowed_origins: ["https://old-admin.test.com"]
      }

      SiteState.save(attrs1)

      # Verify initial origins work
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://old-app.test.com")
      assert site.id == "update_test"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://old-admin.test.com")
      assert site.id == "update_test"

      # Update with new origins
      attrs2 = %{
        id: "update_test",
        name: "Update Test",
        host: "api.test.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "new-app.test.com",
        allowed_origins: ["https://new-admin.test.com", "https://new-partner.test.com"]
      }

      SiteState.save(attrs2)

      # Old origins should not work
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://old-app.test.com")
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://old-admin.test.com")

      # New origins should work
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://new-app.test.com")
      assert site.id == "update_test"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://new-admin.test.com")
      assert site.id == "update_test"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://new-partner.test.com")
      assert site.id == "update_test"
    end

    test "handles clearing allowed_origins" do
      attrs1 = %{
        id: "clear_test",
        name: "Clear Test",
        host: "api.clear.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "app.clear.com",
        allowed_origins: ["https://admin.clear.com"]
      }

      SiteState.save(attrs1)

      # Verify origins work
      assert {:ok, _} = SiteState.get_by_allowed_origin("https://app.clear.com")
      assert {:ok, _} = SiteState.get_by_allowed_origin("https://admin.clear.com")

      # Update with no origins
      attrs2 = %{
        id: "clear_test",
        name: "Clear Test",
        host: "api.clear.com",
        priority: 100,
        active: true,
        mode: "phoenix_only",
        frontend_domain: nil,
        allowed_origins: []
      }

      SiteState.save(attrs2)

      # Origins should not work anymore
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://app.clear.com")
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://admin.clear.com")
    end
  end

  describe "delete with allowed_origins" do
    test "removes allowed_origins index entries when site is deleted" do
      attrs = %{
        id: "delete_test",
        name: "Delete Test",
        host: "api.delete.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "app.delete.com",
        allowed_origins: ["https://admin.delete.com"]
      }

      SiteState.save(attrs)

      # Verify origins work
      assert {:ok, _} = SiteState.get_by_allowed_origin("https://app.delete.com")
      assert {:ok, _} = SiteState.get_by_allowed_origin("https://admin.delete.com")

      # Delete the site
      SiteState.delete("delete_test")

      # Origins should not work anymore
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://app.delete.com")
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("https://admin.delete.com")
    end
  end

  # The cache holds ONE shape. `MishkaCmsCore.Runtime.Site` types `mode` as an atom, so a caller
  # handing over the string a form or an older seed produced gets it normalised on the way in rather
  # than leaving two shapes for every reader to guess between — which is what made
  # `site.mode == "phoenix_only"` in three plugs silently never true.
  describe "mode field behavior" do
    test "a string is normalised to the atom the resource uses" do
      sites = [
        %{
          id: "api_only",
          name: "API Only",
          host: "api-only.com",
          priority: 100,
          active: true,
          mode: "api_only"
        },
        %{
          id: "phoenix_only",
          name: "Phoenix Only",
          host: "phoenix-only.com",
          priority: 90,
          active: true,
          mode: "phoenix_only"
        },
        %{
          id: "hybrid",
          name: "Hybrid",
          host: "hybrid.com",
          priority: 80,
          active: true,
          mode: "hybrid"
        }
      ]

      SiteState.save_batch(sites)

      assert {:ok, site} = SiteState.get("api_only")
      assert site.mode == :api_only

      assert {:ok, site} = SiteState.get("phoenix_only")
      assert site.mode == :phoenix_only

      assert {:ok, site} = SiteState.get("hybrid")
      assert site.mode == :hybrid
    end

    # Atoms are never freed, so a mode that is merely stored must never become one. Asserted on the
    # string itself rather than on the VM's atom count, which every other test moves.
    test "an unknown mode is the default, and coins no atom for what was asked for" do
      asked = "not_a_mode_#{System.unique_integer([:positive])}"

      :ok =
        SiteState.save(%{
          id: "odd",
          name: "Odd",
          host: "odd.example.com",
          priority: 1,
          active: true,
          mode: asked
        })

      assert {:ok, site} = SiteState.get("odd")
      assert site.mode == :hybrid
      assert_raise ArgumentError, fn -> String.to_existing_atom(asked) end
    end

    test "an absent mode is the default too" do
      :ok =
        SiteState.save(%{
          id: "bare",
          name: "Bare",
          host: "bare.example.com",
          priority: 1,
          active: true
        })

      assert {:ok, site} = SiteState.get("bare")
      assert site.mode == :hybrid
    end
  end

  describe "complex scenarios" do
    test "multiple sites can share the same allowed origin" do
      sites = [
        %{
          id: "site_1",
          name: "Site 1",
          host: "api1.shared.com",
          priority: 100,
          active: true,
          mode: "api_only",
          frontend_domain: "shared-app.com",
          allowed_origins: ["https://shared-admin.com"]
        },
        %{
          id: "site_2",
          name: "Site 2",
          host: "api2.shared.com",
          priority: 90,
          active: true,
          mode: "api_only",
          frontend_domain: "shared-app.com",
          allowed_origins: ["https://shared-admin.com"]
        }
      ]

      SiteState.save_batch(sites)

      # Both sites allow the same origin
      # get_by_allowed_origin will return one of them (first found)
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://shared-app.com")
      assert site.id in ["site_1", "site_2"]

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://shared-admin.com")
      assert site.id in ["site_1", "site_2"]
    end

    test "handles empty strings in frontend_domain and allowed_origins" do
      attrs = %{
        id: "empty_test",
        name: "Empty Test",
        host: "empty.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "",
        allowed_origins: ["", "https://valid.com", ""]
      }

      SiteState.save(attrs)

      # Empty strings should be ignored
      assert {:error, :not_found} = SiteState.get_by_allowed_origin("")

      # Valid origin should work
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://valid.com")
      assert site.id == "empty_test"
    end

    test "handles nil frontend_domain" do
      attrs = %{
        id: "nil_test",
        name: "Nil Test",
        host: "nil.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: nil,
        allowed_origins: ["https://admin.nil.com"]
      }

      SiteState.save(attrs)

      assert {:ok, site} = SiteState.get("nil_test")
      assert site.frontend_domain == nil

      # Allowed origins still work
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://admin.nil.com")
      assert site.id == "nil_test"
    end
  end

  describe "performance with allowed_origins" do
    @tag :performance
    test "handles large number of allowed_origins efficiently" do
      # Create site with many allowed origins
      allowed_origins = for i <- 1..100, do: "https://origin#{i}.com"

      attrs = %{
        id: "many_origins",
        name: "Many Origins",
        host: "api.many.com",
        priority: 100,
        active: true,
        mode: "api_only",
        frontend_domain: "app.many.com",
        allowed_origins: allowed_origins
      }

      # Measure save time
      {save_time, :ok} = :timer.tc(fn -> SiteState.save(attrs) end)
      # Should be fast even with 100 origins
      assert save_time < 10_000

      # Measure lookup time
      {lookup_time, {:ok, site}} =
        :timer.tc(fn -> SiteState.get_by_allowed_origin("https://origin50.com") end)

      assert site.id == "many_origins"
      # Lookup should be O(1) - very fast
      assert lookup_time < 1000
    end

    @tag :performance
    test "batch save with many sites having allowed_origins" do
      sites =
        for i <- 1..100 do
          %{
            id: "site_#{i}",
            name: "Site #{i}",
            host: "api#{i}.com",
            priority: i,
            active: true,
            mode: "api_only",
            frontend_domain: "app#{i}.com",
            allowed_origins: ["https://admin#{i}.com", "https://partner#{i}.com"]
          }
        end

      {time, :ok} = :timer.tc(fn -> SiteState.save_batch(sites) end)
      # Should handle 100 sites with origins quickly
      assert time < 50_000

      # Verify indexing worked
      assert {:ok, site} = SiteState.get_by_allowed_origin("https://app50.com")
      assert site.id == "site_50"

      assert {:ok, site} = SiteState.get_by_allowed_origin("https://admin75.com")
      assert site.id == "site_75"
    end
  end
end
