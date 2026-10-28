# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.RenderMetrics do
  @moduledoc """
  How long each runtime component takes to render, and how its module was last built, on this node
  since it started. Read by the component preview modal's Performance Metrics card.

  ## Where a component's time is spent

  LiveView has no telemetry per function component, and timing the call alone measures almost
  nothing: a HEEx render returns a `%Phoenix.LiveView.Rendered{}` whose expressions run LATER, when
  `Phoenix.LiveView.Diff` walks the tree. So `measure/2` times three things and adds them up:

    * the call itself, where the attr defaults are merged and the stored `body` runs;
    * the `dynamic` closure of the returned struct, the template's own expressions;
    * the closures nested in what that returns — `:for` entries, `if` blocks, slots and the
      components drawn inside — which run after it.

  A render with `track = false` is a FULL render (the page's first, a new fingerprint); `true` is an
  UPDATE, where LiveView evaluates only what changed. They are counted apart.

  The time is inclusive: a component's number holds the components and slots drawn inside it. A
  module built lazily inside a render is not: `handle_compile/4` hears the build in the rendering
  process and every clock running around it takes that time out.

  ## Nothing a render does waits

  The clock runs in the rendering process, because that is where the template runs. What it records
  goes to a `:counters` array per module — atomics, lock-free with `:write_concurrency` — found
  through an ETS table that is written once per module. There is no message, no call and no lock on
  the render path, and nothing on it raises: with no table it records nothing. The GenServer only
  owns the two tables and answers nothing.

  ## Off unless it is asked for

  The `runtime.render_metrics` setting (General → Performance, off by default) turns the clock on.
  It is read on every component render, so `on?/0` keeps it in `:persistent_term` as an atom — a
  read costs nanoseconds, and replacing an atom there needs no global garbage collection —
  and `MishkaCmsCore.Runtime.States.SettingsState` replaces it whenever the setting is written, on
  every node. Off, a render does nothing else.

  ## What is left out

  Admin previews and the builder canvas render components for an author, not for a visitor:
  `unmeasured/1` runs them with the clock off. The counts start again whenever the module is built
  again, because the new numbers belong to a new version.
  """
  use GenServer

  alias Phoenix.LiveView.{Comprehension, Rendered}

  @counters :mishka_cms_render_counters
  @builds :mishka_cms_build_metrics
  @off :mishka_cms_render_metrics_off
  @compiling :mishka_cms_render_metrics_compiling
  @setting "runtime.render_metrics"
  @switch {__MODULE__, :on}
  @build_handler "mishka-cms-core-render-metrics-builds"
  @compile_handler "mishka-cms-core-render-metrics-compiles"

  # The four counters of a module: full renders and their time, updates and their time.
  @full_count 1
  @full_time 2
  @update_count 3
  @update_time 4

  @type stats :: %{
          full: %{count: non_neg_integer(), avg_us: non_neg_integer()},
          update: %{count: non_neg_integer(), avg_us: non_neg_integer()}
        }

  @type build :: %{ms: float(), cache: :hit | :miss | :off, at: DateTime.t()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@counters, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@builds, [:named_table, :set, :public, read_concurrency: true])

    :telemetry.detach(@build_handler)
    :telemetry.detach(@compile_handler)

    :telemetry.attach(
      @build_handler,
      [:mishka_cms, :runtime, :compilers, :module, :stop],
      &__MODULE__.handle_build/4,
      nil
    )

    :telemetry.attach(
      @compile_handler,
      [:mishka_cms, :runtime, :handlers, :module_compiler, :stop],
      &__MODULE__.handle_compile/4,
      nil
    )

    {:ok, nil}
  end

  @doc "The render counts and average times of `module`, or `nil` before its first render."
  @spec stats(module()) :: stats() | nil
  def stats(module) do
    case lookup(@counters, module) do
      [{^module, ref}] -> stats_of(ref)
      _none -> nil
    end
  end

  @doc "How `module` was last built on this node, or `nil` when it was not built since boot."
  @spec build(module()) :: build() | nil
  def build(module) do
    case lookup(@builds, module) do
      [{^module, native, cache, at}] ->
        %{ms: ms(native), cache: cache, at: DateTime.from_unix!(at)}

      _none ->
        nil
    end
  end

  @doc "Whether components are timed: the `runtime.render_metrics` setting."
  @spec on?() :: boolean()
  def on? do
    case :persistent_term.get(@switch, nil) do
      nil -> switch_changed()
      on -> on
    end
  end

  @doc false
  # Reads the setting from the settings cache again and keeps it for `on?/0`. With no cache yet (a
  # boot that has not started it) the clock stays off and nothing raises.
  @spec switch_changed() :: boolean()
  def switch_changed do
    on = MishkaCmsCore.Settings.get(@setting, false) == true
    :persistent_term.put(@switch, on)
    on
  rescue
    ArgumentError -> false
  end

  @doc """
  Draws a component through `fun` (which returns what the component returned) and times it.
  `module` is the component's module, the key its numbers are kept under.
  """
  @spec measure(module(), (-> term())) :: term()
  def measure(module, fun), do: timed_call(counters(module), fun)

  @doc "Runs `fun` with the clock off in this process — for what an author sees, not a visitor."
  @spec unmeasured((-> result)) :: result when result: term()
  def unmeasured(fun) do
    previous = Process.put(@off, true)

    try do
      fun.()
    after
      if previous, do: Process.put(@off, previous), else: Process.delete(@off)
    end
  end

  @doc false
  # A module built: record how, and start its counts again.
  def handle_build(_event, %{duration: native}, %{module: module, cache: cache}, _config) do
    if :erlang.module_loaded(module) do
      :ets.insert(@builds, {module, native, cache, System.system_time(:second)})
      :ets.delete(@counters, module)
    end

    :ok
  end

  def handle_build(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  # A lazy build in the rendering process: kept out of every clock running around it.
  def handle_compile(_event, %{duration: native}, _metadata, _config) do
    Process.put(@compiling, Process.get(@compiling, 0) + native)
    :ok
  end

  defp timed_call(nil, fun), do: fun.()

  defp timed_call(ref, fun) do
    {t0, compiling} = start()
    result = fun.()
    timed_rendered(result, ref, elapsed(t0, compiling))
  end

  # The module's counters, made on its first render, or `nil` when nothing is to be recorded.
  defp counters(module) do
    case on?() and Process.get(@off) != true do
      true -> registered(lookup(@counters, module), module)
      false -> nil
    end
  end

  defp registered([{_, ref}], _module), do: ref
  defp registered([], module), do: register(module)
  defp registered(:no_table, _module), do: nil

  # Two first renders at once: the one that inserts first wins and the other uses its counters.
  defp register(module) do
    ref = :counters.new(4, [:write_concurrency])

    case :ets.insert_new(@counters, {module, ref}) do
      true -> ref
      false -> registered(lookup(@counters, module), module)
    end
  end

  defp timed_rendered(%Rendered{dynamic: dynamic} = rendered, ref, call) do
    %{rendered | dynamic: &top(dynamic, ref, call, &1)}
  end

  defp timed_rendered(other, _ref, _call), do: other

  defp top(dynamic, ref, call, track) do
    {t0, compiling} = start()
    values = dynamic.(track)
    add(ref, track, call + elapsed(t0, compiling), 1)
    Enum.map(values, &nested(&1, ref, track))
  end

  defp nested(%Rendered{dynamic: dynamic} = rendered, ref, kind) do
    %{rendered | dynamic: &piece(dynamic, ref, kind, &1)}
  end

  defp nested(%Comprehension{entries: entries} = comprehension, ref, kind) do
    %{comprehension | entries: Enum.map(entries, &entry(&1, ref, kind))}
  end

  defp nested(value, _ref, _kind), do: value

  defp piece(dynamic, ref, kind, track) do
    {t0, compiling} = start()
    values = dynamic.(track)
    add(ref, kind, elapsed(t0, compiling), 0)
    Enum.map(values, &nested(&1, ref, kind))
  end

  defp entry({key, vars, render}, ref, kind),
    do: {key, vars, &entry_piece(render, ref, kind, &1, &2)}

  defp entry_piece(render, ref, kind, vars_changed, track) do
    {t0, compiling} = start()
    values = render.(vars_changed, track)
    add(ref, kind, elapsed(t0, compiling), 0)
    Enum.map(values, &nested(&1, ref, kind))
  end

  # A clock: wall time since `start/0`, less any lazy module build that happened in between.
  defp start, do: {:erlang.monotonic_time(), Process.get(@compiling, 0)}

  defp elapsed(t0, compiling),
    do: :erlang.monotonic_time() - t0 - (Process.get(@compiling, 0) - compiling)

  # `false` is a full render, `true` an update — LiveView's own `track` flag.
  defp add(ref, false, time, count) do
    :counters.add(ref, @full_count, count)
    :counters.add(ref, @full_time, time)
  end

  defp add(ref, true, time, count) do
    :counters.add(ref, @update_count, count)
    :counters.add(ref, @update_time, time)
  end

  defp stats_of(ref) do
    %{
      full: %{count: :counters.get(ref, @full_count), avg_us: avg(ref, @full_time, @full_count)},
      update: %{
        count: :counters.get(ref, @update_count),
        avg_us: avg(ref, @update_time, @update_count)
      }
    }
  end

  defp avg(ref, time, count) do
    case :counters.get(ref, count) do
      0 -> 0
      n -> System.convert_time_unit(div(:counters.get(ref, time), n), :native, :microsecond)
    end
  end

  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  # With no table (its owner restarting) there is nothing to read or record, and nothing raises.
  defp lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> :no_table
  end
end
