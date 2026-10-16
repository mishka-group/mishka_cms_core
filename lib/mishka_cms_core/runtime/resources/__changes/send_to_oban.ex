# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Changes.SendToOban do
  @moduledoc """
  Triggers background compilation jobs for runtime resources.

  This change automatically enqueues Oban jobs whenever runtime resources (Pages,
  Layouts, Components, etc.) are created, updated, or destroyed. The jobs handle
  asynchronous compilation of these resources into executable Elixir modules,
  ensuring the runtime system reflects the latest changes without blocking the
  main request/response cycle.

  The job carries the record's attributes (including `site_id`) and the action;
  the worker resolves the site from `site_id` at run time. Action types are
  differentiated, with special handling for unarchive. Enqueueing is skipped when
  an update changes nothing (context[:changed?] == false).

  Jobs are unique per record (`resource:id`). Changing a record again while its
  job is still queued (available or scheduled) replaces that job's args with the
  latest, so only the newest version is ever compiled — never a stale snapshot.

  In test environments, job enqueueing is disabled to prevent background processing
  during tests, making test execution more predictable and faster. The change uses
  after_action hooks to ensure jobs are only enqueued after successful database
  commits, preventing compilation of resources that fail validation or persistence.
  """

  use Ash.Resource.Change

  @impl true
  @doc """
  Applies the change to enqueue compilation jobs after successful actions.

  ## Parameters
  - `changeset` - The Ash changeset for the resource being modified
  - `_opts` - Change options (unused)
  - `_context` - Change context (unused)

  ## Returns
  Modified changeset with after_action hook for job enqueueing
  """
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      no_op_update? = changeset.action.type == :update and changeset.context[:changed?] == false

      if !deferred?(changeset) and !no_op_update? do
        enqueue_job(changeset, record)
      end

      {:ok, record}
    end)
  end

  # Bulk callers (e.g. the UI-kit installer) set `defer_runtime: true` so no
  # per-row job is enqueued; they trigger one rebuild after the whole batch
  # commits. See `MishkaCmsCore.Runtime.Handlers.UiKitHandler`.
  defp deferred?(changeset), do: changeset.context[:defer_runtime] == true

  @impl true
  @doc """
  Provides atomic operation support for the change.

  Delegates to the regular change function for compatibility.
  """
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp enqueue_job(changeset, record) do
    if Application.get_env(:mishka_cms_core, :env_test?, false) do
      :ok
    else
      build_job_args(changeset, record)
      |> MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker.new(
        queue: :modules,
        meta: %{slug: "#{inspect(changeset.resource)}:#{record.id}"},
        unique: [fields: [:worker, :meta], keys: [:slug], states: [:available, :scheduled]],
        replace: [available: [:args], scheduled: [:args]]
      )
      |> Oban.insert()
    end
  end

  @doc """
  Builds the Oban job args for a runtime change.

  Serializes the record's attributes (which always include `site_id`) plus the
  action. The worker resolves the site name from `site_id` at run time, so the
  `:site` relationship is never touched here — loading it would re-read the
  multitenant source resource and demand a tenant.

  It also carries `actor_id` when somebody is acting. The activity log reads it
  (`MishkaCmsCore.Activity.Sources.Oban`) so a job that failed names the person whose save enqueued
  it rather than "System" — the same actor AshPaperTrail stamps on the version of that very save, so
  the two rows agree. A job nobody triggered (a cron, a boot) has no actor and the key is absent.
  """
  @spec build_job_args(Ash.Changeset.t(), Ash.Resource.record()) :: map()
  def build_job_args(changeset, record) do
    action =
      if(changeset.action.name == :unarchive,
        do: "unarchive",
        else: to_string(changeset.action.type)
      )

    data =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(fn attr -> {attr.name, Map.get(record, attr.name)} end)

    %{resource: inspect(changeset.resource), action: action, data: data}
    |> put_actor(get_in(changeset.context, [:private, :actor]))
  end

  # Read the same way AshPaperTrail reads it, so a job and the version written by the same save can
  # never disagree about who did it.
  defp put_actor(args, %{id: id}) when is_binary(id), do: Map.put(args, :actor_id, id)
  defp put_actor(args, _actor), do: args
end
