# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.TeardownTestSeed do
  @moduledoc """
  Disposable dev fixture for verifying the Site permanent-delete teardown
  (`MishkaCmsCore.Runtime.Workers.SiteTeardownWorker`).

  It builds a throwaway site `teardown-test` whose layout, error page, pages and
  components are all `precompile: true`, so their runtime modules are compiled
  into memory — giving the teardown something real to free. Your normal seeded
  sites (e.g. `localhost`) are the untouched control.

  Built on `MishkaCmsCore.Dev.Generator`, the same generators the dev seeds use.

  ## How to run

  Run inside a live server so Oban actually compiles the modules:

      iex -S mix phx.server

      # 1. create the fixture — returns the site + its loaded module names
      %{modules: mods} = MishkaCmsCore.Dev.TeardownTestSeed.create()

      # 2. confirm the modules are in RAM — every entry should be {_, true}
      MishkaCmsCore.Dev.TeardownTestSeed.module_status(mods)

      # 3a. realistic path: in the admin, ARCHIVE then PERMANENTLY DELETE
      #     `teardown-test` (master user). Archiving keeps RAM; permanent-delete
      #     frees it.
      #
      # 3b. or skip the UI entirely:
      MishkaCmsCore.Dev.TeardownTestSeed.destroy()

      # 4. confirm RAM was freed — every entry should now be {_, false}
      MishkaCmsCore.Dev.TeardownTestSeed.module_status(mods)

  `true -> still true after archive -> false after permanent-delete` proves the
  teardown frees live RAM. The teardown also wipes the site's cached CSS/JS and
  routing; see the `[SiteTeardownWorker] purged ...` log line.

  Re-running `create/0` while the fixture still exists raises; call `destroy/0`
  (or delete it in the admin) first.
  """

  import MishkaCmsCore.Dev.Generator
  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.SiteRuntime
  alias MishkaCmsCore.Runtime.States.SiteState

  @name "teardown-test"

  @doc """
  Creates the `teardown-test` site with precompiled content, waits for the
  runtime modules to compile, and returns `%{site: site, modules: [module]}`.
  """
  def create do
    if exists?(), do: raise("Site #{inspect(@name)} already exists — run destroy/0 first.")

    site =
      [
        name: @name,
        host: "#{@name}.com",
        mode: "hybrid",
        active: true,
        priority: 0,
        allowed_origins: []
      ]
      |> site()
      |> Ash.Generator.generate()

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: true
    })

    layout =
      [name: "tt-layout", precompile: true, active: true]
      |> dev_layout_with_tenant(site.id)
      |> Ash.Generator.generate()

    error =
      [name: "tt-error", precompile: true, active: true]
      |> dev_error_page(site.id)
      |> Ash.Generator.generate()

    pages =
      for i <- 1..3 do
        [
          name: "tt-page-#{i}",
          title: "tt-page-#{i}",
          path: "/tt-#{i}",
          precompile: true,
          active: true,
          layout_id: layout.id,
          site_id: site.id
        ]
        |> page(site.id)
        |> Ash.Generator.generate()
      end

    components =
      for i <- 1..2 do
        [name: "tt-comp-#{i}", active: true]
        |> component(site.id)
        |> Ash.Generator.generate()
      end

    Process.sleep(4000)

    modules =
      Enum.map(pages, &Helpers.module_name(&1.id, @name, "Page")) ++
        [
          Helpers.module_name(layout.id, @name, "Layout"),
          Helpers.module_name(error.id, @name, "ErrorPage")
        ] ++
        Enum.map(components, &Helpers.module_name(&1.name, @name, "Component"))

    %{site: site, modules: modules}
  end

  @doc "Returns `[{module, loaded?}]` for the captured module list."
  def module_status(modules) do
    Enum.map(modules, &{&1, :erlang.module_loaded(&1)})
  end

  @doc """
  Recomputes the current module names from the DB under the site's current name.
  Use after `rename/1` (the names captured by `create/0` point at the old name).
  Returns `[]` when the fixture is absent.
  """
  def modules do
    case site_record() do
      nil ->
        []

      site ->
        site.id
        |> SiteRuntime.module_specs()
        |> Enum.map(fn %{"type" => type, "key" => key} ->
          Helpers.module_name(key, site.name, type)
        end)
    end
  end

  @doc "Deactivates the fixture site — purges its parts. Returns `:ok` / `:not_found`."
  def deactivate, do: update_site(:deactivate, %{})

  @doc "Activates the fixture site — recompiles its parts. Returns `:ok` / `:not_found`."
  def activate, do: update_site(:activate, %{})

  @doc """
  Renames the fixture site to `new_name` — purges the old-name parts and
  recompiles under the new name. Returns `:ok` / `:not_found`.
  """
  def rename(new_name), do: update_site(:update, %{name: new_name})

  defp update_site(action, params) do
    case site_record() do
      nil ->
        :not_found

      site ->
        site
        |> Ash.Changeset.for_update(action, params, authorize?: false)
        |> Ash.update!()

        :ok
    end
  end

  @doc """
  Permanently deletes the `teardown-test` site (cascade), triggering the
  teardown — a shortcut for the admin archive + permanent-delete flow. Returns
  `:ok`, or `:not_found` when the active fixture is absent.
  """
  def destroy do
    case site_record() do
      nil ->
        :not_found

      site ->
        Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
        :ok
    end
  end

  defp exists?, do: site_record() != nil

  defp site_record do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(name == ^@name)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end
end
