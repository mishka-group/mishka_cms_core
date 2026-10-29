# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.SupervisionTest do
  @moduledoc """
  What the core starts itself and what it hands the host. `MishkaCmsCore.Application` starts
  `MishkaCmsCore.PubSub` (no test helper or host starts it), and `MishkaCmsCore.Supervision` lists
  the rest in the three phases a host places around its repo and endpoint — which this suite's
  harness starts exactly as a host does.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Handlers
  alias MishkaCmsCore.Runtime.PageBuilder.BuilderPlugins
  alias MishkaCmsCore.Runtime.States
  alias MishkaCmsCore.Supervision

  describe "MishkaCmsCore.PubSub" do
    # `Phoenix.PubSub` registers its registry under the name and supervises it, with its adapter,
    # under `<name>.Supervisor` — the process a parent supervisor holds.
    test "is started by the core's application, not by the test harness" do
      assert is_pid(Process.whereis(MishkaCmsCore.PubSub))

      pubsub = Process.whereis(MishkaCmsCore.PubSub.Supervisor)

      assert pubsub in pids_of(MishkaCmsCore.Supervisor)
      refute pubsub in pids_of(MishkaCmsCore.TestSupervisor)
    end
  end

  describe "children/1" do
    test ":caches lists the request caches, in start order" do
      assert Supervision.children(:caches) == [
               States.SiteState,
               States.SettingsState,
               States.TranslationsState,
               States.RedirectsState,
               States.ViewerState,
               States.RateLimitState
             ]
    end

    test ":engine lists the metadata states and the runtime compiler, in start order" do
      assert Enum.map(Supervision.children(:engine), &id/1) == [
               States.WebRunTimeMetaDataState,
               States.AssetsState,
               States.CompileFailureState,
               Handlers.CompileGate,
               MishkaCms.ModuleCompilerHandlerRegistry,
               Handlers.ModuleCompilerHandlerPartition,
               MishkaCmsCore.Runtime.TaskSupervisor
             ]
    end

    test ":boot is empty in a test run and BootHandler otherwise" do
      assert Supervision.children(:boot) == []

      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

      assert Supervision.children(:boot) == [Handlers.BootHandler]
    end

    test "every child is a valid child spec, and no two phases share an id" do
      ids = Enum.flat_map([:caches, :engine], &Supervision.children/1) |> Enum.map(&id/1)

      assert ids == Enum.uniq(ids)
    end

    test "the harness runs :caches and :engine, as a host does" do
      running = ids_of(MishkaCmsCore.TestSupervisor)

      for child <- Supervision.children(:caches) ++ Supervision.children(:engine) do
        assert id(child) in running, "#{inspect(id(child))} is not supervised"
      end
    end
  end

  describe "the editor's processes" do
    test "run under the core's application" do
      ids = ids_of(MishkaCmsCore.Supervisor)

      for child <- BuilderPlugins.children() do
        assert child in ids, "#{inspect(child)} is not supervised by the core's application"
      end
    end
  end

  defp ids_of(supervisor),
    do: for({id, _pid, _type, _modules} <- Supervisor.which_children(supervisor), do: id)

  defp pids_of(supervisor),
    do: for({_id, pid, _type, _modules} <- Supervisor.which_children(supervisor), do: pid)

  defp id(child), do: Supervisor.child_spec(child, []).id
end
