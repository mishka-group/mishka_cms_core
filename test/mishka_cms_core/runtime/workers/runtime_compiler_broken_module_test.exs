# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.RuntimeCompilerBrokenModuleTest do
  @moduledoc """
  A page, a layout or an error page that failed to compile on a request is tried again once it is
  saved, switched on, or its site is, though nothing precompiles it.

  `async: false`: `SiteState`, the routing table and `CompileFailureState` are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.Resources.Changes.SendToOban
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Runtime.Workers.{RuntimeCompilerWorker, SiteRuntimeWorker}

  @moduletag :capture_log

  @broken "<p>{no_such_function(1)}</p>"
  @fixed "<p>fixed</p>"

  setup do
    host = "broken-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: 0,
        active: true
      })

    on_exit(fn ->
      SiteState.delete(site.id)
      WebRunTimeMetaDataState.delete_by_site(site.name)
    end)

    {:ok, site: site}
  end

  # A page's own save refuses code that does not compile, and an error page's, so it is stored behind
  # its back.
  defp broken!("Page", site) do
    [site_id: site.id, precompile: false]
    |> create_page!()
    |> Ash.Seed.update!(%{template: @broken})
  end

  defp broken!("Layout", site),
    do: create_layout!(site_id: site.id, precompile: false, template: @broken)

  defp broken!("ErrorPage", site) do
    [site_id: site.id, precompile: false]
    |> create_error_page!()
    |> Ash.Seed.update!(%{error_pages: [%{status: 404, template: @broken}]})
  end

  defp fixed("ErrorPage"), do: %{error_pages: [%{status: 404, template: @fixed}]}
  defp fixed(_type), do: %{template: @fixed}

  defp saved!(record, attrs, site) do
    changeset =
      Ash.Changeset.for_update(record, :update, attrs, tenant: site.id, authorize?: false)

    updated = Ash.update!(changeset)
    built(changeset, updated)
    updated
  end

  # The job the save queues, run.
  defp built(changeset, record) do
    args = changeset |> SendToOban.build_job_args(record) |> Jason.encode!() |> Jason.decode!()
    RuntimeCompilerWorker.perform(%Oban.Job{args: args, inserted_at: DateTime.utc_now()})
  end

  defp requested(record, type, site) do
    record
    |> module(type, site)
    |> ModuleCompilerHandler.compile_or_return_module(record.path, site.name, site.id)
  end

  defp module(record, type, site) do
    module = Helpers.module_name(record.id, site.name, type)

    on_exit(fn ->
      CompileFailureState.clear(module)
      ModuleCompiler.unload(module)
    end)

    module
  end

  defp transition(site, name) do
    SiteRuntimeWorker.perform(%Oban.Job{
      args: %{
        "transition" => name,
        "site_id" => site.id,
        "site_name" => site.name,
        "old_name" => site.name
      }
    })
  end

  for type <- ["Page", "Layout", "ErrorPage"] do
    describe "#{type}" do
      test "fixed, is compiled by the next request", %{site: site} do
        record = broken!(unquote(type), site)

        for _request <- [:compiles, :known_broken],
            do: assert({:error, _reason} = requested(record, unquote(type), site))

        record = saved!(record, fixed(unquote(type)), site)

        assert {:ok, module} = requested(record, unquote(type), site)
        assert Helpers.loaded?(module)
      end

      test "fixed while it is switched off, is compiled once it is on", %{site: site} do
        record = broken!(unquote(type), site)
        assert {:error, _reason} = requested(record, unquote(type), site)

        record = saved!(record, Map.put(fixed(unquote(type)), :active, false), site)
        record = saved!(record, %{active: true}, site)

        assert {:ok, _module} = requested(record, unquote(type), site)
      end

      test "fixed while its site is switched off, is compiled once the site is on", %{site: site} do
        record = broken!(unquote(type), site)
        assert {:error, _reason} = requested(record, unquote(type), site)

        assert :ok = transition(site, "purge")
        cached = SiteState.get!(site.id)
        :ok = SiteState.save(%{cached | active: false})
        record = saved!(record, fixed(unquote(type)), site)
        :ok = SiteState.save(%{cached | active: true})
        assert :ok = transition(site, "recompile")

        assert {:ok, _module} = requested(record, unquote(type), site)
      end

      test "saved still broken, is known as broken again by the next request", %{site: site} do
        record = broken!(unquote(type), site)
        assert {:error, _reason} = requested(record, unquote(type), site)
        record = saved!(record, %{priority: 7}, site)
        assert {:error, reason} = requested(record, unquote(type), site)

        assert CompileFailureState.reason(module(record, unquote(type), site)) == reason
      end
    end
  end
end
