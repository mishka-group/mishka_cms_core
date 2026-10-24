# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker do
  @moduledoc """
  Gives a site created in the admin the content a first install gets, and recompiles or purges a
  site's dependent parts when the site is activated / deactivated / renamed / rehosted / archived /
  unarchived.
  Enqueued by `MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteRuntime` on the dedicated
  `:maintenance` queue, deduped per `site_id`.

    * `"provision"` (create) → `MishkaCmsCore.Install.StarterContent.ensure_auth/1`: the `auth`
      layout, the sign-in pages and the built-in words of its languages; then
      `MishkaCmsCore.Install.StarterContent.seed/2`: the theme, the header, the footer, the
      `site-main` layout and the home page, the installer's own, so every site of an install is
      drawn in the same frame. Both write only what the site is missing, so a job that runs again
      writes nothing twice. The sign-in pages come first: a starter that cannot be written — an
      install with no master site to keep the logo in — is logged, and the site can still be
      signed into. A site that is gone by the time the job runs cancels it. Then the site's `"js"`
      asset job (`BootHandler.asset_job/4`), under its name now: compiling those pages queues its
      CSS and sitemap, but nothing else builds a new site's JS until a JS hook is saved, and
      without it no page of the site connects.
    * `"recompile"` (activate / unarchive) → `BootHandler.compile_site/2`
    * `"rehost"` (a new host) → unload the site's modules, which are compiled for its host
      (`SiteRuntime.unload_modules/2`) → `BootHandler.compile_site/2`
    * `"purge"` (deactivate / archive) → `SiteRuntime.purge_parts/3` (keep templates)
    * `"rename"` → purge under the OLD name (drop templates) → recompile under the new name

  The child DB rows still exist here (only permanent-delete removes them), so the
  module list is streamed at run time via `SiteRuntime.module_specs/1`.

  ## Events

    * `"provision"` fires `ensure_auth/1`'s own, `runtime:site:before_auth_pages` and
      `runtime:site:after_auth_pages`.
    * Every other transition fires `runtime:site:before_rebuild` and `runtime:site:after_rebuild`,
      with `%{site_id: site_id, site_name: site_name, transition: transition}`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  require Logger

  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.Handlers.{SiteRuntime, BootHandler}
  alias MishkaCmsCore.Runtime.States.SiteState

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"transition" => "provision", "site_id" => site_id}}) do
    with {:ok, _auth} <- StarterContent.ensure_auth(site_id),
         :ok <- starter(site_id) do
      build_js(site_id)
    else
      {:error, :site_not_found} -> {:cancel, :site_not_found}
    end
  end

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

  defp starter(site_id) do
    case StarterContent.seed(site_id) do
      {:ok, _report} ->
        :ok

      {:error, :site_not_found} = gone ->
        gone

      {:error, reason} ->
        Logger.warning(
          "[SiteRuntimeWorker] no starter content for #{site_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp build_js(site_id) do
    case SiteState.get!(site_id) do
      %{name: site_name} -> site_name |> BootHandler.asset_job(site_id, "js") |> Oban.insert()
      nil -> :ok
    end

    :ok
  end

  defp dispatch("recompile", site_id, site_name, _old_name) do
    BootHandler.compile_site(site_id, site_name)
  end

  defp dispatch("rehost", site_id, site_name, _old_name) do
    SiteRuntime.unload_modules(site_name, SiteRuntime.module_specs(site_id))
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
