defmodule MishkaCmsCore.Runtime.PageShareCardTargets do
  @moduledoc """
  A plain mishka_installer plugin: answers `MishkaCmsCore.Runtime.ShareCard.targets_event/0` with
  the core's own share cards on the site asked — each active page that shows no record, as
  `{:page, id}`, under `"mishka_cms_core"`. A page that shows records is left to the producer of
  those records. The pages are streamed by id, as the system reads them for a share card
  (`MishkaCmsCore.Runtime.ShareCard.specs/3`). Registered in `MishkaCmsCore.Application`.
  """
  use MishkaInstaller.Event.Hook,
    event: MishkaCmsCore.Runtime.ShareCard.targets_event(),
    initial: %{priority: 50}

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Page, Seo, ShareCard}

  @producer "mishka_cms_core"

  @doc "The name the core's own targets are put under: `\"#{@producer}\"`."
  @spec producer() :: String.t()
  def producer, do: @producer

  @impl true
  def call(%{site_id: site_id} = data),
    do: {:reply, ShareCard.put_targets(data, @producer, fn -> pages(site_id) end)}

  def call(data), do: {:reply, data}

  defp pages(site_id) do
    Page
    |> Ash.Query.filter(active == true)
    |> Ash.Query.select([:id, :extra])
    |> Ash.stream!(tenant: site_id, authorize?: false, batch_size: 500)
    |> Stream.reject(&Seo.record_of(&1.extra))
    |> Stream.map(&{:page, &1.id})
  end
end
