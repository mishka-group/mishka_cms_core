defmodule MishkaCmsCoreWeb.Templates.ActivityTimeline do
  @moduledoc """
  A MishkaGervaz custom table template: an activity log drawn as a vertical timeline — a rail with a
  severity-tinted node per event, day headings across it — rather than a table.

  A template owns the whole table, so the chrome is here: the filter bar (`render_filters/1`) and the
  footer (`render_pagination/1`). The bar is generic — a `:select` with few options becomes a
  segmented switch, a long one a dropdown, a `:text` filter the search box and a `:date_range` a pair
  of date inputs — so the resource stays the single source of truth and no filter is named here.

  Row content comes from each column's `render`, mapped by position: 0 the event (message + badge),
  1 the actor, 2 the date, 3+ inline badges.

  ## What a resource has to give it

  Columns and filters are read off the resource, but three things come from the record itself:

    * `:severity` — an atom field (`:info`, `:warn`, `:error`) tinting the node and the actor avatar
      of a row that carries no `:tone`; an unknown or unloaded one renders the `:info` tint.
    * `:tone` — an optional atom field (`:created`, `:updated`, `:destroyed`) a content-change row
      carries. When present it tints the node and the actor avatar by action rather than severity, so
      a create reads green, an update blue and a destroy red; a row without one (a job, a compile, a
      draft) is `nil` and falls back to `:severity`.
    * `__metadata__.first_of_day?` / `__metadata__.day_count` — the day heading. A LiveView stream
      never hands a row its predecessor, so the READ decides which row opens a day and how many
      events that day holds; a row without them simply gets no heading.
    * a timestamp field, named by the `:timestamp` template option.

  ## Template options

    * `:timestamp` — the record's timestamp field (default `:inserted_at`).
    * `:max_cap` — the read's scan ceiling, when it has one. A count that reaches it is only a floor,
      so it reads `10,000+` rather than claiming an exact total. Default `nil` — counts are exact.

  Used by `MishkaCmsCore.Activity.ActivityEntry` (the unified log at
  `/admin/dashboard/runtime/activity`) and `MishkaDocument.EventLog` (the document event log at
  `/admin/dashboard/document/event-logs`).

  See `MishkaCmsCore.Activity.Query` and `MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index`.
  """
  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages

  import MishkaGervaz.Helpers,
    only: [dynamic_component: 1, get_visible_columns: 2, translate_options: 1]

  alias MishkaGervaz.Table.Templates.Shared

  # A select short enough to read at a glance becomes a segmented switch; anything longer stays a
  # dropdown, which is what the design does with severity/source versus the resource list.
  @segmented_limit 4

  @segment_class "inline-flex cursor-pointer items-center gap-1.5 rounded-lg px-[11px] py-1.5 text-[12px] font-semibold transition-colors"

  @track_class "flex flex-wrap rounded-[10px] border border-[#ecebe6] bg-[#f6f5f2] p-[3px]"

  @date_class "h-[30px] w-[122px] cursor-pointer bg-transparent text-[12px] font-semibold text-[#3a382f] outline-none"

  @default_options [timestamp: :inserted_at, max_cap: nil]

  @impl true
  def name, do: :activity_timeline

  @impl true
  def label, do: dgettext("mishka_gervaz", "Activity Timeline")

  @impl true
  def icon, do: "hero-bolt"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Vertical timeline for an activity log")

  @impl true
  def features, do: [:filter, :paginate]

  @impl true
  def default_options, do: @default_options

  @impl true
  def render(assigns) do
    static = assigns.static

    assigns =
      assigns
      |> assign(:show_filters, static.filters != [] and :filter in static.features)
      |> assign(:show_pagination, :paginate in static.features)

    ~H"""
    <div class="mishka-gervaz-activity-timeline">
      <div :if={@state.has_initial_data? or @state.loading == :loaded}>
        <.render_filters :if={@show_filters} static={@static} state={@state} myself={@myself} />

        <div class="relative rounded-[18px] border border-[#ecebe6] bg-white px-5 pb-3 pt-1.5 shadow-[0_1px_2px_rgba(30,28,24,0.04)]">
          <.render_loading_overlay
            :if={
              @state.has_initial_data? and @state.loading == :loading and
                @state.loading_type == :reset
            }
            static={@static}
            state={@state}
          />

          <div class="relative ps-0.5">
            <div class="absolute bottom-3 start-[11px] top-2 w-0.5 bg-[#f0efea]"></div>

            <div id={"#{@static.stream_name}"} phx-update="stream">
              <div
                id={"#{@static.stream_name}-empty-state"}
                class="hidden only:flex flex-col items-center justify-center gap-3 py-12 text-center"
              >
                <span class="grid size-[52px] place-items-center rounded-[14px] bg-[#f4f3ef] text-[#bcb9b2]">
                  <.dynamic_component
                    module={@static.ui_adapter}
                    function={:icon}
                    name={get_in(@static.config, [:empty_state, :icon]) || "hero-bolt"}
                    class="size-6"
                  />
                </span>
                <span>
                  <span class="block font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
                    {dsl_text(
                      get_in(@static.config, [:empty_state, :message]),
                      dgettext("mishka_gervaz", "No matching events")
                    )}
                  </span>
                  <span class="mt-[3px] block text-[12px] font-medium text-[#8a877f]">
                    {dgettext("mishka_gervaz", "Try a different severity or search term.")}
                  </span>
                </span>
              </div>

              <.render_item
                :for={{id, record} <- @stream}
                id={id}
                record={record}
                static={@static}
                state={@state}
                myself={@myself}
              />
            </div>
          </div>
        </div>

        <.render_pagination :if={@show_pagination} static={@static} state={@state} myself={@myself} />
      </div>
    </div>
    """
  end

  @doc """
  The filter bar: a short `:select` renders as a segmented switch, a long one as a dropdown, a
  `:text` filter as the search box and a `:date_range` as a pair of date inputs. The
  `phx-change="filter"` form and the input names are Gervaz's contract — only the look is ours.
  """
  @impl true
  def render_filters(assigns) do
    filters = Enum.filter(assigns.static.filters, &(&1.type in [:text, :select, :date_range]))

    assigns =
      assigns
      |> assign(:filters, filters)
      |> assign(:max_cap, options(assigns.static)[:max_cap])

    ~H"""
    <form
      :if={@filters != []}
      id={"#{@static.stream_name}-filter"}
      phx-change="filter"
      phx-target={@myself}
      class="mb-4 flex flex-wrap items-center gap-4 rounded-[16px] border border-[#ecebe6] bg-white px-4 py-3.5 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
    >
      <div data-role="filters" class="flex flex-1 flex-wrap items-center gap-2.5">
        <div :for={filter <- @filters} class={filter_wrapper_class(filter)}>
          <%= cond do %>
            <% filter.type == :text -> %>
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-magnifying-glass"
                class="pointer-events-none absolute start-[11px] top-1/2 size-[15px] -translate-y-1/2 text-[#a8a5a0]"
              />
              <input
                type="text"
                name={filter.name}
                value={Map.get(@state.filter_values, filter.name) || ""}
                dir="auto"
                placeholder={filter_placeholder(filter)}
                phx-debounce="300"
                class="h-[38px] w-full rounded-[10px] border border-[#ecebe6] bg-[#f7f6f3] ps-[34px] pe-3 text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0]"
              />
            <% filter.type == :date_range -> %>
              <div class="flex h-[38px] items-center gap-1.5 rounded-[10px] border border-[#ecebe6] bg-white px-[9px]">
                <.dynamic_component
                  module={@static.ui_adapter}
                  function={:icon}
                  name="hero-calendar-days"
                  class="pointer-events-none size-[14px] shrink-0 text-[#8a877f]"
                />
                <input
                  type="date"
                  name={"#{filter.name}_from"}
                  value={date_value(@state, filter, :from)}
                  aria-label={dgettext("mishka_gervaz", "From")}
                  class={date_class()}
                />
                <span class="text-[11px] font-semibold text-[#bcb9b2] rtl:rotate-180">&rarr;</span>
                <input
                  type="date"
                  name={"#{filter.name}_to"}
                  value={date_value(@state, filter, :to)}
                  aria-label={dgettext("mishka_gervaz", "To")}
                  class={date_class()}
                />
              </div>
            <% segmented?(filter) -> %>
              <div class={track_class()}>
                <label
                  :for={{label, value, dot} <- segments(filter)}
                  class={[
                    segment_class(),
                    (selected?(@state, filter, value) && "bg-white text-[#1b1a18]") ||
                      "text-[#8a877f] hover:text-[#5c5a54]"
                  ]}
                >
                  <input
                    type="radio"
                    name={filter.name}
                    value={value}
                    checked={selected?(@state, filter, value)}
                    class="sr-only"
                  />
                  <span :if={dot} class={["size-[7px] shrink-0 rounded-full", dot]}></span>
                  {label}
                </label>
              </div>
            <% true -> %>
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-globe-alt"
                class="pointer-events-none absolute start-3 top-1/2 size-[14px] -translate-y-1/2 text-[#8a877f]"
              />
              <select
                name={filter.name}
                class="h-[38px] cursor-pointer appearance-none rounded-[10px] border border-[#ecebe6] bg-white ps-[34px] pe-8 text-[12.5px] font-semibold text-[#3a382f] outline-none hover:bg-[#f7f6f3]"
              >
                <option value="">{filter_prompt(filter)}</option>
                <.render_options
                  options={translate_options(filter.options || [])}
                  selected={Map.get(@state.filter_values, filter.name)}
                />
              </select>
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-chevron-down"
                class="pointer-events-none absolute end-3 top-1/2 size-[13px] -translate-y-1/2 text-[#a8a5a0]"
              />
          <% end %>
        </div>
      </div>

      <%!-- The range label and Clear ride at the end of the filter row (`ms-auto`); when the filters
            fill the row they wrap down together rather than squeezing the switches off their line. --%>
      <div class="ms-auto flex items-center gap-3">
        <span class="text-[12px] font-semibold text-[#a8a5a0]">{range_label(@state, @max_cap)}</span>

        <button
          :if={map_size(@state.filter_values || %{}) > 0}
          type="button"
          phx-click="clear_filters"
          phx-target={@myself}
          class="inline-flex h-[30px] cursor-pointer items-center gap-1.5 rounded-lg border border-[#ecebe6] bg-white px-[11px] text-[11.5px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-x-mark"
            class="size-[13px] text-[#a8a5a0]"
          />
          {dgettext("mishka_gervaz", "Clear")}
        </button>
      </div>
    </form>
    """
  end

  # Gervaz allows a grouped option list (`{group, [{label, value}]}`) as well as flat pairs; the
  # resource filter uses it to group resources by extension.
  defp render_options(assigns) do
    ~H"""
    <%= for option <- @options do %>
      <%= case option do %>
        <% {group, items} when is_list(items) -> %>
          <optgroup label={group}>
            <option
              :for={{label, value} <- items}
              value={to_string(value)}
              selected={to_string(@selected) == to_string(value)}
            >
              {label}
            </option>
          </optgroup>
        <% {label, value} -> %>
          <option value={to_string(value)} selected={to_string(@selected) == to_string(value)}>
            {label}
          </option>
      <% end %>
    <% end %>
    """
  end

  @impl true
  def render_item(assigns) do
    [event_column, actor_column, date_column | extra_columns] =
      pad(get_visible_columns(assigns.static.columns, assigns.state), 3)

    options = options(assigns.static)
    palette = tone_of(assigns.record) || Map.get(assigns.record, :severity)

    assigns =
      assigns
      |> assign(:event_column, event_column)
      |> assign(:actor_column, actor_column)
      |> assign(:date_column, date_column)
      |> assign(:extra_columns, extra_columns)
      |> assign(:node, node_class(palette))
      |> assign(:node_dot, dot_class(palette))
      |> assign(:first_of_day?, day_mark(assigns.record, :first_of_day?))
      |> assign(:day_label, day_label(Map.get(assigns.record, options[:timestamp])))
      |> assign(:day_count, event_count(day_mark(assigns.record, :day_count), options[:max_cap]))

    ~H"""
    <div id={@id}>
      <div :if={@first_of_day?} class="relative z-10 flex items-center gap-2.5 bg-white pb-2 pt-4">
        <span class="text-[11px] font-bold uppercase tracking-[0.09em] text-[#a8a5a0]">
          {@day_label}
        </span>
        <span class="h-px flex-1 bg-[#f0efea]"></span>
        <span class="text-[11px] font-semibold text-[#bcb9b2]">{@day_count}</span>
      </div>

      <div class="relative flex items-start gap-4 rounded-xl py-3 ps-[30px] pe-2 leading-[normal] transition-colors hover:bg-[#faf9f6]">
        <span class={[
          "absolute start-[5px] top-4 grid size-[14px] place-items-center rounded-full border-2 border-white shadow-[0_0_0_3px_#f4f3ef]",
          @node
        ]}>
          <span class={["size-[5px] rounded-full", @node_dot]}></span>
        </span>

        <div class="min-w-0 flex-1">
          <div :if={@event_column}>
            <Shared.render_cell
              column={@event_column}
              record={@record}
              static={@static}
              state={@state}
            />
          </div>

          <div class="mt-[7px] flex flex-wrap items-center gap-2">
            <div :if={@actor_column}>
              <Shared.render_cell
                column={@actor_column}
                record={@record}
                static={@static}
                state={@state}
              />
            </div>
            <div :for={column <- @extra_columns}>
              <Shared.render_cell column={column} record={@record} static={@static} state={@state} />
            </div>
          </div>
        </div>

        <div
          :if={@date_column}
          data-role="logtime"
          class="shrink-0 pt-px text-end max-[560px]:hidden!"
        >
          <Shared.render_cell column={@date_column} record={@record} static={@static} state={@state} />
        </div>
      </div>
    </div>
    """
  end

  defp dsl_text(text, fallback) when text in [nil, false], do: fallback

  defp dsl_text(text, _fallback) when is_binary(text),
    do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", text)

  defp dsl_text(text, _fallback), do: text

  # The day heading is the read's, not the record's: a LiveView stream never hands a row its
  # predecessor, so whether a row opens a day — and how many events that day holds — is decided while
  # the page is still an ordered list and carried here as metadata.
  defp day_mark(record, key), do: record.__metadata__ |> Kernel.||(%{}) |> Map.get(key)

  # The heading a row opening a new day carries. Today is named rather than dated — "TODAY · JUL 16"
  # — and drops the year, which is only ever this one.
  defp day_label(nil), do: nil

  defp day_label(at) do
    date = DateTime.to_date(at)

    if date == Date.utc_today(),
      do: dgettext("mishka_gervaz", "Today · %{date}", date: upcase(at, :MMMd)),
      else: upcase(at, :yMMMd)
  end

  defp upcase(at, format), do: at |> MishkaCmsCore.Localized.date(format) |> String.upcase()

  # "15 events". A day that filled the read's scan cap is only a floor, so it says so rather than
  # naming a total it never actually reached.
  defp event_count(count, max_cap) when is_integer(count) and count >= 0 do
    if is_integer(max_cap) and count >= max_cap,
      do:
        dgettext("mishka_gervaz", "%{count}+ events",
          count: MishkaCmsCore.Localized.number(max_cap)
        ),
      else: dngettext("mishka_gervaz", "%{count} event", "%{count} events", count)
  end

  defp event_count(_count, _max_cap), do: nil

  # One switch's worth of `{label, value, dot}`, the "all" pseudo-option first. A track whose options
  # are colour-coded names that option just "All" — the dots already say what the track is about, and
  # the whole bar has to stay on one line. Any other track spells its prompt out.
  defp segments(filter) do
    options = option_pairs(filter)
    toned? = Enum.any?(options, fn {_label, value} -> dot_class(value) end)

    all =
      if toned?,
        do: {dgettext("mishka_gervaz", "All"), "", "bg-[#c2bfb6]"},
        else: {filter_prompt(filter), "", nil}

    [all | Enum.map(options, fn {label, value} -> {label, value, dot_class(value)} end)]
  end

  # A content-change row's `:tone` colours the node by action; only an atom does — an unloaded calc
  # (`%Ash.NotLoaded{}`) is not a tone, so the row falls back to its `:severity`.
  defp tone_of(%{tone: tone}) when is_atom(tone), do: tone
  defp tone_of(_record), do: nil

  @doc """
  The dot colour for one palette value — a `:severity` (`:info`/`:warn`/`:error`), a content-change
  `:tone` (`:created`/`:updated`/`:destroyed`), or an action filter's raw value (`create`/`update`/
  `destroy`, which resolve to their tone's colour). The node is a tinted disc (`node_class/1`) around
  this solid dot; the filter switch reuses it for its per-option dots. An unknown value renders no
  dot rather than guess. Accepts the atom or its string form.
  """
  @spec dot_class(atom() | String.t() | nil) :: String.t() | nil
  def dot_class(value) when is_atom(value) and not is_nil(value),
    do: value |> to_string() |> dot_class()

  def dot_class("info"), do: "bg-[#1f9d6b]"
  def dot_class("warn"), do: "bg-[#cf8a24]"
  def dot_class("error"), do: "bg-[#d5544b]"
  def dot_class("created"), do: "bg-[#1f9d6b]"
  def dot_class("updated"), do: "bg-[#2f86c4]"
  def dot_class("destroyed"), do: "bg-[#d5544b]"

  # An action filter's option values are the raw actions, not the tones the rows carry, so the switch's
  # per-option dots match the row dots only if the present tense resolves to the same colour.
  def dot_class("create"), do: dot_class("created")
  def dot_class("update"), do: dot_class("updated")
  def dot_class("destroy"), do: dot_class("destroyed")
  def dot_class(_value), do: nil

  @doc """
  The tinted-disc background the node draws around its `dot_class/1` dot, for a `:severity` or a
  content-change `:tone`. An unknown or `nil` value reads as the `:info`/`:created` green. Accepts
  the atom or its string form.
  """
  @spec node_class(atom() | String.t() | nil) :: String.t()
  def node_class(value) when is_atom(value) and not is_nil(value),
    do: value |> to_string() |> node_class()

  def node_class("warn"), do: "bg-[#fbf1df]"
  def node_class("error"), do: "bg-[#fbe9e7]"
  def node_class("updated"), do: "bg-[#e6f1fa]"
  def node_class("destroyed"), do: "bg-[#fbe9e7]"
  def node_class(_value), do: "bg-[#e6f6ee]"

  @doc """
  The `bg-`/`text-` pair an actor avatar carries for a row of this palette value — the same tint the
  node beside it uses, so the two always agree. Takes the row's tone-or-severity, not the actor: the
  name already says who that was.

  For a resource's `:actor` column `render`; a content-change `:tone` (`:created`/`:updated`/
  `:destroyed`) colours by action, any other value by severity, and an unknown one reads green.
  Accepts the atom or its string form.
  """
  @spec avatar_tone_class(atom() | String.t() | nil) :: String.t()
  def avatar_tone_class(value) when is_atom(value) and not is_nil(value),
    do: value |> to_string() |> avatar_tone_class()

  def avatar_tone_class("warn"), do: "bg-[#fbf1df] text-[#cf8a24]"
  def avatar_tone_class("error"), do: "bg-[#fbe9e7] text-[#d5544b]"
  def avatar_tone_class("updated"), do: "bg-[#e6f1fa] text-[#2f86c4]"
  def avatar_tone_class("destroyed"), do: "bg-[#fbe9e7] text-[#d5544b]"
  def avatar_tone_class(_value), do: "bg-[#e6f6ee] text-[#1f9d6b]"

  @doc """
  The footer: a centred load-more, driven straight from the ui_adapter so it can carry the design's
  classes (`Shared.render_pagination/1` hardcodes its own).
  """
  @impl true
  def render_pagination(assigns) do
    assigns =
      assigns
      |> assign(
        :load_more_label,
        dsl_text(
          assigns.static.pagination_ui.load_more_label,
          dgettext("mishka_gervaz", "Load more events")
        )
      )
      |> assign(
        :load_more?,
        get_in(assigns.static.config, [:pagination, :type]) == :load_more and
          assigns.state.has_more? and assigns.state.loading != :loading
      )

    ~H"""
    <div :if={@load_more?} class="mt-[22px] flex justify-center">
      <button
        type="button"
        phx-click="load_more"
        phx-target={@myself}
        class="inline-flex h-[42px] cursor-pointer items-center gap-2 rounded-xl border border-[#ecebe6] bg-white px-[22px] text-[13px] font-semibold text-[#4f4bcc] transition-colors hover:border-[#dcdbf5] hover:bg-[#eeedfb]"
      >
        <.dynamic_component
          module={@static.ui_adapter}
          function={:icon}
          name="hero-arrow-down"
          class="size-[15px]"
        />
        {@load_more_label}
      </button>
    </div>
    """
  end

  # ── internal ─────────────────────────────────────────────────────────────────

  defp render_loading_overlay(assigns) do
    assigns =
      assign(
        assigns,
        :loading_text,
        dsl_text(
          assigns.static.pagination_ui.loading_text,
          dgettext("mishka_gervaz", "Loading...")
        )
      )

    ~H"""
    <div class="absolute inset-0 z-20 flex min-h-[200px] items-center justify-center rounded-[18px] bg-white/70">
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

  # "20 of 10,000+ shown" — how much of what the filters match is on screen. Gervaz's own
  # `page_info_format` speaks only `{page}`/`{total}`/`{count}` and its pagination renders no info
  # line for `:load_more`, so the window is named here; the total comes from the read's count.
  # A total at the read's scan cap is only a floor and says so.
  defp range_label(%{total_count: total} = state, max_cap) when is_integer(total) and total > 0 do
    shown = min((state.page || 1) * page_size(state), total)

    dgettext("mishka_gervaz", "%{shown} of %{total} shown",
      shown: shown,
      total: MishkaCmsCore.Localized.number(total) <> capped_suffix(total, max_cap)
    )
  end

  defp range_label(_state, _max_cap), do: nil

  defp capped_suffix(total, max_cap) when is_integer(max_cap) and total >= max_cap, do: "+"
  defp capped_suffix(_total, _max_cap), do: ""

  defp page_size(%{current_page_size: size}) when is_integer(size) and size > 0, do: size
  defp page_size(%{static: %{page_size: size}}) when is_integer(size) and size > 0, do: size
  defp page_size(_state), do: 20

  defp options(static), do: Keyword.merge(@default_options, static.template_options || [])

  defp segment_class, do: @segment_class

  defp track_class, do: @track_class

  defp date_class, do: @date_class

  defp date_value(state, filter, key) do
    case Map.get(state.filter_values, filter.name) do
      %{} = range -> range |> Map.get(key) |> date_string()
      _value -> ""
    end
  end

  defp date_string(%Date{} = date), do: Date.to_iso8601(date)
  defp date_string(value) when is_binary(value), do: value
  defp date_string(_value), do: ""

  defp segmented?(%{type: :select} = filter), do: length(option_pairs(filter)) <= @segmented_limit
  defp segmented?(_filter), do: false

  # Flatten Gervaz's option list, which may be flat pairs or `{group, [pairs]}`.
  defp option_pairs(%{options: options}) when is_list(options) do
    options
    |> translate_options()
    |> Enum.flat_map(fn
      {_group, items} when is_list(items) -> items
      {label, value} -> [{label, value}]
      other -> [{other, other}]
    end)
  end

  defp option_pairs(_filter), do: []

  defp selected?(state, filter, value) do
    to_string(Map.get(state.filter_values, filter.name) || "") == to_string(value)
  end

  # The search takes whatever the switches and the dropdown leave, so the bar stays on one line at
  # any width the design's 1040px column allows; below 980px the whole box wraps instead.
  defp filter_wrapper_class(%{type: :text}),
    do: "relative min-w-[110px] flex-1 max-[980px]:w-full! max-[980px]:flex-[1_1_100%]!"

  defp filter_wrapper_class(%{type: :date_range}), do: "flex flex-none"

  defp filter_wrapper_class(filter) do
    if segmented?(filter), do: "flex flex-none", else: "relative flex-none"
  end

  defp filter_prompt(%{ui: %{prompt: prompt}}) when not is_nil(prompt), do: resolve(prompt)
  defp filter_prompt(_filter), do: dgettext("mishka_gervaz", "All")

  defp filter_placeholder(%{ui: %{prompt: prompt}}) when not is_nil(prompt), do: resolve(prompt)
  defp filter_placeholder(_filter), do: dgettext("mishka_gervaz", "Search events…")

  defp resolve(value) when is_function(value, 0), do: value.()
  defp resolve(value), do: dsl_text(value, nil)

  # Guarantee at least `n` leading elements so the destructure never fails on a short column list.
  defp pad(list, n) when length(list) >= n, do: list
  defp pad(list, n), do: list ++ List.duplicate(nil, n - length(list))
end
