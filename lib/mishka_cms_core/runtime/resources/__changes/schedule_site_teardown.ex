defmodule MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteTeardown do
  @moduledoc """
  Schedules the background teardown of a site's in-memory artifacts on
  `:permanent_destroy`.

  A site's compiled modules and asset names are keyed by the site name, and its
  child rows (pages/layouts/error pages/components) are removed by `ON DELETE
  CASCADE` the moment the site row is deleted — bypassing Ash, so no per-record
  job fires. This change therefore captures the module-backed record keys
  **before** the delete, and on success closes the request gate
  (`SiteState.delete/1`) and enqueues `SiteTeardownWorker` to purge the rest.

  It sets `defer_runtime: true` so the generic `SendToOban` change skips the site
  destroy job — teardown fully owns the permanent-delete path.

  See `MishkaCmsCore.Runtime.Workers.SiteTeardownWorker` and
  `MishkaCmsCore.Runtime.Resources.Changes.SendToOban`.
  """
  use Ash.Resource.Change

  alias MishkaCmsCore.Runtime.Handlers.SiteRuntime
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.SiteTeardownWorker

  @impl true
  def change(changeset, _opts, _context) do
    site = changeset.data
    modules = SiteRuntime.module_specs(site.id)

    changeset
    |> Ash.Changeset.set_context(%{defer_runtime: true})
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      if match?({:ok, _}, result) or result == :ok, do: finalize(site, modules)
      result
    end)
  end

  defp finalize(site, modules) do
    SiteState.delete(site.id)

    if !Application.get_env(:mishka_cms_core, :env_test?, false) do
      %{"site_id" => site.id, "site_name" => site.name, "modules" => modules}
      |> SiteTeardownWorker.new()
      |> Oban.insert()
    end
  end
end
