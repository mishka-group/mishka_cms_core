# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.SettingsMultitenancyTest do
  @moduledoc """
  Real tests for tenant-aware settings: a `site_id = nil` row is GLOBAL (shared), a `site_id` row is a
  per-site override, and a site read resolves site value → global → default. Mirrors the `Layout`
  `global? true` model. The ETS cache is process-global, so each test refreshes it in `on_exit`.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  require Ash.Query

  setup do
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    site = create_site!(name: "acme", host: "acme.test")
    other = create_site!(name: "globex", host: "globex.test")
    {:ok, site: site, other: other}
  end

  test "a global write is shared; a site read falls back to the global", %{site: site} do
    {:ok, _} = Settings.put("site.title", "Global Title")

    assert Settings.get("site.title") == "Global Title"
    assert Settings.get("site.title", nil, site.id) == "Global Title"
  end

  test "a per-site write is isolated; other sites + the global are unaffected", %{
    site: site,
    other: other
  } do
    {:ok, _} = Settings.put("site.title", "Default")
    {:ok, _} = Settings.put("site.title", "Acme", site_id: site.id)

    assert Settings.get("site.title", nil, site.id) == "Acme"
    assert Settings.get("site.title", nil, other.id) == "Default"
    assert Settings.get("site.title") == "Default"
  end

  test "upsert keeps the global and per-site rows singular, and they coexist", %{site: site} do
    {:ok, _} = Settings.put("k", 1)
    {:ok, _} = Settings.put("k", 2)
    {:ok, _} = Settings.put("k", 10, site_id: site.id)
    {:ok, _} = Settings.put("k", 20, site_id: site.id)

    assert Settings.get("k") == 2
    assert Settings.get("k", nil, site.id) == 20

    rows =
      Setting |> Ash.Query.filter(key == "k") |> Ash.read!(action: :read_any, authorize?: false)

    assert length(rows) == 2
    assert Enum.count(rows, &is_nil(&1.site_id)) == 1
    assert Enum.count(rows, &(&1.site_id == site.id)) == 1
  end

  test "the tenant :set action auto-stamps site_id from the tenant", %{site: site} do
    {:ok, row} =
      Setting
      |> Ash.Changeset.for_create(:set, %{key: "x", value: %{"value" => 1}},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create()

    assert row.site_id == site.id
  end

  test "read_any sees every scope; a tenant read never sees another site's rows", %{
    site: site,
    other: other
  } do
    {:ok, _} = Settings.put("g", 0)
    {:ok, _} = Settings.put("g", 1, site_id: site.id)
    {:ok, _} = Settings.put("g", 2, site_id: other.id)

    all =
      Setting |> Ash.Query.filter(key == "g") |> Ash.read!(action: :read_any, authorize?: false)

    assert length(all) == 3

    tenant_rows =
      Setting |> Ash.Query.filter(key == "g") |> Ash.read!(tenant: site.id, authorize?: false)

    site_ids = Enum.map(tenant_rows, & &1.site_id)
    assert site.id in site_ids
    refute other.id in site_ids
  end
end
