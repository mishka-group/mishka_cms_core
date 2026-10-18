# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.SiteStateAllowedOriginsTest do
  @moduledoc """
  The CORS origins each site allows, held in `SiteState` as `{scheme, host, port}` the way
  `MishkaCmsCore.Runtime.OriginValidator.site_origins/1` reads them, and asked for by
  `SiteState.allows_origin?/2` with the origin a request names.
  """
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.OriginValidator
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

  defp allows?(site_id, value) do
    {:ok, origin} = OriginValidator.request_origin(value)
    SiteState.allows_origin?(site_id, origin)
  end

  describe "a frontend domain" do
    test "that only starts with http is a domain, not an address" do
      assert :ok =
               SiteState.save(%{
                 id: "http_site",
                 name: "Http Site",
                 host: "http.example.com",
                 priority: 100,
                 active: true,
                 frontend_domain: "httpbin.example.com"
               })

      assert allows?("http_site", "https://httpbin.example.com")
      refute allows?("http_site", "http://httpbin.example.com")
    end

    test "that is a full address is indexed as it is written" do
      assert :ok =
               SiteState.save(%{
                 id: "full_site",
                 name: "Full Site",
                 host: "full.example.com",
                 priority: 100,
                 active: true,
                 frontend_domain: "https://app.example.com"
               })

      assert allows?("full_site", "https://app.example.com")
      refute allows?("full_site", "http://app.example.com")
    end

    test "that is a loopback domain allows http as well, on the port it writes" do
      :ok =
        SiteState.save(%{
          id: "dev_site",
          name: "Dev Site",
          host: "site-a.localhost",
          priority: 1,
          active: true,
          frontend_domain: "localhost:5173"
        })

      for origin <- [
            "https://site-a.localhost",
            "http://site-a.localhost",
            "https://localhost:5173",
            "http://localhost:5173"
          ] do
        assert allows?("dev_site", origin), origin
      end

      refute allows?("dev_site", "http://localhost:5174")
      refute allows?("dev_site", "http://site-a.localhost:4000")
    end
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
      assert allows?("default_site", "https://default.com")
    end
  end

  describe "allows_origin?/2" do
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

    test "answers for the site's own host, frontend domain and allowed origins" do
      for origin <- [
            "https://api1.com",
            "https://app1.com",
            "https://admin1.com",
            "https://partner1.com"
          ] do
        assert allows?("site_1", origin), origin
      end

      for origin <- ["https://api2.com", "https://app2.com", "https://admin2.com"] do
        assert allows?("site_2", origin), origin
      end
    end

    test "answers for the site asked about, not for another that allows the origin" do
      refute allows?("site_2", "https://admin1.com")
      refute allows?("site_1", "https://app2.com")
    end

    test "a bare frontend domain is https only, on its own port" do
      assert allows?("site_1", "https://app1.com")
      refute allows?("site_1", "http://app1.com")
      refute allows?("site_1", "https://app1.com:8443")
    end

    test "answers whether the site is active or not — the plug decides what to do with that" do
      assert allows?("site_3", "https://api3.com")
    end

    test "is false for an unknown origin, an unknown site and a site id of nil" do
      refute allows?("site_1", "https://unknown.com")
      refute allows?("no_such_site", "https://api1.com")
      refute allows?(nil, "https://api1.com")
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

      for origin <- ["https://app-a.com", "https://admin-a.com", "https://partner-a.com"] do
        assert allows?("site_a", origin), origin
      end

      refute allows?("site_a", "http://app-a.com")

      assert allows?("site_b", "https://app-b.com")
      assert allows?("site_b", "https://admin-b.com")

      refute allows?("site_c", "https://app-c.com")
    end

    test "a batch over a site already held replaces what it allows" do
      site = %{
        id: "site_r",
        name: "Site R",
        host: "api-r.com",
        priority: 1,
        active: true,
        allowed_origins: ["https://old-r.com"]
      }

      :ok = SiteState.save(site)
      :ok = SiteState.save_batch([%{site | allowed_origins: ["https://new-r.com"]}])

      refute allows?("site_r", "https://old-r.com")
      assert allows?("site_r", "https://new-r.com")
    end
  end

  describe "updating site with allowed_origins" do
    test "properly updates allowed_origins index when site is updated" do
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

      assert allows?("update_test", "https://old-app.test.com")
      assert allows?("update_test", "https://old-admin.test.com")

      attrs2 = %{
        attrs1
        | frontend_domain: "new-app.test.com",
          allowed_origins: ["https://new-admin.test.com", "https://new-partner.test.com"]
      }

      SiteState.save(attrs2)

      refute allows?("update_test", "https://old-app.test.com")
      refute allows?("update_test", "https://old-admin.test.com")

      for origin <- [
            "https://new-app.test.com",
            "https://new-admin.test.com",
            "https://new-partner.test.com"
          ] do
        assert allows?("update_test", origin), origin
      end
    end

    test "a new host takes the old one's origin with it" do
      attrs = %{id: "rehost", name: "Rehost", host: "old-host.com", priority: 1, active: true}

      :ok = SiteState.save(attrs)
      :ok = SiteState.save(%{attrs | host: "new-host.com"})

      refute allows?("rehost", "https://old-host.com")
      assert allows?("rehost", "https://new-host.com")
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

      assert allows?("clear_test", "https://app.clear.com")
      assert allows?("clear_test", "https://admin.clear.com")

      SiteState.save(%{attrs1 | mode: "phoenix_only", frontend_domain: nil, allowed_origins: []})

      refute allows?("clear_test", "https://app.clear.com")
      refute allows?("clear_test", "https://admin.clear.com")
      assert allows?("clear_test", "https://api.clear.com")
    end

    test "set_master/1 and unset_master/0 keep what the site allows" do
      :ok =
        SiteState.save(%{
          id: "master_test",
          name: "Master Test",
          host: "master.test.com",
          priority: 1,
          active: true,
          allowed_origins: ["https://partner.test.com"]
        })

      {:ok, _site} = SiteState.set_master("master_test")
      assert allows?("master_test", "https://partner.test.com")

      {:ok, _site} = SiteState.unset_master()
      assert allows?("master_test", "https://partner.test.com")
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

      assert allows?("delete_test", "https://app.delete.com")
      assert allows?("delete_test", "https://admin.delete.com")

      SiteState.delete("delete_test")

      for origin <- [
            "https://api.delete.com",
            "https://app.delete.com",
            "https://admin.delete.com"
          ] do
        refute allows?("delete_test", origin), origin
      end

      assert :ets.lookup(:mishka_sites_allowed_origins_index, "delete_test") == []
    end

    test "clear/0 drops every site's origins" do
      :ok =
        SiteState.save(%{
          id: "clear_all",
          name: "Clear All",
          host: "all.com",
          priority: 1,
          active: true
        })

      SiteState.clear()

      refute allows?("clear_all", "https://all.com")
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

      for site_id <- ["site_1", "site_2"],
          origin <- ["https://shared-app.com", "https://shared-admin.com"] do
        assert allows?(site_id, origin), "#{site_id} #{origin}"
      end

      SiteState.delete("site_1")

      refute allows?("site_1", "https://shared-admin.com")
      assert allows?("site_2", "https://shared-admin.com")
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

      assert allows?("empty_test", "https://valid.com")

      assert :ets.lookup(:mishka_sites_allowed_origins_index, "empty_test") == [
               {"empty_test",
                MapSet.new([{"https", "empty.com", 443}, {"https", "valid.com", 443}])}
             ]
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
      assert allows?("nil_test", "https://admin.nil.com")
    end
  end

  describe "performance with allowed_origins" do
    @tag :performance
    test "handles large number of allowed_origins efficiently" do
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

      {save_time, :ok} = :timer.tc(fn -> SiteState.save(attrs) end)
      assert save_time < 10_000

      {:ok, origin} = OriginValidator.request_origin("https://origin50.com")
      {lookup_time, true} = :timer.tc(fn -> SiteState.allows_origin?("many_origins", origin) end)
      assert lookup_time < 1000

      for i <- [1, 100], do: assert(allows?("many_origins", "https://origin#{i}.com"))
      refute allows?("many_origins", "https://origin101.com")
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
      assert time < 50_000

      assert allows?("site_50", "https://app50.com")
      assert allows?("site_75", "https://admin75.com")
      refute allows?("site_75", "https://admin76.com")
    end
  end
end
