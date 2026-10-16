# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.AssetsList do
  @moduledoc """
  A MishkaGervaz table template: the file LIST in the builder's Assets sheet.

  The sheet's other view of the same files — `MishkaCmsCoreWeb.Templates.AssetsGrid` is the cards,
  this is the rows, and the switcher in the toolbar moves between them.

  ## Why it exists at all

  The switcher used to offer Gervaz's own `MishkaGervaz.Table.Templates.Table`, and half of it was
  off the screen. That template draws a PAGE — a filter bar with Search, Type, Site, Featured and
  the archive switch laid across the width, then a multi-column table with a header. The sheet is
  620px of overlay with a folder rail down one side, so the filters, the Type column and the actions
  all ran past the right edge with no way to reach them.

  A row here is the card's information in one line: the same thumbnail, the same name and meta, the
  same actions. What it drops is everything that only pays for itself at page width — the column
  header, sorting, and columns for values the row already says in words.

  The chrome above and below it — search, the switcher, select-all, the bulk bar and the paging — is
  `MishkaCmsCoreWeb.Templates.AssetsChrome`, shared with the grid so the two views differ in exactly
  one thing.

  ## The thumbnail

  A row's image hides itself when it fails to load, leaving the tinted square rather than a broken
  icon, and the admin bundle's `MediaThumb` hook is what notices — see
  `MishkaGervaz.Table.Templates.MediaGallery`. The `onerror=` attribute this replaces is blocked
  outright once a Content-Security-Policy is enforced, and no nonce applies to an event handler.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCoreWeb.Templates.AssetsChrome
  alias MishkaGervaz.Table.Templates.MediaGallery
  alias MishkaGervaz.Table.Templates.Shared

  @impl true
  def name, do: :assets_list

  @impl true
  def label, do: dgettext("mishka_gervaz", "List")

  @impl true
  def icon, do: "hero-queue-list"

  @impl true
  def description, do: dgettext("mishka_gervaz", "The site's files, as rows")

  @impl true
  def features, do: [:filter, :paginate, :select, :bulk_actions]

  @impl true
  def default_options, do: []

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div data-role="pb-assets-skeleton" class="flex flex-col gap-1.5">
      <div :for={_row <- 1..5//1} class="h-[52px] animate-pulse rounded-[11px] bg-[#f4f3ee]"></div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns = Shared.assign_card_flags(assigns)

    ~H"""
    <div id={@static.id} data-role="pb-assets-list" class="flex flex-col gap-3">
      <AssetsChrome.toolbar static={@static} state={@state} myself={@myself} />

      <AssetsChrome.selection
        static={@static}
        state={@state}
        myself={@myself}
        show_checkboxes={@show_checkboxes}
        show_bulk_actions={@show_bulk_actions}
      />

      <AssetsChrome.empty static={@static} state={@state} myself={@myself} empty?={@empty?} />

      <div id={@static.stream_name} phx-update="stream" class="flex flex-col gap-1.5">
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

  @impl true
  def render_item(assigns) do
    static = %{
      assigns.static
      | ui_adapter: MediaGallery.gallery_ui_adapter(assigns.static.ui_adapter)
    }

    state = assigns.state
    record = assigns.record

    checked? = MediaGallery.selected?(state, record)

    checkbox_assigns =
      %{__changed__: %{}}
      |> assign(:name, "select_media")
      |> assign(:value, record.id)
      |> assign(:checked, checked?)
      |> assign(:class, "gervaz-media-checkbox size-4 cursor-pointer rounded accent-[#5b57d6]")

    actions =
      static.row_actions
      |> Shared.non_accordion_actions()
      |> Enum.filter(&Shared.action_visible?(&1, record, state))
      |> MediaGallery.split_actions(static, MediaGallery.featured?(record))

    assigns =
      assigns
      |> assign(:static, static)
      |> assign(:checked?, checked?)
      |> assign(:checkbox_assigns, checkbox_assigns)
      |> assign(:star_actions, actions.overlay)
      |> assign(:row_actions, actions.primary ++ actions.secondary)
      |> assign(:image_url, MediaGallery.thumbnail_url(static, state, record))
      |> assign(:tint, MediaGallery.tint(record))
      |> assign(:media_type, MediaGallery.media_type(record))
      |> assign(:ext, MediaGallery.media_ext(record))
      |> assign(:filename, MediaGallery.media_name(record))
      |> assign(:size_label, MediaGallery.media_size(record))
      |> assign(:category, MediaGallery.media_category(record))
      |> assign(:featured?, MediaGallery.featured?(record))

    ~H"""
    <div
      id={@id}
      class={[
        "flex items-center gap-2.5 rounded-[11px] border bg-white px-2.5 py-2",
        cond do
          @checked? -> "border-[#dcdbf5] ring-1 ring-[#5b57d6]"
          @featured? -> "border-[#f0e2c4]"
          true -> "border-[#ecebe6] hover:border-[#dcdbf5]"
        end
      ]}
    >
      <span :if={@show_checkboxes} class="flex-none">
        <.dynamic_component
          module={@static.ui_adapter}
          function={:checkbox}
          phx-click="toggle_select"
          phx-value-id={@record.id}
          phx-target={@myself}
          {@checkbox_assigns}
        />
      </span>

      <span
        id={"#{@id}-thumb"}
        phx-hook="MediaThumb"
        class={[
          "relative grid size-9 flex-none place-items-center overflow-hidden rounded-[8px]",
          @tint
        ]}
      >
        <img
          :if={@image_url}
          src={@image_url}
          alt=""
          loading="lazy"
          class="absolute inset-0 size-full object-cover"
        />
        <MediaGallery.type_glyph :if={!@image_url} type={@media_type} class="size-[15px]" />
      </span>

      <span class="min-w-0 flex-1">
        <span class="flex items-center gap-1.5">
          <span
            dir="auto"
            class="min-w-0 truncate text-[11.5px] font-semibold text-[#1b1a18]"
            title={@filename}
          >
            {@filename}
          </span>
          <span
            :if={@ext}
            class="flex-none rounded-[5px] bg-[#f4f3ee] px-[5px] py-[1px] text-[8.5px] font-bold uppercase tracking-[0.05em] text-[#6d6a63]"
          >
            {@ext}
          </span>
        </span>
        <span class="mt-[3px] flex items-center gap-1.5 text-[10px]">
          <span class="flex-none font-['Space_Grotesk'] font-semibold text-[#8a877f]">
            {@size_label}
          </span>
          <span :if={@category} class="size-[3px] flex-none rounded-full bg-[#c3c0b8]"></span>
          <span :if={@category} class="min-w-0 truncate font-medium text-[#a8a5a0]">
            {@category}
          </span>
        </span>
      </span>

      <div
        :if={@star_actions != [] or @featured?}
        class={[
          "flex-none [&>div]:contents [&_.lbl]:hidden [&_button]:size-[26px] [&_button]:rounded-[8px] [&_button]:border-0 [&_button]:bg-transparent [&_button]:text-inherit [&_button]:hover:text-inherit",
          (@featured? && "text-[#e6b422]") || "text-[#c3c0b8] hover:text-[#e6b422]"
        ]}
      >
        <Shared.render_row_actions
          :if={@star_actions != []}
          row_actions={@star_actions}
          record={@record}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>

      <div
        :if={@row_actions != []}
        class="flex flex-none items-center gap-1 [&>div]:contents [&_.lbl]:hidden [&_button]:size-[26px]"
      >
        <Shared.render_row_actions
          row_actions={@row_actions}
          record={@record}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>
    </div>
    """
  end
end
