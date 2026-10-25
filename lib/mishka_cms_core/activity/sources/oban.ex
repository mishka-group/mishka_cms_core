# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.Oban do
  @moduledoc """
  Activity source backed by Oban job telemetry. Attaches once on app boot
  via `attach/0` (called from MishkaCmsCore.Application.start/2).

  ## How it works

    * Telemetry handler catches `:oban, :job, :start | :stop | :exception`
      events and rebroadcasts them on a set of PubSub topics so subscribers
      get exactly the slice they asked for (see "Topics").
    * Initial fetch reads recent rows from the `oban_jobs` table, filtered to
      the same scope.
    * Job → entry mapping treats exceptions and discards as errors,
      retryables as warnings, everything else as info.

  ## Scope keys read

    * `:current_user` — tenants only see their `site_id`.
    * `:resources` — optional list of resource modules. When present, only
      jobs whose `args["resource"]` matches one of them are shown (e.g. the
      Component admin page passes `[MishkaCmsCore.Runtime.Component]`).

  ## Topics

  A job is rebroadcast on every topic that applies to it, so a subscriber
  picks the most specific one for its scope:

    * `oban_activity` — all jobs (master, no resource filter)
    * `oban_activity:site:<id>` — jobs for one site
    * `oban_activity:res:<Module>` — jobs for one resource (any site)
    * `oban_activity:site:<id>:res:<Module>` — one resource on one site

  ## Where `site_id` / `resource` come from

  `site_id` is read from either args shape:

    * top-level: `%{"site_id" => "<uuid>"}`
    * nested:    `%{"data" => %{"site_id" => "<uuid>"}}` — used by
      MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker.

  `resource` is read from `args["resource"]` (the inspected module string set
  by `MishkaCmsCore.Runtime.Resources.Changes.SendToOban`). Jobs without one
  never appear on a resource-scoped topic.

  See `MishkaCmsCore.Activity.Behaviours.Source` for the behaviour contract.
  """

  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  use Gettext, backend: MishkaCmsCore.Gettext

  import Ecto.Query

  alias MishkaCmsCore.Activity.Helpers

  @topic "oban_activity"
  @handler_id "mishka-cms-core-activity-oban"

  @doc "Attach Oban telemetry → PubSub bridge. Idempotent."
  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [
        [:oban, :job, :start],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &__MODULE__.handle_telemetry/4,
      nil
    )
  end

  @doc false
  def handle_telemetry([:oban, :job, event], _measurements, %{job: job}, _config) do
    payload = %{__oban__: true, job: job, event: event}
    site_id = job_site_id(job)
    resource = job_resource(job)

    broadcast(@topic, payload)
    if site_id, do: broadcast(site_topic(site_id), payload)
    if resource, do: broadcast(res_topic(resource), payload)
    if site_id && resource, do: broadcast(site_res_topic(site_id, resource), payload)

    :ok
  end

  def handle_telemetry(_, _, _, _), do: :ok

  defp broadcast(topic, payload) do
    MishkaCmsCore.PubSub
    |> Phoenix.PubSub.broadcast(
      topic,
      %Phoenix.Socket.Broadcast{topic: topic, event: "oban_activity", payload: payload}
    )
  end

  @impl true
  def topics(scope) do
    case {Helpers.reach(scope[:current_user]), scope_resources(scope)} do
      {:nothing, _mods} -> []
      {:everything, nil} -> [@topic]
      {{:site, id}, nil} -> [site_topic(id)]
      {:everything, mods} -> Enum.map(mods, &res_topic/1)
      {{:site, id}, mods} -> Enum.map(mods, &site_res_topic(id, &1))
    end
  end

  defp site_topic(id), do: "#{@topic}:site:#{id}"
  defp res_topic(module), do: "#{@topic}:res:#{module}"
  defp site_res_topic(id, module), do: "#{@topic}:site:#{id}:res:#{module}"

  @impl true
  def handles?(%Phoenix.Socket.Broadcast{payload: %{__oban__: true}}), do: true
  def handles?(_), do: false

  @impl true
  def to_entry(%Phoenix.Socket.Broadcast{payload: %{__oban__: true, job: job, event: event}}) do
    now = DateTime.utc_now()

    %{
      id: "oban-#{job.id}-#{event}-#{DateTime.to_unix(now)}",
      resource_label: gettext("Job"),
      action: event,
      severity: severity_for(event),
      badge_label: gettext("WORKER"),
      badge_tone: :violet,
      # A job is not a create/update/destroy of content, so it carries no content tone and the
      # timeline colours it by :severity — but the key is still stated, because every entry
      # carries every key (`MishkaCmsCore.Activity.Helpers.entry_keys/0`).
      tone: nil,
      inserted_at: now,
      source_id: to_string(job.id),
      site_id: job_site_id(job),
      user_id: actor_id(job.args),
      message: message_for(job, event)
    }
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
    base =
      from j in Oban.Job,
        where: j.state in ["completed", "discarded", "retryable"],
        order_by: [desc: coalesce(j.completed_at, coalesce(j.discarded_at, j.inserted_at))],
        limit: ^limit

    base
    |> filter_site(site_id)
    |> filter_resources(scope_resources(scope))
    |> Oban.config().repo.all()
    |> Enum.map(&row_to_entry/1)
  end

  defp filter_site(query, nil), do: query

  defp filter_site(query, site_id) do
    where(
      query,
      [j],
      fragment("COALESCE(?->>'site_id', ?#>>'{data,site_id}') = ?", j.args, j.args, ^site_id)
    )
  end

  defp filter_resources(query, nil), do: query

  defp filter_resources(query, modules) do
    where(query, [j], fragment("?->>'resource'", j.args) in ^modules)
  end

  @doc """
  Build an entry map from a unified `MishkaCmsCore.Activity.Query` SQL row (the
  DB-side merge path). The row carries `worker`, the job `state`, and `args`, so
  it reuses the same event/severity/message derivation as the in-memory path.
  """
  def entry_from_row(row) do
    event = state_event(row["action"])
    job = %{worker: row["resource"], args: row["payload"] || %{}}

    %{
      id: "oban-#{row["source_id"]}-#{event}",
      resource_label: gettext("Job"),
      action: event,
      severity: severity_for(event),
      badge_label: gettext("WORKER"),
      badge_tone: :violet,
      # A job is not a create/update/destroy of content, so it carries no content tone and the
      # timeline colours it by :severity — but the key is still stated, because every entry
      # carries every key (`MishkaCmsCore.Activity.Helpers.entry_keys/0`).
      tone: nil,
      inserted_at: Helpers.to_datetime(row["inserted_at"]),
      source_id: row["source_id"],
      site_id: row["site_id"],
      user_id: row["user_id"],
      message: message_for(job, event)
    }
  end

  # WHO CAUSED THE JOB. `SendToOban.build_job_args/2` stamps the acting user into the args; a job
  # nobody triggered carries none and stays "System", which is what it is. Args come back from the
  # database as JSON, so the key is a string.
  defp actor_id(%{} = args), do: Map.get(args, "actor_id") || Map.get(args, :actor_id)
  defp actor_id(_args), do: nil

  defp state_event("completed"), do: :completed
  defp state_event("discarded"), do: :discarded
  defp state_event("retryable"), do: :retryable
  defp state_event(other), do: Helpers.action_atom(other)

  defp row_to_entry(job) do
    event = job_event(job)

    %{
      id: "oban-#{job.id}-#{event}",
      resource_label: gettext("Job"),
      action: event,
      severity: severity_for(event),
      badge_label: gettext("WORKER"),
      badge_tone: :violet,
      # A job is not a create/update/destroy of content, so it carries no content tone and the
      # timeline colours it by :severity — but the key is still stated, because every entry
      # carries every key (`MishkaCmsCore.Activity.Helpers.entry_keys/0`).
      tone: nil,
      inserted_at: job.completed_at || job.discarded_at || job.inserted_at,
      source_id: to_string(job.id),
      site_id: job_site_id(job),
      user_id: actor_id(job.args),
      message: message_for(job, event)
    }
  end

  defp job_event(%{state: "completed"}), do: :completed
  defp job_event(%{state: "discarded"}), do: :discarded
  defp job_event(%{state: "retryable"}), do: :retryable
  defp job_event(%{state: state}) when is_binary(state), do: Helpers.action_atom(state)
  defp job_event(_), do: :unknown

  defp severity_for(:exception), do: :error
  defp severity_for(:discarded), do: :error
  defp severity_for(:retryable), do: :warn
  defp severity_for(_), do: :info

  defp message_for(%{worker: worker} = job, event) when is_binary(worker) do
    short = worker |> String.split(".") |> List.last()

    case job_detail(job, event) do
      nil -> job_message(short, event)
      detail -> gettext("%{job} — %{detail}", job: job_message(short, event), detail: detail)
    end
  end

  defp message_for(_, event), do: gettext("Job %{event}", event: event)

  defp job_message(worker, :start), do: gettext("%{worker} start", worker: worker)
  defp job_message(worker, :stop), do: gettext("%{worker} stop", worker: worker)
  defp job_message(worker, :exception), do: gettext("%{worker} exception", worker: worker)
  defp job_message(worker, :completed), do: gettext("%{worker} completed", worker: worker)
  defp job_message(worker, :discarded), do: gettext("%{worker} discarded", worker: worker)
  defp job_message(worker, :retryable), do: gettext("%{worker} retryable", worker: worker)

  defp job_message(worker, event),
    do: gettext("%{worker} %{event}", worker: worker, event: event)

  defp job_detail(%{args: %{"transition" => transition, "site_name" => name}}, event)
       when is_binary(name) do
    site_runtime_message(name, transition, event)
  end

  defp job_detail(%{args: %{"site_name" => name, "modules" => modules}}, event)
       when is_binary(name) and is_list(modules) do
    if done?(event),
      do: gettext("Site \"%{name}\" torn down", name: name),
      else: gettext("Site \"%{name}\" tearing down", name: name)
  end

  defp job_detail(%{args: args}, event) when is_map(args) do
    subject =
      [short_resource(args["resource"]), quoted_title(args["data"])]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    case action_message(subject, args, event) do
      "" -> nil
      detail -> detail
    end
  end

  defp job_detail(_, _), do: nil

  defp site_runtime_message(name, "recompile", event) do
    if done?(event),
      do: gettext("Site \"%{name}\" recompiled", name: name),
      else: gettext("Site \"%{name}\" recompiling", name: name)
  end

  defp site_runtime_message(name, "purge", event) do
    if done?(event),
      do: gettext("Site \"%{name}\" disabled", name: name),
      else: gettext("Site \"%{name}\" disabling", name: name)
  end

  defp site_runtime_message(name, "rename", event) do
    if done?(event),
      do: gettext("Site \"%{name}\" renamed", name: name),
      else: gettext("Site \"%{name}\" renaming", name: name)
  end

  defp site_runtime_message(name, "provision", event) do
    if done?(event),
      do: gettext("Site \"%{name}\" given its sign-in pages", name: name),
      else: gettext("Site \"%{name}\" getting its sign-in pages", name: name)
  end

  defp site_runtime_message(name, other, _event),
    do: gettext("Site \"%{name}\" %{transition}", name: name, transition: other)

  defp action_message(subject, %{"action" => _} = args, event) do
    cond do
      purge_job?(args) -> purge_message(subject, done?(event))
      compile_job?(args) -> compile_message(subject, done?(event))
      true -> Enum.join(Enum.reject([subject, args["action"]], &(&1 in [nil, ""])), " ")
    end
  end

  defp action_message(subject, _args, _event), do: subject

  defp purge_message("", true), do: gettext("purged")
  defp purge_message("", false), do: gettext("purging")
  defp purge_message(subject, true), do: gettext("%{subject} purged", subject: subject)
  defp purge_message(subject, false), do: gettext("%{subject} purging", subject: subject)

  defp compile_message("", true), do: gettext("compiled")
  defp compile_message("", false), do: gettext("compiling")
  defp compile_message(subject, true), do: gettext("%{subject} compiled", subject: subject)
  defp compile_message(subject, false), do: gettext("%{subject} compiling", subject: subject)

  defp done?(event), do: event in [:stop, :completed]

  defp purge_job?(%{"action" => "destroy", "data" => %{}}), do: true
  defp purge_job?(%{"action" => "update", "data" => %{"active" => false}}), do: true
  defp purge_job?(_), do: false

  defp compile_job?(%{"action" => action, "data" => %{"active" => true} = data})
       when action in ["create", "update", "unarchive"],
       do: Map.get(data, "precompile", true) == true

  defp compile_job?(_), do: false

  defp short_resource(nil), do: nil

  defp short_resource(resource) when is_binary(resource),
    do: resource |> String.split(".") |> List.last()

  defp short_resource(_), do: nil

  defp quoted_title(%{} = data) do
    case data["title"] || data["name"] || data["site_name"] do
      nil -> nil
      title -> "\"#{title}\""
    end
  end

  defp quoted_title(_), do: nil

  defp job_site_id(%{args: %{"site_id" => site_id}}) when is_binary(site_id), do: site_id

  defp job_site_id(%{args: %{"data" => %{"site_id" => site_id}}}) when is_binary(site_id),
    do: site_id

  defp job_site_id(_), do: nil

  defp job_resource(%{args: %{"resource" => resource}}) when is_binary(resource), do: resource
  defp job_resource(_), do: nil

  defp site_of({:site, site_id}), do: site_id
  defp site_of(:everything), do: nil

  defp scope_resources(%{resources: list}) when is_list(list) and list != [],
    do: Enum.map(list, &inspect/1)

  defp scope_resources(_), do: nil
end
