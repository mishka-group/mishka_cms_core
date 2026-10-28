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
  UPDATE, where LiveView evaluates only what changed. They cost very different amounts, so they are
  counted apart.

  The time is inclusive: a component's number holds the components and slots drawn inside it. The
  lazy build of a module drawn inside it is not, because `lookup/1` keeps that out of every clock
  running around it — the build has its own line, from `[:mishka_cms, :runtime, :compilers, :module]`.

  ## What is left out

  Admin previews and the builder canvas render components for an author, not for a visitor:
  `unmeasured/1` runs them with the clock off. The counts start again whenever the module is built
  again, because the new numbers belong to a new version.
  """
  use GenServer

  alias Phoenix.LiveView.{Comprehension, Rendered}

  @renders :mishka_cms_render_metrics
  @builds :mishka_cms_build_metrics
  @off :mishka_cms_render_metrics_off
  @lookup :mishka_cms_render_metrics_lookup
  @handler "mishka-cms-core-render-metrics-builds"
  @build_event [:mishka_cms, :runtime, :compilers, :module, :stop]

  @type stats :: %{
          full: %{count: non_neg_integer(), avg_us: non_neg_integer()},
          update: %{count: non_neg_integer(), avg_us: non_neg_integer()}
        }

  @type build :: %{ms: float(), cache: :hit | :miss | :off, at: DateTime.t()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@renders, [:named_table, :set, :public, write_concurrency: true])
    :ets.new(@builds, [:named_table, :set, :public, read_concurrency: true])
    :telemetry.detach(@handler)
    :telemetry.attach(@handler, @build_event, &__MODULE__.handle_build/4, nil)
    {:ok, nil}
  end

  @doc "The render counts and average times of `module`, or `nil` before its first render."
  @spec stats(module()) :: stats() | nil
  def stats(module) do
    case lookup_row(@renders, module) do
      {^module, full, full_total, update, update_total} ->
        %{
          full: %{count: full, avg_us: avg(full_total, full)},
          update: %{count: update, avg_us: avg(update_total, update)}
        }

      nil ->
        nil
    end
  end

  @doc "How `module` was last built on this node, or `nil` when it was not built since boot."
  @spec build(module()) :: build() | nil
  def build(module) do
    case lookup_row(@builds, module) do
      {^module, native, cache, at} ->
        %{
          ms: System.convert_time_unit(native, :native, :microsecond) / 1000,
          cache: cache,
          at: DateTime.from_unix!(at)
        }

      nil ->
        nil
    end
  end

  @doc """
  Draws a component through `fun` (which returns what the component returned) and times it.
  `module` is the component's module, the key its numbers are kept under.
  """
  @spec measure(module(), (-> term())) :: term()
  def measure(module, fun) do
    case measuring?() do
      true ->
        {result, call} = timed(fun)
        timed_rendered(result, module, call)

      false ->
        fun.()
    end
  end

  @doc "Finds or lazily builds a module; the time is taken out of every component clock around it."
  @spec lookup((-> term())) :: term()
  def lookup(fun) do
    case measuring?() do
      true ->
        t0 = System.monotonic_time()
        result = fun.()
        Process.put(@lookup, Process.get(@lookup, 0) + System.monotonic_time() - t0)
        result

      false ->
        fun.()
    end
  end

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
  def handle_build(_event, %{duration: native}, %{module: module, cache: cache}, _config) do
    if :erlang.module_loaded(module) do
      :ets.insert(@builds, {module, native, cache, System.system_time(:second)})
      :ets.delete(@renders, module)
    end

    :ok
  end

  def handle_build(_event, _measurements, _metadata, _config), do: :ok

  defp measuring?, do: Process.get(@off) != true and :ets.whereis(@renders) != :undefined

  defp timed_rendered(%Rendered{dynamic: dynamic} = rendered, module, call) do
    %{
      rendered
      | dynamic: fn track ->
          kind = if track, do: :update, else: :full
          {values, time} = timed(fn -> dynamic.(track) end)
          add(module, kind, call + time, 1)
          Enum.map(values, &nested(&1, module, kind))
        end
    }
  end

  defp timed_rendered(other, _module, _call), do: other

  defp nested(%Rendered{dynamic: dynamic} = rendered, module, kind) do
    %{
      rendered
      | dynamic: fn track ->
          {values, time} = timed(fn -> dynamic.(track) end)
          add(module, kind, time, 0)
          Enum.map(values, &nested(&1, module, kind))
        end
    }
  end

  defp nested(%Comprehension{entries: entries} = comprehension, module, kind) do
    entries =
      Enum.map(entries, fn {key, vars, render} ->
        {key, vars,
         fn vars_changed, track ->
           {values, time} = timed(fn -> render.(vars_changed, track) end)
           add(module, kind, time, 0)
           Enum.map(values, &nested(&1, module, kind))
         end}
      end)

    %{comprehension | entries: entries}
  end

  defp nested(value, _module, _kind), do: value

  # Wall time of `fun`, less any module build that happened inside it.
  defp timed(fun) do
    l0 = Process.get(@lookup, 0)
    t0 = System.monotonic_time()
    result = fun.()
    time = System.monotonic_time() - t0 - (Process.get(@lookup, 0) - l0)
    {result, time}
  end

  defp add(module, :full, time, count),
    do: :ets.update_counter(@renders, module, [{2, count}, {3, time}], {module, 0, 0, 0, 0})

  defp add(module, :update, time, count),
    do: :ets.update_counter(@renders, module, [{4, count}, {5, time}], {module, 0, 0, 0, 0})

  defp avg(_total, 0), do: 0
  defp avg(total, count), do: System.convert_time_unit(div(total, count), :native, :microsecond)

  defp lookup_row(table, key) do
    case :ets.whereis(table) != :undefined and :ets.lookup(table, key) do
      [row] -> row
      _none -> nil
    end
  end
end
