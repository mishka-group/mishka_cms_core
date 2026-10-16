# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.AssetsGrid do
  @moduledoc """
  A MishkaGervaz table template: the file grid in the builder's Assets sheet.

  ## Why the sheet has its own template at all

  It is the same resource as the Media library and deliberately the same CARD — a file should not
  look like two different things depending on which screen you found it on, so `render_item/1` is
  `MishkaGervaz.Table.Templates.MediaGallery`'s, unchanged. What differs is everything around the
  card, because the two surfaces are not the same shape:

    * The library is a page. It can afford a filter bar with Type, Site, Featured and the archive
      switch, all laid out across the width.
    * The sheet is 620px of overlay with a folder rail down one side and a dropzone at the top.
      There is room for one control, and the one that earns it is search. The folders answer the
      question Type and Site would have answered, and they answer it in the sidebar where the reader
      is already looking.

  Nothing here removes those filters from the resource; they are simply not drawn on this surface.

  ## How it gets chosen

  `MishkaGervaz.Table.Web.Live` takes a `template` assign — see
  `MishkaGervaz.Table.Web.State.apply_presentation/2`. The Media library passes none and keeps its
  own; the sheet passes this one. One resource, two surfaces, no fork.

  ## Nothing here is drawn twice

  The search box is the adapter's `text_input` in its filter variant and the view switch is
  `Shared.render_template_switcher/1` — the same two controls the library's own filter bar draws.
  Both were hand-rolled here first, and both drifted: a 34px search box beside a 42px one, and a
  switcher whose active tab was a filled violet square where the library's is a white pill.

  ## Which clicks go where

  `filter`, `load_more` and `switch_template` are Gervaz's own events and carry
  `phx-target={@myself}`. Everything the EDITOR owns — using a file in the document, the folder rail
  — is the parent LiveView's and carries no target.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCoreWeb.Templates.AssetsChrome
  alias MishkaGervaz.Table.Templates.MediaGallery
  alias MishkaGervaz.Table.Templates.Shared

  @impl true
  def name, do: :assets_grid

  @impl true
  def label, do: dgettext("mishka_gervaz", "Grid")

  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "The site's files, as cards")

  @impl true
  def features, do: [:filter, :paginate, :select, :bulk_actions]

  @impl true
  def default_options, do: []

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div data-role="pb-assets-skeleton" class="grid grid-cols-2 gap-2.5">
      <div :for={_tile <- 1..4//1} class="h-[132px] animate-pulse rounded-[12px] bg-[#f4f3ee]"></div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns = Shared.assign_card_flags(assigns)

    ~H"""
    <div id={@static.id} data-role="pb-assets-grid" class="flex flex-col gap-3">
      <AssetsChrome.toolbar static={@static} state={@state} myself={@myself} />

      <AssetsChrome.selection
        static={@static}
        state={@state}
        myself={@myself}
        show_checkboxes={@show_checkboxes}
        show_bulk_actions={@show_bulk_actions}
      />

      <AssetsChrome.empty static={@static} state={@state} myself={@myself} empty?={@empty?} />

      <div
        id={@static.stream_name}
        phx-update="stream"
        class="grid grid-cols-2 gap-2.5 max-[420px]:grid-cols-1"
      >
        <.render_item
          :for={{id, record} <- @stream}
          id={id}
          record={record}
          static={@static}
          state={@state}
          myself={@myself}
          show_checkboxes={@show_checkboxes}
        />
      </div>

      <AssetsChrome.pagination static={@static} state={@state} myself={@myself} />
    </div>
    """
  end

  @doc """
  The shared media card, with ONE thing decided differently while a pick is in progress.

  A card has room for exactly one action that says what it does in words; the rest are glyphs
  (see `MishkaGervaz.Table.Templates.MediaGallery.split_actions/3`). That slot defaults to Edit,
  which is right on the Media page — and wrong here, because on this surface the reader did not come
  to edit a file, they came to put one in the document. `Use` was in the glyph row, unlabelled,
  beside Preview, Edit and Archive, so the sheet said "Choosing for image" and then gave no visible
  answer to "how?". Reported on the editor issue as "there is no way at all to tell how to bring it
  into the navbar".

  Only while something is actually waiting for a file: with no pick in flight the `Use` action is not
  rendered at all (`MishkaCmsCore.Runtime.Media` hides it), so the slot goes back to Edit and the
  card is the Media page's card again.
  """
  @impl true
  def render_item(assigns) do
    assigns
    |> Map.update!(:static, &use_first(&1, assigns.state))
    |> MediaGallery.render_item()
  end

  @doc """
  Which action the card gives its one labelled slot to, for a given table state.

  `[]` — no opinion, so the card keeps the Media page's defaults — unless something in the editor is
  waiting for a file, which `editor_pick_node` is the signal for. It is the same param that makes the
  `Use` action visible at all, so the two can never disagree about whether a pick is in flight.
  """
  @spec picking_options(map()) :: keyword()
  def picking_options(%{path_params: params}) do
    case params[:editor_pick_node] do
      node when is_binary(node) ->
        [overlay_action: :toggle_featured, primary_action: :use_in_editor]

      _not_picking ->
        []
    end
  end

  defp use_first(static, state) do
    case picking_options(state) do
      [] -> static
      options -> Map.put(static, :template_options, options)
    end
  end
end
