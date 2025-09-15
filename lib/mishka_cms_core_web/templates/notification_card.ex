defmodule MishkaCmsCoreWeb.Templates.NotificationCard do
  @moduledoc """
  A MishkaGervaz custom table template: the inbox at `/admin/dashboard/notifications`, rendered as one
  card of full-width rows (checkbox, severity tile, title/body/time, per-row actions) rather than a
  table — backed by Gervaz, so filters, selection, bulk actions, pagination and realtime come from the
  resource DSL rather than from this module.

  A template owns the WHOLE table, so the chrome is here too: the filter bar (`render_filters/1`), the
  select-all + bulk toolbar (`render_selection_toolbar/1`) and the footer (`render_pagination/1`). Each
  is generic — it walks `static.filters` / `static.bulk_actions` and never names a specific filter — so
  the resource stays the single source of truth. Row content comes from each column's `render` in
  `MishkaCmsCore.Notify.Notification`, mapped here by position: 0 icon, 1 title, 2 body, 3+ footer.

  It lives in `mishka_cms_core` (not blog) because the bell is core and core cannot depend on an
  extension.

  See `MishkaCmsCore.Notify` and `MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index`.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages

  import MishkaGervaz.Helpers,
    only: [dynamic_component: 1, get_visible_columns: 2, translate_options: 1]

  alias MishkaGervaz.Table.Templates.Shared
  alias Phoenix.LiveView.JS

  @card_class "overflow-hidden rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_1px_2px_rgba(30,28,24,0.04)]"

  @input_class "h-[42px] w-full rounded-[11px] border border-[#ecebe6] bg-white text-[13px] font-medium text-[#1b1a18] outline-none transition focus:border-[#c3c1f0] focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"

  @select_class "h-[42px] w-full min-w-[180px] cursor-pointer appearance-none rounded-[11px] border border-[#ecebe6] bg-white ps-[14px] pe-[34px] text-[13px] font-semibold text-[#3a382f] outline-none max-[560px]:min-w-0!"

  @impl true
  def name, do: :notification_card

  @impl true
  def label, do: dgettext("mishka_gervaz", "Notifications")

  @impl true
  def icon, do: "hero-bell"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Full-width notification cards")

  @impl true
  def features, do: [:filter, :select, :bulk_actions, :paginate]

  @impl true
  def default_options, do: []

  @impl true
  def render(assigns) do
    static = assigns.static
    state = assigns.state
    features = static.features

    show_checkboxes =
      :select in features and static.bulk_actions != [] and
        Shared.has_visible_bulk_actions?(static.bulk_actions, state.archive_status)

    assigns =
      assigns
      |> assign(:show_checkboxes, show_checkboxes)
      |> assign(:show_filters, static.filters != [] and :filter in features)
      |> assign(:show_pagination, :paginate in features)

    ~H"""
    <div class="mishka-gervaz-notification-card">
      <div :if={@state.has_initial_data? or @state.loading == :loaded}>
        <.render_filters :if={@show_filters} static={@static} state={@state} myself={@myself} />

        <.render_selection_toolbar
          show_checkboxes={@show_checkboxes}
          static={@static}
          state={@state}
          myself={@myself}
        />

        <div class="relative isolate">
          <.render_loading_overlay
            :if={
              @state.has_initial_data? and @state.loading == :loading and
                @state.loading_type == :reset
            }
            static={@static}
            state={@state}
          />

          <div id={"#{@static.stream_name}"} phx-update="stream" class={card_class()}>
            <div
              id={"#{@static.stream_name}-empty-state"}
              class="hidden only:block px-4 py-14 text-center text-[13px] font-medium text-[#a8a5a0]"
            >
              {translate(get_in(@static.config, [:empty_state, :message])) ||
                dgettext("mishka_gervaz", "No notifications match your filters.")}
            </div>
            <.render_item
              :for={{id, record} <- @stream}
              id={id}
              record={record}
              static={@static}
              state={@state}
              show_checkboxes={@show_checkboxes}
              myself={@myself}
            />
          </div>
        </div>

        <.render_pagination :if={@show_pagination} static={@static} state={@state} myself={@myself} />
      </div>
    </div>
    """
  end

  @doc """
  The filter bar: every `:text` filter becomes a grow-to-fill search box, every `:select` a labelled
  dropdown. Names and the `phx-change="filter"` form are Gervaz's contract — only the look is ours.
  """
  @impl true
  def render_filters(assigns) do
    filters = Enum.filter(assigns.static.filters, &(&1.type in [:text, :select]))
    assigns = assign(assigns, :filters, filters)

    ~H"""
    <form
      :if={@filters != []}
      id={"#{@static.stream_name}-filter"}
      phx-change="filter"
      phx-target={@myself}
      data-role="nfilters"
      class="mb-[18px] flex flex-wrap items-end gap-4"
    >
      <div :for={filter <- @filters} class={filter_wrapper_class(filter.type)}>
        <label
          :if={filter.type == :select}
          class="text-[11px] font-bold tracking-[0.04em] text-[#8a877f]"
        >
          {filter_label(filter)}
        </label>

        <div class="relative">
          <%= if filter.type == :text do %>
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-magnifying-glass"
              class="pointer-events-none absolute start-[14px] top-1/2 size-4 -translate-y-1/2 text-[#a8a5a0]"
            />
            <input
              type="text"
              name={filter.name}
              value={Map.get(@state.filter_values, filter.name) || ""}
              dir="auto"
              placeholder={filter_placeholder(filter)}
              phx-debounce="300"
              class={[input_class(), "ps-10 pe-[14px]"]}
            />
          <% else %>
            <select name={filter.name} class={select_class()}>
              <option value="">{filter_prompt(filter)}</option>
              <option
                :for={{label, value} <- translate_options(filter.options || [])}
                value={to_string(value)}
                selected={to_string(Map.get(@state.filter_values, filter.name)) == to_string(value)}
              >
                {label}
              </option>
            </select>
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-chevron-down"
              class="pointer-events-none absolute end-3 top-1/2 size-[14px] -translate-y-1/2 text-[#a8a5a0]"
            />
          <% end %>
        </div>
      </div>
    </form>
    """
  end

  @impl true
  def render_item(assigns) do
    static = assigns.static
    state = assigns.state
    record = assigns.record

    [icon_column, title_column, body_column | footer_columns] =
      pad(get_visible_columns(static.columns, state), 3)

    is_checked = Shared.record_checked?(state, record.id)

    checkbox_assigns =
      %{__changed__: %{}}
      |> assign(:name, "select_card")
      |> assign(:value, record.id)
      |> assign(:checked, is_checked)
      |> assign(:class, "gervaz-media-checkbox size-4 accent-[#5b57d6] cursor-pointer")

    assigns =
      assigns
      |> assign(:icon_column, icon_column)
      |> assign(:title_column, title_column)
      |> assign(:body_column, body_column)
      |> assign(:footer_columns, footer_columns)
      |> assign(:checkbox_assigns, checkbox_assigns)
      |> assign(
        :visible_row_actions,
        Enum.filter(static.row_actions, &Shared.action_visible?(&1, record, state))
      )
      |> assign(:unread, is_nil(record.read_at))

    ~H"""
    <div
      id={@id}
      data-role="nrow"
      class={[
        "flex items-center gap-[14px] border-b border-[#f4f3ee] px-[18px] py-[15px] last:border-0 max-[560px]:flex-wrap",
        (@unread && "bg-[#faf9ff]") || "bg-white"
      ]}
    >
      <div :if={@show_checkboxes} class="flex-none">
        <.dynamic_component
          module={@static.ui_adapter}
          function={:checkbox}
          phx-click="toggle_select"
          phx-value-id={@record.id}
          phx-target={@myself}
          {@checkbox_assigns}
        />
      </div>

      <div :if={@icon_column} class="flex-none">
        <Shared.render_cell column={@icon_column} record={@record} static={@static} state={@state} />
      </div>

      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <div
            :if={@title_column}
            class={["text-[13.5px]", (@unread && "font-bold") || "font-semibold"]}
          >
            <Shared.render_cell
              column={@title_column}
              record={@record}
              static={@static}
              state={@state}
            />
          </div>
          <span :if={@unread} class="size-[7px] flex-none rounded-full bg-[#5b57d6]"></span>
        </div>

        <div
          :if={@body_column}
          class="mt-[3px] truncate text-[12px] font-medium text-[#7c7a75]"
        >
          <Shared.render_cell column={@body_column} record={@record} static={@static} state={@state} />
        </div>

        <div
          :for={column <- @footer_columns}
          class="mt-[5px] text-[10.5px] font-semibold text-[#a8a5a0]"
        >
          <Shared.render_cell column={column} record={@record} static={@static} state={@state} />
        </div>
      </div>

      <div
        :if={@visible_row_actions != []}
        data-role="nactions"
        class="flex flex-none items-center gap-[14px] max-[560px]:w-full max-[560px]:justify-end max-[560px]:pt-1"
      >
        <Shared.render_row_actions
          row_actions={@visible_row_actions}
          record={@record}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  @doc """
  The footer: how far into the feed we are on the left, load-more + per-page on the right.

  Gervaz's own `Shared.render_pagination/1` hardcodes the button's look, so its two controls are
  driven straight from here instead — same `load_more` / `change_page_size` events, our classes.
  """
  @impl true
  def render_pagination(assigns) do
    assigns =
      assigns
      |> assign(
        :load_more_label,
        translate(assigns.static.pagination_ui.load_more_label) ||
          dgettext("mishka_gervaz", "Load more")
      )
      |> assign(:page_size_options, assigns.static.page_size_options || [])
      |> assign(
        :load_more?,
        get_in(assigns.static.config, [:pagination, :type]) == :load_more and
          assigns.state.has_more? and assigns.state.loading != :loading
      )

    ~H"""
    <div class="mt-[18px] flex flex-wrap items-center justify-between gap-4">
      <span class="text-[12px] font-semibold text-[#8a877f]">{range_label(@state)}</span>

      <div class="flex items-center gap-[14px]">
        <.dynamic_component
          :if={@load_more?}
          module={@static.ui_adapter}
          function={:pagination_nav_button}
          label={@load_more_label}
          event="load_more"
          myself={@myself}
          disabled={false}
          class="h-[38px] cursor-pointer rounded-[11px] border border-[#dcdbf5] bg-[#f2f1fc] px-[18px] text-[12.5px] font-bold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb]"
        />

        <form
          :if={@page_size_options != []}
          id={"#{@static.id}-page-size-selector-form"}
          phx-change="change_page_size"
          phx-target={@myself}
          class="flex items-center gap-[9px]"
        >
          <span class="text-[12px] font-semibold text-[#8a877f]">
            {dgettext("mishka_gervaz", "Per page")}
          </span>
          <div class="relative">
            <select
              name="size"
              class="h-[38px] cursor-pointer appearance-none rounded-[10px] border border-[#ecebe6] bg-white ps-3 pe-8 text-[12.5px] font-semibold text-[#3a382f] outline-none"
            >
              <option
                :for={option <- @page_size_options}
                value={option}
                selected={option == @state.current_page_size}
              >
                {option}
              </option>
            </select>
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-chevron-down"
              class="pointer-events-none absolute end-[11px] top-1/2 size-[13px] -translate-y-1/2 text-[#a8a5a0]"
            />
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── internal ─────────────────────────────────────────────────────────────────

  # Select-all + the bulk bar share one line with the range label, as in the design; the bulk buttons
  # only appear once something is selected.
  defp render_selection_toolbar(assigns) do
    checkbox_assigns =
      %{__changed__: %{}}
      |> assign(:id, "notification-card-select-all")
      |> assign(:name, "select_all_notification_card")
      |> assign(:value, "all")
      |> assign(:checked, assigns.state.select_all?)
      |> assign(:class, "gervaz-select-all-checkbox size-4 accent-[#5b57d6] cursor-pointer")
      |> assign(:label, dgettext("mishka_gervaz", "Select all"))

    assigns = assign(assigns, :checkbox_assigns, checkbox_assigns)

    ~H"""
    <div class="mb-3 flex flex-wrap items-center justify-between gap-4">
      <div class="flex items-center gap-4">
        <div
          :if={@show_checkboxes}
          class="flex items-center gap-[9px] text-[12.5px] font-semibold text-[#5c5a54]"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:checkbox}
            phx-click={toggle_all_js(@state.select_all?)}
            phx-target={@myself}
            {@checkbox_assigns}
          />
        </div>

        <.render_bulk_actions
          :if={@show_checkboxes}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  defp card_class, do: @card_class

  defp input_class, do: @input_class

  defp select_class, do: @select_class

  # "Showing 1–20 of 42" — how far into the feed the loaded rows reach. Gervaz's `page_info_format`
  # speaks only `{page}`/`{total}`/`{count}` and its pagination renders no info line for `:load_more`,
  # so the window is named here; the totals come from the engine (`show_total true` makes the read
  # countable). `:load_more` grows the window rather than paging, so it always starts at 1.
  defp range_label(%{total_count: total} = state) when is_integer(total) and total > 0 do
    shown = min((state.page || 1) * page_size(state), total)
    dgettext("mishka_gervaz", "Showing 1–%{shown} of %{total}", shown: shown, total: total)
  end

  defp range_label(_state), do: nil

  # The window size lives on the state once the user picks one, and on the static config until then.
  defp page_size(%{current_page_size: size}) when is_integer(size) and size > 0, do: size
  defp page_size(%{static: %{page_size: size}}) when is_integer(size) and size > 0, do: size
  defp page_size(_state), do: 20

  defp toggle_all_js(current_select_all) do
    js = JS.push("toggle_select_all")
    if current_select_all, do: Shared.uncheck_all(js), else: Shared.check_all_gallery(js)
  end

  defp render_loading_overlay(assigns) do
    assigns =
      assign(
        assigns,
        :loading_text,
        translate(assigns.static.pagination_ui.loading_text) ||
          dgettext("mishka_gervaz", "Loading...")
      )

    ~H"""
    <div class="absolute inset-0 z-20 flex min-h-[200px] items-center justify-center bg-white/70">
      <.dynamic_component
        module={@static.ui_adapter}
        function={:loading_state}
        type={:overlay}
        style={:spinner}
        text={@loading_text}
        class="flex items-center gap-2 rounded-lg bg-white px-4 py-2 shadow-md"
      />
    </div>
    """
  end

  # A text filter grows to fill the bar; a select keeps its natural width beside it. Below 560px both
  # take the full row (the design's `[data-role="nfilters"] > div` rule).
  defp filter_wrapper_class(:text),
    do:
      "relative min-w-[200px] flex-1 max-[560px]:w-full! max-[560px]:min-w-0! max-[560px]:flex-[1_1_100%]!"

  defp filter_wrapper_class(_type),
    do: "flex flex-none flex-col gap-[7px] max-[560px]:w-full! max-[560px]:flex-[1_1_100%]!"

  defp filter_label(%{ui: %{label: label}}) when not is_nil(label), do: resolve(label)
  defp filter_label(%{name: name}), do: Phoenix.Naming.humanize(name)

  defp filter_prompt(%{ui: %{prompt: prompt}}) when not is_nil(prompt), do: resolve(prompt)
  defp filter_prompt(_filter), do: dgettext("mishka_gervaz", "All")

  defp filter_placeholder(%{ui: %{placeholder: placeholder}}) when not is_nil(placeholder),
    do: resolve(placeholder)

  defp filter_placeholder(_filter), do: dgettext("mishka_gervaz", "Search notifications…")

  defp resolve(value) when is_function(value, 0), do: translate(value.())
  defp resolve(value), do: translate(value)

  defp translate(text) when is_binary(text) and text != "",
    do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", text)

  defp translate(other), do: other

  # Guarantee at least `n` leading elements so the destructure never fails on a short column list;
  # missing leading slots become nil (skipped by `:if`), extras flow into the footer.
  defp pad(list, n) when length(list) >= n, do: list
  defp pad(list, n), do: list ++ List.duplicate(nil, n - length(list))
end
