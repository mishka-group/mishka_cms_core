defmodule MishkaCmsCoreWeb.Live.Admin.Builder.Panels do
  @moduledoc """
  Every region of the page-builder chrome as a function component: the 56px top bar, the two
  resizable side panels, the crumb bar, the canvas frames, the code drawer, the command palette and
  the overlay sheets.

  Kept apart from `MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive` so the LiveView reads as the
  editor's behaviour — mount, events, session — and this reads as its surface. The measurements come
  straight from the design prototype: 56px bar, a 272px left panel clamped to 230–460, a 300px right
  panel clamped to 220–480, 6px drag grips, a 120–620px drawer, and the 900px breakpoint below which
  both panels collapse into a tab strip.

  The core's own rails, inspector sections and commands are declared here as
  `MishkaCmsCore.Builder.Descriptor` seeds, so the core enters its own registries through the same
  door a plugin does. The canvas toolbar's seed is not among them: that bar is drawn inside the
  frame, so it is declared where it is rendered, in `MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive`.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Phoenix.LiveView.JS
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Presence
  # The prototype's icon set, geometry and all. Ported rather than approximated: an icon drawn "close
  # enough" is the difference a reader notices first, and several of these are two or three shapes
  # (a camera lens, an eye's pupil, a duplicate's offset card) that a single path cannot express.
  #
  # A `:path` value is a plain `d`; anything else is the list of SVG child elements to emit.
  # MOTION, IN BOTH DIRECTIONS, WITHOUT KEEPING ANYTHING MOUNTED.
  #
  # An overlay gated by `:if={@open}` is gone from the DOM the instant the assign flips, so a CSS
  # leave transition never gets a frame to run in — which is why every one of these used to snap.
  # LiveView's answer is `phx-remove`: `DOMPatch.maybePendingRemove/1` sees the binding, refuses to
  # discard the node, runs the commands, and removes it when they finish. So the enter rides
  # `phx-mounted` and the leave rides `phx-remove`, and the `:if` never changes.
  #
  # That is what keeps the expensive sheets lazy. The server drops the subtree the moment the sheet
  # closes — the Gervaz components, the async reads, the upload registration all go with it — and
  # what animates out is the markup the browser already had. Nothing is held open to play it.
  #
  # `:time` MUST match the `duration-*` beside it: removal is scheduled on a timer, not on
  # `transitionend`, and a duration longer than the time is simply cut off.
  #
  # Three speeds, taken from what the admin already uses rather than invented: a menu is nearly
  # instant because it opens under the cursor, a sheet is quick, a modal takes the longest because
  # it covers the page. Leaving is faster than arriving in every pair — waiting to get somewhere is
  # normal, waiting to leave is not.
  @menu_in {"transition-[opacity,transform] ease-out duration-100", "opacity-0 scale-95",
            "opacity-100 scale-100"}
  @menu_out {"transition-[opacity,transform] ease-in duration-75", "opacity-100 scale-100",
             "opacity-0 scale-95"}

  @scrim_in {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
  @scrim_out {"transition-opacity ease-in duration-150", "opacity-100", "opacity-0"}

  @modal_in {"transition-[opacity,transform] ease-out duration-200", "opacity-0 scale-95",
             "opacity-100 scale-100"}
  @modal_out {"transition-[opacity,transform] ease-in duration-150", "opacity-100 scale-100",
              "opacity-0 scale-95"}

  # A MENU IS THE BROWSER'S BUSINESS. Nothing behind these needs the server: the markup is already
  # on the page, so opening it over the wire buys a round trip, a re-render of the panel it hangs
  # off, and a menu that lags the cursor. The pair below is the whole vocabulary — `menu_toggle/1`
  # on whatever opens it, `menu_close/1` on the wrapper's click-away and on any item that acts.
  #
  # An item MUST close it itself. `JS.show` writes `display` as a sticky style, which by design
  # survives the next patch — so a `handle_event` that used to set the flag false can no longer put
  # the menu away, and an item that only pushes leaves it hanging open over the thing it just did.
  @doc false
  def menu_toggle(id), do: JS.toggle(to: id, in: @menu_in, out: @menu_out, time: 100)

  @doc false
  def menu_close(id), do: JS.hide(to: id, transition: @menu_out, time: 75)

  @doc false
  def modal_in(panel) do
    @scrim_in
    |> JS.transition(time: 200)
    |> JS.transition(@modal_in, to: panel, time: 200)
  end

  @doc false
  def modal_out(panel) do
    JS.hide(transition: @scrim_out, time: 150)
    |> JS.hide(to: panel, transition: @modal_out, time: 150)
  end

  @icons %{
    # ---- top bar
    grip: [
      {"circle", %{"cx" => "9", "cy" => "5", "r" => "1.7"}},
      {"circle", %{"cx" => "15", "cy" => "5", "r" => "1.7"}},
      {"circle", %{"cx" => "9", "cy" => "12", "r" => "1.7"}},
      {"circle", %{"cx" => "15", "cy" => "12", "r" => "1.7"}},
      {"circle", %{"cx" => "9", "cy" => "19", "r" => "1.7"}},
      {"circle", %{"cx" => "15", "cy" => "19", "r" => "1.7"}}
    ],
    more: [
      {"circle", %{"cx" => "5", "cy" => "12", "r" => "1.8"}},
      {"circle", %{"cx" => "12", "cy" => "12", "r" => "1.8"}},
      {"circle", %{"cx" => "19", "cy" => "12", "r" => "1.8"}}
    ],
    frames: "M3 4h6v16H3zM11 4h5v16h-5zM18 4h3v16h-3z",
    desktop: "M3 5h18v11H3z M8 20h8M12 16v4",
    tablet: "M6 3h12v18H6z M11 18h2",
    mobile: "M8 2h8v20H8z M11 19h2",
    undo: "M3 12a9 9 0 1 1 3 6.7L3 16 M3 21v-5h5",
    redo: "M21 12a9 9 0 1 0-3 6.7L21 16 M21 21v-5h-5",
    image: [
      {"rect", %{"x" => "3", "y" => "4", "width" => "18", "height" => "16", "rx" => "2"}},
      {"path", %{"d" => "m3 16 5-4 4 3 4-4 5 4"}},
      {"circle", %{"cx" => "8.5", "cy" => "9", "r" => "1.4"}}
    ],
    comment: "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z",
    # A compact arrow: the head at the left on the mid-line, the tail curving away under it. Drawn
    # short and wide rather than across the full box, because it is used at 12px inside a 22px
    # square — a glyph that spans all 24 units loses its arrowhead at that size.
    reply: "M9 8 4 13l5 5M4 13h10a4 4 0 0 1 4 4",
    folder: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
    history: "M4 12a8 8 0 1 0 8-8 M4 5v4h4 M12 8v4l3 2",
    code: "M8 6 3 12l5 6M16 6l5 6-5 6",
    eye: [
      {"path", %{"d" => "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"}},
      {"circle", %{"cx" => "12", "cy" => "12", "r" => "3"}}
    ],
    eye_off:
      "M3 3l18 18 M10.6 10.6a2 2 0 0 0 2.8 2.8 M6.5 6.6C4.2 8.1 2 12 2 12s3.5 7 10 7c1.8 0 3.4-.5 4.7-1.2 M12 5c6.5 0 10 7 10 7s-.8 1.5-2.3 3",
    # A pushpin seen from the side: the head, the shoulders, the shaft. Drawn upright rather than
    # tilted, because at 12px a tilted pin reads as a paperclip.
    pin: "M12 17v5 M9.5 3h5l-.8 6 3.3 2.6V14H7v-2.4L10.3 9z",
    moon: "M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z",
    sun:
      "M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M4.9 19.1l1.8-1.8M17.3 6.7l1.8-1.8",
    draft: "M4 5a2 2 0 0 1 2-2h9l5 5v11a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z M14 3v5h5",
    rocket: "M20 7 10 17l-5-5",
    search: [
      {"circle", %{"cx" => "11", "cy" => "11", "r" => "7"}},
      {"path", %{"d" => "m20 20-3.2-3.2"}}
    ],
    plus: "M12 6v12M6 12h12",
    minus: "M6 12h12",
    trash: "M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13",
    copy: [
      {"rect", %{"x" => "9", "y" => "9", "width" => "12", "height" => "12", "rx" => "2"}},
      {"path", %{"d" => "M5 15V5a2 2 0 0 1 2-2h10"}}
    ],
    chevron: "m9 6 6 6-6 6",
    chevron_up: "m6 15 6-6 6 6",
    chevron_down: "m6 9 6 6 6-6",
    close: "M18 6 6 18M6 6l12 12",
    crop:
      "M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3",
    pen: "M4 20h4L18.5 9.5a2 2 0 0 0-3-3L5 17z",
    publish_arrow: "M12 19V5M5 12l7-7 7 7",
    check: "M20 7 10 17l-5-5",
    download: "M12 4v10M8 11l4 4 4-4 M4 20h16",
    upload: "M12 16V4M7 9l5-5 5 5 M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3",
    refresh: "M20 11a8 8 0 1 0-2.3 6.2 M20 5v6h-6",
    external: "M14 4h6v6 M20 4l-8 8 M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5",
    frame:
      "M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3",
    paperclip: "M21 11.5 12.5 20a5 5 0 0 1-7-7l8-8a3.5 3.5 0 0 1 5 5l-8 8a2 2 0 0 1-3-3l7-7",
    edit:
      "M11 4H5a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-6 M18.5 2.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z",
    attach: "M12 5v14M5 12h14",
    # ---- rails
    layers: "M4 6h16M4 12h16M4 18h16",
    star: "M12 3.5 14.6 9l6 .9-4.3 4.2 1 6-5.3-2.8L6.7 20l1-6L3.4 9.9l6-.9z",
    clock: [
      {"circle", %{"cx" => "12", "cy" => "12", "r" => "8.5"}},
      {"path", %{"d" => "M12 7.5V12l3 2"}}
    ],
    language: [
      {"circle", %{"cx" => "12", "cy" => "12", "r" => "8.5"}},
      {"path",
       %{
         "d" =>
           "M3.5 12h17M12 3.5c2.3 2.4 3.5 5.2 3.5 8.5s-1.2 6.1-3.5 8.5c-2.3-2.4-3.5-5.2-3.5-8.5s1.2-6.1 3.5-8.5z"
       }}
    ],
    arrow_right: "M4 12h14M12 5l7 7-7 7",
    bolt: "M13 2 4 14h7l-1 8 9-12h-7z",
    shield: "M9 11l3 3 5-5M12 3 19 6v6c0 4-3 7-7 8-4-1-7-4-7-8V6z",
    # ---- the palette's per-component set, verbatim from the prototype's `IC` table
    box: "M4 5h16v14H4z",
    window: "M3 4h18v16H3z M3 9h18",
    text: "M4 6h16M4 12h12M4 18h8",
    head: "M6 5v14M14 5v14M6 12h8M18 8v11",
    nav: "M4 7h16M4 12h16M4 17h10",
    img: "M3 5h18v14H3z M3 16l5-4 4 3 5-5 4 3",
    btn: "M4 8h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2z",
    input: "M3 8h18v8H3z M7 11v2",
    list: "M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01",
    grid: "M4 4h7v7H4z M13 4h7v7h-7z M4 13h7v7H4z",
    card: "M4 5h16v14H4z M4 10h16",
    modal: "M6 7h12v10H6z M3 4h18",
    tip: "M4 5h16v9H4z M9 14l3 4 3-4",
    key: "M3 8h18v8H3z M6 11h.01M9 11h.01M12 11h.01M15 11h.01M7 14h10",
    gallery: "M3 5h8v8H3z M13 5h8v5h-8z M13 12h8v7h-8z M3 15h8v4H3z",
    dial: "M12 12v-5 M12 12l4 3 M4 12a8 8 0 1 1 16 0z",
    page: "M7 3h7l4 4v14H7z M13 3v5h5",
    link: "M9 12h6M10 8H8a4 4 0 0 0 0 8h2M14 8h2a4 4 0 0 1 0 8h-2",
    lock: "M5 11h14v10H5z M8 11V7a4 4 0 0 1 8 0v4",
    table: "M3 5h18v14H3z M3 10h18M9 10v9",
    form: "M3 8h18v8H3z M7 11v2",
    sliders: "M4 5h16M4 12h10M4 19h7",
    move:
      "M12 3v18M3 12h18M12 3 9.5 5.5M12 3l2.5 2.5M12 21l-2.5-2.5M12 21l2.5-2.5M3 12l2.5-2.5M3 12l2.5 2.5M21 12l-2.5-2.5M21 12l-2.5 2.5",
    sparkle: "M13 2 4 14h7l-1 8 9-12h-7z"
  }

  # A descriptor's icon is a plain string so a plugin can name one without depending on this module's
  # atoms; only names this panel actually draws are honoured, and anything else falls back.
  @icon_names Map.new(Map.keys(@icons), &{Atom.to_string(&1), &1})

  defp shapes(name) do
    case Map.get(@icons, name, @icons.box) do
      d when is_binary(d) -> [{"path", %{"d" => d}}]
      list -> list
    end
  end

  attr(:name, :atom, required: true)
  attr(:size, :integer, default: 15)
  attr(:class, :string, default: nil)
  attr(:filled, :boolean, default: false, doc: "solid rather than stroked — the drag grip's dots")

  @doc "One inline SVG from the prototype's icon set — no icon font, no runtime lookup."
  def icon(assigns) do
    assigns = assign(assigns, :shapes, shapes(assigns.name))

    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill={(@filled && "currentColor") || "none"}
      stroke={(@filled && "none") || "currentColor"}
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      <.dynamic_tag :for={{tag, attrs} <- @shapes} tag_name={tag} {attrs} />
    </svg>
    """
  end

  # The two canvas zooms, in percent: `:single` is one device frame, `:frame` the all-breakpoints row.
  @zoom_bounds %{single: {40, 200}, frame: {20, 100}}

  @doc """
  How far a canvas zoom may go — `{min, max}` in percent, for `:single` (one device frame) or
  `:frame` (the all-breakpoints row).

  The zoom controls carry these into the DOM as `data-min`/`data-max`, where the `PbZoom` hook
  clamps every click with them, and `BuilderLive` clamps the value it is told with the same pair.
  """
  @spec zoom_bounds(:single | :frame) :: {pos_integer(), pos_integer()}
  def zoom_bounds(kind), do: Map.fetch!(@zoom_bounds, kind)

  defp zoom_min(kind), do: kind |> zoom_bounds() |> elem(0)
  defp zoom_max(kind), do: kind |> zoom_bounds() |> elem(1)

  attr(:record, :any, default: nil)
  attr(:section, :string, required: true)
  attr(:back_path, :string, required: true)
  attr(:current_user, :any, default: nil)
  attr(:editors, :list, default: [])
  attr(:dirty?, :boolean, default: false)
  attr(:saved_at, :any, default: nil)
  attr(:stage, :atom, default: :draft)
  attr(:applied_stage, :atom, default: :draft)
  attr(:device, :string, default: nil)
  attr(:dir, :string, default: "ltr")
  attr(:zoom, :integer, default: 100)
  attr(:preview?, :boolean, default: false)
  attr(:dev_mode?, :boolean, default: false)
  attr(:history_position, :integer, default: 0)
  attr(:history_total, :integer, default: 0)

  @doc "The 56px top bar: identity and save status on the left, every global control on the right."
  def top_bar(assigns) do
    ~H"""
    <header class="flex h-14 flex-none items-center gap-3.5 border-b border-[#e6e4de] bg-white px-4 max-[1060px]:gap-2 max-[1060px]:px-2.5">
      <span
        id="pb-leave-guard"
        phx-hook="PbLeaveGuard"
        data-armed={to_string(@stage == :published and @dirty?)}
        class="hidden"
      />
      <div class="flex flex-none items-center gap-2.5">
        <.link
          id="pb-back"
          navigate={@back_path}
          class="grid size-[30px] flex-none place-items-center rounded-[9px] bg-[#f2f1ec] text-[#5c5a54] hover:text-[#4f4bcc]"
          title={gettext("Back")}
        >
          <.icon name={:chevron} size={15} class="rotate-180" />
        </.link>
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-1.5">
            <div class="truncate text-[13.5px] font-bold leading-tight text-[#17161a]">
              {builder_label(assigns)}
            </div>
            <%!-- WHOSE DOCUMENT THIS IS, on the one screen that could not say. A component or a
                  layout may belong to one site or to every site, and the two are edited at the same
                  address with the same chrome — so the reader had no way to tell a shared row they
                  are about to change for thirty sites from their own. The list pages have carried
                  this badge, in these colours, since they were written. --%>
            <span
              :if={scope_label(assigns)}
              data-role="pb-scope"
              title={scope_title(assigns)}
              class={[
                "flex-none rounded-full px-1.5 py-[1px] font-['Space_Grotesk'] text-[9.5px] font-bold",
                (global_document?(assigns) && "bg-[#f6f4fd] text-[#6d4fc0]") ||
                  "bg-[#f2f1ec] text-[#5c5a54]"
              ]}
            >
              {scope_label(assigns)}
            </span>
          </div>
          <div class="mt-0.5 flex items-center gap-1.5">
            <span class={[
              "size-[5px] rounded-full",
              (@dirty? && "bg-[#cf8a24]") || "bg-[#1f9d6b]"
            ]} />
            <span class="truncate text-[10px] font-medium text-[#6d6a63]">
              {document_label(assigns)}
            </span>
            <span class="flex-none text-[10px] font-medium text-[#6d6a63]">
              · {status_label(assigns)}
            </span>
          </div>
        </div>
      </div>

      <div class="flex-1"></div>

      <div
        data-role="pb-more"
        class="relative flex-none"
        phx-click-away={menu_close("#pb-more-menu")}
      >
        <button
          id="pb-more-btn"
          type="button"
          phx-click={menu_toggle("#pb-more-menu")}
          title={gettext("More")}
          class="grid size-8 place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
        >
          <.icon name={:more} size={16} />
        </button>
        <div
          id="pb-more-menu"
          phx-window-keydown={menu_close("#pb-more-menu")}
          phx-key="escape"
          class="absolute left-0 top-[38px] z-[70] hidden w-[236px] rounded-[13px] border border-[#ecebe6] bg-white p-1.5 shadow-[0_18px_46px_rgba(20,18,26,.22)]"
        >
          <%!-- Stepped in the browser by `PbZoom`, which tells the server through `zoom_set`. --%>
          <div
            id="pb-zoom"
            phx-hook="PbZoom"
            data-zoom="single"
            data-single-zoom={@zoom}
            data-min={zoom_min(:single)}
            data-max={zoom_max(:single)}
            data-event="zoom_set"
            class="flex items-center gap-1.5 px-2 py-2"
          >
            <span class="flex-1 text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#6d6a63]">
              {gettext("Zoom")}
            </span>
            <button
              type="button"
              id="pb-zoom-out"
              data-zoom-step="-10"
              title={gettext("Zoom out")}
              disabled={@zoom <= zoom_min(:single)}
              class="grid size-[26px] place-items-center rounded-[7px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3] disabled:cursor-not-allowed disabled:text-[#c3c0b8]"
            >
              <.icon name={:minus} size={13} />
            </button>
            <button
              type="button"
              id="pb-zoom-reset"
              data-zoom-reset="100"
              class="h-[26px] min-w-12 rounded-[7px] border border-[#ecebe6] bg-[#faf9f6] font-['Space_Grotesk'] text-[11px] font-bold text-[#3a382f] hover:bg-[#f2f1ec]"
            >
              <span data-zoom-label="single">{@zoom}%</span>
            </button>
            <button
              type="button"
              id="pb-zoom-in"
              data-zoom-step="10"
              title={gettext("Zoom in")}
              disabled={@zoom >= zoom_max(:single)}
              class="grid size-[26px] place-items-center rounded-[7px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3] disabled:cursor-not-allowed disabled:text-[#c3c0b8]"
            >
              <.icon name={:plus} size={13} />
            </button>
          </div>
          <span class="mx-1.5 my-1 block h-px bg-[#f0efea]" />
          <%!-- The draft saves itself on a timer, so this is the "now, please" — kept off the top bar
                because the prototype has no Save there and an autosaving editor does not need one. --%>
          <%!-- Undo and redo lost their buttons when the bar went down to one circular icon — three
                near-identical arrows read as three refreshes. The keys still work (⌘Z / ⇧⌘Z) and the
                capability is here, where a menu can say what it will do and whether it can. --%>
          <.more_item
            id="pb-undo"
            event="undo"
            value={%{}}
            icon={:undo}
            label={gettext("Undo")}
            hint={"#{@history_position}/#{@history_total}"}
            badge="⌘Z"
          />
          <.more_item
            id="pb-redo"
            event="redo"
            value={%{}}
            icon={:redo}
            label={gettext("Redo")}
            badge="⇧⌘Z"
          />
          <span class="mx-1.5 my-1 block h-px bg-[#f0efea]" />
          <.more_item
            id="pb-save"
            event="save"
            value={%{}}
            icon={:draft}
            label={gettext("Save draft now")}
            badge="⌘S"
          />
          <%!-- The direction toggle has its own pair of buttons in the bar, but that pair is the
                first thing the collapse ladder drops — so it needs a home that survives. --%>
          <.more_item
            event="set_dir"
            value={%{dir: (@dir == "ltr" && "rtl") || "ltr"}}
            icon={:nav}
            label={gettext("Text direction")}
            badge={String.upcase(@dir)}
            state_badge
          />
          <%!-- IT USED TO HANG OFF THE PREVIEW CARET, which is gone from every page that has no
                draft to share. It belongs here anyway: it is an editor-wide switch like the
                direction above it, not a way of previewing. --%>
          <.more_item
            id="pb-more-dev"
            event="toggle_dev_mode"
            value={%{}}
            icon={:code}
            label={gettext("Developer mode")}
            description={
              (@dev_mode? && gettext("Outlines and node ids are showing")) ||
                gettext("Show outlines and node ids")
            }
            state_badge
            badge={(@dev_mode? && gettext("On")) || gettext("Off")}
          />
          <span class="mx-1.5 my-1 block h-px bg-[#f0efea]" />
          <.more_item
            event="zoom_reset"
            value={%{}}
            icon={:frames}
            label={gettext("Fit to screen")}
            badge="⇧1"
          />
        </div>
      </div>

      <div data-role="pb-devices" class="flex flex-none rounded-[10px] bg-[#f2f1ec] p-[3px]">
        <button
          :for={{key, label, _hint} <- devices()}
          type="button"
          id={"pb-device-#{key}"}
          phx-click="set_device"
          phx-value-device={key}
          title={translate(label)}
          class={[
            "grid h-[30px] w-[34px] place-items-center rounded-lg max-[1060px]:w-[30px]",
            (@device == key && "bg-white text-[#4f4bcc] shadow-[0_1px_3px_rgba(20,18,26,.12)]") ||
              "text-[#6d6a63] hover:text-[#4f4bcc]"
          ]}
        >
          <.icon name={key} size={15} />
        </button>
      </div>

      <span data-role="pb-divider" class="h-6 w-px flex-none bg-[#ecebe6] max-[1000px]:hidden" />

      <div
        data-role="pb-actions"
        class="flex min-w-0 flex-none items-center gap-1.5 max-[1060px]:gap-1"
      >
        <%!-- Re-renders the CANVAS, not the editor. The document inside the frame is drawn by
              compiled component modules and the site's stylesheet, both of which can change while
              this page stays open — recompile a component in another tab and the canvas is showing
              yesterday's markup until something forces it to fetch again. Reloading the whole editor
              would work and would also throw away the panel state, the drawer, and the scroll
              position, so this reloads exactly the frame. --%>
        <button
          id="pb-reload"
          type="button"
          phx-click="reload_canvas"
          title={gettext("Reload the canvas")}
          class="grid size-8 place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"
        >
          <.icon name={:refresh} size={15} />
        </button>



        <div
          data-role="pb-dir"
          class="flex flex-none rounded-[9px] bg-[#f2f1ec] p-0.5 max-[1080px]:hidden"
        >
          <button
            :for={d <- ~w(ltr rtl)}
            type="button"
            id={"pb-dir-#{d}"}
            phx-click="set_dir"
            phx-value-dir={d}
            class={[
              "h-7 w-[30px] rounded-[7px] font-['Space_Grotesk'] text-[10px] font-bold",
              (@dir == d && "bg-white text-[#4f4bcc] shadow-[0_1px_3px_rgba(20,18,26,.12)]") ||
                "text-[#6d6a63]"
            ]}
          >
            {String.upcase(d)}
          </button>
        </div>

        <span data-role="pb-divider" class="h-5 w-px flex-none bg-[#e6e4de] max-[1000px]:hidden" />


            <.bar_button
              id="pb-preview"
              event="toggle_preview"
              value={%{}}
              icon={:eye}
              label={gettext("Preview")}
              active={@preview?}
              tone={:green}
            />
        <%!-- The toggle is CLIENT state. The theme lives on `<html data-theme>` and in localStorage,
              written by the root layout's own script, so a server assign would be a second copy of it
              that is wrong the moment another tab, or the console's own switch, changes it — which is
              exactly how this button ended up only ever turning dark ON. The hook reads the live
              attribute and flips it; both icons are rendered and CSS picks. --%>
        <button
          id="pb-theme"
          type="button"
          phx-hook="PbTheme"
          data-role="pb-themebtn"
          title={gettext("Toggle theme")}
          class="grid size-8 place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3] max-[880px]:hidden"
        >
          <.icon name={:moon} size={15} class="[[data-theme=dark]_&]:hidden" />
          <.icon name={:sun} size={15} class="hidden text-[#c8931f] [[data-theme=dark]_&]:block" />
        </button>
        <%!-- The stage control, as the prototype has it: one split button that SAYS where the page
              stands. Draft is a quiet violet-tinted pair with a pulsing dot; published is the solid
              gradient with a caret. There is no Save beside it because this editor autosaves a draft
              on a timer, exactly as the prototype does — "Save draft now" lives in the ••• menu for
              the case where you want to force one. --%>
        <div
          data-role="pb-publish"
          class="relative flex flex-none"
          phx-click-away={menu_close("#pb-stage-ways")}
        >
          <button
            id="pb-stage"
            type="button"
            phx-click={(@stage == @applied_stage && menu_toggle("#pb-stage-ways")) || "apply_stage"}
            title={stage_button_title(@stage, @applied_stage)}
            class={[
              "inline-flex h-8 items-center gap-[7px] rounded-l-[9px] border-r-0 px-[13px] text-[12px] font-bold max-[1000px]:px-2.5",
              ((@stage == :published or @stage != @applied_stage) &&
                 "border-0 bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-white shadow-[0_4px_12px_rgba(79,75,204,.28)]") ||
                "border border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]"
            ]}
          >
            <.icon name={stage_icon(@stage, @applied_stage)} size={14} />
            <span data-role="pb-lbl" class="max-[820px]:hidden">
              {stage_button_label(@stage, @applied_stage)}
            </span>
          </button>
          <button
            id="pb-stage-menu"
            type="button"
            phx-click={menu_toggle("#pb-stage-ways")}
            class={[
              "grid h-8 w-7 place-items-center rounded-r-[9px]",
              ((@stage == :published or @stage != @applied_stage) &&
                 "border-0 border-l border-l-white/[.28] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] shadow-[0_4px_12px_rgba(79,75,204,.28)]") ||
                "border border-l-[#dcdbf5] border-[#dcdbf5] bg-[#f2f1fc]"
            ]}
          >
            <span
              :if={@stage == :draft and @applied_stage == :draft}
              class="size-[7px] animate-pulse rounded-full bg-[#5b57d6]"
            />
            <.icon
              :if={@stage != :draft or @applied_stage != :draft}
              name={:chevron}
              size={13}
              class="rotate-90 text-white"
            />
          </button>
          <div
            id="pb-stage-ways"
            phx-window-keydown={menu_close("#pb-stage-ways")}
            phx-key="escape"
            class="absolute right-0 top-[38px] z-[70] hidden w-56 rounded-xl border border-[#ecebe6] bg-white p-[5px] shadow-[0_16px_44px_rgba(20,18,26,.2)]"
          >
            <button
              :for={{key, label, hint} <- stages()}
              type="button"
              id={"pb-stage-#{key}"}
              phx-click={menu_close("#pb-stage-ways") |> JS.push("set_stage")}
              phx-value-stage={key}
              class={[
                "flex w-full items-start gap-[9px] rounded-[9px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2]",
                @stage == key && "bg-[#faf9ff]"
              ]}
            >
              <span class={[
                "mt-0.5 size-[15px] flex-none rounded-full border-2",
                (@stage == key && "border-[#5b57d6] bg-[#5b57d6]") || "border-[#d5d3cc]"
              ]} />
              <span class="min-w-0 flex-1">
                <span class={[
                  "block text-[11.5px] font-bold",
                  (@stage == key && "text-[#2e2b6b]") || "text-[#3a382f]"
                ]}>
                  {label}
                </span>
                <span class="mt-0.5 block text-[10px] font-medium leading-[1.45] text-[#6d6a63]">
                  {hint}
                </span>
              </span>
              <%!-- Which one the page is on right now, so the menu answers that without being read
                    twice. --%>
              <span
                :if={@stage == key}
                class="mt-0.5 flex-none rounded-[5px] bg-[#e6f6ee] px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.05em] text-[#177a53]"
              >
                {gettext("Now")}
              </span>
            </button>
          </div>
        </div>
      </div>
      <%!-- Who is in this session, from Presence on its own topic. You are first, because you are
            always here — that is what gives the bar the prototype's avatar stack without inventing
            colleagues who are not watching. The count is real: a second chip means a second person on
            this page, where edits are last-write-wins at the op level. --%>
      <div
        data-role="pb-avatars"
        id="pb-avatars"
        title={avatars_title(@editors)}
        class="ml-1 flex flex-none items-center max-[1180px]:hidden"
      >
        <span
          :for={{initials, tone} <- avatars(@current_user, @editors)}
          class={[
            "grid size-[26px] place-items-center rounded-full border-2 border-white font-['Space_Grotesk'] text-[10px] font-bold [&:not(:first-child)]:-ml-2",
            tone
          ]}
        >
          {initials}
        </span>
      </div>
    </header>
    """
  end

  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:value, :map, default: %{})
  attr(:icon, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:active, :boolean, default: false)
  attr(:count, :integer, default: 0)
  attr(:tone, :atom, default: :violet, values: [:violet, :green])

  attr(:joined, :boolean,
    default: false,
    doc: "square the right edge — the left half of a split control"
  )

  defp bar_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-sheet={@value[:sheet]}
      title={@label}
      class={[
        "inline-flex h-8 items-center gap-1.5 border px-3 text-[12px] font-semibold max-[1000px]:px-2",
        (@joined && "rounded-l-[9px] border-r-0") || "rounded-[9px]",
        (@active && active_tone(@tone)) ||
          "border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
      ]}
    >
      <.icon name={@icon} size={14} />
      <span data-role="pb-lbl" class="max-[1000px]:hidden">{@label}</span>
      <span
        :if={@count > 0}
        id={"#{@id}-count"}
        class="flex h-4 min-w-4 items-center justify-center rounded-[9px] bg-[#c3373c] px-1 text-[10px] font-bold text-white"
      >
        {@count}
      </span>
    </button>
    """
  end

  # Preview is the one control whose "on" is not an editor mode but a state of the page, so the
  # prototype gives it the green the rest of the console uses for live/published.
  defp active_tone(:green), do: "border-[#cfe6d8] bg-[#e6f6ee] text-[#177a53]"
  defp active_tone(_violet), do: "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]"

  attr(:id, :string, default: nil)
  attr(:event, :string, required: true)
  attr(:value, :map, default: %{})
  attr(:icon, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:badge, :string, default: nil)

  attr(:hint, :string,
    default: nil,
    doc: "a small state note before the badge — an undo position"
  )

  attr(:description, :string,
    default: nil,
    doc: "a sentence UNDER the label saying what the item does"
  )

  attr(:accent, :boolean, default: false, doc: "a violet glyph — the palette's own entry")
  attr(:state_badge, :boolean, default: false, doc: "the badge reports state, not a shortcut")

  # A DESCRIPTION GOES UNDER THE THING IT DESCRIBES. Beside it, the two ran together into one line
  # that read as neither a title nor a sentence, and the label lost the weight that made it scannable
  # — the whole point of a menu is that the titles are read first and the rest only when one of them
  # is the answer.
  #
  # `hint` is NOT a description and stays on the title's line: it is a state note the size of a
  # badge — the undo position, "3/12" — and stacking it would give Undo a second line saying nothing.
  defp more_item(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={menu_close("#pb-more-menu") |> JS.push(@event)}
      phx-value-sheet={@value[:sheet]}
      phx-value-dir={@value[:dir]}
      phx-value-tab={@value[:tab]}
      class="flex w-full items-start gap-2.5 rounded-[9px] p-[9px] text-left hover:bg-[#f6f5f2]"
    >
      <.icon
        name={@icon}
        size={15}
        class={"mt-[1px] flex-none " <> ((@accent && "text-[#4f4bcc]") || "text-[#6d6a63]")}
      />
      <span class="min-w-0 flex-1">
        <span class="block text-[12px] font-semibold text-[#1b1a18]">{@label}</span>
        <span
          :if={@description}
          class="mt-0.5 block text-[10.5px] font-medium leading-[1.45] text-[#6d6a63]"
        >
          {@description}
        </span>
      </span>
      <span
        :if={@hint}
        class="mt-[2px] font-['Space_Grotesk'] text-[9.5px] font-medium text-[#a8a5a0]"
      >
        {@hint}
      </span>
      <%!-- A state badge is violet because it says what the editor is currently doing; a shortcut
            badge is grey because it says what to press. --%>
      <span
        :if={@badge}
        class={[
          "mt-[1px] flex-none rounded-[5px] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold",
          (@state_badge && "bg-[#f2f1fc] text-[#4f4bcc]") || "bg-[#f2f1ec] text-[#6d6a63]"
        ]}
      >
        {@badge}
      </span>
    </button>
    """
  end

  @doc "Below 900px both panels collapse into this horizontally scrolling tab strip."
  attr(:mob_panel, :atom, default: :canvas)
  # `dir` is here for `mobile_tabs/1`, whose last tab is the LTR/RTL switch and reads it directly.
  attr(:dir, :string, default: "ltr")

  def mobile_bar(assigns) do
    ~H"""
    <div
      data-role="pb-mobbar"
      id="pb-mobbar"
      class="hidden flex-none gap-1.5 overflow-x-auto border-b border-[#e6e4de] bg-white px-3.5 py-2.5 [scrollbar-width:none] max-[900px]:flex [&::-webkit-scrollbar]:hidden"
    >
      <button
        :for={{key, label} <- mobile_tabs(assigns)}
        type="button"
        id={"pb-mobtab-#{key}"}
        phx-click="set_mob_panel"
        phx-value-panel={key}
        class={[
          "h-9 flex-none whitespace-nowrap rounded-[10px] border px-[13px] text-[12px] font-semibold",
          (to_string(@mob_panel) == key && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
            "border-[#ecebe6] bg-white text-[#5c5a54]"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr(:fault, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:section, :string, default: "page")
  attr(:record, :any, default: nil)

  @doc """
  What the editor shows for a document it cannot parse.

  A CRASH LOOP IS THE WORST SHAPE A FAILURE CAN TAKE, because the page that has to be opened to fix
  the problem is the page that will not open. So: what the tokenizer objected to, where it stopped,
  the stored text itself, and a box to correct it in. Saving from here goes through the same action
  the editor saves with, so a correction that still will not parse is refused the same way.
  """
  def recover(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#f6f5f2] px-6 py-10 font-['Inter']">
      <section
        id="pb-recover"
        class="mx-auto flex w-full max-w-[860px] flex-col gap-4 rounded-[18px] border border-[#ecebe6] bg-white p-7 shadow-[0_20px_50px_rgba(20,18,26,.08)]"
      >
        <div class="flex items-start gap-3">
          <%!-- `:bolt`, not `:alert` — there is no `:alert` in `@icons`, and `icon/1` falls back to
                `:box` rather than failing, so the heading wore a blank square until somebody looked
                at it. --%>
          <span class="grid size-[38px] flex-none place-items-center rounded-[11px] bg-[#fdf3f1] text-[#c0473d]">
            <.icon name={:bolt} size={18} />
          </span>
          <div class="min-w-0">
            <h1 class="font-['Space_Grotesk'] text-[17px] font-bold text-[#17161a]">
              {gettext("This %{section} could not be opened",
                section: String.downcase(translate(Section.label(Section.normalize(@section))))
              )}
            </h1>
            <p class="mt-1 text-[12.5px] font-medium leading-[1.6] text-[#6d6a63]">
              {gettext(
                "Its stored markup does not parse, so there is no tree to edit. Correct it below and the editor opens on the result."
              )}
            </p>
          </div>
        </div>

        <p
          id="pb-recover-fault"
          class="rounded-[10px] border border-[#f0dcd8] bg-[#fdf3f1] px-3.5 py-2.5 font-['Space_Grotesk'] text-[12px] font-semibold leading-[1.6] text-[#c0473d]"
        >
          {@fault[:message] || gettext("The markup could not be read.")}
          <span :if={@fault[:line]} class="font-bold">
            — {(@fault[:column] &&
                  gettext("Line %{line}, column %{column}",
                    line: @fault[:line],
                    column: @fault[:column]
                  )) || gettext("Line %{line}", line: @fault[:line])}
          </span>
        </p>

        <form id="pb-recover-form" phx-submit="recover_template" class="flex flex-col gap-2.5">
          <textarea
            id="pb-recover-source"
            name="template"
            spellcheck="false"
            rows="16"
            data-accent-panel
            class="w-full resize-y rounded-[12px] border-0 bg-[#17161a] px-4 py-3.5 font-['Space_Grotesk'] text-[12.5px] leading-[1.7] text-[#c9c7d1] outline-none [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
          >{@fault[:template]}</textarea>

          <p
            :if={@error}
            id="pb-recover-error"
            class="rounded-[9px] bg-[#fdf3f1] px-3 py-2 text-[11.5px] font-semibold text-[#c0473d]"
          >
            {@error}
          </p>

          <div class="flex items-center gap-2.5">
            <button
              type="submit"
              id="pb-recover-save"
              class="rounded-[10px] bg-[#17161a] px-4 py-2.5 text-[12.5px] font-bold text-white hover:bg-[#2a282f]"
            >
              {gettext("Open with this markup")}
            </button>
            <.link
              navigate={"/admin/dashboard/runtime/#{@section}s"}
              class="rounded-[10px] border border-[#ecebe6] bg-white px-4 py-2.5 text-[12.5px] font-bold text-[#5c5a54] hover:border-[#dcdbf5]"
            >
              {gettext("Back to the list")}
            </.link>
          </div>
        </form>
      </section>
    </div>
    """
  end

  @doc "The centre column: crumb bar, the canvas frames, and the code drawer under them."
  attr(:token, :any, default: nil)
  attr(:record, :any, default: nil)
  attr(:crumbs, :list, default: [])
  attr(:selection, :string, default: nil)
  attr(:selected_node, :any, default: nil)
  attr(:device, :any, default: nil)
  attr(:zoom, :integer, default: 100)
  attr(:frame_row, :any, default: nil)
  attr(:frame_zoom, :integer, default: 100)
  attr(:breakpoint, :atom, default: :base)
  attr(:status, :any, default: nil)
  attr(:statuses, :list, default: [])
  def center(assigns) do
    ~H"""
    <main
      id="pb-canvaswrap"
      phx-hook="PbFrameBusy"
      data-role="pb-canvaswrap"
      class="flex min-w-0 flex-1 flex-col bg-[#f6f5f2]"
    >
      <%!-- An error page is a LIST of per-status templates, not one document, so it gets a strip to
            choose which status the canvas is showing. Every other section has nothing to switch. --%>
      <div
        :if={@statuses != []}
        id="pb-statuses"
        class="flex h-10 flex-none items-center gap-1.5 border-b border-[#e6e4de] bg-white px-3"
      >
        <span class="mr-1 text-[10px] font-bold uppercase tracking-[0.08em] text-[#8a877f]">
          {gettext("Status")}
        </span>
        <%!-- `navigate`, not `patch`: each status is a separate document with its own editing
              session, so switching has to re-mount rather than swap assigns under a live tree. --%>
        <.link
          :for={status <- @statuses}
          navigate={Section.builder_path("error-page", @record.id, status)}
          id={"pb-status-#{status}"}
          class={[
            "h-7 rounded-[8px] px-2.5 font-['Space_Grotesk'] text-[11.5px] font-bold leading-7",
            (@status == status && "bg-[#17161a] text-white") ||
              "bg-[#f2f1ec] text-[#6d6a63] hover:bg-[#e9e7e0]"
          ]}
        >
          {(status == :offline && gettext("offline")) || status}
        </.link>
        <%!-- A STATUS IS ADDED BY OPENING IT. The page an offline site shows, a 403, a 503: the entry
              is written when what is built for it is saved. --%>
        <details id="pb-status-add" class="relative">
          <summary class="flex h-7 cursor-pointer list-none items-center rounded-[8px] bg-[#f2f1ec] px-2.5 font-['Space_Grotesk'] text-[11.5px] font-bold text-[#6d6a63] hover:bg-[#e9e7e0]">
            {gettext("+ Status")}
          </summary>
          <div class="absolute left-0 top-8 z-30 flex max-h-72 w-56 flex-col overflow-y-auto rounded-[10px] border border-[#ecebe6] bg-white p-1 shadow-[0_12px_30px_rgba(20,18,26,.12)]">
            <.link
              :for={status <- Section.offered_statuses() -- @statuses}
              navigate={Section.builder_path("error-page", @record.id, status)}
              id={"pb-status-add-#{status}"}
              class="rounded-[7px] px-2.5 py-1.5 text-[11.5px] font-semibold text-[#3a382f] hover:bg-[#f6f5f2]"
            >
              {translate(MishkaCmsCore.Runtime.ErrorStatus.label(status))}
            </.link>
          </div>
        </details>
      </div>





      <div class="flex flex-none flex-wrap items-center gap-2.5 border-b border-[#e6e4de] bg-[#faf9f6] px-4 py-[9px]">
        <div
          data-role="pb-crumbs"
          class="flex min-w-0 items-center gap-[7px] overflow-x-auto font-['Space_Grotesk'] text-[11.5px] font-medium text-[#6d6a63] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden max-[960px]:hidden"
        >
          <button
            type="button"
            phx-click="select"
            class={[
              "whitespace-nowrap",
              (@selection && "text-[#6d6a63] hover:text-[#4f4bcc]") || "font-bold text-[#1b1a18]"
            ]}
          >
            body
          </button>
          <span :for={crumb <- @crumbs} class="inline-flex items-center gap-[7px]">
            <span class="text-[#6d6a63]">›</span>
            <button
              type="button"
              phx-click="select"
              phx-value-id={crumb.id}
              class={[
                "whitespace-nowrap",
                (crumb.id == @selection && "font-bold text-[#1b1a18]") ||
                  "text-[#6d6a63] hover:text-[#4f4bcc]"
              ]}
            >
              {FormPlacement.form_name(crumb) || node_label(crumb)}
            </button>
          </span>
        </div>
        <span class="flex-1"></span>

        <%!-- Side-by-side frames get their own zoom and a row/column toggle, because that view is
              about fitting three widths on screen at once rather than reading one at full size. The
              zoom is stepped in the browser by `PbZoom`, which tells the server through
              `frame_zoom_set`. --%>
        <span :if={@device == :frames} class="inline-flex flex-none items-center gap-[7px]">
          <span
            id="pb-frzoom"
            phx-hook="PbZoom"
            data-zoom="frame"
            data-frame-zoom={@frame_zoom}
            data-min={zoom_min(:frame)}
            data-max={zoom_max(:frame)}
            data-event="frame_zoom_set"
            class="inline-flex items-center gap-[7px]"
          >
            <button
              type="button"
              id="pb-frzoom-out"
              data-zoom-step="-10"
              title={gettext("Zoom out")}
              disabled={@frame_zoom <= zoom_min(:frame)}
              class="grid size-[26px] place-items-center rounded-[8px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1ec] disabled:cursor-not-allowed disabled:text-[#c3c0b8]"
            >
              <.icon name={:minus} size={13} />
            </button>
            <button
              type="button"
              id="pb-frzoom-reset"
              data-zoom-reset="100"
              title={gettext("Reset to 100%")}
              class="h-[26px] min-w-[46px] rounded-[8px] border border-[#ecebe6] bg-white px-1.5 font-['Space_Grotesk'] text-[11px] font-bold text-[#3a382f] hover:bg-[#f2f1ec]"
            >
              <span data-zoom-label="frame">{@frame_zoom}%</span>
            </button>
            <button
              type="button"
              id="pb-frzoom-in"
              data-zoom-step="10"
              title={gettext("Zoom in")}
              disabled={@frame_zoom >= zoom_max(:frame)}
              class="grid size-[26px] place-items-center rounded-[8px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1ec] disabled:cursor-not-allowed disabled:text-[#c3c0b8]"
            >
              <.icon name={:plus} size={13} />
            </button>
          </span>
          <span class="mx-[3px] h-[18px] w-px bg-[#e6e4de]"></span>
          <button
            type="button"
            id="pb-framedir"
            phx-click="toggle_frame_row"
            title={(@frame_row && gettext("Stack the frames")) || gettext("Lay the frames in a row")}
            class="inline-flex h-[26px] items-center gap-1.5 rounded-[8px] border border-[#ecebe6] bg-white px-2.5 text-[10.5px] font-semibold text-[#5c5a54] hover:bg-[#f2f1ec]"
          >
            <.icon name={(@frame_row && :frames) || :list} size={13} />
            {(@frame_row && gettext("In a row")) || gettext("Stacked")}
          </button>
        </span>

        <span
          :if={@device != :frames}
          data-role="pb-viewnote"
          class="whitespace-nowrap text-[11px] font-semibold text-[#6d6a63]"
        >
          {device_label(@device)} · <span data-zoom-label="single">{@zoom}%</span>
        </span>
      </div>

      <%!-- The zoom root: both zooms live here as `--pb-single-zoom` and `--pb-frame-zoom`, which
            the frames below read and `PbZoom` overwrites as the zoom buttons are clicked. --%>
      <div
        data-role="pb-scroll"
        id="pb-canvas-scroll"
        phx-hook="PbZoom"
        data-zoom="single frame"
        data-zoom-root
        data-single-zoom={@zoom}
        data-frame-zoom={@frame_zoom}
        style={"--pb-single-zoom:#{@zoom / 100};--pb-frame-zoom:#{@frame_zoom / 100}"}
        class={[
          "flex min-h-0 flex-1 items-start gap-4 overflow-auto p-[22px] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
          "[scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
          (@device == :frames && "justify-start") || "justify-center"
        ]}
      >
        <.frames
          :if={@device == :frames}
          token={@token}
          frame_row={@frame_row}
          breakpoint={@breakpoint}
          selected_node={@selected_node}
        />
        <.single_frame :if={@device != :frames} token={@token} device={@device} />
      </div>


    </main>
    """
  end

  # The frame stretches to whatever height is left rather than subtracting a guessed number of
  # pixels from the viewport. A fixed `calc(100vh - …)` has to be re-guessed every time something
  # above or below it changes — opening the code drawer, or the editor going full-page and losing
  # the admin topbar — and is wrong in between.
  # What the frame shows before the socket connects. It is the frame's own surface, not an overlay:
  # an overlay would still need an iframe underneath it, which is the thing that must not exist yet.
  defp frame_loading(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col items-center justify-center gap-3 bg-white">
      <span class="size-6 animate-spin rounded-full border-2 border-[#e6e4de] border-t-[#5b57d6]"></span>
      <span class="text-[11.5px] font-semibold text-[#a8a5a0]">{gettext("Loading the canvas…")}</span>
    </div>
    """
  end

  # ON TOP OF THE FRAME, REMOVED BY `FrameLoader` ON ITS `load`.
  #
  # Behind it does not work, and the reason is worth keeping: an iframe that has not loaded is NOT
  # transparent — it paints its own white canvas — so a spinner underneath is covered from the first
  # frame and never seen. Swapping the frame out for a spinner does not work either, because
  # replacing the element restarts the load.
  #
  # So it overlays, and the hook hides it when the frame reports `load` — the only signal available,
  # since the document inside is another origin and cannot report for itself.
  attr :frame, :string, required: true
  attr :label, :string, default: nil

  defp frame_pending(assigns) do
    ~H"""
    <div
      id={"#{@frame}-pending"}
      phx-hook="FrameLoader"
      phx-update="ignore"
      data-frame={@frame}
      class="pointer-events-none absolute inset-0 z-10 flex flex-col items-center justify-center gap-3 bg-white"
    >
      <span class="size-6 animate-spin rounded-full border-2 border-[#e6e4de] border-t-[#5b57d6]"></span>
      <span class="text-[11.5px] font-semibold text-[#a8a5a0]">{@label || gettext("Loading…")}</span>
    </div>
    """
  end

  # THE SECOND OVERLAY, and it is not the first one twice. `frame_pending` covers the FIRST document
  # load and is taken down by the iframe's own `load`; this covers every LIVE swap after that —
  # opening a draft, restoring a version — where the frame never navigates, so no `load` ever fires
  # again. It is raised by a `pb:frame-busy` push from the editor and taken down by the canvas
  # reporting the revision it has painted.
  #
  # `hidden` rather than a class, because it is toggled by JavaScript and `[hidden]` is one rule the
  # browser already has. `phx-update="ignore"` so a patch on the way through does not re-show it.
  attr :frame, :string, required: true

  defp frame_busy(assigns) do
    ~H"""
    <div
      id={"#{@frame}-busy"}
      data-role="pb-frame-busy"
      phx-update="ignore"
      hidden
      class="pointer-events-none absolute inset-0 z-20 flex flex-col items-center justify-center gap-3 bg-white/92"
    >
      <span class="size-6 animate-spin rounded-full border-2 border-[#e6e4de] border-t-[#5b57d6]"></span>
      <span data-role="pb-busy-label" class="text-[11.5px] font-semibold text-[#3a382f]"></span>
      <span
        data-role="pb-busy-elapsed"
        class="font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#a8a5a0]"
      ></span>
    </div>
    """
  end

  # One device frame, scaled by `--pb-single-zoom` from `#pb-canvas-scroll`.
  defp single_frame(assigns) do
    ~H"""
    <div
      class="relative flex h-full min-h-0 flex-none self-stretch overflow-hidden rounded-[14px] border border-[#e6e4de] bg-white shadow-[0_2px_10px_rgba(20,18,26,.05)]"
      style={"width:#{frame_width(@device)};zoom:var(--pb-single-zoom)"}
    >
      <%!-- No `src` until the socket is connected. The static render has no registered session, and
            pointing the frame at one that is about to be replaced is what made it load twice. --%>
      <.frame_pending
        :if={@token}
        frame={"pb-frame-#{@device}"}
        label={gettext("Loading the canvas…")}
      />
      <.frame_busy :if={@token} frame={"pb-frame-#{@device}"} />
      <iframe
        :if={@token}
        id={"pb-frame-#{@device}"}
        title={gettext("Canvas")}
        src={"/admin/dashboard/runtime/builder-canvas/#{@token}"}
        class="relative block h-full w-full border-0"
      ></iframe>
      <.frame_loading :if={!@token} />
    </div>
    """
  end

  # The all-breakpoints view. The outer box is the SCALED width and the frame inside keeps its real
  # one, so a 1180px desktop at 30% occupies 354px and nothing overflows — which is why the prototype
  # needs no scrollbar per frame. Each carries its size, and the breakpoint currently being edited is
  # ringed and names the selected element, so the row doubles as a reminder of where an edit lands.
  # The scale is `--pb-frame-zoom` from `#pb-canvas-scroll`: each box is its width times it, and each
  # frame is zoomed by it.
  defp frames(assigns) do
    ~H"""
    <div
      id="pb-framerow"
      data-role="pb-framerow"
      phx-hook="PbDragScroll"
      data-axis="both"
      class={[
        "flex flex-none cursor-grab select-none items-start gap-[18px]",
        (@frame_row && "flex-row") || "flex-col"
      ]}
    >
      <div :for={{label, width} <- frame_widths()} class="flex-none">
        <div class="mb-2 flex items-center gap-2">
          <span class="text-[10.5px] font-bold uppercase tracking-[0.07em] text-[#17161a]">
            {translate(label)}
          </span>
          <span class="font-['Space_Grotesk'] text-[10.5px] font-medium text-[#6d6a63]">
            {width}px
          </span>
          <span
            :if={frame_active?(@breakpoint, label) && @selected_node}
            class="font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc]"
          >
            &lt;{node_label(@selected_node)}&gt;
          </span>
        </div>
        <div
          class={[
            "relative overflow-hidden rounded-[12px] border bg-white",
            (frame_active?(@breakpoint, label) && "border-[#8481de]") || "border-[#e6e4de]"
          ]}
          style={"width:calc(#{width}px * var(--pb-frame-zoom))"}
        >
          <%!-- A real device VIEWPORT, not a guessed box and not a measured one. Measuring the
                document's height cannot work here: this page's own root is `min-h-screen`, so its
                height is defined AS the viewport's — set the frame to what it reports and the two
                chase each other upward. A breakpoint preview is a screen of that width, so the frame
                is a screen of that width, shown at `zoom`. Nothing scrolls because nothing is cropped
                that was not cropped on the real device too. --%>
          <.frame_pending
            :if={@token}
            frame={"pb-frame-#{width}"}
            label={gettext("Loading the canvas…")}
          />
          <.frame_busy :if={@token} frame={"pb-frame-#{width}"} />
          <iframe
            :if={@token}
            id={"pb-frame-#{width}"}
            title={gettext("Canvas at %{width}px", width: width)}
            src={"/admin/dashboard/runtime/builder-canvas/#{@token}"}
            class="relative block border-0"
            style={"width:#{width}px;height:#{frame_viewport(width)}px;zoom:var(--pb-frame-zoom)"}
          ></iframe>
          <div
            :if={!@token}
            style={"width:#{width}px;height:#{frame_viewport(width)}px;zoom:var(--pb-frame-zoom)"}
          >
            <.frame_loading />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The viewport height each breakpoint stands for — a laptop, a tablet held upright, a phone.
  defp frame_viewport(1180), do: 820
  defp frame_viewport(900), do: 1024
  defp frame_viewport(560), do: 844
  defp frame_viewport(_width), do: 900

  # Which frame the Editing-at selector currently points at. `Desktop` is the base bucket.
  defp frame_active?(:base, "Desktop"), do: true
  defp frame_active?(:tablet, "Tablet"), do: true
  defp frame_active?(:mobile, "Mobile"), do: true
  defp frame_active?(_breakpoint, _label), do: false

  @doc "Whether this row's component renders its own content closed — a dialog, a drawer, a dropdown."
  @spec overlay?(map() | nil) :: boolean()
  def overlay?(entry) when is_map(entry), do: Map.get(entry, :concealed?, false) == true
  def overlay?(_entry), do: false

  @doc """
  The centred confirmation shown before reloading the canvas with unsaved work in the session.

  Reloading the frame does not throw an edit away — the canvas re-renders from the same editing
  session — but it does discard whatever is mid-flight in the browser: an inline text edit still
  focused, a drag in progress. Asking is cheap; guessing wrong is not.
  """
  def reload_modal(assigns) do
    ~H"""
    <div
      id="pb-reload-modal"
      class="fixed inset-0 z-[96] flex items-center justify-center bg-[#17161a]/40 p-6"
      phx-mounted={modal_in("#pb-reload-modal > section")}
      phx-remove={modal_out("#pb-reload-modal > section")}
      phx-window-keydown="close_reload"
      phx-key="escape"
    >
      <section
        phx-click-away="close_reload"
        class="w-[420px] max-w-[94vw] overflow-hidden rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_30px_80px_rgba(20,18,26,.3)]"
      >
        <div class="flex items-start gap-3 px-5 pb-3 pt-[18px]">
          <span class="grid size-9 flex-none place-items-center rounded-[11px] bg-[#fbf1df] text-[#8a5514]">
            <.icon name={:refresh} size={17} />
          </span>
          <div class="min-w-0">
            <h2 class="font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]">
              {gettext("Reload the canvas?")}
            </h2>
            <p class="mt-1.5 text-[11.5px] font-medium leading-[1.55] text-[#6d6a63]">
              {gettext(
                "This page has changes that are not in a draft or published yet. They stay in this editing session and will be drawn again — but anything you are typing on the canvas right now is lost when the frame reloads."
              )}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2 border-t border-[#f0efea] px-5 py-3.5">
          <span class="flex-1"></span>
          <button
            type="button"
            id="pb-reload-cancel"
            phx-click="close_reload"
            class="h-8 flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[11.5px] font-semibold text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            id="pb-reload-confirm"
            phx-click="confirm_reload"
            class="h-8 flex-none rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3.5 text-[11.5px] font-bold text-white"
          >
            {gettext("Reload")}
          </button>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  The question asked when someone leaves the editor in publish mode with changes.

  Every other mode saves as you work, so leaving is free and nothing asks. Publish mode deliberately
  writes nothing — that is what makes "refresh and the original comes back" true — which leaves one
  state where walking away and discarding are the same gesture.

  So the question is not "are you sure": it is the two things the work could become. Keeping it puts
  it in a draft under this sitting's name; publishing puts it in front of visitors. Both then leave.
  Throwing it away is still possible, but it is the quiet third option rather than the loud one — a
  discard that is easier to press than either save is a discard people hit by accident.
  """
  def leave_modal(assigns) do
    ~H"""
    <div
      id="pb-leave-modal"
      class="fixed inset-0 z-[97] flex items-center justify-center bg-[#17161a]/40 p-6"
      phx-mounted={modal_in("#pb-leave-modal > section")}
      phx-remove={modal_out("#pb-leave-modal > section")}
      phx-window-keydown="stay"
      phx-key="escape"
    >
      <section
        phx-click-away="stay"
        class="w-[452px] max-w-[94vw] overflow-hidden rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_30px_80px_rgba(20,18,26,.3)]"
      >
        <div class="flex items-start gap-3 px-5 pb-1 pt-[18px]">
          <span class="grid size-9 flex-none place-items-center rounded-[11px] bg-[#fbf1df] text-[#8a5514]">
            <.icon name={:external} size={17} />
          </span>
          <div class="min-w-0">
            <h2 class="font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]">
              {gettext("This isn’t on the page yet")}
            </h2>
            <p class="mt-1.5 text-[11.5px] font-medium leading-[1.55] text-[#6d6a63]">
              {gettext(
                "The chip is on Publish, so this is recorded in the page’s history but is not on the live page and not in a draft. What should happen to it?"
              )}
            </p>
          </div>
        </div>

        <div class="flex flex-col gap-2 px-5 py-4">

          <button
            type="button"
            id="pb-leave-publish"
            phx-click="publish_and_leave"
            class="flex w-full items-start gap-3 rounded-[11px] border border-transparent bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] p-3 text-left shadow-[0_4px_14px_rgba(79,75,204,.28)] hover:brightness-[1.06]"
          >
            <span class="grid size-7 flex-none place-items-center rounded-[9px] bg-white/20 text-white">
              <.icon name={:publish_arrow} size={14} />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block text-[12.5px] font-bold text-white">{gettext("Publish it now")}</span>
              <span class="mt-0.5 block text-[11px] font-medium leading-[1.5] text-white/80">
                {gettext("Goes live on the site straight away, and the page is rebuilt.")}
              </span>
            </span>
          </button>
        </div>

        <div class="flex items-center gap-2 border-t border-[#f0efea] px-5 py-3">
          <button
            type="button"
            id="pb-leave-go"
            phx-click="leave_anyway"
            class="h-8 flex-none rounded-[9px] px-2.5 text-[11.5px] font-semibold text-[#a3554f] hover:bg-[#fdf2f1]"
          >
            {gettext("Leave — it stays in history")}
          </button>
          <span class="flex-1"></span>
          <button
            type="button"
            id="pb-leave-stay"
            phx-click="stay"
            class="h-8 flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[11.5px] font-semibold text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            {gettext("Stay here")}
          </button>
        </div>
      </section>
    </div>
    """
  end

  defp devices,
    do: [
      {:frames, gettext("All breakpoints"), gettext("side by side")},
      {:desktop, gettext("Desktop"), "100%"},
      {:tablet, gettext("Tablet"), "834px"},
      {:mobile, gettext("Mobile"), "390px"}
    ]

  defp frame_widths,
    do: [
      {gettext_noop("Desktop"), 1180},
      {gettext_noop("Tablet"), 900},
      {gettext_noop("Mobile"), 560}
    ]

  defp device_label(:tablet), do: gettext("Tablet · 834px")
  defp device_label(:mobile), do: gettext("Mobile · 390px")
  defp device_label(_device), do: gettext("Desktop")

  defp frame_width(:tablet), do: "834px"
  defp frame_width(:mobile), do: "390px"
  defp frame_width(_device), do: "100%"

  # Published first: the menu is a choice about visibility, and the consequential option leads.
  defp stages do
    [
      {:published, gettext("Published"), gettext("Visitors can see this page.")},
      {:draft, gettext("Draft"), gettext("Only your team can see it. Nothing goes live.")}
    ]
  end

  # You, then up to two others, then a "+N" for the rest — the prototype's stack, with real people in
  # it. The tones alternate the way its three chips do.
  defp avatars(user, editors) do
    mine = [{Presence.initials(user), "bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-white"}]

    others =
      editors
      |> Enum.take(2)
      |> Enum.map(&{&1.initials, "bg-[#177a53] text-white"})

    mine ++ others ++ overflow(length(editors) - 2)
  end

  defp overflow(rest) when rest > 0,
    do: [{"+#{rest}", "bg-[#f2f1ec] text-[#6d6a63]"}]

  defp overflow(_rest), do: []

  defp avatars_title([]), do: gettext("Only you are editing this page")

  defp avatars_title(editors),
    do:
      ngettext(
        "You and %{count} other editing this page",
        "You and %{count} others editing this page",
        length(editors)
      )

  # Selecting a stage in the menu does not apply it, so the button says which it is: while the two
  # agree it names the stage, and while they differ it names the action it will take.
  defp stage_button_label(stage, stage), do: stage_label(stage)
  defp stage_button_label(:published, _applied), do: gettext("Publish")
  defp stage_button_label(_draft, _applied), do: gettext("Save draft")

  defp stage_button_title(stage, stage), do: stage_title(stage)

  defp stage_button_title(:published, _applied),
    do: gettext("Publish — this will make the page visible to visitors")

  defp stage_button_title(_draft, _applied),
    do: gettext("Save draft — kept aside; the live page is untouched until you publish")

  defp stage_icon(stage, stage), do: (stage == :published && :check) || :draft
  defp stage_icon(:published, _applied), do: :rocket
  defp stage_icon(_draft, _applied), do: :draft

  defp stage_label(:published), do: gettext("Published")
  defp stage_label(_draft), do: gettext("Draft")

  defp stage_title(:published), do: gettext("Published — visitors can see this page")
  defp stage_title(_draft), do: gettext("Draft — kept aside, not in front of visitors")

  defp mobile_tabs(assigns) do
    [
      {"canvas", gettext("Canvas")},
      {"dir", String.upcase(assigns.dir)}
    ]
  end

  # "Page builder" over a page, "Component builder" over a component. The noun comes from the same
  # table the back link and the flash messages read, so there is one place to change a name.
  defp builder_label(%{section: section}),
    do:
      gettext("%{section} builder", section: translate(Section.label(Section.normalize(section))))

  defp builder_label(_assigns), do: gettext("Builder")

  # A SITE-LESS ROW IS EVERY SITE'S. That is what `site_id: nil` means for a layout and a component,
  # and it is the distinction worth a badge: the same editor, the same address, thirty times the
  # blast radius. A page always has a site, so its badge simply names it.
  defp global_document?(%{record: %{site_id: nil}}), do: true
  defp global_document?(_assigns), do: false

  defp scope_label(%{record: %{site_id: nil}}), do: gettext("Global")
  defp scope_label(%{record: %{site: %{name: name}}}) when is_binary(name), do: name
  defp scope_label(%{record: %{site_id: id}}) when is_binary(id), do: gettext("This site")
  defp scope_label(_no_record), do: nil

  defp scope_title(%{record: %{site_id: nil}}),
    do: gettext("Shared with every site — changes here reach all of them")

  defp scope_title(assigns) do
    case scope_label(assigns) do
      nil -> nil
      name -> gettext("Belongs to %{name}", name: name)
    end
  end

  defp document_label(%{record: %{name: name}, section: section}) when is_binary(name),
    do: name <> "." <> section_extension(section)

  defp document_label(%{section: section}),
    do: gettext("untitled.%{extension}", extension: section_extension(section))

  defp section_extension(_section), do: "heex"

  # PUBLISHED STAGE IS NOT SILENT. Nothing is written to the page there, deliberately — but the work
  # IS recorded, and showing nothing at all is what made that stage read as "the editor stopped
  # caring". Same slot as draft's "saved", one different word, so the two stages read as siblings.
  defp status_label(%{stage: :published}), do: gettext("recorded, not saved to the page")
  defp status_label(%{dirty?: true}), do: gettext("unsaved changes")
  defp status_label(%{saved_at: nil}), do: gettext("not saved yet")
  defp status_label(_assigns), do: gettext("saved")

  @doc """
  The short name a node goes by in the layers tree, the crumb bar and a review byline.

  Public because a review note captures the label of the element it was written about at the time it
  was posted — see `MishkaCmsCore.Runtime.PageBuilder.Comment`.
  """
  @spec node_label(Node.t()) :: String.t()
  # A runtime component goes by its OWN name — `chelekom-alert`, not the `.component` wrapper tag the
  # template happens to use to call it. `.component` told the reader nothing and made every component
  # on the page look identical in the tree.
  # THE WORDING LIVES ON THE NODE. A review note captures it and `Review.locate/2` compares against
  # it, so the panel cannot be the only place that knows how an element is named.
  defdelegate node_label(node), to: Node, as: :label

  defp translate(text) when is_binary(text), do: Gettext.gettext(MishkaCmsCore.Gettext, text)
  defp translate(other), do: other

  @doc """
  The icon this panel draws for a descriptor's plain-string `icon`, so a plugin can name one without
  depending on this module's atoms. A name the set does not hold falls back to the chevron.
  """
  @spec icon_name(String.t() | nil) :: atom()
  def icon_name(name), do: Map.get(@icon_names, name, :chevron)

end
