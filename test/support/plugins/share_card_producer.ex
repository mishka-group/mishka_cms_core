defmodule MishkaCmsCore.Test.Plugins.ShareCardProducer do
  @moduledoc """
  A producer on `MishkaCmsCore.Runtime.ShareCard.targets_event/0`, as an extension writes one: it
  answers under `"test_producer"` — or the name `:persistent_term.get({__MODULE__, :name})` holds —
  with as many `{:record, "test:thing", …}` targets as
  `:persistent_term.get({__MODULE__, :count}, 3)` says, one of them twice, one job of its own worker
  on `:share_cards` built with the `force` it was asked for, and one job on another queue. It counts
  how often its targets were read, under `{__MODULE__, :reads}`.
  """
  use MishkaInstaller.Event.Hook, event: MishkaCmsCore.Runtime.ShareCard.targets_event()

  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Test.ShareCardLookWorker

  @impl true
  def call(%{site_id: site_id, force: force} = data) do
    name = :persistent_term.get({__MODULE__, :name}, "test_producer")
    {:reply, ShareCard.put_targets(data, name, fn -> targets(site_id, force) end)}
  end

  defp targets(site_id, force) do
    :persistent_term.put({__MODULE__, :reads}, :persistent_term.get({__MODULE__, :reads}, 0) + 1)
    count = :persistent_term.get({__MODULE__, :count}, 3)
    things = for n <- 1..count//1, do: {:record, "test:thing", %{"slug" => "thing-#{n}"}}

    things ++
      Enum.take(things, 1) ++
      [
        ShareCardLookWorker.new(%{site_id: site_id, theme: "home", force: force}),
        ShareCardLookWorker.new(%{site_id: site_id, theme: "elsewhere"}, queue: :default)
      ]
  end
end
