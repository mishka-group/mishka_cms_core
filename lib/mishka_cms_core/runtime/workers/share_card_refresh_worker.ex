defmodule MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker do
  @moduledoc """
  Looks at the share card a page or a record shows now (`MishkaCmsCore.Runtime.ShareCard.specs/2`)
  and queues its drawing when it is not drawn yet — or, with `force`, draws it again over the old
  file. Enqueued by `MishkaCmsCore.Runtime.ShareCard.refresh/3`, on `:share_cards`, one job per site
  and target at a time: the saves of a burst are one look.
  """
  use Oban.Worker,
    queue: :share_cards,
    max_attempts: 3,
    unique: [
      period: 5,
      keys: [:site_id, :target, :force],
      states: [:available, :scheduled, :executing]
    ]

  alias MishkaCmsCore.Runtime.ShareCard

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id, "target" => target} = args}) do
    for spec <- ShareCard.specs(site_id, ShareCard.decode(target)) do
      if args["force"],
        do: ShareCard.redraw(site_id, spec),
        else: ShareCard.image(site_id, spec)
    end

    :ok
  end
end
