# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.SiteTeardownWorker do
  @moduledoc """
  Frees everything a permanently-deleted site loaded into memory.

  Runs on the dedicated `:maintenance` queue so a large site's teardown never
  competes with live module/asset compilation for other sites. The site's DB
  rows (and all child rows) are already gone via the `ON DELETE CASCADE` from the
  `:permanent_destroy` action; this worker only reclaims the in-memory artifacts:
  compiled modules, cached CSS/JS, routing metadata, and on-disk templates.

  The job carries the site name and the list of module-backed records captured
  *before* the cascade ran (see
  `MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteTeardown`), because those
  rows no longer exist by the time this runs.

  See `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker` for the per-record
  lifecycle and `MishkaCmsCore.Runtime.States.SiteState` for the request gate.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  require Logger

  alias MishkaCmsCore.Runtime.Handlers.SiteRuntime
  alias MishkaCmsCore.Runtime.States.SiteState

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"site_id" => site_id, "site_name" => site_name, "modules" => modules}
      }) do
    if site_present?(site_id) do
      Logger.info("[SiteTeardownWorker] #{inspect(site_name)} still exists — teardown skipped")
      :ok
    else
      run_teardown(site_id, site_name, modules)
    end
  end

  # Guards against a rolled-back permanent delete: if the row is still there (even
  # archived) the site is not really gone, so we must not purge anything. Uses the
  # archived-inclusive `:get_any` read, since a permanent delete always follows an
  # archive.
  defp site_present?(site_id) do
    match?(
      {:ok, _},
      Ash.get(MishkaCmsCore.Runtime.Site, site_id, action: :get_any, authorize?: false)
    )
  end

  defp run_teardown(site_id, site_name, modules) do
    MishkaInstaller.Event.Hook.call(
      "runtime:site:before_teardown",
      %{
        site_id: site_id,
        site_name: site_name,
        modules: length(modules)
      },
      return: false
    )

    :telemetry.span(
      [:mishka_cms, :runtime, :workers, :site_teardown],
      %{site: site_name, modules: length(modules)},
      fn ->
        SiteState.delete(site_id)
        counts = SiteRuntime.purge_parts(site_name, modules, true)

        Logger.info(
          "[SiteTeardownWorker] purged #{inspect(site_name)}: " <>
            "#{counts.modules} modules, #{counts.assets} assets, #{counts.routes} routes"
        )

        MishkaInstaller.Event.Hook.call(
          "runtime:site:after_teardown",
          %{
            site_id: site_id,
            site_name: site_name,
            counts: counts
          },
          return: false
        )

        {:ok, Map.put(counts, :site, site_name)}
      end
    )
  end
end
