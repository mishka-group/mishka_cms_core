# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.EventLog do
  @moduledoc """
  Activity source backed by `AshEvents.EventLog` resources (a centralized,
  durable event log per extension, e.g. `MishkaDocument.EventLog`). Auto-discovers
  every event-log resource across all configured domains via
  `MishkaCmsCore.Activity.Discovery.event_logs/0` — no per-extension wiring.

  Each event row normalizes to the shared entry shape: the `:resource` column
  becomes the label, `:action_type` drives the badge/severity/icon, `:occurred_at`
  the timestamp, `:record_id` the source id, `:actor_id` the user, and the
  `site_id` is read from the row's `metadata`/`data` for tenant scoping.

  Read uses the universal `:read` action rather than a log's own named reads
  (such as `MishkaDocument.EventLog`'s `:tenant_read`), so heterogeneous logs
  work. A resource-scoped feed (`scope.resources`) filters rows by the
  `:resource` column — so an
  AshEvents-tracked resource (e.g. `MishkaDocument.Workspace`) appears in a feed
  scoped to it, while a feed scoped to a non-AshEvents resource (the runtime
  resources, which use PaperTrail) simply matches nothing. `in_scope?/2` applies
  the same `:resource` filter to live broadcasts (the topic is global).

  See `MishkaCmsCore.Activity.Behaviours.Source` for the behaviour contract.
  """

  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaCmsCore.Activity.{Discovery, Helpers}

  @impl true
  def topics(scope) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      _reach -> ["event_log:created"]
    end
  end

  @impl true
  def handles?(%Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{resource: resource}
      }),
      do: resource in Discovery.event_logs()

  def handles?(_), do: false

  @impl true
  def to_entry(%Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{data: row}}),
    do: entry_from_record(row)

  def to_entry(_), do: nil

  @impl true
  def in_scope?(%Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{data: row}}, scope),
    do: resource_in_scope?(row, scope)

  def in_scope?(_, _), do: true

  @impl true
  def initial_fetch(scope, limit) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      reach -> fetch(site_of(reach), scope_resources(scope), limit)
    end
  end

  defp fetch(site_id, resources, limit) do
    logs = Discovery.event_logs()

    logs
    |> Task.async_stream(
      fn log -> fetch_events(log, site_id, resources, limit) end,
      max_concurrency: max(length(logs), 1),
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, rows} -> Enum.map(rows, &entry_from_record/1)
      _ -> []
    end)
  end

  defp scope_resources(%{resources: list}) when is_list(list) and list != [], do: list
  defp scope_resources(_), do: nil

  defp resource_in_scope?(row, %{resources: list}) when is_list(list) and list != [],
    do: Map.get(row, :resource) in list

  defp resource_in_scope?(_row, _scope), do: true

  defp site_of({:site, site_id}), do: site_id
  defp site_of(:everything), do: nil

  defp fetch_events(log, site_id, resources, limit) do
    log
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(occurred_at: :desc)
    |> maybe_filter_resources(resources)
    |> Ash.Query.limit(limit)
    |> maybe_filter_site(site_id)
    |> Ash.read(authorize?: false, page: false)
    |> case do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  defp maybe_filter_resources(query, nil), do: query

  defp maybe_filter_resources(query, resources),
    do: Ash.Query.filter(query, resource in ^resources)

  defp maybe_filter_site(query, nil), do: query

  defp maybe_filter_site(query, site_id) do
    Ash.Query.filter(
      query,
      fragment("(?->>'site_id') = ?", metadata, ^site_id) or
        fragment("(?->>'site_id') = ?", data, ^site_id)
    )
  end

  @doc """
  Build an entry map from a unified `MishkaCmsCore.Activity.Query` SQL row (the
  DB-side merge path), reusing the same label/severity/badge/message derivation
  as the live and in-memory paths.
  """
  def entry_from_row(row) do
    action = Helpers.action_atom(row["action"])
    label = resource_label(row["resource"])
    at = Helpers.to_datetime(row["inserted_at"])
    {badge_label, badge_tone} = Helpers.paper_trail_badge(action)

    %{
      id: "event-#{row["event_id"]}",
      resource_label: label,
      action: action,
      severity: Helpers.severity_for(action),
      tone: Helpers.tone_for(action),
      badge_label: badge_label,
      badge_tone: badge_tone,
      inserted_at: at,
      source_id: row["source_id"],
      site_id: row["site_id"],
      user_id: row["user_id"],
      message: message_for(label, action, row["payload"])
    }
  end

  @doc """
  Build an entry map from an event-log RECORD (or any map carrying its fields) — the live-broadcast
  and in-memory paths, and the document event log's own table, which draws the same rows through the
  same timeline and so has to phrase them the same way.

  Reads `:id`, `:record_id`, `:occurred_at`, `:actor_id`, `:resource`, `:action_type`, `:metadata`
  and `:data`; a caller handing it a plain map has to carry those.
  """
  def entry_from_record(row) do
    action = action_type(row)
    label = resource_label(Map.get(row, :resource))
    {badge_label, badge_tone} = Helpers.paper_trail_badge(action)

    %{
      id: "event-#{Map.get(row, :id)}",
      resource_label: label,
      action: action,
      severity: Helpers.severity_for(action),
      tone: Helpers.tone_for(action),
      badge_label: badge_label,
      badge_tone: badge_tone,
      inserted_at: Map.get(row, :occurred_at),
      source_id: stringify(Map.get(row, :record_id)),
      site_id: site_id_of(row),
      user_id: stringify(Map.get(row, :actor_id)),
      message: message_for(label, action, payload_of(row))
    }
  end

  # A row's title sits in whichever column the writer had: `metadata` is where a log keeping minimal
  # context puts it, `data` where the action's own params land. Both are read, `data` winning — the
  # same merge `MishkaCmsCore.Activity.Query` does in SQL, so a row reads the same live as it does
  # once it comes back from the database.
  defp payload_of(row),
    do: Map.merge(json_map(Map.get(row, :metadata)), json_map(Map.get(row, :data)))

  defp json_map(map) when is_map(map) and not is_struct(map), do: map
  defp json_map(_map), do: %{}

  defp action_type(%{action_type: type}) when is_atom(type) and not is_nil(type), do: type

  # Route DB-sourced strings through action_atom (maps known actions, unknown → :other)
  # so an attacker-influenced action_type can never create an unbounded atom.
  defp action_type(%{action_type: type}) when is_binary(type), do: Helpers.action_atom(type)

  defp action_type(_), do: :update

  defp resource_label(module) when is_atom(module) and not is_nil(module),
    do: Helpers.humanize_module(module)

  defp resource_label(string) when is_binary(string) do
    string
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/([A-Z])/, " \\1")
    |> String.trim()
    |> Helpers.translate()
  end

  defp resource_label(_), do: gettext("Record")

  defp site_id_of(row) do
    from_json(Map.get(row, :metadata), "site_id") || from_json(Map.get(row, :data), "site_id")
  end

  defp from_json(%{} = map, key), do: map[key]
  defp from_json(_, _), do: nil

  defp message_for(label, action, data) do
    case record_title(data) do
      name when name in [nil, ""] -> unnamed_message(label, action)
      name -> named_message(label, name, action)
    end
  end

  defp record_title(%{} = data),
    do: data["title"] || data["name"] || data[:title] || data[:name]

  defp record_title(_), do: nil

  defp unnamed_message(label, action) when action in [:create, :master_create],
    do: gettext("%{label} created", label: label)

  defp unnamed_message(label, action) when action in [:update, :master_update],
    do: gettext("%{label} updated", label: label)

  defp unnamed_message(label, action) when action in [:destroy, :master_destroy],
    do: gettext("%{label} archived", label: label)

  defp unnamed_message(label, action)
       when action in [:permanent_destroy, :master_permanent_destroy],
       do: gettext("%{label} permanently deleted", label: label)

  defp unnamed_message(label, action) when action in [:unarchive, :master_unarchive],
    do: gettext("%{label} restored", label: label)

  defp unnamed_message(label, action),
    do: gettext("%{label} %{action}", label: label, action: action)

  defp named_message(label, name, action) when action in [:create, :master_create],
    do: gettext("%{label} \"%{name}\" created", label: label, name: name)

  defp named_message(label, name, action) when action in [:update, :master_update],
    do: gettext("%{label} \"%{name}\" updated", label: label, name: name)

  defp named_message(label, name, action) when action in [:destroy, :master_destroy],
    do: gettext("%{label} \"%{name}\" archived", label: label, name: name)

  defp named_message(label, name, action)
       when action in [:permanent_destroy, :master_permanent_destroy],
       do: gettext("%{label} \"%{name}\" permanently deleted", label: label, name: name)

  defp named_message(label, name, action) when action in [:unarchive, :master_unarchive],
    do: gettext("%{label} \"%{name}\" restored", label: label, name: name)

  defp named_message(label, name, action),
    do: gettext("%{label} \"%{name}\" %{action}", label: label, name: name, action: action)

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
