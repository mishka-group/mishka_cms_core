defmodule MishkaCmsCore.Runtime.Workers.ShareCardPlanWorker do
  @moduledoc """
  Collects every share card of a site and queues a look at each: the planner
  `MishkaCmsCore.Runtime.ShareCard.redraw_all/2` enqueues, on `:share_cards`.

  It asks the producers for their cards through `MishkaCmsCore.Runtime.ShareCard.targets/2`, then
  inserts, in batches of 500:

    * a `MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker` job for each `{:page, id}` and
      `{:record, kind, captures}`, with the planner's `force`;
    * each `Oban.Job` changeset a producer answered with, as it is — one on another queue than
      `:share_cards` is left out.

  Asked for every producer's cards, it then queues a
  `MishkaCmsCore.Runtime.Workers.ShareCardSweepWorker`, which deletes the card files none of those
  looks showed once they have run. A target two producers name is looked at once. While the targets event cannot run — one of its
  plugins is started but not loaded — the planner waits 30 seconds and asks again.

  One planner a site, `force` and `producer` waits at a time: a second request while one waits is
  that one. Once its looks are queued it broadcasts
  `{:share_cards_planned, %{site_id:, force:, producer:, counts: %{producer => looks}}}` on
  `planned_topic/0` of `MishkaCmsCore.PubSub`.
  """
  use Oban.Worker,
    queue: :share_cards,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:site_id, :force, :producer],
      states: [:available, :scheduled, :retryable]
    ]

  require Logger

  alias MishkaCmsCore.Runtime.{ShareCard, ShareCardQueue}
  alias MishkaCmsCore.Runtime.Workers.{ShareCardRefreshWorker, ShareCardSweepWorker}

  @batch 500
  @topic "share_cards:planned"

  @doc "The PubSub topic a planner says on how many looks it queued."
  @spec planned_topic() :: String.t()
  def planned_topic, do: @topic

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id} = args}) do
    force = args["force"] == true
    producer = args["producer"]
    since = System.os_time(:second)

    case ShareCard.targets(site_id, force: force, producer: producer) do
      {:ok, by_producer} ->
        counts = plan(site_id, by_producer, force)
        :ok = sweep(site_id, producer, since)

        Phoenix.PubSub.broadcast(
          MishkaCmsCore.PubSub,
          @topic,
          {:share_cards_planned,
           %{site_id: site_id, force: force, producer: producer, counts: counts}}
        )

        :ok

      {:error, :cannot_run} ->
        {:snooze, 30}
    end
  end

  # After a look at every producer's cards, the files none of them shows go.
  defp sweep(site_id, nil, since) do
    case Oban.insert(ShareCardSweepWorker.after_plan(site_id, since)) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("[ShareCardPlanWorker] no sweep: #{inspect(reason)}")
    end
  end

  defp sweep(_site_id, _one_producer, _since), do: :ok

  # Each producer's looks, a target named twice looked at once; how many each producer queued.
  defp plan(site_id, by_producer, force) do
    {jobs, counts, _seen} =
      by_producer
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({[], %{}, MapSet.new()}, fn {producer, targets}, {jobs, counts, seen} ->
        {mine, seen} =
          Enum.reduce(targets, {[], seen}, fn target, {mine, seen} ->
            case job(site_id, target, force) do
              nil ->
                {mine, seen}

              {id, changeset} ->
                if id in seen, do: {mine, seen}, else: {[changeset | mine], MapSet.put(seen, id)}
            end
          end)

        {mine ++ jobs, Map.put(counts, producer, length(mine)), seen}
      end)

    jobs
    |> Enum.reverse()
    |> Enum.chunk_every(@batch)
    |> Enum.each(&Oban.insert_all/1)

    counts
  end

  defp job(site_id, {:page, id} = target, force) when is_binary(id),
    do: refresh(site_id, target, force)

  defp job(site_id, {:record, kind, %{}} = target, force) when is_binary(kind),
    do: refresh(site_id, target, force)

  defp job(_site_id, %Ecto.Changeset{data: %Oban.Job{}, valid?: true} = changeset, _force) do
    queue = Atom.to_string(ShareCardQueue.queue())

    case Ecto.Changeset.get_field(changeset, :queue) do
      ^queue ->
        {{Ecto.Changeset.get_field(changeset, :worker),
          Ecto.Changeset.get_field(changeset, :args)}, changeset}

      other ->
        Logger.warning(
          "[ShareCardPlanWorker] a share-card job on #{inspect(other)} is left out: it runs on #{queue}"
        )

        nil
    end
  end

  defp job(_site_id, _not_a_target, _force), do: nil

  defp refresh(site_id, target, force) do
    args = %{site_id: site_id, target: ShareCard.encode(target), force: force}
    {{:refresh, args.target}, ShareCardRefreshWorker.new(args)}
  end
end
