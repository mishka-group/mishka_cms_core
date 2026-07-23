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

  alias MishkaCmsCore.Builder.Descriptor
  alias Phoenix.LiveView.JS
  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
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

  # The sizes each resizable region may be dragged between, in pixels — the prototype's measurements,
  # written once.
  # The left floor is 336 rather than the original 230 because the tab strip carries THREE tabs now —
  # Components, Blocks, Inspector — and 336 is the measured width at which the longest of the three
  # labels stops ellipsising. Below it the panel still works: the glyphs stay whole and the labels
  # shorten, which is what the tabs' `title` is for.
  @resize_bounds %{left: {336, 460}, right: {220, 480}, drawer: {120, 620}}

  @doc """
  How far a panel may be dragged — `{min, max}` in pixels.

  One source, two readers. The grip carries these into the DOM as `data-min`/`data-max` so the drag
  can stop at the right place without asking the server, and `BuilderLive` clamps the value it is
  finally told with the same pair — a bound only the browser enforces is not a bound, and a bound
  only the server enforces makes the panel overshoot and snap back.
  """
  @spec resize_bounds(:left | :right | :drawer) :: {pos_integer(), pos_integer()}
  def resize_bounds(panel), do: Map.fetch!(@resize_bounds, panel)

  defp grip_min(panel), do: panel |> resize_bounds() |> elem(0)
  defp grip_max(panel), do: panel |> resize_bounds() |> elem(1)

  # The custom property a drag writes to, live on `<html>` — which is outside the LiveView and so is
  # never patched. The server renders the assign as the FALLBACK, so a fresh page, a reconnect or a
  # reader who has never dragged anything all get the stored size, and a drag simply out-specifies it
  # until the gesture ends and the server is told.
  #
  # This indirection is why the drag survives a concurrent render. These panels are called as
  # `<Panels.left_panel {assigns} />`, and a component handed a bare `assigns` map has change
  # tracking DISABLED (`Phoenix.LiveView.Engine` emits `__changed__: nil` for it), so every render of
  # the editor re-emits this element's `style` and morphdom copies it onto the live node. Written as
  # a plain `width:272px` that would stamp the stale server width over the width under the reader's
  # cursor — an autosave tick or another editor's keystroke mid-drag, and the panel jumps.
  defp grip_var(:left), do: "--pb-left-w"

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

  @doc "The core's ⌘K commands — the seed of `builder:commands`."
  def core_commands do
    [
      descriptor("save", :command, gettext_noop("Save"), 10,
        shortcut: "⌘S",
        icon: "check",
        description: gettext_noop("Write the draft")
      ),
      descriptor("publish", :command, gettext_noop("Publish"), 20,
        icon: "rocket",
        description: gettext_noop("Make this version live")
      ),
      descriptor("undo", :command, gettext_noop("Undo"), 30,
        shortcut: "⌘Z",
        icon: "undo",
        description: gettext_noop("Step back one change")
      ),
      descriptor("redo", :command, gettext_noop("Redo"), 40,
        shortcut: "⇧⌘Z",
        icon: "redo",
        description: gettext_noop("Step forward again")
      ),
      descriptor("toggle_preview", :command, gettext_noop("Toggle preview"), 80,
        shortcut: "⌘P",
        icon: "eye",
        description: gettext_noop("Turn the editor chrome off")
      )
    ]
  end

  defp descriptor(key, kind, label, priority, opts) do
    {:ok, built} =
      Descriptor.builder(%{
        key: key,
        kind: kind,
        label: label,
        priority: priority,
        icon: opts[:icon],
        shortcut: opts[:shortcut],
        description: opts[:description]
      })

    built
  end

  # DECLARED, NEVER SPLATTED — see `left_panel/1`. This one is 562 lines and is drawn on every single
  # event, so a splat here re-evaluated the whole bar to discover the same chip, the same crumbs and
  # the same buttons. `record` and `saved_at` are here for `document_label/1` and `status_label/1`,
  # which read the assigns map directly.
  attr(:field, :string, required: true)
  attr(:event, :string, required: true)
  attr(:params, :map, default: %{})

  @doc """
  The ✖ inside a text field, shown only while there is something to clear.

  ## Why there is no hook

  WHETHER IT IS SHOWN IS A CSS QUESTION. `:placeholder-shown` is true exactly while an input is
  empty — that is what the pseudo-class means — so `peer-placeholder-shown:hidden` on a button that
  follows the input answers it in the browser, on the keystroke, with no listener, no state and no
  round trip. A hook would have to bind `input`, unbind it on destroy, and re-run itself on every
  LiveView patch to stay right; this cannot fall out of step because there is nothing to fall out of
  step with.

  The one requirement it puts on the field is a non-empty `placeholder`, which every search box in
  the editor already has because an empty one is unlabelled.

  ## Why the click still reaches the server

  What these fields hold is not private to the browser: the palette's list, the block sheet's list,
  the registry's list and the find sheet's hit count are all rendered from the query the SERVER
  holds. Clearing the input alone would blank the box and leave the results filtered by a word no
  longer written anywhere — the worst of the two states. So the button pushes the same event the
  field's own typing pushes, with an empty value, and the field is blanked by the re-render that
  answers it.

  ## Why the caret is not put back

  The obvious finish is `JS.focus/1` on the field, since the reason to clear a search box is to type
  a different word. It was written that way and it is wrong, which only driving it showed:
  **LiveView never overwrites the value of a FOCUSED input.** `mergeFocusedInput` copies every
  attribute except `value`, so focusing the field before the server's answer arrives left the box
  still reading "drop" over a list that had gone back to all 135 — the exact half-cleared state the
  paragraph above exists to avoid, produced by trying to be helpful.

  `JS.set_attribute` cannot stand in for it either: once a person has typed, the input's value
  property is dirty and no longer follows its attribute. Measured, not assumed.

  So the field clears and the caret does not return. Clicking into a box you just cleared is one
  click; a box that lies about what is filtering the list is a bug.
  """
  def clear_field(assigns) do
    ~H"""
    <button
      type="button"
      data-role="pb-clear"
      data-for={@field}
      tabindex="-1"
      aria-label={gettext("Clear this field")}
      title={gettext("Clear")}
      phx-click={JS.push(@event, value: @params)}
      class="absolute right-[8px] top-1/2 grid size-[18px] -translate-y-1/2 place-items-center rounded-full text-[#a8a5a0] hover:bg-[#f0efea] hover:text-[#3a382f] peer-placeholder-shown:hidden"
    >
      <.icon name={:close} size={11} />
    </button>
    """
  end

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
            event="toggle_command"
            value={%{}}
            icon={:search}
            accent
            label={gettext("Command palette")}
            badge="⌘K"
          />
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

  @doc """
  The left panel — Components and Inspector — with its collapse rail and 6px resize grip.

  Collapsing leaves a 34px rail carrying a chevron and the panel's name set vertically, so the panel
  is one click from coming back. Preview mode does not touch either: it cleans the CANVAS, and the
  editor around it stays where the author left it.
  """
  # DECLARED, NEVER SPLATTED. `Phoenix.LiveView.Engine` switches change tracking OFF for a component
  # that receives a dynamic splat — it cannot know which assigns the child reads, so it assumes all
  # of them — and it propagates that to every nested child. This panel holds the palette, and the
  # palette's own explicit-attr call below has been inert the whole time because of it: ~180 cards
  # were re-evaluated on every event that touched the chrome, including every canvas selection.
  #
  # The list is the union of what this function reads and what `.inspector` reads, because the two
  # share this component's assigns. A missing one is a render-time `KeyError`, which is loud.
  attr(:editor, :any, required: true)
  attr(:palette, :any, required: true)
  attr(:picked, :string, default: nil)
  attr(:component_presets, :map, default: %{})
  attr(:palette_query, :string, default: "")
  attr(:palette_cat, :string, default: "all")
  attr(:block_query, :string, default: "")
  attr(:block_cat, :string, default: "all")
  attr(:block_library, :list, default: [])
  attr(:element_library, :list, default: [])
  attr(:left_hidden, :boolean, default: false)
  attr(:left_tab, :atom, default: :components)
  attr(:left_w, :integer, required: true)
  attr(:mob_panel, :atom, default: :canvas)
  def left_panel(assigns) do
    ~H"""
    <%!-- One wrapper that is ALWAYS in the DOM. The rail and the panel swap inside it, so the number
          of nodes before the canvas never changes — when they did, every sibling after them shifted
          position, LiveView rebuilt the centre column, and the canvas iframe was re-created and
          reloaded on every collapse. `display:contents` keeps the flex layout exactly as it was. --%>
    <div class="contents">
      <button
        :if={@left_hidden}
        type="button"
        phx-click="toggle_left"
        id="pb-left-rail"
        title={gettext("Show components panel")}
        class="flex w-[34px] flex-none flex-col items-center gap-3 border-r border-[#e6e4de] bg-white py-3 hover:bg-[#faf9f6] max-[900px]:hidden"
      >
        <.icon name={:chevron} size={15} class="text-[#4f4bcc]" />
        <span class="text-[10px] font-bold uppercase tracking-[0.13em] text-[#6d6a63] [writing-mode:vertical-rl]">
          {gettext("Components")}
        </span>
      </button>

      <aside
        :if={!@left_hidden}
        data-role="pb-left"
        id="pb-left"
        style={"width:var(--pb-left-w, #{@left_w}px)"}
        class={[
          "flex flex-none flex-col border-r border-[#e6e4de] bg-white",
          mobile_visibility(@mob_panel, [:components, :inspector])
        ]}
      >
        <div class="flex flex-none items-center gap-1 px-3.5 pt-3">
          <div
            data-role="pb-lefttabs"
            class="flex min-w-0 flex-1 gap-0.5 rounded-[10px] bg-[#f2f1ec] p-[3px]"
          >
            <%!-- The label carries `truncate`, not the button. `truncate` on a flex CONTAINER does
                  nothing: the bare text is an anonymous flex item that refuses to shrink past its
                  own width, so the row overflowed and `justify-center` split the overflow evenly —
                  clipping the FIRST tab's glyph against the panel edge. Shrinking the label instead
                  keeps every glyph whole at any width the drag handle can reach. --%>
            <button
              :for={
                {key, label, icon} <- [
                  {:components, gettext("Components"), :grid},
                  {:blocks, gettext("Blocks"), :card},
                ]
              }
              type="button"
              id={"pb-lefttab-#{key}"}
              phx-click="set_left_tab"
              phx-value-tab={key}
              title={label}
              class={[
                "flex h-[30px] min-w-0 flex-1 items-center justify-center gap-1 overflow-hidden rounded-[8px] px-1 text-[10.5px] font-bold",
                (@left_tab == key && "bg-white text-[#4f4bcc] shadow-[0_1px_3px_rgba(30,28,24,.12)]") ||
                  "text-[#6d6a63]"
              ]}
            >
              <.icon name={icon} size={12} class="flex-none" />
              <span class="min-w-0 truncate">{label}</span>
            </button>
          </div>
          <button
            type="button"
            phx-click="toggle_left"
            title={gettext("Collapse panel")}
            class="grid h-[30px] w-5 flex-none place-items-center text-[#a8a5a0] hover:text-[#4f4bcc]"
          >
            <.icon name={:chevron} size={13} class="rotate-180" />
          </button>
        </div>

        <%!-- Explicit assigns, not `{assigns}`: a function component handed the whole map re-renders
            whenever ANY assign changes, and this one draws 167 cards. Selecting an element used to
            redraw every one of them.

            HIDDEN RATHER THAN REMOVED, and only this one. A `:if` takes the cards out of the DOM, so
            coming back to the tab has to send all 177 again — measured at 197 KB and 245 ms every
            time. Components is the tab the editor opens on, so the markup is in the first render
            either way: keeping it costs nothing at open and makes every later switch free. The other
            two stay conditional, because they are NOT in the first render and mounting them for a
            tab nobody opened would be the same waste in the other direction. --%>
        <.palette
          hidden={@left_tab != :components}
          components={@editor.components}
          site_name={@editor.site_name}
          site_id={@editor.site_id}
          component_presets={@component_presets}
          picked={@picked}
          palette_query={@palette_query}
          palette_cat={@palette_cat}
          palette={@palette}
        />
        <.blocks
          :if={@left_tab == :blocks}
          picked_block={@editor.picked}
          block_cat={@block_cat}
          block_query={@block_query}
          block_library={@block_library}
          element_library={@element_library}
        />
      </aside>

      <div
        :if={!@left_hidden}
        data-role="pb-grip"
        id="pb-grip-left"
        phx-hook="PbGrip"
        data-panel="left"
        data-min={grip_min(:left)}
        data-max={grip_max(:left)}
        data-var={grip_var(:left)}
        class="w-1.5 flex-none cursor-col-resize bg-transparent hover:bg-[#e4e2f7] max-[900px]:hidden"
      />
    </div>
    """
  end

  attr(:components, :list, required: true)
  attr(:site_name, :string, default: nil)
  attr(:site_id, :string, default: nil)
  attr(:component_presets, :map, default: %{})
  attr(:picked, :string, default: nil)
  attr(:palette_query, :string, required: true)
  attr(:palette_cat, :string, required: true)
  attr(:palette, :any, default: nil, doc: "the AsyncResult carrying the component list")

  attr(:hidden, :boolean,
    default: false,
    doc: "kept in the DOM while another tab is showing, so coming back costs nothing"
  )

  defp palette(assigns) do
    assigns =
      assigns
      |> assign(:entries, filter_palette(assigns))
      |> assign(:kit_prefixes, kit_prefixes(assigns.components))

    ~H"""
    <div
      id="pb-palette"
      phx-hook="PbPalettePrefs"
      data-scope={@site_name || "global"}
      data-showing={to_string(!@hidden)}
      class={["min-h-0 flex-1 flex-col", (@hidden && "hidden") || "flex"]}
    >
      <div class="flex-none px-3.5 pb-2.5 pt-3.5">
        <div class="mb-2.5 flex items-center justify-between">
          <span class="text-[10.5px] font-bold uppercase tracking-[0.12em] text-[#6d6a63]">
            {gettext("Components")}
          </span>
          <span
            data-role="pb-count"
            class="rounded-full bg-[#f4f3ef] px-2 py-0.5 font-['Space_Grotesk'] text-[10px] font-bold text-[#6d6a63]"
          >
            {length(@entries)}
          </span>
        </div>

        <div class="relative">
          <.icon
            name={:search}
            size={14}
            class="pointer-events-none absolute left-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
          />
          <input
            id="pb-palette-search"
            type="text"
            value={@palette_query}
            phx-keyup="palette_query"
            phx-debounce="120"
            name="value"
            placeholder={gettext("Search components…")}
            class="peer h-[38px] w-full rounded-[10px] border border-[#ecebe6] bg-[#faf9f6] pl-[34px] pr-[30px] text-[12px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,.1)]"
          />
          <.clear_field field="pb-palette-search" event="palette_query" params={%{"value" => ""}} />
        </div>

        <%!-- Drag-to-scroll, and no scrollbar: the row is a strip of chips, and a scrollbar under it
              both eats a row of pixels and reads as a defect. `PbDragScroll` gives it the grab
              cursor and pointer panning the prototype has. --%>
        <div
          id="pb-palette-cats"
          data-role="pb-cats"
          phx-hook="PbDragScroll"
          class="mt-2.5 flex cursor-grab gap-[5px] overflow-x-auto [scrollbar-width:none] select-none [&::-webkit-scrollbar]:hidden"
        >
          <.cat_chip cat="all" active={@palette_cat} />
          <%!-- RIGHT AFTER "ALL", where the eye already is. These two are the same kind of thing as
                the category chips — a way to cut 177 tiles down — but they are the only ones the
                server knows nothing about: a star says what one author keeps reaching for, which is
                not the site's data, so it stays in the browser and costs no round trip. They narrow
                whatever the category chips left, so "★ + forms" is a real question you can ask. --%>
          <button
            :for={
              {mode, id, glyph, label, title} <- [
                {"fav", "pb-palette-fav", :star, gettext("Starred"),
                 gettext("Show only starred components")},
                {"recent", "pb-palette-recent", :clock, gettext("Recent"),
                 gettext("Show only recent components")}
              ]
            }
            type="button"
            id={id}
            data-pb-prefchip={mode}
            title={title}
            class={[
              "group/chip h-7 flex-none rounded-[8px] border px-[9px] text-[11px] font-semibold",
              "inline-flex items-center gap-1.5 border-[#ecebe6] bg-white text-[#6d6a63] hover:border-[#dcdbf5]",
              "data-[on=true]:border-[#dcdbf5] data-[on=true]:bg-[#f2f1fc] data-[on=true]:text-[#4f4bcc]"
            ]}
          >
            <.icon name={glyph} size={12} class="group-data-[on=true]/chip:text-[#e0a52a]" />{label}
          </button>
          <.cat_chip :for={cat <- component_categories(@components)} cat={cat} active={@palette_cat} />
        </div>

        <%!-- The scope legend: without it the G/T badge on each card is an unexplained letter. --%>
        <div class="mt-2.5 flex items-center gap-3">
          <span class="inline-flex items-center gap-1.5 text-[9.5px] font-semibold text-[#6d6a63]">
            <span class="grid size-[15px] flex-none place-items-center rounded-[4px] bg-[#eef1fc] font-['Space_Grotesk'] text-[10px] font-bold leading-none text-[#4f4bcc]">
              {gettext("G")}
            </span>{gettext(
              "Global — all sites"
            )}
          </span>
          <span class="inline-flex items-center gap-1.5 text-[9.5px] font-semibold text-[#6d6a63]">
            <span class="grid size-[15px] flex-none place-items-center rounded-[4px] bg-[#fbf1df] font-['Space_Grotesk'] text-[10px] font-bold leading-none text-[#8a5514]">
              {gettext("T")}
            </span>{gettext(
              "Tenant only"
            )}
          </span>
        </div>

        <div :if={@picked} class="mt-2 text-[10px] font-bold text-[#4f4bcc]">
          {gettext("Placing %{label} — click the canvas or a layer", label: picked_label(@picked))}
        </div>
      </div>

      <div
        id="pb-card-preview"
        phx-hook="PbPaletteHover"
        phx-update="ignore"
        hidden
        class="pointer-events-none fixed z-[70] w-[380px] overflow-hidden rounded-[14px] border border-[#e6e5df] bg-white shadow-[0_16px_40px_-8px_rgba(30,28,24,.22),0_2px_6px_rgba(30,28,24,.06)]"
      >
        <div class="flex items-center gap-2 border-b border-[#f0efea] px-3 py-2.5">
          <span
            data-role="pb-card-preview-global"
            class="grid size-[15px] flex-none place-items-center rounded-[4px] bg-[#eef1fc] font-['Space_Grotesk'] text-[10px] font-bold leading-none text-[#4f4bcc]"
          >
            {gettext("G")}
          </span>
          <span
            data-role="pb-card-preview-tenant"
            hidden
            class="grid size-[15px] flex-none place-items-center rounded-[4px] bg-[#fbf1df] font-['Space_Grotesk'] text-[10px] font-bold leading-none text-[#8a5514]"
          >
            {gettext("T")}
          </span>
          <span
            data-role="pb-card-preview-head"
            class="min-w-0 flex-1 truncate text-[11.5px] font-semibold leading-none text-[#3a382f]"
          ></span>
          <span
            data-role="pb-card-preview-name"
            class="max-w-[45%] flex-none truncate font-['Space_Grotesk'] text-[9.5px] font-semibold leading-none text-[#a8a49b]"
          ></span>
        </div>
        <div
          data-role="pb-card-preview-body"
          class="relative h-[150px] bg-[#fcfcfb] transition-[height] duration-150"
        >
          <div class="pointer-events-none absolute inset-0 z-[1] ring-1 ring-inset ring-[#f0efea]">
          </div>
          <div
            data-role="pb-card-preview-note"
            class="absolute inset-0 grid place-items-center px-5 text-center text-[11px] font-medium leading-[1.5] text-[#8b877e]"
          >
          </div>
          <iframe
            data-role="pb-card-preview-frame"
            title={gettext("What this component looks like")}
            sandbox="allow-same-origin"
            scrolling="no"
            class="pointer-events-none absolute left-0 top-0 origin-top-left border-0 opacity-0 transition-opacity duration-150"
          ></iframe>
        </div>
        <div class="flex items-center gap-1.5 border-t border-[#f0efea] bg-[#fbfbf9] px-3 py-[7px] text-[9.5px] font-semibold text-[#a8a49b]">
          {gettext("Click to place, or drag onto the canvas")}
        </div>
      </div>

      <div
        data-role="pb-comps"
        class="min-h-0 flex-1 overflow-y-auto px-3.5 pb-[18px] pt-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        <section :for={{group, group_entries} <- grouped_entries(@entries)} class="mb-4">
          <div class="mb-2.5 flex items-center gap-2">
            <span
              class="size-[5px] flex-none rounded-full"
              style={"background:#{category_dot(group)}"}
            />
            <span class="text-[10px] font-bold uppercase tracking-[0.11em] text-[#6d6a63]">
              {String.upcase(category_name(group))}
            </span>
            <span class="h-px flex-1 bg-[#f0efea]"></span>
            <span class="font-['Space_Grotesk'] text-[9.5px] font-semibold text-[#6d6a63]">
              {length(group_entries)}
            </span>
          </div>

          <div class="grid grid-cols-2 content-start gap-2">
            <span
              :for={entry <- group_entries}
              data-role="pb-compcell"
              data-name={entry.name}
              data-label={short_label(entry, @kit_prefixes)}
              data-scope={(entry.global? && "global") || "tenant"}
              class="group relative block"
            >
              <button
                type="button"
                id={"pb-comp-#{entry.name}"}
                phx-hook="PbPaletteItem"
                draggable="true"
                data-template={component_template(entry, @site_name, @component_presets, @components)}
                phx-click="pick"
                phx-value-name={entry.name}
                aria-label={
                  (entry.global? &&
                     gettext("Global · %{name} — click to place, or drag onto the canvas",
                       name: entry.name
                     )) ||
                    gettext("Tenant · %{name} — click to place, or drag onto the canvas",
                      name: entry.name
                    )
                }
                class={[
                  "relative flex h-[86px] w-full cursor-grab flex-col items-center gap-2 rounded-[12px] border px-2 pb-[11px] pt-[13px]",
                  "shadow-[0_1px_2px_rgba(30,28,24,.04)] hover:border-[#dcdbf5] hover:shadow-[0_4px_12px_rgba(30,28,24,.07)]",
                  (@picked == entry.name && "border-[#4f4bcc] bg-[#f2f1fc]") ||
                    ((entry.global? && "border-[#ecebe6] bg-white") || "border-[#f0e6cd] bg-white")
                ]}
              >
                <span
                  title={
                    (entry.global? && gettext("Global component — all sites")) ||
                      gettext("Tenant component — this site only")
                  }
                  class={[
                    "pointer-events-none absolute right-1.5 top-1.5 grid size-[15px] place-items-center rounded-[4px]",
                    "font-['Space_Grotesk'] text-[10px] font-bold leading-none",
                    (entry.global? && "bg-[#eef1fc] text-[#4f4bcc]") || "bg-[#fbf1df] text-[#8a5514]"
                  ]}
                >
                  {(entry.global? && gettext("G")) || gettext("T")}
                </span>
                  <span
                    class="grid size-[30px] place-items-center rounded-[9px]"
                    style={"background:#{category_tint(entry.type)};color:#{category_dot(entry.type)}"}
                  >
                    <.icon name={entry_icon(entry)} size={16} />
                  </span>
                <span class="line-clamp-2 w-full text-center text-[10.5px] font-semibold leading-[1.3] text-[#3a382f] [word-break:break-word]">
                  {short_label(entry, @kit_prefixes)}
                </span>
              </button>
              <%!-- NO `phx-click`. Starring is the browser's business from end to end — see
                    `assets/js/pb_prefs.js` — so this button carries no event and the tile behind it
                    is never re-rendered for it. It stays out of the way until the pointer is on the
                    card, and then stays put once it is on. --%>
              <button
                type="button"
                data-role="pb-fav"
                title={gettext("Keep this one at hand")}
                aria-label={gettext("Star %{name}", name: entry.name)}
                class={[
                  "absolute bottom-[3px] right-[3px] grid size-[19px] place-items-center rounded-[6px]",
                  "text-[#c8c5bd] opacity-0 hover:bg-[#f6f5f2] hover:text-[#e0a52a]",
                  "group-hover:opacity-100 focus-visible:opacity-100",
                  "data-[on=true]:text-[#e0a52a] data-[on=true]:opacity-100"
                ]}
              >
                <.icon name={:star} size={12} />
              </button>
            </span>
          </div>
        </section>
        <%!-- LiveView's own async states rather than a hand-rolled flag: "no components" and "not
              here yet" are different answers and only one of them is bad news. The skeleton keeps
              the column the height the list will be, so nothing jumps when it lands. --%>
        <.async_result :if={@palette} assign={@palette}>
          <:loading>
            <div data-role="pb-palette-skeleton" class="px-1">
              <div :for={group <- 1..2} class="mb-4">
                <div class="mb-[9px] h-[9px] w-[64px] animate-pulse rounded-[3px] bg-[#ecebe6]"></div>
                <div class="grid grid-cols-2 gap-[9px]">
                  <div
                    :for={tile <- 1..4}
                    id={"pb-palette-skel-#{group}-#{tile}"}
                    class="h-[74px] animate-pulse rounded-[13px] border border-[#f0efea] bg-[#faf9f6]"
                  >
                  </div>
                </div>
              </div>
            </div>
          </:loading>

          <%!-- A failed read is not an empty site, and the difference has to be visible: an empty
                rail reads as "nothing is installed" and leaves the author with nowhere to go. Almost
                every failure here is a dropped connection under load, so the remedy is to ask
                again — and asking again in place keeps the document, the history and the selection,
                which a page reload would not. --%>
          <:failed :let={_reason}>
            <div class="px-2.5 py-10 text-center">
              <p class="text-[12px] font-medium text-[#c0473d]">
                {gettext("The component list could not be loaded.")}
              </p>
              <button
                type="button"
                id="pb-palette-retry"
                phx-click="retry_palette"
                class="mt-3 inline-flex h-[28px] items-center gap-1.5 rounded-[8px] border border-[#ecebe6] bg-white px-3 text-[11px] font-bold text-[#3a382f] hover:border-[#c3c1f0] hover:text-[#4f4bcc]"
              >
                <.icon name={:undo} size={12} /> {gettext("Try again")}
              </button>
            </div>
          </:failed>

          <p
            :if={@entries == []}
            class="px-2.5 py-10 text-center text-[12px] font-medium text-[#6d6a63]"
          >
            {gettext("No components match.")}
          </p>

          <%!-- The server cannot write these: it does not know what is starred. Rendered hidden and
                revealed by the hook, so an empty ★ row reads as "you have not starred anything"
                rather than as a palette that failed to load. --%>
          <p
            :for={
              {id, copy} <- [
                {"pb-palette-empty-fav",
                 gettext("Nothing starred yet — press ★ on a card to keep it here.")},
                {"pb-palette-empty-recent",
                 gettext("Nothing placed yet. What you use will collect here.")}
              ]
            }
            id={id}
            hidden
            class="px-2.5 py-10 text-center text-[12px] font-medium text-[#6d6a63]"
          >
            {copy}
          </p>
        </.async_result>
      </div>
    </div>
    """
  end

  attr(:picked_block, :any, default: nil)
  attr(:block_cat, :string, default: "all")
  attr(:block_query, :string, default: "")
  attr(:block_library, :list, required: true)
  attr(:element_library, :list, required: true)

  @doc """
  Whole sections, one click each.

  The palette lists components and the Studio's Presets tab offers whole-page themes nothing on disk
  supplies. Between them there was nothing, so a landing page meant placing a grid, a heading, a
  paragraph and a button and repeating it for every band. Same click-to-place flow the palette uses,
  so there is nothing new to learn — see `MishkaCmsCore.Runtime.PageBuilder.Blocks`.
  """
  def blocks(assigns) do
    assigns =
      assigns
      # FILTERED AFTER THE MERGE, not before it. The two libraries arrive already merged with
      # whatever extensions contributed — collected once at mount rather than here, because this is a
      # render function and a plugin's code has no business running on every keystroke.
      |> assign(
        :items,
        Blocks.filter(assigns.block_library, assigns.block_cat, assigns.block_query)
      )
      |> assign(
        :elements,
        elements_for(assigns.element_library, assigns.block_cat, assigns.block_query)
      )

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div class="border-b border-[#f0efea] px-3 py-2.5">
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] font-bold uppercase tracking-[0.09em] text-[#6d6a63]">{gettext(
            "Blocks"
          )}</span>
          <span class="flex-1"></span>
          <span class="text-[10px] font-semibold text-[#a8a5a0]">
            {length(@elements) + length(@items)}
          </span>
        </div>

        <form
          id="pb-block-search-form"
          phx-change="block_query"
          phx-submit="block_query"
          class="relative mt-2"
        >
          <input
            type="text"
            name="value"
            id="pb-block-search"
            value={@block_query}
            placeholder={gettext("Search elements and sections…")}
            phx-debounce="120"
            class="peer h-[30px] w-full rounded-[9px] border border-[#ecebe6] bg-[#faf9f6] pl-2.5 pr-[28px] text-[11.5px] text-[#3a382f] placeholder:text-[#a8a5a0] focus:border-[#c9c7ee] focus:outline-none"
          />
          <.clear_field field="pb-block-search" event="block_query" params={%{"value" => ""}} />
        </form>

        <div class="mt-2 flex flex-wrap gap-1">
          <button
            :for={cat <- categories_of(@element_library, @block_library)}
            type="button"
            id={"pb-blockcat-#{cat}"}
            phx-click="block_cat"
            phx-value-cat={cat}
            class={[
              "h-[22px] rounded-[7px] px-2 text-[10px] font-bold capitalize",
              (@block_cat == cat && "bg-[#1b1a18] text-white") ||
                "bg-[#f2f1ec] text-[#6d6a63] hover:bg-[#e8e6df]"
            ]}
          >
            {(cat == "all" && gettext("All")) || translate(cat)}
          </button>
        </div>

        <p :if={picked_block_id(@picked_block)} class="mt-2 text-[10px] font-semibold text-[#4f4bcc]">
          {gettext("Placing %{label} — click the canvas or a layer",
            label: picked_block_id(@picked_block)
          )}
        </p>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto px-3 py-3">
        <p
          :if={@items == [] and @elements == []}
          id="pb-blocks-empty"
          class="px-2 py-10 text-center text-[11.5px] font-medium text-[#6d6a63]"
        >
          {gettext("Nothing matches that.")}
        </p>

        <%!-- ELEMENTS FIRST, because they are what a page is made of — the sections below are the
              shortcut. Grouped by their own heading and drawn small: there are twenty-eight of
              them and they are picked by name, not by preview. --%>
        <div :for={group <- element_groups(@elements)} class="mb-4">
          <div class="mb-1.5 px-1 text-[10px] font-bold uppercase tracking-[0.09em] text-[#a8a5a0]">
            {translate(elem(group, 0))}
          </div>
          <div class="grid grid-cols-2 gap-1.5">
            <button
              :for={element <- elem(group, 1)}
              type="button"
              id={"pb-el-#{element.id}"}
              phx-hook="PbPaletteItem"
              draggable="true"
              data-template={element.template}
              phx-click="pick_block"
              phx-value-block={element.id}
              title={
                gettext("%{description} — click to place, or drag onto the canvas",
                  description: translate(element.description)
                )
              }
              class={[
                "flex cursor-grab items-center gap-1.5 rounded-[9px] border px-2 py-[7px] text-left",
                (picked_block_id(@picked_block) == element.id &&
                   "border-[#4f4bcc] bg-[#f2f1fc]") ||
                  "border-[#ecebe6] bg-white hover:border-[#c9c7ee] hover:bg-[#faf9fe]"
              ]}
            >
              <span class="grid size-[18px] flex-none place-items-center rounded-[5px] bg-[#f2f1ec] text-[#6d6a63]">
                <.icon name={element_icon(element.id)} size={11} />
              </span>
              <span class="truncate text-[11px] font-semibold text-[#3a382f]">{translate(
                element.title
              )}</span>
            </button>
          </div>
        </div>

        <div
          :if={@elements != [] and @items != []}
          class="mb-1.5 px-1 text-[10px] font-bold uppercase tracking-[0.09em] text-[#a8a5a0]"
        >
          {gettext("Sections")}
        </div>

        <div class="flex flex-col gap-2">
          <button
            :for={block <- @items}
            type="button"
            id={"pb-block-#{block.id}"}
            phx-hook="PbPaletteItem"
            draggable="true"
            data-template={block.template}
            phx-click="pick_block"
            phx-value-block={block.id}
            title={
              gettext("%{description} — click to place, or drag onto the canvas",
                description: translate(block.description)
              )
            }
            class={[
              "w-full cursor-grab rounded-[12px] border p-2.5 text-left",
              (picked_block_id(@picked_block) == block.id && "border-[#4f4bcc] bg-[#f2f1fc]") ||
                "border-[#ecebe6] bg-white hover:border-[#c9c7ee]"
            ]}
          >
            <.block_sketch id={block.id} />
            <div class="mt-2 text-[11.5px] font-bold text-[#3a382f]">{translate(block.title)}</div>
            <div class="mt-0.5 text-[10px] leading-[1.45] text-[#6d6a63]">
              {translate(block.description)}
            </div>
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Only the categories the current filter actually left something in, in the order the module
  # declares them — so choosing "Text" does not leave two empty headings above the results.
  defp element_groups(elements) do
    order = Elements.categories(nil) ++ ["Dynamic"]

    elements
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, _items} ->
      Enum.find_index(order, &(&1 == category)) || length(order)
    end)
  end

  # An element library filtered by the same two questions the blocks are: which category, and does it
  # match what was typed. A category that belongs to neither library answers nothing rather than
  # everything.
  defp elements_for(library, category, query) do
    case category == "all" or category in Enum.map(library, &Map.get(&1, :category)) do
      false -> []
      true -> Blocks.filter(library, category, query)
    end
  end

  # EVERY CATEGORY THERE IS SOMETHING IN, including the ones an extension brought. Built from the
  # merged libraries rather than the core lists, or a plugin's own category had no chip to reach it
  # by and its cards showed under every filter instead.
  defp categories_of(elements, blocks) do
    ["all"] ++
      ((elements ++ blocks)
       |> Enum.map(&Map.get(&1, :category))
       |> Enum.reject(&is_nil/1)
       |> Enum.uniq())
  end

  # The glyph beside a name. The set is the editor's own — see `icon/1` — so an element that has no
  # obvious one falls back to the box rather than inventing a shape.
  @element_icons %{
    "el-section" => :frame,
    "el-container" => :frame,
    "el-main" => :page,
    "el-article" => :page,
    "el-aside" => :layers,
    "el-header" => :head,
    "el-footer" => :window,
    "el-nav" => :nav,
    "el-div" => :box,
    "el-columns-2" => :grid,
    "el-columns-3" => :grid,
    "el-columns-4" => :grid,
    "el-row" => :list,
    "el-stack" => :layers,
    "el-spacer" => :move,
    "el-divider" => :minus,
    "el-h1" => :text,
    "el-h2" => :text,
    "el-h3" => :text,
    "el-h4" => :text,
    "el-h5" => :text,
    "el-h6" => :text,
    "el-paragraph" => :text,
    "el-link" => :link,
    "el-list" => :list,
    "el-list-ordered" => :list,
    "el-quote" => :comment,
    "el-image" => :image,
    "el-figure" => :gallery
  }

  defp element_icon(id), do: Map.get(@element_icons, id, :box)

  # A DRAWING, NOT A SCREENSHOT. Rendering the real block at thumbnail size would need the site's
  # compiled CSS inside a panel that has none, so each one is a few bars in the shape of the section.
  # It reads at a glance, costs nothing, and cannot drift out of sync with a stylesheet.
  #
  # A bar's width is a WHOLE CLASS NAME here rather than a number the markup then builds one from. A
  # `w-[…%]` assembled around an interpolation is source text no Tailwind build can match, so the
  # rule would not exist and every bar would collapse; written this way the table itself is what the
  # build scans, and a bar cannot be added without its width.
  @block_sketches %{
    "hero-centred" => [{"w-[60%]", :bar}, {"w-[38%]", :bar}, {"w-[26%]", :btn}],
    "features-three" => [{"w-[34%]", :bar}, {:row, 3}],
    "features-four" => [{:row, 4}],
    "media-split" => [{:split, 2}],
    "stats-row" => [{:row, 3}],
    "pricing-three" => [{"w-[30%]", :bar}, {:row, 3}],
    "cta-band" => [{"w-[46%]", :bar}, {"w-[24%]", :btn}],
    "footer-columns" => [{:row, 3}, {"w-[70%]", :bar}]
  }

  attr(:id, :string, required: true)

  defp block_sketch(assigns) do
    assigns = assign(assigns, :parts, Map.get(@block_sketches, assigns.id, [{"w-[50%]", :bar}]))

    ~H"""
    <div class="flex h-[46px] flex-col justify-center gap-[3px] rounded-[8px] bg-[#f7f6f3] px-2.5">
      <div :for={part <- @parts} class="flex gap-[3px]">
        <span
          :if={match?({_width, :bar}, part)}
          class={["h-[4px] rounded-full bg-[#d8d6ce]", elem(part, 0)]}
        ></span>
        <span
          :if={match?({_width, :btn}, part)}
          class={["h-[8px] rounded-[3px] bg-[#c3c1e8]", elem(part, 0)]}
        ></span>
        <span
          :for={_column <- 1..column_span(part)//1}
          class="h-[13px] flex-1 rounded-[3px] bg-[#e4e2da]"
        ></span>
      </div>
    </div>
    """
  end

  defp column_span({:row, count}), do: count
  defp column_span({:split, count}), do: count
  defp column_span(_part), do: 0

  # ONE `picked` FIELD, TWO KINDS. A block arrives tagged `{:block, id}` so the canvas, the layer
  # tree and both hints all read the same field and cannot disagree about what is armed — and so a
  # tuple never reaches a template, which is not renderable.
  defp picked_block_id({:block, id}), do: id
  defp picked_block_id(_other), do: nil

  defp picked_label({:block, id}), do: id
  defp picked_label(name) when is_binary(name), do: name
  defp picked_label(_other), do: ""

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
  attr(:picked, :string, default: nil)
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
        <span :if={@picked} class="whitespace-nowrap text-[11px] font-bold text-[#4f4bcc]">
          {gettext("Placing %{label}", label: picked_label(@picked))}
        </span>

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
        phx-click="place"
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

  @doc "⌘K — actions first, then the admin routes to jump to."
  def command_palette(assigns) do
    ~H"""
    <div
      id="pb-command"
      class="fixed inset-0 z-[95] flex items-start justify-center bg-[#17161a]/[.44] px-5 pt-[11vh]"
      phx-mounted={modal_in("#pb-command > div")}
      phx-remove={modal_out("#pb-command > div")}
    >
      <%!-- `phx-click-away` belongs on the PANEL, not on the backdrop. On a full-screen backdrop no
            click is ever "away" from it, so the overlay never closed — which is why clicking outside
            the Studio did nothing. --%>
      <div
        phx-click-away="toggle_command"
        class="flex max-h-[70vh] w-full max-w-[560px] flex-col overflow-hidden rounded-[16px] bg-white shadow-[0_30px_80px_rgba(20,18,26,.42)]"
      >
        <div class="flex items-center gap-2.5 border-b border-[#f0efea] px-4 py-3">
          <.icon name={:search} size={17} class="text-[#a8a5a0]" />
          <div class="relative flex-1">
            <input
              id="pb-command-input"
              type="text"
              name="value"
              value={@command_query}
              phx-keyup="command_query"
              phx-debounce="80"
              placeholder={gettext("Jump to a page, or run a command…")}
              autocomplete="off"
              class="peer w-full pr-[26px] text-[13.5px] font-medium text-[#17161a] outline-none"
            />
            <.clear_field field="pb-command-input" event="command_query" params={%{"value" => ""}} />
          </div>
          <span class="rounded-[5px] bg-[#f2f1ec] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold text-[#6d6a63]">
            ESC
          </span>
        </div>
        <div class="min-h-0 flex-1 overflow-y-auto p-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          <div :if={matching_commands(@commands, @command_query) != []} class="mb-1.5">
            <h3 class="px-2.5 pb-1.5 pt-2 text-[9.5px] font-bold uppercase tracking-[0.11em] text-[#6d6a63]">
              {gettext("Actions")}
            </h3>
            <button
              :for={command <- matching_commands(@commands, @command_query)}
              type="button"
              id={"pb-cmd-#{command.key}"}
              phx-click={command.key}
              class="flex w-full items-center gap-[11px] rounded-[10px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2]"
            >
              <span class="grid size-[26px] flex-none place-items-center rounded-[8px] bg-[#f4f3ee] text-[#6d6a63]">
                <.icon name={icon_name(command.icon)} size={14} />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-[12.5px] font-semibold text-[#1b1a18]">
                  {translate(command.label)}
                </span>
                <span
                  :if={command.description}
                  class="mt-px block truncate text-[10.5px] font-medium text-[#6d6a63]"
                >
                  {translate(command.description)}
                </span>
              </span>
              <span
                :if={command.shortcut}
                class="flex-none rounded-[5px] bg-[#f2f1ec] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold text-[#6d6a63]"
              >
                {command.shortcut}
              </span>
            </button>
          </div>

          <%!-- "Go to" is the real admin menu, permission-filtered by `MishkaCmsCore.Sidebar.menu/1`,
                so the palette can never offer someone a page they would be refused. --%>
          <div :if={matching_targets(@goto, @command_query) != []}>
            <h3 class="px-2.5 pb-1.5 pt-2 text-[9.5px] font-bold uppercase tracking-[0.11em] text-[#6d6a63]">
              {gettext("Go to")}
            </h3>
            <.link
              :for={target <- matching_targets(@goto, @command_query)}
              navigate={target.path}
              id={"pb-goto-#{target.key}"}
              class="flex w-full items-center gap-[11px] rounded-[10px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2]"
            >
              <span class="grid size-[26px] flex-none place-items-center rounded-[8px] bg-[#f2f1fc] text-[#4f4bcc]">
                <.icon name={goto_icon(target)} size={14} />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-[12.5px] font-semibold text-[#1b1a18]">
                  {translate(target.label)}
                </span>
                <span class="mt-px block truncate font-['Space_Grotesk'] text-[10.5px] font-medium text-[#6d6a63]">
                  {target.path}
                </span>
              </span>
            </.link>
          </div>

          <p
            :if={
              matching_commands(@commands, @command_query) == [] &&
                matching_targets(@goto, @command_query) == []
            }
            class="px-2.5 py-10 text-center text-[12.5px] font-medium text-[#6d6a63]"
          >
            {gettext("No matches.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # The sidebar names its icons as heroicons; this panel draws its own inline set. Only the menu's
  # own names are translated, and anything else falls through to the chevron — a wrong glyph reads as
  # a different destination, which is worse than a neutral one.
  @goto_icons %{
    "hero-home" => :page,
    "hero-map-pin" => :nav,
    "hero-rectangle-group" => :grid,
    "hero-squares-2x2" => :grid,
    "hero-document-text" => :draft,
    "hero-exclamation-triangle" => :shield,
    "hero-photo" => :image,
    "hero-paint-brush" => :sparkle,
    "hero-code-bracket" => :code,
    "hero-users" => :key,
    "hero-user" => :key,
    "hero-shield-check" => :shield,
    "hero-bell" => :comment,
    "hero-cog-6-tooth" => :sliders,
    "hero-book-open" => :list,
    "hero-folder" => :gallery,
    "hero-clock" => :history,
    "hero-bolt" => :bolt
  }

  defp goto_icon(%{icon: icon}) when is_binary(icon), do: Map.get(@goto_icons, icon, :chevron)
  defp goto_icon(_target), do: :chevron

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

  # The prototype's own order and set. The last four are not panels at all — they open the overlays
  # that the top bar has no room for at this width — and the direction toggle reports its own state
  # in its label rather than needing a second control.
  # Below 900px there is room for exactly one column, so the panel the mobile bar names takes the
  # whole width and everything else is hidden. The panels themselves are reused rather than copied:
  # a second rendering of the same panel would put every one of its DOM ids on the page twice, and
  # LiveView patches by id.
  defp mobile_visibility(mob_panel, panels) do
    case mob_panel in panels do
      true -> "max-[900px]:flex max-[900px]:!w-full"
      false -> "max-[900px]:hidden"
    end
  end

  defp mobile_tabs(assigns) do
    [
      {"canvas", gettext("Canvas")},
      {"components", gettext("Components")},
      {"palette", gettext("Search")},
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

  # The prototype's per-category icon tints, so a palette scanned at speed reads by colour.
  # One colour per category, used three ways: the dot beside a group heading, the icon tile's text,
  # and (lightened) that tile's background. The prototype hand-authored an icon and a pair of colours
  # per component; here the category carries them, because these components come from the database
  # and there are 183 of them. Same rhythm, real data.
  @category_colors %{
    "layout" => {"#4f4bcc", "#eef1fc", :layers},
    "text" => {"#1f9d6b", "#e6f6ee", :text},
    "nav" => {"#3a6cb5", "#e9f0fa", :nav},
    "form" => {"#cf8a24", "#fbf1df", :form},
    "forms" => {"#cf8a24", "#fbf1df", :form},
    "media" => {"#b03a76", "#fdeaf3", :image},
    "feedback" => {"#0f8f86", "#e6f5f2", :tip},
    "data" => {"#7a5bd0", "#f1edfb", :table},
    "overlay" => {"#c2478f", "#fdeaf3", :layers},
    "general" => {"#6d6a63", "#f4f3ef", :box}
  }

  defp category_entry(type) do
    name = String.downcase(to_string(type || "general"))

    case Map.fetch(@category_colors, name) do
      {:ok, entry} -> entry
      :error -> derived_entry(name)
    end
  end

  # A KIT BRINGS ITS OWN TAXONOMY, and ten hand-picked names cannot cover one nobody has written yet.
  # Every unlisted category used to take the same grey, so a kit filing its components under
  # `widgets`/`charts`/`commerce` got a palette where the dot beside every group heading and the tile
  # behind every card were identical — the colour coding still drawn, still costing the space, and
  # carrying no information at all. Chelekom's own palette read by colour; theirs did not.
  #
  # The hue comes from the name, so it is stable across renders, sessions and machines without a
  # table to maintain. Saturation and lightness are FIXED at the range the hand-picked ten already
  # occupy, which is what keeps a derived colour from looking like it came from somewhere else.
  @derived_hues 16
  @golden_angle 137

  defp derived_entry(name) do
    hue = rem(:erlang.phash2(name, @derived_hues) * @golden_angle, 360)

    {hsl_hex(hue, 0.48, 0.40), hsl_hex(hue, 0.52, 0.95), :box}
  end

  defp hsl_hex(hue, saturation, lightness) do
    chroma = (1 - abs(2 * lightness - 1)) * saturation
    second = chroma * (1 - abs(:math.fmod(hue / 60, 2) - 1))
    base = lightness - chroma / 2

    div(hue, 60)
    |> sector(chroma, second)
    |> Tuple.to_list()
    |> Enum.map_join(&channel_hex(&1 + base))
    |> then(&("#" <> &1))
  end

  defp sector(0, chroma, second), do: {chroma, second, 0}
  defp sector(1, chroma, second), do: {second, chroma, 0}
  defp sector(2, chroma, second), do: {0, chroma, second}
  defp sector(3, chroma, second), do: {0, second, chroma}
  defp sector(4, chroma, second), do: {second, 0, chroma}
  defp sector(_sector, chroma, second), do: {chroma, 0, second}

  defp channel_hex(value) do
    (value * 255)
    |> round()
    |> min(255)
    |> max(0)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  @doc """
  The kit prefixes worth dropping from a card's label.

  The prototype's cards read "Card", "Grid", "Navbar" while the components themselves are
  "chelekom-card" and friends — the kit's own name is on all 157 of them, so printing it on every
  card spends the label on the one word that never varies, and pushes the part that does off the
  card. A first segment shared by three or more components is that kind of prefix; a one-off like
  "hero-banner" keeps both words. The full name stays in the tooltip and everywhere else.
  """
  @spec kit_prefixes([map()]) :: MapSet.t(String.t())
  def kit_prefixes(entries) do
    entries
    |> Enum.map(&(&1.name |> to_string() |> String.split("-") |> hd()))
    |> Enum.frequencies()
    |> Enum.filter(fn {_prefix, count} -> count >= 3 end)
    |> MapSet.new(fn {prefix, _count} -> prefix end)
  end

  @doc "A card's label with its kit prefix removed. Falls back to the full label."
  @spec short_label(map(), MapSet.t(String.t())) :: String.t()
  def short_label(entry, prefixes) do
    case String.split(to_string(entry.name), "-") do
      [head | [_ | _] = rest] ->
        (MapSet.member?(prefixes, head) && titleize(rest)) || entry.label

      _single_word ->
        entry.label
    end
  end

  defp titleize(words), do: Enum.map_join(words, " ", &String.capitalize/1)

  @doc false
  def category_dot(type), do: category_entry(type) |> elem(0)

  @doc false
  def category_tint(type), do: category_entry(type) |> elem(1)

  @doc false
  def category_icon(type), do: category_entry(type) |> elem(2)

  @doc """
  The glyph a palette card draws.

  A component may name its own in `extra.icon` — that is the authored answer and always wins. When it
  does not, one is SUGGESTED from the name, because "chelekom-checkbox-field" plainly wants the input
  glyph and making someone fill in 183 rows before the palette looks right is not a real option. The
  category is the last resort.
  """
  @spec entry_icon(map()) :: atom()
  def entry_icon(%{icon: icon}) when is_binary(icon) and icon != "" do
    Map.get(@icon_names, icon, category_icon(nil))
  end

  def entry_icon(entry), do: suggest_icon(Map.get(entry, :name), Map.get(entry, :type))

  @suggestions [
    {~w(mega-menu navbar breadcrumb pagination menu nav tabs), :nav},
    {~w(heading title h1 h2 h3 h4 h5 h6), :head},
    {~w(paragraph blockquote text-content typography divider), :text},
    {~w(password lock), :lock},
    {~w(keyboard kbd), :key},
    {~w(checkbox radio toggle switch), :box},
    {~w(field input search-field textarea range), :input},
    {~w(button btn), :btn},
    {~w(link anchor), :link},
    {~w(modal drawer dialog overlay sheet), :modal},
    {~w(tooltip popover hint), :tip},
    {~w(gallery carousel), :gallery},
    {~w(image img avatar picture video media), :img},
    {~w(card panel), :card},
    {~w(grid layout column row stack), :grid},
    {~w(list menu-list steps timeline), :list},
    {~w(table datatable), :table},
    {~w(progress rating speed-dial indicator spinner loader), :dial},
    {~w(page article document), :page},
    {~w(alert toast banner flash notification), :tip},
    {~w(clipboard copy), :card},
    {~w(form fieldset), :form}
  ]

  # Matched on whole WORDS, not substrings: "kit-image-block" contains "lock", and a substring rule
  # handed it the padlock. A hyphenated key like "mega-menu" is matched against the joined name.
  defp suggest_icon(name, type) when is_binary(name) do
    needle = String.downcase(name)
    words = String.split(needle, ~r/[-_\s]+/, trim: true)

    Enum.find_value(@suggestions, fn {keys, icon} ->
      Enum.any?(keys, &word_match?(&1, needle, words)) && icon
    end) || category_icon(type)
  end

  defp suggest_icon(_name, type), do: category_icon(type)

  defp word_match?(key, needle, words) do
    case String.contains?(key, "-") do
      true -> String.contains?(needle, key)
      false -> key in words
    end
  end

  # One template string serves both insertion gestures — the drag payload and the click-to-place
  # op — so the two can never disagree about what a palette card actually inserts.
  # THE SAME MARKUP A CLICK PRODUCES. A drag carries the template with it, so it has to go through
  # the site's preset too — otherwise dragging a Button and clicking it would place two different
  # buttons. See `MishkaCmsCore.Runtime.PageBuilder.Presets`.
  defp component_template(entry, site_name, presets, components),
    do: MishkaCmsCore.Runtime.PageBuilder.Presets.template(entry, site_name, presets, components)

  # The demo groups the palette under category headings with a count each, which is what makes 100+
  # components scannable; a flat grid is not.
  defp grouped_entries(entries) do
    entries
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {group, _entries} -> group end)
    |> Enum.map(fn {group, group_entries} ->
      {String.upcase(group || "general"), Enum.sort_by(group_entries, & &1.label)}
    end)
  end

  # The row is no longer one list: All is drawn first, the two browser-side chips sit right after it,
  # and the kit's own categories follow — so this returns the categories WITHOUT "all".
  defp component_categories(components) do
    components |> Enum.map(& &1.type) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  attr(:cat, :string, required: true)
  attr(:active, :string, required: true)

  # One chip, drawn in two places — All is rendered on its own so the two browser-side chips can sit
  # between it and the kit's categories.
  defp cat_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="palette_cat"
      phx-value-cat={@cat}
      class={[
        "h-7 flex-none rounded-[8px] border px-[11px] text-[11px] font-semibold capitalize",
        (@active == @cat && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
          "border-[#ecebe6] bg-white text-[#6d6a63] hover:border-[#dcdbf5]"
      ]}
    >
      {(@cat == "all" && gettext("All")) || category_name(@cat)}
    </button>
    """
  end

  defp category_name(type) do
    case type |> to_string() |> String.downcase() do
      "layout" -> gettext("layout")
      "text" -> gettext("text")
      "nav" -> gettext("nav")
      "form" -> gettext("form")
      "forms" -> gettext("forms")
      "media" -> gettext("media")
      "feedback" -> gettext("feedback")
      "data" -> gettext("data")
      "overlay" -> gettext("overlay")
      "general" -> gettext("general")
      _kit_category -> to_string(type)
    end
  end

  defp filter_palette(%{components: components, palette_query: query, palette_cat: cat}) do
    components
    |> Enum.filter(&(cat == "all" or &1.type == cat))
    |> Enum.filter(&matches?(&1, query))
    |> Enum.sort_by(& &1.label)
  end

  defp matches?(_entry, ""), do: true

  defp matches?(entry, query) do
    needle = String.downcase(query)

    String.contains?(String.downcase(entry.name), needle) or
      String.contains?(String.downcase(entry.label), needle) or
      String.contains?(String.downcase(entry.description || ""), needle)
  end

  defp matching_commands(commands, ""), do: commands

  defp matching_commands(commands, query) do
    needle = String.downcase(query)

    Enum.filter(commands, fn command ->
      contains?(translate(Descriptor.label(command)), needle) ||
        contains?(translate(command.description), needle)
    end)
  end

  defp matching_targets(targets, ""), do: targets

  defp matching_targets(targets, query) do
    needle = String.downcase(query)
    Enum.filter(targets, &(contains?(translate(&1.label), needle) || contains?(&1.path, needle)))
  end

  defp contains?(nil, _needle), do: false
  defp contains?(text, needle), do: String.contains?(String.downcase(text), needle)

  defp translate(text) when is_binary(text), do: Gettext.gettext(MishkaCmsCore.Gettext, text)
  defp translate(other), do: other

  @doc """
  The icon this panel draws for a descriptor's plain-string `icon`, so a plugin can name one without
  depending on this module's atoms. A name the set does not hold falls back to the chevron.
  """
  @spec icon_name(String.t() | nil) :: atom()
  def icon_name(name), do: Map.get(@icon_names, name, :chevron)

end
