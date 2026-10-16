# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.DiscoveryTest do
  @moduledoc """
  Discovery scans every configured domain at runtime, so the activity log adapts
  to whatever extensions are installed — no hardcoded resource/extension names.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Activity.Discovery

  test "paper_trailed/0 includes the core Runtime resources" do
    pt = Discovery.paper_trailed()
    assert MishkaCmsCore.Runtime.Component in pt
    assert MishkaCmsCore.Runtime.Page in pt
  end

  test "every discovered resource's version exposes :sorted_versions (the guard holds)" do
    for resource <- Discovery.paper_trailed() do
      version = AshPaperTrail.Resource.Info.version_resource(resource)
      actions = version |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)
      assert :sorted_versions in actions, "#{inspect(resource)} version lacks :sorted_versions"
    end
  end

  # This library ships no event log of its own, so naming one here could only name an extension's —
  # and standalone there are none, which made the previous `Code.ensure_loaded?` branches assert
  # nothing at all. What holds everywhere is the scan's contract; each extension asserts that ITS log
  # is found (see `MishkaDocument.ActivityDiscoveryTest`).
  test "event_logs/0 returns only AshEvents.EventLog resources" do
    for resource <- Discovery.event_logs() do
      assert AshEvents.EventLog in Spark.extensions(resource),
             "#{inspect(resource)} was discovered but is not an AshEvents.EventLog"
    end
  end

  test "invalidate/0 clears the memoized sets; recompute is stable" do
    before = Discovery.paper_trailed()
    assert :ok = Discovery.invalidate()
    assert Enum.sort(Discovery.paper_trailed()) == Enum.sort(before)
  end
end
