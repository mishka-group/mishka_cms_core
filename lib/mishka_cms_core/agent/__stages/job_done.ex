# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.JobDone do
  @moduledoc """
  An Oban job the operation queued finished.

      {:job_done, :feed_built, worker: MyExtension.Workers.Feed}

  ## Options

    * `:worker` — required: the worker module, which is how the result is matched to the stage.
    * `:skip_when` — as `MishkaCmsCore.Agent.Stages.JobEnqueued`'s.

  ## How it hears

  A job carries the receipt id in its `meta` when it was built while a receipt was open
  (`MishkaCmsCore.Agent.Receipts.job_meta/1`). Oban's own telemetry (`[:oban, :job, :stop]` and
  `[:oban, :job, :exception]`) is attached by `MishkaCmsCore.Agent.ReceiptStore`; the handler
  stores the result for that receipt, and it is applied when the receipt is read. When the receipt
  is stored the job has usually not run yet, so the stage starts unverified (`:pending`).

  ## What verified means

  Oban reported the job's `perform/1` as a success on this node. A failed attempt fails the stage
  (`:failure`), and a later successful retry verifies it again; a discarded or cancelled job fails
  it.

  ## What it does not prove

  What the job did beyond returning success. A job run on another node is reported there, where
  this receipt does not exist, so it stays `:pending`. A unique job another operation queued first
  carries that operation's id, so this receipt never hears of it. Jobs built without
  `job_meta/1` are never heard.
  """
  @behaviour MishkaCmsCore.Agent.Stages

  alias MishkaCmsCore.Agent.Receipt.Stage
  alias MishkaCmsCore.Agent.Receipts
  alias MishkaCmsCore.Agent.Stages.JobEnqueued

  @handler_id "mishka-cms-core-agent-receipts-oban"

  @impl true
  def layer(_opts), do: :app

  @impl true
  def key(opts), do: opts |> Keyword.fetch!(:worker) |> inspect()

  @impl true
  def verify(ctx, opts) do
    case JobEnqueued.skip(ctx, opts) do
      nil -> {:unverified, :pending}
      reason -> {:skip, reason}
    end
  end

  @doc """
  The site's sitemap build, the job `MishkaCmsCore.Agent.Stages.JobEnqueued.sitemap/1` finds.
  """
  @spec sitemap(atom()) :: {:job_done, atom(), keyword()}
  def sitemap(name \\ :sitemap_built) do
    {:job_done, name,
     worker: MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker,
     skip_when: &JobEnqueued.sitemap_off/1}
  end

  @doc false
  # Attaches the Oban telemetry handler. Idempotent.
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_telemetry/4,
      nil
    )
  end

  @doc false
  def handle_telemetry(
        _event,
        _measurements,
        %{job: %{meta: %{} = job_meta} = job} = meta,
        _config
      ) do
    with id when is_binary(id) <- job_meta["receipt_id"],
         answer when not is_nil(answer) <- answer(Map.get(meta, :state)) do
      spec = %{kind: :job_done, name: :job_done, layer: :app, key: job.worker, module: __MODULE__}
      _ = Receipts.late(id, Stage.new(spec, answer))
    end

    :ok
  end

  def handle_telemetry(_event, _measurements, _meta, _config), do: :ok

  defp answer(:success), do: {:ok, %{state: :success}}
  defp answer(:snoozed), do: nil

  defp answer(state) when is_atom(state) and not is_nil(state),
    do: {:error, state, %{state: state}}

  defp answer(_unknown), do: nil
end
