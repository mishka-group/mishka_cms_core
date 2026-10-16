# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.ShareCardRedraw do
  @moduledoc """
  A Redraw share cards button: after a confirmation, every share card of a site — or of every
  active site — is drawn again over its old file in the background
  (`MishkaCmsCore.Runtime.ShareCard.redraw_all/2` with `force: true`), one at a time on the
  `:share_cards` queue, and the button says how many cards were queued once the planner has
  collected them.

  The settings page's SEO tab draws one for every producer together and one for each producer
  that answers `MishkaCmsCore.Runtime.ShareCard.targets_event/0` on the site; an extension's
  "on this site" modal draws one for its own (`MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel.doctor_modal/1`).

  Assigns:

    * `:id`
    * `:site_id` — the site, or `nil` for every active site
    * `:producer` — the one producer to redraw, `"mishka_blog"`; `nil` for every one
    * `:allowed?` — whether the viewer may redraw them; the parent decides, the button refuses
      without it
    * `:title`, `:blurb`, `:action` — what the row says, and the button
    * `:wait` — how many milliseconds the count is waited for, 60 000 by default
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.Workers.ShareCardPlanWorker

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         state: :idle,
         counts: nil,
         site_id: nil,
         producer: nil,
         allowed?: false,
         wait: 60_000
       )}

  @impl true
  def update(assigns, socket) do
    moved? =
      Map.get(assigns, :site_id, socket.assigns.site_id) != socket.assigns.site_id or
        Map.get(assigns, :producer, socket.assigns.producer) != socket.assigns.producer

    socket = assign(socket, assigns)

    {:ok, if(moved?, do: assign(socket, state: :idle, counts: nil), else: socket)}
  end

  @impl true
  def handle_event("redraw", _params, %{assigns: %{allowed?: true, state: state}} = socket)
      when state != :queuing do
    %{site_id: site_id, producer: producer, wait: wait} = socket.assigns

    {:noreply,
     socket
     |> assign(state: :queuing, counts: nil)
     |> MishkaGervaz.Messages.start_async(:redraw, fn -> redraw(site_id, producer, wait) end)}
  end

  def handle_event("redraw", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:redraw, {:ok, {:ok, counts}}, socket),
    do: {:noreply, assign(socket, state: :queued, counts: counts)}

  def handle_async(:redraw, {:ok, {:waiting, counts}}, socket),
    do: {:noreply, assign(socket, state: :waiting, counts: counts)}

  def handle_async(:redraw, _failed, socket),
    do: {:noreply, assign(socket, state: :failed, counts: nil)}

  # Listens first, so a planner that runs at once is not missed; then queues one planner a site and
  # adds up what each says it queued, until every site answered or `wait` runs out.
  defp redraw(site_id, producer, wait) do
    :ok = Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, ShareCardPlanWorker.planned_topic())

    case ShareCard.redraw_all(site_id, force: true, producer: producer) do
      {:ok, sites} ->
        deadline = System.monotonic_time(:millisecond) + wait
        collect(MapSet.new(sites), producer, %{sites: length(sites), cards: 0}, deadline)

      {:error, _reason} = error ->
        error
    end
  end

  defp collect(left, producer, counts, deadline) do
    if MapSet.size(left) == 0 do
      {:ok, counts}
    else
      receive do
        {:share_cards_planned, %{site_id: site, force: true, producer: ^producer, counts: found}} ->
          if MapSet.member?(left, site) do
            counts = %{counts | cards: counts.cards + Enum.sum(Map.values(found))}
            collect(MapSet.delete(left, site), producer, counts, deadline)
          else
            collect(left, producer, counts, deadline)
          end
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:waiting, counts}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="text-[13px] font-bold text-[#17161a]">{@title}</div>
        <div :if={@blurb} class="mt-0.5 text-[12px] font-medium text-[#8a877f]">{@blurb}</div>
        <div
          :if={@state != :idle}
          id={"#{@id}-status"}
          class={[
            "mt-1.5 text-[12px] font-semibold",
            if(@state == :failed, do: "text-[#c2410c]", else: "text-[#177a53]")
          ]}
        >
          {status(@state, @counts)}
        </div>
      </div>

      <button
        id={"#{@id}-button"}
        type="button"
        phx-click="redraw"
        phx-target={@myself}
        disabled={!@allowed? or @state == :queuing}
        data-confirm={
          gettext(
            "Every share card here is drawn again, one at a time, in the background. Pages keep showing their current card until the new one is written. Go on?"
          )
        }
        class="flex h-[42px] shrink-0 items-center gap-2 rounded-xl border border-[#ecebe6] bg-white px-[15px] text-[12.5px] font-semibold text-[#3a382f] transition-colors hover:bg-[#f6f5f2] disabled:cursor-not-allowed disabled:opacity-50"
      >
        <.icon name="hero-photo" class="size-4 text-[#6d6a63]" /> {@action}
      </button>
    </div>
    """
  end

  defp status(:queuing, _counts), do: gettext("Queuing…")

  defp status(:queued, %{cards: cards, sites: 1}),
    do: ngettext("Queued 1 share card.", "Queued %{count} share cards.", cards)

  defp status(:queued, %{cards: cards, sites: sites}),
    do:
      gettext("Queued %{cards} on %{sites} sites.",
        cards: ngettext("1 share card", "%{count} share cards", cards),
        sites: sites
      )

  defp status(:waiting, _counts),
    do:
      gettext(
        "Queued. The share-card queue has not reached it yet: the cards are counted and drawn once it does."
      )

  defp status(:failed, _counts), do: gettext("The share cards could not be queued.")
  defp status(_state, _counts), do: nil
end
