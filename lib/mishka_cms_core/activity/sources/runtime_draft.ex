# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.RuntimeDraft do
  @moduledoc """
  Activity source for ALL runtime drafts — `PageDraft`, `LayoutDraft`, `ErrorPageDraft` — each tagged
  `badge_label: "DRAFT"` with a resource label of `"Page Draft"` / `"Layout Draft"` / `"Error Page
  Draft"` so a viewer can see it came from a draft.

  None of these are AshPaperTrail-versioned, AshEvents logs, or Oban jobs, so no other source sees
  them. They DO broadcast through `Ash.Notifier.PubSub` (prefixes `page_draft` / `layout_draft` /
  `error_page_draft`) on `created` / `updated` / `destroyed`, which this adapter consumes for the
  live feed; for history it reads each draft table directly.

  ## A discard is a live event only

  These three resources do NOT archive — `destroy :destroy` is a plain destroy, so discarding a
  draft removes the row. A publish leaves one behind (`status: :published`); a discard does not.
  So **discarded** appears on the live feed, as it happens, and never in the history read: there is
  nothing left in the table to report. An earlier version soft-deleted and the history read
  `archived_at` to spot a discard; that column is gone, and `MishkaCmsCore.Activity.Query` no longer
  looks for it. On a database that predates the change, rows left behind by that soft delete are
  cleaned up by `Mix.Tasks.MishkaCmsCore.PurgeDraftArchival`.

  Three user-facing events, derived from the action / row state: **saved** (create/update),
  **published** (publish), **discarded** (destroy/permanent_destroy — live feed only). Each draft contributes only to
  feeds whose scope covers its parent resource (the per-resource System Logs) or is unscoped (the
  `/admin/dashboard/runtime/activity` page). Config-driven via `@drafts`. See
  `MishkaCmsCore.Activity.Behaviours.Source` and `MishkaCmsCore.Activity.Query` (the DB-merge branch).
  """

  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.Helpers

  alias MishkaCmsCore.Runtime.{
    Page,
    Layout,
    ErrorPage,
    PageDraft,
    LayoutDraft,
    ErrorPageDraft
  }

  @events ~w(created updated destroyed)

  @drafts [
    %{module: PageDraft, prefix: "page_draft", label: gettext_noop("Page Draft"), scope: Page},
    %{
      module: LayoutDraft,
      prefix: "layout_draft",
      label: gettext_noop("Layout Draft"),
      scope: Layout
    },
    %{
      module: ErrorPageDraft,
      prefix: "error_page_draft",
      label: gettext_noop("Error Page Draft"),
      scope: ErrorPage
    }
  ]

  @by_module Map.new(@drafts, &{&1.module, &1})
  @label_by_resource Map.new(@drafts, &{to_string(&1.module), &1.label})

  @impl true
  def topics(scope) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      reach -> topics_for(site_of(reach), scope)
    end
  end

  defp topics_for(site_id, scope) do
    for cfg <- @drafts, covers?(cfg, scope), event <- @events do
      if site_id, do: "#{cfg.prefix}:#{site_id}:#{event}", else: "#{cfg.prefix}:#{event}"
    end
  end

  @impl true
  def handles?(%Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{resource: resource}
      }),
      do: Map.has_key?(@by_module, resource)

  def handles?(_), do: false

  @impl true
  def to_entry(%Phoenix.Socket.Broadcast{
        payload: %Ash.Notifier.Notification{resource: resource} = n
      }) do
    case Map.get(@by_module, resource) do
      nil ->
        nil

      cfg ->
        entry(
          cfg.label,
          norm(n.action.name),
          Map.get(n.data, :id),
          Map.get(n.data, :name),
          Map.get(n.data, :site_id),
          n.actor && Map.get(n.actor, :id),
          event_time(n.data)
        )
    end
  end

  def to_entry(_), do: nil

  @impl true
  def initial_fetch(scope, limit) do
    case Helpers.reach(scope[:current_user]) do
      :nothing -> []
      reach -> fetch(site_of(reach), scope, limit)
    end
  end

  defp fetch(site_id, scope, limit) do
    @drafts
    |> Enum.filter(&covers?(&1, scope))
    |> Enum.flat_map(fn cfg ->
      cfg.module |> fetch_drafts(site_id, limit) |> Enum.map(&record_to_entry(cfg.label, &1))
    end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Build an entry from a unified `MishkaCmsCore.Activity.Query` SQL row (the DB-merge path). The label
  is derived from the row's `resource` module string, so one dispatch covers all three draft tables.
  """
  def entry_from_row(row) do
    label = Map.get(@label_by_resource, row["resource"], gettext_noop("Draft"))

    entry(
      label,
      Helpers.action_atom(row["action"]),
      row["source_id"],
      payload_name(row["payload"]),
      row["site_id"],
      row["user_id"],
      Helpers.to_datetime(row["inserted_at"])
    )
  end

  defp record_to_entry(label, %{} = draft) do
    entry(
      label,
      record_action(draft),
      draft.id,
      draft.name,
      draft.site_id,
      nil,
      draft.updated_at || DateTime.utc_now()
    )
  end

  defp entry(label, action, source_id, name, site_id, user_id, at) do
    label = Helpers.translate(label)

    %{
      id: "draft-#{source_id}-#{action}-#{unix(at)}",
      resource_label: label,
      action: action,
      severity: Helpers.severity_for(action),
      badge_label: gettext("DRAFT"),
      badge_tone: :indigo,
      tone: Helpers.tone_for(action),
      inserted_at: at,
      source_id: source_id,
      site_id: site_id,
      user_id: user_id,
      message: message_for(label, name, action)
    }
  end

  # The action atom carried on the entry — drives icon + severity. Saves collapse to :update so a
  # publish/discard stays distinct (the message verb spells the rest out).
  defp norm(name) when name in [:publish, :master_publish], do: :publish

  defp norm(name)
       when name in [:destroy, :master_destroy, :permanent_destroy, :master_permanent_destroy],
       do: :destroy

  defp norm(_name), do: :update

  defp record_action(%{status: :published}), do: :publish
  defp record_action(_draft), do: :update

  defp message_for(label, name, :publish) when name in [nil, ""],
    do: gettext("%{label} published", label: label)

  defp message_for(label, name, :destroy) when name in [nil, ""],
    do: gettext("%{label} discarded", label: label)

  defp message_for(label, name, _action) when name in [nil, ""],
    do: gettext("%{label} saved", label: label)

  defp message_for(label, name, :publish),
    do: gettext("%{label} \"%{name}\" published", label: label, name: name)

  defp message_for(label, name, :destroy),
    do: gettext("%{label} \"%{name}\" discarded", label: label, name: name)

  defp message_for(label, name, _action),
    do: gettext("%{label} \"%{name}\" saved", label: label, name: name)

  # The last save/publish time the record carried. A discard broadcast hands over the row as it was
  # immediately before deletion, so `updated_at` is the closest thing to a discard time there is —
  # these resources do not archive, and there is no later timestamp to prefer.
  #
  # NOT `DateTime.utc_now()` for a discard, tempting as it is: this timestamp feeds the entry's id
  # through `unix/1`, which truncates to the second. A clock read makes the id depend on WHEN the
  # message was handled, so a topic delivered twice either side of a second boundary yields two ids
  # and the feed shows the discard twice. A draft discarded long after its last save is therefore
  # stamped a little early — the deliberate price of an id that survives redelivery.
  defp event_time(%{} = data),
    do: Map.get(data, :updated_at) || DateTime.utc_now()

  defp payload_name(%{} = payload), do: Map.get(payload, "name") || Map.get(payload, :name)
  defp payload_name(_payload), do: nil

  defp unix(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_unix()
  defp unix(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> unix()
  defp unix(_at), do: 0

  defp fetch_drafts(module, site_id, limit) do
    module
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(limit)
    |> then(&if(site_id, do: Ash.Query.filter_input(&1, %{site_id: site_id}), else: &1))
    |> Ash.read(authorize?: false, page: false)
    |> case do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  # A draft contributes to a scope when the scope is unscoped (the activity page) or its parent
  # resource is in the scoped list (the per-resource System Logs feed).
  defp covers?(cfg, %{resources: list}) when is_list(list), do: cfg.scope in list
  defp covers?(_cfg, _scope), do: true

  defp site_of({:site, site_id}), do: site_id
  defp site_of(:everything), do: nil
end
