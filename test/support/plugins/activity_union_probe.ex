# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ActivityUnionProbe do
  @moduledoc """
  Test plugin for `activity:sources`: a union source with no table of its own, whose branch is one
  shared row carrying a parameter of its own, so a test can see a plugin's rows reach the log
  through the core's filters and its own values arrive bound, not written into the SQL.
  """
  use MishkaCmsCore.ProviderRegistry, event: "activity:sources", priority: 50

  @behaviour MishkaCmsCore.Activity.Behaviours.UnionSource

  alias MishkaCmsCore.Activity.Query

  @said "said through a parameter"
  @resource "'Elixir.MishkaCmsCore.Runtime.Page'"

  @doc "What the probe's one row says."
  @spec said() :: String.t()
  def said, do: @said

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def id, do: "probe"

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def union_branch(%{site_id: site_id, severity: severity, shown: shown, first_param: n}) do
    sql = """
    (SELECT 'probe' AS source, #{@resource} AS resource, 'update' AS action,
            NULL::text AS source_id, 'probe-row' AS event_id, site_id::text AS site_id,
            NULL::text AS user_id, (now() AT TIME ZONE 'utc') AS inserted_at,
            jsonb_build_object('said', $#{n}::text) AS payload
       FROM (SELECT NULL::uuid AS site_id) probe
      WHERE TRUE#{Query.version_site_clause(site_id, true)}#{Query.content_severity_clause(severity, "'update'")}#{Query.resource_clause(@resource)}#{Query.shown_clause(@resource, shown)}#{Query.search_clause(["$#{n}::text"])}
      LIMIT $1)\
    """

    {sql, [@said]}
  end

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def entry_from_row(row) do
    %{
      id: "probe-#{row["event_id"]}",
      resource_label: "Probe",
      badge_label: "PROBE",
      badge_tone: nil,
      action: :update,
      severity: :info,
      tone: :updated,
      inserted_at: row["inserted_at"],
      source_id: row["source_id"],
      site_id: row["site_id"],
      user_id: row["user_id"],
      message: row["payload"]["said"]
    }
  end
end
