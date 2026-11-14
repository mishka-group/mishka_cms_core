# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.MissingTableTest do
  @moduledoc """
  A source whose table is not in the database, such as an extension installed before its
  migrations ran, is left out of the activity log, so the other sources still show.

  The test renames `MishkaCmsCore.Runtime.Component`'s version table inside its own sandbox
  transaction, which rolls the rename back, and scans the domains again. It runs on its own
  (`async: false`), so no other test reads the discovery sets it leaves for that while.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.{Discovery, Query}
  alias MishkaCmsCore.Runtime.{Component, PageDraft}

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  setup do
    on_exit(&Discovery.invalidate/0)
    :ok
  end

  test "the activity log leaves out a source with no table, says so once, and shows the others" do
    site = create_site!()

    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Kept", title: "Kept", path: "/kept", template: "<h1>k</h1>"},
      tenant: site.id
    )
    |> Ash.create!(authorize?: false)

    table =
      Component
      |> AshPaperTrail.Resource.Info.version_resource()
      |> AshPostgres.DataLayer.Info.table()

    Ecto.Adapters.SQL.query!(@repo, "ALTER TABLE #{table} RENAME TO #{table}_gone", [])
    Discovery.invalidate()

    logged =
      capture_log(fn ->
        refute Component in Discovery.paper_trailed()
        refute Component in Discovery.paper_trailed()

        assert %{site_id: site.id, limit: 50}
               |> Query.page()
               |> Enum.any?(&(&1.badge_label == "DRAFT"))
      end)

    assert length(String.split(logged, "[Activity.Discovery]")) == 2
    assert logged =~ table
    refute logged =~ "[Activity.Query]"
  end

  test "a source whose table is there stays in" do
    Discovery.invalidate()
    assert Component in Discovery.paper_trailed()
  end
end
