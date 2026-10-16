# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.EventLogTest do
  @moduledoc """
  The EventLog source maps AshEvents central-log rows to the unified entry shape
  and filters both the initial fetch and live broadcasts by `scope.resources`.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Sources.EventLog

  defp broadcast(row) do
    %Phoenix.Socket.Broadcast{
      topic: "event_log:created",
      event: "create",
      payload: %Ash.Notifier.Notification{resource: MishkaDocument.EventLog, data: row}
    }
  end

  test "to_entry maps an event row to the unified entry shape" do
    row = %{
      id: "ev1",
      resource: MishkaDocument.Workspace,
      action_type: :create,
      record_id: "rec-1",
      occurred_at: ~U[2026-05-31 00:00:00Z],
      actor_id: "user-1",
      metadata: %{"site_id" => "site-1"},
      data: %{"title" => "Q1 Plan"}
    }

    entry = EventLog.to_entry(broadcast(row))

    assert entry.id == "event-ev1"
    assert entry.resource_label == "Workspace"
    assert entry.action == :create
    assert entry.severity == :info
    assert entry.badge_label == "CREATE"
    assert entry.site_id == "site-1"
    assert entry.user_id == "user-1"
    assert entry.source_id == "rec-1"
    assert entry.message =~ "Q1 Plan"
    assert entry.message =~ "created"
  end

  test "resource stored as a string still humanizes; site_id falls back to data" do
    row = %{
      id: "ev2",
      resource: "MishkaDocument.WorkspaceVersion",
      action_type: :update,
      occurred_at: ~U[2026-05-31 00:00:00Z],
      data: %{"site_id" => "site-2"},
      metadata: %{}
    }

    entry = EventLog.to_entry(broadcast(row))
    assert entry.resource_label == "Workspace Version"
    assert entry.action == :update
    assert entry.site_id == "site-2"
  end

  test "a scope of non-AshEvents resources matches no event-log rows" do
    assert EventLog.initial_fetch(
             %{current_user: %{site_id: nil}, resources: [MishkaCmsCore.Runtime.Component]},
             5
           ) == []
  end

  test "no viewer, or one with no site on record, subscribes to nothing" do
    assert EventLog.topics(%{}) == []
    assert EventLog.topics(%{current_user: %{}}) == []
    assert EventLog.topics(%{current_user: %{site_id: nil}}) == ["event_log:created"]
  end

  test "in_scope? keeps a broadcast whose resource is in the scope" do
    msg = broadcast(%{id: "x", resource: MishkaDocument.Workspace})
    assert EventLog.in_scope?(msg, %{resources: [MishkaDocument.Workspace, MishkaDocument.Issue]})
  end

  test "in_scope? drops a broadcast whose resource is outside the scope" do
    msg = broadcast(%{id: "x", resource: MishkaDocument.Workspace})
    refute EventLog.in_scope?(msg, %{resources: [MishkaDocument.Issue]})
  end

  test "in_scope? keeps everything for an unscoped feed" do
    msg = broadcast(%{id: "x", resource: MishkaDocument.Workspace})
    assert EventLog.in_scope?(msg, %{resources: nil})
    assert EventLog.in_scope?(msg, %{})
  end
end
