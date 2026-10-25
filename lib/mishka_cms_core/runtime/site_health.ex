# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteHealth do
  @moduledoc """
  Read-only health roll-up for a single Site, for the admin Sites table's expanded
  row. A Site is an aggregate (it owns Pages/Layouts/Components/ErrorPages/Stylesheets/
  JsHooks + its CSS/JS bundles + a serving state), so this is a dashboard, not the
  linear pipeline used per-record by `MishkaCmsCore.Runtime.RuntimeStatus`.

  Signals (all cheap, computed on expand and on each realtime refresh):
    * serving state — straight off the loaded Site record, and whether it is offline: `offline_by` is
      `MishkaCmsCore.Settings.offline_by/1`, so the site's own switch and the Global one are told apart
    * compile jobs since this node booted, grouped per target into in-progress, unrecovered (the
      target's latest job failed) and recovered (failed earlier, but a later job succeeded) — one
      `oban_jobs` query matched on the site's immutable `site_id` (all jobs carry it). A job from
      before the boot is left out: the boot cancelled it and compiled from the database itself
      (`MishkaCmsCore.Runtime.Handlers.BootHandler.booted_at/0`)
    * whether the app's Oban rescues jobs a restart interrupts (`BootHandler.lifeline?/0`)
    * per-resource active/inactive/archived counts — one UNION query across the 6
      runtime tables (site-specific records only)
    * CSS/JS bundle presence + freshness — O(1) `AssetsState` ETS reads
    * recent activity — last few unified-log entries for the site (`Activity.Query`)

  The derived headline is `:inactive → :offline → :attention (unrecovered) → :working (in progress)
  → :recovered → :healthy`. Red (`:attention`) is reserved for a target whose latest job
  is still failed; a target that failed and then succeeded is a soft orange `:recovered`,
  because a later success supersedes the old failure (a fix saved after a failed save).

  Rendered by `MishkaCmsCoreWeb.Live.Admin.Components.SiteHealthPanel`.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Activity.Query, as: ActivityQuery
  alias MishkaCmsCore.Activity.Helpers

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # {display label, table name} — table names are constants (never user input).
  @parts [
    {gettext_noop("Page"), "pages"},
    {gettext_noop("Layout"), "layouts"},
    {gettext_noop("Component"), "components"},
    {gettext_noop("Error Page"), "error_pages"},
    {gettext_noop("Stylesheet"), "stylesheets"},
    {gettext_noop("JS Hook"), "js_hooks"}
  ]

  @in_progress ~w(executing available scheduled)
  @failed ~w(retryable discarded cancelled)
  @success ~w(completed)

  @doc "Compute the health map for `site` (a loaded Site record)."
  def compute(site) do
    site_id = to_string(site.id)
    jobs = site_jobs(site_id)
    in_progress = Enum.filter(jobs, &(&1.state in @in_progress))
    %{unrecovered: unrecovered, recovered: recovered} = classify(jobs)

    base = %{
      name: site.name,
      host: site.host,
      mode: site.mode,
      serving?: site.active == true,
      offline_by: Settings.offline_by(site),
      master?: site.master == true,
      in_progress: in_progress,
      unrecovered: unrecovered,
      recovered: recovered,
      error: latest_error(unrecovered),
      parts: part_counts(site_id),
      assets: %{css: asset_state(site.name, "css"), js: asset_state(site.name, "js")},
      recent: recent_activity(site_id),
      lifeline?: BootHandler.lifeline?()
    }

    Map.merge(base, headline(base))
  end

  # Per target, judge by its newest job (query is newest-first): latest failed →
  # unrecovered; failed earlier but latest succeeded → recovered (a later build supersedes).
  defp classify(jobs) do
    acc =
      jobs
      |> Enum.group_by(& &1.target)
      |> Enum.reduce(%{unrecovered: [], recovered: []}, &classify_target/2)

    %{
      unrecovered: Enum.sort_by(acc.unrecovered, & &1.at, {:desc, DateTime}),
      recovered: Enum.sort_by(acc.recovered, & &1.recovered_at, {:desc, DateTime})
    }
  end

  defp classify_target({_target, [newest | _] = group}, acc) do
    cond do
      newest.state in @failed ->
        %{acc | unrecovered: [newest | acc.unrecovered]}

      newest.state in @success ->
        case Enum.find(group, &(&1.state in @failed)) do
          nil ->
            acc

          failure ->
            %{acc | recovered: [Map.put(failure, :recovered_at, newest.at) | acc.recovered]}
        end

      true ->
        acc
    end
  end

  defp headline(%{serving?: false}),
    do: %{
      state: :inactive,
      label: gettext("Inactive"),
      message: gettext("Site is deactivated — not serving requests.")
    }

  defp headline(%{offline_by: [:global | _site]}),
    do: %{
      state: :offline,
      label: gettext("Offline"),
      message:
        gettext("Every site is offline from Global — visitors see this site's offline page.")
    }

  defp headline(%{offline_by: [:site]}),
    do: %{
      state: :offline,
      label: gettext("Offline"),
      message: gettext("Taken offline in this site's settings — visitors see its offline page.")
    }

  defp headline(%{unrecovered: [_ | _] = jobs}),
    do: %{
      state: :attention,
      label: gettext("Needs attention"),
      message: gettext("%{count} job(s) failed — needs a look.", count: length(jobs))
    }

  defp headline(%{in_progress: [_ | _] = jobs}),
    do: %{
      state: :working,
      label: gettext("Working"),
      message: gettext("%{count} task(s) compiling…", count: length(jobs))
    }

  defp headline(%{recovered: [_ | _] = jobs}),
    do: %{
      state: :recovered,
      label: gettext("Recovered"),
      message:
        ngettext(
          "Recovered from %{count} recent error — serving normally.",
          "Recovered from %{count} recent errors — serving normally.",
          length(jobs)
        )
    }

  defp headline(_base),
    do: %{
      state: :healthy,
      label: gettext("Healthy"),
      message: gettext("Serving normally — nothing pending, no failures.")
    }

  defp latest_error([%{error: error} | _]) when is_binary(error), do: error
  defp latest_error(_), do: nil

  defp asset_state(site_name, type) do
    if AssetsState.exists?(site_name, type),
      do: %{present?: true, updated_at: AssetsState.updated_at(site_name, type)},
      else: %{present?: false, updated_at: nil}
  end

  # This site's jobs, newest-first, including completed (needed to tell recovered from
  # still-failed). Match on `site_id` ONLY — an immutable UUID that's never reused. (Not
  # `site_name`: it's reusable after a site is archived, which would cross-match another
  # site's bundle jobs. All jobs, incl. asset-bundle, carry `data.site_id`.)
  defp site_jobs(site_id) do
    # `errors` is a Postgres jsonb[] array, so use `errors[1]->>'error'`, not the `#>>` path op.
    sql =
      "SELECT id, state, args->>'resource', args->>'action', " <>
        "COALESCE(args#>>'{data,name}', args#>>'{data,path}'), args#>>'{data,type}', " <>
        "args#>>'{data,id}', errors[1]->>'error', " <>
        "COALESCE(completed_at, cancelled_at, discarded_at, attempted_at, inserted_at) " <>
        "FROM oban_jobs " <>
        "WHERE COALESCE(args->>'site_id', args#>>'{data,site_id}') = $1 " <>
        "AND state IN ('executing','available','scheduled','retryable','discarded','cancelled','completed') " <>
        "AND inserted_at >= $2 " <>
        "ORDER BY id DESC LIMIT 100"

    booted_at = DateTime.to_naive(BootHandler.booted_at())

    case Ecto.Adapters.SQL.query(@repo, sql, [site_id, booted_at]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &job_row/1)
      _ -> []
    end
  end

  defp job_row([id, state, resource, action, name, type, rec_id, error, at]) do
    %{
      id: to_string(id),
      state: state,
      label: job_label(resource, action, name, type),
      error: error,
      target: target_key(resource, rec_id),
      at: Helpers.to_datetime(at)
    }
  end

  # Recovery target: asset jobs share one "bundle" per site; module jobs key by record id
  # (so a success on one record never recovers a different record's failure).
  defp target_key(resource, rec_id) do
    cond do
      is_binary(resource) and String.contains?(resource, "BootHandler") -> "bundle"
      is_binary(rec_id) -> "rec:" <> rec_id
      is_binary(resource) -> "res:" <> resource
      true -> "site"
    end
  end

  defp job_label(resource, action, name, type) when is_binary(resource) do
    if String.contains?(resource, "BootHandler") and is_binary(type) do
      gettext("%{type} bundle rebuild", type: String.upcase(type))
    else
      label = resource |> String.split(".") |> List.last()
      base = if action, do: "#{label} #{action}", else: label
      if name, do: "#{base} · #{name}", else: base
    end
  end

  defp job_label(_resource, _action, _name, _type), do: gettext("Site task")

  # One UNION query: per-resource active/inactive/archived counts, site-specific only.
  # sobelow_skip ["SQL.Query"]
  # Labels and table names are the literals in `@parts`; the only input, `site_id`, is bound as `$1`.
  defp part_counts(site_id) do
    sql =
      Enum.map_join(@parts, " UNION ALL ", fn {label, table} ->
        "SELECT '#{label}' AS kind, " <>
          "COUNT(*) FILTER (WHERE active AND archived_at IS NULL) AS active, " <>
          "COUNT(*) FILTER (WHERE NOT active AND archived_at IS NULL) AS inactive, " <>
          "COUNT(*) FILTER (WHERE archived_at IS NOT NULL) AS archived " <>
          "FROM #{table} WHERE site_id = $1::text::uuid"
      end)

    case Ecto.Adapters.SQL.query(@repo, sql, [site_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [kind, active, inactive, archived] ->
          %{
            kind: Gettext.gettext(MishkaCmsCore.Gettext, kind),
            active: active,
            inactive: inactive,
            archived: archived
          }
        end)

      _ ->
        []
    end
  end

  defp recent_activity(site_id) do
    ActivityQuery.page(%{site_id: site_id, limit: 6, offset: 0})
  end
end
