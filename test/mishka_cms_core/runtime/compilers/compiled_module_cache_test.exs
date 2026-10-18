# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.CompiledModuleCacheTest do
  # NOT ASYNC: the cache is configured through the application environment, which every compile on
  # the node reads, and a build is swapped in `:persistent_term` by one test. ExUnit runs the modules
  # that are not async one at a time, after the async ones, so no other test compiles meanwhile.
  use MishkaCmsCore.DataCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Compilers.{
    CompiledModuleCache,
    ComponentCompiler,
    Helpers,
    ModuleCompiler
  }

  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  @endpoint MishkaCmsCore.TestEndpoint
  @moduletag :tmp_dir

  @span [:mishka_cms, :runtime, :compilers, :module]
  @generation {CompiledModuleCache, :generation}

  @counter """
  <div id={@id} {@rest} data-role="counter">
    <span data-role="count">{@count}</span>
    <button type="button" phx-click="bump" phx-target={@myself}>more</button>
  </div>
  """

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket),
      do: {:ok, Phoenix.Component.assign(socket, :mod, session["mod"])}

    def render(assigns) do
      ~H"""
      <div id="host">
        <.live_component module={@mod} id="counter-one" />
      </div>
      """
    end
  end

  def handle_span(event, _measurements, metadata, %{test: test}),
    do: send(test, {:span, List.last(event), metadata})

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env(:mishka_cms_core, :compiled_module_cache)
    Application.delete_env(:mishka_cms_core, :compiled_module_cache)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mishka_cms_core, :compiled_module_cache, value)
        :error -> Application.delete_env(:mishka_cms_core, :compiled_module_cache)
      end
    end)

    %{dir: Path.join(tmp_dir, "cache")}
  end

  describe "off" do
    test "with nothing configured a module is compiled, and the cache does nothing but look" do
      module = probe()
      watch_compiles()

      {result, calls} =
        traced({CompiledModuleCache, :_, :_}, [:local], fn ->
          ModuleCompiler.compile_module(quoted(module, 1), "nofile", cache: true)
        end)

      assert {:ok, ^module, _diagnostics} = result
      assert module.value() == 1
      assert Enum.uniq(calls) == [{CompiledModuleCache, :dir, 0}]
      assert [stop] = stops()
      assert Map.delete(stop, :telemetry_span_context) == %{}
    end

    test "with `dir: nil`, and when unloading, nothing is hashed, read or written" do
      Application.put_env(:mishka_cms_core, :compiled_module_cache, dir: nil)
      module = probe()

      {result, calls} =
        traced({CompiledModuleCache, :_, :_}, [:local], fn ->
          result = ModuleCompiler.compile_module(quoted(module, 1), "nofile", cache: true)
          ModuleCompiler.unload(module)
          result
        end)

      assert {:ok, ^module, _diagnostics} = result

      assert calls |> Enum.uniq() |> Enum.sort() == [
               {CompiledModuleCache, :dir, 0},
               {CompiledModuleCache, :forget, 1},
               {CompiledModuleCache, :present, 1}
             ]
    end

    test "a compile that does not ask for it never reaches it, even when it is configured", %{
      dir: dir
    } do
      cache_on(dir)
      module = probe()

      {result, calls} =
        traced({CompiledModuleCache, :_, :_}, [:local], fn ->
          ModuleCompiler.compile_module(quoted(module, 1))
        end)

      assert {:ok, ^module, _diagnostics} = result
      assert calls == []
      refute File.exists?(dir)
    end
  end

  describe "a module compiled once" do
    test "is loaded from its file the next time, without calling the compiler", %{dir: dir} do
      cache_on(dir)
      module = probe()
      ast = quoted(module, 41)
      watch_compiles()

      {first, compiled} = traced({:elixir_compiler, :quoted, 3}, [], fn -> compile(ast) end)
      assert {:ok, ^module, _diagnostics} = first
      assert length(compiled) == 1
      assert [%{cache: :miss, module: ^module}] = stops()
      md5 = module.module_info(:md5)

      restart(module)

      {second, compiled} = traced({:elixir_compiler, :quoted, 3}, [], fn -> compile(ast) end)
      assert second == {:ok, module, []}
      assert compiled == []
      assert [%{cache: :hit, module: ^module}] = stops()
      assert module.value() == 41
      assert module.module_info(:md5) == md5
    end

    test "is written privately, one file per module", %{dir: dir} do
      cache_on(dir)
      module = probe()
      {:ok, ^module, _diagnostics} = compile(quoted(module, 1))
      {:ok, entry} = CompiledModuleCache.entry(dir, module, "nofile", quoted(module, 1))

      assert mode(dir) == 0o700
      assert mode(Path.dirname(entry.folder)) == 0o700
      assert mode(entry.folder) == 0o700
      assert mode(entry.path) == 0o600
      assert File.ls!(entry.folder) == [Path.basename(entry.path)]
    end

    test "a stateful component from its file is the same component", %{dir: dir} do
      cache_on(dir)
      watch_compiles()

      component =
        create_component!(
          name: "cached-counter-#{System.unique_integer([:positive])}",
          stateful: true,
          active: true,
          precompile: false,
          template: @counter,
          attrs: [%{"name" => "rest", "type" => "global", "opts" => %{}}],
          helpers: [
            %{
              name: "mount",
              args: "socket",
              code: "{:ok, Phoenix.Component.assign(socket, :count, 0)}"
            },
            %{
              name: "handle_event",
              args: ~s|"bump", _params, socket|,
              code: "{:noreply, Phoenix.Component.update(socket, :count, &(&1 + 1))}"
            }
          ]
        )

      module = Helpers.module_name(component.name, nil, "Component")
      assert {:ok, ^module} = component_module(component)
      assert_receive {:span, :stop, %{cache: :miss, module: ^module}}
      md5 = module.module_info(:md5)

      restart(module)

      assert {:ok, ^module} = component_module(component)
      assert_receive {:span, :stop, %{cache: :hit, module: ^module}}
      refute_received {:span, :stop, %{cache: :miss, module: ^module}}
      assert module.module_info(:md5) == md5
      assert ComponentCompiler.check_root(module) == :ok
      assert module.__component_information__([:private, :stateful]) == true

      {:ok, view, _html} =
        live_isolated(Phoenix.ConnTest.build_conn(), Host, session: %{"mod" => module})

      assert count(view) == "0"
      view |> element("#counter-one button", "more") |> render_click()
      assert count(view) == "1"
    end

    test "a stateful component whose root fails the check fails it again from its file", %{
      dir: dir
    } do
      cache_on(dir)
      watch_compiles()

      component =
        create_component!(
          name: "cached-unrooted-#{System.unique_integer([:positive])}",
          stateful: true,
          active: true,
          precompile: false,
          template: ~S|<div :if={@id}>conditional root</div>|
        )

      module = Helpers.module_name(component.name, nil, "Component")
      assert {:error, {:compilation_error, why}} = component_module(component)
      assert_receive {:span, :stop, %{cache: :miss, module: ^module}}
      assert CompileFailureState.failed?(module)

      restart(module)
      CompileFailureState.clear(module)

      assert {:error, {:compilation_error, ^why}} = component_module(component)
      assert_receive {:span, :stop, %{cache: :hit, module: ^module}}
      assert CompileFailureState.failed?(module)
    end

    test "a crowd asking for it cold compiles it once, and after a restart loads it once", %{
      dir: dir
    } do
      cache_on(dir)
      page = cold_page!()
      watch_compiles()

      assert crowd(page, 200) == [{:ok, page.module}]
      assert outcomes(page.module) == [:miss]

      restart(page.module)

      assert crowd(page, 200) == [{:ok, page.module}]
      assert outcomes(page.module) == [:hit]

      {:ok, entry} = CompiledModuleCache.entry(dir, page.module, "nofile", page_ast(page))
      assert File.ls!(entry.folder) == [Path.basename(entry.path)]
    end
  end

  describe "the key" do
    test "follows the code, the module, the file name and the build" do
      digest = :crypto.hash(:sha256, "a build")
      key = CompiledModuleCache.key(Some.Module, "nofile", quoted(Some.Module, 1), digest)

      assert byte_size(key) == 32
      assert key == CompiledModuleCache.key(Some.Module, "nofile", quoted(Some.Module, 1), digest)
      refute key == CompiledModuleCache.key(Some.Module, "nofile", quoted(Some.Module, 2), digest)

      refute key ==
               CompiledModuleCache.key(Other.Module, "nofile", quoted(Some.Module, 1), digest)

      refute key == CompiledModuleCache.key(Some.Module, "other", quoted(Some.Module, 1), digest)

      refute key ==
               CompiledModuleCache.key(
                 Some.Module,
                 "nofile",
                 quoted(Some.Module, 1),
                 :crypto.hash(:sha256, "another build")
               )
    end

    # HEEx READS ITS CHANGE CHECKS OUT OF A MAP, and a map of more than 32 assigns is read in an
    # order of the node's own — so a big template's checks, and the fingerprint hashed from them,
    # come out in another order after a restart.
    test "is the same for HEEx's change checks in another order, under another fingerprint" do
      digest = :crypto.hash(:sha256, "a build")
      key = &CompiledModuleCache.key(Some.Module, "nofile", &1, digest)

      assert key.(rendered(checks([:a, :b, :c]), 11)) == key.(rendered(checks([:c, :a, :b]), 22))
      refute key.(rendered(checks([:a, :b, :c]), 11)) == key.(rendered(checks([:a, :b, :d]), 11))

      refute key.(quote(do: first() or second())) == key.(quote(do: second() or first())),
             "an `or` of anything else keeps its order"

      refute key.(rendered(checks([:a]), 1, ["one"])) == key.(rendered(checks([:a]), 1, ["two"]))
      assert CompiledModuleCache.canonical([1 | 2]) == [1 | 2]
    end

    test "of a page changes with its row, and the old file goes", %{dir: dir} do
      cache_on(dir)
      page = cold_page!()
      watch_compiles()

      assert visit(page) == {:ok, page.module}
      assert outcomes(page.module) == [:miss]
      {:ok, before} = CompiledModuleCache.entry(dir, page.module, "nofile", page_ast(page))

      update_page!(page.record, %{template: ~S(<div id="cold">changed</div>)})

      assert visit(page, :update) == {:ok, page.module}
      assert outcomes(page.module) == [:miss]
      {:ok, now} = CompiledModuleCache.entry(dir, page.module, "nofile", page_ast(page))

      refute now.key == before.key
      assert File.ls!(now.folder) == [Path.basename(now.path)]
    end

    test "of the same code under another build misses, and keeps that build's file", %{dir: dir} do
      cache_on(dir)
      module = probe()
      ast = quoted(module, 7)
      watch_compiles()

      {:ok, ^module, _diagnostics} = compile(ast)
      original = CompiledModuleCache.generation()
      {:ok, ours} = CompiledModuleCache.entry(dir, module, "nofile", ast)
      on_exit(fn -> :persistent_term.put(@generation, original) end)

      digest = :crypto.hash(:sha256, "another build")
      :persistent_term.put(@generation, %{id: hex(binary_part(digest, 0, 8)), digest: digest})
      restart(module)

      assert {:ok, ^module, _diagnostics} = compile(ast)
      {:ok, theirs} = CompiledModuleCache.entry(dir, module, "nofile", ast)
      refute theirs.path == ours.path
      assert File.exists?(theirs.path)

      :persistent_term.put(@generation, original)
      restart(module)

      assert compile(ast) == {:ok, module, []}
      assert [%{cache: :miss}, %{cache: :miss}, %{cache: :hit}] = stops()
    end
  end

  describe "a file that cannot be used" do
    setup %{dir: dir} do
      cache_on(dir)
      module = probe()
      ast = quoted(module, 3)
      {:ok, ^module, _diagnostics} = compile(ast)
      {:ok, entry} = CompiledModuleCache.entry(dir, module, "nofile", ast)
      %{module: module, ast: ast, entry: entry, good: File.read!(entry.path)}
    end

    test "is deleted, and the module compiled — truncated, flipped or not a beam at all", %{
      module: module,
      ast: ast,
      entry: entry,
      good: good
    } do
      half = div(byte_size(good), 2)
      <<head::binary-size(^half), byte, tail::binary>> = good

      watch_compiles()

      for bad <- [
            binary_part(good, 0, byte_size(good) - 3),
            binary_part(good, 0, half),
            <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>,
            :crypto.strong_rand_bytes(byte_size(good)),
            ""
          ] do
        File.write!(entry.path, bad)
        restart(module)

        assert capture_log(fn ->
                 assert CompiledModuleCache.load(entry, "nofile") == {:miss, :corrupt}
               end) =~ "could not be used (corrupt)"

        refute File.exists?(entry.path)
        refute Helpers.loaded?(module)

        File.write!(entry.path, bad)

        log = capture_log(fn -> assert {:ok, ^module, _diagnostics} = compile(ast) end)

        assert log =~ "could not be used (corrupt)"
        assert [%{cache: :miss}] = stops()
        assert module.value() == 3
        assert File.read!(entry.path) == good
      end
    end

    test "holding another module is refused", %{module: module, entry: entry} do
      other = probe()
      other_ast = quoted(other, :other)
      {:ok, ^other, _diagnostics} = compile(other_ast)
      {:ok, theirs} = CompiledModuleCache.entry(cache_dir(entry), other, "nofile", other_ast)

      File.cp!(theirs.path, entry.path)
      restart(module)
      restart(other)

      capture_log(fn ->
        assert CompiledModuleCache.load(entry, "nofile") == {:miss, :wrong_module}
      end)

      refute File.exists?(entry.path)
      refute Helpers.loaded?(module)
      refute Helpers.loaded?(other)
    end

    test "filed under another key — the module's file of another build — is refused", %{
      module: module,
      ast: ast,
      entry: entry,
      good: good
    } do
      digest = :crypto.hash(:sha256, "another build")
      key = CompiledModuleCache.key(module, "nofile", ast, digest)
      elsewhere = %{entry | key: key}

      File.write!(elsewhere.path, good)
      restart(module)

      capture_log(fn ->
        assert CompiledModuleCache.load(elsewhere, "nofile") == {:miss, :corrupt}
      end)

      refute Helpers.loaded?(module)
    end

    test "a file that cannot be written leaves the module compiled and says so", %{dir: dir} do
      module = probe()
      ast = quoted(module, 9)
      {:ok, entry} = CompiledModuleCache.entry(dir, module, "nofile", ast)
      File.write!(entry.folder, "a file where the module's folder goes")
      watch_compiles()

      log = capture_log(fn -> assert {:ok, ^module, _diagnostics} = compile(ast) end)

      assert log =~ "could not write"
      assert module.value() == 9
      assert [%{cache: :miss}] = stops()
    end

    test "a directory that cannot be made private is not used", %{tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "a-file")
      File.write!(blocker, "")
      cache_on(Path.join(blocker, "cache"))
      module = probe()
      watch_compiles()

      log =
        capture_log(fn -> assert {:ok, ^module, _diagnostics} = compile(quoted(module, 5)) end)

      assert log =~ "compiled-module cache is off"
      assert [stop] = stops()
      assert Map.delete(stop, :telemetry_span_context) == %{}
    end

    test "a compile that makes more than one module is not saved", %{dir: dir} do
      module = probe()
      inner = Module.concat(module, Inner)

      ast =
        quote do
          defmodule unquote(module) do
            defmodule unquote(inner) do
              def value, do: :inner
            end

            def value, do: unquote(inner).value()
          end
        end

      on_exit(fn -> restart(inner) end)
      assert {:ok, ^module, _diagnostics} = compile(ast)
      {:ok, entry} = CompiledModuleCache.entry(dir, module, "nofile", ast)
      refute File.exists?(entry.folder)
    end
  end

  describe "forgetting and sweeping" do
    test "unloading a module deletes its folder", %{dir: dir} do
      cache_on(dir)
      module = probe()
      ast = quoted(module, 1)
      {:ok, ^module, _diagnostics} = compile(ast)
      {:ok, entry} = CompiledModuleCache.entry(dir, module, "nofile", ast)
      assert File.exists?(entry.path)

      ModuleCompiler.unload(module)

      refute File.exists?(entry.folder)
      refute Helpers.loaded?(module)
    end

    test "only the folders of other builds idle for longer than the limit go", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "sweep")
      week = 7 * 86_400
      old = System.os_time(:second) - 2 * week

      stale = folder!(dir, "aaaaaaaaaaaaaaaa", old)
      current = folder!(dir, "bbbbbbbbbbbbbbbb", old)
      recent = folder!(dir, "cccccccccccccccc", System.os_time(:second))
      foreign = folder!(dir, "not-a-build", old)
      upper = folder!(dir, "DDDDDDDDDDDDDDDD", old)

      assert CompiledModuleCache.sweep(dir, "bbbbbbbbbbbbbbbb", week) == [stale]

      refute File.exists?(stale)
      assert File.exists?(current)
      assert File.exists?(recent)
      assert File.exists?(foreign)
      assert File.exists?(upper)
    end

    test "the first use of a directory sweeps it", %{dir: dir} do
      stale = folder!(dir, "eeeeeeeeeeeeeeee", System.os_time(:second) - 30 * 86_400)
      cache_on(dir)

      module = probe()
      {:ok, ^module, _diagnostics} = compile(quoted(module, 1))
      sweeps_done()

      refute File.exists?(stale)
    end
  end

  defp cache_on(dir), do: Application.put_env(:mishka_cms_core, :compiled_module_cache, dir: dir)

  defp compile(ast), do: ModuleCompiler.compile_module(ast, "nofile", cache: true)

  # A module named as the runtime names its own, so the suite's own clean-up unloads it too.
  defp probe do
    hash = hex(:crypto.strong_rand_bytes(16))
    module = Module.concat(["MishkaCmsCore.Runtime.#{hash}.CacheProbe"])
    on_exit(fn -> restart(module) end)
    module
  end

  defp quoted(module, value) do
    quote do
      defmodule unquote(module) do
        def value, do: unquote(value)
      end
    end
  end

  # What a restart leaves of a module: no code loaded, and its file where it was.
  defp restart(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp watch_compiles do
    id = {__MODULE__, make_ref()}
    events = [@span ++ [:stop]]
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_span/4, %{test: self()})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp stops(acc \\ []) do
    receive do
      {:span, :stop, metadata} -> stops([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp outcomes(module) do
    for %{module: ^module, cache: cache} <- stops(), do: cache
  end

  # Calls to `mfa` made by this process while `fun` runs, as `{module, function, arity}`. A process
  # is not handed its own trace messages, so a tracer of its own collects them.
  defp traced({module, _function, _arity} = mfa, flags, fun) do
    Code.ensure_loaded!(module)
    tracer = spawn_link(fn -> collect_calls([]) end)
    :erlang.trace_pattern(mfa, true, flags)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    result = fun.()
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern(mfa, false, flags)
    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, {:calls, self()})
    assert_receive {:traced, calls}
    {result, calls}
  end

  defp collect_calls(acc) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        collect_calls([{module, function, length(args)} | acc])

      {:calls, test} ->
        send(test, {:traced, Enum.reverse(acc)})
    end
  end

  defp component_module(component),
    do:
      ModuleCompilerHandler.compile_or_return_module(
        Helpers.module_name(component.name, nil, "Component"),
        component.name,
        "Global",
        nil
      )

  defp count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="count"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  defp cold_page! do
    site = create_site!()
    n = System.unique_integer([:positive])

    record =
      create_page!(
        site_id: site.id,
        name: "cached-#{n}",
        path: "/cached-#{n}",
        template: ~S(<div id="cold">cold</div>)
      )

    module = Helpers.module_name(record.id, site.name, "Page")

    on_exit(fn ->
      restart(module)
      CompileFailureState.clear(module)
    end)

    %{module: module, path: record.path, site: site.name, site_id: site.id, record: record}
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

  defp crowd(page, size) do
    1..size
    |> Enum.map(fn _ -> Task.async(fn -> visit(page) end) end)
    |> Task.await_many(30_000)
    |> Enum.uniq()
  end

  # The code the page compiles from now, as the handler builds it.
  defp page_ast(page) do
    {:ok, ast} =
      ModuleCompilerHandler.get_data_from_database_to_ast(
        {Atom.to_string(page.module), %{path: page.path, site: page.site, site_id: page.site_id}}
      )

    ast
  end

  defp update_page!(record, attrs) do
    record
    |> Ash.Changeset.for_update(:update, attrs, tenant: record.site_id)
    |> Ash.update!(authorize?: false)
  end

  defp folder!(dir, name, mtime) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    File.touch!(path, mtime)
    path
  end

  # `or`-joined change checks as `Phoenix.LiveView.Engine` writes them, inside a rendered struct.
  defp checks(assigns) do
    assigns
    |> Enum.map(fn assign ->
      {{:., [], [Phoenix.LiveView.Engine, :changed_assign?]}, [],
       [{:changed, [], Phoenix.LiveView.Engine}, assign]}
    end)
    |> Enum.reduce(&{:or, [], [&1, &2]})
  end

  defp rendered(chain, fingerprint, static \\ ["<p>", "</p>"]) do
    quote do
      %Phoenix.LiveView.Rendered{
        static: unquote(static),
        dynamic: fn changed -> [if(unquote(chain), do: "x")] end,
        fingerprint: unquote(fingerprint),
        root: true
      }
    end
  end

  defp cache_dir(entry), do: entry.folder |> Path.dirname() |> Path.dirname()

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp hex(binary), do: Base.encode16(binary, case: :lower)

  # The sweep runs in a task of the runtime's task supervisor: every task running there now is
  # waited for, and one that already ended has done its work.
  defp sweeps_done do
    for pid <- Task.Supervisor.children(MishkaCmsCore.Runtime.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    :ok
  end
end
