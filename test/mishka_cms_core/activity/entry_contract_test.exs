# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.EntryContractTest do
  @moduledoc """
  The activity feed's entry shape, held to by every source.

  Sources are pluggable and each writes its own map literal, so nothing stops a new one from
  omitting a key a renderer reads — and two renderers read entries as PLAIN MAPS
  (`MishkaCmsCore.Dashboard.Widgets.RecentActivity` and the `ActivityFeed` component), where a
  missing key is a `KeyError` in the LiveView process, not a blank cell. That is how a seeded editor
  row once took `/admin/dashboard` into a reconnect loop.

  Two things stand between a forgotten key and a dead page, and this file holds both:

    * `MishkaCmsCore.Activity.Helpers.complete_entry/1` — the runtime seam, on every path an entry
      takes into the system, so an omission degrades to a grey badge instead of a crash;
    * these tests — so an omission is a red build, and the seam never has to be the thing that saves
      anybody.

  The sources are asserted on their RAW output, deliberately: were each source built through
  `complete_entry/1` the assertion could never fail, and the contract would be enforced by nothing.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Behaviours.UnionSource
  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.Activity.Sources

  # One row in the shape `MishkaCmsCore.Activity.Query`'s UNION hands `dispatch/1`: string keys, and
  # every column any branch selects. Each source reads the subset it knows.
  @row %{
    "source" => "version",
    "source_id" => "11111111-1111-1111-1111-111111111111",
    "event_id" => "22222222-2222-2222-2222-222222222222",
    "resource" => "MishkaCmsCore.Runtime.Page",
    "action" => "update",
    "inserted_at" => ~U[2026-01-01 09:00:00.000000Z],
    "site_id" => "33333333-3333-3333-3333-333333333333",
    "user_id" => "44444444-4444-4444-4444-444444444444",
    "payload" => %{"name" => "Home", "label" => "Edited text", "target" => "<h1>"}
  }

  # Every core source `MishkaCmsCore.Activity.Query.dispatch/2` routes a merged row to. Adding a
  # branch there without adding it here is the one gap this file cannot close on its own. A union
  # source an extension registers on `activity:sources` is asked below, whichever are installed.
  @db_sources [
    Sources.PaperTrail,
    Sources.EventLog,
    Sources.Oban,
    Sources.RuntimeDraft
  ]

  defp missing_message(source, missing) do
    """
    #{inspect(source)} built an entry without #{inspect(missing)}.

    Two renderers dot-access an activity entry as a plain map — the dashboard's Recent
    activity widget and the ActivityFeed component — so a missing key raises a KeyError
    in the LiveView process and the page reconnects into the same crash.

    Add the key to the map in entry_from_row/1. A tone you have no value for is `nil`,
    which every badge/dot helper already draws.
    """
  end

  describe "every source fills the whole entry shape" do
    for source <- @db_sources do
      test "#{inspect(source)}.entry_from_row/1 omits no key" do
        entry = unquote(source).entry_from_row(@row)
        missing = Helpers.entry_keys() -- Map.keys(entry)

        assert missing == [], missing_message(unquote(source), missing)
      end
    end

    test "and so does every union source installed" do
      for source <- UnionSource.all() do
        entry = source.entry_from_row(Map.put(@row, "source", source.id()))
        missing = Helpers.entry_keys() -- Map.keys(entry)

        assert missing == [], missing_message(source, missing)
      end
    end
  end

  describe "complete_entry/1, the runtime seam" do
    test "fills a key a source forgot, so dot-access cannot raise" do
      entry = Helpers.complete_entry(%{id: "x-1", message: "hi"})

      assert Helpers.entry_keys() -- Map.keys(entry) == []
      assert entry.badge_tone == nil
      assert entry.tone == nil
    end

    test "never overwrites what the source did set, and keeps its extra keys" do
      entry = Helpers.complete_entry(%{badge_tone: :emerald, severity: :error, host: "a-site"})

      assert entry.badge_tone == :emerald
      assert entry.severity == :error
      assert entry.host == "a-site"
    end

    test "does not invent a timestamp for a row that has none" do
      # `utc_now()` here would sort a broken row to the TOP of every feed and give it a day heading,
      # pushing real entries out of the window — worse than a row that does not draw.
      assert Helpers.complete_entry(%{id: "x-1"}).inserted_at == nil
    end

    test "passes nil through — the live path's 'no source claimed this broadcast'" do
      assert Helpers.complete_entry(nil) == nil
    end
  end
end
