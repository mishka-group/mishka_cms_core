# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.CompileOnceTest do
  # ONE COMPILE PER PAGE, HOWEVER MANY ASK FOR IT. After a restart every page is cold, and the
  # visitors who arrive before a page is built must all be answered by its one compile — while the
  # gate is busy, while it is compiling, when the visitor who started it is gone, and when the page
  # changed and many open copies of it ask for it again.
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.Handlers.{CompileGate, ModuleCompilerHandler}
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  @registry MishkaCms.ModuleCompilerHandlerRegistry
  @compiling [:mishka_cms, :runtime, :handlers, :database_to_ast, :page, :start]

  # Every compile of a page reads its row first; the handler runs in the process that compiles.
  def compiling(_event, _measurements, %{path: path}, %{test: test, paths: paths, hold?: hold?}) do
    if path in paths do
      send(test, {:compiling, path, self()})
      if hold?, do: receive(do: (:go -> :ok), after: (15_000 -> :ok))
    end
  end

  test "a restart with every slot busy: 4,500 visitors on three sites' cold pages, one compile each" do
    pages = for _ <- 1..3, do: cold_page!()
    watch_compiles(pages, hold?: false)

    limit = :sys.get_state(CompileGate).limit

    blockers =
      for _ <- 1..limit, do: spawn(fn -> CompileGate.run(fn -> receive do: (:go -> :ok) end) end)

    on_exit(fn -> Enum.each(blockers, &send(&1, :go)) end)
    wait_until(fn -> Enum.all?(blockers, &holding?/1) end)

    visitors =
      for page <- pages, _ <- 1..1_500 do
        {page, Task.async(fn -> visit(page) end)}
      end

    workers = for page <- pages, do: worker_with_waiters!(page, 1_500)
    wait_until(fn -> Enum.all?(workers, &(&1 in queued())) end)

    # One place in the gate's queue per page, and no visitor in the queue or holding a slot.
    visitor_pids = MapSet.new(visitors, fn {_page, task} -> task.pid end)
    gate = :sys.get_state(CompileGate)
    assert Enum.count(queued(), &(&1 in workers)) == 3
    refute Enum.any?(queued() ++ Map.keys(gate.holders), &MapSet.member?(visitor_pids, &1))

    blockers |> hd() |> send(:go)

    for {page, task} <- visitors do
      assert Task.await(task, 30_000) == {:ok, page.module}
    end

    for page <- pages, do: assert(compiles(page) == 1)
  end

  test "visitors who come while it compiles wait for that compile, even when its starter is gone" do
    page = cold_page!()
    watch_compiles([page], hold?: true)

    starter = spawn(fn -> visit(page) end)
    assert_receive {:compiling, path, compile}, 5_000
    assert path == page.path

    late = for _ <- 1..500, do: Task.async(fn -> visit(page) end)
    worker = worker_with_waiters!(page, 501)

    Process.exit(starter, :kill)
    send(compile, :go)

    # Well before the minute a worker may take, so nobody waited for the starter to come back.
    assert Task.await_many(late, 5_000) |> Enum.uniq() == [{:ok, page.module}]
    assert compiles(page) == 0, "a compile besides the one they waited for"
    refute Process.alive?(worker)
  end

  test "three sites' pages: those who come halfway through a compile share it with those before" do
    pages = for _ <- 1..3, do: cold_page!()
    watch_compiles(pages, hold?: true)

    first = for page <- pages, _ <- 1..10, do: {page, Task.async(fn -> visit(page) end)}
    workers = for page <- pages, do: worker_with_waiters!(page, 10)

    # Halfway: as many of the three compiles as the gate has slots for are held inside the compile.
    running = for _ <- 1..min(3, :sys.get_state(CompileGate).limit), do: next_compile!()

    late = for page <- pages, _ <- 1..20, do: {page, Task.async(fn -> visit(page) end)}
    assert workers == for(page <- pages, do: worker_with_waiters!(page, 30))

    Enum.each(running, &send(&1, :go))
    for _ <- 1..(3 - length(running))//1, do: send(next_compile!(), :go)

    for {page, task} <- first ++ late do
      assert Task.await(task, 5_000) == {:ok, page.module}
    end

    for page <- pages, do: assert(compiles(page) == 0, "a second compile of #{page.path}")
  end

  test "a changed page open in many places is compiled again once more, not once per viewer" do
    page = cold_page!()
    assert visit(page) == {:ok, page.module}
    watch_compiles([page], hold?: true)

    first_viewer = Task.async(fn -> visit(page, :update) end)
    assert_receive {:compiling, _path, first}, 5_000

    # They ask while that compile runs: it may have read the page before the change.
    viewers = for _ <- 1..199, do: Task.async(fn -> visit(page, :update) end)
    first_worker = worker_with_waiters!(page, 200)
    send(first, :go)

    # The next one, started after they asked, is the one they all take.
    assert_receive {:compiling, _path, second}, 5_000
    second_worker = worker_with_waiters!(page, 199)
    assert second_worker != first_worker
    send(second, :go)

    assert Task.await_many([first_viewer | viewers], 5_000) |> Enum.uniq() == [{:ok, page.module}]
    assert compiles(page) == 0, "a compile besides those two"
  end

  test "a worker that starts after the page was built does not build it again" do
    page = cold_page!()
    watch_compiles([page], hold?: false)
    assert visit(page) == {:ok, page.module}
    assert compiles(page) == 1

    {:ok, worker} =
      DynamicSupervisor.start_child(
        ModuleCompilerHandler.get_dynamic_supervisor_key(),
        ModuleCompilerHandler.child_spec({page.module, page.path, page.site, page.site_id, :new})
      )

    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
    assert compiles(page) == 0
  end

  defp cold_page! do
    site = create_site!()
    n = System.unique_integer([:positive])

    page =
      create_page!(
        site_id: site.id,
        name: "cold-#{n}",
        path: "/cold-#{n}",
        template: ~S(<div id="cold">cold</div>)
      )

    module = Helpers.module_name(page.id, site.name, "Page")

    on_exit(fn ->
      ModuleCompiler.unload(module)
      CompileFailureState.clear(module)
    end)

    refute Helpers.loaded?(module)
    %{module: module, path: page.path, site: site.name, site_id: site.id}
  end

  defp visit(page, type \\ :new),
    do:
      ModuleCompilerHandler.compile_or_return_module(
        page.module,
        page.path,
        page.site,
        page.site_id,
        type
      )

  defp watch_compiles(pages, hold?: hold?) do
    id = "compile-once-#{System.unique_integer([:positive])}"
    config = %{test: self(), paths: Enum.map(pages, & &1.path), hold?: hold?}
    :ok = :telemetry.attach(id, @compiling, &__MODULE__.compiling/4, config)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # The page's worker, once `count` callers are waiting for it.
  defp worker_with_waiters!(page, count) do
    wait_until(fn ->
      case Registry.lookup(@registry, page.module) do
        [{pid, _}] -> waiters(pid) >= count
        [] -> false
      end
    end)

    [{pid, _}] = Registry.lookup(@registry, page.module)
    pid
  end

  defp waiters(pid) do
    case Process.info(pid, :monitored_by) do
      {:monitored_by, by} -> Enum.count(by, &is_pid/1)
      nil -> 0
    end
  end

  defp next_compile! do
    assert_receive {:compiling, _path, compile}, 5_000
    compile
  end

  defp holding?(pid), do: Map.has_key?(:sys.get_state(CompileGate).holders, pid)

  defp queued,
    do: for({pid, _tag} <- :queue.to_list(:sys.get_state(CompileGate).waiting), do: pid)

  # How many compiles of the page have started since it was last asked.
  defp compiles(page, count \\ 0) do
    path = page.path

    receive do
      {:compiling, ^path, _compile} -> compiles(page, count + 1)
    after
      0 -> count
    end
  end

  defp wait_until(fun, tries \\ 1_000) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("the processes never reached that state")

      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end
end
