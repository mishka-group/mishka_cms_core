# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ActivityUnionLive do
  @moduledoc """
  Test plugin for `activity:sources`: a union source whose one row a test writes with `write/1`,
  carrying a badge of its own.
  """
  use MishkaCmsCore.ProviderRegistry, event: "activity:sources", priority: 55

  @behaviour MishkaCmsCore.Activity.Behaviours.UnionSource

  alias MishkaCmsCore.Activity.Query

  @key {__MODULE__, :said}
  @resource "'Elixir.MishkaCmsCore.Runtime.Page'"

  @doc "Writes the source's one row, saying `said`; `nil` takes it away."
  @spec write(String.t() | nil) :: :ok
  def write(nil) do
    :persistent_term.erase(@key)
    :ok
  end

  def write(said), do: :persistent_term.put(@key, said)

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def id, do: "live_probe"

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def union_branch(%{site_id: site_id, severity: severity, shown: shown, first_param: n}) do
    sql = """
    (SELECT 'live_probe' AS source, #{@resource} AS resource, 'paid' AS action,
            NULL::text AS source_id, 'live-row' AS event_id, site_id::text AS site_id,
            NULL::text AS user_id, (now() AT TIME ZONE 'utc') AS inserted_at,
            jsonb_build_object('said', $#{n}::text) AS payload
       FROM (SELECT NULL::uuid AS site_id) live
      WHERE $#{n}::text IS NOT NULL#{Query.version_site_clause(site_id, true)}#{Query.content_severity_clause(severity, "'paid'")}#{Query.resource_clause(@resource)}#{Query.shown_clause(@resource, shown)}#{Query.search_clause(["$#{n}::text"])}
      LIMIT $1)\
    """

    {sql, [:persistent_term.get(@key, nil)]}
  end

  @impl MishkaCmsCore.Activity.Behaviours.UnionSource
  def entry_from_row(row) do
    %{
      id: "live-probe-#{row["event_id"]}",
      resource_label: "Live probe",
      badge_label: "MONEY",
      badge_tone: :emerald,
      action: :paid,
      severity: :info,
      tone: nil,
      inserted_at: MishkaCmsCore.Activity.Helpers.to_datetime(row["inserted_at"]),
      source_id: row["source_id"],
      site_id: row["site_id"],
      user_id: row["user_id"],
      message: row["payload"]["said"]
    }
  end
end
