# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.PaperTrail do
  @moduledoc """
  Activity source backed by AshPaperTrail-versioned resources in the
  `MishkaCmsCore.Runtime` domain. Auto-discovers any resource that ships
  with `AshPaperTrail.Resource` — no per-resource configuration.

  ## Scope keys read

    * `:current_user` — used to derive master vs tenant subscription topics.
      Tenants see only their `site_id`.
    * `:resources`    — optional list of modules to restrict to (e.g. on the
      Component admin page, pass `[MishkaCmsCore.Runtime.Component]`).

  See `MishkaCmsCore.Activity.Behaviours.Source` for the behaviour contract.
  """

  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.{Discovery, Helpers}

  @events ~w(created updated destroyed)

  @doc "Every paper-trailed resource auto-discovered across all configured domains."
  def discovered_modules, do: Discovery.paper_trailed()

  @impl true
  def topics(scope) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      reach -> topics_for(resources_for_scope(scope), site_of(reach))
    end
  end

  defp topics_for(modules, site_id) do
    for module <- modules,
        event <- @events,
        prefix = Ash.Notifier.PubSub.Info.prefix(module) do
      if site_id, do: "#{prefix}:#{site_id}:#{event}", else: "#{prefix}:#{event}"
    end
  end

  @impl true
  def handles?(%Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{resource: resource}
      }),
      do: resource in Discovery.paper_trailed()

  def handles?(_), do: false

  @impl true
  def to_entry(%Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{} = n}) do
    label = Helpers.humanize_module(n.resource)
    action = n.action.name
    now = DateTime.utc_now()
    source_id = Map.get(n.data, :id)
    {badge_label, badge_tone} = Helpers.paper_trail_badge(action)

    %{
      id: entry_id(source_id, action, now),
      resource_label: label,
      action: action,
      severity: Helpers.severity_for(action),
      tone: Helpers.tone_for(action),
      badge_label: badge_label,
      badge_tone: badge_tone,
      inserted_at: now,
      source_id: source_id,
      site_id: Map.get(n.data, :site_id),
      user_id: n.actor && Map.get(n.actor, :id),
      message: message_for(label, action, n.data)
    }
  end

  def to_entry(_), do: nil

  @impl true
  def initial_fetch(scope, limit) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      reach -> fetch(resources_for_scope(scope), site_of(reach), limit)
    end
  end

  defp fetch(modules, site_id, limit) do
    modules
    |> Task.async_stream(
      fn module -> {module, fetch_versions(module, site_id, limit)} end,
      max_concurrency: max(length(modules), 1),
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {module, versions}} -> Enum.map(versions, &version_to_entry(&1, module))
      _ -> []
    end)
  end

  defp resources_for_scope(%{resources: list}) when is_list(list) and list != [] do
    Enum.filter(list, &(&1 in Discovery.paper_trailed()))
  end

  defp resources_for_scope(_), do: Discovery.paper_trailed()

  defp site_of({:site, site_id}), do: site_id
  defp site_of(:everything), do: nil

  defp fetch_versions(module, site_id, limit) do
    query =
      module
      |> AshPaperTrail.Resource.Info.version_resource()
      |> Ash.Query.for_read(:sorted_versions)
      |> Ash.Query.limit(limit)
      |> then(&if(site_id, do: Ash.Query.filter_input(&1, %{site_id: site_id}), else: &1))

    case Ash.read(query, authorize?: false, page: false) do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  @doc """
  Build an entry map from a unified `MishkaCmsCore.Activity.Query` SQL row (the
  DB-side merge path), reusing the same label/severity/badge/message derivation
  as the live and in-memory paths.
  """
  def entry_from_row(row) do
    label = resource_label(row["resource"])
    action = Helpers.action_atom(row["action"])
    at = Helpers.to_datetime(row["inserted_at"])
    source_id = row["source_id"]
    {badge_label, badge_tone} = Helpers.paper_trail_badge(action)

    %{
      id: entry_id(source_id, action, at),
      resource_label: label,
      action: action,
      severity: Helpers.severity_for(action),
      tone: Helpers.tone_for(action),
      badge_label: badge_label,
      badge_tone: badge_tone,
      inserted_at: at,
      source_id: source_id,
      site_id: row["site_id"],
      user_id: row["user_id"],
      message: message_for(label, action, row["payload"])
    }
  end

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

  defp version_to_entry(version, module) do
    label = Helpers.humanize_module(module)
    action = version.version_action_name
    {badge_label, badge_tone} = Helpers.paper_trail_badge(action)

    %{
      id: entry_id(version.version_source_id, action, version.version_inserted_at),
      resource_label: label,
      action: action,
      severity: Helpers.severity_for(action),
      tone: Helpers.tone_for(action),
      badge_label: badge_label,
      badge_tone: badge_tone,
      inserted_at: version.version_inserted_at,
      source_id: version.version_source_id,
      site_id: Map.get(version, :site_id),
      user_id: Map.get(version, :user_id),
      message: message_for(label, action, version.version_action_inputs)
    }
  end

  defp entry_id(source_id, action, %DateTime{} = at) do
    unix = at |> DateTime.truncate(:second) |> DateTime.to_unix()
    "pt-#{source_id}-#{action}-#{unix}"
  end

  defp message_for(label, action, source) do
    case record_title(source) do
      name when name in [nil, ""] -> unnamed_message(label, action)
      name -> named_message(label, name, action)
    end
  end

  defp record_title(%{} = record) do
    Map.get(record, :title) ||
      Map.get(record, :name) ||
      Map.get(record, "title") ||
      Map.get(record, "name")
  end

  defp record_title(_), do: nil

  defp unnamed_message(label, action) when action in [:create, :master_create],
    do: gettext("%{label} created", label: label)

  defp unnamed_message(label, action) when action in [:update, :master_update],
    do: gettext("%{label} updated", label: label)

  defp unnamed_message(label, :restore_version),
    do: gettext("%{label} restored to previous version", label: label)

  defp unnamed_message(label, action) when action in [:unarchive, :master_unarchive],
    do: gettext("%{label} restored", label: label)

  defp unnamed_message(label, action) when action in [:destroy, :master_destroy],
    do: gettext("%{label} archived", label: label)

  defp unnamed_message(label, action)
       when action in [:permanent_destroy, :master_permanent_destroy],
       do: gettext("%{label} permanently deleted", label: label)

  defp unnamed_message(label, action),
    do: gettext("%{label} %{action}", label: label, action: action)

  defp named_message(label, name, action) when action in [:create, :master_create],
    do: gettext("%{label} \"%{name}\" created", label: label, name: name)

  defp named_message(label, name, action) when action in [:update, :master_update],
    do: gettext("%{label} \"%{name}\" updated", label: label, name: name)

  defp named_message(label, name, :restore_version),
    do: gettext("%{label} \"%{name}\" restored to previous version", label: label, name: name)

  defp named_message(label, name, action) when action in [:unarchive, :master_unarchive],
    do: gettext("%{label} \"%{name}\" restored", label: label, name: name)

  defp named_message(label, name, action) when action in [:destroy, :master_destroy],
    do: gettext("%{label} \"%{name}\" archived", label: label, name: name)

  defp named_message(label, name, action)
       when action in [:permanent_destroy, :master_permanent_destroy],
       do: gettext("%{label} \"%{name}\" permanently deleted", label: label, name: name)

  defp named_message(label, name, action),
    do: gettext("%{label} \"%{name}\" %{action}", label: label, name: name, action: action)
end
