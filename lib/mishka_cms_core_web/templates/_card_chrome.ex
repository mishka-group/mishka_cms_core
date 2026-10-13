defmodule MishkaCmsCoreWeb.Templates.CardChrome do
  @moduledoc """
  The chrome every document card page wears: the control row, the count over the list, the loading
  veils and the pagination underneath.

  `MishkaDocumentWeb.Templates.IssueCard`, `MishkaDocumentWeb.Templates.DocumentSection` and
  `MishkaBlogWeb.Templates.CollectionCard` draw the same
  furniture around different cards — only `render_item/1` really differs between them — so the furniture
  lives here once rather than being copied per template.

  Most of what is here are the pieces, and a template that lays its page out differently takes only the
  pieces it wants. But the six blog card pages had assembled those pieces into byte-identical pages —
  six copies of the same ninety lines differing in a wrapper class, two empty labels and an icon — so
  `card_scaffold/1` is the assembled page as well, for the templates whose layout genuinely is the
  common one. A template with its own layout (`MishkaDocumentWeb.Templates.DocumentCard`) still builds
  it from the pieces.

  Everything here is a plain `Phoenix.Component`, so a template calls it as
  `<Shared.filter_bar … />`. The events (`filter`, `clear_filters`, `archive_filter`,
  `change_page_size`, `prev_page` / `next_page` / `go_to_page`, `toggle_select_all`) and the input names
  are Gervaz's contract — only the look is ours.

  See `MishkaGervaz.Table.Templates.Shared`, which this leans on for the parts that stay generic
  (`render_filter/1`, `render_bulk_actions/1`, relation filter state), and
  `MishkaCmsCoreWeb.UIAdapters.Admin`, which draws the archive switch and the row actions.
  """

  use Phoenix.Component
  use MishkaGervaz.Messages

  import MishkaCmsCore.CoreComponents, only: [icon: 1, select_chevron: 1]
  import MishkaGervaz.Helpers, only: [dynamic_component: 1, accessible?: 2]

  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz
  alias Phoenix.LiveView.JS

  @doc """
  The control row — search, the archive switch, an Advanced panel holding every other filter — plus
  whatever the page wants on either side of it.

  Nothing here names a filter: the one `:text` filter becomes the search box and the rest fall into the
  panel, so the resource stays the single source of truth. `accessible?/2` is what keeps a `restricted`
  filter (a site or contributor picker) away from a tenant and a `visible false` one (a deep-link id)
  out of the panel entirely.

  The archive switch draws its own `archive_filter` form, so it stays a **sibling** of the filter form
  rather than a child — a nested form is dropped by the parser, and its `status` radio would then be
  serialized into `filter`, where it collides with a status filter of the same name and narrows every
  search to nothing. The filter form is `display: contents`, so this row lays its children out and
  `order-*` puts them back in the design's sequence.

  ## Slots
  - `:leading` — sits before the search box (a primary action such as "Add Section")
  - `:trailing` — sits after the Advanced button (a view switcher)
  """
  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true
  attr :search_placeholder, :string, default: nil

  slot :leading
  slot :trailing

  def filter_bar(assigns) do
    all_filters =
      Gervaz.merge_relation_filter_state(
        assigns.static.filters,
        assigns.state.relation_filter_state || %{}
      )

    {search, advanced} =
      all_filters
      |> Enum.filter(&accessible?(&1, assigns.state))
      |> Enum.split_with(&(&1.type == :text))

    assigns =
      assigns
      |> assign(:all_filters, all_filters)
      |> assign(:search, List.first(search))
      |> assign(:advanced, advanced)
      |> assign(:active_filters?, map_size(assigns.state.filter_values || %{}) > 0)
      |> assign(:panel_id, "#{assigns.static.stream_name}-advanced")

    ~H"""
    <div data-role="sec-toolbar" class="mb-4 flex flex-wrap items-center gap-3">
      <%!-- The design leads with the primary action on a wide screen and with the search box on a
            narrow one, so every child carries its own `order` rather than relying on source order. --%>
      <div :if={@leading != []} class="order-1 flex-none max-[860px]:order-2!">
        {render_slot(@leading)}
      </div>

      <div :if={@state.supports_archive} class="order-3">
        <.dynamic_component
          module={@static.ui_adapter}
          function={:archive_toggle}
          table_id={@static.id}
          archive_status={@state.archive_status}
          myself={@myself}
        />
      </div>

      <div :if={@trailing != []} class="order-5 flex-none">{render_slot(@trailing)}</div>

      <form
        id={"#{@static.stream_name}-filter"}
        phx-change="filter"
        phx-target={@myself}
        class="contents"
      >
        <div
          :if={@search}
          data-role="sec-search"
          class="relative order-2 min-w-[210px] flex-1 max-[860px]:order-1! max-[860px]:basis-full!"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-magnifying-glass"
            class="pointer-events-none absolute start-[14px] top-1/2 size-4 -translate-y-1/2 text-[#a8a5a0]"
          />
          <input
            type="text"
            name={@search.name}
            value={Map.get(@state.filter_values, @search.name) || ""}
            dir="auto"
            placeholder={placeholder(@search, @search_placeholder)}
            phx-debounce="300"
            class="h-[42px] w-full rounded-xl border border-[#ecebe6] bg-white ps-10 pe-3.5 text-[13px] font-medium text-[#1b1a18] outline-none transition-colors focus:border-[#c3c1f0]"
          />
        </div>

        <button
          :if={@advanced != []}
          type="button"
          id={"#{@panel_id}-btn"}
          phx-click={toggle_advanced(@panel_id)}
          aria-controls={@panel_id}
          class="order-4 inline-flex h-[42px] flex-none items-center gap-[7px] rounded-xl border border-[#ecebe6] bg-white px-[15px] text-[12.5px] font-semibold text-[#5c5a54] transition-colors"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-adjustments-horizontal"
            class="size-[15px]"
          />
          {dgettext("mishka_gervaz", "Advanced")}
        </button>

        <div :if={@advanced != []} id={@panel_id} class={["order-6 hidden basis-full", panel_class()]}>
          <div class="grid grid-cols-3 gap-3 [&>*]:min-w-0 max-[860px]:grid-cols-2! max-[640px]:grid-cols-1!">
            <Gervaz.render_filter
              :for={filter <- @advanced}
              filter={filter}
              all_filters={@all_filters}
              state={@state}
              static={@static}
              myself={@myself}
            />
          </div>

          <button
            :if={@active_filters?}
            type="button"
            phx-click="clear_filters"
            phx-target={@myself}
            class="mt-4 inline-flex h-[30px] items-center gap-1.5 rounded-lg border border-[#ecebe6] bg-white px-[11px] text-[11.5px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
          >
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-x-mark"
              class="size-[13px] text-[#a8a5a0]"
            />
            {dgettext("mishka_gervaz", "Clear filters")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  # The panel restyles the labels and inputs `MishkaGervaz.Table.Templates.Shared.render_filter/1`
  # brings with it rather than printing a second set beside them. `!` where a base utility sets the
  # same property — the runtime compiler emits two bundles and their order is not reliable.
  defp panel_class do
    [
      "rounded-[14px] border border-[#e4e2f7] bg-white px-[18px] py-4",
      "[&_label]:mb-[9px]! [&_label]:text-[10px]! [&_label]:font-bold! [&_label]:uppercase",
      "[&_label]:tracking-[0.07em] [&_label]:text-[#8a877f]"
    ]
  end

  # The panel opens client-side: it is already rendered, and asking the server to remember whether a
  # filter drawer is open would cost a round trip per click. Both class sets are swapped rather than one
  # layered over the other — they set the same properties, and which wins would otherwise be down to
  # their order in the stylesheet.
  defp toggle_advanced(panel_id) do
    JS.toggle(to: "##{panel_id}")
    |> JS.toggle_class("border-[#ecebe6] bg-white text-[#5c5a54]", to: "##{panel_id}-btn")
    |> JS.toggle_class("border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]", to: "##{panel_id}-btn")
  end

  defp placeholder(filter, override) do
    MishkaGervaz.Helpers.resolve_label((filter.ui && filter.ui.placeholder) || override) ||
      dgettext("mishka_gervaz", "Search…")
  end

  @doc """
  The head of an admin modal: an icon tile, a title, and the thing the modal is about beneath it.

  Every modal on these pages wears the same head — version history, an edition's details, an edit form —
  so they read as one surface with different contents rather than three unrelated dialogs. Pair it with
  `MishkaCmsCore.CoreComponents.modal/1` given `padding_class="p-0"`, which is what lets the head sit
  edge to edge above a scrolling body.

  The right padding leaves room for the modal's own close button; anything in the `:actions` slot sits
  to the left of it. When the icon, title and subtitle need the row, the actions move to a row of
  their own beneath them, wrapping again if they still do not fit.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :tone, :string, default: "bg-[#f2f1fc] text-[#5b57d6]"

  slot :actions

  def modal_head(assigns) do
    ~H"""
    <div
      data-role="modal-head"
      class="flex flex-wrap items-start justify-between gap-x-[11px] gap-y-3 border-b border-[#f0efea] py-[18px] ps-[22px] pe-14"
    >
      <div data-role="modal-head-title" class="flex min-w-0 flex-auto items-start gap-[11px]">
        <span class={["grid size-9 flex-none place-items-center rounded-[10px]", @tone]}>
          <.icon name={@icon} class="size-[18px]" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="font-['Space_Grotesk'] text-[16px] font-bold text-[#17161a]">{@title}</div>
          <div :if={@subtitle} class="mt-px truncate text-[12px] font-medium text-[#8a877f]">
            {@subtitle}
          </div>
        </div>
      </div>
      <div
        :if={@actions != []}
        data-role="modal-head-actions"
        class="flex flex-wrap items-center gap-2"
      >
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  The scrolling body of an admin modal, capped so the head and footer stay put on a short screen.

  Its scrollbar is hidden, as every scrolling surface in this admin is.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def modal_body(assigns) do
    ~H"""
    <div class={[
      "max-h-[min(60vh,520px)] overflow-y-auto px-[22px] py-4 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The footer of an admin modal — a ruled band under the body for counts and controls."
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def modal_footer(assigns) do
    ~H"""
    <div class={[
      "flex flex-wrap items-center justify-between gap-3 border-t border-[#f0efea] px-[22px] py-3.5",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Every filter laid out at once, each under its own label, with the switches and the count beneath.

  The alternative to `filter_bar/1`: a page with only a handful of filters shows them all rather than
  hiding them behind a drawer. `:boolean` filters drop out of the grid and join the Select-all line as
  switches, which is where a "Featured only" reads naturally.

  All of it — including Select all — sits in **one** `phx-change="filter"` form, because Gervaz rebuilds
  the whole filter set from the submitted params on every change: a filter left out of the form is a
  filter cleared. The archive switch stays outside, since it draws a form of its own and a nested form
  is dropped by the parser.
  """
  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true
  attr :show_checkboxes, :boolean, required: true
  attr :empty_label, :string, default: nil

  def filter_grid(assigns) do
    all_filters =
      Gervaz.merge_relation_filter_state(
        assigns.static.filters,
        assigns.state.relation_filter_state || %{}
      )

    {switches, fields} =
      all_filters
      |> Enum.filter(&accessible?(&1, assigns.state))
      |> Enum.split_with(&(&1.type == :boolean))

    assigns =
      assigns
      |> assign(:all_filters, all_filters)
      |> assign(:switches, switches)
      |> assign(:fields, fields)
      |> assign(:active_filters?, map_size(assigns.state.filter_values || %{}) > 0)
      |> assign(:count, range_label(assigns.state, page_size(assigns), assigns.empty_label))

    ~H"""
    <div :if={@state.supports_archive} class="mb-3.5 flex">
      <.dynamic_component
        module={@static.ui_adapter}
        function={:archive_toggle}
        table_id={@static.id}
        archive_status={@state.archive_status}
        myself={@myself}
      />
    </div>

    <form
      id={"#{@static.stream_name}-filter"}
      phx-change="filter"
      phx-target={@myself}
      class="contents"
    >
      <div
        :if={@fields != []}
        data-role="col-filters"
        class={[
          "mb-4 grid grid-cols-[2fr_repeat(3,1fr)] items-end gap-3.5",
          "[&>*]:min-w-0 max-[860px]:grid-cols-2! max-[640px]:grid-cols-1!"
        ]}
      >
        <Gervaz.render_filter
          :for={filter <- @fields}
          filter={filter}
          all_filters={@all_filters}
          state={@state}
          static={@static}
          myself={@myself}
        />
      </div>

      <div class="mb-3.5 flex flex-wrap items-center gap-x-[18px] gap-y-2.5 px-0.5">
        <div :for={filter <- @switches} class={switch_class()}>
          <Gervaz.render_filter
            filter={filter}
            all_filters={@all_filters}
            state={@state}
            static={@static}
            myself={@myself}
          />
        </div>

        <.select_all :if={@show_checkboxes} static={@static} state={@state} myself={@myself} />

        <%!-- Every visible filter is shown, so a "Clear" here is the only way back to the full set —
              filter_bar hides its filters behind a drawer and puts the clear inside it, but a grid
              has no drawer. Rides the same select-all line rather than a row of its own. --%>
        <button
          :if={@active_filters?}
          type="button"
          phx-click="clear_filters"
          phx-target={@myself}
          class="inline-flex h-[30px] items-center gap-1.5 rounded-lg border border-[#ecebe6] bg-white px-[11px] text-[11.5px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-x-mark"
            class="size-[13px] text-[#a8a5a0]"
          />
          {dgettext("mishka_gervaz", "Clear filters")}
        </button>

        <span class="ms-auto text-[12px] font-semibold text-[#a8a5a0]">{@count}</span>
      </div>
    </form>
    """
  end

  defp switch_class do
    "[&_label]:flex [&_label]:cursor-pointer [&_label]:items-center [&_label]:gap-[9px] " <>
      "[&_input]:size-4 [&_input]:cursor-pointer [&_input]:rounded [&_input]:accent-[#5b57d6] " <>
      "[&_span]:text-[12.5px]! [&_span]:font-semibold [&_span]:text-[#5c5a54]"
  end

  @doc """
  The Select-all checkbox on the left, the count on the right, immediately over the list.

  The checkbox keeps the `gervaz-select-all-checkbox` class because that is what
  `MishkaGervaz.Table.Templates.Shared.uncheck_all/2` and `check_all_gallery/2` target — without it the
  optimistic toggle silently no-ops and the box stays checked for a round trip after "Clear selection".
  """
  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true
  attr :show_checkboxes, :boolean, required: true
  attr :empty_label, :string, default: nil

  def select_row(assigns) do
    assigns =
      assign(assigns, :count, range_label(assigns.state, page_size(assigns), assigns.empty_label))

    ~H"""
    <div class="mb-3 flex flex-wrap items-center justify-between gap-3 px-0.5">
      <.select_all :if={@show_checkboxes} static={@static} state={@state} myself={@myself} />

      <span class="ms-auto text-[12px] font-semibold text-[#a8a5a0]">{@count}</span>
    </div>
    """
  end

  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  defp select_all(assigns) do
    ~H"""
    <div class="[&_label]:gap-[9px] [&_span]:font-semibold [&_span]:text-[12.5px]! [&_span]:text-[#5c5a54]">
      <.dynamic_component
        module={@static.ui_adapter}
        function={:checkbox}
        phx-click={toggle_all_js(@state.select_all?)}
        phx-target={@myself}
        id={"#{@static.stream_name}-select-all"}
        name={"select_all_#{@static.stream_name}"}
        value="all"
        checked={@state.select_all?}
        class="gervaz-select-all-checkbox size-4 cursor-pointer rounded accent-[#5b57d6]"
        label={dgettext("mishka_gervaz", "Select all")}
      />
    </div>
    """
  end

  @doc """
  How many records the table holds in total — the `24 items` over the grid.

  Unlike `range_label/3` this counts the whole result set rather than the page, because the grid's own
  count sits beside the view switch where the page is not yet the subject.
  """
  @spec total_label(map(), String.t() | nil) :: String.t()
  def total_label(%{total_count: total}, _empty) when is_integer(total) and total > 0,
    do: dgettext("mishka_gervaz", "%{count} items", count: total)

  def total_label(_state, empty), do: empty || dgettext("mishka_gervaz", "0 items")

  @doc """
  What the select-all tick does when clicked, given whether it is currently on.

  The event and the DOM flip travel together: the server is told to invert the selection, and the
  same click sets or clears every checkbox on the page without waiting for the round trip. Public
  because a card template that draws its own toolbar still needs this exact pair.
  """
  @spec toggle_all_js(boolean()) :: JS.t()
  def toggle_all_js(true = _select_all?), do: Gervaz.uncheck_all(JS.push("toggle_select_all"))
  def toggle_all_js(_select_all?), do: Gervaz.check_all_gallery(JS.push("toggle_select_all"))

  @doc """
  The tooltip on an edition chip — "Open the FA edition".

  Every card that lists sibling editions words this the same way, so the string is translated once.
  """
  @spec edition_title(map()) :: String.t()
  def edition_title(%{language: language}),
    do:
      dgettext("mishka_gervaz", "Open the %{language} edition", language: String.upcase(language))

  @doc """
  Reveals a card's remaining edition chips.

  Opening the row is a client-side class flip, not a round trip: the chips are already rendered, and
  a stream row's expanded state must not depend on the server remembering it. Every id is scoped by
  the row's own DOM id so one card's toggle cannot reach another's — the card supplies that id and
  must name its three elements `<id>-editions-rest`, `-more` and `-less`.

  `hidden` alone cannot hide a button that also carries `inline-flex` — both set `display`, and which
  one wins is down to their order in the stylesheet, not the order they were added. So each toggle
  takes the display class off as well as putting `hidden` on.
  """
  @spec expand_editions(String.t()) :: JS.t()
  def expand_editions(id) do
    JS.remove_class("hidden", to: "##{id}-editions-rest")
    |> JS.add_class("flex", to: "##{id}-editions-rest")
    |> JS.add_class("hidden", to: "##{id}-editions-more")
    |> JS.remove_class("inline-flex", to: "##{id}-editions-more")
    |> JS.remove_class("hidden", to: "##{id}-editions-less")
    |> JS.add_class("inline-flex", to: "##{id}-editions-less")
  end

  @doc "Hides a card's extra edition chips again — the exact inverse of `expand_editions/1`."
  @spec collapse_editions(String.t()) :: JS.t()
  def collapse_editions(id) do
    JS.add_class("hidden", to: "##{id}-editions-rest")
    |> JS.remove_class("flex", to: "##{id}-editions-rest")
    |> JS.remove_class("hidden", to: "##{id}-editions-more")
    |> JS.add_class("inline-flex", to: "##{id}-editions-more")
    |> JS.add_class("hidden", to: "##{id}-editions-less")
    |> JS.remove_class("inline-flex", to: "##{id}-editions-less")
  end

  @doc """
  Which slice of the result set is under your eyes — `Showing 1–20 of 48`.

  The last page holds a remainder rather than a full page, so the upper bound is clamped by the total
  rather than by where the page would end.
  """
  @spec range_label(map(), pos_integer(), String.t() | nil) :: String.t()
  def range_label(state, page_size, empty_label \\ nil)

  def range_label(%{total_count: total}, _page_size, empty_label) when total in [nil, 0],
    do: empty_label || dgettext("mishka_gervaz", "Nothing found")

  def range_label(%{total_count: total, page: page}, page_size, _empty_label)
      when is_integer(total) and is_integer(page) do
    dgettext("mishka_gervaz", "Showing %{first}–%{last} of %{total}",
      first: (page - 1) * page_size + 1,
      last: min(page * page_size, total),
      total: total
    )
  end

  def range_label(_state, _page_size, empty_label),
    do: empty_label || dgettext("mishka_gervaz", "Nothing found")

  @doc """
  What sits under the list: numbered pages, or a Load More button over the page-size picker.

  Every event and figure here is Gervaz's — only the look is ours. A table that asked for `:infinite`
  keeps the shared pagination, which is the only thing that knows how to draw it.
  """
  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  def pagination(assigns) do
    pagination_type = get_in(assigns.static.config, [:pagination, :type]) || :numbered

    cond do
      pagination_type == :numbered and is_integer(assigns.state.total_pages) ->
        numbered_pagination(assigns)

      pagination_type == :load_more ->
        load_more_pagination(assigns)

      true ->
        assigns
        |> assign(:pagination_type, pagination_type)
        |> assign(:loading_text, assigns.static.pagination_ui.loading_text)
        |> assign(:load_more_label, assigns.static.pagination_ui.load_more_label)
        |> Gervaz.render_pagination()
    end
  end

  defp load_more_pagination(assigns) do
    assigns =
      assigns
      |> assign(:page_size, page_size(assigns))
      |> assign(:page_size_options, assigns.static.page_size_options || [])
      |> assign(:more?, assigns.state.has_more?)
      |> assign(
        :label,
        translate_dsl(assigns.static.pagination_ui.load_more_label) ||
          dgettext("mishka_gervaz", "Load More")
      )

    ~H"""
    <div :if={@more?} class="mt-[22px] flex items-center justify-center">
      <button
        type="button"
        phx-click="load_more"
        phx-target={@myself}
        disabled={@state.loading == :loading}
        class="h-[42px] rounded-xl border border-[#dcdbf5] bg-[#f2f1fc] px-[22px] text-[12.5px] font-bold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb] disabled:opacity-60"
      >
        {@label}
      </button>
    </div>

    <form
      :if={@page_size_options != []}
      id={"#{@static.stream_name}-page-size"}
      phx-change="change_page_size"
      phx-target={@myself}
      class="mt-[22px] flex items-center gap-[9px]"
    >
      <span id={"#{@static.id}-page-size-show"} class="text-[12px] font-semibold text-[#8a877f]">
        {dgettext("mishka_gervaz", "Show")}
      </span>
      <div class="relative">
        <select
          name="size"
          aria-labelledby={"#{@static.id}-page-size-show #{@static.id}-page-size-unit"}
          class="h-9 cursor-pointer appearance-none rounded-[9px] border border-[#ecebe6] bg-white ps-3 pe-8 text-[12.5px] font-semibold text-[#3a382f] outline-none"
        >
          <option :for={option <- @page_size_options} value={option} selected={option == @page_size}>
            {option}
          </option>
        </select>
        <.select_chevron />
      </div>
      <span id={"#{@static.id}-page-size-unit"} class="text-[12px] font-semibold text-[#8a877f]">
        {dgettext("mishka_gervaz", "per page")}
      </span>
    </form>
    """
  end

  defp numbered_pagination(assigns) do
    %{page: page, total_pages: total_pages} = assigns.state

    assigns =
      assigns
      |> assign(:page, page)
      |> assign(:total_pages, total_pages)
      |> assign(:pages, page_window(page, total_pages))
      |> assign(:page_size, page_size(assigns))
      |> assign(:page_size_options, assigns.static.page_size_options || [])

    ~H"""
    <div class="mt-5 flex flex-wrap items-center justify-between gap-4">
      <form
        :if={@page_size_options != []}
        id={"#{@static.stream_name}-page-size"}
        phx-change="change_page_size"
        phx-target={@myself}
        class="flex items-center gap-[9px]"
      >
        <span id={"#{@static.id}-page-size-show"} class="text-[12px] font-semibold text-[#8a877f]">
          {dgettext("mishka_gervaz", "Show")}
        </span>
        <div class="relative">
          <select
            name="size"
            aria-labelledby={"#{@static.id}-page-size-show #{@static.id}-page-size-unit"}
            class="h-9 cursor-pointer appearance-none rounded-[9px] border border-[#ecebe6] bg-white ps-3 pe-8 text-[12.5px] font-semibold text-[#3a382f] outline-none"
          >
            <option
              :for={option <- @page_size_options}
              value={option}
              selected={option == @page_size}
            >
              {option}
            </option>
          </select>
          <.select_chevron />
        </div>
        <span id={"#{@static.id}-page-size-unit"} class="text-[12px] font-semibold text-[#8a877f]">
          {dgettext("mishka_gervaz", "per page")}
        </span>
      </form>

      <div :if={@total_pages > 1} class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="prev_page"
          phx-target={@myself}
          disabled={@page <= 1}
          class="h-9 rounded-[9px] border border-[#ecebe6] bg-white px-3.5 text-[12px] font-semibold text-[#6d6a63] transition-colors hover:bg-[#f7f6f3] disabled:cursor-default disabled:bg-[#f6f5f2] disabled:text-[#c3c0b8]"
        >
          {translate_dsl(@static.pagination_ui.prev_label) || dgettext("mishka_gervaz", "Previous")}
        </button>

        <%= for entry <- @pages do %>
          <%= case entry do %>
            <% :gap -> %>
              <span class="px-1 text-[12px] font-semibold text-[#a8a5a0]">…</span>
            <% number -> %>
              <button
                type="button"
                phx-click="go_to_page"
                phx-value-page={number}
                phx-target={@myself}
                aria-current={number == @page && "page"}
                class={[
                  "h-9 min-w-9 rounded-[9px] border px-2.5 text-[12px] font-bold transition-colors",
                  (number == @page && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
                    "border-[#ecebe6] bg-white text-[#6d6a63] hover:bg-[#f7f6f3]"
                ]}
              >
                {number}
              </button>
          <% end %>
        <% end %>

        <button
          type="button"
          phx-click="next_page"
          phx-target={@myself}
          disabled={@page >= @total_pages}
          class="h-9 rounded-[9px] border border-[#ecebe6] bg-white px-3.5 text-[12px] font-semibold text-[#6d6a63] transition-colors hover:bg-[#f7f6f3] disabled:cursor-default disabled:bg-[#f6f5f2] disabled:text-[#c3c0b8]"
        >
          {translate_dsl(@static.pagination_ui.next_label) || dgettext("mishka_gervaz", "Next")}
        </button>
      </div>

      <span class="text-[12px] font-semibold text-[#a8a5a0]">
        {dgettext("mishka_gervaz", "Page %{page} of %{total}", page: @page, total: @total_pages)}
      </span>
    </div>
    """
  end

  @doc """
  Which page buttons to draw: all of them while they fit, otherwise the ends, a window around where you
  are, and an ellipsis for the rest.
  """
  @window 2
  @max_pages 7

  @spec page_window(pos_integer(), pos_integer()) :: [pos_integer() | :gap]
  def page_window(_page, total) when total <= @max_pages, do: Enum.to_list(1..total//1)

  def page_window(page, total) do
    [1, total, page]
    |> Enum.concat((page - @window)..(page + @window)//1)
    |> Enum.filter(&(&1 >= 1 and &1 <= total))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [a, b] when b - a > 1 -> [a, :gap]
      [a, _b] -> [a]
    end)
    |> Kernel.++([total])
  end

  defp page_size(%{state: state, static: static}), do: state.current_page_size || static.page_size

  @doc "The spinner shown while the first page is still on its way."
  attr :text, :string, default: nil

  def loading(assigns) do
    assigns =
      assign_new(assigns, :label, fn -> assigns.text || dgettext("mishka_gervaz", "Loading…") end)

    ~H"""
    <div class="flex items-center justify-center gap-2.5 py-12 text-[12.5px] font-semibold text-[#6d6a63]">
      <span class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]" />
      {@label}
    </div>
    """
  end

  @doc """
  A veil over the list while it reloads — the cards stay readable underneath, so the spinner rides on
  the page rather than on a panel of its own.
  """
  attr :text, :string, default: nil

  def loading_overlay(assigns) do
    assigns =
      assign_new(assigns, :label, fn -> assigns.text || dgettext("mishka_gervaz", "Loading…") end)

    ~H"""
    <div class="absolute inset-0 z-20 flex min-h-[200px] items-center justify-center rounded-2xl bg-white/70">
      <span class="inline-flex items-center gap-2.5 text-[12.5px] font-semibold text-[#6d6a63]">
        <span class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]" />
        {@label}
      </span>
    </div>
    """
  end

  @doc """
  What a stream shows when it holds nothing.

  Muted by class rather than dropped by `:if` — a stream container keeps children the server stops
  rendering, and `hidden only:flex` is what makes this appear exactly while it is the sole child.
  """
  attr :id, :string, required: true
  attr :static, :map, required: true
  attr :icon, :string, default: "hero-document"
  attr :class, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "hidden only:flex flex-col items-center justify-center gap-3 rounded-2xl border border-[#ecebe6] bg-white py-11 text-center",
        @class
      ]}
    >
      <span class="grid size-[52px] place-items-center rounded-[14px] bg-[#f2f1ec] text-[#a8a5a0]">
        <.dynamic_component
          module={@static.ui_adapter}
          function={:icon}
          name={get_in(@static.config, [:empty_state, :icon]) || @icon}
          class="size-6"
        />
      </span>
      <div class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
        {translate_dsl(get_in(@static.config, [:empty_state, :message])) ||
          dgettext("mishka_gervaz", "No records found")}
      </div>
    </div>
    """
  end

  defp translate_dsl(text) when is_binary(text),
    do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", text)

  defp translate_dsl(other), do: other

  @doc """
  A whole card page: the count, the order and the view switch, the filter row, the bulk bar, the stream
  and its pager.

  This is the layout the blog card pages share — a list or a grid of records with the same furniture
  around it. What differs between them is only what a card is called and how its records are laid out,
  so those arrive as classes and labels rather than as six copies of this markup.

  The records themselves stay with the caller, in the `:records` slot: they are that template's own
  `render_item/1` over the stream, and the stream loop has to be written where `@stream` is. This only
  supplies the `phx-update="stream"` container it belongs in, and the empty state that shares it.

  Pass the five `show_*` flags from `MishkaGervaz.Table.Templates.Shared.assign_card_flags/1`.

  The caller keeps the page's outermost `<div>` rather than passing its class in: a template's
  `render/1` is the root of a stateful LiveComponent, and LiveView requires that root to be a literal
  HTML tag — a component call there raises "Stateful components must have a single static HTML tag at
  the root".
  """
  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  attr :container_class, :string, required: true, doc: "the stream container: a column, or a grid"
  attr :data_role, :string, required: true, doc: "test/debug handle on the stream container"
  attr :empty_label, :string, required: true, doc: "the count's zero form, e.g. `0 posts`"
  attr :empty_icon, :string, required: true
  attr :empty_class, :string, default: nil, doc: "`col-span-full` when the container is a grid"

  attr :show_checkboxes, :boolean, required: true
  attr :show_filters, :boolean, required: true
  attr :show_pagination, :boolean, required: true
  attr :show_bulk_actions, :boolean, required: true
  attr :show_switcher, :boolean, required: true

  attr :before_table, :any, default: nil, doc: "optional slot the page puts above the filter row"

  slot :records, required: true

  def card_scaffold(assigns) do
    ~H"""
    <div>
      <div :if={@state.has_initial_data? or @state.loading == :loaded}>
        <div :if={@before_table} class="mb-4">{render_slot(@before_table)}</div>

        <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
          <span class="text-[12.5px] font-semibold text-[#8a877f]">
            {total_label(@state, dgettext("mishka_gervaz", "0 items"))}
          </span>

          <.sort_control
            :if={:sort in @static.features and @static.sortable_columns != []}
            static={@static}
            state={@state}
            myself={@myself}
          />

          <Gervaz.render_template_switcher
            :if={@show_switcher}
            switchable_templates={@static.switchable_templates}
            current_template={@state.template}
            ui_adapter={@static.ui_adapter}
            myself={@myself}
          />
        </div>

        <.filter_grid
          :if={@show_filters}
          static={@static}
          state={@state}
          myself={@myself}
          show_checkboxes={@show_checkboxes}
          empty_label={@empty_label}
        />

        <.select_row
          :if={!@show_filters}
          static={@static}
          state={@state}
          myself={@myself}
          show_checkboxes={@show_checkboxes}
          empty_label={@empty_label}
        />

        <Gervaz.render_bulk_actions
          :if={@show_bulk_actions}
          static={@static}
          state={@state}
          myself={@myself}
        />

        <div class="relative isolate">
          <.loading_overlay :if={
            @state.has_initial_data? and @state.loading == :loading and
              @state.loading_type == :reset
          } />

          <div
            id={"#{@static.stream_name}"}
            data-role={@data_role}
            phx-update="stream"
            class={@container_class}
          >
            <.empty_state
              id={"#{@static.stream_name}-empty-state"}
              static={@static}
              icon={@empty_icon}
              class={@empty_class}
            />

            {render_slot(@records)}
          </div>
        </div>

        <.pagination :if={@show_pagination} static={@static} state={@state} myself={@myself} />
      </div>
    </div>
    """
  end

  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  # THE ORDER A CARD PAGE IS IN, chosen as a table's column headers choose it — a sortable column, and
  # which way — since a page of cards has no headers to click. Both go to the table as `sort_by`.
  defp sort_control(assigns) do
    columns =
      for %{name: name} = column <- assigns.static.columns,
          name in assigns.static.sortable_columns,
          do:
            {to_string(name), MishkaGervaz.Helpers.resolve_label(column.label) || to_string(name)}

    {column, order} = current_sort(assigns.static, assigns.state)

    assigns =
      assign(assigns,
        columns: columns,
        column: column,
        order: order,
        form_id: "#{assigns.static.id}-sort"
      )

    ~H"""
    <form
      id={@form_id}
      phx-change="sort_by"
      phx-target={@myself}
      class="ms-auto flex items-center gap-1.5"
    >
      <label for={@form_id <> "-column"} class="text-[12px] font-semibold text-[#8a877f]">
        {dgettext("mishka_gervaz", "Sort by")}
      </label>
      <div class="relative">
        <select
          id={@form_id <> "-column"}
          name="column"
          class="h-8 cursor-pointer appearance-none rounded-[9px] border border-[#ecebe6] bg-white ps-2.5 pe-8 text-[12px] font-semibold text-[#3a382f] outline-none focus:border-[#c3c1f0]"
        >
          <option :if={is_nil(@column)} value="" selected>
            {dgettext("mishka_gervaz", "Default")}
          </option>
          <option :for={{name, label} <- @columns} value={name} selected={name == @column}>
            {label}
          </option>
        </select>
        <.select_chevron />
      </div>
      <input type="hidden" name="order" value={@order} />
      <button
        :if={@column}
        type="button"
        id={@form_id <> "-order"}
        phx-click={
          JS.push("sort_by", value: %{column: @column, order: flip(@order)}, target: @myself)
        }
        aria-label={order_label(@order)}
        title={order_label(@order)}
        data-order={@order}
        class="flex size-8 items-center justify-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"
      >
        <.icon
          name={(@order == "desc" && "hero-bars-arrow-down") || "hero-bars-arrow-up"}
          class="size-4"
        />
      </button>
    </form>
    """
  end

  # The column the table is sorted by now, and which way: the first sort field's column.
  defp current_sort(static, %{sort_fields: [{field, order} | _]}) do
    column =
      Enum.find(static.sortable_columns, fn name ->
        field in Map.get(static.sort_field_map || %{}, name, [name])
      end)

    {column && to_string(column), to_string(order)}
  end

  defp current_sort(_static, _state), do: {nil, "desc"}

  defp flip("desc"), do: "asc"
  defp flip(_asc), do: "desc"

  defp order_label("desc"), do: dgettext("mishka_gervaz", "Descending — click for ascending")
  defp order_label(_asc), do: dgettext("mishka_gervaz", "Ascending — click for descending")
end
