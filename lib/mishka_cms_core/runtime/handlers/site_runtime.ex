# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.SiteRuntime do
  @moduledoc """
  Shared per-site purge of runtime artifacts — compiled modules, cached CSS/JS,
  routing entries, and on-disk templates. Used by both the permanent-delete
  teardown (`MishkaCmsCore.Runtime.Workers.SiteTeardownWorker`) and the
  activate/deactivate/rename worker (`MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker`).

  Recompilation (the other direction) is `BootHandler.compile_site/2`.
  """
  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.{ModuleCompiler, Helpers}
  alias MishkaCmsCore.Runtime.States.{AssetsState, WebRunTimeMetaDataState}

  # The resources that compile into their own BEAM module (the only ones to
  # unload). JsHook/Stylesheet have no per-record module — they live in the
  # site's JS/CSS bundles, freed by `AssetsState.delete_by_site`.
  @module_resources [
    {MishkaCmsCore.Runtime.Page, :id, "Page"},
    {MishkaCmsCore.Runtime.Layout, :id, "Layout"},
    {MishkaCmsCore.Runtime.ErrorPage, :id, "ErrorPage"},
    {MishkaCmsCore.Runtime.Component, :name, "Component"}
  ]

  @doc """
  Streams the site's module-backed records and returns `[%{"type", "key"}]` — the
  inputs to `Helpers.module_name/3`. Call while the rows still exist (for the
  permanent-delete teardown, capture before the cascade).
  """
  def module_specs(site_id) do
    Enum.flat_map(@module_resources, fn {resource, key, type} ->
      resource
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.filter(site_id == ^site_id)
      |> Ash.stream!(authorize?: false)
      |> Enum.map(fn record -> %{"type" => type, "key" => to_string(Map.get(record, key))} end)
    end)
  end

  @doc """
  Frees a site's runtime artifacts from RAM, all keyed by `site_name`: unloads the
  given module specs, drops the cached CSS/JS (`AssetsState`), and clears routing
  (`WebRunTimeMetaDataState`). When `remove_templates?` is true (rename /
  permanent-delete) the site's on-disk template dir is removed too. Returns the
  counts; `:modules` is how many were actually loaded (and thus genuinely freed).
  """
  def purge_parts(site_name, module_specs, remove_templates?) do
    MishkaInstaller.Event.Hook.call(
      "runtime:site:before_purge",
      %{site_name: site_name, remove_templates?: remove_templates?},
      return: false
    )

    unloaded = unload_modules(site_name, module_specs)
    assets = AssetsState.delete_by_site(site_name)
    :ok = Helpers.forget_asset_builds(site_name)
    routes = WebRunTimeMetaDataState.delete_by_site(site_name)

    if remove_templates? do
      File.rm_rf(MishkaCmsCore.Runtime.Helpers.static_temp_dir(["runtime", site_name]))
    end

    result = %{modules: unloaded, assets: assets, routes: routes}

    MishkaInstaller.Event.Hook.call(
      "runtime:site:after_purge",
      Map.put(result, :site_name, site_name),
      return: false
    )

    result
  end

  @doc """
  Unloads the given module specs of the site `site_name`, and nothing else — its cached CSS/JS,
  routing and templates stay. Returns how many were loaded. A module is compiled for its site's
  name and host, so a new host needs new ones: `BootHandler.compile_site/2` builds them again, and
  a lazy one is built by the first request for it.
  """
  def unload_modules(site_name, module_specs) do
    Enum.count(module_specs, fn %{"type" => type, "key" => key} ->
      module = Helpers.module_name(key, site_name, type)
      loaded? = Helpers.loaded?(module)
      ModuleCompiler.unload(module)
      loaded?
    end)
  end
end
