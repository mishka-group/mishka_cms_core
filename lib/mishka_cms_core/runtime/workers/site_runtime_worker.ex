defmodule MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker do
  @moduledoc """
  Recompiles or purges a site's
  dependent parts when the site is activated / deactivated / renamed / archived / unarchived.
  Enqueued by `MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteRuntime` on the dedicated
  `:maintenance` queue, deduped per `site_id`.

    * `"recompile"` (activate / unarchive) → `BootHandler.compile_site/2`
    * `"purge"` (deactivate / archive) → `SiteRuntime.purge_parts/3` (keep templates)
    * `"rename"` → purge under the OLD name (drop templates) → recompile under the new name

  The child DB rows still exist here (only permanent-delete removes them), so the
  module list is streamed at run time via `SiteRuntime.module_specs/1`.

  ## Events

    * Every transition fires `runtime:site:before_rebuild` and `runtime:site:after_rebuild`,
      with `%{site_id: site_id, site_name: site_name, transition: transition}`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  require Logger

  alias MishkaCmsCore.Runtime.Handlers.{SiteRuntime, BootHandler}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"transition" => transition, "site_id" => site_id, "site_name" => site_name} = args
      }) do
    MishkaInstaller.Event.Hook.call(
      "runtime:site:before_rebuild",
      %{
        site_id: site_id,
        site_name: site_name,
        transition: transition
      },
      return: false
    )

    :telemetry.span(
      [:mishka_cms, :runtime, :workers, :site_runtime],
      %{site: site_name, transition: transition},
      fn ->
        dispatch(transition, site_id, site_name, args["old_name"])
        Logger.info("[SiteRuntimeWorker] #{transition} #{inspect(site_name)}")

        MishkaInstaller.Event.Hook.call(
          "runtime:site:after_rebuild",
          %{
            site_id: site_id,
            site_name: site_name,
            transition: transition
          },
          return: false
        )

        {:ok, %{site: site_name, transition: transition}}
      end
    )
  end

  defp dispatch("recompile", site_id, site_name, _old_name) do
    BootHandler.compile_site(site_id, site_name)
  end

  defp dispatch("purge", site_id, site_name, _old_name) do
    SiteRuntime.purge_parts(site_name, SiteRuntime.module_specs(site_id), false)
  end

  defp dispatch("rename", site_id, site_name, old_name) do
    SiteRuntime.purge_parts(old_name, SiteRuntime.module_specs(site_id), true)
    BootHandler.compile_site(site_id, site_name)
  end
end
