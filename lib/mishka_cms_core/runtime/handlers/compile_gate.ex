# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.CompileGate do
  @moduledoc """
  Per-node concurrency limiter for runtime module compilation.

  Compiling is CPU-bound, so allowing more compiles at once than the node has cores only
  thrashes the scheduler and the (single) code server — it does NOT add resources. This gate
  caps concurrent compiles to `System.schedulers_online()` (one per core, the measured sweet
  spot); extra compiles wait in a FIFO queue and start as slots free. So a cold-start burst of
  many distinct pages can't saturate the node and stall live requests.

  Every compile funnels through `run/1`, called by the one
  `MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler` worker a module has — covering boot,
  lazy first-request, and Oban-worker compiles. The callers waiting for that worker hold no slot.

  Per-node by design: CPU is a per-node resource, so each node throttles its own compiles with
  zero cluster coordination. The limit is overridable via
  `config :mishka_cms_core, :compile_gate_limit`.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run `fun` once a compile slot is free — blocking the caller until one opens — then release the
  slot. The holder is monitored, so if `fun` raises or the caller is killed the slot is still
  reclaimed (see `handle_info/2`); a slot is never leaked.
  """
  def run(fun) do
    :ok = GenServer.call(__MODULE__, :acquire, :infinity)

    MishkaInstaller.Event.Hook.call("runtime:compile_gate:acquired", %{at: :acquire},
      return: false
    )

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, {:release, self()})

      MishkaInstaller.Event.Hook.call("runtime:compile_gate:released", %{at: :release},
        return: false
      )
    end
  end

  @impl true
  def init(opts) do
    limit =
      Keyword.get(opts, :limit) ||
        Application.get_env(:mishka_cms_core, :compile_gate_limit) ||
        System.schedulers_online()

    {:ok, %{limit: limit, used: 0, waiting: :queue.new(), holders: %{}}}
  end

  @impl true
  def handle_call(:acquire, {pid, _}, %{used: used, limit: limit} = state) when used < limit do
    {:reply, :ok, hold(state, pid)}
  end

  def handle_call(:acquire, from, %{waiting: q} = state) do
    {:noreply, %{state | waiting: :queue.in(from, q)}}
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, release(state, pid)}

  # A holder that crashed before releasing frees its slot automatically.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, release(state, pid)}

  # Never crash the gate on an unexpected message — that would disrupt every in-flight compile.
  def handle_info(_msg, state), do: {:noreply, state}

  defp hold(state, pid) do
    ref = Process.monitor(pid)
    %{state | used: state.used + 1, holders: Map.put(state.holders, pid, ref)}
  end

  defp release(%{holders: holders} = state, pid) do
    case Map.pop(holders, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        grant_next(%{state | used: state.used - 1, holders: rest})
    end
  end

  defp grant_next(%{used: used, limit: limit, waiting: q} = state) when used < limit do
    case :queue.out(q) do
      {{:value, {pid, _} = from}, rest} ->
        GenServer.reply(from, :ok)
        %{hold(state, pid) | waiting: rest}

      {:empty, _} ->
        state
    end
  end

  defp grant_next(state), do: state
end
