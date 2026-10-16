# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.ShareCardField do
  @moduledoc """
  The share card a page or a record shows where a link to it is shared
  (`MishkaCmsCore.Runtime.ShareCard`), in its edit modal: the card as drawn, and **Regenerate**,
  which draws it again over the old file (`ShareCard.refresh(site_id, target, force: true)`) and
  shows the new one once it is written.

  Handed the `target` (`t:MishkaCmsCore.Runtime.ShareCard.target/0`) — the page builder's SEO tab
  — or the `record` a form edits and `target_of`, a function of it returning the target, `nil` for
  a record that shows none: what `MishkaCmsCoreWeb.UIAdapters.Admin.text_input/1` hands it for a
  field whose `ui` says `extra %{share_card: &target/1}`. `target_of` runs with the card's read,
  in the background, never while the modal is drawn.

  A card not drawn yet is queued when the panel opens (`ShareCard.refresh/3`) and shown once it is
  written; a record saved while its modal is open is read again.

  It is its own component because it reads the card in the background and keeps looking until a
  regenerated one is written.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Runtime.ShareCard
  alias Phoenix.LiveView.AsyncResult

  # How often, and how many times, a regenerated card is looked for.
  @recheck_ms 1500
  @rechecks 8

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         cards: AsyncResult.loading(),
         drawing?: false,
         since: nil,
         shown: nil,
         given: nil,
         target: nil,
         record: nil,
         target_of: nil,
         disabled: false
       )}

  # Looked at again after Regenerate, until every card was written since the click or `left` runs
  # out.
  @impl true
  def update(%{recheck: left}, socket) do
    cards = ShareCard.cards(socket.assigns.site_id, socket.assigns.target)
    since = socket.assigns.since
    drawn? = Enum.all?(cards, &(is_integer(&1.drawn_at) and &1.drawn_at >= since))

    if not drawn? and left > 0,
      do: send_update_after(__MODULE__, [id: socket.assigns.id, recheck: left - 1], @recheck_ms)

    {:ok, assign(socket, cards: AsyncResult.ok(cards), drawing?: not drawn? and left > 0)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :site_id, :record, :target_of, :disabled]))
      |> assign(:given, assigns[:target])

    if socket.assigns.shown == shown(socket.assigns),
      do: {:ok, socket},
      else: {:ok, load(socket)}
  end

  # What is shown: one site's target, or one record as it was saved — not every redraw of the modal
  # it is in.
  defp shown(%{site_id: site_id, given: target}) when not is_nil(target), do: {site_id, target}

  defp shown(%{site_id: site_id, record: %{__struct__: kind, id: id} = record}),
    do: {site_id, kind, id, Map.get(record, :updated_at)}

  defp shown(_assigns), do: nil

  defp load(%{assigns: %{site_id: site_id} = assigns} = socket) when is_binary(site_id) do
    case {assigns.given, assigns.record, assigns.target_of} do
      {nil, %{} = record, target_of} when is_function(target_of, 1) ->
        start(socket, fn -> target_of.(record) end)

      {target, _record, _target_of} when not is_nil(target) ->
        start(socket, fn -> target end)

      _nothing_to_show ->
        assign(socket, shown: nil, cards: AsyncResult.ok([]))
    end
  end

  defp load(socket), do: assign(socket, shown: nil, cards: AsyncResult.ok([]))

  defp start(socket, target) do
    site_id = socket.assigns.site_id

    socket
    |> assign(shown: shown(socket.assigns), cards: AsyncResult.loading())
    |> MishkaGervaz.Messages.start_async(:cards, fn ->
      case target.() do
        nil -> {nil, []}
        target -> {target, ShareCard.cards(site_id, target)}
      end
    end)
  end

  @impl true
  def handle_async(:cards, {:ok, {target, cards}}, socket) do
    socket = assign(socket, target: target, cards: AsyncResult.ok(cards))

    if Enum.any?(cards, &is_nil(&1.drawn_at)) do
      ShareCard.refresh(socket.assigns.site_id, target)
      send_update_after(__MODULE__, [id: socket.assigns.id, recheck: @rechecks], @recheck_ms)
      {:noreply, assign(socket, drawing?: true, since: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:cards, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :cards, AsyncResult.failed(socket.assigns.cards, reason))}

  @impl true
  def handle_event(
        "regenerate",
        _params,
        %{assigns: %{site_id: site_id, target: target}} = socket
      )
      when is_binary(site_id) and not is_nil(target) do
    :ok = ShareCard.refresh(site_id, target, force: true)
    send_update_after(__MODULE__, [id: socket.assigns.id, recheck: @rechecks], @recheck_ms)
    {:noreply, assign(socket, drawing?: true, since: System.os_time(:second))}
  end

  def handle_event("regenerate", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :shown_cards, (assigns.cards.ok? && assigns.cards.result) || [])

    ~H"""
    <div id={@id} data-role="share-card-field" class="flex min-w-0 flex-col gap-3">
      <div
        :if={@cards.loading}
        class="h-[120px] w-[240px] max-w-full animate-pulse rounded-[12px] border border-[#ecebe6] bg-[#f6f5f2]"
      >
      </div>

      <p :if={@cards.failed} class="m-0 text-[12.5px] font-medium text-[#a5352c]">
        {gettext("The share image could not be read.")}
      </p>

      <p
        :if={@cards.ok? && @shown_cards == []}
        id={@id <> "-none"}
        class="m-0 text-[12.5px] font-medium text-[#8a877f]"
      >
        {gettext("No share image: this is not public yet, or its SEO sets an image of its own.")}
      </p>

      <div
        :for={{card, i} <- Enum.with_index(@shown_cards)}
        id={"#{@id}-card-#{i}"}
        class="flex min-w-0 items-center gap-3"
      >
        <a
          :if={card.drawn_at}
          href={card.url}
          target="_blank"
          rel="noopener"
          class="block w-[240px] max-w-[60%] flex-none overflow-hidden rounded-[10px] border border-[#ecebe6]"
        >
          <img
            src={"#{card.url}?v=#{card.drawn_at}"}
            alt={card.title}
            width="1200"
            height="630"
            class="block h-auto w-full"
          />
        </a>
        <div
          :if={!card.drawn_at}
          class="grid aspect-[1200/630] w-[240px] max-w-[60%] flex-none place-items-center rounded-[10px] border border-dashed border-[#d9d7d0] bg-[#faf9f6] px-3 text-center text-[11.5px] font-medium text-[#8a877f]"
        >
          {gettext("Not drawn yet")}
        </div>
        <span class="min-w-0 truncate text-[12.5px] font-semibold text-[#3a382f]" dir="auto">
          {card.title}
        </span>
      </div>

      <div :if={@shown_cards != []} class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          id={@id <> "-regenerate"}
          phx-click="regenerate"
          phx-target={@myself}
          disabled={@drawing? || @disabled == true}
          class="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-[#ecebe6] bg-white px-3 text-[12.5px] font-semibold text-[#3a382f] hover:border-[#c3c1f0] hover:text-[#5b57d6] disabled:cursor-wait disabled:opacity-60"
        >
          <.icon
            name="hero-arrow-path-mini"
            class={if(@drawing?, do: "size-4 animate-spin", else: "size-4")}
          />
          {if @drawing?, do: gettext("Drawing…"), else: gettext("Regenerate")}
        </button>
        <span class="text-[11.5px] font-medium text-[#9a978f]">
          {gettext("Drawn again from what this shows now, replacing the old picture.")}
        </span>
      </div>
    </div>
    """
  end
end
