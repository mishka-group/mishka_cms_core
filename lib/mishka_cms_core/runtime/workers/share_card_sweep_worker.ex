defmodule MishkaCmsCore.Runtime.Workers.ShareCardSweepWorker do
  @moduledoc """
  Deletes the share cards of a site that no page shows any more: the planner
  (`MishkaCmsCore.Runtime.Workers.ShareCardPlanWorker`) queues one, on `:share_cards`, after it has
  queued a look at every card of the site, with the time it started as `since`.

  Every look marks the card files its pages show (`MishkaCmsCore.Runtime.ShareCard.keep/2`), and a
  card drawn by a look is written after `since`. So once the looks have run, a file in the site's
  share folder (`MishkaCmsCore.Runtime.ShareCard.dir/1`) last written before `since` is one no page
  names: a card drawn for data that has changed since. Those are deleted, with any `.part` file a
  drawing left behind before `since`.

  It runs after the looks: at the lowest priority, so every job of the queue that is waiting — the
  looks, and each drawing they queue — goes first, and while another job of the queue is running on
  this node it waits 15 seconds and looks again. One sweep a site waits at a time.

  The names deleted are announced on `MishkaCmsCore.Runtime.ShareCard.swept_event/0`, and the core
  forgets the ones it remembered as drawn, so a page that asks for one again has it drawn again.
  """
  use Oban.Worker,
    queue: :share_cards,
    priority: 9,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:site_id],
      states: [:available, :scheduled, :retryable]
    ]

  require Logger

  alias MishkaCmsCore.Runtime.{ShareCard, ShareCardQueue}
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaInstaller.Event.Hook

  @wait 15

  @doc """
  The sweep of the site `site_id` that follows a look at every card of it begun at `since`, a Unix
  time in seconds.
  """
  @spec after_plan(String.t(), integer()) :: Ecto.Changeset.t()
  def after_plan(site_id, since) when is_binary(site_id) and is_integer(since),
    do: new(%{site_id: site_id, since: since})

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"site_id" => site_id, "since" => since}}) do
    case others_running?(id) do
      true -> {:snooze, @wait}
      false -> sweep(site_id, since)
    end
  end

  defp others_running?(id) do
    case Oban.check_queue(queue: ShareCardQueue.queue()) do
      %{running: running} -> Enum.any?(running, &(&1 != id))
      _no_queue -> false
    end
  end

  defp sweep(site_id, since) do
    dir = ShareCard.dir(site_id)

    removed =
      case File.ls(dir) do
        {:ok, names} ->
          for name <- names,
              card_file?(name),
              file = Path.join(dir, name),
              older?(file, since),
              :ok <- [File.rm(file)],
              do: name

        {:error, _no_folder} ->
          []
      end

    cards = Enum.filter(removed, &(Path.extname(&1) == ".jpg"))

    for name <- cards, do: AssetsState.delete(site_id, "share_card:" <> Path.rootname(name))

    if removed != [] do
      Logger.info("[ShareCardSweepWorker] #{length(removed)} old share card files of #{site_id}")
    end

    Hook.call(ShareCard.swept_event(), %{site_id: site_id, removed: cards}, return: false)
    :ok
  end

  defp card_file?(name),
    do: Path.extname(name) == ".jpg" or String.ends_with?(name, ".jpg.part")

  defp older?(file, since) do
    case File.stat(file, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} -> mtime < since
      _not_a_file -> false
    end
  end
end
