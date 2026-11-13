# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.ReceiptStore do
  @moduledoc """
  Where this node keeps its receipts: bounded ETS tables, written by the process that ran the
  operation and read by whoever asks. Nothing on the write or the read path calls a process.

  The GenServer owns the tables and does two things: it attaches the Oban telemetry handler that
  brings a job's late result (`MishkaCmsCore.Agent.Stages.JobDone`), and it drops receipts older
  than `max_age_seconds` once a minute. `MishkaCmsCore.Application` starts it, so a host does
  nothing to have it.

  ## Tables

    * receipts, an `:ordered_set` keyed by `seq` (newest last), so the newest are read from the end
      in `O(log n)` each, with no sort;
    * ids, a `:set` from a receipt id to its `seq` (or to `:open` while its operation still runs, so
      late evidence for it is accepted);
    * late, a `:set` of the evidence that arrived after a receipt was stored: a job's result, a
      LiveView that saw the broadcast;
    * meta, the counters: the next `seq`, receipts per site, how many were dropped.

  ## Bounds

  Set under `config :mishka_cms_core, MishkaCmsCore.Agent.Receipts`:

    * `max_receipts` (1000) — the most kept on this node. A new one drops the oldest.
    * `per_site_max` (200) — the most kept for one site, so a busy site cannot push out another
      site's evidence. A new one drops that site's oldest.
    * `max_age_seconds` (3600) — older ones are dropped.

  Every dropped receipt counts in `dropped/0`. Writers do not lock: several finishing at the same
  moment can hold the table above `max_receipts` by their number until the next write evicts.

  ## Loss

  Receipts are evidence for whoever is watching, not a record of truth: they live in memory on one
  node and go when this process restarts (the tables are made again, empty) or the node stops. The
  record of who changed what is the Activity log and the version trail.
  """
  use GenServer

  alias MishkaCmsCore.Agent.Receipt
  alias MishkaCmsCore.Agent.Receipt.Stage

  @receipts :mishka_cms_agent_receipts
  @ids :mishka_cms_agent_receipt_ids
  @late :mishka_cms_agent_receipt_late
  @meta :mishka_cms_agent_receipt_meta
  @sweep_every :timer.minutes(1)
  @defaults [max_receipts: 1_000, per_site_max: 200, max_age_seconds: 3_600]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    options = [:named_table, :public, read_concurrency: true, write_concurrency: true]
    :ets.new(@receipts, [:ordered_set | options])
    :ets.new(@ids, [:set | options])
    :ets.new(@late, [:set | options])
    :ets.new(@meta, [:set | options])
    :ets.insert(@meta, [{:seq, 0}, {:dropped, 0}])
    :ok = MishkaCmsCore.Agent.Stages.JobDone.attach()
    :timer.send_interval(@sweep_every, :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, state}
  end

  @doc "The bounds in force, `config :mishka_cms_core, MishkaCmsCore.Agent.Receipts` over the defaults."
  @spec bounds() :: keyword()
  def bounds,
    do:
      Keyword.merge(
        @defaults,
        Application.get_env(:mishka_cms_core, MishkaCmsCore.Agent.Receipts, [])
      )

  @doc "Whether the tables exist (the store is running)."
  @spec running?() :: boolean()
  def running?, do: :ets.whereis(@receipts) != :undefined

  @doc false
  # Marks `id` as running, so late evidence for it is kept before it is stored.
  @spec open(String.t()) :: :ok
  def open(id) do
    safely(fn -> :ets.insert(@ids, {id, :open, System.monotonic_time(:second)}) end)
    :ok
  end

  @doc false
  # Stores a finished receipt and evicts what the bounds no longer allow. Returns it with its `seq`.
  @spec put(Receipt.t()) :: Receipt.t() | nil
  def put(%Receipt{id: id, site_id: site_id} = receipt) do
    safely(fn ->
      seq = :ets.update_counter(@meta, :seq, 1)
      receipt = %{receipt | seq: seq}
      :ets.insert(@receipts, {seq, id, site_id, System.monotonic_time(:second), receipt})
      :ets.insert(@ids, {id, seq, nil})
      bound(site_id)
      receipt
    end)
  end

  @doc false
  # Keeps evidence that arrived late for `id`, if this node knows the receipt.
  @spec late(String.t(), Stage.t()) :: :ok | :unknown
  def late(id, %Stage{kind: kind, key: key} = stage) do
    safely(fn ->
      case :ets.lookup(@ids, id) do
        [{^id, _seq, _at}] ->
          :ets.insert(@late, {{id, kind, key}, stage})
          :ok

        [] ->
          :unknown
      end
    end) || :unknown
  end

  @doc false
  # The late evidence stored for `id` of `kind` and `key`.
  @spec late_for(String.t(), atom(), String.t() | nil) :: Stage.t() | nil
  def late_for(id, kind, key) do
    safely(fn ->
      case :ets.lookup(@late, {id, kind, key}) do
        [{_key, stage}] -> stage
        [] -> nil
      end
    end)
  end

  @doc false
  # A stored receipt by id, with its late evidence applied; no permission is asked.
  @spec fetch(String.t()) :: Receipt.t() | nil
  def fetch(id) when is_binary(id) do
    safely(fn ->
      with [{^id, seq, _at}] when is_integer(seq) <- :ets.lookup(@ids, id),
           [{^seq, ^id, _site, _at, receipt}] <- :ets.lookup(@receipts, seq) do
        with_late(receipt)
      else
        _none -> nil
      end
    end)
  end

  def fetch(_id), do: nil

  @doc false
  # Stored receipts newest first, the ones `keep?` accepts, at most `limit`, late evidence applied.
  @spec newest((Receipt.t() -> boolean()), pos_integer()) :: [Receipt.t()]
  def newest(keep?, limit) do
    safely(fn -> walk(:ets.last(@receipts), keep?, limit, []) end) || []
  end

  defp walk(:"$end_of_table", _keep?, _limit, acc), do: Enum.reverse(acc)
  defp walk(_seq, _keep?, 0, acc), do: Enum.reverse(acc)

  defp walk(seq, keep?, limit, acc) do
    case :ets.lookup(@receipts, seq) do
      [{^seq, _id, _site, _at, receipt}] ->
        receipt = with_late(receipt)

        case keep?.(receipt) do
          true -> walk(:ets.prev(@receipts, seq), keep?, limit - 1, [receipt | acc])
          false -> walk(:ets.prev(@receipts, seq), keep?, limit, acc)
        end

      [] ->
        walk(:ets.prev(@receipts, seq), keep?, limit, acc)
    end
  end

  @doc "How many receipts this node keeps now."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(@receipts, :size) do
      size when is_integer(size) -> size
      :undefined -> 0
    end
  end

  @doc "How many receipts were dropped to stay within the bounds since the store started."
  @spec dropped() :: non_neg_integer()
  def dropped, do: safely(fn -> :ets.lookup_element(@meta, :dropped, 2) end) || 0

  @doc false
  # Drops what is older than `max_age_seconds`, receipts and ids of operations that never finished.
  @spec sweep() :: :ok
  def sweep do
    oldest = System.monotonic_time(:second) - bounds()[:max_age_seconds]

    safely(fn ->
      sweep_from(:ets.first(@receipts), oldest)
      :ets.select_delete(@ids, [{{:_, :open, :"$1"}, [{:<, :"$1", oldest}], [true]}])
    end)

    :ok
  end

  defp sweep_from(:"$end_of_table", _oldest), do: :ok

  defp sweep_from(seq, oldest) do
    case :ets.lookup(@receipts, seq) do
      [{^seq, _id, _site, at, _receipt} = row] when at < oldest ->
        next = :ets.next(@receipts, seq)
        evict(row)
        sweep_from(next, oldest)

      _fresh ->
        :ok
    end
  end

  defp with_late(%Receipt{id: id} = receipt) do
    case :ets.match_object(@late, {{id, :_, :_}, :_}) do
      [] -> receipt
      rows -> Receipt.with_late(Enum.map(rows, &elem(&1, 1)), receipt)
    end
  end

  defp bound(site_id) do
    bounds = bounds()

    if :ets.update_counter(@meta, {:site, site_id}, 1, {{:site, site_id}, 0}) >
         bounds[:per_site_max] do
      evict_oldest_of(site_id)
    end

    evict_over(:ets.info(@receipts, :size) - bounds[:max_receipts])
  end

  defp evict_oldest_of(site_id) do
    case :ets.select(@receipts, [{{:_, :_, site_id, :_, :_}, [], [:"$_"]}], 1) do
      {[row], _continuation} -> evict(row)
      _none -> :ok
    end
  end

  defp evict_over(over) when over <= 0, do: :ok

  defp evict_over(over) do
    case :ets.first(@receipts) do
      :"$end_of_table" ->
        :ok

      seq ->
        Enum.each(:ets.lookup(@receipts, seq), &evict/1)
        evict_over(over - 1)
    end
  end

  # Two writers may pick the same oldest row: only the one whose `take` returns it counts it.
  defp evict({seq, id, site_id, _at, _receipt}) do
    case :ets.take(@receipts, seq) do
      [_row] ->
        :ets.delete(@ids, id)
        :ets.match_delete(@late, {{id, :_, :_}, :_})
        :ets.update_counter(@meta, {:site, site_id}, -1, {{:site, site_id}, 1})
        :ets.update_counter(@meta, :dropped, 1)

      [] ->
        :ok
    end
  end

  # With no tables (the store is not started, or restarting) nothing is kept and nothing raises.
  defp safely(fun) do
    fun.()
  rescue
    ArgumentError -> nil
  end
end
