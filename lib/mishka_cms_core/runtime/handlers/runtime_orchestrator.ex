defmodule MishkaCmsCore.Runtime.Handlers.RuntimeOrchestrator do
  @moduledoc """
  Central rebuild coordinator for the runtime pipeline.

  Single-resource edits flow through `SendToOban` → `RuntimeCompilerWorker`,
  which already debounces/dedups per-site asset jobs. This module owns the
  OTHER path: a **bulk** write (e.g. the UI-kit installer inserts hundreds of
  rows in one transaction with `defer_runtime: true`) that must rebuild the
  runtime **once** for the final result instead of per row.

  `sync_after_bulk/1` rebuilds from the DB using the same steps boot uses:

    1. component templates + modules (`BootHandler.compile_components/0`)
    2. JS-hook templates (`BootHandler.create_js_hooks_template/0`)
    3. stylesheet load (`BootHandler.load_stylesheets/0`)
    4. for a global change: drop + rebuild the shared base once
    5. fan out per-site asset jobs (unique + debounced)

  Step 4 precedes 5 so every site recompiles against a fresh shared base
  (avoids the stale/partial-base bug). Asset jobs are deduped in
  `BootHandler.asset_job/4`, so the fan-out can never storm.

  No-op under `config :mishka_cms_core, env_test?: true` so tests stay fast and
  don't depend on a populated `AssetsState`.

  See `MishkaCmsCore.Runtime.Handlers.BootHandler` and
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler`.
  """

  require Logger

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Compilers.{TailwindCompiler, JavaScriptCompiler}

  @default_kinds [:component, :js_hook, :stylesheet]

  @doc """
  Rebuild the runtime once after a deferred bulk write.

  ## Options

    * `:scope` — `:global` (default) rebuilds the shared base and fans out to
      every active site; `{:site, site_id}` scopes the rebuild to one site.
    * `:kinds` — which resource kinds were touched (default
      `#{inspect(@default_kinds)}`); limits which build steps run.
  """
  @spec sync_after_bulk(keyword()) :: :ok
  def sync_after_bulk(opts \\ []) do
    if Application.get_env(:mishka_cms_core, :env_test?, false) do
      :ok
    else
      do_sync_after_bulk(opts)
    end
  end

  defp do_sync_after_bulk(opts) do
    scope = Keyword.get(opts, :scope, :global)
    kinds = Keyword.get(opts, :kinds, @default_kinds)

    MishkaInstaller.Event.Hook.call("runtime:before_bulk_sync", %{scope: scope, kinds: kinds},
      return: false
    )

    if :component in kinds, do: BootHandler.compile_components()
    if :js_hook in kinds, do: BootHandler.create_js_hooks_template()
    if :stylesheet in kinds, do: BootHandler.load_stylesheets()

    rebuild_assets(scope)

    MishkaInstaller.Event.Hook.call("runtime:after_bulk_sync", %{scope: scope, kinds: kinds},
      return: false
    )

    Logger.info("[RuntimeOrchestrator] bulk sync complete (scope: #{inspect(scope)})")
    :ok
  end

  defp rebuild_assets(:global) do
    TailwindCompiler.delete_shared_base_css()
    TailwindCompiler.compile_and_store_shared_base()
    JavaScriptCompiler.delete_shared_base_js()
    BootHandler.create_assets_compilation_jobs("asset")
  end

  defp rebuild_assets({:site, _site_id}) do
    BootHandler.create_assets_compilation_jobs("asset")
  end
end
