defmodule MishkaCmsCore.Activity.Discovery do
  @moduledoc """
  Runtime discovery of the resources that feed the activity log, scanning every
  configured Ash domain (`config :mishka_cms, ash_domains`) — so the log adapts to
  whatever extensions are installed, and to future ones, with no hardcoded
  resource or extension names.

    * `paper_trailed/0` — resources carrying `AshPaperTrail.Resource` whose version
      resource exposes the project's `:sorted_versions` read action.
    * `event_logs/0`    — resources carrying `AshEvents.EventLog` (central event
      logs such as `MishkaDocument.EventLog`).
    * `areas/1`         — the permission areas a resource's own policies ask for, which decide
      whose Activity log shows its entries.

  Results are memoised in `:persistent_term` (read O(1), hot on the live
  `handles?/1` path). Call `invalidate/0` when the installed extension set changes
  (the same lifecycle that mutates `ash_domains`); a fresh scan recomputes the set.

  See `MishkaCmsCore.Activity.Sources.PaperTrail` and
  `MishkaCmsCore.Activity.Sources.EventLog`.
  """

  # The activity log spans everything installed, not just this library, so it has to look at the
  # application that actually lists the domains — the CMS in a deployment, this library on its own,
  # an extension when that extension is under test. Naming one here would make the log blind to every
  # other extension, so the host says which app it is.
  @otp_app Application.compile_env!(:mishka_cms_core, :host_app)
  @paper_trailed_key {__MODULE__, :paper_trailed}
  @event_logs_key {__MODULE__, :event_logs}
  @areas_key {__MODULE__, :areas}

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @doc "Paper-trailed resources across all domains (with a `:sorted_versions` guard)."
  def paper_trailed, do: memo(@paper_trailed_key, &compute_paper_trailed/0)

  @doc "Central `AshEvents.EventLog` resources across all domains."
  def event_logs, do: memo(@event_logs_key, &compute_event_logs/0)

  @doc "Every resource of every Ash domain the host application lists."
  @spec resources() :: [Ash.Resource.t()]
  def resources do
    for domain <- Ash.Info.domains(@otp_app),
        resource <- Ash.Domain.Info.resources(domain),
        do: resource
  end

  @doc """
  The dashboard names `resource`'s own policies ask for — every `admin:dashboard:<area>` name a
  `MishkaCmsCore.Accounts.Checks.AccessPermissions` check among them lists, such as
  `["admin:dashboard:runtime:media"]` — and `[]` for a resource that names none.
  """
  @spec areas(module()) :: [String.t()]
  def areas(resource), do: memo({@areas_key, resource}, fn -> compute_areas(resource) end)

  @doc "Drop the cached discovery sets so the next call rescans the domains."
  def invalidate do
    :persistent_term.erase(@paper_trailed_key)
    :persistent_term.erase(@event_logs_key)

    for {{@areas_key, _resource} = key, _areas} <- :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end

  defp compute_areas(resource) do
    for policy <- Ash.Policy.Info.policies(resource),
        %{check_module: AccessPermissions, check_opts: opts} <- policy.policies,
        name <- List.wrap(opts[:permissions]),
        is_binary(name),
        dashboard_area?(String.split(name, ":")),
        uniq: true,
        do: name
  end

  defp dashboard_area?(["admin", "dashboard", area | _rest]), do: area != "*"
  defp dashboard_area?(_segments), do: false

  defp compute_paper_trailed do
    for resource <- resources(),
        AshPaperTrail.Resource in Spark.extensions(resource),
        sorted_versions?(resource),
        do: resource
  end

  defp compute_event_logs do
    for resource <- resources(),
        AshEvents.EventLog in Spark.extensions(resource),
        do: resource
  end

  # `:sorted_versions` is a project convention on every paper-trail mixin, not an
  # AshPaperTrail built-in, so a foreign paper-trailed resource lacking it is
  # skipped rather than crashing the feed at read time.
  defp sorted_versions?(resource) do
    case version_resource(resource) do
      nil -> false
      version -> :sorted_versions in Enum.map(Ash.Resource.Info.actions(version), & &1.name)
    end
  end

  defp version_resource(resource) do
    AshPaperTrail.Resource.Info.version_resource(resource)
  rescue
    _ -> nil
  end

  defp memo(key, compute) do
    case :persistent_term.get(key, :__miss__) do
      :__miss__ ->
        value = compute.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
