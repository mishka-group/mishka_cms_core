defmodule MishkaCmsCore.Runtime.RuntimeStatus do
  @moduledoc """
  Read-only runtime status of a single runtime record (Component, Layout, ErrorPage,
  Page, Stylesheet, JsHook): its latest Oban compile job and whether its compiled
  artifact is present — a module loaded in RAM (module-backed resources) or the
  site's combined CSS/JS bundle (asset-backed Stylesheet/JsHook).

  `compute/2` returns a plain map consumed by
  `MishkaCmsCoreWeb.Live.Admin.Components.RuntimeStatusTimeline`. It never compiles
  or writes — only `:erlang.module_loaded/1`, `AssetsState.exists?/2`, and one
  `oban_jobs` read.

  Lazy parts (`precompile: false` — a Page, a Layout, an Error Page or a Component)
  are NOT compiled until the first request that needs them, so "module not loaded"
  is the normal `:lazy_ready` state, not a failure. See
  `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker` `compile?/3`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Ecto.Query

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  @doc """
  Per-resource shape: artifact kind, module-name key/type, label.

  `key_field` names the module (`Helpers.module_name/3` hashes it); `lookup_field` names the column
  the compiler searches the row by. They differ for everything but a Component: a Layout's module is
  keyed by `id` while the compile worker finds the row by `path`, which is why one field cannot
  serve both.
  """
  def config(MishkaCmsCore.Runtime.Component),
    do: %{
      kind: :module,
      key_field: :name,
      lookup_field: :name,
      type: "Component",
      label: gettext("Component")
    }

  def config(MishkaCmsCore.Runtime.Layout),
    do: %{
      kind: :module,
      key_field: :id,
      lookup_field: :path,
      type: "Layout",
      label: gettext("Layout")
    }

  def config(MishkaCmsCore.Runtime.ErrorPage),
    do: %{
      kind: :module,
      key_field: :id,
      lookup_field: :path,
      type: "ErrorPage",
      label: gettext("Error Page")
    }

  def config(MishkaCmsCore.Runtime.Page),
    do: %{
      kind: :module,
      key_field: :id,
      lookup_field: :path,
      type: "Page",
      label: gettext("Page")
    }

  def config(MishkaCmsCore.Runtime.Stylesheet),
    do: %{kind: :asset, asset_type: "css", label: gettext("Stylesheet")}

  def config(MishkaCmsCore.Runtime.JsHook),
    do: %{kind: :asset, asset_type: "js", label: gettext("JS Hook")}

  @doc "Compute the status map for `record` of `resource`."
  def compute(record, resource) do
    cfg = config(resource)
    site_name = site_name_of(record)
    mode = mode_of(cfg, record)
    {loaded?, artifact_label} = artifact(cfg, record, site_name)
    job = resource |> latest_job(record.id) |> unless_orphaned()

    base = %{
      mode: mode,
      active?: record.active,
      archived?: !is_nil(record.archived_at),
      artifact_loaded?: loaded?,
      artifact_label: artifact_label,
      site_name: site_name,
      module: module_of(cfg, record, site_name),
      job: job
    }

    {state, label, message} = classify(base, cfg)
    Map.merge(base, %{state: state, label: label, message: message})
  end

  defp site_name_of(%{site: %{name: name}}) when is_binary(name), do: name
  defp site_name_of(_record), do: "Global"

  defp module_of(%{kind: :module} = cfg, record, site_name),
    do: Helpers.module_name(Map.get(record, cfg.key_field), site_name, cfg.type)

  defp module_of(_cfg, _record, _site_name), do: nil

  # Every module-backed resource reads the flag the same way, components included: set means the
  # module is built at boot, unset means the first request that needs it builds it.
  defp mode_of(%{kind: :asset}, _record), do: :asset
  defp mode_of(_cfg, %{precompile: true}), do: :eager_precompile
  defp mode_of(_cfg, _record), do: :lazy

  # Site assets bundle under the site name; global assets bundle into the shared base.
  defp artifact(%{kind: :asset, asset_type: type}, _record, site_name),
    do:
      {AssetsState.exists?(asset_bundle_id(site_name), type),
       gettext("part of the %{site} %{type} bundle", site: site_name, type: type)}

  defp artifact(%{kind: :module} = cfg, record, site_name) do
    module = Helpers.module_name(Map.get(record, cfg.key_field), site_name, cfg.type)

    if :erlang.module_loaded(module),
      do: {true, gettext("module %{module} loaded in RAM", module: inspect(module))},
      else: {false, gettext("module not loaded")}
  end

  defp asset_bundle_id("Global"), do: "__shared_base__"
  defp asset_bundle_id(site_name), do: site_name

  # First match wins.
  defp classify(%{archived?: true}, _cfg),
    do: {:archived, gettext("Archived"), gettext("Soft-deleted — runtime artifact purged.")}

  defp classify(%{active?: false}, _cfg),
    do:
      {:inactive, gettext("Inactive"),
       gettext("Not active — not compiled / removed from runtime.")}

  defp classify(%{job: %{state: s}}, _cfg) when s in ~w(executing available scheduled),
    do: {:compiling, gettext("Compiling…"), gettext("Background compile job %{state}.", state: s)}

  defp classify(%{job: %{state: s} = job}, _cfg) when s in ~w(retryable discarded cancelled),
    do: {:failed, failed_label(s), job_error(job) || gettext("Job %{state}.", state: s)}

  # THE REASON EXISTED AND NOTHING READ IT. `CompileFailureState` records why a module would not
  # compile so the hot path can skip recompiling it on every request, and until now the only reader
  # was that hot path — so a page whose code was broken reported `Live` if an older version of the
  # module happened to still be loaded, and `Ready — compiles on first request` if it was not. Both
  # are true statements about the runtime and neither is the one an author needs.
  defp classify(%{module: module} = base, cfg) when not is_nil(module) do
    case CompileFailureState.failed?(module) do
      true -> {:failed, gettext("Compile failed"), failure_message(base, reason(module))}
      false -> classify_runtime(base, cfg)
    end
  end

  defp classify(base, cfg), do: classify_runtime(base, cfg)

  # A page that will not compile but whose module is still loaded keeps serving the last version
  # that did, which is the right thing for a visitor and a trap for an author: their change is not
  # on the page and nothing said so.
  defp failure_message(%{artifact_loaded?: true}, reason),
    do:
      gettext(
        "Still serving the last version that compiled. Your latest change is not live. %{reason}",
        reason: reason
      )

  defp failure_message(_base, reason), do: reason

  defp reason(module) do
    case CompileFailureState.reason(module) do
      {:compilation_error, message} when is_binary(message) -> message
      :compilation_error -> gettext("The module did not compile.")
      other -> inspect(other)
    end
  end

  defp classify_runtime(%{mode: :asset, artifact_loaded?: true} = base, cfg),
    do:
      {:live, gettext("Live"),
       gettext("Part of the %{site} %{type} bundle.", site: base.site_name, type: cfg.asset_type)}

  defp classify_runtime(%{mode: :asset} = base, cfg),
    do:
      {:pending, gettext("Pending bundle"),
       gettext("Active but not yet in the %{site} %{type} bundle.",
         site: base.site_name,
         type: cfg.asset_type
       )}

  defp classify_runtime(%{mode: :eager_precompile, artifact_loaded?: true}, _cfg),
    do: {:live, gettext("Live"), gettext("Compiled module loaded in RAM.")}

  defp classify_runtime(%{mode: :eager_precompile}, _cfg),
    do:
      {:pending, gettext("Pending compile"),
       gettext("Active but the module is not loaded yet — compile pending.")}

  defp classify_runtime(%{mode: :lazy, artifact_loaded?: true}, _cfg),
    do:
      {:live, gettext("Live (lazy)"), gettext("Compiled on a previous request — module in RAM.")}

  defp classify_runtime(%{mode: :lazy}, _cfg),
    do:
      {:lazy_ready, gettext("Ready — compiles on first request"),
       gettext(
         "Lazy (precompile: false). The module is not loaded until the first visitor request. This is normal."
       )}

  defp failed_label("retryable"), do: gettext("Compile retrying")
  defp failed_label("cancelled"), do: gettext("Compile cancelled")
  defp failed_label(_), do: gettext("Compile failed")

  defp job_error(%{errors: [first | _]}) when is_map(first),
    do: first["error"] || first[:error] || inspect(first)

  defp job_error(_), do: nil

  # Latest Oban job for this record, as a partially-loaded `%Oban.Job{}`. Oban has
  # no read API; you query the `Oban.Job` schema yourself. The select field list and
  # the `Oban.Repo.one(Oban.config(), query)` call mirror `Oban.Web.JobQuery` — that
  # resolves the configured repo + prefix at runtime (this extension can't see the
  # parent app's `MishkaCms.Repo` at compile time). The args JSON paths match the ones
  # written by MishkaCmsCore.Runtime.Changes.SendToOban and read by Activity.Sources.Oban.
  @job_fields [
    :state,
    :attempted_by,
    :errors,
    :attempted_at,
    :completed_at,
    :cancelled_at,
    :discarded_at,
    :inserted_at
  ]

  # A JOB LEFT `executing` BY A NODE THAT STOPPED MID-RUN — a restart, a deploy — keeps that state
  # until `Oban.Lifeline` rescues it, and `Compiling…` stayed on a record that had compiled and was
  # serving. A job this node took before it booted is not running, so it says nothing about the
  # record; one another node took cannot be told apart from a running one and still counts.
  defp unless_orphaned(
         %{state: "executing", attempted_at: %DateTime{} = at, attempted_by: [node | _]} = job
       ) do
    case node == Oban.config().node and DateTime.before?(at, booted_at()) do
      true -> nil
      false -> job
    end
  end

  defp unless_orphaned(job), do: job

  defp booted_at do
    {since_boot, _since_last_call} = :erlang.statistics(:wall_clock)
    DateTime.add(DateTime.utc_now(), -since_boot, :millisecond)
  end

  defp latest_job(resource, id) do
    query =
      from(j in Oban.Job,
        where: fragment("? ->> 'resource'", j.args) == ^inspect(resource),
        where: fragment("? #>> '{data,id}'", j.args) == ^to_string(id),
        order_by: [desc: j.id],
        limit: 1
      )
      |> select(^@job_fields)

    Oban.Repo.one(Oban.config(), query)
  end
end
