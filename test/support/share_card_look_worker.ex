defmodule MishkaCmsCore.Test.ShareCardLookWorker do
  @moduledoc "A producer's own share-card worker, as a site that draws cards of its own has one."
  use Oban.Worker, queue: :share_cards

  @impl Oban.Worker
  def perform(_job), do: :ok
end
