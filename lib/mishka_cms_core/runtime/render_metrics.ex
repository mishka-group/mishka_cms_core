# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.RenderMetrics do
  @moduledoc """
  How long each runtime component, page, layout and error page takes to render, and how its module
  was last built, on this node since that build. Read by the runtime preview modal's Performance
  Metrics card.

  ## Where a template's time is spent

  LiveView has no telemetry per function component, and timing the call alone measures almost
  nothing: a HEEx render returns a `%Phoenix.LiveView.Rendered{}` whose expressions run LATER, when
  `Phoenix.LiveView.Diff` walks the tree. So `measure/3` times three things and adds them up:

    * the call itself, where the attr defaults are merged and the stored `body` runs;
    * the `dynamic` closure of the returned struct, the template's own expressions;
    * the closures nested in what that returns — `:for` entries, `if` blocks, slots and the
      components drawn inside — which run after it.

  A render with `track = false` is a FULL render (the page's first, a new fingerprint); `true` is an
  UPDATE, where LiveView evaluates only what changed. They are counted apart.

  The time is inclusive: a component's or a page's number holds the function components and slots
  drawn inside it. A page is handed to its layout as `@inner_content`, so a page's clocks put their
  time in the pot every clock around them leaves out (`measure/3`, `:handed_in`): the layout's number
  — and a component's that draws `@inner_content` — does not hold the page, which has its own. What
  a layout still pays for the page is the clocks' own cost around each of its parts, tens of
  nanoseconds a part while measuring is on.

  A module built lazily inside a render is not in the time either: `handle_compile/4` hears the
  build in the rendering process and every clock running around it takes that time out. Neither are live
  components drawn inside it, which LiveView renders on their own, nor a live component's own
  `mount/1` and `update/2`, which run before its `render/1`. A component drawn through
  `MishkaCmsCore.Runtime.ComponentBoundary` is evaluated whole every time, so it counts full renders
  and no updates.

  ## Nothing a render does waits

  The clock runs in the rendering process, because that is where the template runs. What it records
  goes to a `:counters` array per module — atomics, lock-free with `:write_concurrency` — found
  through an ETS table that is written once per module. There is no message, no call and no lock on
  the render path, and nothing on it raises: with no table it records nothing. The GenServer only
  owns the two tables and answers nothing.

  ## Off unless it is asked for

  The `runtime.render_metrics` setting (General → Performance, off by default) turns the clock on.
  It is read on every measured render, so it is kept in `:persistent_term` as an atom — a read
  costs nanoseconds, and replacing an atom there needs no global garbage collection.
  `MishkaCmsCore.Runtime.States.SettingsState` writes it when it loads and whenever the setting is
  written, on every node (`switch_changed/0`). Off, a render does nothing else.

  ## What is left out

  Admin previews and the builder canvas render components for an author, not for a visitor:
  `unmeasured/1` runs them with the clock off, and a draft preview's own module is built with no
  clock (`measured?/1`). The counts start again whenever the module is built again, because the new
  numbers belong to a new version.
  """
  use GenServer

  alias Phoenix.LiveView.{Comprehension, Rendered}

  @counters :mishka_cms_render_counters
  @builds :mishka_cms_build_metrics
  @off :mishka_cms_render_metrics_off
  @excluded :mishka_cms_render_metrics_excluded
  @setting "runtime.render_metrics"
  @switch {__MODULE__, :on}
  @measured ~w(Component Page Layout)
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

  @type build :: %{us: non_neg_integer(), cache: :hit | :miss | :off, at: DateTime.t()}

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
      [{^module, us, cache, at}] ->
        %{us: us, cache: cache, at: DateTime.from_unix!(at)}

      _none ->
        nil
    end
  end

  @doc "Whether renders are timed: the `runtime.render_metrics` setting."
  @spec on?() :: boolean()
  def on?, do: :persistent_term.get(@switch, false)

  @doc false
  # Reads the setting from the settings cache again and keeps it for `on?/0`.
  @spec switch_changed() :: boolean()
  def switch_changed do
    on = MishkaCmsCore.Settings.get(@setting, false) == true
    :persistent_term.put(@switch, on)
    on
  rescue
    ArgumentError -> false
  end

  @doc """
  Draws through `fun` (which returns what the template returned) and times it under `key`: the
  module drawn.

  `role` is `:inline` for what is drawn where it is called — a component — and `:handed_in` for a
  page, whose output is handed to its layout (see the moduledoc).
  """
  @spec measure(term(), (-> term()), :inline | :handed_in) :: term()
  def measure(key, fun, role \\ :inline), do: timed_call(counters(key), role == :handed_in, fun)

  @doc """
  Whether `module` is one whose renders and builds are kept: a component, page, layout or error page
  of a site, as `MishkaCmsCore.Runtime.Compilers.Helpers.module_name/3` names them. The modules a
  draft preview builds (`MishkaCmsCore.Runtime.Preview.*`) are not: no card reads them.

  The compilers ask it at compile time, so a module that is not kept is built with no clock at all.
  """
  @spec measured?(module()) :: boolean()
  def measured?(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> name ->
        match?(
          ["MishkaCmsCore", "Runtime", _hash, type] when type in @measured,
          String.split(name, ".")
        )

      _not_an_elixir_module ->
        false
    end
  end

  def measured?(_no_module), do: false

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
  # A measured module built: record how, and start its counts again.
  def handle_build(_event, %{duration: native}, %{module: module, cache: cache}, _config) do
    if measured?(module) do
      us = System.convert_time_unit(native, :native, :microsecond)
      :ets.insert(@builds, {module, us, cache, System.system_time(:second)})
      :ets.delete(@counters, module)
    end

    :ok
  end

  def handle_build(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  # A lazy build in the rendering process: kept out of every clock running around it.
  def handle_compile(_event, %{duration: native}, _metadata, _config) do
    if on?(), do: Process.put(@excluded, Process.get(@excluded, 0) + native)
    :ok
  end

  defp timed_call(nil, _handed?, fun), do: fun.()

  defp timed_call(ref, handed?, fun) do
    {t0, excluded} = start()
    result = fun.()
    timed_rendered(result, {ref, handed?}, elapsed(t0, excluded))
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
  rescue
    ArgumentError -> nil
  end

  # A clock is `{ref, handed?}`: the counters it adds to, and whether its time is handed over.
  defp timed_rendered(%Rendered{dynamic: dynamic} = rendered, clock, call) do
    %{rendered | dynamic: &top(dynamic, clock, call, &1)}
  end

  defp timed_rendered(other, _clock, _call), do: other

  defp top(dynamic, {ref, handed?} = clock, call, track) do
    {t0, excluded} = start()
    values = dynamic.(track)
    add(ref, track, call + elapsed(t0, excluded), 1)
    values |> Enum.map(&nested(&1, clock, track)) |> hand_over(handed?, t0, excluded)
  end

  defp nested(%Rendered{dynamic: dynamic} = rendered, clock, kind) do
    %{rendered | dynamic: &piece(dynamic, clock, kind, &1)}
  end

  defp nested(%Comprehension{entries: entries} = comprehension, clock, kind) do
    %{comprehension | entries: Enum.map(entries, &entry(&1, clock, kind))}
  end

  defp nested(value, _clock, _kind), do: value

  defp piece(dynamic, {ref, handed?} = clock, kind, track) do
    {t0, excluded} = start()
    values = dynamic.(track)
    add(ref, kind, elapsed(t0, excluded), 0)
    values |> Enum.map(&nested(&1, clock, kind)) |> hand_over(handed?, t0, excluded)
  end

  defp entry({key, vars, render}, clock, kind),
    do: {key, vars, &entry_piece(render, clock, kind, &1, &2)}

  defp entry_piece(render, {ref, handed?} = clock, kind, vars_changed, track) do
    {t0, excluded} = start()
    values = render.(vars_changed, track)
    add(ref, kind, elapsed(t0, excluded), 0)
    values |> Enum.map(&nested(&1, clock, kind)) |> hand_over(handed?, t0, excluded)
  end

  # A clock: wall time since `start/0`, less what the clocks inside it left out — a lazy build, a
  # page handed in. Never below zero.
  defp start, do: {:erlang.monotonic_time(), Process.get(@excluded, 0)}

  defp elapsed(t0, excluded),
    do: max(:erlang.monotonic_time() - t0 - (Process.get(@excluded, 0) - excluded), 0)

  # A page's time goes in the pot, so the clocks of the layout around it leave it out: all of it,
  # its clock's own bookkeeping included, which is why it is handed over last.
  defp hand_over(result, false, _t0, _excluded), do: result

  defp hand_over(result, true, t0, excluded) do
    Process.put(@excluded, Process.get(@excluded, 0) + elapsed(t0, excluded))
    result
  end

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

  # With no table (its owner restarting) there is nothing to read or record, and nothing raises.
  defp lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> :no_table
  end
end
