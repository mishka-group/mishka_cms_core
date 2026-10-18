# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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

  import MishkaCmsCore.CoreComponents, only: [roadmap_notice: 1, select_chevron: 1]

  alias MishkaCmsCore.Builder.Collection
  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Builder.Descriptor
  alias MishkaCmsCore.Builder.PaletteEntry
  alias Phoenix.LiveView.JS
  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.PageBuilder.AiBackend
  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Runtime.PageBuilder.CodeFlags
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
  alias MishkaCmsCore.Runtime.PageBuilder.Highlight
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Runtime.MediaCategory
  alias MishkaCmsCore.Runtime.PageBuilder.Conditions
  alias MishkaCmsCore.Runtime.PageBuilder.Containment
  alias MishkaCmsCore.Runtime.PageBuilder.Review
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.PageBuilder.SeoSettings
  alias MishkaCmsCore.Runtime.PageComment
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Icons
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Interface
  alias MishkaCmsCore.Runtime.PageBuilder.LayoutSlot
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Shadow
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Demo
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.PageBuilder.Presence
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard

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
  # A row nobody has anything to say about. Named so the layers row can read one shape whether or not
  # the sweep found it, rather than every reader guarding on nil.
  @no_needs %{attrs: 0, slots: 0, total: 0}

  @menu_in {"transition-[opacity,transform] ease-out duration-100", "opacity-0 scale-95",
            "opacity-100 scale-100"}
  @menu_out {"transition-[opacity,transform] ease-in duration-75", "opacity-100 scale-100",
             "opacity-0 scale-95"}

  @scrim_in {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
  @scrim_out {"transition-opacity ease-in duration-150", "opacity-100", "opacity-0"}

  @panel_in {"transition-[opacity,transform] ease-out duration-200", "opacity-0 translate-x-6",
             "opacity-100 translate-x-0"}
  @panel_out {"transition-[opacity,transform] ease-in duration-150", "opacity-100 translate-x-0",
              "opacity-0 translate-x-6"}

  @modal_in {"transition-[opacity,transform] ease-out duration-200", "opacity-0 scale-95",
             "opacity-100 scale-100"}
  @modal_out {"transition-[opacity,transform] ease-in duration-150", "opacity-100 scale-100",
              "opacity-0 scale-95"}

  # The drawer lives at the foot of the canvas column, so it arrives and leaves from below rather
  # than fading in place.
  @drawer_in {"transition-[opacity,transform] ease-out duration-200", "opacity-0 translate-y-4",
              "opacity-100 translate-y-0"}
  @drawer_out {"transition-[opacity,transform] ease-in duration-150", "opacity-100 translate-y-0",
               "opacity-0 translate-y-4"}

  # A SCROLLBAR THAT ARRIVES WITH THE POINTER. The rest of the editor's panels hide theirs outright
  # — `[scrollbar-width:none]` — which is right for a list of components and wrong for code, where
  # how far down the file you are is worth knowing. So: thin, the panel's own border colour, and
  # invisible until somebody points at the pane.
  #
  # Both spellings every time. Firefox has never implemented the `::-webkit-scrollbar` pseudo-
  # elements and WebKit has never implemented `scrollbar-color`, so either one alone leaves half the
  # browsers on the native bar.
  @quiet_scroll_dark "[scrollbar-width:thin] [scrollbar-color:transparent_transparent] " <>
                       "hover:[scrollbar-color:#3b3746_transparent] " <>
                       "[&::-webkit-scrollbar]:h-2 [&::-webkit-scrollbar]:w-2 " <>
                       "[&::-webkit-scrollbar-corner]:bg-transparent " <>
                       "[&::-webkit-scrollbar-track]:bg-transparent " <>
                       "[&::-webkit-scrollbar-thumb]:rounded-full " <>
                       "[&::-webkit-scrollbar-thumb]:bg-transparent " <>
                       "hover:[&::-webkit-scrollbar-thumb]:bg-[#3b3746] " <>
                       "hover:[&::-webkit-scrollbar-thumb:hover]:bg-[#56545e]"

  # The Code window is the light surface, so the same bar in its own greys.
  @quiet_scroll_light "[scrollbar-width:thin] [scrollbar-color:transparent_transparent] " <>
                        "hover:[scrollbar-color:#d5d3cb_transparent] " <>
                        "[&::-webkit-scrollbar]:h-2 [&::-webkit-scrollbar]:w-2 " <>
                        "[&::-webkit-scrollbar-corner]:bg-transparent " <>
                        "[&::-webkit-scrollbar-track]:bg-transparent " <>
                        "[&::-webkit-scrollbar-thumb]:rounded-full " <>
                        "[&::-webkit-scrollbar-thumb]:bg-transparent " <>
                        "hover:[&::-webkit-scrollbar-thumb]:bg-[#d5d3cb] " <>
                        "hover:[&::-webkit-scrollbar-thumb:hover]:bg-[#bdbab1]"

  @doc "The scrollbar treatment for a pane that holds code, on a dark or a light surface."
  @spec quiet_scroll(:dark | :light) :: String.t()
  def quiet_scroll(:dark), do: @quiet_scroll_dark
  def quiet_scroll(:light), do: @quiet_scroll_light

  @doc false
  def drawer_in, do: JS.transition(@drawer_in, time: 200)

  @doc false
  def drawer_out, do: JS.hide(transition: @drawer_out, time: 150)

  @doc false
  def menu_in, do: JS.transition(@menu_in, time: 100)

  @doc false
  def menu_out, do: JS.hide(transition: @menu_out, time: 75)

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

  # The backdrop fades and the panel slides, which is why both halves are named: one command targets
  # the root, the other reaches the child by selector.
  @doc false
  def overlay_in(panel) do
    @scrim_in
    |> JS.transition(time: 200)
    |> JS.transition(@panel_in, to: panel, time: 200)
  end

  @doc false
  def overlay_out(panel) do
    JS.hide(transition: @scrim_out, time: 150)
    |> JS.hide(to: panel, transition: @panel_out, time: 150)
  end

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
  defp grip_var(:right), do: "--pb-right-w"
  defp grip_var(:drawer), do: "--pb-drawer-h"

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

  @doc "The keys the core draws itself; everything else is drawn by its own descriptor."
  def core_rail_keys, do: ["layers", "assistant", "audit"]

  # The open rail, when an extension contributed it. The core's three are spelled out above because
  # each takes a different slice of the editor's state.
  defp contributed_rails(rails, open) do
    Enum.filter(rails, fn rail ->
      key = to_string(Descriptor.key(rail))
      key == to_string(open) and key not in core_rail_keys()
    end)
  end

  @doc "The core's right-rail tabs — the seed of the `builder:rails` registry."
  def core_rails do
    [
      descriptor("layers", :rail_tab, gettext_noop("Layers"), 10, icon: "layers"),
      descriptor("assistant", :rail_tab, gettext_noop("Assistant"), 20, icon: "sparkle"),
      descriptor("audit", :rail_tab, gettext_noop("Audit"), 30, icon: "shield")
    ]
  end

  @doc "The core's inspector sections — the seed of `builder:inspector:sections`."
  def core_inspector_sections do
    [
      descriptor("element", :inspector_section, gettext_noop("Element"), 10),
      descriptor("editing_at", :inspector_section, gettext_noop("Editing at"), 20),
      descriptor("state", :inspector_section, gettext_noop("State"), 30),
      descriptor("layout", :inspector_section, gettext_noop("Layout"), 40),
      descriptor("appearance", :inspector_section, gettext_noop("Appearance"), 50),
      descriptor("behavior", :inspector_section, gettext_noop("Behavior"), 60),
      descriptor("attributes", :inspector_section, gettext_noop("Attributes"), 70),
      descriptor("props", :inspector_section, gettext_noop("Props"), 80)
    ] ++ Inspector.form_sections()
  end

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
      descriptor("duplicate", :command, gettext_noop("Duplicate selection"), 50,
        shortcut: "⌘D",
        icon: "copy",
        description: gettext_noop("Copy the selected element in place")
      ),
      descriptor("toggle_visibility", :command, gettext_noop("Hide or show for visitors"), 55,
        shortcut: "⇧⌘H",
        icon: "eye_off",
        description:
          gettext_noop("Keep the selection in the page, shown to nobody, or show it again")
      ),
      descriptor("delete", :command, gettext_noop("Delete selection"), 60,
        shortcut: "⌫",
        icon: "trash",
        description: gettext_noop("Remove the selected element")
      ),
      descriptor("toggle_code", :command, gettext_noop("Toggle code drawer"), 70,
        shortcut: "⌘/",
        icon: "code",
        description: gettext_noop("Show or hide the generated source")
      ),
      descriptor("toggle_preview", :command, gettext_noop("Toggle preview"), 80,
        shortcut: "⌘P",
        icon: "eye",
        description: gettext_noop("Turn the editor chrome off")
      )
    ]
  end

  # An extension can add its own interaction — a modal opener, an analytics ping — beside the core's.
  # COLLECTED ONCE, INSIDE `actions/1`. Collecting again here fired every plugin a second time per
  # render and handed it a list of `{key, label}` tuples where the first pass had handed it
  # descriptors, so a plugin could not answer both the same way; what it appended came back in the
  # wrong shape and the comprehension below dropped it without a word. `offer?/2` runs in `actions/1`
  # too, so a second pass could put back the verbs a target cannot honour.
  defp interaction_actions(opener), do: Interactions.actions(opener)

  defp descriptor(key, kind, label, priority, opts \\ []) do
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

  attr(:editor, :any, required: true)
  attr(:record, :any, default: nil)
  attr(:section, :string, required: true)
  attr(:back_path, :string, required: true)
  attr(:current_user, :any, default: nil)
  attr(:editors, :list, default: [])
  attr(:draft, :any, default: nil)
  attr(:drafts_enabled?, :boolean, default: false)
  attr(:dirty?, :boolean, default: false)
  attr(:saved_at, :any, default: nil)
  attr(:stage, :atom, default: :draft)
  attr(:applied_stage, :atom, default: :draft)
  attr(:device, :string, default: nil)
  attr(:dir, :string, default: "ltr")
  attr(:zoom, :integer, default: 100)
  attr(:preview?, :boolean, default: false)
  attr(:source_modal, :boolean, default: false)
  attr(:dev_mode?, :boolean, default: false)
  attr(:open_bugs, :integer, default: 0)
  attr(:studio_badge, :integer, default: 0)
  attr(:history_position, :integer, default: 0)
  attr(:history_total, :integer, default: 0)

  @doc """
  The 56px top bar: identity and save status on the left, every global control on the right.

  THE IDENTITY BLOCK IS THE ONLY CHILD THAT GIVES WAY. Everything on its right is `flex-none`, so it
  is the controls that must stay whole; the block takes what is left and truncates — the document's
  name, the status, the scope badge and the draft chip each carry `min-w-0` for it. A block that was
  itself `flex-none` grew with whatever the record was called and pushed Publish off the screen, and
  the status line is longest exactly when the stage is Published. Below 1180px the status wording
  goes and its dot, with the words as a tooltip, stays — the same ladder the avatars and the labels
  follow.
  """
  def top_bar(assigns) do
    assigns = assign(assigns, :shareable_draft?, shareable_draft?(assigns[:draft]))

    ~H"""
    <header class="flex h-14 flex-none items-center gap-3.5 border-b border-[#e6e4de] bg-white px-4 max-[1060px]:gap-2 max-[1060px]:px-2.5">
      <span
        id="pb-leave-guard"
        phx-hook="PbLeaveGuard"
        data-armed={to_string(@stage == :published and @dirty?)}
        class="hidden"
      />
      <div data-role="pb-identity" class="flex min-w-0 flex-1 items-center gap-2.5">
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
                "min-w-0 max-w-[120px] truncate rounded-full px-1.5 py-[1px] font-['Space_Grotesk'] text-[9.5px] font-bold",
                (global_document?(assigns) && "bg-[#f6f4fd] text-[#6d4fc0]") ||
                  "bg-[#f2f1ec] text-[#5c5a54]"
              ]}
            >
              {scope_label(assigns)}
            </span>
          </div>
          <div class="mt-0.5 flex items-center gap-1.5">
            <span
              title={status_label(assigns)}
              class={[
                "size-[5px] flex-none rounded-full",
                (@dirty? && "bg-[#cf8a24]") || "bg-[#1f9d6b]"
              ]}
            />
            <%!-- THE NAME IS THE WAY IN, which is where a reader already looks for it — and it is a
                  button only when there is a record to change and an address to change about it.
                  Before that, the essentials step is asking for exactly these fields one layer up. --%>
            <button
              :if={settable?(assigns)}
              type="button"
              id="pb-settings-open"
              phx-click="open_settings"
              title={gettext("Name and path")}
              class="inline-flex min-w-0 items-center gap-1 rounded-[6px] px-1 py-px text-[10px] font-medium text-[#6d6a63] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
            >
              <span class="truncate">{document_label(assigns)}</span>
              <.icon name={:sliders} size={10} class="flex-none opacity-70" />
            </button>
            <span
              :if={not settable?(assigns)}
              class="truncate text-[10px] font-medium text-[#6d6a63]"
            >
              {document_label(assigns)}
            </span>
            <span
              data-role="pb-status"
              title={status_label(assigns)}
              class="min-w-0 truncate text-[10px] font-medium text-[#6d6a63] max-[1180px]:hidden"
            >
              · {status_label(assigns)}
            </span>
            <%!-- Which of this document's versions the editor is writing to. Absent means the live
                  one. A save that lands somewhere the author did not choose is the failure this
                  names away. --%>
            <%!-- The one control that answers "where am I saving, and when did it last save?" — and
                  the way to a different draft. It replaces a toolbar icon that said neither. --%>
            <button
              :if={@drafts_enabled?}
              type="button"
              id="pb-draft-target"
              phx-click="draft_sheet"
              title={gettext("Choose a draft")}
              class="inline-flex min-w-0 max-w-[190px] items-center gap-1 rounded-full border border-[#dcdbf5] bg-[#f2f1fc] px-2 py-[1px] font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
            >
              <span class="truncate">
                {(@editor.draft_label &&
                    MishkaCmsCore.Runtime.PageBuilder.Drafts.display_label(@editor.draft_label)) ||
                  live_label(@section)}
              </span>
              <span :if={@editor.saved_at} class="flex-none font-medium text-[#8580d8]">
                · {ago(@editor.saved_at)}
              </span>
              <.icon name={:chevron} size={9} class="flex-none rotate-90" />
            </button>
          </div>
        </div>
      </div>

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
          <.more_item
            :if={@drafts_enabled?}
            id="pb-more-drafts"
            event="draft_sheet"
            value={%{}}
            icon={:layers}
            label={gettext("Draft history")}
            description={gettext("Open a saved draft, or save this one under a name")}
          />
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
          <.more_item
            id="pb-find-open"
            event="open_find"
            value={%{}}
            icon={:search}
            label={gettext("Find and replace")}
            badge="⌘F"
          />
          <.more_item
            event="open_sheet"
            value={%{sheet: "assets"}}
            icon={:image}
            label={gettext("Assets")}
          />
          <.more_item
            id="pb-more-translations"
            event="open_sheet"
            value={%{sheet: "translations"}}
            icon={:language}
            label={gettext("Translations")}
            description={gettext("The t(…) words on this document, in every language")}
          />
          <%!-- The same settings the name opens, landing on their SEO tab. --%>
          <.more_item
            :if={settable?(assigns) and SeoSettings.mode(@section)}
            id="pb-more-seo"
            event="open_settings"
            value={%{tab: "seo"}}
            icon={:sliders}
            label={gettext("SEO")}
            description={seo_menu_description(SeoSettings.mode(@section))}
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
          <.more_item
            event="open_sheet"
            value={%{sheet: "history"}}
            icon={:history}
            label={gettext("Record history")}
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

        <button
          id="pb-assets"
          type="button"
          data-role="pb-assets"
          phx-click="open_sheet"
          phx-value-sheet="assets"
          title={gettext("Assets")}
          class="grid size-8 flex-none place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc] max-[1080px]:hidden"
        >
          <.icon name={:image} size={15} />
        </button>

        <button
          id="pb-studio"
          type="button"
          phx-click="open_sheet"
          phx-value-sheet="studio"
          title={gettext("Studio — tokens, presets, snippets, packages")}
          class="inline-flex h-8 items-center gap-2.5 rounded-[10px] bg-[#17161a] px-1.5 text-[12px] font-bold text-white shadow-[0_2px_8px_rgba(20,18,26,.24)] hover:bg-[#221f27]"
        >
          <span class="grid size-[22px] flex-none grid-cols-2 grid-rows-2 gap-[1.5px] rounded-[7px] bg-white/10 p-[3px]">
            <span class="rounded-[1.5px] bg-[#8580d8]" />
            <span class="rounded-[1.5px] bg-[#4ec08d]" />
            <span class="rounded-[1.5px] bg-[#e0a52e]" />
            <span class="rounded-[1.5px] bg-[#f0f0f2]" />
          </span>
          <span data-role="pb-studiolbl" class="-tracking-[.01em] max-[820px]:hidden">{gettext(
            "Studio"
          )}</span>
          <span
            :if={@studio_badge > 0}
            title={gettext("Design tokens your team added")}
            class="ml-0.5 mr-0.5 flex h-6 min-w-5 items-center justify-center gap-1 rounded-[7px] bg-[#2e2c33] px-1.5 font-['Space_Grotesk'] text-[10px] font-bold text-[#8ee0b8]"
          >
            <span class="size-[5px] rounded-full bg-[#4ec08d]" />{@studio_badge}
          </span>
          <span :if={@studio_badge == 0} class="pr-1.5" />
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

        <%!-- THE NUMBER IS UNRESOLVED BUGS, counted in the database rather than measured off
              whatever the sheet happens to have loaded. It moves when a bug is raised, resolved,
              reopened or deleted, because those are the only four things that change the count. --%>
        <.bar_button
          id="pb-review"
          event="open_sheet"
          value={%{sheet: "review"}}
          icon={:comment}
          label={gettext("Review")}
          count={@open_bugs}
        />
        <button
          id="pb-history"
          type="button"
          data-role="pb-hist"
          phx-click="open_sheet"
          phx-value-sheet="history"
          title={gettext("Record history")}
          class="grid size-8 flex-none place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
        >
          <.icon name={:history} size={15} />
        </button>

        <%!-- THE TOP BAR'S CODE IS THE PAGE'S SOURCE, in a window big enough to read it in. It used
              to toggle the strip at the bottom of the canvas, which is a different surface with a
              different job — a glance at what the selection serialises to, in a 300px sliver. That
              drawer is untouched and still opens from its own strip and from ⌘/. --%>
        <.bar_button
          id="pb-code"
          event="open_source"
          value={%{}}
          icon={:code}
          label={gettext("Code")}
          active={@source_modal}
        />
        <%!-- PREVIEW IS A TOGGLE, and on most pages that is all it is: press it to see the page
              itself, press it again to come back. The caret used to be there always, holding two
              more ways to preview — which made a one-click control look like a three-way choice and
              put a menu in front of the thing it was hiding.
              
              It appears only when there IS a second way: a draft has a shareable URL and nothing
              else does. Opening that link never touches the toggle — it is a different surface, in
              a different tab. --%>
        <div
          data-role="pb-preview"
          class="relative flex-none"
          phx-click-away={menu_close("#pb-preview-ways")}
        >
          <span class="flex">
            <.bar_button
              id="pb-preview"
              joined={@shareable_draft?}
              event="toggle_preview"
              value={%{}}
              icon={:eye}
              label={gettext("Preview")}
              active={@preview?}
              tone={:green}
            />
            <%!-- Joined to the button, the way the stage control is: one control that acts on the
                  left and offers its other way on the right, not two squares that happen to be
                  adjacent. --%>
            <button
              :if={@shareable_draft?}
              id="pb-preview-menu"
              type="button"
              phx-click={menu_toggle("#pb-preview-ways")}
              title={gettext("More ways to preview")}
              class="grid h-8 w-7 flex-none place-items-center rounded-r-[9px] border border-l-[#ecebe6] border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
            >
              <.icon name={:chevron} size={12} class="rotate-90" />
            </button>
          </span>
          <div
            :if={@shareable_draft?}
            id="pb-preview-ways"
            phx-window-keydown={menu_close("#pb-preview-ways")}
            phx-key="escape"
            class="absolute right-0 top-[38px] z-[70] hidden w-[248px] rounded-[13px] border border-[#ecebe6] bg-white p-1.5 shadow-[0_18px_46px_rgba(20,18,26,.22)]"
          >
            <.link
              id="pb-preview-tab"
              phx-click={menu_close("#pb-preview-ways")}
              href={preview_href(@section, @draft, @editor)}
              target="_blank"
              class="flex w-full items-start gap-2.5 rounded-[9px] p-[9px] text-left hover:bg-[#f6f5f2]"
            >
              <.icon name={:rocket} size={15} class="mt-[1px] flex-none text-[#6d6a63]" />
              <span class="min-w-0 flex-1">
                <span class="block text-[12px] font-semibold text-[#1b1a18]">
                  {gettext("Open in a new tab")}
                </span>
                <span class="mt-0.5 block text-[10.5px] font-medium leading-[1.45] text-[#6d6a63]">
                  {gettext("The shareable link for “%{label}”",
                    label: MishkaCmsCore.Runtime.PageBuilder.Drafts.display_label(@draft.label)
                  )}
                </span>
              </span>
            </.link>
          </div>
        </div>
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
            title={autosave_title(@draft)}
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
              :if={@drafts_enabled?}
              type="button"
              id="pb-stage-drafts"
              phx-click={menu_close("#pb-stage-ways") |> JS.push("draft_sheet")}
              class="flex w-full items-start gap-[9px] rounded-[9px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2]"
            >
              <span class="grid size-[26px] flex-none place-items-center rounded-[8px] bg-[#f2f1ec] text-[#6d6a63]">
                <.icon name={:layers} size={13} />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block font-['Space_Grotesk'] text-[12px] font-bold text-[#1b1a18]">
                  {gettext("Draft history")}
                </span>
                <span class="mt-0.5 block text-[10.5px] font-medium leading-[1.45] text-[#6d6a63]">
                  {gettext("Every saved draft of this page — open one, or save this as a new one.")}
                </span>
              </span>
            </button>
            <span :if={@drafts_enabled?} class="my-[3px] block h-px bg-[#f0efea]"></span>
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

  # A DRAFT IS THE ONLY THING WITH A SECOND WAY TO PREVIEW IT: a URL somebody who is not editing can
  # open. Without one there is nothing behind the caret, and a caret with nothing behind it turns a
  # one-click toggle into a choice.
  defp shareable_draft?(%{preview_token: token}) when is_binary(token) and token != "", do: true
  defp shareable_draft?(_none), do: false

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
  attr(:selected_node, :any, default: nil)
  attr(:attr_form, :any, default: nil)

  attr(:typed, :map,
    default: %{},
    doc: "what the panels' forms hold, typed and not yet applied, by form id — see `typed_in/4`"
  )

  attr(:breakpoint, :atom, default: :base)
  attr(:pseudo, :atom, default: :base)
  attr(:focus_attr, :string, default: nil)
  attr(:group_folds, :map, default: %{})
  attr(:style_tokens, :list, default: [])
  attr(:icon_picker, :string, default: nil)
  attr(:icon_query, :string, default: "")
  attr(:icon_library, :any, default: nil)
  attr(:icon_variant, :string, default: nil)
  attr(:element_css, :string, default: "")
  attr(:element_css_error, :string, default: nil)
  attr(:element_css_advice, :string, default: nil)
  attr(:js_hooks, :list, default: [])

  attr(:fragments, :map,
    default: %{},
    doc: "the page's stored code: `events`, `infos` and `helpers` entries"
  )

  attr(:rename_origin, :any,
    default: nil,
    doc: "the selected form as it was when its rename began, which the rename warning reads"
  )

  attr(:retagged, :map,
    default: %{},
    doc: "the stored handler names a pending rename moves onto its form's tagged names"
  )

  attr(:code_allowed?, :boolean,
    default: false,
    doc: "whether the author may write the page's code"
  )

  attr(:section, :string, default: "page", doc: "which of the four documents is being edited")

  # The record is here for the Expression section, which offers what THIS document declares — a
  # component's own attributes and slots — rather than a vocabulary written into the editor.
  attr(:record, :any, default: nil)

  # Who is looking, for the Inspector's way into a component's own editor — see
  # `component_editor_path/3`.
  attr(:current_user, :any, default: nil)

  attr(:aim_target, :string,
    default: nil,
    doc: "the node id in the On-click target select right now, before it is saved"
  )

  attr(:act_action, :string,
    default: nil,
    doc: "the verb in the On-click action select right now, which decides what box sits under it"
  )

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
                  {:inspector, gettext("Inspector"), :sliders}
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
        <.inspector
          :if={@left_tab == :inspector}
          editor={@editor}
          selected_node={@selected_node}
          attr_form={@attr_form}
          typed={@typed}
          breakpoint={@breakpoint}
          pseudo={@pseudo}
          focus_attr={@focus_attr}
          group_folds={@group_folds}
          style_tokens={@style_tokens}
          icon_picker={@icon_picker}
          icon_query={@icon_query}
          icon_library={@icon_library}
          icon_variant={@icon_variant}
          element_css={@element_css}
          element_css_error={@element_css_error}
          element_css_advice={@element_css_advice}
          js_hooks={@js_hooks}
          fragments={@fragments}
          rename_origin={@rename_origin}
          retagged={@retagged}
          code_allowed?={@code_allowed?}
          section={@section}
          record={@record}
          aim_target={@aim_target}
          act_action={@act_action}
          current_user={@current_user}
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
        <section
          :for={{group, group_entries} <- grouped_entries(@entries)}
          data-role="pb-group"
          data-group={group}
          class="mb-4"
        >
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
                  "relative flex h-[92px] w-full cursor-grab flex-col items-center gap-2 rounded-[12px] border px-2 pb-[11px] pt-[13px]",
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
                <%!-- WHICH KIND THIS ONE IS, on the glyph rather than in a corner: both corners of
                      the card are taken (scope, examples) and the label beneath can run to two
                      lines. A live component answers clicks and keeps state and a function
                      component cannot, so two cards that look identical are two cards a reader
                      cannot choose between. --%>
                <span class="relative flex-none">
                  <span
                    class="grid size-[30px] place-items-center rounded-[9px]"
                    style={"background:#{category_tint(entry.type)};color:#{category_dot(entry.type)}"}
                  >
                    <.icon name={entry_icon(entry)} size={16} />
                  </span>
                  <span
                    :if={PaletteEntry.optional(entry, :stateful?)}
                    data-role="pb-livedot"
                    title={gettext("Live component — keeps its own state and answers its own events")}
                    class="absolute -bottom-[3px] -right-[3px] grid size-[13px] place-items-center rounded-full border border-white bg-[#4f4bcc] text-white"
                  >
                    <.icon name={:bolt} size={8} />
                  </span>
                </span>
                <span class="line-clamp-2 w-full flex-none text-center text-[10.5px] font-semibold leading-[1.3] text-[#3a382f] [word-break:break-word]">
                  {short_label(entry, @kit_prefixes)}
                </span>
              </button>
              <%!-- The examples affordance sits over the card's top-left corner rather than inside
                    its flow, so a card with variants is the same size as one without. --%>
              <button
                :if={
                  PaletteEntry.optional(entry, :has_examples?) ||
                    PaletteEntry.optional(entry, :offers_options?)
                }
                type="button"
                data-role="pb-variantbtn"
                phx-click="show_examples"
                phx-value-name={entry.name}
                aria-label={gettext("Browse examples for %{name}", name: entry.name)}
                title={gettext("Browse the example variants of this component")}
                class="absolute left-px top-px grid size-6 place-items-center"
              >
                <span
                  data-role="pb-variantdot"
                  class="pointer-events-none grid size-[15px] place-items-center rounded-[4px] bg-[#fbf1df] font-['Space_Grotesk'] text-[10px] font-bold leading-none text-[#8a5514]"
                >
                  !
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
                    class="h-[92px] animate-pulse rounded-[13px] border border-[#f0efea] bg-[#faf9f6]"
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

  # THE SAME MENU IN BOTH PLACES, written once. The canvas and the layers rail are separate
  # LiveViews; a menu authored twice is a menu whose two halves drift, and the entry that drifts
  # first is always Delete.
  @context_menu [
    [
      %{action: "duplicate", label: gettext_noop("Duplicate"), icon: :copy, keys: "⌘D"},
      %{
        action: "visibility",
        label: gettext_noop("Hide from visitors"),
        icon: :eye_off,
        keys: "⇧⌘H"
      },
      %{action: "wrap", label: gettext_noop("Wrap in a container"), icon: :box, keys: nil},
      %{action: "link", label: gettext_noop("Make it a link"), icon: :link, keys: nil}
    ],
    [
      %{action: "copy", label: gettext_noop("Copy"), icon: :copy, keys: "⌘C"},
      %{action: "cut", label: gettext_noop("Cut"), icon: :crop, keys: "⌘X"},
      %{action: "paste", label: gettext_noop("Paste after"), icon: :attach, keys: "⌘V"}
    ],
    [
      %{action: "copy_styles", label: gettext_noop("Copy styles"), icon: :sliders, keys: nil},
      %{action: "paste_styles", label: gettext_noop("Paste styles"), icon: :sliders, keys: nil}
    ],
    [
      %{action: "snippet", label: gettext_noop("Save as snippet"), icon: :draft, keys: nil},
      %{action: "delete", label: gettext_noop("Delete"), icon: :trash, keys: "⌫"}
    ]
  ]

  attr(:find, :string, default: "")
  attr(:replace, :string, default: "")
  attr(:hits, :list, default: [])

  @doc """
  Find and replace over the page's WORDS.

  Deliberately not over the markup: a page says "Contact Us" in four places and the fifth is a class
  called `contact-us`. Renaming the company should not touch the CSS, so class names, attributes and
  expressions are out of reach here — the code drawer is where those are edited, by someone who
  means to.
  """
  def find_modal(assigns) do
    ~H"""
    <div
      id="pb-find"
      class="fixed inset-0 z-[92] flex items-start justify-center bg-[#17161a]/[.42] px-5 pt-[12vh]"
      phx-mounted={modal_in("#pb-find > section")}
      phx-remove={modal_out("#pb-find > section")}
      phx-window-keydown="close_find"
      phx-key="escape"
    >
      <section
        phx-click-away="close_find"
        class="flex max-h-[70vh] w-full max-w-[560px] flex-col overflow-hidden rounded-[16px] bg-white shadow-[0_30px_80px_rgba(20,18,26,.4)]"
      >
        <form
          id="pb-find-form"
          phx-change="find_query"
          phx-submit="find_query"
          class="flex flex-none gap-2 border-b border-[#f0efea] p-3.5"
        >
          <div class="relative flex-1">
            <.icon
              name={:search}
              size={14}
              class="pointer-events-none absolute left-[11px] top-1/2 -translate-y-1/2 text-[#a8a5a0]"
            />
            <input
              type="text"
              name="find"
              id="pb-find-input"
              value={@find}
              autocomplete="off"
              phx-debounce="150"
              placeholder={gettext("Find in the page's text…")}
              class="peer h-[38px] w-full rounded-[10px] border border-[#ecebe6] bg-[#faf9f6] pl-[34px] pr-[30px] text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white"
            />
            <%!-- One form, two fields, one handler that reads both — so clearing either has to
                  restate the other, or "clear the search" would silently throw away the replacement
                  the author had typed beside it. --%>
            <.clear_field
              field="pb-find-input"
              event="find_query"
              params={%{"find" => "", "replace" => @replace}}
            />
          </div>
          <div class="relative w-[180px] flex-none">
            <input
              type="text"
              name="replace"
              id="pb-replace-input"
              value={@replace}
              autocomplete="off"
              phx-debounce="150"
              placeholder={gettext("Replace with…")}
              class="peer h-[38px] w-full rounded-[10px] border border-[#ecebe6] bg-[#faf9f6] pl-3 pr-[30px] text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white"
            />
            <.clear_field
              field="pb-replace-input"
              event="find_query"
              params={%{"find" => @find, "replace" => ""}}
            />
          </div>
        </form>

        <%!-- Each hit is a way IN as well as a count: pressing one selects that element, which is
              usually what someone wanted from a search in the first place. --%>
        <div class="min-h-0 flex-1 overflow-y-auto p-2">
          <p
            :if={@hits == [] and String.trim(@find) != ""}
            id="pb-find-none"
            class="px-2.5 py-8 text-center text-[12px] font-medium text-[#6d6a63]"
          >
            {gettext("No text on this page says that.")}
          </p>
          <p
            :if={String.trim(@find) == ""}
            class="px-2.5 py-8 text-center text-[12px] font-medium text-[#a8a5a0]"
          >
            {gettext("Type to search the words on this page.")}
          </p>
          <button
            :for={hit <- @hits}
            type="button"
            id={"pb-find-hit-#{hit.id}"}
            phx-click="select"
            phx-value-id={hit.id}
            class="flex w-full items-center gap-2.5 rounded-[9px] px-2.5 py-2 text-left hover:bg-[#f2f1fc]"
          >
            <span class="grid size-[15px] flex-none place-items-center text-[#6d6a63]">
              <.icon name={:text} size={12} />
            </span>
            <span class="min-w-0 flex-1 truncate text-[11.5px] font-medium text-[#3a382f]">
              {String.trim(hit.text)}
            </span>
            <span
              :if={hit.count > 1}
              class="flex-none font-['Space_Grotesk'] text-[10px] font-bold text-[#6d6a63]"
            >
              ×{hit.count}
            </span>
          </button>
        </div>

        <div class="flex flex-none items-center gap-2 border-t border-[#f0efea] px-3.5 py-2.5">
          <span class="flex-1 text-[11px] font-semibold text-[#6d6a63]">
            {find_summary(@hits)}
          </span>
          <button
            type="button"
            phx-click="close_find"
            class="h-8 flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[11.5px] font-semibold text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            {gettext("Close")}
          </button>
          <%!-- ONE UNDO STEP for the whole sweep. Forty entries would mean forty presses to get back
                to where you were, and no way to tell which of them was the accident. --%>
          <button
            type="button"
            id="pb-find-replace-all"
            phx-click="replace_all"
            disabled={@hits == []}
            class="h-8 flex-none rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3 font-['Space_Grotesk'] text-[11.5px] font-bold text-white disabled:opacity-40"
          >
            {gettext("Replace all")}
          </button>
        </div>
      </section>
    </div>
    """
  end

  defp find_summary([]), do: gettext("Nothing to replace")

  defp find_summary(hits) do
    total = Enum.reduce(hits, 0, &(&1.count + &2))
    places = length(hits)

    ngettext("%{count} match in %{places}", "%{count} matches in %{places}", total,
      places: ngettext("%{count} place", "%{count} places", places)
    )
  end

  attr(:id, :string, required: true)

  attr(:target, :string,
    required: true,
    doc: "the selector for a row or node this menu belongs to — what a right-click has to land on"
  )

  attr(:key, :string,
    required: true,
    doc: "the dataset key on that element holding the node id — `nodeId` or `layerRow`"
  )

  @doc """
  The right-click menu, for a canvas node or a layers row.

  Nothing in here is dynamic, deliberately: the hook stamps the node it was opened on and pushes the
  action itself, so opening the menu costs no round trip and no patch can arrive mid-gesture and
  replace the row under the pointer. See `Hooks.PbContextMenu`.
  """
  def context_menu(assigns) do
    assigns = assign(assigns, :groups, @context_menu)

    ~H"""
    <div
      id={@id}
      phx-hook="PbContextMenu"
      data-target={@target}
      data-key={@key}
      data-hidden="false"
      hidden
      class="group/ctx fixed z-[95] w-[216px] rounded-[13px] border border-[#ecebe6] bg-white p-1.5 shadow-[0_18px_46px_rgba(20,18,26,.22)]"
    >
      <div
        :for={{group, index} <- Enum.with_index(@groups)}
        class={["flex flex-col", index > 0 && "mt-1 border-t border-[#f4f3ef] pt-1"]}
      >
        <button
          :for={item <- group}
          type="button"
          data-action={item.action}
          class={[
            "flex w-full items-center gap-2.5 rounded-[9px] px-2 py-[6px] text-left",
            "text-[11.5px] font-semibold text-[#3a382f] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]",
            item.action == "delete" && "hover:bg-[#fdf3f1] hover:text-[#c0473d]"
          ]}
        >
          <%!-- ONE ENTRY, TWO WORDS. The menu is drawn once for every node, so the hook marks it with
                whether the node it opened on is hidden from visitors, and the entry says what a
                click will do. --%>
          <span
            :if={item.action != "visibility"}
            class="grid size-[15px] flex-none place-items-center text-[#6d6a63]"
          >
            <.icon name={item.icon} size={13} />
          </span>
          <span :if={item.action != "visibility"} class="flex-1 truncate">
            {translate(item.label)}
          </span>
          <span
            :if={item.action == "visibility"}
            class="grid size-[15px] flex-none place-items-center text-[#6d6a63]"
          >
            <.icon name={:eye_off} size={13} class="group-data-[hidden=true]/ctx:hidden" />
            <.icon name={:eye} size={13} class="hidden group-data-[hidden=true]/ctx:block" />
          </span>
          <span :if={item.action == "visibility"} class="flex-1 truncate">
            <span class="group-data-[hidden=true]/ctx:hidden">{translate(item.label)}</span>
            <span class="hidden group-data-[hidden=true]/ctx:inline">
              {gettext("Show to visitors")}
            </span>
          </span>
          <span
            :if={item.keys}
            class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#a8a5a0]"
          >
            {item.keys}
          </span>
        </button>
      </div>
    </div>
    """
  end

  @doc "Every action the right-click menu can send — the list both LiveViews validate against."
  @spec context_actions() :: [String.t()]
  def context_actions,
    do: Enum.flat_map(@context_menu, fn group -> Enum.map(group, & &1.action) end)

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

  @form_part_words %{
    form: gettext_noop("Form"),
    field: gettext_noop("Field"),
    submit: gettext_noop("Submit button"),
    not_submit: gettext_noop("Button · does not send the form"),
    button: gettext_noop("Button")
  }

  attr(:part, :atom, default: nil)

  # The selected node's part in a form, in plain words.
  defp form_part(assigns) do
    assigns = assign(assigns, :words, Map.get(@form_part_words, assigns.part))

    ~H"""
    <span
      :if={@words}
      id="pb-form-part"
      data-part={@part}
      class="mt-1 inline-flex w-fit items-center gap-1.5 rounded-full border border-[#dcdbf5] bg-white px-2 py-[2px] font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc]"
    >
      <span class={[
        "size-1.5 flex-none rounded-full",
        (@part == :not_submit && "bg-[#a8a5a0]") || "bg-[#4f4bcc]"
      ]}></span>
      {translate(@words)}
    </span>
    """
  end

  attr(:node, :any, required: true)
  attr(:hider, :any, required: true)

  # HIDDEN FROM VISITORS, said where the element is being edited, with the way back: Show for the one
  # that was hidden, the element that hides it for one inside it. See `PageBuilder.Visibility`.
  defp hidden_note(assigns) do
    ~H"""
    <div
      :if={@hider}
      id="pb-insp-hidden"
      class="flex items-center gap-2.5 rounded-[12px] border border-[#e6e4de] bg-[#faf9f6] px-3 py-2.5"
    >
      <.icon name={:eye_off} size={14} class="flex-none text-[#8a877f]" />
      <span class="min-w-0 flex-1 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]">
        {(@hider.id == @node.id &&
            gettext("Hidden from visitors. It stays in the page, with everything inside it.")) ||
          gettext("Hidden from visitors with the element around it.")}
      </span>
      <button
        :if={@hider.id == @node.id}
        type="button"
        id="pb-insp-show"
        phx-click="toggle_visibility"
        phx-value-id={@node.id}
        class="inline-flex h-[26px] flex-none items-center gap-1.5 rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
      >
        <.icon name={:eye} size={12} /> {gettext("Show")}
      </button>
      <button
        :if={@hider.id != @node.id}
        type="button"
        id="pb-insp-select-hider"
        phx-click="select"
        phx-value-id={@hider.id}
        class="inline-flex h-[26px] flex-none items-center gap-1.5 rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
      >
        <.icon name={:layers} size={12} /> {gettext("Select it")}
      </button>
    </div>
    """
  end

  defp inspector(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col overflow-y-auto px-3.5 pb-4 pt-3.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      <p :if={!@selected_node} class="py-10 text-center text-[12px] font-medium text-[#a8a5a0]">
        {gettext("Select an element on the canvas to edit it.")}
      </p>

      <div :if={@selected_node} class="flex flex-col gap-[14px]">
        <div class="flex items-center gap-2.5 rounded-[12px] border border-[#e4e2f7] bg-[#f2f1fc] px-3 py-2.5">
          <span class="grid size-[30px] flex-none place-items-center rounded-[9px] bg-[#e4e2f7] text-[#4f4bcc]">
            <.icon name={:layers} size={15} />
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex min-w-0 items-center gap-1.5">
              <div class="truncate font-['Space_Grotesk'] text-[12.5px] font-bold text-[#2e2b6b]">
                {selection_tag(@selected_node)}
              </div>
              <%!-- SAID ONCE, WHERE THE READER IS LOOKING AT THE THING. A live component answers
                    clicks and keeps state; a function component cannot, and on the canvas neither
                    of them does — the frame draws markup, not a running component. Without this the
                    two are the same panel over two different capabilities, and the author finds out
                    which by publishing. --%>
              <span
                :if={PaletteEntry.optional(component_entry(assigns), :stateful?)}
                data-role="pb-insp-kind"
                title={
                  gettext(
                    "A Phoenix LiveComponent: on the published page it keeps its own state and answers its own events."
                  )
                }
                class="inline-flex flex-none items-center gap-1 rounded-full bg-[#f2f1fc] px-1.5 py-[1px] font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc]"
              >
                <.icon name={:bolt} size={9} /> {gettext("Live")}
              </span>
            </div>
            <%!-- AND WHY NOTHING IN THE FRAME RESPONDS. The canvas draws a live component's own
                  markup in its cold state — `@myself` is nil, so `phx-target` renders away and no
                  click reaches anything. Without this line an author presses the component's own
                  button, nothing happens, and the only available conclusion is that they built it
                  wrong.

                  IT USED TO SAY PREVIEW WAS WHERE IT RUNS, and that stopped being true when Preview
                  took the same cold path: an author who believed it toggled Preview, clicked again,
                  and was told nothing new. The published page is the only place it runs; the
                  new-tab preview reads its address, so a pager built on the URL pages there too. --%>
            <div
              :if={PaletteEntry.optional(component_entry(assigns), :stateful?)}
              data-role="pb-insp-cold"
              class="mt-[3px] text-[10px] font-medium leading-[1.45] text-[#6d6a63]"
            >
              {gettext(
                "Drawn with its first page of real data. Its buttons and state run on the published page; paging by URL also works in the new-tab preview."
              )}
            </div>
            <div class="text-[10.5px] font-medium text-[#6d6a63]">
              {selection_meta(@selected_node)}
            </div>
            <.form_part part={Inspector.form_part(@editor, @selected_node)} />
            <%!-- WHERE THE AUTHOR IS LOOKING. The only way into a component's own editor was an icon
                  on its layers row that shows on hover, so someone looking at a live list in the
                  Inspector had no way to change what it draws. Same tab, with the way back in the
                  address; the leave guard still stands between this and unsaved work. --%>
            <.link
              :if={component_editor_path(component_entry(assigns), @editor, @current_user)}
              id="pb-insp-edit-component"
              navigate={component_editor_path(component_entry(assigns), @editor, @current_user)}
              title={
                gettext(
                  "Edit the ORIGINAL %{name} — its markup is shared, so this changes every page using it",
                  name: component_entry(assigns).name
                )
              }
              class="mt-1.5 inline-flex h-6 items-center gap-1.5 rounded-[7px] border border-[#dcdbf5] bg-white px-2 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f7f6ff]"
            >
              {gettext("Edit component")} <.icon name={:external} size={11} />
            </.link>
          </div>
          <%!-- THE KIT ALREADY SAYS WHERE ITS DOCS ARE. Every Chelekom component carries a `doc_url`
                and nothing read it, so someone stuck on what `variant` means had the answer sitting
                in the database with no way to reach it. Here, beside the name of the thing they are
                stuck on. Opens in a new tab: the editor holds unsaved work. --%>
          <a
            :if={docs_url(component_entry(assigns))}
            id="pb-docs-link"
            href={docs_url(component_entry(assigns))}
            target="_blank"
            rel="noopener noreferrer"
            title={gettext("Open this component's documentation")}
            class="inline-flex h-7 flex-none items-center gap-1.5 rounded-[8px] border border-[#dcdbf5] bg-white px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f7f6ff]"
          >
            {gettext("Docs")} <.icon name={:external} size={11} />
          </a>
        </div>

        <.hidden_note
          node={@selected_node}
          hider={Visibility.hidden_by(@editor.tree, @selected_node.id)}
        />

        <%!-- A component's own properties and slots come FIRST. They are what the component is; the
              breakpoint, state and box controls under them apply to any element and are the same
              everywhere. --%>
        <.props
          :if={component_entry(assigns)}
          entry={component_entry(assigns)}
          node={@selected_node}
          hidden={panel_owned(@selected_node, @section)}
          focus={@focus_attr}
          icon_picker={@icon_picker}
          icon_query={@icon_query}
          icon_variant={@icon_variant}
          icon_library={@icon_library}
          group_folds={@group_folds}
          typed={@typed}
        />

        <%!-- A SLOT AN AUTHOR HAS TO ADD IS NOT A DETAIL. Folded, the row that says "End section +"
              was the one thing a field could not be built without — the only way to put a button
              inside an input's border — and nobody found it. A component with nothing but an
              inner_block has nothing to add here and stays folded. --%>
        <.inspector_group
          :if={slot_entries(assigns) != [] or inner_block_slot?(assigns)}
          title={gettext_noop("Slots")}
          group_folds={@group_folds}
          folded_by_default={slot_entries(assigns) == []}
        >
          <div class="flex flex-col gap-1.5">
            <div
              :for={slot <- slot_entries(assigns)}
              class="flex items-center justify-between gap-2 rounded-[8px] bg-[#faf9f6] px-2.5 py-1.5"
            >
              <span class="truncate font-['Space_Grotesk'] text-[11px] font-bold text-[#5c5a54]">
                {Inspector.label(slot)}
              </span>
              <button
                type="button"
                id={"pb-slot-add-inspector-#{Inspector.name(slot)}"}
                phx-click="op"
                phx-value-kind="insert"
                phx-value-parent_id={@selected_node.id}
                phx-value-template={"<:#{Inspector.name(slot)}></:#{Inspector.name(slot)}>"}
                class="shrink-0 rounded-[6px] px-1.5 py-0.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f2f1fc]"
              >
                {gettext("+ Add")}
              </button>
            </div>
            <%!-- The inner content gets a line of its own rather than an Add button. `<:inner_block>`
                  is not writable — the HEEx compiler rejects the name — and the thing it stands for is
                  filled by putting elements IN the component, which is what this says. --%>
            <p
              :if={inner_block_slot?(assigns)}
              id="pb-slot-inner-block"
              class="rounded-[8px] bg-[#faf9f6] px-2.5 py-1.5 text-[10.5px] font-medium leading-[1.55] text-[#6d6a63]"
            >
              <span class="font-['Space_Grotesk'] text-[11px] font-bold text-[#5c5a54]">
                {gettext("Inner block")}
              </span>
              {gettext(
                "— drop an element onto this component, or pick one from the palette and click it, to fill its content."
              )}
            </p>
          </div>
        </.inspector_group>

        <%!-- THE CHIP ON THE CANVAS PROMISED THIS AND IT DID NOT EXIST. An expression's own title
              attribute read "edit its source in the inspector"; the inspector had nothing for one, so
              `{@inner_content}` in a layout and `{render_slot(@inner_block)}` in a component — the
              two expressions those documents are BUILT on — could be seen, selected, moved and
              deleted, and changed only by opening the code drawer.

              A plain text box rather than a picker, because what goes in it is Elixir and the editor
              has no business narrowing that. It writes through `set_text`, the op that already exists
              for exactly this shape: the serializer emits an `:eex` node's text back into `{…}` or
              `<%= … %>` depending on how it was written, so the form it was authored in survives. --%>
        <.expression_section
          :if={expression_node?(@selected_node)}
          node={@selected_node}
          section={@section}
          record={@record}
          group_folds={@group_folds}
        />

        <%!-- A FORM IS A THING WITH HANDLERS BEHIND IT. Every control here writes `phx-change`,
              `phx-submit` or the `for=` they are bound through — `Inspector.rename_ops/3` rewrites
              all three together — and only a document with an `events` column has anywhere to put
              the handlers they name. On the other three the section renamed a form into handlers
              that could not exist. --%>
        <.rule_section
          :if={Inspector.form_node?(@selected_node) and handles_events?(@section)}
          title={gettext_noop("Form")}
          controls={Inspector.form_controls(@selected_node, @editor)}
          node={@selected_node}
          warning={
            Inspector.rename_warning(
              renamed_from(@rename_origin, @selected_node),
              @fragments,
              @code_allowed?
            )
          }
          group_folds={@group_folds}
        >
          <.form_handlers_card
            node={@selected_node}
            code_allowed?={@code_allowed?}
            entries={pending_entries(Map.get(@fragments, :events, []), @editor.tree, @retagged)}
            record={@record}
          />
        </.rule_section>

        <.idle_form
          :if={FormPlacement.page_forms?(@editor)}
          node={@selected_node}
          state={Inspector.form_state(@selected_node, @editor.components)}
          entries={Map.get(@fragments, :events, [])}
          components={@editor.components}
        />

        <.form_phoenix
          :if={Inspector.form_node?(@selected_node) and handles_events?(@section)}
          node={@selected_node}
          editor={@editor}
          group_folds={@group_folds}
        />

        <.merge_form_row
          :if={Inspector.form_node?(@selected_node) and handles_events?(@section)}
          node={@selected_node}
          targets={merge_targets(@editor, @selected_node)}
        />

        <%!-- MOSTLY BROWSER-ENFORCED, AND TWO THAT ARE NOT. `required`, `minlength`, `maxlength`,
              `min`, `max` and `pattern` are HTML attributes every browser checks on its own, so
              they belong in all four documents. `format` and `confirms` write `data-format` and
              `data-confirms`, which nothing checks but `MishkaCmsCore.Runtime.PageForm.Rules` —
              wired up only by the compiler that also emits the handlers. Offered where that runs. --%>
        <.rule_section
          :if={Inspector.validated_node?(@editor.tree, @selected_node)}
          title={gettext_noop("Validation")}
          controls={validation_controls(@section)}
          node={@selected_node}
          note={validation_note(@editor.tree, @selected_node)}
          form_id={owning_form_id(@editor, @selected_node)}
          group_folds={@group_folds}
        />

        <.in_form_section
          :if={
            FormPlacement.page_forms?(@editor) and
              FormPlacement.field?(@editor.tree, @selected_node, @editor.components)
          }
          node={@selected_node}
          editor={@editor}
          group_folds={@group_folds}
        />

        <.rule_section
          :if={handles_events?(@section) and field_in_form?(@editor, @selected_node)}
          title={gettext_noop("Field options")}
          controls={
            Inspector.field_controls(@selected_node, @editor.components,
              code_allowed?: @code_allowed?,
              form: Inspector.owning_form(@editor.tree, @selected_node)
            )
          }
          node={@selected_node}
          group_folds={@group_folds}
        >
          <button
            :if={@code_allowed?}
            type="button"
            id="pb-field-code-link"
            phx-click="open_source"
            phx-value-tab="events"
            class="h-7 w-full rounded-[8px] border border-[#dcdbf5] bg-white text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f7f6ff]"
          >
            {gettext("Write their code in Code ›")}
          </button>
        </.rule_section>

        <.send_section
          :if={
            handles_events?(@section) and
              Inspector.form_part(@editor, @selected_node) in [:submit, :not_submit]
          }
          node={@selected_node}
          editor={@editor}
          group_folds={@group_folds}
        />

        <%!-- THE BREAKPOINT IS A TAB, AND WHAT IT GOVERNS SITS INSIDE IT. It used to be a folded
              group of three buttons with State, Layout and Appearance as its SIBLINGS — nothing said
              those sections were the tab's contents, so an author who left the panel on Mobile and
              came back later read the Layout numbers as the element's, not as a mobile override, and
              edited the wrong breakpoint. Drawing the body joined to the active tab says it once, in
              a way nobody has to be told.

              Component properties stay ABOVE this on purpose: a property is one value for the whole
              page, and putting it inside a breakpoint would promise a per-device version that does
              not exist. Everything below the strip is per-breakpoint; everything above is not.

              The count on a tab is the only way to SEE that a page carries mobile overrides without
              opening each one — the thing that makes a responsive edit findable a week later. --%>
        <div :if={styleable?(@selected_node)}>
          <div
            data-role="pb-bptabs"
            class="flex gap-1 rounded-t-[12px] border border-b-0 border-[#e6e4de] bg-[#f2f1ec] p-1"
          >
            <%!-- The breakpoint travels in the button's OWN `value`, not in `phx-value-value`.
                  `View.extractMeta` writes `meta.value = el.value` after collecting the `phx-value-*`
                  attributes, and a button's `value` is `""` unless it is given one — so the two
                  collide and the server was told `%{"value" => ""}` every time. Every tab in this
                  panel picked the first option no matter which one was clicked, which reads as "the
                  tabs are dead". --%>
            <button
              :for={{bp, label, icon, tip} <- breakpoint_tabs()}
              type="button"
              id={"pb-bp-#{bp}"}
              phx-click="set_breakpoint"
              value={bp}
              title={tip}
              aria-pressed={to_string(@breakpoint == bp)}
              class={[
                "flex h-[30px] min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden rounded-[8px] text-[10.5px] font-bold",
                (@breakpoint == bp && "bg-white text-[#4f4bcc] shadow-[0_1px_3px_rgba(30,28,24,.12)]") ||
                  "text-[#6d6a63]"
              ]}
            >
              <.icon name={icon} size={12} class="flex-none" />
              <span class="min-w-0 truncate">{label}</span>
              <span
                :if={override_count(@selected_node, bp) > 0}
                id={"pb-bp-count-#{bp}"}
                title={gettext("%{count} set here", count: override_count(@selected_node, bp))}
                class={[
                  "grid size-[15px] flex-none place-items-center rounded-full font-['Space_Grotesk'] text-[9px] font-bold",
                  (@breakpoint == bp && "bg-[#e4e2f7] text-[#4f4bcc]") ||
                    "bg-[#e0ded7] text-[#6d6a63]"
                ]}
              >
                {override_count(@selected_node, bp)}
              </span>
            </button>
          </div>

          <div class="flex flex-col gap-[14px] rounded-b-[12px] border border-[#e6e4de] bg-white px-3 py-[13px]">
            <p class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
              {breakpoint_note(@breakpoint)}
            </p>

            <section>
              <.fold_heading
                title={gettext_noop("State")}
                group_folds={@group_folds}
                folded_by_default={true}
              >
                <:meta>
                  <span
                    :if={@pseudo != :base}
                    id="pb-state-recorded"
                    class="inline-flex items-center gap-1.5 rounded-full border border-[#f0e3c9] bg-[#fbf1df] px-2 py-0.5 text-[10px] font-bold text-[#8a5514]"
                  >
                    <span class="size-[5px] rounded-full bg-[#cf8a24]"></span>{gettext("Recorded")}
                  </span>
                </:meta>
              </.fold_heading>
              <div
                :if={!folded?(@group_folds, "section", "State", dense_panel?(assigns))}
                class="flex flex-wrap gap-1"
              >
                <button
                  :for={
                    {ps, label} <- [
                      {:base, gettext("Normal")},
                      {:hover, ":hover"},
                      {:focus, ":focus"},
                      {:active, ":active"}
                    ]
                  }
                  type="button"
                  id={"pb-state-#{ps}"}
                  phx-click="set_pseudo"
                  value={ps}
                  class={[
                    "h-[26px] flex-none rounded-full border px-2.5 font-['Space_Grotesk'] text-[10px] font-semibold",
                    (@pseudo == ps && "border-[#17161a] bg-[#17161a] text-white") ||
                      "border-[#ecebe6] bg-[#f6f5f2] text-[#6d6a63]"
                  ]}
                >
                  {label}
                </button>
              </div>
              <p
                :if={!folded?(@group_folds, "section", "State", dense_panel?(assigns))}
                class="mt-1.5 text-[10px] font-medium leading-[1.5] text-[#6d6a63]"
              >
                {state_note(@pseudo)}
              </p>
            </section>

            <%!-- Layout and Appearance write STYLE overrides into the bucket the tab strip and the
                  State chips choose, which is what makes those selectors mean something. Without
                  these controls the breakpoint tabs pick a bucket nothing ever writes to. --%>
            <%!-- OPEN, because spacing is the first thing anyone reaches for and it was three folds
                  and a scroll away. `group_folds` still remembers a deliberate collapse. --%>
            <.style_group
              title={gettext_noop("Layout")}
              group_folds={@group_folds}
              folded_by_default={false}
              props={layout_props()}
              node={@selected_node}
              bucket={write_bucket(assigns)}
              breakpoint={@breakpoint}
              pseudo={@pseudo}
              covered={covered_controls(@element_css, write_bucket(assigns))}
            >
              <:pre>
                <.layout_pictures
                  node={@selected_node}
                  bucket={write_bucket(assigns)}
                  covered={covered_controls(@element_css, write_bucket(assigns))}
                />

                <div class="mt-3">
                  <.spacing_box
                    node={@selected_node}
                    bucket={write_bucket(assigns)}
                    covered={covered_controls(@element_css, write_bucket(assigns))}
                  />
                </div>

                <div class="mt-2.5">
                  <.style_group
                    title={gettext_noop("Spacing by axis")}
                    group_folds={@group_folds}
                    folded_by_default={
                      !axes_in_play?(
                        @selected_node,
                        write_bucket(assigns),
                        covered_controls(@element_css, write_bucket(assigns))
                      )
                    }
                    props={axis_props()}
                    node={@selected_node}
                    bucket={write_bucket(assigns)}
                    breakpoint={@breakpoint}
                    pseudo={@pseudo}
                    covered={covered_controls(@element_css, write_bucket(assigns))}
                  />
                </div>
              </:pre>
            </.style_group>

            <.style_group
              title={gettext_noop("Typography")}
              group_folds={@group_folds}
              folded_by_default={false}
              props={typography_props()}
              node={@selected_node}
              bucket={write_bucket(assigns)}
              breakpoint={@breakpoint}
              pseudo={@pseudo}
              covered={covered_controls(@element_css, write_bucket(assigns))}
            />

            <section>
              <.fold_heading
                title={gettext_noop("Appearance")}
                group_folds={@group_folds}
                folded_by_default={false}
              />
              <div
                :if={!folded?(@group_folds, "section", "Appearance", false)}
                class="mb-[7px] flex items-center gap-1.5 text-[10.5px] font-semibold text-[#6d6a63]"
              >
                {gettext("Background")}
              </div>
              <div
                :if={!folded?(@group_folds, "section", "Appearance", false)}
                class="flex flex-wrap gap-[7px]"
              >
                <button
                  :for={{name, value, tint} <- swatches()}
                  type="button"
                  id={"pb-swatch-#{name}"}
                  phx-click="op"
                  phx-value-kind="set_style"
                  phx-value-node_id={@selected_node.id}
                  phx-value-bucket={write_bucket(assigns)}
                  phx-value-prop="background"
                  value={
                    (own_style(@selected_node, write_bucket(assigns), "background") == value && "") ||
                      value
                  }
                  title={gettext("Background %{value}", value: value)}
                  aria-pressed={
                    to_string(own_style(@selected_node, write_bucket(assigns), "background") == value)
                  }
                  class={[
                    "size-[34px] rounded-[9px] border-2",
                    tint,
                    (own_style(@selected_node, write_bucket(assigns), "background") == value &&
                       "border-[#5b57d6]") || "border-[#ecebe6]"
                  ]}
                ></button>

                <button
                  type="button"
                  id="pb-background-pick"
                  phx-click="pick_background"
                  phx-value-node_id={@selected_node.id}
                  phx-value-bucket={write_bucket(assigns)}
                  title={gettext("Use a picture from the media library as this element's background")}
                  aria-label={gettext("Choose a background picture")}
                  class="grid size-[34px] place-items-center rounded-[9px] border-2 border-dashed border-[#dcdbf5] bg-[#f7f6ff] text-[#4f4bcc] hover:border-[#c3c1f0]"
                >
                  <.icon name={:image} size={14} />
                </button>
              </div>

              <section :if={@style_tokens != []} class="mt-[13px]">
                <.fold_heading
                  title={gettext_noop("Site colours")}
                  group_folds={@group_folds}
                  folded_by_default={true}
                >
                  <:meta>
                    <span class="grid h-[15px] min-w-[15px] flex-none place-items-center rounded-full bg-[#e0ded7] px-1 font-['Space_Grotesk'] text-[9px] font-bold text-[#6d6a63]">
                      {length(@style_tokens)}
                    </span>
                  </:meta>
                </.fold_heading>

                <div
                  :if={!folded?(@group_folds, "section", "Site colours", true)}
                  class="flex flex-wrap gap-[7px]"
                >
                  <.token_swatch
                    :for={{key, value, label} <- @style_tokens}
                    node={@selected_node}
                    bucket={write_bucket(assigns)}
                    prop="background"
                    token={key}
                    value={value}
                    label={label}
                  />
                </div>
              </section>

              <div :if={!folded?(@group_folds, "section", "Appearance", false)} class="mt-[13px]">
                <.style_group
                  props={appearance_props()}
                  node={@selected_node}
                  bucket={write_bucket(assigns)}
                  breakpoint={@breakpoint}
                  pseudo={@pseudo}
                  covered={covered_controls(@element_css, write_bucket(assigns))}
                />
              </div>

              <div :if={!folded?(@group_folds, "section", "Appearance", false)} class="mt-[13px]">
                <.shadow_editor
                  node={@selected_node}
                  bucket={write_bucket(assigns)}
                  covered={covered_controls(@element_css, write_bucket(assigns))}
                />
              </div>
            </section>

            <%!-- Clearing ONE bucket, not the element's styles: the tab and the State chips name a
                  bucket, and this is how you undo what was written into it without hunting each
                  field's own reset dot. Absent when the bucket holds nothing, because a button that
                  would do nothing reads as one that is broken. --%>
            <button
              :if={bucket_written?(@selected_node, write_bucket(assigns))}
              type="button"
              id="pb-style-reset"
              phx-click="op"
              phx-value-kind="reset_styles"
              phx-value-node_id={@selected_node.id}
              phx-value-bucket={write_bucket(assigns)}
              class="inline-flex h-[26px] items-center gap-1.5 self-start rounded-[8px] border border-[#f0dcd8] bg-[#fdf3f1] px-2.5 text-[10.5px] font-bold text-[#c0473d] hover:bg-[#fbe9e7]"
            >
              <.icon name={:undo} size={12} /> {gettext("Clear %{bucket} overrides",
                bucket: bucket_label(write_bucket(assigns))
              )}
            </button>
          </div>
        </div>
        <div
          :if={!styleable?(@selected_node)}
          id="pb-not-styleable"
          class="flex flex-col gap-2 rounded-[12px] border border-[#e6e4de] bg-[#faf9f6] px-3 py-[13px]"
        >
          <p class="text-[10.5px] font-medium leading-[1.55] text-[#6d6a63]">
            {unstyleable_note(@selected_node)}
          </p>
          <p
            :if={raw_block?(@selected_node) and @selected_node.tag == "style"}
            id="pb-style-nonce-note"
            class="flex items-start gap-1 font-['Space_Grotesk'] text-[10px] leading-[1.35] text-[#a5691a]"
          >
            <.icon name={:shield} size={11} class="mt-[1px] flex-none" />
            <span>
              {gettext(
                "Saved with nonce={csp_nonce()}, this page's security nonce, so the browser applies it."
              )}
            </span>
          </p>
          <.link
            :if={raw_block?(@selected_node)}
            id="pb-raw-block-home"
            navigate={raw_block_home(@selected_node)}
            class="inline-flex h-[26px] items-center gap-1.5 self-start rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
          >
            <.icon name={:code} size={12} /> {raw_block_home_label(@selected_node)}
          </.link>
          <button
            :if={@selected_node.parent_id}
            type="button"
            id="pb-select-parent"
            phx-click="select"
            phx-value-id={@selected_node.parent_id}
            class="inline-flex h-[26px] items-center gap-1.5 self-start rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
          >
            <.icon name={:layers} size={12} /> {gettext("Style the element around it")}
          </button>
          <%!-- WHERE SOMEBODY HAS ALREADY POINTED AT THE WORDS. The right-click menu offers this on
                every node, but a run of text is the one selection whose panel is otherwise a dead
                end — and turning words into a link is the commonest thing an author wants from a
                run of text that is not editing it. --%>
          <button
            :if={@selected_node.kind == :text}
            type="button"
            id="pb-text-link"
            phx-click="ctx"
            phx-value-action="link"
            phx-value-node_id={@selected_node.id}
            class="inline-flex h-[26px] items-center gap-1.5 self-start rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
          >
            <.icon name={:link} size={12} /> {gettext("Make it a link")}
          </button>
        </div>

        <%!-- Each switch is a class the element either carries or does not, so the toggle reports the
              document's real state rather than a preference stored beside it. Visibility and locking
              are NOT here: those are session state and belong to the layers rail, which is where the
              prototype keeps them too. --%>
        <.inspector_group
          :if={styleable?(@selected_node)}
          title={gettext_noop("Behavior")}
          group_folds={@group_folds}
          folded_by_default={true}
        >
          <div class="flex flex-col">
            <.toggle_row
              :for={{key, label, _classes} <- behavior_toggles()}
              id={"pb-toggle-#{key}"}
              label={label}
              on={behavior_on?(@selected_node, key)}
              event="toggle_behavior"
              node_id={@selected_node.id}
              value={key}
            />
          </div>
        </.inspector_group>

        <%!-- Raw HTML attributes — `aria-label`, `data-*`, and `phx-hook` where one would attach. A
              COMPONENT has no use for them: what it accepts is declared, and the properties form
              above is where that is set, so this would be a second attribute editor disagreeing
              with the first. --%>
        <.inspector_group
          :if={
            (styleable?(@selected_node) or raw_block?(@selected_node)) and
              @selected_node.kind != :component
          }
          title={gettext_noop("Attributes")}
          group_folds={@group_folds}
          folded_by_default={true}
        >
          <div class="flex flex-col">
            <%!-- One bordered list, a violet key and its value beside it — the prototype's shape. The
                  value is editable here and each row can be removed, which its static mock could not
                  do; the row still reads the same. --%>
            <div
              :if={attr_rows(@selected_node) != []}
              class="overflow-hidden rounded-[11px] border border-[#ecebe6]"
            >
              <%!-- Rung when the add box below sends the reader here: a name typed into it that the
                    element already carries is refused rather than written over, and the row it was
                    refused in favour of is the whole of what says so. --%>
              <div
                :for={{name, kind, value} <- attr_rows(@selected_node)}
                id={"pb-attr-row-#{@selected_node.id}-#{name}"}
                class={[
                  "scroll-mt-4 border-b border-[#f4f3ee] px-[11px] py-[9px] last:border-b-0",
                  (@focus_attr == name && "bg-[#f7f6ff]") || "bg-[#faf9f6]"
                ]}
                phx-mounted={@focus_attr == name && JS.dispatch("pb:reveal")}
              >
                <div class="flex items-center gap-2">
                  <span class="flex-none font-['Space_Grotesk'] text-[10.5px] font-bold text-[#7a5bd0]">
                    {name}
                  </span>
                  <%!-- The box shows the expression's source, the same as a property box does, so the
                        mark is what says this one is code and not the words it looks like. --%>
                  <span
                    :if={kind == "expr"}
                    id={"pb-attr-row-expr-#{name}"}
                    title={
                      gettext("%{name} holds an expression — what is in the box is its source",
                        name: name
                      )
                    }
                    class="flex-none rounded-[5px] bg-[#f2f1fc] px-[5px] py-px font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc]"
                  >
                    ƒx
                  </span>
                  <.attr_row_control
                    node={@selected_node}
                    name={name}
                    kind={kind}
                    value={value}
                    widget={Inspector.element_widget(@selected_node.tag, name)}
                  />
                  <button
                    type="button"
                    phx-click="op"
                    phx-value-kind="delete_attr"
                    phx-value-node_id={@selected_node.id}
                    phx-value-name={name}
                    title={gettext("Remove attribute")}
                    class="grid size-5 flex-none place-items-center rounded-[6px] text-[#a8a5a0] hover:bg-[#fbe9e7] hover:text-[#d5544b]"
                  >
                    <.icon name={:close} size={11} />
                  </button>
                </div>
                <p
                  :if={name == "style" and !SecurityHeaders.inline_style_allowed?()}
                  class="mt-[5px] flex items-start gap-1 font-['Space_Grotesk'] text-[10px] leading-[1.35] text-[#a5691a]"
                >
                  <.icon name={:shield} size={11} class="mt-[1px] flex-none" />
                  <span>
                    {gettext(
                      "This site's security policy ignores inline styles, so the published page will not use this. Put it in a class instead."
                    )}
                  </span>
                </p>
              </div>
            </div>

            <%!-- Listing the attributes a node already has is not the same as being able to give it
                  one. Without this the only way to add `aria-label`, `phx-hook` or a data attribute
                  was to type it into the code drawer. --%>
            <.form
              :if={@attr_form}
              for={%{}}
              as={:attr}
              id="pb-attr-form"
              phx-change="typed:pb-attr-form"
              phx-submit="add_attr"
              class="mt-[9px] flex items-center gap-1.5"
            >
              <input
                type="text"
                name="attr[name]"
                phx-debounce="blur"
                value={typed_in(@typed, "pb-attr-form", ["attr", "name"])}
                placeholder={gettext("name")}
                autocomplete="off"
                class="h-7 w-[86px] flex-none rounded-[7px] border border-[#c9c6f0] bg-white px-2 font-['Space_Grotesk'] text-[11px] font-bold text-[#3a382f] outline-none"
              />
              <input
                type="text"
                name="attr[value]"
                phx-debounce="blur"
                value={typed_in(@typed, "pb-attr-form", ["attr", "value"])}
                placeholder={gettext("value")}
                autocomplete="off"
                class="h-7 min-w-0 flex-1 rounded-[7px] border border-[#ecebe6] bg-white px-2 text-[11.5px] font-medium text-[#3a382f] outline-none focus:border-[#c9c6f0]"
              />
              <button
                type="submit"
                title={gettext("Add attribute")}
                class="grid size-7 flex-none place-items-center rounded-[7px] bg-[#4f4bcc] text-white hover:bg-[#413ea8]"
              >
                <.icon name={:check} size={12} />
              </button>
            </.form>

            <button
              :if={!@attr_form}
              type="button"
              id="pb-attr-add"
              phx-click="toggle_attr_form"
              class="mt-[9px] h-[34px] w-full rounded-[9px] border border-dashed border-[#d9d7d0] bg-white text-[11.5px] font-semibold text-[#5c5a54] hover:border-[#5b57d6] hover:text-[#4f4bcc]"
            >
              {gettext("+ Add attribute")}
            </button>
          </div>
        </.inspector_group>

        <%!-- A `<style>` or `<script>` draws nothing, so it has no CSS box, nothing to click and
              nothing to hook; whether it renders at all is still a condition it can take. --%>
        <.element_css
          :if={!raw_block?(@selected_node)}
          node={@selected_node}
          entry={component_entry(assigns)}
          css={@element_css}
          error={@element_css_error}
          advice={@element_css_advice}
          typed={@typed}
        />

        <%!-- NOT ON AN ERROR PAGE. Both of these write a binding the LiveView client attaches —
              `phx-click` here, `phx-hook` below — and an error page is rendered by a controller, as
              `MishkaCmsCore.Runtime.Compilers.ErrorCompiler` says in its own words while binding
              `socket` so the TagEngine output renders "outside a live socket". With no view owning
              that DOM the binding is never attached, so the panel was offering six verbs, an Apply
              button and a violet "this element does something when clicked" dot for a click that
              cannot fire. --%>
        <.conditions
          :if={@selected_node.kind in [:tag, :component]}
          node={@selected_node}
          state={Conditions.read(Node.attr(@selected_node, Conditions.attribute()))}
        />

        <.interactions
          :if={bindable?(@section) and !raw_block?(@selected_node)}
          node={@selected_node}
          entry={component_entry(assigns)}
          state={Interactions.read(Node.attr(@selected_node, "phx-click"))}
          aimed={Interactions.target(Node.attr(@selected_node, "phx-click"))}
          openable={openable(@editor)}
          opener={aimed_opener(@editor, @aim_target, @selected_node)}
          aiming={@aim_target}
          acting={@act_action}
        />

        <.hook_picker
          :if={bindable?(@section) and !raw_block?(@selected_node)}
          node={@selected_node}
          entry={component_entry(assigns)}
          hooks={@js_hooks}
          attached={attached_hook(@selected_node)}
        />
      </div>
    </div>
    """
  end

  # The component property panel: every declared attribute as a real control, grouped, with its
  # option list folded in from the kit's helper discriminators.
  #
  # This is the surface the React editor never had — it shipped a well-designed
  # `PropertiesPanel` type→widget mapping that nothing rendered, so "configure everything visually"
  # was unmet for all 1,764 attributes in the bundle.
  #
  attr(:entry, :map, required: true)
  attr(:node, :any, required: true)
  attr(:focus, :string, default: nil, doc: "the property a tree row asked to land on")
  attr(:icon_picker, :string, default: nil, doc: "the property whose icon picker is open")
  attr(:icon_query, :string, default: "")
  attr(:icon_variant, :string, default: "")
  attr(:icon_library, :string, default: nil)
  attr(:group_folds, :map, default: %{}, doc: "the sections the reader has explicitly folded")
  attr(:hidden, :list, default: [], doc: "attributes another section of the panel writes")
  attr(:typed, :map, default: %{}, doc: "what the forms hold, typed and not yet applied")

  defp props(assigns) do
    assigns =
      assigns
      |> assign(:groups, assigns.entry |> grouped_attrs() |> without(assigns.hidden))
      |> assign(
        :extras,
        assigns.entry |> extra_attr_rows(assigns.node) |> without(assigns.hidden)
      )

    ~H"""
    <%!-- Each group folds, and only the two an author actually came for start open: the words on the
          element and the options the component declares. Appearance, Layout and Behavior are real
          groups but secondary ones — starting them open pushed Properties off the first screen on
          every component with more than a handful of attributes. --%>
    <section :for={{group, attrs} <- @groups}>
      <.fold_heading
        title={group}
        scope="prop"
        group_folds={@group_folds}
        folded_by_default={group not in ~w(Content Properties)}
      >
        <:meta>
          <span
            :if={folded?(@group_folds, "prop", group, group not in ~w(Content Properties))}
            class="flex-none font-['Space_Grotesk'] text-[9.5px] font-semibold text-[#a8a5a0]"
          >
            {length(attrs)}
          </span>
        </:meta>
      </.fold_heading>

      <div :if={!folded?(@group_folds, "prop", group, false)} class="mb-3 flex flex-col gap-2.5">
        <.attr_input
          :for={attr <- attrs}
          attr={attr}
          node={@node}
          focus={@focus}
          icon_picker={@icon_picker}
          icon_query={@icon_query}
          icon_variant={@icon_variant}
          icon_library={@icon_library}
          widget={Inspector.widget(attr, @entry.features, @entry)}
        />
      </div>
    </section>

    <p :if={@groups == []} class="text-[10.5px] font-medium text-[#a8a5a0]">
      {gettext("This one declares no properties of its own.")}
    </p>

    <%!-- Everything the component did NOT declare: `aria-*`, `data-*`, a stray `phx-hook`. It is a
          real need and a rare one, so it lives at the bottom behind a disclosure rather than in the
          list of the component's own properties. --%>
    <section :if={@extras != [] or @node.kind == :component}>
      <button
        type="button"
        id="pb-prop-advanced"
        phx-click={
          JS.toggle(to: "#pb-prop-advanced-body", display: "flex")
          |> JS.toggle_class("rotate-90", to: "#pb-prop-advanced > svg")
        }
        class="flex w-full items-center gap-2 rounded-[9px] px-1 py-1.5 text-left hover:bg-[#f6f5f2]"
      >
        <.icon name={:chevron} size={11} />
        <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("Advanced")}
        </span>
        <span class="flex-1"></span>
        <span
          :if={@extras != []}
          class="flex-none rounded-full bg-[#f2f1ec] px-1.5 text-[9.5px] font-bold text-[#6d6a63]"
        >
          {length(@extras)}
        </span>
      </button>

      <div id="pb-prop-advanced-body" class="mt-1.5 hidden flex-col gap-2.5">
        <p class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
          <.sentence
            text={
              gettext_noop(
                "HTML attributes this component does not declare. They reach it through its %{rest} catch-all."
              )
            }
            parts={%{rest: {"code", nil, "@rest"}}}
          />
        </p>

        <div
          :if={@extras != []}
          class="overflow-hidden rounded-[11px] border border-[#ecebe6]"
        >
          <%!-- Rung the same way a declared property is, because the box below sends the reader here
                rather than writing over what is already in the row: a name typed into it that the
                node already carries is refused, and this is the whole of what says so. --%>
          <div
            :for={{name, kind, value} <- @extras}
            id={"pb-extra-row-#{name}"}
            class={[
              "flex scroll-mt-4 items-center gap-2 border-b border-[#f4f3ee] px-[11px] py-[9px] last:border-b-0",
              (@focus == name && "bg-[#f7f6ff]") || "bg-[#faf9f6]"
            ]}
            phx-mounted={@focus == name && JS.dispatch("pb:reveal")}
          >
            <span class="flex-none font-['Space_Grotesk'] text-[10.5px] font-bold text-[#7a5bd0]">
              {name}
            </span>
            <%!-- The box shows the expression's source, so the mark is what says this one is code. --%>
            <span
              :if={kind == "expr"}
              id={"pb-extra-expr-#{name}"}
              title={
                gettext("%{name} holds an expression — what is in the box is its source", name: name)
              }
              class="flex-none rounded-[5px] bg-[#f2f1fc] px-[5px] py-px font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc]"
            >
              ƒx
            </span>
            <.field_form
              id={"pb-extra-form-#{@node.id}-#{name}"}
              class="min-w-0 flex-1"
              phx-value-kind="set_attr"
              phx-value-node_id={@node.id}
              phx-value-name={name}
              phx-value-value_kind={kind}
            >
              <input
                type="text"
                id={"pb-extra-#{name}"}
                value={value}
                name="value"
                phx-debounce="350"
                class="w-full truncate border-0 bg-transparent p-0 font-['Space_Grotesk'] text-[11px] font-medium text-[#3a382f] outline-none"
              />
            </.field_form>
            <button
              type="button"
              phx-click="op"
              phx-value-kind="delete_attr"
              phx-value-node_id={@node.id}
              phx-value-name={name}
              title={gettext("Remove attribute")}
              class="grid size-5 flex-none place-items-center rounded-[6px] text-[#a8a5a0] hover:bg-[#fbe9e7] hover:text-[#d5544b]"
            >
              <.icon name={:close} size={11} />
            </button>
          </div>
        </div>

        <form
          id={"pb-extra-form-#{@node.id}"}
          phx-change={"typed:pb-extra-form-#{@node.id}"}
          phx-submit="add_extra_attr"
          class="flex items-center gap-1.5"
        >
          <input type="hidden" name="node_id" value={@node.id} />
          <input
            type="text"
            name="name"
            phx-debounce="blur"
            value={typed_in(@typed, "pb-extra-form-#{@node.id}", "name")}
            placeholder="aria-label"
            autocomplete="off"
            class="h-[26px] min-w-0 flex-1 rounded-[7px] border border-[#ecebe6] bg-white px-2 font-['Space_Grotesk'] text-[11px] text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
          />
          <button
            type="submit"
            class="grid size-[26px] flex-none place-items-center rounded-[7px] border border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            <.icon name={:plus} size={12} />
          </button>
        </form>
      </div>
    </section>
    """
  end

  attr(:node, :any, required: true)
  attr(:entry, :any, default: nil)
  attr(:css, :string, default: "")
  attr(:error, :string, default: nil)
  attr(:advice, :string, default: nil)
  attr(:typed, :map, default: %{}, doc: "what the forms hold, typed and not yet applied")

  @doc """
  One element's own CSS.

  Behind a disclosure, next to Advanced, for the same reason: it is a real need and a rare one, and
  the panel above it answers the common case. `&` means this element — plain CSS nesting rather
  than Elementor's `selector` keyword or Bricks' `%root%`, so what is typed is real CSS and can be
  checked by reading it. See `MishkaCmsCore.Runtime.PageBuilder.ElementCss`.

  A COMPONENT IS ONE NODE AND MANY ELEMENTS. The rule is keyed on a class written into the node's
  `class` attribute, which reaches the DOM only if the component declares `class` and puts it
  somewhere — a kit component that does not is unreachable this way, and offering the box anyway
  would take CSS that could never match. Those say so instead, and name the way round.

  The movable list carries NO `phx-no-curly-interpolation`. That attribute is a parse-time switch
  over the template source and everything nested in it; a declaration's text arrives at runtime,
  where braces are never interpolated and so need no protecting. Wearing it anyway cost the row its
  content — the author read the interpolation's own characters back, never the line they had just
  written. The `&` and `&:hover` shown above the box keep theirs: those ARE template source, and
  read as literal text either way.

  THE ADVICE IS SHOWN WHERE THE CSS WAS TYPED. `MishkaCmsCore.Runtime.PageBuilder.ElementCss.advice/1`
  catches the one mistake the validator cannot refuse — `main { … }` is valid CSS that quietly aims
  at a `main` INSIDE this element rather than at the element — and the reply only ever reached the
  code drawer. An author working in this box wrote a rule, watched the page not change, and was
  told nothing: `inspector/1` took `element_css_advice` and never passed it on. It is drawn next to
  `@error` and hidden behind it, because a body that will not parse has no aim to comment on yet.
  """
  def element_css(assigns) do
    assigns =
      assigns
      |> assign(:targetable?, targetable?(assigns.node, assigns.entry))
      |> assign(:movable, movable_declarations(assigns.css))
      |> assign(:reaching, ElementCss.reaching_selectors(assigns.css))
      |> assign(:kit, kit_label(assigns.entry))

    ~H"""
    <section :if={@node.kind in [:tag, :component]}>
      <button
        type="button"
        id="pb-css-toggle"
        phx-click={
          JS.toggle(to: "#pb-css-body", display: "flex")
          |> JS.toggle_class("rotate-90", to: "#pb-css-toggle > svg")
        }
        class="flex w-full items-center gap-2 rounded-[9px] px-1 py-1.5 text-left hover:bg-[#f6f5f2]"
      >
        <.icon name={:chevron} size={11} />
        <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("Custom CSS")}
        </span>
        <span class="flex-1"></span>
        <span
          :if={String.trim(@css) != ""}
          class="size-[6px] flex-none rounded-full bg-[#8580d8]"
          title={gettext("This element has its own CSS")}
        ></span>
      </button>

      <div id="pb-css-body" class="mt-1.5 hidden flex-col gap-2">
        <%!-- A DEAD END WITH A DOOR IN IT. Saying "put it inside a container" and leaving the reader
              to find out how is the same as saying no: the wrapper is one op the editor already has,
              so it is offered here rather than described. --%>
        <div :if={!@targetable?} class="flex flex-col gap-1.5">
          <p
            id="pb-css-unreachable"
            class="rounded-[9px] bg-[#faf9f6] px-2.5 py-2 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]"
          >
            {gettext(
              "This component takes no class of its own, so there is nothing here for a rule to attach to. Put it inside a container and style that instead."
            )}
          </p>
          <button
            type="button"
            id="pb-css-wrap"
            phx-click="op"
            phx-value-kind="wrap"
            phx-value-node_id={@node.id}
            phx-value-tag="div"
            class="w-full rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] py-2 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            {gettext("Wrap it in a div")}
          </button>
        </div>

        <p :if={@targetable?} class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
          <.sentence
            text={
              gettext_noop(
                "Declarations for this element. Write %{self} where you mean it — %{hover}, or a media query."
              )
            }
            parts={%{self: {"code", nil, "&"}, hover: {"code", nil, "&:hover"}}}
          />
        </p>

        <form
          :if={@targetable?}
          id={"pb-css-form-#{@node.id}"}
          phx-change={"typed:pb-css-form-#{@node.id}"}
          phx-submit="save_element_css"
        >
          <input type="hidden" name="node_id" value={@node.id} />
          <input type="hidden" name="base" value={@css} />
          <textarea
            id="pb-css-text"
            name="css"
            phx-debounce="blur"
            spellcheck="false"
            rows="6"
            placeholder="padding: 20px;&#10;&#10;&:hover {&#10;  opacity: .8;&#10;}"
            data-accent-panel
            class="w-full resize-y rounded-[10px] border-0 bg-[#17161a] px-3 py-2.5 font-['Space_Grotesk'] text-[11.5px] leading-[1.7] text-[#c9c7d1] outline-none [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
          >{typed_over(@typed, "pb-css-form-#{@node.id}", "css", @css)}</textarea>

          <p
            :if={@error}
            id="pb-css-error"
            class="mt-1.5 rounded-[8px] bg-[#fdf3f1] px-2.5 py-1.5 text-[10.5px] font-semibold text-[#c0473d]"
          >
            {@error}
          </p>

          <p
            :if={!@error && @advice}
            id="pb-css-advice"
            class="mt-1.5 rounded-[8px] bg-[#fdf8ef] px-2.5 py-1.5 text-[10.5px] font-medium leading-[1.5] text-[#8a6d3b]"
          >
            {@advice}
          </p>

          <%!-- REACHING INTO MARKUP THE AUTHOR DOES NOT OWN. `& > .badge` on a component aims a rule
                at the kit's own elements, which the next version of the kit is free to rename. Not
                refused — sometimes it is the only way to style the thing — but said out loud, and
                named with the kit and version so the reader knows what they are betting on. --%>
          <p
            :if={@reaching != [] and @node.kind == :component}
            id="pb-css-reaching"
            class="mt-1.5 rounded-[8px] bg-[#fdf8ef] px-2.5 py-1.5 text-[10px] font-medium leading-[1.5] text-[#8a6d3b]"
          >
            <span class="font-bold">{Enum.join(@reaching, ", ")}</span>
            {gettext(
              "reaches inside %{kit}, whose markup this page does not own. A future version of the kit can rename it and this rule would stop matching.",
              kit: @kit
            )}
          </p>

          <button
            type="submit"
            id="pb-css-save"
            class="mt-2 w-full rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] py-2 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            {gettext("Apply")}
          </button>
        </form>

        <div :if={@targetable? and @movable != []} id="pb-css-movable" class="flex flex-col gap-1">
          <%!-- NOT "same result". A control writes an ordinary utility, where this text is emitted
                last and beats everything — so on an element already carrying a class for the same
                property, moving the line hands the argument to that class. Saying so is one line;
                a reader who has just watched the padding change and been told it would not is a
                reader who stops trusting the panel. --%>
          <p class="text-[10px] font-medium leading-[1.5] text-[#8a877f]">
            {gettext(
              "These have a control of their own. Moving one takes it out of the text and sets the control — one place to change it, though a class already on the element can then win."
            )}
          </p>
          <div
            :for={{declaration, index, prop} <- @movable}
            class="flex items-center gap-1.5 rounded-[8px] border border-[#ecebe6] bg-[#faf9f6] px-2 py-1.5"
          >
            <code class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#3a382f]">
              {declaration.text}
            </code>
            <span
              :if={declaration.bucket != :base}
              class="flex-none text-[9px] font-bold uppercase tracking-[0.06em] text-[#a8a5a0]"
            >
              {source_word(declaration.bucket)}
            </span>
            <button
              type="button"
              id={"pb-css-move-#{index}"}
              phx-click="move_css_to_controls"
              phx-value-node_id={@node.id}
              phx-value-index={index}
              title={gettext("Set the %{prop} control from this line", prop: prop)}
              class="h-[21px] flex-none rounded-[6px] border border-[#dcdbf5] bg-white px-2 text-[10px] font-bold text-[#4f4bcc] hover:bg-[#f2f1fc]"
            >
              {gettext("Move to controls")}
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # THE LINES A CONTROL COULD HOLD INSTEAD, paired with their position in the text so the server can
  # take exactly that line back out. A declaration the panel has no control for — `border-image`,
  # anything carrying `!important`, a value the enumerated controls cannot spell — is absent rather
  # than offered and then refused.
  #
  # Only base, hover, focus and active: those are the buckets the panel can write, and a media query
  # an author wrote by hand need not line up with Tablet or Mobile.
  defp movable_declarations(css) do
    css
    |> ElementCss.declarations()
    |> Enum.with_index()
    |> Enum.flat_map(fn {declaration, index} ->
      case Styles.from_declaration(declaration.property, declaration.value) do
        {:ok, {prop, _value}} -> [{declaration, index, prop}]
        :error -> []
      end
    end)
  end

  # Every property the component declares, in the panel's own section order — not "the ones already
  # set, and the rest behind a `+`". A component's option surface IS the thing an author came to the
  # inspector for; alert declares seventeen properties and used to show two.
  #
  # `Inspector.grouped/1` has always known how to do this (Layout, Appearance, Behavior, Content,
  # Properties) and its result was flattened away at the only call site.
  # A working form's names and options are the Form panel's, not Props' or Advanced's, on a
  # document the Form panel is shown in.
  defp panel_owned(node, section) do
    case Inspector.form_node?(node) and handles_events?(section) do
      true -> Inspector.form_panel_attrs()
      false -> []
    end
  end

  defp without(groups_or_rows, []), do: groups_or_rows

  defp without([{_group, attrs} | _rest] = groups, hidden) when is_list(attrs) do
    groups
    |> Enum.map(fn {group, attrs} ->
      {group, Enum.reject(attrs, &(Inspector.name(&1) in hidden))}
    end)
    |> Enum.reject(fn {_group, attrs} -> attrs == [] end)
  end

  defp without(rows, hidden),
    do: Enum.reject(rows, fn {name, _kind, _value} -> name in hidden end)

  defp grouped_attrs(entry) do
    entry
    |> Inspector.grouped()
    |> Enum.reject(fn {_group, attrs} -> attrs == [] end)
  end

  # The whole style vocabulary `Tree.Styles` can express, split the way the panel groups it. A
  # property missing here is one the author cannot reach even though the serialiser understands it —
  # a template carrying `max-w-[60ch]` would parse into an override the panel could neither show nor
  # undo. The builder's tests (`test/mishka_cms_core_web/live/builder_live/`) walk
  # `Styles.properties/0` and fail if a control is missing.
  # `display`, `direction`, `justify`, `align`, `wrap` and `gap` are ABSENT on purpose: they have the
  # picture controls above instead — the same properties, a control someone who does not write CSS
  # can read. Two controls writing one override is how a panel starts disagreeing with itself.
  # THE BOX DRAWS THE EDGES NOW. Padding top and Padding bottom used to be two fields in a flat list
  # of thirteen, with no left or right at all and no margin edge of any kind — so `mt-*`, the third
  # most common utility in the block library, had no control, and the two edges that did exist sat a
  # scroll apart from each other. `spacing_box/1` puts all eight where they are on the element.
  #
  # What stays here is what a box cannot show.
  @layout_props [
    {"width", gettext_noop("Width")},
    {"height", gettext_noop("Height")},
    {"min-height", gettext_noop("Min height")},
    {"max-width", gettext_noop("Max width")},
    {"z-index", gettext_noop("Z index")}
  ]

  # THE AXES, folded away under the box. A page may already carry `py-[…]` — absorbed from something
  # somebody typed, or written by this panel before the box existed — and an override with no
  # control is one nobody can clear. They are also how a reader who thinks in axes rather than in
  # edges sets both at once.
  @axis_props [
    {"padding", gettext_noop("Padding")},
    {"py", gettext_noop("Padding Y")},
    {"px", gettext_noop("Padding X")},
    {"margin", gettext_noop("Margin")},
    {"my", gettext_noop("Margin Y")},
    {"mx", gettext_noop("Margin X")}
  ]

  # SIZE, WEIGHT AND CASE ARE NOT DECORATION. Across the eleven starter blocks there are 54 font
  # sizes, 37 weights, 33 top margins, 10 letter-spacings and 7 alignments — and until now the only
  # one of them the panel could touch was the colour. Changing a hero heading's size meant writing
  # CSS by hand in the box at the bottom of the drawer.
  #
  # Colour moves here from Appearance, where it was the odd one out: it is the thing people set
  # SECOND, right after the size, and every other editor groups it with the type for that reason.
  @typography_props [
    {"font-size", gettext_noop("Size")},
    {"line-height", gettext_noop("Line height")},
    {"letter-spacing", gettext_noop("Letter spacing")},
    {"color", gettext_noop("Colour")},
    {"font-weight", gettext_noop("Weight")},
    {"text-align", gettext_noop("Align")},
    {"text-transform", gettext_noop("Case")}
  ]

  # A BORDER COLOUR ON ITS OWN CHANGES NOTHING, which is how this list read before: an element with
  # no border took the colour, drew nothing, and the control looked broken. Width and style are what
  # make it a border.
  @appearance_props [
    {"background", gettext_noop("Background")},
    {"radius", gettext_noop("Radius")},
    {"border-color", gettext_noop("Border colour")},
    {"border-width", gettext_noop("Border width")},
    {"opacity", gettext_noop("Opacity")},
    {"border-style", gettext_noop("Border style")}
  ]

  @doc false
  def layout_props, do: @layout_props

  @doc false
  def axis_props, do: @axis_props

  @doc false
  def typography_props, do: @typography_props

  @doc false
  def appearance_props, do: @appearance_props

  # `background` is BOTH a swatch row and a field, which is the shape Gap already has: named values
  # for the ones a page reuses, and a box for everything else.
  #
  # Swatches alone made **Move to controls** a one-way door. `background-color: #dadada` left the
  # text box, matched none of the five, and there was then nothing on screen that held it — no
  # selected swatch, no field, nothing to clear but the whole bucket. `color` and `border-color`
  # never had that problem because they are fields, and this is the same field.

  # Whether the property panel above the chrome is long enough that "Editing at" should start folded.
  # The threshold is a screenful: alert declares seventeen properties, and pushing the breakpoint and
  # state rows between the reader and those properties is what the fold is for. A plain `<div>` has
  # no properties at all and the chrome IS the panel, so it stays open.
  @dense_panel 8

  defp dense_panel?(assigns) do
    case component_entry(assigns) do
      nil -> false
      entry -> length(Inspector.attrs(entry)) > @dense_panel
    end
  end

  # The attributes written on the node that the component never declared — what the Advanced
  # disclosure lists. `id` is excluded: it has its own row above, and offering it twice invites two
  # controls writing the same attribute.
  defp extra_attr_rows(entry, node) do
    declared = declared_names(entry)

    for {name, _kind, _value} = row <- attr_rows(node),
        not MapSet.member?(declared, name),
        do: row
  end

  # `rest_attrs/1` too: a switch the panel now offers for a key the component reads out of `@rest`
  # has a control of its own above, and listing it here as well puts two controls on one attribute
  # — flip the switch and the same name appears again in Advanced, holding the value it just wrote.
  #
  # AN ELEMENT DECLARES NOTHING. It has no entry, so there is no control above for a row to collide
  # with and `id` is an ordinary row in its own list — excluding it there would take away the only
  # way the panel has of giving an element one.
  defp declared_names(nil), do: MapSet.new()

  defp declared_names(entry) do
    (Inspector.attrs(entry) ++ Inspector.rest_attrs(entry))
    |> MapSet.new(&Inspector.name/1)
    |> MapSet.put("id")
  end

  @doc """
  Whether a free-text add box may put `name` on this node — asked by Advanced's box and by the
  Attributes list's on an element, of the same rules the list above each box is built from, so the
  add and the list cannot disagree.

  A name the node already carries is refused. An add has no value to offer that the row it would
  land on does not already hold: Advanced sends none at all, and the Attributes box sends whatever
  was typed beside it, empty included. An empty one is worse than nothing — it either beats the
  component's own default, or is taken for a removal by the funnel every write goes through, and
  `class=""` throws away everything the style panel wrote while `:if={}` reads as nil, which takes
  the element and all of its content off the published page.

  A HEEx special — `:if`, `:for`, `:let` — is refused whether the node carries it or not: it must be
  an expression between braces, so `:if=""` is not a condition that never matches, it is a template
  that will not compile at all, and a box that can only produce a string has no way to write one.
  The Conditions section above is where a `:if` is written, through
  `MishkaCmsCore.Runtime.PageBuilder.Conditions`.

  A name the component declares is refused because Advanced is the attributes it does NOT declare —
  that property has a control of its own above, and a row written here would never appear.
  """
  @spec attr_addable?(map(), Node.t() | nil, String.t()) :: boolean()
  def attr_addable?(assigns, %Node{} = node, name) do
    entry = component_entry(Map.put(assigns, :selected_node, node))

    is_nil(Node.attr(node, name)) and not String.starts_with?(name, ":") and
      not MapSet.member?(declared_names(entry), name)
  end

  def attr_addable?(_assigns, _gone, _name), do: false

  attr(:attr, :map, required: true)
  attr(:node, :any, required: true)
  attr(:widget, :any, required: true)
  attr(:focus, :string, default: nil, doc: "the property a tree row asked to land on")
  attr(:icon_picker, :string, default: nil)
  attr(:icon_query, :string, default: "")
  attr(:icon_variant, :string, default: "")
  attr(:icon_library, :string, default: nil)

  # One property control, chosen by `MishkaCmsCore.Runtime.PageBuilder.Inspector.widget/2`.
  #
  # An attribute the author has not set renders the component's own default and serializes nothing —
  # the explicit-versus-default distinction the demo marks with an override dot. Clearing a control
  # removes the attribute rather than writing an empty string, so the default comes back.
  #
  defp attr_input(assigns) do
    assigns =
      assigns
      |> assign(:name, Inspector.name(assigns.attr))
      |> assign(:doc, Inspector.doc(assigns.attr))
      |> assign(:atom?, Inspector.atom?(assigns.attr))
      # AN ICON IN A MAP IS STILL AN ICON. The control shows and writes a name; the map around it is
      # the component's business, and `Inspector.icon_in/1` reads the name out of whichever shape the
      # value arrives in — the bundle's default or the expression the editor writes back.
      |> assign(:icon_map?, Inspector.icon_map?(assigns.attr))
      |> then(&assign(&1, :value, shown(&1, Node.attr_text(&1.node, &1.name))))
      |> then(&assign(&1, :default, shown(&1, Inspector.default(&1.attr))))
      # An ATOM is written as an expression too — `kind={:danger}` is how HEEx spells one — but it is
      # a literal the editor itself writes that way, not a binding to something outside. Only the
      # ones that are genuinely bound get marked, or every option pill in the panel would claim to be.
      # A map holding an icon is the same case: the editor composed it, and offering to store it as
      # plain text would hand the component a binary where its own `Map.get/2` expects a map.
      |> then(
        &assign(
          &1,
          :expr?,
          not &1.atom? and not &1.icon_map? and
            match?({:expr, _source}, Node.attr(&1.node, &1.name))
        )
      )

    assigns =
      assigns
      |> assign(:required?, Inspector.required?(assigns.attr))
      |> then(&assign(&1, :missing?, &1.required? and blank?(&1.value)))

    ~H"""
    <%!-- One property. It carries its own state rather than leaving it to be inferred: a violet dot
          when this page has set it, a red border and a line of text when it is required and empty,
          and a delete that is disabled — not hidden — when the property cannot be removed at all.
          Arriving from a property row in the tree also rings it and scrolls it into view. --%>
    <div
      id={"pb-attr-#{@node.id}-#{@name}"}
      class={[
        "scroll-mt-4 rounded-[10px] border px-2.5 py-2",
        (@missing? && "border-[#e8b7b1] bg-[#fdf6f5]") ||
          ((@focus == @name && "border-[#c3c1f0] bg-[#f7f6ff]") || "border-[#ecebe6] bg-white")
      ]}
      phx-mounted={@focus == @name && JS.dispatch("pb:reveal")}
    >
      <label class="block" title={Inspector.doc(@attr)}>
        <span class="mb-1.5 flex items-center gap-1.5">
          <span class="min-w-0 flex-1 truncate text-[10.5px] font-bold text-[#3a382f]">
            {Inspector.label(@attr)}<span :if={@required?} class="text-[#d5544b]">*</span>
          </span>

          <span
            :if={!is_nil(@value)}
            title={gettext("Set on this page")}
            class="size-[7px] flex-none rounded-full bg-[#4f4bcc]"
          />

          <%!-- THIS ONE IS BOUND, NOT TYPED. `name={@icon}` and `name="hero-bolt"` looked identical
                in this panel — both drew a box reading what was between the braces — and the write
                that went back turned the first into the second, silently. A component that nests
                another component is made of these bindings, so the mark says which box is one, and
                pressing it is the way to stop it being one deliberately. --%>
          <button
            :if={@expr?}
            type="button"
            id={"pb-attr-literal-#{@node.id}-#{@name}"}
            phx-click="op"
            phx-value-kind="set_attr"
            phx-value-node_id={@node.id}
            phx-value-name={@name}
            phx-value-value={@value}
            phx-value-value_kind="string"
            title={
              gettext("%{name} is bound to %{value} — press to store it as plain text instead",
                name: @name,
                value: @value
              )
            }
            class="flex-none rounded-[5px] bg-[#f2f1fc] px-[5px] py-px font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc] hover:bg-[#e4e2f7]"
          >
            ƒx
          </button>

          <%!-- Required properties keep the control, greyed: a disabled affordance says "not here",
                where a missing one says "look elsewhere". --%>
          <button
            type="button"
            id={"pb-attr-clear-#{@node.id}-#{@name}"}
            phx-click={!@required? && "op"}
            phx-value-kind="delete_attr"
            phx-value-node_id={@node.id}
            phx-value-name={@name}
            disabled={@required?}
            title={
              (@required? &&
                 gettext("%{label} is required — it cannot be removed", label: Inspector.label(@attr))) ||
                gettext("Remove this property and go back to the component's default")
            }
            class="grid size-[18px] flex-none place-items-center rounded-[5px] text-[#a8a5a0] hover:bg-[#fdf3f1] hover:text-[#c0473d] disabled:cursor-not-allowed disabled:bg-transparent disabled:text-[#d5d3cc]"
          >
            <.icon name={:trash} size={11} />
          </button>
        </span>

        <.widget_control {assigns} />
      </label>

      <%!-- The kit writes an explanation for 1743 of its 1764 properties and it used to be reachable
            only by hovering a row you had already added — invisible at the one moment it is most
            needed, which is while you are deciding whether you want the property at all. --%>
      <p
        :if={@doc not in [nil, ""] and !@missing?}
        class="mt-1.5 text-[10px] font-medium leading-[1.5] text-[#8a877f]"
      >
        {@doc}
      </p>

      <p :if={@missing?} class="mt-1.5 text-[10px] font-semibold text-[#c0473d]">
        {gettext("Required — the page cannot be saved without it.")}
      </p>
      <p
        :if={!@missing? and is_nil(@value) and @default not in [nil, ""]}
        class="mt-1.5 text-[10px] font-medium text-[#a8a5a0]"
      >
        {gettext("Using the component's default.")}
      </p>
    </div>
    """
  end

  # An ATOM attribute is written as an expression — `kind={:danger}` — because that is the value the
  # component's clauses match on. Handed the string `"danger"` they all fall through and the
  # component renders whatever its catch-all renders, silently: every colour of alert came out
  # identical, which is exactly how this was found. The kit's own examples write it the same way.
  defp option_kind(true), do: "expr"
  defp option_kind(_string), do: nil

  # A NUMBER HAS TO BE WRITTEN AS ONE. The stepper wrote `value="45"` — a HEEx string literal — and
  # the kit's own body does arithmetic on it, so a progress bar set to 45 rendered a bare track and a
  # section set to 45 rendered 0%. It looked as though the field did nothing.
  #
  # Keyed on the DECLARED type and not on the widget, because `opts.editor == "number"` may sit on a
  # string attribute that genuinely wants quotes — `chelekom-range-field`'s value among them. The
  # three numeric types are the ones `Inspector.widget/2` itself routes to a number box.
  defp number_kind(attr) do
    (Inspector.type(attr) in ~w(integer float pos_integer) && "expr") || nil
  end

  defp option_value(value, true), do: ":#{value}"
  defp option_value(value, _string), do: value

  # The node stores `:danger` for an atom and `danger` for a string; the control's options are
  # labelled without the colon either way, so the leading one is ignored when matching.
  defp chosen?(nil, _value), do: false

  defp chosen?(current, value),
    do: String.trim_leading(to_string(current), ":") == to_string(value)

  # What the control puts in its box. An icon carried in a map shows the name inside it; everything
  # else shows itself.
  defp shown(%{icon_map?: true}, value), do: Inspector.icon_in(value)
  defp shown(_assigns, value), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # HOW MANY BARS TO DRAW for each value the kit offers. A kit may spell its columns as words
  # (Chelekom's `one`..`twelve`) or as numbers; anything this cannot count is drawn as a single bar
  # rather than dropped, so an unfamiliar vocabulary still gets a picker it can click.
  @column_words ~w(one two three four five six seven eight nine ten eleven twelve)

  # ONE `picked` FIELD, TWO KINDS. A block arrives tagged `{:block, id}` so the canvas, the layer
  # tree and both hints all read the same field and cannot disagree about what is armed — and so a
  # tuple never reaches a template, which is not renderable.
  defp picked_block_id({:block, id}), do: id
  defp picked_block_id(_other), do: nil

  defp picked_label({:block, id}), do: id
  defp picked_label(name) when is_binary(name), do: name
  defp picked_label(_other), do: ""

  defp column_choices(values), do: Enum.map(values, &{&1, column_count(&1)})

  defp column_count(value) do
    word = value |> to_string() |> String.trim_leading(":") |> String.downcase()

    case Integer.parse(word) do
      {count, ""} when count > 0 and count < 13 -> count
      _not_a_number -> (Enum.find_index(@column_words, &(&1 == word)) || 0) + 1
    end
  end

  defp widget_control(%{widget: :toggle} = assigns) do
    ~H"""
    <%!-- The switch's ON state travels in the button's OWN `value`, for the reason the breakpoint
          tabs above already document: `View.extractMeta` overwrites `meta.value` with `el.value`
          after collecting the `phx-value-*` attributes, and a button with no `value` is `""`. An
          empty value is how this editor spells "remove the attribute" — so turning a property ON
          arrived as a delete, and the switch could only ever move one way. --%>
    <button
      type="button"
      role="switch"
      value="true"
      aria-checked={to_string(@value == "" or @value == "true")}
      phx-click="op"
      phx-value-kind={(is_nil(@value) && "set_attr") || "delete_attr"}
      phx-value-node_id={@node.id}
      phx-value-name={@name}
      phx-value-value_kind="boolean"
      class={[
        "relative h-[23px] w-10 rounded-full transition",
        (is_nil(@value) && "bg-[#e0ded7]") || "bg-[#4f4bcc]"
      ]}
    >
      <span class={[
        "absolute top-[3px] size-[17px] rounded-full bg-white shadow transition-all",
        (is_nil(@value) && "left-[3px]") || "left-5"
      ]} />
    </button>
    """
  end

  defp widget_control(%{widget: {:segmented, values}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <div class="flex gap-0.5 rounded-[9px] bg-[#f2f1ec] p-0.5">
      <button
        :for={value <- @values}
        type="button"
        phx-click="op"
        phx-value-kind="set_attr"
        phx-value-node_id={@node.id}
        phx-value-name={@name}
        phx-value-value_kind={option_kind(@atom?)}
        value={option_value(value, @atom?)}
        class={[
          "h-7 min-w-0 flex-1 truncate rounded-[7px] px-1 text-[10.5px] font-semibold capitalize",
          (chosen?(@value, value) && "bg-white text-[#4f4bcc] shadow-sm") || "text-[#6d6a63]"
        ]}
      >
        {value}
      </button>
    </div>
    """
  end

  # THE SHAPE, NOT THE WORD. Same event contract as the segmented control above — the value rides on
  # the button's own `value`, because LiveView overwrites `phx-value-value` with `el.value`.
  defp widget_control(%{widget: {:columns, values}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <div class="flex flex-wrap gap-[5px]">
      <button
        :for={{value, count} <- column_choices(@values)}
        type="button"
        id={"pb-cols-#{@node.id}-#{value}"}
        phx-click="op"
        phx-value-kind="set_attr"
        phx-value-node_id={@node.id}
        phx-value-name={@name}
        phx-value-value_kind={option_kind(@atom?)}
        value={option_value(value, @atom?)}
        title={ngettext("%{count} column", "%{count} columns", count)}
        aria-label={ngettext("%{count} column", "%{count} columns", count)}
        class={[
          "flex h-[30px] w-[54px] flex-none gap-[3px] rounded-[9px] border p-[6px]",
          (chosen?(@value, value) && "border-[#4f4bcc] bg-[#f2f1fc]") ||
            "border-[#ecebe6] bg-white hover:border-[#c9c7ee]"
        ]}
      >
        <span
          :for={_slot <- 1..count//1}
          class={[
            "flex-1 rounded-[2px]",
            (chosen?(@value, value) && "bg-[#4f4bcc]") || "bg-[#e6e4de]"
          ]}
        ></span>
      </button>
    </div>
    """
  end

  defp widget_control(%{widget: {:select, values}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <%!-- The `phx-value-*` that say WHICH property this is are only merged into the payload for FORM
          events, and `phx-change` on a bare `<select>` outside a form fires nothing at all. Without
          this wrapper every property whose option list is long enough to be a dropdown — 381 of the
          kit's attributes, `variant` and `color` among them — silently could not be changed, while
          the short ones next to them worked because a segmented control is a button. --%>
    <.form
      for={%{}}
      id={"pb-attr-form-#{@node.id}-#{@name}"}
      phx-change="op"
      phx-value-kind="set_attr"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
      phx-value-value_kind={option_kind(@atom?)}
    >
      <div class="relative">
        <select
          id={"pb-attr-#{@name}"}
          name="value"
          class="h-8 w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[12px] font-semibold text-[#3a382f]"
        >
          <option value="">
            {(default_text(@default) && gettext("%{value} (default)", value: default_text(@default))) ||
              gettext("— default —")}
          </option>
          <option
            :for={value <- @values}
            value={option_value(value, @atom?)}
            selected={chosen?(@value, value)}
          >
            {value}
          </option>
        </select>
        <.select_chevron />
      </div>
    </.form>
    """
  end

  defp widget_control(%{widget: {:number, min, max, step}} = assigns) do
    assigns = assigns |> assign(:min, min) |> assign(:max, max) |> assign(:step, step)

    ~H"""
    <.field_form
      id={"pb-attr-form-#{@node.id}-#{@name}"}
      phx-value-kind="set_attr"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
      phx-value-value_kind={number_kind(@attr)}
    >
      <input
        type="number"
        id={"pb-attr-#{@name}"}
        name="value"
        value={@value}
        min={@min}
        max={@max}
        step={@step}
        placeholder={default_text(@default)}
        phx-debounce="350"
        class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-semibold text-[#3a382f]"
      />
    </.field_form>
    """
  end

  # An icon's value is a CLASS NAME the Tailwind heroicons plugin resolves — `hero-check`,
  # `hero-check-solid`. Fifty-seven attributes across the kit are one, and every one of them used to
  # be a bare text box: the author had to know the exact string, and a typo rendered nothing at all
  # rather than an error. The catalogue is read from the same directory the plugin reads.
  #
  # The chip shows what is set; the popover searches 1,288 classes across the four weights the set
  # ships. `MishkaCmsCore.Runtime.PageBuilder.Icons.available?/0` is false when the host has no
  # heroicons, and the control falls back to the text box below.
  defp widget_control(%{widget: :icon} = assigns) do
    assigns =
      assigns
      |> assign(:open?, assigns.icon_picker == assigns.name)
      |> assign_new(:icon_library, fn -> nil end)
      |> assign_new(:icon_map?, fn -> false end)

    # THE BUTTON WAS DEAD. `:icon_library` was assigned on the LiveView and defaulted here, and then
    # never reached `Icons.search/2` — while `icon_variant`, threaded one line above, did. Clicking a
    # library left the grid on the same 60 heroicons and the footer reading "Showing 60 of 316",
    # because `Enum.take/2` on the merged list is spent before a second set is reached.
    library = library_module(assigns.icon_library)

    assigns =
      assigns
      |> assign(
        :results,
        Icons.search(assigns.icon_query, variant: assigns.icon_variant, library: library)
      )
      |> assign(:total, Icons.count(assigns.icon_query, assigns.icon_variant, library: library))

    ~H"""
    <div :if={!Icons.available?()}>
      <.plain_input {assigns} />
    </div>

    <div :if={Icons.available?()} class="relative">
      <%!-- The TRIGGER IS THE FIELD. It was a button opening a popover with a search box of its own,
            so the only reachable values were the ones this install has a catalogue for — and the
            catalogue is only ever the sets registered here. An author naming a glyph from a set the
            editor was never told about had no way to write it down. Typing now sets the attribute
            directly and narrows the grid below with the same keystrokes. --%>
      <form
        id={"pb-icon-form-#{@node.id}-#{@name}"}
        phx-change="icon_typed"
        phx-submit="icon_typed"
        class="flex h-[30px] w-full items-center gap-2 rounded-[8px] border border-[#ecebe6] bg-white px-2 focus-within:border-[#c3c1f0]"
      >
        <input type="hidden" name="name" value={@name} />
        <input type="hidden" name="node_id" value={@node.id} />
        <%!-- WHAT THE COMPONENT EXPECTS BACK. A bare name for an icon-typed attribute, and the map
              the component reads `type` and `value` out of for one declared as a map — writing a
              binary into the second is a `Map.get/2` on a string the moment it renders. --%>
        <input :if={@icon_map?} type="hidden" name="shape" value="map" />

        <span :if={Icons.known?(@value)} class="flex-none text-[#3a382f]">
          {Icons.svg(@value, 15)}
        </span>
        <span
          :if={!Icons.known?(@value)}
          class="grid size-[15px] flex-none place-items-center rounded-[4px] bg-[#f2f1ec] text-[9px] font-bold text-[#a8a5a0]"
          title={gettext("Not in any installed icon set — it will still be written as you typed it")}
        >
          ?
        </span>
        <input
          type="text"
          id={"pb-icon-open-#{@node.id}-#{@name}"}
          name="value"
          value={@value}
          placeholder={@default || gettext("Type or pick an icon")}
          autocomplete="off"
          spellcheck="false"
          phx-debounce="250"
          phx-focus="toggle_icon_picker"
          phx-value-name={@name}
          class="min-w-0 flex-1 border-0 bg-transparent p-0 font-['Space_Grotesk'] text-[11px] font-semibold text-[#1b1a18] placeholder:font-medium placeholder:text-[#a8a5a0] focus:outline-none"
        />
        <button
          type="button"
          phx-click="toggle_icon_picker"
          phx-value-name={@name}
          class="flex-none"
          aria-label={gettext("Browse icons")}
        >
          <.icon name={:chevron} size={11} class="rotate-90 text-[#a8a5a0]" />
        </button>
      </form>

      <div
        :if={@open?}
        id={"pb-icon-picker-#{@name}"}
        phx-mounted={menu_in()}
        phx-remove={menu_out()}
        phx-click-away="close_icon_picker"
        class="absolute left-0 right-0 top-[34px] z-50 rounded-[12px] border border-[#ecebe6] bg-white p-2 shadow-[0_16px_44px_rgba(20,18,26,.2)]"
      >
        <%!-- One row per registered set, and only when there is a choice to make. `Icons.libraries/0`
              is a list, so an install that adds Lucide beside Heroicons gets the selector for free. --%>
        <div :if={length(Icons.libraries()) > 1} class="mb-1.5 flex gap-1">
          <button
            :for={library <- Icons.libraries()}
            type="button"
            id={"pb-icon-library-#{library.prefixes() |> List.first() |> to_string() |> String.trim_trailing("-")}"}
            phx-click="icon_library"
            phx-value-library={inspect(library)}
            class={[
              "h-[22px] flex-1 rounded-[6px] text-[9.5px] font-bold",
              (library_module(@icon_library) == library && "bg-[#4f4bcc] text-white") ||
                "bg-[#f6f5f2] text-[#6d6a63] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
            ]}
          >
            {library.label()}
          </button>
        </div>

        <div class="mb-1.5 flex gap-1">
          <button
            :for={{suffix, label} <- Icons.variants()}
            type="button"
            id={"pb-icon-variant-#{(suffix == "" && "outline") || String.trim_leading(suffix, "-")}"}
            phx-click="icon_variant"
            phx-value-variant={suffix}
            class={[
              "h-[22px] flex-1 rounded-[6px] text-[9.5px] font-bold",
              (@icon_variant == suffix && "bg-[#17161a] text-white") ||
                "bg-[#f6f5f2] text-[#6d6a63] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
            ]}
          >
            {translate(label)}
          </button>
        </div>

        <div class="grid max-h-[188px] grid-cols-8 gap-1 overflow-y-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          <button
            :for={name <- @results}
            type="button"
            id={"pb-icon-#{name}"}
            phx-click="icon_picked"
            phx-value-node_id={@node.id}
            phx-value-name={@name}
            phx-value-shape={@icon_map? && "map"}
            value={name}
            title={name}
            class={[
              "grid aspect-square place-items-center rounded-[6px] hover:bg-[#f2f1fc]",
              (@value == name && "bg-[#f2f1fc] ring-1 ring-[#c3c1f0]") || ""
            ]}
          >
            <span class="text-[#3a382f]">{Icons.svg(name, 15)}</span>
          </button>
        </div>

        <p :if={@results == []} class="px-1 py-3 text-center text-[10.5px] font-medium text-[#a8a5a0]">
          {gettext("No icon matches “%{query}”.", query: @icon_query)}
        </p>

        <p
          :if={@total > length(@results)}
          class="mt-1 px-1 text-[9.5px] font-medium text-[#a8a5a0]"
        >
          {gettext("Showing %{shown} of %{total} — keep typing to narrow it.",
            shown: length(@results),
            total: @total
          )}
        </p>
      </div>
    </div>
    """
  end

  defp widget_control(%{widget: :color} = assigns) do
    ~H"""
    <.field_form
      id={"pb-attr-form-#{@node.id}-#{@name}"}
      phx-value-kind="set_attr"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
    >
      <div class="flex items-center gap-1.5">
        <span
          class="size-8 shrink-0 rounded-[8px] border border-[#ecebe6]"
          style={"background:#{swatch(@value)}"}
        />
        <input
          type="text"
          id={"pb-attr-#{@name}"}
          name="value"
          value={@value}
          placeholder={default_text(@default) || gettext("e.g. primary or #4f4bcc")}
          phx-debounce="350"
          class="h-8 min-w-0 flex-1 rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-medium text-[#3a382f]"
        />
      </div>
    </.field_form>
    """
  end

  # A link the author types, with the one thing a text field cannot do: open it. The check is
  # deliberately loose — a relative `/about` is as valid a link as an absolute one.
  defp widget_control(%{widget: :url} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <.field_form
        id={"pb-attr-form-#{@node.id}-#{@name}"}
        phx-value-kind="set_attr"
        phx-value-node_id={@node.id}
        phx-value-name={@name}
        class="min-w-0 flex-1"
      >
        <input
          type="text"
          id={"pb-attr-#{@name}"}
          name="value"
          value={@value}
          inputmode="url"
          placeholder={default_text(@default) || "https://…"}
          phx-debounce="350"
          class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-medium text-[#3a382f]"
        />
      </.field_form>
      <a
        :if={openable?(@value)}
        href={@value}
        target="_blank"
        rel="noopener noreferrer"
        id={"pb-attr-open-#{@name}"}
        title={gettext("Open in a new tab")}
        class="grid size-8 flex-none place-items-center rounded-[8px] border border-[#ecebe6] bg-[#faf9f6] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
      >
        <.icon name={:external} size={12} />
      </a>
    </div>
    """
  end

  # A picture is chosen from the site's own library, not typed. The button hands the Assets sheet the
  # attribute waiting for an answer; picking there writes straight back here. The field stays
  # editable underneath, because a CDN URL nobody uploaded is still a legitimate value.
  defp widget_control(%{widget: :media} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <div class="flex items-center gap-1.5">
        <.field_form
          id={"pb-attr-form-#{@node.id}-#{@name}"}
          phx-value-kind="set_attr"
          phx-value-node_id={@node.id}
          phx-value-name={@name}
          class="min-w-0 flex-1"
        >
          <input
            type="text"
            id={"pb-attr-#{@name}"}
            name="value"
            value={@value}
            placeholder={default_text(@default) || "/uploads/…"}
            phx-debounce="350"
            class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-medium text-[#3a382f]"
          />
        </.field_form>
        <button
          type="button"
          id={"pb-attr-pick-#{@name}"}
          phx-click="pick_media"
          phx-value-node_id={@node.id}
          phx-value-name={@name}
          title={gettext("Choose from the media library")}
          class="grid size-8 flex-none place-items-center rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc] hover:bg-[#e9e7fb]"
        >
          <.icon name={:image} size={13} />
        </button>
      </div>
      <%!-- A BROKEN GLYPH IS NOT AN ANSWER. A path that points at nothing — a file since deleted, a
            URL typed by hand, a name that never existed — drew the browser's own torn-page icon and
            left the author to guess which of those it was. `MediaThumb` hides the `<img>` when it
            fails to load, so the sentence behind it becomes the answer; when it loads, the picture
            covers the sentence. The hook binds `load`/`error` in JS because an `onerror=` attribute
            is exactly what this admin's Content-Security-Policy refuses.

            No `phx-update="ignore"` here, unlike the gallery's cards: those are stream items and a
            new record arrives as a new node, while this one keeps its id and changes `src` under it.
            The hook re-judges in `updated()`, which is what that callback is for. --%>
      <div
        :if={previewable?(@value)}
        id={"pb-attr-thumb-#{@node.id}-#{@name}"}
        phx-hook="MediaThumb"
        data-loaded-background="#fff"
        class="relative h-[68px] w-full overflow-hidden rounded-[8px] border border-[#f0efea] bg-[#faf9f6]"
      >
        <span class="absolute inset-0 grid place-items-center px-2 text-center text-[10.5px] font-semibold text-[#a8a5a0]">
          {gettext("Nothing loads from this path")}
        </span>
        <img src={@value} alt="" class="relative h-full w-full object-contain" />
      </div>
    </div>
    """
  end

  # A BOX WITH A PLUS, which is what was asked for. Thirty-nine attributes across the kit hold a
  # collection — `chelekom-filterable-gallery` keeps its whole content in two of them — and every one
  # of them drew a one-line text box whose write turned the value into a string, so the component
  # raised the moment anything was typed. "we cannot add any image and it's not clear how it works".
  #
  # A ROW PER ITEM AND A TILE TO ADD ONE. A list of maps is cards — a picture, the words that go with
  # it, and whichever other keys the kit put there; a list of anything else is one field each. Every
  # change rewrites the whole collection as one `set_attr`, so one add, one removal or one edit is
  # one undo step.
  #
  # AND AN ATTRIBUTE THAT IS NOT DATA IS LEFT ALONE. `media={@photos}` is an author binding the list
  # to something outside the page, and the panel says so rather than offering to overwrite it with
  # what it could not read.
  defp widget_control(%{widget: {:collection, _kind}} = assigns) do
    assigns =
      case Collection.read(assigns.node, assigns.name, assigns.default) do
        {:ok, items} -> assigns |> assign(:items, items) |> assign(:bound?, false)
        :error -> assigns |> assign(:items, []) |> assign(:bound?, true)
      end

    ~H"""
    <p :if={@bound?} class="rounded-[8px] bg-[#faf9f6] px-2 py-1.5 text-[10.5px] text-[#6d6a63]">
      <.sentence
        text={gettext_noop("This is bound to %{value}, so the editor leaves it alone.")}
        parts={%{value: {"span", "font-semibold", @value}}}
      />
    </p>

    <div :if={!@bound?} class="flex flex-col gap-1.5">
      <.collection_item
        :for={{item, index} <- Enum.with_index(@items)}
        node={@node}
        name={@name}
        index={index}
        item={item}
        options={sibling_options(@node, @name)}
      />

      <button
        type="button"
        id={"pb-collection-add-#{@node.id}-#{@name}"}
        phx-click="collection_add"
        phx-value-node_id={@node.id}
        phx-value-name={@name}
        class="flex h-[34px] items-center justify-center gap-1.5 rounded-[8px] border border-dashed border-[#cfcdf0] bg-[#faf9ff] text-[11px] font-bold text-[#4f4bcc] hover:bg-[#f2f1fc]"
      >
        <.icon name={:plus} size={12} /> {gettext("Add")}
      </button>
    </div>
    """
  end

  defp widget_control(%{widget: :textarea} = assigns) do
    ~H"""
    <.field_form
      id={"pb-attr-form-#{@node.id}-#{@name}"}
      phx-value-kind="set_attr"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
    >
      <textarea
        id={"pb-attr-#{@name}"}
        name="value"
        rows="3"
        placeholder={default_text(@default)}
        phx-debounce="350"
        class="w-full resize-y rounded-[8px] border border-[#ecebe6] bg-white p-2 text-[12px] font-medium text-[#3a382f]"
      >{@value}</textarea>
    </.field_form>
    """
  end

  defp widget_control(%{widget: {:struct, struct_name}} = assigns) do
    assigns = assign(assigns, :struct_name, struct_name)

    ~H"""
    <span
      title={gettext("Struct attributes are set in code, not visually")}
      class="inline-flex items-center gap-1.5 rounded-[7px] bg-[#f2f1ec] px-2 py-1.5 font-['Space_Grotesk'] text-[10.5px] font-bold text-[#8a877f]"
    >
      <.icon name={:lock} size={11} /> {@struct_name || gettext("struct")}
    </span>
    """
  end

  defp widget_control(assigns), do: plain_input(assigns)

  attr(:node, :map, required: true)
  attr(:name, :string, required: true)
  attr(:index, :integer, required: true)
  attr(:item, :any, required: true)
  attr(:options, :list, default: [])

  # One card. A map shows a field per key it already has — the kit decided which those are, and
  # inventing more would write keys the component never reads.
  defp collection_item(%{item: item} = assigns) when is_map(item) do
    assigns = assign(assigns, :keys, item |> Map.keys() |> Enum.sort_by(&key_rank/1))

    ~H"""
    <div class="flex flex-col gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white p-2">
      <div class="flex items-center justify-between">
        <span class="font-['Space_Grotesk'] text-[10px] font-bold text-[#a8a5a0]">
          {@index + 1}
        </span>
        <button
          type="button"
          id={"pb-collection-del-#{@node.id}-#{@name}-#{@index}"}
          phx-click="collection_remove"
          phx-value-node_id={@node.id}
          phx-value-name={@name}
          phx-value-index={@index}
          title={gettext("Remove")}
          class="grid size-[18px] place-items-center rounded-[5px] text-[#a8a5a0] hover:bg-[#fdf6f5] hover:text-[#d5544b]"
        >
          <.icon name={:trash} size={11} />
        </button>
      </div>

      <div
        :if={previewable?(picture(@item))}
        id={"pb-collection-thumb-#{@node.id}-#{@name}-#{@index}"}
        phx-hook="MediaThumb"
        data-loaded-background="#fff"
        class="relative h-[62px] w-full overflow-hidden rounded-[7px] border border-[#f0efea] bg-[#faf9f6]"
      >
        <span class="absolute inset-0 grid place-items-center px-2 text-center text-[10px] font-semibold text-[#a8a5a0]">
          {gettext("Nothing loads from this path")}
        </span>
        <img src={picture(@item)} alt="" class="relative h-full w-full object-contain" />
      </div>

      <div :for={key <- @keys} class="flex items-center gap-1.5">
        <span class="w-[58px] flex-none truncate text-[10px] font-semibold text-[#8a877f]">
          {Inspector.label(to_string(key))}
        </span>

        <.collection_field
          node={@node}
          name={@name}
          index={@index}
          key={key}
          value={Map.get(@item, key)}
          options={options_for(@name, key, @options)}
        />

        <button
          :if={picture_key?(key)}
          type="button"
          id={"pb-collection-pick-#{@node.id}-#{@name}-#{@index}"}
          phx-click="pick_media"
          phx-value-node_id={@node.id}
          phx-value-name={@name}
          phx-value-index={@index}
          phx-value-key={key}
          title={gettext("Choose from the media library")}
          class="grid size-[26px] flex-none place-items-center rounded-[7px] border border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc] hover:bg-[#e9e7fb]"
        >
          <.icon name={:image} size={12} />
        </button>
      </div>
    </div>
    """
  end

  # ONE SIDE EACH. A `map` attribute is read out as its pairs — `chelekom-flash` holds
  # `%{"info" => "…"}`, `chelekom-pagination` a map of query parameters — and a pair is two fields,
  # not one value with a tuple in it.
  defp collection_item(%{item: {key, value}} = assigns) do
    assigns = assigns |> assign(:pair_key, key) |> assign(:pair_value, value)

    ~H"""
    <div class="flex items-center gap-1.5">
      <.collection_field
        node={@node}
        name={@name}
        index={@index}
        key="__key"
        value={@pair_key}
        options={[]}
      />
      <span class="flex-none text-[11px] font-bold text-[#a8a5a0]">→</span>
      <.collection_field
        node={@node}
        name={@name}
        index={@index}
        key="__value"
        value={@pair_value}
        options={[]}
      />
      <button
        type="button"
        id={"pb-collection-del-#{@node.id}-#{@name}-#{@index}"}
        phx-click="collection_remove"
        phx-value-node_id={@node.id}
        phx-value-name={@name}
        phx-value-index={@index}
        title={gettext("Remove")}
        class="grid size-8 flex-none place-items-center rounded-[8px] text-[#a8a5a0] hover:bg-[#fdf6f5] hover:text-[#d5544b]"
      >
        <.icon name={:trash} size={12} />
      </button>
    </div>
    """
  end

  defp collection_item(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <.collection_field
        node={@node}
        name={@name}
        index={@index}
        key={nil}
        value={@item}
        options={[]}
      />
      <button
        type="button"
        id={"pb-collection-del-#{@node.id}-#{@name}-#{@index}"}
        phx-click="collection_remove"
        phx-value-node_id={@node.id}
        phx-value-name={@name}
        phx-value-index={@index}
        title={gettext("Remove")}
        class="grid size-8 flex-none place-items-center rounded-[8px] text-[#a8a5a0] hover:bg-[#fdf6f5] hover:text-[#d5544b]"
      >
        <.icon name={:trash} size={12} />
      </button>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:name, :string, required: true)
  attr(:index, :integer, required: true)
  attr(:key, :any, default: nil)
  attr(:value, :any, default: nil)
  attr(:options, :list, default: [])

  # A CATEGORY IS ONE OF THE FILTERS, not a word to spell again. The options come off the sibling
  # attribute on the same node, so a filter renamed in the list above is the list this offers.
  defp collection_field(assigns) do
    ~H"""
    <form
      id={"pb-collection-form-#{@node.id}-#{@name}-#{@index}-#{@key || "item"}"}
      phx-change="collection_set"
      phx-submit="collection_set"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
      phx-value-index={@index}
      phx-value-key={@key}
      class="min-w-0 flex-1"
    >
      <div :if={@options != []} class="relative">
        <select
          name="value"
          class="h-[26px] w-full cursor-pointer appearance-none rounded-[7px] border border-[#ecebe6] bg-white ps-1.5 pe-8 text-[11px] font-semibold text-[#3a382f]"
        >
          <option value="">{gettext("— none —")}</option>
          <option :for={option <- @options} value={option} selected={printable(@value) == option}>
            {option}
          </option>
        </select>
        <.select_chevron />
      </div>

      <input
        :if={@options == []}
        type="text"
        name="value"
        value={printable(@value)}
        phx-debounce="350"
        class="h-[26px] w-full rounded-[7px] border border-[#ecebe6] bg-white px-1.5 text-[11px] font-medium text-[#3a382f]"
      />
    </form>
    """
  end

  # WHATEVER IS IN THERE, AS A WORD. A collection is a kit's own data and may hold anything its
  # component reads; the field shows what can be shown and leaves the rest to the expression.
  defp printable(value) when is_binary(value), do: value
  defp printable(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp printable(value), do: inspect(value)

  # A picture is the one field in a card that has a library behind it. Read off the key's name, the
  # same question `Inspector.widget/3` asks of an attribute.
  defp picture_key?(key), do: Inspector.element_widget("img", to_string(key)) == :media

  defp picture(%{} = item) do
    Enum.find_value(item, fn {key, value} ->
      (picture_key?(key) and is_binary(value) and value) || nil
    end)
  end

  defp picture(_item), do: nil

  # The picture first, then the words, then whatever else the kit put there.
  defp key_rank(key) do
    case to_string(key) do
      name when name in ~w(src image poster) -> {0, name}
      name when name in ~w(alt title label) -> {1, name}
      name -> {2, name}
    end
  end

  # THE LIST THIS ONE IS CATEGORISED BY. `chelekom-filterable-gallery` keeps its buttons in
  # `filters` and each picture's `category` has to be one of them; nothing else in the kit pairs two
  # collections this way, so this is asked of the node rather than declared anywhere.
  defp sibling_options(node, "media"), do: strings_in(node, "filters")
  defp sibling_options(_node, _name), do: []

  # THE LIST BELONGS TO ONE KEY, NOT TO THE WHOLE ROW. `sibling_options/2` answers "a filterable
  # gallery's categories come from its filters", which is about `category` and about nothing else —
  # but it was handed to every key in the item that was not a picture, so `alt` drew a dropdown of
  # Branding / Web design / Print and the alt text of a photograph could not be typed at all.
  #
  # Named here rather than guessed at: a key is offered a sibling's list only when that is what the
  # list is a list of. Everything else gets the text box it always should have had.
  @drawn_from_siblings %{"media" => "category"}

  defp options_for(name, key, options) do
    if Map.get(@drawn_from_siblings, name) == to_string(key), do: options, else: []
  end

  defp strings_in(node, name) do
    case Collection.read(node, name, []) do
      {:ok, items} -> Enum.filter(items, &is_binary/1)
      :error -> []
    end
  end

  # Hidden from visitors on this row: `:self` where it was hidden, `:parent` inside a hidden one.
  defp visitor_off(tree, id) do
    case Visibility.hidden_by(tree, id) do
      nil -> nil
      %{id: ^id} -> :self
      _container -> :parent
    end
  end

  # "Layout" is both a property group of a COMPONENT and a section of the style panel, so the fold
  # state is namespaced by which one it is — otherwise closing one closed the other, and the two
  # headings collided on the same DOM id.
  defp folded?(folds, scope, name, default), do: Map.get(folds, "#{scope}:#{name}", default)

  # "Editing at" is a heading, not an id. A space in one is invalid HTML and unaddressable from a
  # selector, which is how the fold toggle came to be untestable and unclickable.
  defp slug(title), do: title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  attr(:id, :string, required: true)
  attr(:event, :string, default: "op", doc: "the change event; `op` for anything editing a node")
  attr(:rest, :global)
  slot(:inner_block, required: true)

  @doc false
  # Every editable field lives in one of these.
  #
  # Two reasons, and the second is the one that bites. A bare `<input phx-change>` outside a form
  # fires NOTHING — LiveView binds change events through forms — and the `phx-value-*` that say which
  # property is being written are only merged into the payload for form events. That is the same trap
  # that left every dropdown in this panel inert.
  #
  # The first reason is what the reader feels: committing on `phx-blur` meant a change only landed
  # when you clicked somewhere else, so typing a title and looking at the canvas showed nothing until
  # you clicked away. With `phx-debounce` on the input the field commits itself while you type.
  def field_form(assigns) do
    ~H"""
    <form id={@id} phx-change={@event} phx-submit={@event} {@rest}>
      {render_slot(@inner_block)}
    </form>
    """
  end

  # The text box every control that has nothing better falls back to — including the icon picker on a
  # host that ships no heroicons.
  defp plain_input(assigns) do
    ~H"""
    <.field_form
      id={"pb-attr-form-#{@node.id}-#{@name}"}
      phx-value-kind="set_attr"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
    >
      <input
        type="text"
        id={"pb-attr-#{@name}"}
        name="value"
        value={@value}
        placeholder={default_text(@default)}
        phx-debounce="350"
        class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-medium text-[#3a382f]"
      />
    </.field_form>
    """
  end

  # Loose on purpose: a relative `/about` is as much a link as an absolute one, and refusing to offer
  # Open for one would be wrong more often than guessing right.
  defp openable?(value) when is_binary(value),
    do:
      MishkaCmsCore.Runtime.OriginValidator.web_url?(value) or
        MishkaCmsCore.Runtime.OriginValidator.site_path?(value)

  defp openable?(_value), do: false

  # A named kit colour has no hex the panel can know, so the chip shows the literal when it is one
  # and a neutral otherwise rather than guessing wrong.
  defp swatch("#" <> _rest = value), do: value
  defp swatch(_value), do: "#f2f1ec"

  defp component_entry(%{selected_node: %Node{kind: :component} = node, editor: editor} = assigns) do
    name = Node.component_name(node)

    Enum.find(editor.components, &(&1.name == name)) || own_declaration(assigns, node, name)
  end

  # A slot has properties of its own. Phoenix declares them in the slot's block —
  # `slot :item do attr :id, :string end` — so they live on the OWNING component, not on the slot
  # node, and 63 of the kit's components use them. Looking the parent up and handing the slot's own
  # block back as an entry is what puts them in the inspector; selecting a slot that declares six
  # properties used to read "Nothing set yet".
  #
  # `slots: []` is not laziness: a slot cannot contain another slot, so there is nothing to list.
  defp component_entry(%{selected_node: %Node{kind: :slot} = node, editor: editor}) do
    with %Node{} = parent <- Tree.get(editor.tree, node.parent_id),
         %{} = entry <- Enum.find(editor.components, &(&1.name == Node.component_name(parent))),
         %{} = slot <-
           Enum.find(Inspector.slots(entry), &(Inspector.name(&1) == Node.slot_name(node))) do
      # The parent's feature map comes along: a slot's `color` or `size` is drawn from the SAME
      # option lists the component's own are, and the panel reads `entry.features` unconditionally —
      # without this key, selecting any slot raised `KeyError :features` and took the editor down.
      %{
        name: Node.slot_name(node),
        attrs: Inspector.attrs(slot),
        slots: [],
        features: Map.get(entry, :features, %{})
      }
    else
      _no_declaration -> nil
    end
  end

  defp component_entry(_assigns), do: nil

  defp override?(_node, :base, _prop), do: false
  defp override?(node, bucket, prop), do: own_style(node, bucket, prop)

  # `inner_block` is deliberately absent: it is not a slot you add, it is the content you put inside
  # the component. Offering it as one emitted `<:inner_block></:inner_block>`, which the HEEx compiler
  # refuses outright — "the slot name :inner_block is reserved" — so the button could only ever fail.
  defp slot_entries(assigns) do
    case component_entry(assigns) do
      nil -> []
      entry -> Inspector.addable_slots(entry)
    end
  end

  # THE DECLARATION FOR A COMPONENT YOU ARE STANDING INSIDE.
  #
  # `editor.components` is the palette, and the palette is missing exactly the two things a
  # component builder meets in its own markup. The component being edited is kept out of it so it
  # cannot be dropped into itself — `chelekom-menu` renders itself for its submenus, so its own
  # inner node had no declaration and drew a panel with no properties, no slots and no docs. And a
  # component's private helpers (`<.badge_dismiss>`, twenty-three of them across the kit) are never
  # in the palette at all, because `palette_entry/1` deliberately drops the `helpers` column — it is
  # 87% of the palette's weight, and the palette rides inside the editing session.
  #
  # Both are on the record in hand, so both are answered from it. Built off the component's own
  # entry with the helper's declaration swapped in, so a helper inherits every other key an entry
  # carries rather than needing a second list of them here.
  defp own_declaration(%{record: %{} = record}, node, name) do
    cond do
      to_string(Map.get(record, :name)) == name -> record_entry(record, name, record)
      helper = local_helper(record, node) -> record_entry(record, name, helper)
      true -> nil
    end
  end

  defp own_declaration(_assigns, _node, _name), do: nil

  # A dotted tag that is not `<.component>` names a function in the component's own prelude, which
  # is where its `attrs` and `slots` are declared.
  defp local_helper(record, %Node{tag: "." <> _rest} = node) do
    wanted = Node.component_name(node)

    record
    |> Map.get(:helpers)
    |> List.wrap()
    |> Enum.find(fn helper -> to_string(Inspector.name(helper)) == wanted end)
  end

  defp local_helper(_record, _node), do: nil

  defp record_entry(record, name, declaring) do
    %{
      id: Map.get(record, :id),
      key: name,
      name: name,
      label: Phoenix.Naming.humanize(String.replace(name, "-", "_")),
      type: Map.get(record, :type) || "general",
      description: Map.get(record, :description),
      template: Map.get(record, :template),
      attrs: Inspector.attrs(declaring),
      slots: Inspector.slots(declaring),
      features: Inspector.features(declaring),
      examples: [],
      global?: is_nil(Map.get(record, :site_id))
    }
  end

  defp inner_block_slot?(assigns) do
    case component_entry(assigns) do
      nil -> false
      entry -> entry |> Inspector.slots() |> Enum.any?(&Inspector.inner_block?/1)
    end
  end

  attr(:title, :string,
    default: nil,
    doc: "omit to render the fields alone, inside another section"
  )

  attr(:props, :list, required: true)
  attr(:node, :any, required: true)
  attr(:bucket, :atom, required: true)
  attr(:breakpoint, :atom, required: true)
  attr(:pseudo, :atom, required: true)
  attr(:group_folds, :map, default: %{})
  attr(:folded_by_default, :boolean, default: false)
  attr(:covered, :map, default: %{})

  slot(:pre, doc: "controls shown above the field grid, folding with it")

  # One group of style overrides, written into whichever bucket the breakpoint tab / State chips
  # currently name. Each row shows where its effective value comes from — the prototype's
  # `inherited` / `from desktop` provenance — and an override dot that resets just this bucket.
  defp style_group(assigns) do
    ~H"""
    <section class={[!@title && "contents"]}>
      <.fold_heading
        :if={@title}
        title={@title}
        group_folds={@group_folds}
        folded_by_default={@folded_by_default}
      />

      <div
        :if={
          @pre != [] and (!@title or !folded?(@group_folds, "section", @title, @folded_by_default))
        }
        class="mb-3"
      >
        {render_slot(@pre)}
      </div>

      <div
        :if={!@title or !folded?(@group_folds, "section", @title, @folded_by_default)}
        class="grid grid-cols-2 gap-2.5"
      >
        <%!-- A `div` rather than a `label`, because an enumerated property's control is a form (see
              below) and a form is not valid inside a label. --%>
        <div :for={{prop, label} <- @props} class={["min-w-0", labelled?(prop) && "col-span-2"]}>
          <span class="mb-1.5 flex items-center gap-1.5">
            <span class="min-w-0 truncate text-[10.5px] font-semibold text-[#6d6a63]">{translate(
              label
            )}</span>
            <%!-- Only away from base. At Desktop/Normal the value IS the element's value, not an
                  override of one, and marking it as such made every styled element look edited. --%>
            <span
              :if={override?(@node, @bucket, prop)}
              title={gettext("Set for %{bucket}", bucket: source_word(@bucket))}
              class="size-[6px] flex-none rounded-full bg-[#5b57d6]"
            />
            <.overruled covered={@covered} prop={prop} />
            <span class="flex-1"></span>
            <button
              :if={override?(@node, @bucket, prop)}
              type="button"
              id={"pb-style-clear-#{@bucket}-#{prop}"}
              phx-click="op"
              phx-value-kind="set_style"
              phx-value-node_id={@node.id}
              phx-value-bucket={@bucket}
              phx-value-prop={prop}
              value=""
              title={gettext("Clear this %{bucket} override", bucket: source_word(@bucket))}
              class="h-[19px] flex-none rounded-[5px] border border-[#ecebe6] bg-white px-1.5 text-[10px] font-bold text-[#6d6a63] hover:border-[#e8b7b1] hover:text-[#d5544b]"
            >
              {gettext("Reset")}
            </button>
            <span
              :if={!own_style(@node, @bucket, prop) && inherited_from(@node, @bucket, prop)}
              class="flex-none text-[9px] font-bold text-[#a8a5a0]"
            >
              {gettext("from %{source}", source: inherited_from(@node, @bucket, prop))}
            </span>
          </span>
          <%!-- The `phx-value-*` that say WHICH override this is are only merged into the payload
                for form events — a bare `<select phx-change>` sends nothing but its own value, so the
                op would arrive with no node, bucket or property. --%>
          <div :if={labelled?(prop)} class="flex flex-wrap gap-1">
            <button
              :for={{value, title, tailwind, _css} <- Styles.labels(prop)}
              type="button"
              id={"pb-style-#{@bucket}-#{prop}-#{value}"}
              phx-click="op"
              phx-value-kind="set_style"
              phx-value-node_id={@node.id}
              phx-value-bucket={@bucket}
              phx-value-prop={prop}
              value={(own_style(@node, @bucket, prop) == value && "") || value}
              title={Styles.value_title(prop, value)}
              aria-pressed={to_string(own_style(@node, @bucket, prop) == value)}
              class={[
                "h-[27px] min-w-[52px] flex-1 rounded-[8px] border px-2 text-[10.5px]",
                (own_style(@node, @bucket, prop) == value &&
                   "border-[#5b57d6] bg-[#f2f1fc] text-[#4f4bcc]") ||
                  "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63] hover:border-[#c3c1f0]"
              ]}
            >
              <span class={["block w-full truncate", tailwind]}>{translate(title)}</span>
            </button>
          </div>
          <.form
            :if={Styles.options(prop) != [] and !labelled?(prop)}
            for={%{}}
            id={"pb-style-form-#{@bucket}-#{prop}"}
            phx-change="op"
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop={prop}
          >
            <div class="relative">
              <select
                id={"pb-style-#{@bucket}-#{prop}"}
                name="value"
                class={[
                  "h-9 w-full cursor-pointer appearance-none rounded-[9px] border py-0 ps-2.5 pe-8 text-[11.5px] font-semibold text-[#3a382f] outline-none",
                  (own_style(@node, @bucket, prop) && "border-[#c3c1f0] bg-white") ||
                    "border-[#ecebe6] bg-[#faf9f6]"
                ]}
              >
                <option value="">{effective_style(@node, @bucket, prop) || gettext("unset")}</option>
                <option
                  :for={option <- Styles.options(prop)}
                  value={option}
                  selected={own_style(@node, @bucket, prop) == option}
                >
                  {option}
                </option>
              </select>
              <.select_chevron />
            </div>
          </.form>
          <.field_form
            :if={Styles.options(prop) == []}
            id={"pb-style-form-#{@bucket}-#{prop}"}
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop={prop}
          >
            <%!-- WHAT THE BOX TAKES, when there is nothing in it to imply it. These fields accept
                  any CSS length — `50%`, `2rem`, `600px`, `calc(100% - 2rem)` — and a bare number is
                  read as pixels. The placeholder said "unset", so an author who typed `1000`, got
                  pixels and had no reason to try anything else concluded the field was pixels-only,
                  and reported it as such. Gap has said "any length, e.g. 2rem" all along; the rest
                  now say it too. Only when empty: an inherited value is a better hint than any
                  sentence, and it goes on saying what the element actually has. --%>
            <input
              type="text"
              id={"pb-style-#{@bucket}-#{prop}"}
              name="value"
              value={own_style(@node, @bucket, prop)}
              placeholder={effective_style(@node, @bucket, prop) || length_hint(prop)}
              phx-debounce="350"
              data-inherited={
                (!own_style(@node, @bucket, prop) && effective_style(@node, @bucket, prop) &&
                   "true") || nil
              }
              class={
                [
                  "h-9 w-full rounded-[9px] border px-2.5 font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#1b1a18] outline-none",
                  (own_style(@node, @bucket, prop) && "border-[#c3c1f0] bg-white") ||
                    "border-[#ecebe6] bg-[#faf9f6]",
                  # A VALUE THE AUTHOR SET IS NOT AN EXAMPLE. An empty field's placeholder is a
                  # made-up hint — "any length, e.g. 2rem" — and a field inheriting from another
                  # bucket showed the REAL value in the same grey, so `1000px` read as a suggestion
                  # rather than as the width this element actually has. Reported as the value being
                  # missing on reopen, which is how an inherited value that looks like a hint reads.
                  #
                  # Darker and not italic, so it is legibly a value, while staying lighter than an own
                  # value so the two are still told apart at a glance. The `from base` chip beside the
                  # label says where it comes from; this says it is real.
                  !own_style(@node, @bucket, prop) && effective_style(@node, @bucket, prop) &&
                    "placeholder:font-semibold placeholder:text-[#6d6a63]"
                ]
              }
            />
          </.field_form>
        </div>
      </div>
    </section>
    """
  end

  attr(:node, :map, required: true)
  attr(:bucket, :string, required: true)
  attr(:prop, :string, required: true)
  attr(:token, :string, required: true)
  attr(:value, :string, required: true)
  attr(:label, :string, required: true)

  @doc false
  # ONE OF THE SITE'S OWN COLOURS, and the reason to prefer it over the hex beside it: it writes
  # `var(--danger-light)`, so the element resolves through the same declaration every component on
  # the site resolves through. Change the token in the Studio and this element changes with
  # everything else — which is what "rebrand" means, and what typing `#de1135` here can never do.
  #
  # Drawn in the colour it actually is, read from the stylesheet rather than from a list here: a
  # swatch that shows the editor's idea of `--danger-light` would be wrong the moment somebody
  # edited it.
  #
  # SMALLER THAN THE FIVE ABOVE, and folded away behind a count. A kit theme declares every state of
  # every variant — the installed one is 251 colours — so a row of them at the neutrals' size is a
  # wall the Background control disappears into. The five that are always open are the editor's own;
  # these are the site's, and worth a click.
  defp token_swatch(assigns) do
    ~H"""
    <button
      type="button"
      id={"pb-token-#{@bucket}-#{@prop}-#{String.trim_leading(@token, "-")}"}
      phx-click="op"
      phx-value-kind="set_style"
      phx-value-node_id={@node.id}
      phx-value-bucket={@bucket}
      phx-value-prop={@prop}
      value={(own_style(@node, @bucket, @prop) == var(@token) && "") || var(@token)}
      title={"#{@label} — #{@token} (#{@value})"}
      aria-label={@label}
      aria-pressed={to_string(own_style(@node, @bucket, @prop) == var(@token))}
      class={[
        "size-[24px] rounded-[7px] border-2",
        (own_style(@node, @bucket, @prop) == var(@token) && "border-[#5b57d6]") ||
          "border-[#ecebe6]"
      ]}
      style={"background:#{@value}"}
    ></button>
    """
  end

  # A CUSTOM PROPERTY IS ALWAYS TWO DASHES, and a token's key reaches here spelled either way
  # depending on which sheet declared it. Normalising here is what stops `var(danger-light)` — a
  # reference to nothing, in a page that then paints its default and reads as a broken control.
  #
  # Joined rather than interpolated on purpose. This is a CSS VALUE, not a class name — it becomes
  # the element's `background` override, and the class around it (`bg-[var(--danger-light)]`) is
  # assembled by `Tree.Styles` and written into the stored template, where the per-site Tailwind pass
  # finds it. `interpolated_class_test.exs` cannot tell those apart from the outside, and earning a
  # whole-file exemption for one line would blunt it across eleven thousand.
  defp var(token), do: "var(--" <> String.trim_leading(token, "-") <> ")"

  attr(:node, :map, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, required: true)
  attr(:kind, :string, required: true, doc: "what the attribute holds — `string` or `expr`")
  attr(:widget, :atom, required: true)

  @doc false
  # THE SAME AFFORDANCES A COMPONENT'S PROPERTIES GET, for the attributes nobody declared. Everything
  # in this list used to be a text box, so a block's `<img src>` was a path to type from memory while
  # the media library sat one panel away, and its `<a href>` was a URL with nothing to check it
  # against — on the two attributes a page is most often edited through.
  #
  # `Inspector.element_widget/2` reads the TAG as well as the name, which is what separates a
  # picture's `src` from an `<iframe>`'s. Ids are `pb-attr-row-*` and not `pb-attr-*`: a component
  # node draws its declared properties above this list and both would answer to the same id.
  defp attr_row_control(%{widget: :media} = assigns) do
    ~H"""
    <.attr_row_field node={@node} name={@name} kind={@kind} value={@value} />
    <button
      type="button"
      id={"pb-attr-row-pick-#{@name}"}
      phx-click="pick_media"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
      title={gettext("Choose from the media library")}
      class="grid size-[18px] flex-none place-items-center rounded-[5px] text-[#4f4bcc] hover:bg-[#f2f1fc]"
    >
      <.icon name={:image} size={11} />
    </button>
    """
  end

  defp attr_row_control(%{widget: :url} = assigns) do
    ~H"""
    <.attr_row_field node={@node} name={@name} kind={@kind} value={@value} />
    <a
      :if={openable?(@value)}
      href={@value}
      target="_blank"
      rel="noopener noreferrer"
      id={"pb-attr-row-open-#{@name}"}
      title={gettext("Open in a new tab")}
      class="grid size-[18px] flex-none place-items-center rounded-[5px] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
    >
      <.icon name={:external} size={11} />
    </a>
    """
  end

  defp attr_row_control(%{widget: :color} = assigns) do
    ~H"""
    <span
      class="size-[14px] flex-none rounded-[4px] border border-[#ecebe6]"
      style={"background:#{swatch(@value)}"}
    />
    <.attr_row_field node={@node} name={@name} kind={@kind} value={@value} />
    """
  end

  defp attr_row_control(assigns) do
    ~H"""
    <.attr_row_field node={@node} name={@name} kind={@kind} value={@value} />
    """
  end

  attr(:node, :map, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, required: true)
  attr(:kind, :string, required: true, doc: "what the attribute holds — `string` or `expr`")

  @doc false
  defp attr_row_field(assigns) do
    ~H"""
    <.field_form
      id={"pb-attr-row-form-#{@node.id}-#{@name}"}
      class="min-w-0 flex-1"
      phx-value-kind="set_attr"
      phx-value-node_id={@node.id}
      phx-value-name={@name}
      phx-value-value_kind={@kind}
    >
      <input
        type="text"
        id={"pb-attr-row-#{@name}"}
        value={@value}
        name="value"
        phx-debounce="350"
        class="w-full truncate border-0 bg-transparent p-0 font-['Space_Grotesk'] text-[11px] font-medium text-[#3a382f] outline-none"
      />
    </.field_form>
    """
  end

  # A ROW OF WORDS, EACH DRAWN AS THE THING IT NAMES. The select `style_group/1` falls back to spells
  # an enumerated value the way Tailwind does — `font-extrabold`, `normal-case` — which is a class
  # name to decode rather than a choice to make. A labelled property carries its own words instead,
  # styled by the rule it sets: Bold is bold, UPPER is upper case, Dashed is underlined with a dashed
  # rule. Clicking the one already chosen clears it, the same as a swatch.
  defp labelled?(prop), do: Styles.labels(prop) != []

  # Whether the axis pair holds anything worth opening the fold for: an override written into this
  # bucket, or a hand-written declaration that has taken one of them over.
  defp axes_in_play?(node, bucket, covered) do
    Enum.any?(@axis_props, fn {prop, _label} ->
      own_style(node, bucket, prop) || covered[prop]
    end)
  end

  attr(:node, :map, required: true)
  attr(:bucket, :string, required: true)
  attr(:covered, :map, required: true)

  @doc false
  # A SHADOW IS SIX DECISIONS, NOT ONE STRING. `0 10px 24px -4px rgba(15,23,42,.18)` is a value people
  # paste, not one they write — so a single text box for it is a control that only helps somebody who
  # already had the answer. Which side the shadow falls on is two numbers; how soft it is, a third.
  #
  # Taken apart they are all nudgeable, which is exactly what Chrome's own shadow editor does and why
  # its numbers are the ones designers reach for. The presets are above them because elevation is a
  # scale before it is a measurement: most of the time the answer is "a bit more than that one", and
  # each swatch really casts the shadow it offers — the rule the layout pictures already follow, and
  # the only way "L" means anything before you click it.
  #
  # Inset is a switch beside the numbers rather than a fifth preset, because an inner shadow is a
  # different thing and not a smaller one: a pressed field rather than a lifted card.
  defp shadow_editor(assigns) do
    assigns = assign(assigns, :parts, shadow_parts(assigns.node, assigns.bucket))

    ~H"""
    <section>
      <div class="mb-[7px] flex items-center gap-1.5">
        <span class="text-[10.5px] font-semibold text-[#6d6a63]">{gettext("Shadow")}</span>
        <span
          :if={own_style(@node, @bucket, "shadow")}
          title={gettext("Set for %{bucket}", bucket: source_word(@bucket))}
          class="size-[6px] flex-none rounded-full bg-[#5b57d6]"
        />
        <.overruled covered={@covered} prop="shadow" />
        <span class="flex-1"></span>
        <button
          :if={own_style(@node, @bucket, "shadow")}
          type="button"
          id={"pb-shadow-clear-#{@bucket}"}
          phx-click="op"
          phx-value-kind="set_style"
          phx-value-node_id={@node.id}
          phx-value-bucket={@bucket}
          phx-value-prop="shadow"
          value=""
          title={gettext("Clear this %{bucket} override", bucket: source_word(@bucket))}
          class="h-[19px] flex-none rounded-[5px] border border-[#ecebe6] bg-white px-1.5 text-[10px] font-bold text-[#6d6a63] hover:border-[#e8b7b1] hover:text-[#d5544b]"
        >
          {gettext("Reset")}
        </button>
      </div>

      <div class="flex items-stretch gap-[7px]">
        <button
          :for={{name, value} <- Shadow.presets()}
          type="button"
          id={"pb-shadow-preset-#{String.downcase(name)}"}
          phx-click="op"
          phx-value-kind="set_style"
          phx-value-node_id={@node.id}
          phx-value-bucket={@bucket}
          phx-value-prop="shadow"
          value={(own_style(@node, @bucket, "shadow") == value && "") || value}
          title={gettext("Shadow %{value}", value: value)}
          aria-pressed={to_string(own_style(@node, @bucket, "shadow") == value)}
          class={[
            "grid h-[34px] flex-1 place-items-center rounded-[9px] border-2",
            (own_style(@node, @bucket, "shadow") == value && "border-[#5b57d6]") ||
              "border-[#ecebe6]"
          ]}
        >
          <span
            class="grid size-[17px] place-items-center rounded-[5px] bg-white text-[8.5px] font-bold text-[#6d6a63]"
            style={"box-shadow: #{value}"}
          >
            {name}
          </span>
        </button>
      </div>

      <div class="mt-[9px] grid grid-cols-4 gap-1.5">
        <.shadow_field
          :for={{field, label} <- shadow_fields()}
          node={@node}
          bucket={@bucket}
          field={field}
          label={label}
          value={Map.get(@parts, field)}
        />
      </div>

      <div class="mt-1.5 flex items-center gap-1.5">
        <.field_form
          id={"pb-shadow-form-#{@bucket}-color"}
          event="set_shadow"
          class="min-w-0 flex-1"
          phx-value-node_id={@node.id}
          phx-value-bucket={@bucket}
          phx-value-field="color"
        >
          <input
            type="text"
            id={"pb-shadow-#{@bucket}-color"}
            name="value"
            value={@parts.color}
            aria-label={gettext("Shadow colour")}
            phx-debounce="350"
            class="h-[27px] w-full rounded-[7px] border border-[#ecebe6] bg-white px-2 font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#3a382f] outline-none"
          />
        </.field_form>

        <button
          type="button"
          id={"pb-shadow-#{@bucket}-inset"}
          phx-click="set_shadow"
          phx-value-node_id={@node.id}
          phx-value-bucket={@bucket}
          phx-value-field="inset"
          value={to_string(!@parts.inset)}
          title={gettext("Cast the shadow inside the element instead of behind it")}
          aria-pressed={to_string(@parts.inset)}
          class={[
            "h-[27px] flex-none rounded-[7px] border px-2.5 text-[10.5px] font-bold",
            (@parts.inset && "border-[#5b57d6] bg-[#f2f1fc] text-[#4f4bcc]") ||
              "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63]"
          ]}
        >
          {gettext("Inside")}
        </button>
      </div>
    </section>
    """
  end

  # RIGHT AND DOWN, not X and Y. The axis names are what CSS calls them and what nobody else does;
  # a reader deciding which way the shadow falls is choosing a direction, not naming an axis.
  defp shadow_fields,
    do: [
      {:x, gettext("Right")},
      {:y, gettext("Down")},
      {:blur, gettext("Blur")},
      {:spread, gettext("Spread")}
    ]

  # What the controls open on: the element's own shadow when it has one this can hold, and otherwise
  # a shadow worth seeing — nudging Down on `0 0 0 0 transparent` would move nothing at all.
  defp shadow_parts(node, bucket) do
    case Shadow.parse(effective_style(node, bucket, "shadow")) do
      {:ok, parts} -> parts
      :error -> Shadow.default()
    end
  end

  attr(:node, :map, required: true)
  attr(:bucket, :string, required: true)
  attr(:field, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  @doc false
  defp shadow_field(assigns) do
    ~H"""
    <.field_form
      id={"pb-shadow-form-#{@bucket}-#{@field}"}
      event="set_shadow"
      phx-value-node_id={@node.id}
      phx-value-bucket={@bucket}
      phx-value-field={@field}
    >
      <label class="block">
        <span class="mb-1 block text-[9px] font-bold uppercase tracking-[.08em] text-[#a8a5a0]">
          {@label}
        </span>
        <input
          type="text"
          id={"pb-shadow-#{@bucket}-#{@field}"}
          name="value"
          value={@value}
          phx-debounce="350"
          class="h-[27px] w-full rounded-[7px] border border-[#ecebe6] bg-white text-center font-['Space_Grotesk'] text-[10.5px] font-bold text-[#3a382f] outline-none"
        />
      </label>
    </.field_form>
    """
  end

  attr(:node, :map, required: true)
  attr(:bucket, :string, required: true)
  attr(:covered, :map, required: true)

  @doc false
  # THE ELEMENT, DRAWN, WITH ITS EDGES WHERE THEY ARE. Spacing was eight numbers in a two-column list
  # of `Padding Y`, `Padding X`, `Padding top`, `Padding bottom` — four of the eight edges missing
  # outright, and the four that existed named in a vocabulary you have to translate before you can
  # use it. Nobody thinks "padding-block". They think "more room under this heading", and they point.
  #
  # So this is the box model, the same shape Chrome, Figma and every builder draws it in: margin
  # outside, padding inside, and each edge sitting where it will actually apply. Reading which edge a
  # value is on stops being a matter of remembering what the label meant.
  #
  # Each cell is its own tiny form for the reason every field in this panel is: a bare input outside
  # one fires nothing, and the `phx-value-*` naming the property are only merged for form events.
  defp spacing_box(assigns) do
    ~H"""
    <div class="rounded-[11px] border border-[#ecebe6] bg-[#faf9f6] p-2">
      <div class="mb-1 flex items-center gap-1.5">
        <span class="text-[9px] font-bold uppercase tracking-[.09em] text-[#a8a5a0]">{gettext(
          "Margin"
        )}</span>
      </div>

      <div class="grid grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)_minmax(0,1fr)] items-center gap-1">
        <span></span>
        <.edge_field
          node={@node}
          bucket={@bucket}
          covered={@covered}
          prop="mt"
          label={gettext("Top")}
        />
        <span></span>

        <.edge_field
          node={@node}
          bucket={@bucket}
          covered={@covered}
          prop="ml"
          label={gettext("Left")}
        />

        <div class="rounded-[9px] border border-[#e4e2f7] bg-white p-1.5">
          <div class="mb-1 flex items-center justify-center gap-1.5">
            <span class="text-[9px] font-bold uppercase tracking-[.09em] text-[#8580d8]">
              {gettext("Padding")}
            </span>
          </div>

          <div class="grid grid-cols-3 items-center gap-1">
            <span></span>
            <.edge_field
              node={@node}
              bucket={@bucket}
              covered={@covered}
              prop="pt"
              label={gettext("Top")}
            />
            <span></span>

            <.edge_field
              node={@node}
              bucket={@bucket}
              covered={@covered}
              prop="pl"
              label={gettext("Left")}
            />
            <span class="text-center text-[9px] font-semibold text-[#c2c0ba]">{gettext("content")}</span>
            <.edge_field
              node={@node}
              bucket={@bucket}
              covered={@covered}
              prop="pr"
              label={gettext("Right")}
            />

            <span></span>
            <.edge_field
              node={@node}
              bucket={@bucket}
              covered={@covered}
              prop="pb"
              label={gettext("Bottom")}
            />
            <span></span>
          </div>
        </div>

        <.edge_field
          node={@node}
          bucket={@bucket}
          covered={@covered}
          prop="mr"
          label={gettext("Right")}
        />

        <span></span>
        <.edge_field
          node={@node}
          bucket={@bucket}
          covered={@covered}
          prop="mb"
          label={gettext("Bottom")}
        />
        <span></span>
      </div>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:bucket, :string, required: true)
  attr(:covered, :map, required: true)
  attr(:prop, :string, required: true)
  attr(:label, :string, required: true)

  @doc false
  # One edge. The placeholder is what the edge reads as WITHOUT an override — inherited from a wider
  # breakpoint, or from the element's own classes — so an empty cell still tells you what is there,
  # and typing over it is visibly a change rather than a first value.
  #
  # `-` rather than `0` when nothing is set anywhere: a zero would be a lie about an element with
  # `p-4` on it, and this box cannot read Tailwind's numeric scale.
  #
  # AND A SET EDGE HAS A WAY OUT THAT IS NOT THE KEYBOARD. Emptying the text was the only way to
  # clear one, which fails in the one way a control must not: the field goes blank, the change does
  # not reach the server, and the next render puts the old value back — so it reads as a box that
  # remembers what you deleted. Every other control in this panel has a Reset; this is the box's.
  defp edge_field(assigns) do
    ~H"""
    <div class="group/edge relative">
      <.overruled
        covered={@covered}
        prop={@prop}
        class="absolute -top-[3px] left-[3px] z-10"
      />

      <button
        :if={own_style(@node, @bucket, @prop)}
        type="button"
        id={"pb-edge-clear-#{@bucket}-#{@prop}"}
        phx-click="op"
        phx-value-kind="set_style"
        phx-value-node_id={@node.id}
        phx-value-bucket={@bucket}
        phx-value-prop={@prop}
        value=""
        title={gettext("Clear %{label}", label: @label)}
        aria-label={gettext("Clear %{label}", label: @label)}
        class="absolute -right-[4px] -top-[5px] z-10 grid size-[13px] place-items-center rounded-full border border-[#ecebe6] bg-white text-[#a8a5a0] opacity-0 hover:border-[#e8b7b1] hover:text-[#d5544b] focus:opacity-100 group-hover/edge:opacity-100"
      >
        <.icon name={:close} size={8} />
      </button>
      <.field_form
        id={"pb-edge-form-#{@bucket}-#{@prop}"}
        phx-value-kind="set_style"
        phx-value-node_id={@node.id}
        phx-value-bucket={@bucket}
        phx-value-prop={@prop}
      >
        <input
          type="text"
          id={"pb-edge-#{@bucket}-#{@prop}"}
          name="value"
          value={own_style(@node, @bucket, @prop)}
          placeholder={effective_style(@node, @bucket, @prop) || "–"}
          title={
            gettext("%{label} — %{property}",
              label: @label,
              property: Styles.declaration(@prop, "") |> elem(0)
            )
          }
          aria-label={@label}
          phx-debounce="350"
          class={[
            "h-[25px] w-full rounded-[7px] border text-center font-['Space_Grotesk'] text-[10.5px] font-bold outline-none",
            (own_style(@node, @bucket, @prop) &&
               "border-[#c3c1f0] bg-white text-[#4f4bcc]") ||
              "border-[#ecebe6] bg-white text-[#3a382f] placeholder:text-[#c2c0ba]"
          ]}
        />
      </.field_form>
    </div>
    """
  end

  attr(:covered, :map, required: true)
  attr(:prop, :string, required: true)
  attr(:class, :string, default: nil, doc: "where to put the dot when it is not in a heading row")

  @doc false
  # THE ONE PLACE A CONTROL SAYS IT HAS BEEN OVERRULED. A control writes a Tailwind utility; the
  # element's own CSS is emitted last and unlayered, so where the two name the same property the CSS
  # wins and the control moves nothing — which, without this, is a control that reads as broken.
  #
  # `#8580d8` rather than the `#5b57d6` beside it, because it is the colour the Custom CSS heading
  # already uses for "this element has its own CSS". Same idea, same dot: the panel gains a meaning,
  # not a palette.
  #
  # ONCE PER PROPERTY. `covered` is keyed by property and so is the id, so a property two widgets
  # offer — `background` is a swatch row AND a free-form field, the shape Gap has — has to draw the
  # dot on one of them. The field row `style_group` already draws is the one, because that list is
  # where every other appearance property carries it. Marking the swatch heading as well put
  # `pb-css-wins-background` in the document twice the moment an author wrote `background-color`
  # into Custom CSS, which is a DOM patch aiming at whichever it finds first.
  def overruled(assigns) do
    ~H"""
    <span
      :if={@covered[@prop]}
      id={"pb-css-wins-#{@prop}"}
      title={
        gettext("Custom CSS sets %{property} here, so it wins over this control.",
          property: @covered[@prop]
        )
      }
      class={["size-[6px] flex-none rounded-full bg-[#8580d8] ring-2 ring-[#efeefb]", @class]}
    />
    """
  end

  # Which controls this element's own CSS has taken over in the bucket the panel is writing to, each
  # against THE PROPERTY THE AUTHOR ACTUALLY WROTE. Padding top is overruled by `padding: 20px`, and
  # a note saying "Custom CSS sets padding-top here" would send them looking for a line that is not
  # in the box.
  #
  # Read off the text on every render rather than stored: the text is the record, and a stored copy
  # would be one Apply behind what the author is looking at.
  defp covered_controls(css, bucket) do
    css
    |> ElementCss.declarations()
    |> Enum.filter(&(&1.bucket == bucket))
    |> Enum.flat_map(fn declaration ->
      for control <- Styles.controls_for(declaration.property),
          do: {control, declaration.property}
    end)
    |> Map.new()
  end

  attr(:node, :any, required: true)
  attr(:bucket, :atom, required: true)
  attr(:covered, :map, default: %{})

  # THE SAME CONTROL THE CANVAS TOOLBAR USES, in the panel. Direction, Spread, Align and Wrap were
  # `<select>`s listing `justify-around` and `items-baseline` — the serialiser's vocabulary shown raw
  # to someone who is here because they do not write CSS. Each option is a picture of itself now,
  # laid out with the rule it applies, over a plain-words name, and the whole row is one click rather
  # than open-scan-choose.
  #
  # `Styles.pictures/1` is the single vocabulary both panels read, so the toolbar and the Inspector
  # cannot offer different sets of the same property.
  defp layout_pictures(assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5">
      <div
        :for={{prop, label} <- picture_rows(@node, @bucket)}
        id={"pb-style-pics-#{@bucket}-#{prop}"}
      >
        <div class="mb-1.5 flex items-center gap-1.5">
          <span class="text-[10.5px] font-semibold text-[#6d6a63]">{translate(label)}</span>
          <span
            :if={override?(@node, @bucket, prop)}
            title={gettext("Set for %{bucket}", bucket: source_word(@bucket))}
            class="size-[6px] flex-none rounded-full bg-[#5b57d6]"
          />
          <.overruled covered={@covered} prop={prop} />
          <span class="flex-1"></span>
          <button
            :if={override?(@node, @bucket, prop)}
            type="button"
            id={"pb-style-clear-#{@bucket}-#{prop}"}
            phx-click="op"
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop={prop}
            value=""
            title={gettext("Clear this %{bucket} override", bucket: source_word(@bucket))}
            class="h-[19px] flex-none rounded-[5px] border border-[#ecebe6] bg-white px-1.5 text-[10px] font-bold text-[#6d6a63] hover:border-[#e8b7b1] hover:text-[#d5544b]"
          >
            {gettext("Reset")}
          </button>
          <span class="truncate text-[9.5px] font-bold text-[#a8a5a0]">
            {picture_hint(@node, @bucket, prop)}
          </span>
        </div>
        <div class="flex flex-wrap gap-1">
          <%!-- CLICKING THE CHOSEN ONE CLEARS IT. The value the button sends is `""` when it is
                already the current one, so the same press that set an override takes it off again —
                no separate reset dot for a control this small, and the server does no extra work to
                decide it. --%>
          <button
            :for={{value, title, tailwind, _css, bars} <- Styles.pictures(prop)}
            type="button"
            id={"pb-style-pic-#{@bucket}-#{prop}-#{value}"}
            phx-click="op"
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop={prop}
            value={(own_style(@node, @bucket, prop) == value && "") || value}
            title={translate(title)}
            aria-label={translate(title)}
            aria-pressed={to_string(own_style(@node, @bucket, prop) == value)}
            class={[
              "flex h-[26px] w-[34px] flex-none rounded-[7px] border p-[4px]",
              (own_style(@node, @bucket, prop) == value && "border-[#5b57d6] bg-[#f2f1fc]") ||
                "border-[#ecebe6] bg-[#faf9f6] hover:border-[#c3c1f0]"
            ]}
          >
            <span class={["size-full gap-[1.5px]", tailwind, swatch_extra(prop)]}>
              <span
                :for={index <- 1..bars//1}
                class={["rounded-[1.5px]", bar_tone(prop, index), bar_shape(prop, index)]}
              ></span>
            </span>
          </button>
        </div>
      </div>

      <div :if={grid?(@node, @bucket)} id={"pb-style-cols-#{@bucket}"}>
        <div class="mb-1.5 flex items-center gap-1.5">
          <span class="text-[10.5px] font-semibold text-[#6d6a63]">{gettext("Columns")}</span>
          <span
            :if={override?(@node, @bucket, "grid-cols")}
            title={gettext("Set for %{bucket}", bucket: source_word(@bucket))}
            class="size-[6px] flex-none rounded-full bg-[#5b57d6]"
          />
          <.overruled covered={@covered} prop="grid-cols" />
          <span class="flex-1"></span>
          <span class="flex-none text-[9.5px] font-semibold text-[#a8a5a0]">
            {effective_style(@node, @bucket, "grid-cols") || gettext("unset")}
          </span>
        </div>

        <div class="flex flex-wrap gap-[7px]">
          <button
            :for={count <- 1..6}
            type="button"
            id={"pb-style-cols-#{@bucket}-#{count}"}
            phx-click="op"
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop="grid-cols"
            value={(own_style(@node, @bucket, "grid-cols") == to_string(count) && "") || count}
            title={ngettext("%{count} column", "%{count} columns", count)}
            aria-label={ngettext("%{count} column", "%{count} columns", count)}
            aria-pressed={to_string(own_style(@node, @bucket, "grid-cols") == to_string(count))}
            class={[
              "flex h-[26px] w-[38px] flex-none rounded-[7px] border p-[4px]",
              (own_style(@node, @bucket, "grid-cols") == to_string(count) &&
                 "border-[#5b57d6] bg-[#f2f1fc]") ||
                "border-[#ecebe6] bg-[#faf9f6] hover:border-[#c3c1f0]"
            ]}
          >
            <span class="flex size-full gap-[1.5px]">
              <span
                :for={index <- 1..count//1}
                class={["flex-1 rounded-[1.5px]", bar_tone("grid-cols", index)]}
              ></span>
            </span>
          </button>
        </div>

        <.field_form
          id={"pb-style-form-#{@bucket}-grid-cols"}
          class="mt-1.5"
          phx-value-kind="set_style"
          phx-value-node_id={@node.id}
          phx-value-bucket={@bucket}
          phx-value-prop="grid-cols"
        >
          <input
            type="text"
            id={"pb-style-#{@bucket}-grid-cols"}
            name="value"
            value={own_style(@node, @bucket, "grid-cols")}
            placeholder={gettext("a track list, e.g. 2fr 1fr")}
            phx-debounce="350"
            class={[
              "h-8 w-full rounded-[8px] border px-2.5 font-['Space_Grotesk'] text-[11px] font-semibold text-[#1b1a18] outline-none",
              (own_style(@node, @bucket, "grid-cols") && "border-[#c3c1f0] bg-white") ||
                "border-[#ecebe6] bg-[#faf9f6]"
            ]}
          />
        </.field_form>
      </div>

      <%!-- Gap is free-form — any length is legal — but the row of names is what stops someone
            typing `16px` to get the thing every design system already calls medium. The field below
            still takes anything, and the two write the same override. --%>
      <div>
        <div class="mb-1.5 flex items-center gap-1.5">
          <span class="text-[10.5px] font-semibold text-[#6d6a63]">{gettext("Gap")}</span>
          <span
            :if={override?(@node, @bucket, "gap")}
            title={gettext("Set for %{bucket}", bucket: source_word(@bucket))}
            class="size-[6px] flex-none rounded-full bg-[#5b57d6]"
          />
          <.overruled covered={@covered} prop="gap" />
          <span class="flex-1"></span>
          <button
            :if={override?(@node, @bucket, "gap")}
            type="button"
            id={"pb-style-clear-#{@bucket}-gap"}
            phx-click="op"
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop="gap"
            value=""
            title={gettext("Clear this %{bucket} override", bucket: source_word(@bucket))}
            class="h-[19px] flex-none rounded-[5px] border border-[#ecebe6] bg-white px-1.5 text-[10px] font-bold text-[#6d6a63] hover:border-[#e8b7b1] hover:text-[#d5544b]"
          >
            {gettext("Reset")}
          </button>
          <span class="truncate text-[9.5px] font-bold text-[#a8a5a0]">
            {effective_style(@node, @bucket, "gap") || gettext("unset")}
          </span>
        </div>
        <div class="flex flex-wrap gap-1">
          <button
            :for={{value, label} <- Styles.gap_presets()}
            type="button"
            id={"pb-style-gap-#{@bucket}-#{label}"}
            phx-click="op"
            phx-value-kind="set_style"
            phx-value-node_id={@node.id}
            phx-value-bucket={@bucket}
            phx-value-prop="gap"
            value={(own_style(@node, @bucket, "gap") == value && "") || value}
            title={gettext("Gap %{value}", value: value)}
            aria-pressed={to_string(own_style(@node, @bucket, "gap") == value)}
            class={[
              "h-[26px] flex-none rounded-[7px] border px-2 font-['Space_Grotesk'] text-[10px] font-bold",
              (own_style(@node, @bucket, "gap") == value &&
                 "border-[#5b57d6] bg-[#f2f1fc] text-[#4f4bcc]") ||
                "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63] hover:border-[#c3c1f0]"
            ]}
          >
            {label}
          </button>
        </div>
        <.field_form
          id={"pb-style-form-#{@bucket}-gap"}
          class="mt-1.5"
          phx-value-kind="set_style"
          phx-value-node_id={@node.id}
          phx-value-bucket={@bucket}
          phx-value-prop="gap"
        >
          <input
            type="text"
            id={"pb-style-#{@bucket}-gap"}
            name="value"
            value={own_style(@node, @bucket, "gap")}
            placeholder={effective_style(@node, @bucket, "gap") || gettext("any length, e.g. 2rem")}
            phx-debounce="350"
            class={[
              "h-8 w-full rounded-[9px] border px-2.5 font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#1b1a18] outline-none",
              (own_style(@node, @bucket, "gap") && "border-[#c3c1f0] bg-white") ||
                "border-[#ecebe6] bg-[#faf9f6]"
            ]}
          />
        </.field_form>
      </div>
    </div>
    """
  end

  @flex_rows [
    {"direction", gettext_noop("Direction")},
    {"justify", gettext_noop("Spread")},
    {"align", gettext_noop("Align")},
    {"wrap", gettext_noop("Wrap")}
  ]

  # WHICH ROWS ARE WORTH SHOWING. Direction, Spread, Align and Wrap do nothing to an element that is
  # not a flex row, so they appear when it is one and stay out of the way when it is not.
  #
  # The EFFECTIVE display decides, not the open bucket's own: Tablet and Mobile inherit Desktop
  # unless they override it, so reading only the open bucket made these four vanish the moment you
  # switched to Mobile — on an element that is plainly still a row on screen.
  #
  # A ROW THAT ALREADY HOLDS A VALUE IS DRAWN WHATEVER THE DISPLAY IS. `align-items: center` moved
  # out of the CSS box onto an element that is not a row wrote an override with no control anywhere
  # on screen: nothing showed it, and the only way to take it off again was to clear the whole
  # bucket. An override doing nothing to the page is a reason to show it, not to hide it — and an
  # authored `items-center` on a `block` element parses into exactly the same state.
  defp picture_rows(node, bucket) do
    [
      {"display", gettext_noop("Layout")}
      | Enum.filter(@flex_rows, &drawn_row?(node, bucket, elem(&1, 0)))
    ]
  end

  defp drawn_row?(node, bucket, prop),
    do: flex_row?(node, bucket) or effective_style(node, bucket, prop) != nil

  defp flex_row?(node, bucket),
    do: (own_style(node, bucket, "display") || own_style(node, :base, "display")) == "flex"

  # The same question for a grid, and it has to be `effective_style/3` rather than the two `own`
  # lookups above: a block ships `grid grid-cols-3` in its class attribute, which is absorbed into
  # the base bucket on parse — but a reader who has switched to Mobile is on a bucket that owns
  # nothing, and the columns row would vanish on the one breakpoint where changing it matters most.
  # HOW MANY COLUMNS, DRAWN AS COLUMNS, and only where columns mean something. Making an element a
  # grid was already one click, and then the count — the only thing anybody changes about a grid —
  # had no control at all: `Features ×3` could be turned into the grid it already was, and not into
  # two columns.
  #
  # Or already set, which is the same rule `drawn_row?/3` follows for the flex rows: an override that
  # exists and has no control is one nobody can see, clear, or explain — including the one **Move to
  # controls** has just written out of the Custom CSS box.
  defp grid?(node, bucket) do
    effective_style(node, bucket, "display") == "grid" or
      effective_style(node, bucket, "grid-cols") != nil
  end

  # What the row reads as right now, in words rather than in Tailwind — and where it came from when
  # this bucket did not set it, which is the same provenance the field rows below show.
  defp picture_hint(node, bucket, prop) do
    case {own_style(node, bucket, prop), effective_style(node, bucket, prop)} do
      {nil, nil} ->
        gettext("unset")

      {nil, value} ->
        gettext("%{title} · from %{source}",
          title: Styles.value_title(prop, value),
          source: inherited_from(node, bucket, prop) || gettext("desktop")
        )

      {value, _effective} ->
        Styles.value_title(prop, value)
    end
  end

  # The FIRST bar is brighter, which is the only way a reader can tell `row` from `row-reverse` in a
  # picture: it shows where the children start.
  defp bar_tone(_prop, 1), do: "bg-[#c3c1f0]"
  defp bar_tone(_prop, _index), do: "bg-[#8a877f]"

  # A BAR THAT GROWS CANNOT SHOW SPACING. Every one of these used to be `flex-1`, which fills the
  # swatch — so `justify-start` and `justify-between` drew exactly the same picture, and the row that
  # exists to make spacing legible was the one row you could not read. Spread and Wrap need bars that
  # keep their width, so the FREE SPACE is what moves.
  #
  # Alignment sets `min-h` rather than `h` on purpose: a fixed height would defeat `items-stretch`,
  # which is the one value whose whole point is that the child fills the box.
  defp bar_shape("justify", _index), do: "w-[5px] flex-none"
  defp bar_shape("align", 1), do: "w-[5px] flex-none min-h-[5px]"
  defp bar_shape("align", 2), do: "w-[5px] flex-none min-h-[9px]"
  defp bar_shape("align", _index), do: "w-[5px] flex-none min-h-[13px]"
  # A wrapped line is only as tall as what is in it, and a bar with no height is nothing — the
  # second row rendered at zero pixels and `wrap` looked like an empty box.
  defp bar_shape("wrap", _index), do: "h-[6px] w-[9px] shrink-0 grow-0"
  defp bar_shape(_prop, _index), do: "flex-1 min-h-[3px]"

  # Four 9px bars cannot fit a 24px swatch, which is the point: `nowrap` runs them off the edge and
  # `wrap` breaks them onto a second line. Without the clip the overflow spills over the border.
  defp swatch_extra("wrap"), do: "content-start overflow-hidden"
  defp swatch_extra(_prop), do: nil

  # The three device tabs, and the widths their overrides actually apply below — `Styles` writes
  # `max-[900px]:` and `max-[560px]:`, so the tooltip is the rule, not a label beside it.
  defp breakpoint_tabs do
    [
      {:base, gettext("Desktop"), :desktop,
       gettext("Everywhere, unless a narrower tab overrides it")},
      {:tablet, gettext("Tablet"), :tablet, gettext("Applies below 900px")},
      {:mobile, gettext("Mobile"), :mobile, gettext("Applies below 560px")}
    ]
  end

  # How much this breakpoint sets of its own — the number on its tab. Only the breakpoint's own
  # bucket counts; a state override recorded at :hover belongs to the State chips, not to a device.
  @pseudo_states [:hover, :focus, :active]

  # EVERYTHING WRITTEN AT THIS WIDTH, states included. The badge answers "does this breakpoint carry
  # anything", and a hover colour set only on mobile is emphatically something it carries — counted
  # against the width alone it was invisible, which is the whole reason a responsive edit is hard to
  # find again a week later.
  defp override_count(node, breakpoint) do
    Enum.reduce([:base | @pseudo_states], 0, fn pseudo, total ->
      total + (styles(node) |> Map.get(Styles.bucket(breakpoint, pseudo), %{}) |> map_size())
    end)
  end

  # ONE RULE, NOT A MATCHING PAIR. This was a byte-identical copy of `EditorSession.write_bucket/1`,
  # and it was the copy that ran — the server's own was called by nothing but its tests. Two rules
  # that must agree, one of them untested, is the shape where the inspector highlights one bucket
  # and the write lands in another.
  defdelegate write_bucket(editor), to: MishkaCmsCore.Runtime.PageBuilder.EditorSession

  defp styles(node), do: (node && node.meta[:styles]) || %{}

  # Whether this bucket holds anything of its own — what decides if there is a reset to offer.
  defp bucket_written?(node, bucket), do: styles(node) |> Map.get(bucket, %{}) |> map_size() > 0

  # The words on the Reset button, and they name BOTH axes now: "Clear mobile :hover overrides" is a
  # different button from "Clear mobile overrides", and clicking the wrong one is a different
  # element's worth of work lost.
  defp bucket_label(bucket) do
    case Styles.axes(bucket) do
      {:base, :base} ->
        gettext("desktop")

      {breakpoint, :base} ->
        breakpoint_word(breakpoint)

      {:base, pseudo} ->
        ":#{pseudo}"

      {breakpoint, pseudo} ->
        gettext("%{breakpoint} :%{pseudo}",
          breakpoint: breakpoint_word(breakpoint),
          pseudo: pseudo
        )
    end
  end

  defp breakpoint_word(:tablet), do: gettext("tablet")
  defp breakpoint_word(:mobile), do: gettext("mobile")
  defp breakpoint_word(other), do: to_string(other)

  defp own_style(node, bucket, prop), do: styles(node) |> Map.get(bucket, %{}) |> Map.get(prop)

  # What the element actually shows for this property, following the cascade base → breakpoint →
  # state, so an unset field's placeholder is the value the author is really seeing.
  defp effective_style(node, bucket, prop) do
    Enum.find_value(cascade(bucket), fn b -> own_style(node, b, prop) end)
  end

  defp inherited_from(node, bucket, prop) do
    cascade(bucket)
    |> Enum.drop(1)
    |> Enum.find(fn b -> own_style(node, b, prop) end)
    |> then(&(&1 && source_word(&1)))
  end

  defp source_word(:base), do: gettext("base")
  defp source_word(bucket), do: breakpoint_word(bucket)

  # WHAT THE ELEMENT REALLY SHOWS in this bucket, which is a search across two axes now rather than
  # one. STATE BEATS WIDTH, because that is what the browser does: `hover:` carries a pseudo-class
  # and `max-[560px]:` does not, so a plain hover outranks a mobile-only plain value even inside the
  # query. Within one state the narrower width wins, which is emission order.
  defp cascade(bucket) do
    {breakpoint, pseudo} = Styles.axes(bucket)

    for p <- states(pseudo), b <- widths(breakpoint), do: Styles.bucket(b, p)
  end

  defp widths(:mobile), do: [:mobile, :tablet, :base]
  defp widths(:tablet), do: [:tablet, :base]
  defp widths(:base), do: [:base]

  defp states(:base), do: [:base]
  defp states(pseudo), do: [pseudo, :base]

  # The two selectors decide where an edit is written, which is not self-evident from a segmented
  # control — the prototype puts a sentence under each one, and the widths quoted here are the real
  # ones `Tree.Styles` compiles to.
  defp breakpoint_note(:base),
    do: gettext("Recorded as the value for every size unless a smaller one overrides it.")

  defp breakpoint_note(:tablet),
    do: gettext("Recorded against 900px and below. Desktop keeps its own value.")

  defp breakpoint_note(:mobile),
    do: gettext("Recorded against 560px and below. Desktop keeps its own value.")

  defp state_note(:base), do: gettext("The resting state, as visitors first see it.")

  defp state_note(pseudo),
    do:
      gettext("Recorded against :%{pseudo} — open the CSS pane to see the rule.", pseudo: pseudo)

  # `<header>` for a plain tag, the label itself for anything else — a text node is not `<text>`.
  @doc """
  How a node is named in the chrome: `<header>` for an element, the component's own name for a
  component. Public because `BuilderLive` labels an AI attachment with the same words the composer's
  scope chip shows — one name for one thing.
  """
  @spec selection_tag(Node.t()) :: String.t()
  def selection_tag(%Node{tag: tag} = node) when is_binary(tag) do
    case tag =~ ~r/^[a-z][a-z0-9]*$/ do
      true -> "<" <> tag <> ">"
      false -> node_label(node)
    end
  end

  def selection_tag(node), do: node_label(node)

  defp selection_meta(%Node{children: []}), do: gettext("no children · selected")

  defp selection_meta(%Node{children: children}),
    do: ngettext("%{count} child · selected", "%{count} children · selected", length(children))

  @doc """
  The Behavior switches: a label and the classes each one adds.

  Every switch is a real class on the element, so it reads the document rather than a flag kept
  alongside it — turn one on, save, reopen, and it is still on because the class is still there.
  """
  @spec behavior_toggles() :: [{String.t(), String.t(), [String.t()]}]
  def behavior_toggles do
    [
      {"sticky", gettext("Sticky on scroll"), ~w(sticky top-0 z-10)},
      {"shadow", gettext("Drop shadow"), ~w(shadow-lg)},
      {"container", gettext("Constrain to container"), ~w(max-w-5xl mx-auto)}
    ]
  end

  @doc "Whether a node already carries every class one of the switches adds."
  @spec behavior_on?(Node.t() | nil, String.t()) :: boolean()
  def behavior_on?(nil, _key), do: false

  def behavior_on?(node, key) do
    case Enum.find(behavior_toggles(), fn {k, _label, _classes} -> k == key end) do
      nil -> false
      {_key, _label, classes} -> Enum.all?(classes, &(&1 in node_class_list(node)))
    end
  end

  @doc """
  A node's authored classes as a list, in the order they were written.

  `Tree.classes/1` rather than the text of the attribute, because an expression's TEXT is not a list
  of classes: reading `class={[@variant, "pb-…"]}` that way answered `["[@variant,", …]` and the
  Behavior switches went on to write those fragments back as the class.
  """
  @spec node_class_list(Node.t() | nil) :: [String.t()]
  def node_class_list(nil), do: []
  def node_class_list(node), do: Tree.classes(node)

  # The prototype's five background swatches. A named palette is faster than typing a hex for the
  # colours a page actually reuses, and each one still lands in the same override bucket.
  #
  # Each row carries BOTH the value a click writes into the document and the class the button paints
  # itself with. The two cannot drift, and `[background:…]` built by interpolation would be source
  # text no Tailwind build can match — the swatches would all render blank.
  #
  # CLICKING THE CHOSEN ONE CLEARS IT, the way the picture rows and the gap presets do: the value
  # sent is `""` when it is already the current one. They are presets over a field, not the only way
  # in, so the field below carries the override dot and the Reset — see `appearance_props/0`.
  # THE FIVE, AND THE ABSENCE OF ONE. Every swatch here paints something, so a row of them could set
  # a background and never clear one back to nothing — and "nothing" is a real answer, not the lack
  # of an answer: a card meant to show the section behind it needs `transparent`, and typing the word
  # into the field below is not a thing anybody found. Reported on the editor issue as "you should
  # add transparent as well".
  #
  # It leads the row rather than trailing it, because it is the one that UNDOES the other five, and
  # its tint is the chequerboard every design tool draws for "see-through" — a plain white square
  # would be indistinguishable from the white swatch beside it.
  @transparent_tint "[background-image:linear-gradient(45deg,#e6e4de_25%,transparent_25%),linear-gradient(-45deg,#e6e4de_25%,transparent_25%),linear-gradient(45deg,transparent_75%,#e6e4de_75%),linear-gradient(-45deg,transparent_75%,#e6e4de_75%)] [background-position:0_0,0_5px,5px_-5px,-5px_0] [background-size:10px_10px]"

  defp swatches do
    [
      {"transparent", "transparent", @transparent_tint},
      {"white", "#ffffff", "[background:#ffffff]"},
      {"paper", "#faf9f6", "[background:#faf9f6]"},
      {"sand", "#f2f1ec", "[background:#f2f1ec]"},
      {"violet", "#4f4bcc", "[background:#4f4bcc]"},
      {"ink", "#17161a", "[background:#17161a]"}
    ]
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:on, :boolean, required: true)
  attr(:event, :string, required: true)
  attr(:node_id, :string, required: true)
  attr(:value, :string, default: nil)

  defp toggle_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 border-b border-[#f4f3ee] py-2 last:border-b-0">
      <span class="flex-1 text-[11.5px] font-semibold text-[#3a382f]">{@label}</span>
      <button
        type="button"
        id={@id}
        role="switch"
        aria-checked={to_string(@on)}
        phx-click={@event}
        phx-value-id={@node_id}
        phx-value-key={@value}
        class={[
          "flex h-[23px] w-10 flex-none items-center rounded-full p-[3px] transition-colors",
          (@on && "justify-end bg-[#4f4bcc]") || "justify-start bg-[#dcdad3]"
        ]}
      >
        <span class="size-[17px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,.22)]"></span>
      </button>
    </div>
    """
  end

  attr(:node, :any, required: true)
  attr(:section, :string, default: "page")
  attr(:record, :any, default: nil)
  attr(:group_folds, :map, default: %{})

  # An `:eex_block` is a `<%= for … do %>` — its source is the WHOLE construct, including everything
  # nested inside it, so a text box would be editing a container's structure through a keyhole. The
  # document's code is the right surface for that one, and the panel opens it rather than offering a
  # box that would silently drop the block's children.
  defp expression_section(%{node: %Node{kind: :eex_block}} = assigns) do
    ~H"""
    <section>
      <.fold_heading
        title={gettext_noop("Expression")}
        group_folds={@group_folds}
        folded_by_default={false}
      />
      <div
        :if={!folded?(@group_folds, "section", "Expression", false)}
        class="flex flex-col gap-2"
      >
        <p
          id="pb-expr-block-note"
          class="rounded-[8px] bg-[#faf9f6] px-2.5 py-2 text-[10.5px] font-medium leading-[1.55] text-[#6d6a63]"
        >
          <span class="font-['Space_Grotesk'] font-bold text-[#5c5a54]">{Node.label(@node)}</span>
          {gettext(
            "wraps the elements inside it, so its source is edited as code — a box here would rewrite the block and drop what it contains."
          )}
        </p>
        <%!-- SAYING WHERE IS NOT TAKING THEM THERE. The note named the surface and left the author to
              find the Code button on their own. Not gated on `code_allowed?`, the same as that
              button: the Template tab is drawn for everyone in the builder. --%>
        <button
          type="button"
          id="pb-expr-block-open-code"
          phx-click="open_source"
          phx-value-tab="template"
          class="inline-flex h-[26px] items-center gap-1.5 self-start rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fa]"
        >
          <.icon name={:code} size={12} /> {gettext("Open code")}
        </button>
      </div>
    </section>
    """
  end

  defp expression_section(assigns) do
    assigns = assign(assigns, :offers, expression_offers(assigns.section, assigns.record))

    ~H"""
    <section>
      <.fold_heading
        title={gettext_noop("Expression")}
        group_folds={@group_folds}
        folded_by_default={false}
      />

      <div
        :if={!folded?(@group_folds, "section", "Expression", false)}
        class="flex flex-col gap-2"
      >
        <%!-- WHAT THIS DOCUMENT ACTUALLY HAS TO OFFER. The box stays a box — what goes in it is
              Elixir and the editor has no business narrowing that — but it was the WHOLE surface,
              and a text field whose only guidance is a placeholder asks the author to remember the
              names of things this editor already knows.

              Read off the record's own declaration, so a component that declares `size` offers
              `@size` the moment it is declared and stops offering it the moment it is not. Nothing
              here is a list of names: a layout has exactly one assign to be handed, and a page's
              assigns come from handlers this editor cannot read, so it offers none and says so in
              the line underneath rather than pretending. --%>
        <div :if={@offers != []} class="flex flex-wrap gap-1" id={"pb-expr-offers-#{@node.id}"}>
          <button
            :for={offer <- @offers}
            type="button"
            id={"pb-expr-offer-#{@node.id}-#{offer.name}"}
            phx-click="op"
            phx-value-kind="set_text"
            phx-value-node_id={@node.id}
            phx-value-text={offer.token}
            title={offer.title}
            class={[
              "max-w-full truncate rounded-[7px] border px-[7px] py-[3px] font-['Space_Grotesk'] text-[10.5px] font-semibold",
              (@node.text == offer.token &&
                 "border-[#c3c1f0] bg-[#f2f1fc] text-[#4f4bcc]") ||
                "border-[#ecebe6] bg-white text-[#5c5a54] hover:border-[#c3c1f0] hover:bg-[#f7f6fd] hover:text-[#4f4bcc]"
            ]}
          >
            {offer.token}
          </button>
        </div>

        <form id={"pb-expr-form-#{@node.id}"} phx-change="op" phx-submit="op">
          <input type="hidden" name="kind" value="set_text" />
          <input type="hidden" name="node_id" value={@node.id} />
          <div class="relative">
            <textarea
              id={"pb-expr-input-#{@node.id}"}
              name="text"
              rows="2"
              spellcheck="false"
              phx-debounce="300"
              placeholder={expression_placeholder(@offers)}
              class="peer w-full resize-y rounded-[8px] border border-[#ecebe6] bg-[#faf9f6] px-2.5 py-2 font-['Space_Grotesk'] text-[11.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white"
            >{@node.text}</textarea>
          </div>
        </form>
        <p class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
          {expression_hint(@section)}
        </p>
      </div>
    </section>
    """
  end

  attr(:node, :any, required: true)
  attr(:code_allowed?, :boolean, default: false)

  attr(:entries, :list,
    default: [],
    doc: "the Handlers tab's entries, saved or not, under the names a Save stores them by"
  )

  attr(:record, :any, default: nil)

  # A code author sees the form's two events and opens them in the Code window once the form has a
  # name; anyone else reads two sentences with no event name in them.
  defp form_handlers_card(%{code_allowed?: true} = assigns) do
    assigns = assign(assigns, :rows, PageForms.handlers(assigns.node, assigns.entries))

    ~H"""
    <section
      id="pb-form-handlers-card"
      class="rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2"
    >
      <div
        :for={row <- @rows}
        id={"pb-form-card-#{row.kind}"}
        data-custom={to_string(row.custom?)}
        class="flex items-center gap-2 py-0.5"
      >
        <span class="w-[62px] flex-none text-[10.5px] font-bold text-[#3a382f]">
          {handler_kind(row.kind)}
        </span>
        <code class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10.5px] text-[#5c5a54]">
          {row.event}
        </code>
        <span class={[
          "flex-none rounded-full px-1.5 text-[9.5px] font-bold",
          (row.custom? && "bg-[#f2f1fc] text-[#4f4bcc]") || "bg-[#e6f6ee] text-[#177a53]"
        ]}>
          {handler_state(row.custom?)}
        </span>
      </div>
      <button
        :if={PageForms.param_name(@node)}
        type="button"
        id="pb-form-edit-in-code"
        phx-click="open_source"
        phx-value-tab="events"
        phx-value-form={@node.id}
        class="mt-1.5 h-7 w-full rounded-[8px] border border-[#dcdbf5] bg-white text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f7f6ff]"
      >
        {gettext("Edit in Code")}
      </button>
      <p
        :if={!PageForms.param_name(@node)}
        id="pb-form-card-unnamed"
        class="mt-1.5 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]"
      >
        {gettext("Give this form a name above to write code for it.")}
      </p>
    </section>
    """
  end

  defp form_handlers_card(assigns) do
    assigns = assign(assigns, :story, Inspector.form_story(assigns.node, assigns.record))

    ~H"""
    <section
      id="pb-form-handlers-card"
      class="flex flex-col gap-1 rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2 text-[10.5px] font-medium leading-[1.5] text-[#5c5a54]"
    >
      <p id="pb-form-card-typing">{elem(@story, 0)}</p>
      <p id="pb-form-card-sending">{elem(@story, 1)}</p>
    </section>
    """
  end

  # The rename warning reads the form as it was when its rename began.
  defp renamed_from(%Node{id: id} = origin, %Node{id: id}), do: origin
  defp renamed_from(_origin, node), do: node

  # Whether this document holds handlers — asked of the resource, the way the code tabs ask it, so
  # one that gains or loses the column answers differently without a list of section names here.
  defp handles_events?(section) do
    resource = Section.resource(Section.normalize(section))

    not is_nil(Ash.Resource.Info.attribute(resource, :events))
  end

  # The two rules a browser does not enforce are dropped where nothing else would either: they are
  # read by `PageForm.Rules`, which only the compiler that emits handlers wires up.
  defp validation_controls(section) do
    case handles_events?(section) do
      true -> Inspector.validation_controls()
      false -> Enum.reject(Inspector.validation_controls(), &(&1.key in ~w(format confirms)))
    end
  end

  # Whether a LiveView owns this document's DOM at all. Three of the four are rendered by one — a
  # component inside the page that places it — and an error page is not: `ErrorHTML` calls the
  # compiled module from a controller, so nothing is there to attach a `phx-` binding.
  defp bindable?(section), do: Section.normalize(section) != "error-page"

  # Whatever this document is actually handed, so the empty box stops suggesting `@inner_content` to
  # the three sections that are never handed one.
  defp expression_placeholder([%{token: token} | _rest]), do: token
  defp expression_placeholder(_none), do: "@assign"

  @typep expression_offer :: %{name: String.t(), token: String.t(), title: String.t()}

  # THE SAME QUESTION THE HINT ANSWERS IN WORDS, answered in things that can be clicked — and
  # answered from the RECORD rather than from a list in this file, because which names are real is a
  # property of the component somebody is editing and of nothing else.
  #
  # Replacing rather than inserting at the caret: an `:eex` node IS one expression, the common case
  # is "this one should be `@size`", and a replacement is one `set_text` op — which means one undo
  # step back to whatever was typed, the same as every other write in this panel.
  @spec expression_offers(String.t(), map() | nil) :: [expression_offer()]
  defp expression_offers("component", record) do
    Enum.map(Interface.attrs(record), fn attr ->
      name = Interface.value(attr, "name")

      %{
        name: name,
        token: "@" <> name,
        title: use_attribute_title(name, Interface.value(attr, "type"))
      }
    end) ++
      Enum.map(Interface.slots(record), fn slot ->
        name = Interface.value(slot, "name")

        %{
          name: name,
          token: "render_slot(@#{name})",
          title: gettext("Render whatever was put in the %{name} slot here", name: name)
        }
      end)
  end

  # A layout is handed exactly one thing, and it is the thing a layout is FOR.
  defp expression_offers("layout", _record),
    do: [
      %{
        name: "inner_content",
        token: "@inner_content",
        title: gettext("Render the page this layout is wrapping here")
      }
    ]

  # AND AN ERROR PAGE IS HANDED THREE, on exactly the same footing.
  # `MishkaCmsCore.Runtime.Compilers.ErrorCompiler` binds `conn`, `status` and `site` before the
  # stored template renders, unconditionally — so `{@status}` is as certain here as
  # `{@inner_content}` is on a layout. It was falling into the page's clause, which offers nothing
  # because a page's assigns come from handlers; an error page has no handlers and these three
  # instead, which made it the one section that could see neither.
  defp expression_offers("error-page", _record),
    do: [
      %{
        name: "status",
        token: "@status",
        title:
          gettext(
            "The status this page answers — 404, 500, or :offline while the site is offline"
          )
      },
      %{name: "conn", token: "@conn", title: gettext("The connection that was refused")},
      %{name: "site", token: "@site", title: gettext("The site this page belongs to")}
    ]

  # A page's assigns come from handlers written on the Handlers tab, which this editor does not
  # evaluate. Offering a guess would be worse than offering nothing.
  defp expression_offers(_page, _record), do: []

  defp use_attribute_title(name, ""),
    do: gettext("Use the %{name} attribute here", name: name)

  defp use_attribute_title(name, type),
    do: gettext("Use the %{name} attribute here — declared as %{type}", name: name, type: type)

  # WHAT AN EXPRESSION CAN NAME DEPENDS ON WHAT IS BEING EDITED, and nothing in the editor said so.
  # A layout is handed `@inner_content`; a component is handed its own declared attributes and its
  # `@inner_block`; a page is handed the assigns its own handlers put there. Naming the right one is
  # most of the question "how do I put an expression in here".
  defp expression_hint("layout"),
    do:
      gettext(
        "Elixir, evaluated when the page renders. A layout is handed @inner_content — the page that is being wrapped — plus the site's own assigns."
      )

  defp expression_hint("component"),
    do:
      gettext(
        "Elixir, evaluated when the component renders. A component is handed every attribute it declares as @name, and render_slot(@inner_block) for whatever was put inside it."
      )

  defp expression_hint("error-page"),
    do:
      gettext(
        "Elixir, evaluated when the error page renders. It is handed @status, @conn and @site — and nothing else: an error page is served by a controller and holds no handlers of its own."
      )

  defp expression_hint(_page),
    do:
      gettext(
        "Elixir, evaluated when the page renders. It can name any assign the page's own handlers set — @posts, @current_user."
      )

  defp expression_node?(%Node{kind: kind}) when kind in [:eex, :eex_block], do: true
  defp expression_node?(_node), do: false

  attr(:node, :any, required: true)
  attr(:editor, :any, required: true)
  attr(:group_folds, :map, default: %{})

  # A button in a form: what it says while sending and whether it sends at all, and the way to its
  # form's settings. Nothing for a button with neither, such as one that renders a link, so a button
  # that does not send is warned only where Button type is there to change it.
  defp send_section(assigns) do
    %{tree: tree, components: components} = assigns.editor
    node = assigns.node
    roles = Fields.roles([node | Tree.ancestors(tree, node.id)], components)
    rules = Fields.submit_rules(roles, components)
    send? = Fields.submit_node?(node, roles, rules)

    assigns =
      assigns
      |> assign(:send?, send?)
      |> assign(
        :controls,
        node
        |> Inspector.send_controls(components, send?, Fields.type_attr(node, roles, rules))
        |> Enum.filter(&(send? or &1.key == "button_type"))
      )
      |> assign(:form_id, owning_form_id(assigns.editor, node))

    ~H"""
    <.rule_section
      :if={@controls != []}
      title={gettext_noop("Send button")}
      controls={@controls}
      node={@node}
      form_id={@form_id}
      group_folds={@group_folds}
    >
      <p
        :if={!@send?}
        id="pb-send-type-warning"
        class="rounded-[8px] border border-[#f0e3c9] bg-[#fbf1df] px-2.5 py-1.5 text-[10px] font-semibold leading-[1.5] text-[#8a5514]"
      >
        {gettext("This button does not send the form. Choose \"Sends the form\" if it should.")}
      </p>
    </.rule_section>
    """
  end

  # The form a node sits in, any kind of form, for the Form settings link.
  defp owning_form_id(%{tree: tree, components: components}, node) do
    case FormPlacement.form_of(tree, node, components) do
      %Node{id: id} -> id
      nil -> nil
    end
  end

  # A field inside a working form.
  defp field_in_form?(%{tree: tree, components: components}, %Node{} = node),
    do:
      Fields.field_node?(node, Fields.roles([node], components)) and
        Inspector.owning_form(tree, node) != nil

  defp field_in_form?(_editor, _node), do: false

  attr(:title, :string, required: true)
  attr(:controls, :list, required: true)
  attr(:node, :any, required: true)
  attr(:form_id, :string, default: nil, doc: "the form whose settings the section links to")
  attr(:note, :string, default: nil, doc: "which field of which form the rules are for")
  attr(:warning, :string, default: nil, doc: "what a rename would stop calling")
  attr(:group_folds, :map, default: %{})
  slot(:inner_block, doc: "drawn under the controls, and folded with them")

  # One of the two sections a form adds, drawn from the controls
  # `MishkaCmsCore.Runtime.PageBuilder.Inspector.form_sections/0` declares rather than from markup of
  # its own — a control added there appears here without this function changing.
  #
  # OPEN BY DEFAULT, where Behavior and Attributes start closed. Both sections are conditional — Form
  # only on a form, Validation only on a field bound to one of that form's keys — so a reader who can
  # see the heading at all came to the panel for what is under it.
  #
  # ABOVE THE BREAKPOINT STRIP, with the component properties, for the reason written there: every
  # control here writes a plain attribute, one value for the whole page. Drawn inside the strip they
  # sat under "Recorded against 560px and below", which promises a mobile-only `required` that does
  # not exist.
  defp rule_section(assigns) do
    ~H"""
    <section>
      <.fold_heading title={@title} group_folds={@group_folds} folded_by_default={false} />

      <div :if={!folded?(@group_folds, "section", @title, false)} class="flex flex-col gap-2.5">
        <p
          :if={@note}
          id="pb-rule-note"
          class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]"
        >
          {@note}
        </p>
        <button
          :if={@form_id}
          type="button"
          id="pb-form-settings-link"
          phx-click="select"
          phx-value-id={@form_id}
          class="w-fit text-[10.5px] font-bold text-[#4f4bcc] hover:underline"
        >
          {gettext("Form settings ›")}
        </button>
        <p
          :if={@warning}
          id="pb-rule-warning"
          class="rounded-[8px] border border-[#f0e3c9] bg-[#fbf1df] px-2.5 py-1.5 text-[10px] font-semibold leading-[1.5] text-[#8a5514]"
        >
          {@warning}
        </p>
        <.rule_control :for={control <- @controls} control={control} node={@node} />
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr(:control, :map, required: true)
  attr(:node, :any, required: true)

  # One rule: its label, the widget its descriptor asks for, and the sentence the descriptor writes
  # about it. The value is read back off the node's own attribute, so re-selecting the field shows
  # what is actually set rather than what was last typed.
  #
  # A `div` rather than a `label`, for the reason `style_group/1` gives: a text rule's control is a
  # form, and a form inside a label is not valid HTML.
  defp rule_control(assigns) do
    assigns =
      assigns
      |> assign(:key, assigns.control.key)
      |> assign(:event, rule_event(assigns.control))
      |> assign(:value, Inspector.rule_value(assigns.node, assigns.control))

    ~H"""
    <div
      id={@control[:id] || "pb-rule-control-#{@key}"}
      class="rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2"
    >
      <span class="mb-1.5 block truncate text-[10.5px] font-bold text-[#3a382f]">
        {translate(@control.label)}
      </span>

      <.rule_widget {assigns} />

      <p class="mt-1.5 text-[10px] font-medium leading-[1.5] text-[#8a877f]">
        {translate(@control.help)}
      </p>
    </div>
    """
  end

  # THE SEED IS NOT A ONE-ATTRIBUTE WRITE. It renames all five of the names a form derives, so it
  # goes to `rename_form` and its batch; `MishkaCmsCore.Runtime.PageBuilder.Inspector.rule_op/3` has
  # no clause for it and raises rather than quietly writing one of the five.
  defp rule_event(%{key: "seed"}), do: "rename_form"
  defp rule_event(%{key: "how"}), do: "form_how"
  defp rule_event(_control), do: "set_rule"

  # THE SWITCH'S NEXT STATE RIDES THE BUTTON'S OWN `value`, for the reason the breakpoint tabs
  # already document: `View.extractMeta` overwrites `meta.value` with `el.value`, so a
  # `phx-value-value` never arrives and the switch could only ever move one way.
  defp rule_widget(%{control: %{widget: :toggle}} = assigns) do
    ~H"""
    <button
      type="button"
      id={"pb-rule-#{@key}"}
      role="switch"
      aria-checked={to_string(@value == true)}
      value={to_string(@value != true)}
      phx-click={@event}
      phx-value-key={@key}
      phx-value-node_id={@node.id}
      class={[
        "relative h-[23px] w-10 rounded-full transition",
        (@value == true && "bg-[#4f4bcc]") || "bg-[#e0ded7]"
      ]}
    >
      <span class={[
        "absolute top-[3px] size-[17px] rounded-full bg-white shadow transition-all",
        (@value == true && "left-5") || "left-[3px]"
      ]} />
    </button>
    """
  end

  defp rule_widget(%{control: %{widget: {:number, min, max, step}}} = assigns) do
    assigns = assigns |> assign(:min, min) |> assign(:max, max) |> assign(:step, step)

    ~H"""
    <.field_form
      id={"pb-rule-form-#{@key}"}
      event={@event}
      phx-value-key={@key}
      phx-value-node_id={@node.id}
    >
      <input
        type="number"
        id={"pb-rule-#{@key}"}
        name="value"
        value={@value}
        min={@min}
        max={@max}
        step={@step}
        phx-debounce="350"
        class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-semibold text-[#3a382f]"
      />
    </.field_form>
    """
  end

  # CLICKING THE CHOSEN PILL CLEARS IT. "Neither pill means no format check" is only true while there
  # is a way back to neither, and an empty value is how this editor spells removing an attribute.
  defp rule_widget(%{control: %{widget: {:segmented, values}}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <div class="flex gap-0.5 rounded-[9px] bg-[#f2f1ec] p-0.5">
      <button
        :for={choice <- @values}
        type="button"
        id={"pb-rule-#{@key}-#{choice}"}
        phx-click={@event}
        phx-value-key={@key}
        phx-value-node_id={@node.id}
        value={(@value == choice && "") || choice}
        class={[
          "h-7 min-w-0 flex-1 truncate rounded-[7px] px-1 text-[10.5px] font-semibold capitalize",
          (@value == choice && "bg-white text-[#4f4bcc] shadow-sm") || "text-[#6d6a63]"
        ]}
      >
        {choice}
      </button>
    </div>
    """
  end

  # Pills with their own words, and a number box for any other value.
  defp rule_widget(%{control: %{widget: {:choices_or_number, pairs}}} = assigns) do
    assigns =
      assigns
      |> assign(:pairs, pairs)
      |> assign(:number, other_number(assigns.value, pairs))

    ~H"""
    <div class="flex flex-col gap-1.5">
      <.rule_widget
        control={%{@control | widget: {:choices, @pairs}}}
        key={@key}
        event={@event}
        value={@value}
        node={@node}
      />
      <.field_form
        id={"pb-rule-form-#{@key}"}
        event={@event}
        phx-value-key={@key}
        phx-value-node_id={@node.id}
      >
        <input
          type="number"
          id={"pb-rule-#{@key}-number"}
          name="value"
          value={@number}
          min="0"
          step="50"
          placeholder={gettext("Or wait this long, like 500")}
          phx-debounce="350"
          class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-semibold text-[#3a382f]"
        />
      </.field_form>
    </div>
    """
  end

  # Pills, each with its own words; the one the node reads now is pressed. `stacked` puts them one
  # under another, for words too long to share a row.
  defp rule_widget(%{control: %{widget: {:choices, pairs}}} = assigns) do
    assigns =
      assigns |> assign(:pairs, pairs) |> assign(:stacked?, assigns.control[:stacked] == true)

    ~H"""
    <div class={[
      "flex gap-0.5 rounded-[9px] bg-[#f2f1ec] p-0.5",
      @stacked? && "flex-col"
    ]}>
      <button
        :for={{choice, label} <- @pairs}
        type="button"
        id={"pb-rule-#{@key}-#{(choice == "" && "default") || choice}"}
        phx-click={@event}
        phx-value-key={@key}
        phx-value-node_id={@node.id}
        value={choice}
        aria-pressed={to_string(@value == choice)}
        class={[
          "h-7 min-w-0 truncate rounded-[7px] text-[10.5px] font-semibold",
          (@stacked? && "px-2 text-left") || "flex-1 px-1",
          (@value == choice && "bg-white text-[#4f4bcc] shadow-sm") || "text-[#6d6a63]"
        ]}
      >
        {translate(label)}
      </button>
    </div>
    """
  end

  defp rule_widget(assigns) do
    ~H"""
    <.field_form
      id={"pb-rule-form-#{@key}"}
      event={@event}
      phx-value-key={@key}
      phx-value-node_id={@node.id}
    >
      <input
        type="text"
        id={"pb-rule-#{@key}"}
        name="value"
        value={@value}
        placeholder={translate(@control[:placeholder])}
        autocomplete="off"
        spellcheck="false"
        phx-debounce="350"
        class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-medium text-[#3a382f]"
      />
    </.field_form>
    """
  end

  defp other_number(value, pairs) do
    case List.keymember?(pairs, value, 0) do
      true -> nil
      false -> value
    end
  end

  attr(:node, :any, required: true)
  attr(:editor, :any, required: true)
  attr(:group_folds, :map, default: %{})

  # Which form sends the selected field; choosing another moves the whole field there. Titled
  # "In form" because fold state is keyed by title and the form's own section is "Form".
  defp in_form_section(assigns) do
    %{tree: tree, components: components} = assigns.editor

    current =
      FormPlacement.form_of(tree, FormPlacement.unit(tree, assigns.node, components), components)

    forms = FormPlacement.forms(tree)

    assigns =
      assigns
      |> assign(:forms, forms)
      |> assign(:current, current && current.id)
      |> assign(:listed?, current != nil and List.keymember?(forms, current.id, 0))
      |> assign(
        :unlisted,
        (current && gettext("A form that does not work yet")) || gettext("Not in a form")
      )

    ~H"""
    <section id="pb-field-form-section">
      <.fold_heading
        title={gettext_noop("In form")}
        group_folds={@group_folds}
        folded_by_default={false}
      />

      <div :if={!folded?(@group_folds, "section", "In form", false)} class="flex flex-col gap-1.5">
        <.field_form id="pb-field-form-form" event="move_to_form" phx-value-node_id={@node.id}>
          <.form_select id="pb-field-form">
            <option :if={!@listed?} value="" selected>{@unlisted}</option>
            <option :for={{id, name} <- @forms} value={id} selected={id == @current}>
              {name}
            </option>
            <option value={FormPlacement.new_target()}>{gettext("A new form")}</option>
          </.form_select>
        </.field_form>
        <p class="text-[10px] font-medium leading-[1.5] text-[#8a877f]">
          {gettext("Which form sends this field. Choose another to move it there.")}
        </p>
      </div>
    </section>
    """
  end

  attr(:node, :any, required: true)
  attr(:state, :any, required: true)
  attr(:entries, :list, default: [], doc: "the page's Events-tab entries")
  attr(:components, :list, default: [])

  # A form that does not work yet, and the way to make it one where there is a safe way. One the
  # page's own code answers says so instead.
  defp idle_form(%{state: {:idle, _hands?}} = assigns) do
    assigns =
      assigns
      |> assign(:fixable?, FormPlacement.wirable?(assigns.node, assigns.components))
      |> assign(
        :handled?,
        PageForms.answered?(assigns.entries, Node.attr_text(assigns.node, "phx-submit"))
      )

    ~H"""
    <section
      id="pb-form-idle"
      class="flex flex-col gap-2 rounded-[10px] border border-[#f0e3c9] bg-[#fbf1df] px-2.5 py-2"
    >
      <p
        id="pb-form-idle-state"
        data-handled={to_string(@handled?)}
        class="text-[10.5px] font-semibold leading-[1.5] text-[#8a5514]"
      >
        {idle_line(@handled?, Node.attr(@node, "action") != nil)}
      </p>
      <button
        :if={@fixable?}
        type="button"
        id="pb-form-wire"
        phx-click="wire_form"
        phx-value-node_id={@node.id}
        class="h-7 w-full rounded-[8px] border border-[#dcdbf5] bg-white text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f7f6ff]"
      >
        {gettext("Make it a working form")}
      </button>
      <p
        :if={!@fixable?}
        id="pb-form-idle-why"
        class="text-[10px] font-medium leading-[1.5] text-[#8a5514]"
      >
        {gettext(
          "It sends to its own web address, or cannot pass its fields on. To have one that works here, use Form from Blocks › Forms."
        )}
      </p>
    </section>
    """
  end

  defp idle_form(assigns), do: ~H""

  defp idle_line(true, _elsewhere?),
    do:
      gettext(
        "Your own code handles this form when they press Send. Making it a working form keeps that code and the names its fields send."
      )

  defp idle_line(false, true),
    do:
      gettext(
        "This form sends what is typed to its own web address. Its fields are not checked here."
      )

  defp idle_line(false, false),
    do: gettext("This is a form, but it does not work yet. Fields in it are not checked or sent.")

  attr(:node, :any, required: true)
  attr(:editor, :any, required: true)
  attr(:group_folds, :map, default: %{})

  # A working form's Phoenix side, folded: the names only Form name changes, read-only, then the
  # form's own options, each where the form forwards it.
  defp form_phoenix(assigns) do
    %{tree: tree, components: components} = assigns.editor

    assigns =
      assigns
      |> assign(:controls, Inspector.phoenix_form_controls(assigns.node, components))
      |> assign(:files?, Fields.takes?(assigns.node, "multipart", components))
      |> assign(:files_on?, Node.attr(assigns.node, "multipart") != nil)
      |> assign(:holds_file?, Inspector.holds_file_field?(tree, assigns.node, components))
      |> assign(:address?, Inspector.address_takes?(assigns.node, components))
      |> assign(:address, PageForms.address(assigns.node))

    ~H"""
    <section id="pb-form-phoenix">
      <.fold_heading
        title={gettext_noop("Form · Phoenix")}
        group_folds={@group_folds}
        folded_by_default={true}
      />

      <div
        :if={!folded?(@group_folds, "section", "Form · Phoenix", true)}
        class="flex flex-col gap-2.5"
      >
        <div id="pb-form-names" class="rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2">
          <span class="mb-1.5 block truncate text-[10.5px] font-bold text-[#3a382f]">
            {gettext("Names it uses")}
          </span>
          <div
            :for={{name, value} <- Inspector.form_names(@node)}
            data-name={name}
            class="flex items-center gap-2 py-0.5"
          >
            <code class="w-[74px] flex-none font-['Space_Grotesk'] text-[10px] font-bold text-[#7a5bd0]">
              {name}
            </code>
            <code class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10px] text-[#5c5a54]">
              {value || "—"}
            </code>
          </div>
          <p class="mt-1.5 text-[10px] font-medium leading-[1.5] text-[#8a877f]">
            {gettext("Form name above changes these, all together.")}
          </p>
        </div>

        <.rule_control :for={control <- @controls} control={control} node={@node} />

        <div
          :if={@files?}
          id="pb-form-files"
          data-on={to_string(@files_on?)}
          class="rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2"
        >
          <span class="mb-1 block truncate text-[10.5px] font-bold text-[#3a382f]">
            {gettext("Can send files")}
          </span>
          <p class="text-[10px] font-medium leading-[1.5] text-[#8a877f]">
            {files_line(@files_on?, @holds_file?)}
          </p>
        </div>

        <div
          :if={@address?}
          id="pb-form-address"
          class="rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2"
        >
          <span class="mb-1.5 block truncate text-[10.5px] font-bold text-[#3a382f]">
            {gettext("Send to another address")}
          </span>
          <.field_form id="pb-form-address-form" event="form_address" phx-value-node_id={@node.id}>
            <input
              type="url"
              id="pb-form-address-input"
              name="value"
              value={@address}
              placeholder="https://"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="blur"
              class="h-8 w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[12px] font-medium text-[#3a382f]"
            />
          </.field_form>
          <p class="mt-1.5 text-[10px] font-medium leading-[1.5] text-[#8a877f]">
            {gettext(
              "What they type is checked here first, then sent to this address, and what it answers opens in this same tab. Leave it empty to keep them on this page."
            )}
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp files_line(true, true), do: gettext("On, because a file field is inside this form.")
  defp files_line(true, false), do: gettext("On.")

  defp files_line(false, _holds?),
    do: gettext("Off. It turns on by itself when a file field is put in this form.")

  attr(:node, :any, required: true)
  attr(:targets, :list, required: true)

  # A selected form's fields, moved into another form in one step.
  defp merge_form_row(assigns) do
    ~H"""
    <div
      :if={@targets != []}
      id="pb-form-merge-row"
      class="rounded-[10px] border border-[#ecebe6] bg-white px-2.5 py-2"
    >
      <span class="mb-1.5 block truncate text-[10.5px] font-bold text-[#3a382f]">
        {gettext("Move its fields into")}
      </span>
      <.field_form id="pb-form-merge-form" event="merge_forms" phx-value-node_id={@node.id}>
        <.form_select id="pb-form-merge">
          <option value="" selected>{gettext("Choose a form")}</option>
          <option :for={{id, name} <- @targets} value={id}>{name}</option>
        </.form_select>
      </.field_form>
      <p class="mt-1.5 text-[10px] font-medium leading-[1.5] text-[#8a877f]">
        {gettext("Its fields go in front of that form's Send button, and this form is removed.")}
      </p>
    </div>
    """
  end

  attr(:id, :string, required: true)
  slot(:inner_block, required: true, doc: "the `<option>`s")

  # A `form` select with its chevron, as the In form picker and Move its fields into draw it.
  defp form_select(assigns) do
    ~H"""
    <div class="relative">
      <select
        id={@id}
        name="form"
        class="h-9 w-full cursor-pointer appearance-none rounded-[9px] border border-[#ecebe6] bg-white py-0 ps-2.5 pe-8 text-[11.5px] font-semibold text-[#3a382f] outline-none"
      >
        {render_slot(@inner_block)}
      </select>
      <.select_chevron />
    </div>
    """
  end

  # The other working forms a form with fields can move them into.
  defp merge_targets(%{tree: tree, components: components}, node) do
    case FormPlacement.units(tree, node, components) do
      [] -> []
      _fields -> Enum.reject(FormPlacement.forms(tree), fn {id, _name} -> id == node.id end)
    end
  end

  # WHICH FIELD OF WHICH FORM. Two forms on one page can both hold an `email`, and the header card
  # says `<.input>` for either of them — so the section names the binding the rules hang off.
  defp validation_note(tree, node),
    do: field_note(Inspector.bound_key(tree, node), form_seed_of(tree, node))

  defp form_seed_of(tree, node), do: tree |> Inspector.owning_form(node) |> seed_of()

  defp seed_of(nil), do: nil
  defp seed_of(form), do: Inspector.form_seed(form)

  defp field_note(nil, _seed), do: nil
  defp field_note(_key, nil), do: nil

  # The form by the name Layers, the crumbs and the In form picker give it.
  defp field_note(key, seed),
    do:
      gettext("%{key} in %{form}. Checked in the browser and again on the server.",
        key: key,
        form: seed |> Naming.people_name() |> FormPlacement.phrase()
      )

  attr(:title, :string, required: true)
  attr(:group_folds, :map, default: %{})
  attr(:folded_by_default, :boolean, default: false)
  attr(:scope, :string, default: "section", doc: "which namespace the fold state is kept under")
  slot(:meta, doc: "extra chrome on the heading row, right-aligned")

  @doc false
  # Every heading in this panel folds, and they all fold the same way. The state lives on the server
  # because the panel re-renders from it — a client-side toggle would be undone by the next patch.
  defp fold_heading(assigns) do
    assigns =
      assign(
        assigns,
        :folded,
        folded?(assigns.group_folds, assigns.scope, assigns.title, assigns.folded_by_default)
      )

    ~H"""
    <button
      type="button"
      id={"pb-#{@scope}-#{slug(@title)}"}
      phx-click="toggle_prop_group"
      phx-value-group={"#{@scope}:#{@title}"}
      phx-value-folded={to_string(@folded)}
      class="mb-[9px] flex w-full items-center gap-2 rounded-[7px] py-0.5 text-left hover:bg-[#f6f5f2]"
    >
      <.icon
        name={:chevron}
        size={10}
        class={"flex-none text-[#a8a5a0] #{(@folded && "") || "rotate-90"}"}
      />
      <h3 class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
        {translate(@title)}
      </h3>
      <span class="h-px flex-1 bg-[#f0efea]"></span>
      {render_slot(@meta)}
    </button>
    """
  end

  attr(:title, :string, required: true)
  attr(:group_folds, :map, default: %{})

  attr(:folded_by_default, :boolean,
    default: false,
    doc: "starts closed until the reader says otherwise; for chrome under a long property panel"
  )

  slot(:inner_block, required: true)

  defp inspector_group(assigns) do
    assigns = assign_new(assigns, :group_folds, fn -> %{} end)

    ~H"""
    <%!-- Flat, as in the prototype: a label and its controls. Boxing each group in a card cost 24px
          of the panel's width, which is why the state pills wrapped onto a second line here and not
          there.
          The heading folds for the same reason the property groups do — on a component with thirty
          properties, "Editing at" and "State" are two rows of chrome between the reader and the
          thing they came for. Open by default, except where the panel above is already long enough
          that the chrome pushes the properties off screen; the fold is theirs to choose either way. --%>
    <section>
      <.fold_heading
        title={@title}
        group_folds={@group_folds}
        folded_by_default={@folded_by_default}
      />
      <div :if={!folded?(@group_folds, "section", @title, @folded_by_default)}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr(:fault, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:section, :string, default: "page")
  attr(:record, :any, default: nil)
  attr(:typed, :map, default: %{}, doc: "what the forms hold, typed and not yet applied")

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

        <form
          id="pb-recover-form"
          phx-change="typed:pb-recover-form"
          phx-submit="recover_template"
          class="flex flex-col gap-2.5"
        >
          <input type="hidden" name="base" value={@fault[:template]} />
          <textarea
            id="pb-recover-source"
            name="template"
            phx-debounce="blur"
            spellcheck="false"
            rows="16"
            data-accent-panel
            class="w-full resize-y rounded-[12px] border-0 bg-[#17161a] px-4 py-3.5 font-['Space_Grotesk'] text-[12.5px] leading-[1.7] text-[#c9c7d1] outline-none [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
          >{typed_over(@typed, "pb-recover-form", "template", @fault[:template])}</textarea>

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
  # DECLARED, NEVER SPLATTED — see `left_panel/1`. The union of this function's own and what the
  # three it renders read.
  attr(:editor, :any, required: true)
  attr(:tree, :any, required: true)
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
  attr(:resumable, :any, default: nil)
  attr(:inherited_draft, :any, default: nil)

  attr(:original_changed?, :boolean,
    default: false,
    doc: "whether the document the open draft was made from has changed since"
  )

  attr(:stage, :atom, default: :draft)
  attr(:dirty?, :boolean, default: false)
  attr(:keeping_draft?, :boolean, default: false)
  attr(:code_open, :boolean, default: false)
  attr(:code_tab, :atom, default: :heex)
  attr(:drawer_h, :integer, default: 300)
  attr(:marked, :any, default: nil)

  # The drawer's CSS pane writes the same value the Inspector's Custom CSS box does, so it needs the
  # same two assigns — and `component_entry/1`, which decides whether the selection can hold a rule
  # at all, reads the palette off `@editor`.
  attr(:element_css, :string, default: "")
  attr(:element_css_error, :string, default: nil)
  attr(:element_css_advice, :string, default: nil)
  attr(:heex_error, :string, default: nil)

  def center(assigns) do
    ~H"""
    <main
      id="pb-canvaswrap"
      phx-hook="PbFrameBusy"
      data-role="pb-canvaswrap"
      class="flex min-w-0 flex-1 flex-col bg-[#f6f5f2]"
    >
      <%!-- HOLDING SEVERAL. It appears only once a second element is held, says how many, and every
            button on it acts on all of them as ONE undo step. Above the canvas rather than floating
            over it: a bar that covers the page hides the thing it is about. --%>
      <div
        :if={marked_count(@marked) > 0}
        id="pb-multi-bar"
        class="flex h-10 flex-none items-center gap-2 border-b border-[#dcdbf5] bg-[#f2f1fc] px-3"
      >
        <span class="grid size-[22px] flex-none place-items-center rounded-[7px] bg-[#e4e2f7] text-[#4f4bcc]">
          <.icon name={:layers} size={12} />
        </span>
        <span class="flex-1 text-[11.5px] font-bold text-[#2e2b6b]">
          {ngettext("%{count} element held", "%{count} elements held", marked_count(@marked) + 1)}
        </span>
        <button
          :for={
            {action, label} <- [
              {"wrap", gettext("Wrap together")},
              {"duplicate", gettext("Duplicate")},
              {"paste_styles", gettext("Paste styles")},
              {"delete", gettext("Delete")}
            ]
          }
          type="button"
          id={"pb-multi-#{action}"}
          phx-click="bulk"
          phx-value-action={action}
          class={[
            "h-7 flex-none rounded-[8px] border border-[#dcdbf5] bg-white px-2.5",
            "font-['Space_Grotesk'] text-[11px] font-bold text-[#4f4bcc] hover:bg-[#faf9fe]",
            action == "delete" && "text-[#c0473d] hover:bg-[#fdf3f1]"
          ]}
        >
          {label}
        </button>
        <button
          type="button"
          id="pb-multi-clear"
          phx-click="clear_marks"
          title={gettext("Back to one element")}
          class="grid size-7 flex-none place-items-center rounded-[8px] text-[#6d6a63] hover:bg-white hover:text-[#1b1a18]"
        >
          <.icon name={:close} size={13} />
        </button>
      </div>
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

      <%!-- Work a previous session left behind. OFFERED, never loaded: opening a page and silently
            being handed something else is exactly the surprise this feature exists to remove.

            It has nothing to say once the editor is pointed at a draft. Every word of it is then
            wrong — you are not looking at the live page, and "Resume" would swap the draft you
            chose for a different one. The condition is the editor's target rather than a flag
            cleared per route, so opening a draft, forking one, and the first change of a session
            all put the bar away without each having to remember to. --%>
      <%!-- YOU WALKED BACK INTO A DRAFT. The editing session outlives a reload — which is what stops
            a refresh throwing work away — so reopening the page put you inside whatever draft was
            open, showing something other than the live page, and said nothing about it. This asks,
            once per visit: keep going in it, or leave it alone and start again from the live page.
            Either way the draft survives; neither button throws anything away. --%>
      <div
        :if={@inherited_draft}
        id="pb-inherited-bar"
        class="flex flex-none flex-wrap items-center gap-2.5 border-b border-[#dcdbf5] bg-[#f2f1fc] px-4 py-[9px]"
      >
        <span class="grid size-[22px] flex-none place-items-center rounded-[7px] bg-[#e4e2f7] text-[#4f4bcc]">
          <.icon name={:draft} size={12} />
        </span>
        <span class="min-w-0 flex-1 text-[11.5px] font-semibold text-[#2e2b6b]">
          {inherited_question(@inherited_draft)}
        </span>
        <button
          type="button"
          id="pb-inherited-continue"
          phx-click="continue_draft"
          class="h-7 flex-none rounded-[8px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-2.5 font-['Space_Grotesk'] text-[11px] font-bold text-white"
        >
          {inherited_action(@inherited_draft)}
        </button>
        <button
          type="button"
          id="pb-inherited-fresh"
          phx-click="start_fresh"
          class="h-7 flex-none rounded-[8px] border border-[#dcdbf5] bg-white px-2.5 font-['Space_Grotesk'] text-[11px] font-bold text-[#4f4bcc] hover:bg-[#faf9fe]"
        >
          {inherited_decline(@inherited_draft)}
        </button>
      </div>

      <div
        :if={@resumable && is_nil(@editor.draft_id) && is_nil(@inherited_draft)}
        id="pb-resume-bar"
        class="flex flex-none flex-wrap items-center gap-2.5 border-b border-[#f0e3c9] bg-[#fbf1df] px-4 py-[9px]"
      >
        <span class="grid size-[22px] flex-none place-items-center rounded-[7px] bg-[#f6e5c6] text-[#8a5514]">
          <.icon name={:history} size={12} />
        </span>
        <span class="min-w-0 flex-1 text-[11.5px] font-semibold text-[#8a5514]">
          {gettext("“%{label}” — %{ago}, never published. You are looking at the live page.",
            label: @resumable.label,
            ago: ago(@resumable.updated_at)
          )}
        </span>
        <button
          type="button"
          id="pb-resume"
          phx-click="resume_autosave"
          class="h-7 flex-none rounded-[8px] bg-[#17161a] px-2.5 font-['Space_Grotesk'] text-[11px] font-bold text-white hover:bg-[#2e2c33]"
        >
          {gettext("Resume")}
        </button>
        <button
          type="button"
          id="pb-resume-discard"
          phx-click="discard_autosave"
          class="h-7 flex-none rounded-[8px] border border-[#e8d9bb] bg-white px-2.5 font-['Space_Grotesk'] text-[11px] font-bold text-[#8a5514] hover:bg-[#fdf7ec]"
        >
          {gettext("Discard")}
        </button>
      </div>

      <div
        :if={@original_changed?}
        id="pb-original-changed"
        class="flex flex-none flex-wrap items-center gap-2.5 border-b border-[#f0e3c9] bg-[#fbf1df] px-4 py-[9px]"
      >
        <span class="grid size-[22px] flex-none place-items-center rounded-[7px] bg-[#f6e5c6] text-[#8a5514]">
          <.icon name={:tip} size={12} />
        </span>
        <span class="min-w-0 flex-1 text-[11.5px] font-semibold text-[#8a5514]">
          {gettext(
            "The original was changed after this draft was made. Publishing the draft writes it over those changes."
          )}
        </span>
      </div>

      <%!-- PUBLISH MODE KEEPS NOTHING, AND HAS TO SAY SO. Every other mode writes as you work; this
            one deliberately does not, because a publish is meant to be a deliberate act. Silence
            about that is indistinguishable from a save that is failing — so this appears the moment
            there is unsaved work and offers the way to keep it.
            `keeping_draft?` is the one thing that takes it down early: the draft it offered is
            being written, and it comes back if that write fails. --%>
      <div
        :if={@stage == :published and @dirty? and not @keeping_draft?}
        id="pb-publish-bar"
        class="flex flex-none flex-wrap items-center gap-2.5 border-b border-[#f0d9d9] bg-[#fdf1f1] px-4 py-[9px]"
      >
        <span class="grid size-[22px] flex-none place-items-center rounded-[7px] bg-[#f9e2e2] text-[#a33a3a]">
          <.icon name={:alert} size={12} />
        </span>
        <span class="min-w-0 flex-1 text-[11.5px] font-semibold text-[#8a2f2f]">
          {gettext(
            "Publish mode — these changes are not being saved. Publish to make them live, or keep them as a draft."
          )}
        </span>
        <button
          type="button"
          id="pb-publish-keep"
          phx-click="keep_as_draft"
          class="h-7 flex-none rounded-[8px] border border-[#f0d9d9] bg-white px-2.5 font-['Space_Grotesk'] text-[11px] font-bold text-[#a33a3a] hover:bg-[#fef7f7]"
        >
          {gettext("Keep as a draft")}
        </button>
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

      <.code_drawer
        :if={@code_open}
        tree={@tree}
        code_tab={@code_tab}
        drawer_h={@drawer_h}
        selection={@selection}
        selected_node={@selected_node}
        element_css={@element_css}
        element_css_error={@element_css_error}
        element_css_advice={@element_css_advice}
        heex_error={@heex_error}
        entry={component_entry(assigns)}
      />

      <%!-- The drawer's collapsed state is a strip, not nothing: the demo keeps the code editor
            permanently in view so it reads as part of the editor rather than a hidden mode. --%>
      <button
        :if={!@code_open}
        id="pb-code-strip"
        type="button"
        phx-click="toggle_code"
        data-accent-panel
        class="flex h-10 flex-none items-center gap-[11px] border-t border-[#262429] bg-[#17161a] px-4 text-left hover:bg-[#1d1b21] [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)] [[data-theme=dark]_&]:!bg-[#141317] [[data-theme=dark]_&]:!border-[#232228]"
      >
        <span class="font-['Space_Grotesk'] text-[12px] font-bold text-[#8ee0b8]">&gt;_</span>
        <span class="text-[12px] font-bold text-white">{gettext("Code Editor")}</span>
        <span class="text-[11px] font-medium text-[#9b99a6]">HEEx · CSS · JS</span>
        <span class="flex-1"></span>
        <span class="inline-flex items-center gap-1.5 text-[11px] font-semibold text-[#8b8995]">
          {gettext("Expand")} <.icon name={:chevron_up} size={14} />
        </span>
      </button>
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

  # Two panes: what you are looking at on the left, and what you can WRITE on the right.
  #
  # THE RIGHT PANE USED TO IGNORE THE SELECTION ENTIRELY. It rendered `override_css(tree)` — every
  # styled node on the page, every time anything re-rendered — so clicking an element changed the
  # left pane and left the right one showing the same wall of other people's rules. Three separate
  # complaints in one control: it always showed CSS whatever tab you were on, it never showed the CSS
  # of the thing you clicked, and you could not type in it.
  #
  # It is now the element's own CSS, editable, over THE SAME VALUE the Inspector's Custom CSS box
  # holds — one value, two surfaces, which is what the design said from the start and never got.
  # The Inspector is where you set a property; this is where there is room to write a block.
  #
  # The whole-tree walk went with it. It was O(nodes × buckets × props) on every drawer render to
  # fill a pane nobody could act on.
  # THE LEFT PANE IS AN EDITOR TOO, on the HEEx tab. Before this it was a picture of the markup: the
  # reader could see `Log to console` and the `px-4` on the button beside it and change neither, and
  # the answer to both was to hunt for the control in the Inspector that happened to own it. The two
  # other tabs stay pictures on purpose — CSS there is a projection of recorded overrides (ADR-8) and
  # JS belongs to the site's hook rows, not to this document.
  defp code_drawer(assigns) do
    editable? = assigns.code_tab == :html

    assigns =
      assigns
      |> assign(:heex_editable?, editable?)
      |> assign(:heex_source, (editable? && drawer_source(assigns)) || "")
      # Skipped entirely when the pane is an editor: CodeMirror colours its own text, and this is the
      # 4.5 ms whole-document tokenize that used to run on every drawer render.
      |> assign(
        :source_lines,
        (!editable? && numbered(drawer_source(assigns), assigns.code_tab)) || []
      )
      |> assign(:css_targetable?, drawer_css_targetable?(assigns))
      |> then(
        &assign(&1, :heex_key, editor_key("pb-drawer-heex", assigns.selection, &1.heex_source))
      )
      |> then(
        &assign(&1, :css_key, editor_key("pb-drawer-css", assigns.selection, &1.element_css))
      )

    ~H"""
    <div
      data-role="pb-grip"
      id="pb-grip-drawer"
      phx-hook="PbGrip"
      data-panel="drawer"
      data-min={grip_min(:drawer)}
      data-max={grip_max(:drawer)}
      data-var={grip_var(:drawer)}
      title={gettext("Drag to resize")}
      phx-mounted={drawer_in()}
      phx-remove={drawer_out()}
      class="flex h-2 flex-none cursor-row-resize items-center justify-center bg-[#1d1b21] hover:bg-[#262429]"
    >
      <span class="h-[3px] w-[34px] rounded-[2px] bg-[#4a4852]"></span>
    </div>
    <section
      data-role="pb-drawer"
      data-accent-panel
      phx-mounted={drawer_in()}
      phx-remove={drawer_out()}
      style={"height:var(--pb-drawer-h, #{@drawer_h}px)"}
      class="flex flex-none flex-col overflow-hidden border-t border-[#262429] bg-[#17161a] [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)] [[data-theme=dark]_&]:!bg-[#141317] [[data-theme=dark]_&]:!border-[#232228]"
    >
      <div class="flex flex-none items-center gap-3 border-b border-[#262429] px-4 py-[11px]">
        <span class="text-[12.5px] font-bold text-white">{gettext("Code Editor")}</span>
        <span class="flex-1"></span>
        <div class="flex rounded-[9px] bg-[#221f27] p-[3px]">
          <button
            :for={{key, label} <- code_tabs()}
            type="button"
            id={"pb-codetab-#{key}"}
            phx-click="set_code_tab"
            phx-value-tab={key}
            class={[
              "h-[26px] rounded-[7px] px-[13px] font-['Space_Grotesk'] text-[11px] font-bold",
              (@code_tab == key && "bg-[#312d3d] text-white") || "text-[#8b8995] hover:text-white"
            ]}
          >
            {label}
          </button>
        </div>
        <button
          type="button"
          id="pb-code-minimize"
          phx-click="toggle_code"
          title={gettext("Minimize")}
          class="grid size-7 flex-none place-items-center rounded-[8px] text-[#7e7c86] hover:bg-[#232128] hover:text-white"
        >
          <.icon name={:minus} size={16} />
        </button>
      </div>

      <div data-role="pb-code2" class="grid min-h-0 flex-1 grid-cols-2">
        <div
          data-pane="heex"
          class="group/heex flex min-h-0 min-w-0 flex-col border-r border-[#262429]"
        >
          <div class="flex flex-none items-center gap-2.5 border-b border-[#262429] px-4 py-2.5">
            <span class="font-['Space_Grotesk'] text-[11px] font-bold text-[#8ee0b8]">
              {code_tab_label(@code_tab)}
            </span>
            <%!-- THE SCOPE IS ALSO THE WAY OUT OF IT. Selecting an element narrows this pane to that
                  element, which is what makes the pane useful — but the narrowing announced itself
                  only by the name changing, and the one way back was Escape, which nothing says.
                  Dropping a component selects it, so an author's first experience of this pane was
                  their whole document apparently replaced by the thing they just added; a reload
                  "fixed" it because a reload starts with nothing selected. --%>
            <button
              :if={@code_tab == :html and @selected_node}
              type="button"
              phx-click="clear_selection"
              title={gettext("Showing this element only — click to show the whole document")}
              class="group/scope flex min-w-0 flex-1 items-center gap-1 truncate rounded px-1 py-0.5 text-left font-['Space_Grotesk'] text-[10.5px] font-medium text-[#a3a1ad] hover:bg-[#262429] hover:text-[#e6e4ed]"
            >
              <span class="truncate">{code_scope(@code_tab, @selected_node)}</span>
              <%!-- The way out of the narrowed pane, so it has to be readable: `#6f6d78` measured
                    3.6:1 against this panel. This is the colour of the scope label beside it. --%>
              <span class="flex-none text-[9px] text-[#a3a1ad] group-hover/scope:text-[#8ee0b8]">
                {gettext("✕ whole document")}
              </span>
            </button>
            <span
              :if={!(@code_tab == :html and @selected_node)}
              class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10.5px] font-medium text-[#a3a1ad]"
            >
              {code_scope(@code_tab, @selected_node)}
            </span>
            <%!-- APPEARS WHEN THE TEXT DIFFERS, and by a data attribute rather than a round trip:
                  a button that materialises on the first keystroke would otherwise cost one
                  server render per character typed. `PbCodeEditor` flips `data-dirty` on this
                  pane; the class is written here, so the JIT compiles the rule. --%>
            <button
              :if={@heex_editable?}
              type="submit"
              form="pb-drawer-heex-form"
              id="pb-drawer-heex-save"
              title={gettext("Apply this markup to the page (⌘↵)")}
              class="hidden h-[22px] flex-none items-center gap-1.5 rounded-[7px] bg-[#2f7d5b] px-2.5 font-['Space_Grotesk'] text-[10.5px] font-bold text-white hover:bg-[#37916a] group-data-[dirty=true]/heex:inline-flex"
            >
              {gettext("Apply")} <span class="text-[9.5px] font-medium opacity-70">⌘↵</span>
            </button>
          </div>

          <%!-- The document — or one element of it — as text somebody can rewrite. Editing here is
                the same capability the Code window's Apply already had; this is that door in the
                wall the reader is already standing at, with the element they have selected already
                in it. --%>
          <form
            :if={@heex_editable?}
            id="pb-drawer-heex-form"
            phx-auto-recover="ignore"
            phx-submit="apply_element_heex"
            class="flex min-h-0 flex-1 flex-col"
          >
            <input type="hidden" name="node_id" value={@selection} />
            <%!-- Keyed on the text as well as the element — see the CSS pane below for why. It is
                  also what holds a REFUSAL still: a refused apply leaves the tree alone, so the key
                  does not move, so the markup somebody just typed is exactly where they left it. --%>
            <div
              id={@heex_key}
              data-fill="true"
              phx-hook="PbCodeEditor"
              phx-update="ignore"
              data-language="heex"
              class="min-h-0 flex-1 overflow-hidden px-4 py-1"
            >
              <textarea
                id={"#{@heex_key}-field"}
                data-role="pb-drawer-heex"
                name="source"
                spellcheck="false"
                class="h-full w-full resize-none border-0 bg-transparent py-2.5 font-['Space_Grotesk'] text-[11.5px] leading-[1.75] text-[#c9c7d1] outline-none"
              >{@heex_source}</textarea>
            </div>
            <p
              :if={@heex_error}
              id="pb-drawer-heex-error"
              class="flex-none border-t border-[#3a2a2a] bg-[#2a1f1f] px-4 py-2 font-['Space_Grotesk'] text-[11px] font-bold text-[#e2938a]"
            >
              {@heex_error}
            </p>
          </form>

          <.code_lines :if={!@heex_editable?} id="pb-code-source" lines={@source_lines} />
        </div>

        <div data-pane="css" class="group/css flex min-h-0 min-w-0 flex-col">
          <div class="flex flex-none items-center gap-2.5 border-b border-[#262429] px-4 py-2.5">
            <span class="font-['Space_Grotesk'] text-[11px] font-bold text-[#a48fe0]">CSS</span>
            <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10.5px] font-medium text-[#a3a1ad]">
              {drawer_css_scope(@selected_node, @css_targetable?)}
            </span>
            <button
              :if={@css_targetable?}
              type="submit"
              form="pb-drawer-css-form"
              id="pb-drawer-css-save"
              title={gettext("Apply this CSS to the selected element (⌘↵)")}
              class="hidden h-[22px] flex-none items-center gap-1.5 rounded-[7px] bg-[#5b4fb8] px-2.5 font-['Space_Grotesk'] text-[10.5px] font-bold text-white hover:bg-[#6a5ecb] group-data-[dirty=true]/css:inline-flex"
            >
              {gettext("Apply")} <span class="text-[9.5px] font-medium opacity-70">⌘↵</span>
            </button>
          </div>

          <p
            :if={!@css_targetable?}
            id="pb-drawer-css-note"
            class="px-4 py-3.5 font-['Space_Grotesk'] text-[11.5px] font-medium leading-[1.7] text-[#7e7c86]"
          >
            {drawer_css_note(@selected_node)}
          </p>

          <%!-- `&` means this element, the same as in the Inspector's box and the same as what the
                compiler wraps. Nothing here is a second dialect to learn. --%>
          <form
            :if={@css_targetable?}
            id="pb-drawer-css-form"
            phx-auto-recover="ignore"
            phx-submit="save_element_css"
            class="flex min-h-0 flex-1 flex-col"
          >
            <input type="hidden" name="node_id" value={@selected_node.id} />
            <%!-- THE TEXTAREA IS STILL THE FIELD. `PbCodeEditor` mounts CodeMirror beside it and
                  writes back on every change, so the form submits the same `css` param it always
                  did and the server has no idea an editor is involved. `phx-update="ignore"` keeps
                  LiveView from reconciling away the DOM CodeMirror built. --%>
            <%!-- KEYED ON THE ELEMENT AND ON THE TEXT, because `phx-update="ignore"` is what stops
                  LiveView reconciling away the DOM CodeMirror built — and it stops the CONTENT
                  arriving too. A changed id is a fresh mount, which is the only way new text gets in
                  here, and both halves of the key earn their place: the node, or selecting a second
                  element leaves the first one's CSS in the box; the text, or a value written from
                  the Inspector — or a line taken out by "move to controls" — never shows up.

                  It cannot remount mid-sentence: nothing here posts on change, so this value only
                  moves when a write lands. --%>
            <div
              id={@css_key}
              data-fill="true"
              phx-hook="PbCodeEditor"
              phx-update="ignore"
              data-language="css"
              class="min-h-0 flex-1 overflow-hidden px-4 py-1"
            >
              <textarea
                id={"#{@css_key}-field"}
                data-role="pb-drawer-css"
                name="css"
                spellcheck="false"
                placeholder="padding: 20px;&#10;&#10;&:hover {&#10;  opacity: .8;&#10;}"
                class="h-full w-full resize-none border-0 bg-transparent py-2.5 font-['Space_Grotesk'] text-[11.5px] leading-[1.75] text-[#c9c7d1] outline-none placeholder:text-[#8b8995]"
              >{@element_css}</textarea>
            </div>
            <p
              :if={@element_css_error}
              id="pb-drawer-css-error"
              class="flex-none border-t border-[#3a2a2a] bg-[#2a1f1f] px-4 py-2 font-['Space_Grotesk'] text-[11px] font-bold text-[#e2938a]"
            >
              {@element_css_error}
            </p>
            <p
              :if={!@element_css_error && @element_css_advice}
              id="pb-drawer-css-advice"
              class="flex-none border-t border-[#3a3227] bg-[#2a2419] px-4 py-2 font-['Space_Grotesk'] text-[11px] font-medium leading-[1.55] text-[#e0bd80]"
            >
              {@element_css_advice}
            </p>
          </form>
        </div>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:lines, :list, required: true)

  # `phx-no-curly-interpolation` is what lets generated HEEx containing `{…}` be shown as text — and
  # it applies to the WHOLE subtree, so the lines themselves have to be interpolated the other way.
  # With `{number}`/`{text}` the drawer faithfully printed the words "{number}" and "{text}" on every
  # line and never showed a single line of the document.
  #
  # `phx-no-format` is load-bearing, not tidiness: the HEEx formatter rewrites `<%= x %>` in a tag
  # body to `{x}`, which is equivalent everywhere EXCEPT under `phx-no-curly-interpolation`. Without
  # it, the next `mix format` silently reintroduces the bug above.
  defp code_lines(assigns) do
    ~H"""
    <div
      id={@id}
      phx-no-curly-interpolation
      phx-no-format
      class={["min-h-0 flex-1 overflow-auto px-4 py-3.5", quiet_scroll(:dark)]}
    >
      <div
        :for={{number, segments} <- @lines}
        class="flex gap-[14px] font-['Space_Grotesk'] text-[11.5px] font-medium leading-[1.75]"
      ><span class="w-[18px] flex-none text-right text-[#9b99a6]"><%= number %></span><span class="whitespace-pre-wrap [overflow-wrap:anywhere]"><span
            :for={{chunk, colour} <- segments}
            class={code_colour_class(colour)}
          ><%= chunk %></span></span></div>
    </div>
    """
  end

  # The six colours `MishkaCmsCore.Runtime.PageBuilder.Highlight` hands back, one whole class name
  # each. The tokenizer keeps owning WHICH colour a chunk takes; this only turns that answer into a
  # class the compiled stylesheet has a rule for.
  defp code_colour_class("#8b8995"), do: "[color:#8b8995]"
  defp code_colour_class("#8ee0b8"), do: "[color:#8ee0b8]"
  defp code_colour_class("#a3a1ad"), do: "[color:#a3a1ad]"
  defp code_colour_class("#c8a2ff"), do: "[color:#c8a2ff]"
  defp code_colour_class("#e6c477"), do: "[color:#e6c477]"
  defp code_colour_class(_plain), do: "[color:#c9c7d1]"

  defp code_tabs, do: [{:html, "HEEx"}, {:css, "CSS"}, {:js, "JS"}]

  defp code_tab_label(:html), do: "HEEX"
  defp code_tab_label(:css), do: "CSS"
  defp code_tab_label(_js), do: "JS"

  defp code_scope(:html, nil), do: gettext("# the whole document")
  defp code_scope(:html, node), do: "# " <> node_label(node)
  defp code_scope(:css, _node), do: gettext("# selected element")
  defp code_scope(_js, _node), do: gettext("# page hooks")

  # Source lines are left in one colour rather than tinted by a guess at what each one is. The one
  # distinction worth drawing is a comment, which is not code at all.
  # COLOURED BY THE TOKENIZERS, not by "does this line start with a comment marker" — which is what
  # this did, and which is wrong about a `#` inside a string, a `<` in a text node and every heredoc.
  # `MishkaCmsCore.Runtime.PageBuilder.Highlight` explains why it is scoped to the drawer: 64 µs for a
  # node-sized snippet against 4.5 ms for a whole page, measured, and this pane re-renders on every
  # selection change.
  defp numbered(source, language) do
    source
    |> highlighted(language)
    |> Enum.with_index(1)
    |> Enum.map(fn {segments, number} -> {number, segments} end)
  end

  # `:html` is the tab's name and `:heex` was the tokenizer's, so the HEEx tab fell past both clauses
  # and was painted by the ELIXIR tokenizer for as long as it was read-only — every tag name an
  # identifier, `end` inside a string a keyword. It is CodeMirror's job now; what is left here is CSS
  # and one sentence of prose.
  # THE FIELD'S ID MOVES WITH ITS WRAPPER, and this is the whole reason the function exists.
  #
  # `phx-update="ignore"` is what stops LiveView reconciling away the DOM CodeMirror builds, and a
  # changing wrapper id is the only way new text can reach it. But morphdom matches nodes by `id`
  # BEFORE anything else: a constant `id="pb-drawer-heex"` on the textarea inside meant that when the
  # wrapper was re-keyed, the new wrapper's textarea adopted the old element and ran
  # `fromEl.value = toEl.value` — silently replacing whatever the reader had typed with the server's
  # own text.
  #
  # Silently is the operative word. The textarea is `display:none` under CodeMirror, so the screen
  # went on showing the reader's edit while the field that actually gets submitted had been reverted;
  # and the dirty flag lives on the `[data-pane]` div, which is never re-created, so Apply stayed
  # lit. Pressing it then re-inserted the markup that was already there — a successful apply that
  # changed nothing, which is exactly how this was reported.
  #
  # Tests select these by `data-role`, which does not move.
  defp editor_key(prefix, selection, content),
    do: "#{prefix}-#{selection || "doc"}-#{:erlang.phash2(content)}"

  defp highlighted(source, :css), do: Highlight.css(source)
  defp highlighted(source, _js), do: Highlight.prose(source)

  # Whether the drawer may take CSS for what is selected — the SAME question `targetable?/2` answers
  # for the Inspector, asked through the same function so the two surfaces can never disagree about
  # which elements can hold a rule.
  defp drawer_css_targetable?(%{selected_node: %Node{} = node} = assigns),
    do: targetable?(node, assigns[:entry])

  defp drawer_css_targetable?(_assigns), do: false

  defp drawer_css_scope(%Node{} = node, true),
    do: gettext("%{label} — this element's own", label: Node.label(node))

  defp drawer_css_scope(%Node{} = node, false), do: Node.label(node)
  defp drawer_css_scope(_node, _targetable?), do: gettext("nothing selected")

  defp drawer_css_note(%Node{kind: :component}),
    do:
      gettext(
        "This component takes no class of its own, so there is nothing here for a rule to attach to. Put it inside a container and style that instead."
      )

  defp drawer_css_note(%Node{}),
    do: gettext("This element holds text only — select the element around it to give it CSS.")

  defp drawer_css_note(_node), do: gettext("Select an element to write CSS for it.")

  @doc "The right panel — Layers, Assistant and Audit — as `builder:rails` contributions."
  # DECLARED, NEVER SPLATTED — see `left_panel/1`. The union of this function's own five and what
  # its three tabs read, because they share this component's assigns.
  attr(:rails, :list, required: true)
  attr(:right_tab, :atom, default: :layers)
  attr(:right_hidden, :boolean, default: false)
  attr(:right_w, :integer, required: true)
  attr(:mob_panel, :atom, default: :canvas)
  attr(:editor, :any, required: true)
  attr(:tree, :any, required: true)
  attr(:selection, :string, default: nil)
  attr(:expanded, :any, required: true)
  attr(:selected_node, :any, default: nil)
  attr(:ai_messages, :list, default: [])
  attr(:ai_prompt, :string, default: "")
  attr(:ai_backend, :any, default: nil)
  attr(:ai_attachment, :any, default: nil)
  # `record` is read by `.audit`, which derives its findings from the document and the row, and by
  # `.layers`, whose `.interface` group is a view of two of that row's columns. `section` says which
  # kind of document this is, which is the only thing that decides whether that group exists at all.
  attr(:record, :any, default: nil)
  attr(:section, :string, default: nil)
  # Read by `.layers`, whose component rows lead into that component's own editor — see
  # `component_editor_path/3`.
  attr(:current_user, :any, default: nil)

  def right_panel(assigns) do
    ~H"""
    <div
      :if={!@right_hidden}
      data-role="pb-grip"
      id="pb-grip-right"
      phx-hook="PbGrip"
      data-panel="right"
      data-min={grip_min(:right)}
      data-max={grip_max(:right)}
      data-var={grip_var(:right)}
      class="w-1.5 flex-none cursor-col-resize hover:bg-[#e4e2f7] max-[900px]:hidden"
    />

    <aside
      :if={!@right_hidden}
      data-role="pb-right"
      id="pb-right"
      style={"width:var(--pb-right-w, #{@right_w}px)"}
      class={[
        "flex flex-none flex-col border-l border-[#e6e4de] bg-white",
        mobile_visibility(@mob_panel, [:layers, :assistant, :audit])
      ]}
    >
      <%!-- Mirrored from the left panel: the collapse chevron sits on the outside edge, so both
            panels fold away from the canvas rather than toward it. --%>
      <div class="flex flex-none items-center gap-1 px-3.5 pt-3">
        <button
          type="button"
          phx-click="toggle_right"
          title={gettext("Collapse panel")}
          class="grid h-[30px] w-5 flex-none place-items-center text-[#a8a5a0] hover:text-[#4f4bcc]"
        >
          <.icon name={:chevron} size={13} />
        </button>
        <div class="flex min-w-0 flex-1 gap-0.5 rounded-[10px] bg-[#f2f1ec] p-[3px]">
          <button
            :for={rail <- @rails}
            type="button"
            id={"pb-rail-#{rail.key}"}
            phx-click="set_right_tab"
            phx-value-tab={rail.key}
            title={translate(rail.label)}
            class={[
              "flex h-[30px] min-w-0 flex-1 items-center justify-center gap-1.5 truncate rounded-[8px] px-1 text-[10.5px] font-bold",
              (to_string(@right_tab) == rail.key &&
                 "bg-white text-[#4f4bcc] shadow-[0_1px_3px_rgba(30,28,24,.12)]") || "text-[#6d6a63]"
            ]}
          >
            <.icon name={rail_icon(rail)} size={13} class="flex-none" />{translate(rail.label)}
          </button>
        </div>
      </div>

      <.layers
        :if={@right_tab == :layers}
        editor={@editor}
        tree={@tree}
        selection={@selection}
        expanded={@expanded}
        record={@record}
        section={@section}
        current_user={@current_user}
      />
      <.assistant
        :if={@right_tab == :assistant}
        ai_messages={@ai_messages}
        ai_prompt={@ai_prompt}
        ai_backend={@ai_backend}
        ai_attachment={@ai_attachment}
        selected_node={@selected_node}
      />
      <.audit :if={@right_tab == :audit} tree={@tree} record={@record} editor={@editor} />

      <%!-- AND WHATEVER AN EXTENSION ADDED. The three above are the core's own rails and stay
            spelled out, because each takes a different slice of the editor's state; a contributed
            one is handed the same assigns and draws itself. Without this a plugin's rail drew a tab
            button that opened onto nothing, which is worse than not offering the seam at all. --%>
      <%= for rail <- contributed_rails(@rails, @right_tab) do %>
        {Descriptor.render(rail, assigns)}
      <% end %>
    </aside>

    <button
      :if={@right_hidden}
      type="button"
      phx-click="toggle_right"
      id="pb-right-rail"
      title={gettext("Show layers panel")}
      class="flex w-[34px] flex-none flex-col items-center gap-3 border-l border-[#e6e4de] bg-white py-3 hover:bg-[#faf9f6] max-[900px]:hidden"
    >
      <.icon name={:chevron} size={15} class="rotate-180 text-[#4f4bcc]" />
      <span class="text-[10px] font-bold uppercase tracking-[0.13em] text-[#6d6a63] [writing-mode:vertical-rl]">
        {gettext("Layers")}
      </span>
    </button>
    """
  end

  attr(:editor, :any, required: true)
  attr(:tree, :any, required: true)
  attr(:selection, :string, default: nil)
  attr(:expanded, :any, required: true)
  attr(:record, :any, default: nil)
  attr(:section, :string, default: nil)
  attr(:current_user, :any, default: nil)

  defp layers(assigns) do
    assigns = assign(assigns, :unmet, unmet_map(assigns.tree, declarations(assigns)))

    ~H"""
    <div
      id="pb-layers"
      data-role="pb-scroll"
      phx-hook="PbLayers"
      data-parent-id="root"
      class="min-h-0 flex-1 overflow-y-auto p-3.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      <div class="mb-2.5 text-[10.5px] font-bold uppercase tracking-[0.12em] text-[#6d6a63]">
        {gettext("Elements hierarchy")}
      </div>

      <.interface_group section={@section} record={@record} expanded={@expanded} />

      <.layer_row
        :for={{id, index} <- Enum.with_index(@tree.roots)}
        id={id}
        index={index}
        depth={0}
        tree={@tree}
        selection={@selection}
        expanded={@expanded}
        editor={@editor}
        unmet={@unmet}
        current_user={@current_user}
      />
      <p :if={@tree.roots == []} class="py-8 text-center text-[12px] font-medium text-[#a8a5a0]">
        {gettext("Nothing on this page yet.")}
      </p>

      <%!-- THE END OF THE PAGE, which the rail could not otherwise offer. Every other target here is
            a row, so a document with one root had exactly one place to aim at and an EMPTY one had
            none — the tray's whole gesture, dragging a card into a page that has nothing in it yet,
            could only be done on the canvas. Last in the rail, so revealing it moves nothing above
            it, and revealed for the length of a gesture like every other target. --%>
      <div
        data-role="pb-root-drop"
        data-parent-id="root"
        class={[
          "mt-1 hidden items-center gap-2 rounded-[9px] border border-dashed border-[#dcdbf5]",
          "py-[7px] pl-[9px] pr-[9px] text-[#8580d8] data-[show=true]:flex",
          "data-[drop=inside]:border-solid data-[drop=inside]:border-[#5b57d6] data-[drop=inside]:bg-[#f2f1fc]"
        ]}
      >
        <span class="grid size-[15px] flex-none place-items-center">
          <.icon name={:plus} size={11} />
        </span>
        <span class="min-w-0 flex-1 truncate text-[11.5px] font-semibold">
          {gettext("drop at the end of the page")}
        </span>
      </div>
    </div>
    """
  end

  # THE SAME TWO THINGS `component_entry/1` HAS TO REACH FOR. The rail counts what a node still
  # needs from the palette, and the palette is missing the component being edited and its private
  # helpers — so a required property on one of those was never counted, and the rail said nothing
  # while the panel beside it said "1 needed". Record entries go first, so a palette component of
  # the same name still wins, which is the order `component_entry/1` resolves in.
  defp declarations(%{editor: editor, record: %{} = record}),
    do: own_entries(record) ++ editor.components

  defp declarations(%{editor: editor}), do: editor.components

  defp own_entries(record) do
    named = to_string(Map.get(record, :name) || "")

    own = (named != "" && [record_entry(record, named, record)]) || []

    helpers =
      for helper <- List.wrap(Map.get(record, :helpers)),
          helper_name = to_string(Inspector.name(helper) || ""),
          helper_name != "",
          do: record_entry(record, helper_name, helper)

    own ++ helpers
  end

  attr(:section, :string, default: nil)
  attr(:record, :any, default: nil)
  attr(:expanded, :any, required: true)

  @doc false
  # WHAT THIS COMPONENT TAKES, and the first thing in the tree because it is the first thing true
  # about a component: everything below it is markup that reads these names.
  #
  # A page's rail opens on the page's own elements and there is nothing else it could open on. A
  # COMPONENT's rail opened the same way, and the declaration — the attributes and slots that decide
  # what the markup may say, what the Inspector offers, and whether a drop into a slot is allowed —
  # was reachable only by knowing that the Code window has a tab for it. The one thing with no row
  # was the one thing everything else depends on.
  #
  # Read only here, and deliberately: this is a VIEW of the Interface tab, drawn at the size of a
  # tree row. Editing a declaration means the form, with its validation and its save, so every row
  # is a way into that form rather than a second place to type. Folded, so it costs one row until
  # asked for, like `.properties` and `.markup`.
  defp interface_group(assigns) do
    assigns =
      assigns
      |> assign(:attrs, Interface.attrs(assigns.record))
      |> assign(:slots, Interface.slots(assigns.record))
      |> assign(:open?, MapSet.member?(assigns.expanded, "iface:root"))

    ~H"""
    <div :if={Section.normalize(@section) == "component" and @record != nil} class="mb-1">
      <div class="flex items-center gap-1 pr-[9px]">
        <button
          type="button"
          id="pb-interface-group"
          phx-click="toggle_expand"
          phx-value-id="iface:root"
          title={gettext("What this component takes — its attributes and slots")}
          class="flex min-w-0 flex-1 items-center gap-2 rounded-[9px] py-[6px] pl-[9px] text-left hover:bg-[#f7f6f3]"
        >
          <.icon
            name={:chevron}
            size={11}
            class={"flex-none text-[#a8a5a0] " <> ((@open? && "rotate-90") || "")}
          />
          <span class="grid size-[15px] flex-none place-items-center text-[#6d6a63]">
            <.icon name={:code} size={12} />
          </span>
          <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#6d6a63]">
            {gettext(".interface")}
          </span>
          <span class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]">
            ({length(@attrs) + length(@slots)})
          </span>
        </button>

        <%!-- TWO ACTIONS, TWO CONTROLS — the same split `.markup` makes. The chevron shows what is
              declared; this opens the form that declares it. --%>
        <button
          type="button"
          id="pb-interface-edit"
          phx-click="open_source"
          phx-value-tab="interface"
          title={gettext("Edit this component's attributes and slots")}
          class="grid size-5 flex-none place-items-center rounded-[6px] text-[#a8a5a0] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
        >
          <.icon name={:edit} size={12} />
        </button>
      </div>

      <div :if={@open?}>
        <%!-- Silence reads as "not loaded", the same way it does under `.properties`. A component
              that declares nothing says so, and says where to add one. --%>
        <div
          :if={@attrs == [] and @slots == []}
          class="py-[5px] pl-[35px] pr-[9px] text-[10.5px] font-medium text-[#a8a5a0]"
        >
          {gettext("nothing declared yet — add an attribute or a slot")}
        </div>

        <.interface_row
          :for={row <- interface_rows(@attrs, @slots)}
          name={row.name}
          label={row.label}
          detail={row.detail}
          required?={row.required?}
          kind={row.kind}
        />
      </div>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:detail, :string, default: "")
  attr(:required?, :boolean, default: false)
  attr(:kind, :atom, required: true)

  # Named the way the MARKUP names it — `@size`, `<:actions>` — rather than as the column stores it,
  # because the row beside this one is the markup that reads it and the two should read alike. The
  # DOM id keeps the stored name instead: `@` and `<` are not things a selector can be pointed at.
  defp interface_row(assigns) do
    ~H"""
    <button
      type="button"
      id={"pb-interface-#{@kind}-#{@name}"}
      phx-click="open_source"
      phx-value-tab="interface"
      title={gettext("Edit %{label} in the component's interface", label: @label)}
      class="flex w-full items-center gap-2 rounded-[9px] py-[5px] pl-[35px] pr-[9px] text-left hover:bg-[#f2f1fc]"
    >
      <span class={[
        "size-[6px] flex-none rounded-full",
        (@kind == :slot && "bg-[#8580d8]") || "bg-[#4f4bcc]"
      ]} />
      <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-medium text-[#3a382f]">
        {@label}
      </span>
      <span
        :if={@required?}
        class="flex-none rounded-[5px] bg-[#f2f1ec] px-[5px] py-px text-[9px] font-bold uppercase tracking-[0.05em] text-[#a8a5a0]"
      >
        {gettext("required")}
      </span>
      <span class="max-w-[86px] flex-none truncate font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63]">
        {@detail}
      </span>
    </button>
    """
  end

  # ATTRIBUTES FIRST, THEN SLOTS, which is the order a declaration is written in and the order
  # `.properties` and `.slots` already stand in on a page's rail. A slot is marked as one by the way
  # it is written rather than by a word beside it: `<:actions>` is a slot to anyone who would be
  # reading this rail at all, and `inner_block` is the one that is written as plain content.
  defp interface_rows(attrs, slots) do
    Enum.map(attrs, fn attr ->
      name = Interface.value(attr, "name")

      %{
        kind: :attr,
        name: name,
        label: "@" <> name,
        detail: Interface.value(attr, "type"),
        required?: Interface.required?(attr)
      }
    end) ++
      Enum.map(slots, fn slot ->
        name = Interface.value(slot, "name")

        %{
          kind: :slot,
          name: name,
          label: (name == "inner_block" && gettext("inner content")) || "<:" <> name <> ">",
          detail: slot_detail(slot),
          required?: Interface.required?(slot)
        }
      end)
  end

  defp slot_detail(slot) do
    case slot |> Interface.attrs() |> length() do
      0 -> gettext("slot")
      count -> ngettext("slot · %{count} attr", "slot · %{count} attrs", count)
    end
  end

  attr(:id, :string, required: true)
  attr(:index, :integer, default: 0)
  attr(:depth, :integer, required: true)
  attr(:tree, :any, required: true)
  attr(:selection, :string, default: nil)
  attr(:expanded, :any, required: true)
  attr(:editor, :any, required: true)
  attr(:unmet, :map, default: %{})
  attr(:current_user, :any, default: nil)

  defp layer_row(assigns) do
    assigns =
      assigns
      |> assign(:node, Tree.get(assigns.tree, assigns.id))
      |> then(&assign(&1, :kids, listed_children(&1.node, &1.tree)))
      |> then(&assign(&1, :folded?, folded?(&1.node, &1.editor)))
      |> then(&assign(&1, :entry, layer_entry(&1.node, &1.tree, &1.editor)))
      |> then(&assign(&1, :ghosts, addable_slots(&1.node, &1.entry, &1.tree)))
      |> then(&assign(&1, :props, layer_props(&1.node, &1.entry, &1.tree)))
      |> then(&assign(&1, :holds?, drop_target?(&1.node, &1.entry)))
      |> then(&assign(&1, :needs, Map.get(&1.unmet, &1.id, @no_needs)))
      |> then(&assign(&1, :off, visitor_off(&1.tree, &1.id)))
      |> then(&assign(&1, :inside, component_inside(&1.node, &1.entry, &1.expanded, &1.id)))

    ~H"""
    <div :if={@node && !whitespace?(@node)} data-layer-id={@id}>
      <%!-- Everything a drop needs to be resolved without a round trip: who the row's parent is,
            where it sits among its siblings, and whether it can take children at all. The server
            re-checks containment before it moves anything, so a wrong guess here is refused rather
            than trusted.

            `data-can` is WHERE THIS PARTICULAR DRAG COULD GO, written by the hook from the server's
            own verdict and standing for the length of one gesture. `Containment` has always been
            able to answer it; the rail just never showed it, so the only way to find out whether a
            container would take something was to drop it and read the flash. Drawn as an OUTLINE
            rather than a border or a tint because both of those are already spoken for by the drop
            marker, and because an outline costs no layout at all — which on this surface is the
            whole point. --%>
      <div
        draggable="true"
        data-layer-row={@id}
        data-parent-id={@node.parent_id || "root"}
        data-index={@index}
        data-container={@holds? && "true"}
        data-kind={@node.kind}
        data-open={openness(assigns)}
        data-pb-hidden={@off && "true"}
        class={[
          "group flex items-center gap-2 rounded-[9px] border py-[7px] pr-[9px]",
          "data-[drop=before]:border-t-[#5b57d6] data-[drop=after]:border-b-[#5b57d6]",
          "data-[drop=inside]:border-[#5b57d6] data-[drop=inside]:bg-[#f2f1fc]",
          "data-[can=true]:[outline:1px_dashed_#cfcdf0] data-[can=true]:[outline-offset:-2px]",
          cond do
            @id == @selection -> "border-[#dcdbf5] bg-[#f2f1fc]"
            held?(@editor, @id) -> "border-[#e4e2f7] bg-[#faf9fe]"
            true -> "border-transparent hover:bg-[#f7f6f3]"
          end
        ]}
        style={"padding-left:#{9 + @depth * 13}px"}
      >
        <button
          :if={expandable?(assigns)}
          type="button"
          phx-click="toggle_expand"
          phx-value-id={@id}
          class="grid size-4 flex-none place-items-center text-[#a8a5a0]"
        >
          <.icon
            name={:chevron}
            size={11}
            class={(MapSet.member?(@expanded, @id) && "rotate-90") || ""}
          />
        </button>
        <span :if={!expandable?(assigns)} class="w-3.5 flex-none" />
        <%!-- A component's own glyph is the marker. It differs from every tag glyph already, so a
              border, a tint or a badge would add weight for a distinction the icon has made. --%>
        <span class={[
          "grid size-[15px] flex-none place-items-center",
          (@id == @selection && "text-[#4f4bcc]") || "text-[#6d6a63]"
        ]}>
          <.icon name={layer_icon(@node)} size={13} />
        </span>
        <%!-- A component or a slot is a thing with a FORM behind it, so clicking it opens that form:
              the left panel comes back if it was collapsed and lands on the Inspector. Anything else
              is just a selection. --%>
        <button
          type="button"
          phx-click={(@node.kind in [:component, :slot] && "inspect") || "select"}
          phx-value-id={@id}
          title={(@node.kind == :slot && slot_label(@node, @tree)) || node_label(@node)}
          class={[
            "min-w-0 flex-1 truncate text-left font-['Space_Grotesk'] text-[12px]",
            (@id == @selection && "font-bold text-[#2e2b6b]") ||
              (@off && "font-medium text-[#a8a5a0]") || "font-medium text-[#3a382f]"
          ]}
        >
          {(@node.kind == :slot && slot_label(@node, @tree)) || node_label(@node)}
        </button>
        <span
          :if={FormPlacement.form_name(@node)}
          id={"pb-layer-form-#{@id}"}
          class="flex-none rounded-full bg-[#f2f1fc] px-1.5 py-px font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc]"
        >
          {FormPlacement.form_name(@node)}
        </span>
        <%!-- HIDDEN FROM VISITORS, said where it was done, and pressed to show it again; what is
              inside it is dimmed instead. --%>
        <button
          :if={@off == :self}
          type="button"
          id={"pb-layer-hidden-#{@id}"}
          phx-click="toggle_visibility"
          phx-value-id={@id}
          title={gettext("Hidden from visitors. Click to show it again.")}
          class="flex-none rounded-[5px] bg-[#f2f1ec] px-[5px] py-px font-['Space_Grotesk'] text-[9.5px] font-bold text-[#6d6a63] hover:bg-[#e9e7fa] hover:text-[#4f4bcc]"
        >
          {gettext("Hidden")}
        </button>
        <%!-- STILL MISSING, SOMEWHERE UNDER HERE. A required property left blank refuses the Publish
              button, and until this row drew it the first anyone heard was a flash naming a field
              several rows inside a component that may not even be open. It counts the whole subtree,
              which is the point: a shut `chelekom-video` says the `:source` inside it is unfinished
              without being opened.

              It is STATE, so it stands at rest — the same rule the hidden and locked marks follow,
              and the opposite of the controls beside it, which wait for the pointer. --%>
        <span
          :if={@needs.total > 0}
          title={needs_title(@needs)}
          class={[
            "flex-none rounded-[5px] bg-[#fdf3f1] px-[5px] py-px",
            "font-['Space_Grotesk'] text-[9.5px] font-bold text-[#c0473d]"
          ]}
        >
          {gettext("%{count} needed", count: @needs.total)}
        </span>
        <span
          :if={@kids != []}
          class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]"
        >
          ({length(@kids)})
        </span>
        <%!-- WHERE CONTENT GOES, SAID ON THE ROW ITSELF.

              This was a separate strip under every container, revealed for the row under the
              pointer — and revealing an in-flow box is a reflow. Showing one is harmless (it only
              moves what is BELOW its own row); HIDING the previous one is not, because that box sits
              ABOVE the row now under the pointer and is taller than a row. Travelling down the rail,
              every row-to-row step pulled the new row up by more than its own height, so the drop
              line jumped from "before footer" to "inside footer" with the pointer standing still —
              and reaching the end-of-page target moved it out from under the pointer entirely, which
              is a released drop that fires no `drop` event and reports nothing.

              A chip inside the row cannot do any of that. The row's height is fixed by the controls
              beside it, the chip is shorter than they are, and the only thing that changes when it
              appears is how much width the name gets — which `truncate` already handles. Nothing in
              the rail moves during a drag now, at all.

              Hidden by default rather than `group-hover`: `:hover` does not apply during a native
              drag, and this is only ever true during one. --%>
        <span
          :if={@holds?}
          data-role="pb-drop-inside"
          class={[
            "hidden flex-none items-center rounded-[6px] bg-[#5b57d6] px-[6px] py-px",
            "text-[9.5px] font-bold uppercase tracking-[0.06em] text-white",
            "group-data-[drop=inside]:flex"
          ]}
        >
          {gettext("drop inside")}
        </span>
        <%!-- STATE STAYS, CONTROLS ARRIVE. Hidden and locked are state the tree exists to report, and
              state you have to hunt for with the pointer is state you miss — so a row that IS hidden
              or IS locked keeps saying so at rest, and so does the selected row. What was costing the
              name its width is the other case: four controls held open on every row to offer actions
              nobody had asked for yet. Those wait for the pointer or the keyboard.

              `hidden` rather than `opacity-0`, because the point is the width: an invisible button
              still holds its column, and the name would truncate exactly as before. Reserved with
              `group-focus-within` too, so tab-through reaches them. --%>
        <button
          type="button"
          phx-click="toggle_hidden"
          phx-value-id={@id}
          title={
            (@folded? && gettext("Show on canvas")) ||
              gettext("Fold away on canvas, only for you. Visitors still see it.")
          }
          class={[
            "size-3.5 flex-none place-items-center hover:text-[#4f4bcc]",
            "group-hover:grid group-focus-within:grid",
            (@folded? || @id == @selection) && "grid",
            !(@folded? || @id == @selection) && "hidden",
            (@folded? && "text-[#8580d8]") ||
              ((@id == @selection && "text-[#8580d8]") || "text-[#6d6a63]")
          ]}
        >
          <.icon name={(@folded? && :eye_off) || :eye} size={12} />
        </button>
        <%!-- ONLY WHERE THERE IS SOMETHING TO PIN. An overlay opens on the canvas while it is
              selected and shuts when the selection moves on, which is what an author wants nine
              times in ten. This is the tenth: keeping a dialog open while working on the page
              behind it. Every other row has no closed state, so it gets no pin. --%>
        <button
          :if={overlay?(@entry)}
          type="button"
          phx-click="toggle_pinned"
          phx-value-id={@id}
          title={
            (pinned?(@editor, @id) && gettext("Let it close again")) ||
              gettext("Keep it open on the canvas")
          }
          class={[
            "size-5 flex-none place-items-center rounded-[6px] hover:bg-[#f2f1ec]",
            "group-hover:grid group-focus-within:grid",
            (pinned?(@editor, @id) || @id == @selection) && "grid",
            !(pinned?(@editor, @id) || @id == @selection) && "hidden",
            (pinned?(@editor, @id) && "text-[#8580d8]") || "text-[#a8a5a0]"
          ]}
        >
          <.icon name={:pin} size={12} />
        </button>
        <button
          type="button"
          phx-click="toggle_lock"
          phx-value-id={@id}
          title={(MapSet.member?(@editor.locked, @id) && gettext("Unlock")) || gettext("Lock")}
          class={[
            "size-5 flex-none place-items-center rounded-[6px] hover:bg-[#f2f1ec]",
            "group-hover:grid group-focus-within:grid",
            (MapSet.member?(@editor.locked, @id) || @id == @selection) && "grid",
            !(MapSet.member?(@editor.locked, @id) || @id == @selection) && "hidden",
            (MapSet.member?(@editor.locked, @id) && "text-[#cf8a24]") || "text-[#a8a5a0]"
          ]}
        >
          <.icon name={:lock} size={12} />
        </button>
        <%!-- A runtime component's markup belongs to the COMPONENT, not to this page: the page only
              names it and fills its slots. So the tree cannot show a `<footer>` inside it — that
              footer is the component's own document — and this is the way in to edit it. --%>
        <.link
          :if={@node.kind == :component && component_editor_path(@entry, @editor, @current_user)}
          id={"pb-layer-open-#{@id}"}
          navigate={component_editor_path(@entry, @editor, @current_user)}
          title={
            gettext(
              "Edit the ORIGINAL %{name} — its markup is shared, so this changes every page using it. The values on this page are the .properties and .slots groups below.",
              name: @entry.name
            )
          }
          class={[
            "size-5 flex-none place-items-center rounded-[6px] text-[#a8a5a0] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]",
            "group-hover:grid group-focus-within:grid",
            (@id == @selection && "grid") || "hidden"
          ]}
        >
          <.icon name={:external} size={12} />
        </.link>
        <%!-- Deleting a row deletes the branch under it, which is why the title says how many go with
              it rather than leaving that to be discovered. --%>
        <button
          type="button"
          id={"pb-layer-delete-#{@id}"}
          phx-click="op"
          phx-value-kind="delete"
          phx-value-node_id={@id}
          title={delete_title(@tree, @id)}
          class={[
            "size-5 flex-none place-items-center rounded-[6px] text-[#a8a5a0] hover:bg-[#fdf3f1] hover:text-[#c0473d]",
            "group-hover:grid group-focus-within:grid",
            (@id == @selection && "grid") || "hidden"
          ]}
        >
          <.icon name={:trash} size={12} />
        </button>
      </div>

      <%!-- A Phoenix component's PROPERTIES are part of its shape, so the tree carries them the way it
            carries children: one row each, under a group that says how many there are. Clicking one
            opens the Inspector on that exact field — the tree is the map, the Inspector is the form.
            Slots sit directly under the component, not inside a folder, and carry their own
            properties the same way. --%>
      <%!-- WHAT THIS SLOT IS, when it is not what it looks like. A slot the component never renders is
            configuration wearing a container's clothes: it has a row, it has children in the tree, and
            the canvas draws none of them. The report was exactly that — "i add a card in source but
            tell me what is the source here, because when i put card it does not show anything but it
            is located under the source".

            Containment now refuses the drop, so this is the other half: the sentence that says why,
            in the one place the question gets asked. --%>
      <div
        :if={MapSet.member?(@expanded, @id) and @node.kind == :slot and not @holds?}
        class="py-[5px] pr-[9px] text-[10.5px] font-medium text-[#a8a5a0]"
        style={"padding-left:#{9 + (@depth + 1) * 13}px"}
      >
        {gettext("set by its properties — nothing dropped here is drawn")}
      </div>

      <div :if={MapSet.member?(@expanded, @id) and (@props != [] or @node.kind == :component)}>
        <button
          type="button"
          id={"pb-props-#{@id}"}
          phx-click="toggle_expand"
          phx-value-id={"props:" <> @id}
          class="flex w-full items-center gap-2 rounded-[9px] py-[6px] pr-[9px] text-left hover:bg-[#f7f6f3]"
          style={"padding-left:#{9 + (@depth + 1) * 13}px"}
        >
          <.icon
            name={:chevron}
            size={11}
            class={
              "flex-none text-[#a8a5a0] " <>
                ((MapSet.member?(@expanded, "props:" <> @id) && "rotate-90") || "")
            }
          />
          <span class="grid size-[15px] flex-none place-items-center text-[#6d6a63]">
            <.icon name={:dial} size={12} />
          </span>
          <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#6d6a63]">
            {gettext(".properties")}
          </span>
          <span
            :if={@needs.attrs > 0}
            class="flex-none rounded-[5px] bg-[#fdf3f1] px-[5px] py-px font-['Space_Grotesk'] text-[9.5px] font-bold text-[#c0473d]"
          >
            {gettext("%{count} needed", count: @needs.attrs)}
          </span>
          <span class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]">
            ({length(@props)})
          </span>
        </button>

        <%!-- Silence reads as "not loaded". A component that declares nothing says so, and says where
              to add one, rather than leaving an empty group behind a chevron. --%>
        <div
          :if={MapSet.member?(@expanded, "props:" <> @id) and @props == []}
          class="py-[5px] pr-[9px] text-[10.5px] font-medium text-[#a8a5a0]"
          style={"padding-left:#{9 + (@depth + 2) * 13}px"}
        >
          {gettext("none declared — add one on the component itself")}
        </div>

        <button
          :for={prop <- (MapSet.member?(@expanded, "props:" <> @id) && @props) || []}
          type="button"
          id={"pb-prop-row-#{@id}-#{prop.name}"}
          phx-click="inspect"
          phx-value-id={@id}
          phx-value-prop={prop.name}
          title={gettext("Edit %{name} in the Inspector", name: prop.name)}
          class="flex w-full items-center gap-2 rounded-[9px] py-[5px] pr-[9px] text-left hover:bg-[#f2f1fc]"
          style={"padding-left:#{9 + (@depth + 2) * 13}px"}
        >
          <span class="w-3.5 flex-none"></span>
          <span class={[
            "size-[6px] flex-none rounded-full",
            cond do
              prop.missing? -> "bg-[#c0473d]"
              prop.set? -> "bg-[#4f4bcc]"
              true -> "bg-[#d5d3cc]"
            end
          ]} />
          <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-medium text-[#3a382f]">
            {prop.name}
          </span>
          <%!-- WHICH OF THESE THE COMPONENT CANNOT DO WITHOUT. They were drawn identically to the
                optional ones, so the only way to learn that `src` was compulsory was to press
                Publish and read the refusal. Loud while it is empty, quiet once it is filled: a
                satisfied requirement is worth knowing before you clear it, and worth nothing louder
                than that. --%>
          <span
            :if={prop.required?}
            class={[
              "flex-none rounded-[5px] px-[5px] py-px text-[9px] font-bold uppercase tracking-[0.05em]",
              (prop.missing? && "bg-[#fdf3f1] text-[#c0473d]") || "bg-[#f2f1ec] text-[#a8a5a0]"
            ]}
          >
            {gettext("required")}
          </span>
          <span class="max-w-[86px] flex-none truncate font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63]">
            {prop.value}
          </span>
        </button>
      </div>

      <%!-- WHAT CAN GO INSIDE, as the other half of the same question `.properties` answers. The two
            are peers and read as peers: same row, same chevron, same count, both folded until asked.

            This replaces a bare `__ no slots declared` line that hung off the bottom of the property
            list. It was the wrong shape three times over — it appeared on the COMMON case (most
            components declare no slots), it was written in the tree's internal vocabulary rather
            than the author's, and it sat under `.properties`, which is not what it was about. A
            component that takes no slots now says so once, inside the group that was asked to open,
            and says nothing at all until then. --%>
      <div :if={MapSet.member?(@expanded, @id) and @node.kind == :component and @entry != nil}>
        <button
          type="button"
          id={"pb-slots-#{@id}"}
          phx-click="toggle_expand"
          phx-value-id={"slots:" <> @id}
          class="flex w-full items-center gap-2 rounded-[9px] py-[6px] pr-[9px] text-left hover:bg-[#f7f6f3]"
          style={"padding-left:#{9 + (@depth + 1) * 13}px"}
        >
          <.icon
            name={:chevron}
            size={11}
            class={
              "flex-none text-[#a8a5a0] " <>
                ((MapSet.member?(@expanded, "slots:" <> @id) && "rotate-90") || "")
            }
          />
          <span class="grid size-[15px] flex-none place-items-center text-[#6d6a63]">
            <.icon name={:layers} size={12} />
          </span>
          <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#6d6a63]">
            {gettext(".slots")}
          </span>
          <span
            :if={@needs.slots > 0}
            class="flex-none rounded-[5px] bg-[#fdf3f1] px-[5px] py-px font-['Space_Grotesk'] text-[9.5px] font-bold text-[#c0473d]"
          >
            {gettext("%{count} needed", count: @needs.slots)}
          </span>
          <span class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]">
            ({length(@ghosts)})
          </span>
        </button>

        <div
          :if={MapSet.member?(@expanded, "slots:" <> @id) and @ghosts == []}
          class="py-[5px] pr-[9px] text-[10.5px] font-medium text-[#a8a5a0]"
          style={"padding-left:#{9 + (@depth + 2) * 13}px"}
        >
          {slots_note(@entry)}
        </div>

        <%!-- An empty slot is still part of the component's shape, so it is listed rather than
              hidden: seeing `:actions` here is how you learn the component takes one, and clicking
              it fills it. Named the way it is WRITTEN — `<:actions>` in the markup — rather than as
              `__actions_slot`, which was the tree's own bookkeeping leaking into the label.

              `index` is sent because `Op`'s own default is 0, and a slot inserted FIRST is invisible
              and poisonous: the component renders it wherever its markup says — usually last — while
              every child after it in the tree now counts one place higher than the box it draws,
              which is how a field dropped after a textarea landed in front of it. Appended, the two
              agree. --%>
        <button
          :for={
            {slot, filled?, markup} <-
              (MapSet.member?(@expanded, "slots:" <> @id) && @ghosts) || []
          }
          type="button"
          id={"pb-slot-add-#{@id}-#{slot}"}
          phx-click="op"
          phx-value-kind="insert"
          phx-value-parent_id={@id}
          phx-value-index={length(@node.children)}
          phx-value-template={markup}
          title={
            (filled? && gettext("Add another :%{slot} slot", slot: slot)) ||
              gettext("Add the :%{slot} slot to this component", slot: slot)
          }
          class="flex w-full items-center gap-2 rounded-[9px] border border-dashed border-[#dcdbf5] py-[6px] pr-[9px] text-left hover:bg-[#f7f6ff]"
          style={"padding-left:#{9 + (@depth + 2) * 13}px"}
        >
          <span class="grid size-[15px] flex-none place-items-center text-[#8580d8]">
            <.icon name={:plus} size={11} />
          </span>
          <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[12px] font-medium text-[#8580d8]">
            :{slot}
          </span>
          <span class="flex-none text-[9.5px] font-semibold text-[#a8a5a0]">
            {ghost_note(@entry, slot, filled?)}
          </span>
        </button>
      </div>

      <%!-- WHAT THE COMPONENT IS MADE OF, and the third peer of `.properties` and `.slots`.

            These rows were drawn loose, at the same indent as the page's own children and directly
            among them, with nothing saying what they were. A `chelekom-footer` put nine rows of
            somebody else's markup between the component and the one line of content the page
            actually put in it — rows that look like children of the page, are not, and accept
            nothing. The report was the plain truth: it makes the tree dirty and confusing, and if it
            is worth showing at all it belongs behind a heading like the other two.

            Folded, so it costs one row until asked for. Read only, because a component's markup
            belongs to the COMPONENT and is shared by every page using it: dragging or deleting one
            of these would rewrite the component under every other page silently. The open icon on
            the component's own row is where that edit is made deliberately. --%>
      <div :if={MapSet.member?(@expanded, @id) and @inside != []}>
        <%!-- TWO ACTIONS, TWO CONTROLS. Reading what is in there and going to edit it are different
              intents, and one row cannot be both — a link inside a button swallows the click, and a
              heading that navigated away would take the fold with it. The chevron shows, the arrow
              leaves. It is the same arrow, going to the same place, as the one on the component's
              own row: that one appears only while the row is selected, and by the time a reader has
              opened `.markup` and found the thing they want to change, this is where their eye is. --%>
        <div
          class="flex items-center gap-1 pr-[9px]"
          style={"padding-left:#{9 + (@depth + 1) * 13}px"}
        >
          <button
            type="button"
            id={"pb-markup-#{@id}"}
            phx-click="toggle_expand"
            phx-value-id={"markup:" <> @id}
            class="flex min-w-0 flex-1 items-center gap-2 rounded-[9px] py-[6px] text-left hover:bg-[#f7f6f3]"
          >
            <.icon
              name={:chevron}
              size={11}
              class={
                "flex-none text-[#a8a5a0] " <>
                  ((MapSet.member?(@expanded, "markup:" <> @id) && "rotate-90") || "")
              }
            />
            <span class="grid size-[15px] flex-none place-items-center text-[#6d6a63]">
              <.icon name={:code} size={12} />
            </span>
            <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#6d6a63]">
              {gettext(".markup")}
            </span>
            <span class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]">
              ({inside_count(@inside)})
            </span>
          </button>

          <.link
            :if={component_editor_path(@entry, @editor, @current_user)}
            id={"pb-markup-open-#{@id}"}
            navigate={component_editor_path(@entry, @editor, @current_user)}
            title={
              gettext(
                "Open %{name} and edit this markup — it is shared, so this changes every page using it",
                name: @entry.name
              )
            }
            class="grid size-5 flex-none place-items-center rounded-[6px] text-[#a8a5a0] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
          >
            <.icon name={:external} size={12} />
          </.link>
        </div>

        <div :if={MapSet.member?(@expanded, "markup:" <> @id)}>
          <div
            class="py-[5px] pr-[9px] text-[10.5px] font-medium text-[#a8a5a0]"
            style={"padding-left:#{9 + (@depth + 2) * 13}px"}
          >
            {gettext("read only — shared by every page using this component")}
          </div>
          <.inside_row
            :for={{inner, inner_tree} <- @inside}
            node={inner}
            tree={inner_tree}
            depth={@depth + 2}
          />
        </div>
      </div>

      <.layer_row
        :for={
          {child, index} <- Enum.with_index((MapSet.member?(@expanded, @id) && @node.children) || [])
        }
        id={child}
        index={index}
        depth={@depth + 1}
        tree={@tree}
        selection={@selection}
        expanded={@expanded}
        editor={@editor}
        unmet={@unmet}
        current_user={@current_user}
      />
    </div>
    """
  end

  defp assistant(assigns) do
    assigns = assign(assigns, :ai_sample?, sample?(ai_thread(assigns.ai_messages)))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div
        :if={@ai_sample? or not AiBackend.connected?()}
        class="flex-none px-3.5 pt-3.5"
      >
        <.roadmap_notice id="pb-ai-roadmap" title={gettext("The AI Assistant is not available yet")}>
          {ai_roadmap_text(@ai_sample?)}
        </.roadmap_notice>
      </div>

      <%!-- Who you are talking to, what it has already done, and how it is connected — the three
            things worth knowing before typing. --%>
      <div data-role="pb-aichrome" class="flex-none border-b border-[#f0efea] px-3.5 pb-2.5 pt-3.5">
        <div class="flex items-center gap-[9px]">
          <span class="grid size-7 flex-none place-items-center rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-white">
            <.icon name={:bolt} size={15} />
          </span>
          <div class="min-w-0">
            <div class="text-[12.5px] font-bold text-[#17161a]">{gettext("AI Assistant")}</div>
            <div class="truncate text-[10px] font-medium text-[#6d6a63]">{@ai_backend}</div>
          </div>
        </div>

        <div class="mt-[11px] flex items-center gap-2 rounded-[10px] border border-[#f0efea] bg-[#faf9f6] px-[9px] py-[7px]">
          <.icon name={:history} size={13} class="flex-none text-[#6d6a63]" />
          <span class="text-[10.5px] font-bold text-[#3a382f]">
            {ngettext(
              "%{count} revision",
              "%{count} revisions",
              ai_revision_count(ai_thread(@ai_messages))
            )}
          </span>
          <span class="flex-1"></span>
          <span class="text-[9.5px] font-semibold text-[#6d6a63]">{gettext("autosaved")}</span>
        </div>

        <button
          type="button"
          id="pb-ai-advanced"
          phx-click={
            JS.toggle(to: "#pb-ai-advanced-body")
            |> JS.toggle_class("is-open", to: "#pb-ai-advanced")
          }
          class="mt-[7px] flex w-full items-center gap-2 rounded-[9px] px-[9px] py-[7px] hover:bg-[#f2f1fc]"
        >
          <.icon name={:link} size={13} class="flex-none text-[#6d6a63]" />
          <span class="min-w-0 flex-1 text-left text-[10px] font-bold uppercase tracking-[0.05em] text-[#6d6a63]">
            {gettext("Advanced settings")}
          </span>
          <span class={[
            "rounded-[20px] px-2 py-0.5 text-[10px] font-bold",
            (AiBackend.connected?() && "bg-[#e6f6ee] text-[#177a53]") || "bg-[#f4f3ef] text-[#6d6a63]"
          ]}>
            {(AiBackend.connected?() && gettext("Connected")) || gettext("Not connected")}
          </span>
          <.icon
            name={:chevron}
            size={12}
            class="flex-none rotate-90 text-[#a8a5a0] [.is-open_&]:-rotate-90"
          />
        </button>

        <div
          id="pb-ai-advanced-body"
          class="mt-1.5 hidden rounded-[11px] border border-[#e4e2f7] bg-[#faf9ff] px-[11px] py-2.5"
        >
          <div class="flex items-center gap-[7px]">
            <span class={[
              "size-1.5 flex-none rounded-full",
              (AiBackend.connected?() && "bg-[#1f9d6b]") || "bg-[#a8a5a0]"
            ]} />
            <span class="min-w-0 flex-1 text-[10.5px] font-semibold text-[#3a382f]">
              {@ai_backend}
            </span>
          </div>
          <p class="mt-2 text-[9.5px] font-medium leading-[1.5] text-[#6d6a63]">
            {AiBackend.adapter_note()}
          </p>
        </div>
      </div>

      <%!-- The thread. A reply that changed the document carries its revision, so it can be rolled
            back from where it was made rather than from a separate history list. --%>
      <div
        id="pb-ai-thread"
        data-role="pb-thread"
        class="flex min-h-0 flex-1 flex-col gap-2.5 overflow-y-auto p-3.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        <p
          :if={ai_thread(@ai_messages) == []}
          class="text-[11.5px] font-medium leading-[1.55] text-[#5c5a54]"
        >
          {gettext(
            "I can edit this page for you — describe a change, or select an element and use “Ask AI” to scope it."
          )}
        </p>

        <div
          :for={{message, index} <- Enum.with_index(ai_thread(@ai_messages))}
          id={"pb-ai-msg-#{index}"}
          class={[
            "flex items-start gap-2",
            (message.role == :user && "flex-row-reverse") || "flex-row"
          ]}
        >
          <span class={[
            "grid size-[26px] flex-none place-items-center rounded-full font-['Space_Grotesk'] text-[9.5px] font-bold text-white",
            (message.role == :user && "bg-[#5b57d6]") ||
              "bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)]"
          ]}>
            {ai_initials(message)}
          </span>

          <div class={[
            "max-w-[82%] rounded-[12px] border px-2.5 py-2",
            (message.role == :user && "border-[#e4e2f7] bg-[#f2f1fc]") || "border-[#f0efea] bg-white"
          ]}>
            <div class="mb-[5px] flex items-center gap-[7px]">
              <span class={[
                "text-[10px] font-bold",
                (message.role == :user && "text-[#2e2b6b]") || "text-[#4f4bcc]"
              ]}>
                {ai_sender(message)}
              </span>
              <span
                :if={message.scope}
                class="rounded-[5px] bg-[#f4f3ef] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9px] font-bold text-[#6d6a63]"
              >
                {message.scope}
              </span>
            </div>

            <%!-- What was sent with the question, named. The prototype shows a screenshot chip; this
                  shows what actually travelled. --%>
            <div
              :if={message[:attachment]}
              class="mb-[7px] flex items-center gap-[7px] rounded-[8px] bg-[#5b57d6]/[.10] px-2 py-1.5"
            >
              <.icon name={:paperclip} size={12} class="flex-none text-[#4f4bcc]" />
              <span class="min-w-0 truncate font-['Space_Grotesk'] text-[10px] font-semibold text-[#4f4bcc]">
                {message[:attachment]}
              </span>
            </div>

            <div dir="auto" class="text-[12px] font-medium leading-[1.55] text-[#3a382f]">
              {message.text}
            </div>

            <div
              :if={message[:revision]}
              class="mt-[9px] flex items-center gap-2 border-t border-[#f0efea] pt-[9px]"
            >
              <span class="flex-none rounded-[5px] bg-[#f2f1fc] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc]">
                {message.revision}
              </span>
              <span class="min-w-0 flex-1 truncate text-[9.5px] font-medium text-[#6d6a63]">
                {message[:revision_note]}
              </span>
              <button
                type="button"
                id={"pb-ai-restore-#{index}"}
                phx-click="ai_restore"
                phx-value-index={index}
                title={gettext("Roll back to this revision")}
                class="inline-flex h-[23px] flex-none items-center gap-[5px] rounded-[6px] border border-[#ecebe6] bg-white px-2 text-[9.5px] font-bold text-[#5c5a54] hover:border-[#c3c1f0] hover:text-[#4f4bcc]"
              >
                <.icon name={:undo} size={10} /> {gettext("Restore")}
              </button>
            </div>

            <div
              :if={message[:plain]}
              class="mt-[7px] text-[10.5px] font-medium leading-[1.55] text-[#6d6a63]"
            >
              {message[:plain]}
            </div>
          </div>
        </div>
      </div>

      <div data-role="pb-composer" class="flex-none border-t border-[#f0efea] px-3.5 pb-3.5 pt-3">
        <%!-- Starter phrasings. They fill the box rather than sending, so the wording stays the
              author's to adjust. --%>
        <div
          data-role="pb-chips"
          id="pb-ai-chips"
          phx-hook="PbDragScroll"
          class="mb-[9px] flex cursor-grab select-none gap-[5px] overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
        >
          <button
            :for={chip <- ai_chips()}
            type="button"
            phx-click="ai_chip"
            phx-value-text={chip}
            class="h-[26px] flex-none whitespace-nowrap rounded-[20px] border border-[#ecebe6] bg-white px-2.5 text-[10px] font-semibold text-[#6d6a63] hover:border-[#dcdbf5] hover:text-[#4f4bcc]"
          >
            {chip}
          </button>
        </div>

        <.form
          for={%{}}
          as={:ai}
          id="pb-ai-form"
          phx-change="ai_change"
          phx-submit="ai_submit"
          class="rounded-[13px] border border-[#ecebe6] bg-[#faf9f6] p-2.5 focus-within:border-[#c3c1f0] focus-within:bg-white"
        >
          <div
            :if={@ai_attachment}
            id="pb-ai-attachment"
            class="mb-2 flex items-center gap-[7px] rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2 py-1.5"
          >
            <.icon name={:paperclip} size={12} class="flex-none text-[#4f4bcc]" />
            <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10px] font-semibold text-[#4f4bcc]">
              {@ai_attachment.label}
            </span>
            <button
              type="button"
              id="pb-ai-attachment-drop"
              phx-click="drop_attachment"
              title={gettext("Remove")}
              class="grid size-4 flex-none place-items-center rounded-[5px] text-[#6d6a63] hover:text-[#c0473d]"
            >
              <.icon name={:close} size={11} />
            </button>
          </div>

          <textarea
            id="pb-ai-prompt"
            name="prompt"
            phx-debounce="blur"
            rows="2"
            placeholder={
              gettext("Describe a change — e.g. “add a testimonials section under the hero”")
            }
            class="min-h-[56px] w-full resize-none border-0 bg-transparent p-0 text-[12px] font-medium leading-[1.55] text-[#1b1a18] outline-none [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
          >{@ai_prompt}</textarea>
          <div class="mt-1.5 flex items-center gap-[7px]">
            <%!-- Attach. Each item sends REAL context with the next prompt — the selected element's
                  own markup, the whole template, or a file from the site's media library — because a
                  model that is handed a picture of a screenshot and nothing else cannot act on it,
                  and this editor already has the source. --%>
            <div class="relative flex-none" phx-click-away={menu_close("#pb-ai-attach-menu")}>
              <button
                type="button"
                id="pb-ai-attach"
                phx-click={menu_toggle("#pb-ai-attach-menu")}
                title={gettext("Attach")}
                class="grid size-[30px] place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
              >
                <.icon name={:plus} size={16} />
              </button>

              <div
                id="pb-ai-attach-menu"
                phx-window-keydown={menu_close("#pb-ai-attach-menu")}
                phx-key="escape"
                class="absolute bottom-9 left-0 z-40 hidden w-[224px] rounded-[12px] border border-[#ecebe6] bg-white p-[5px] shadow-[0_16px_44px_rgba(20,18,26,.2)]"
              >
                <button
                  type="button"
                  id="pb-ai-attach-selection"
                  phx-click={menu_close("#pb-ai-attach-menu") |> JS.push("attach")}
                  phx-value-kind="selection"
                  disabled={is_nil(@selected_node)}
                  class="flex w-full items-center gap-2.5 rounded-[9px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2] disabled:cursor-not-allowed disabled:opacity-45"
                >
                  <.icon name={:frame} size={15} class="flex-none text-[#4f4bcc]" />
                  <span>
                    <span class="block text-[11.5px] font-semibold text-[#1b1a18]">
                      {gettext("Capture selection")}
                    </span>
                    <span class="block text-[10px] font-medium text-[#6d6a63]">
                      {gettext("Just the selected element")}
                    </span>
                  </span>
                </button>
                <button
                  type="button"
                  id="pb-ai-attach-template"
                  phx-click={menu_close("#pb-ai-attach-menu") |> JS.push("attach")}
                  phx-value-kind="template"
                  class="flex w-full items-center gap-2.5 rounded-[9px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2]"
                >
                  <.icon name={:window} size={15} class="flex-none text-[#4f4bcc]" />
                  <span>
                    <span class="block text-[11.5px] font-semibold text-[#1b1a18]">
                      {gettext("Capture template")}
                    </span>
                    <span class="block text-[10px] font-medium text-[#6d6a63]">
                      {gettext("The whole page canvas")}
                    </span>
                  </span>
                </button>
                <span class="mx-1.5 my-1 block h-px bg-[#f0efea]"></span>
                <button
                  type="button"
                  id="pb-ai-attach-file"
                  phx-click={menu_close("#pb-ai-attach-menu") |> JS.push("attach")}
                  phx-value-kind="file"
                  class="flex w-full items-center gap-2.5 rounded-[9px] px-2.5 py-[9px] text-left hover:bg-[#f6f5f2]"
                >
                  <.icon name={:draft} size={15} class="flex-none text-[#4f4bcc]" />
                  <span>
                    <span class="block text-[11.5px] font-semibold text-[#1b1a18]">{gettext(
                      "Add file"
                    )}</span>
                    <span class="block text-[10px] font-medium text-[#6d6a63]">
                      {gettext("Image, HTML, or design spec")}
                    </span>
                  </span>
                </button>
              </div>
            </div>

            <span class="inline-flex min-w-0 flex-1 items-center gap-1.5">
              <span class="size-[5px] flex-none rounded-full bg-[#5b57d6]" />
              <span class="truncate font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#6d6a63]">
                {(@selected_node && selection_tag(@selected_node)) || gettext("whole page")}
              </span>
            </span>
            <button
              id="pb-ai-send"
              type="submit"
              class="inline-flex h-[30px] flex-none items-center gap-1.5 rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3 text-[11.5px] font-bold text-white"
            >
              <.icon name={:arrow_right} size={13} /> {gettext("Send")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # An empty thread shows the sample conversation when the demo flag is on; one real message and the
  # session's own transcript is all that shows.
  defp ai_thread([]), do: Demo.messages()
  defp ai_thread(messages) when is_list(messages), do: messages

  # `Demo` marks every sample entry `demo?: true`; a message or a finding with a key of its own, or
  # none, is a real one.
  defp sample?(%{} = entry), do: Map.get(entry, :demo?) == true
  defp sample?(entries) when is_list(entries), do: Enum.any?(entries, &sample?/1)
  defp sample?(_other), do: false

  defp ai_roadmap_text(true),
    do:
      gettext(
        "This part of the editor is on our roadmap. The conversation below is a sample of how it will work."
      )

  defp ai_roadmap_text(false), do: gettext("This part of the editor is on our roadmap.")

  defp audit_roadmap_title(true), do: gettext("Some checks are not available yet")

  defp audit_roadmap_title(false),
    do: gettext("Some checks and automatic fixes are not available yet")

  defp audit_roadmap_text(connected?, sample?) do
    [
      {not connected?,
       gettext("Fix hands a finding to the AI Assistant, which is on our roadmap.")},
      {sample?,
       gettext("Findings marked Sample show how they will look; they are on our roadmap.")}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map_join(" ", &elem(&1, 1))
  end

  # A Forms finding is mended by `FormChecks`; Fix on any other is handed to the assistant.
  defp assistant_fix?(%{rule: rule}), do: not FormChecks.rule?(rule)

  defp fix_off?(finding, connected?),
    do: sample?(finding) or (assistant_fix?(finding) and not connected?)

  defp fix_title(finding, connected?) do
    case fix_off?(finding, connected?) and not sample?(finding) do
      true -> gettext("Needs the AI Assistant, which is on our roadmap")
      false -> nil
    end
  end

  defp sample_badge_id(%{rule: rule, node_id: nil}), do: "pb-audit-sample-#{rule}"
  defp sample_badge_id(%{rule: rule, node_id: node_id}), do: "pb-audit-sample-#{rule}-#{node_id}"

  # The prototype's starter phrasings, as things this editor can actually be asked for.
  defp ai_chips do
    [
      gettext("Make the header sticky"),
      gettext("Add a testimonials section"),
      gettext("Tighten the spacing"),
      gettext("Improve the heading copy")
    ]
  end

  defp ai_revision_count(messages),
    do: Enum.count(messages, &(is_map(&1) and Map.get(&1, :revision)))

  defp ai_sender(%{role: :user, author: author}) when is_binary(author), do: author
  defp ai_sender(%{role: :user}), do: gettext("You")
  defp ai_sender(_message), do: gettext("AI Assistant")

  defp ai_initials(message) do
    message
    |> ai_sender()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase/1)
  end

  defp audit(assigns) do
    assigns =
      assigns
      |> assign(:findings, audit_findings(assigns.tree, assigns.record, assigns.editor))
      |> then(&assign(&1, :groups, audit_groups(&1.findings)))
      |> then(&assign(&1, :audit_sample?, sample?(&1.findings)))
      |> assign(:ai_connected?, AiBackend.connected?())

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col gap-3.5 overflow-y-auto p-3.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
      <.roadmap_notice
        :if={@audit_sample? or not @ai_connected?}
        id="pb-audit-roadmap"
        title={audit_roadmap_title(@ai_connected?)}
        class="flex-none"
      >
        {audit_roadmap_text(@ai_connected?, @audit_sample?)}
      </.roadmap_notice>

      <%!-- The score is a ring, not a number in a box: the sweep is the reading, and the line under
            it says what kind of problem it is. --%>
      <div class="flex items-center gap-3 rounded-[13px] border border-[#f0efea] bg-[#faf9f6] p-[13px]">
        <span
          class="grid size-11 flex-none place-items-center rounded-full"
          style={"background:conic-gradient(#{score_colour(@findings)} 0 #{audit_score(@findings)}%, #ecebe6 #{audit_score(@findings)}% 100%)"}
        >
          <span
            id="pb-audit-score"
            class="grid size-[34px] place-items-center rounded-full bg-white font-['Space_Grotesk'] text-[12.5px] font-bold text-[#1b1a18]"
          >
            {audit_score(@findings)}
          </span>
        </span>
        <div class="min-w-0">
          <div class="text-[12.5px] font-bold text-[#1b1a18]">{gettext("Page score")}</div>
          <div id="pb-audit-summary" class="mt-0.5 text-[10.5px] font-medium text-[#6d6a63]">
            {audit_summary(@findings)}
          </div>
        </div>
        <span class="flex-1"></span>
        <button
          type="button"
          id="pb-audit-rerun"
          phx-click="audit_rerun"
          class="h-7 flex-none rounded-[8px] border border-[#ecebe6] bg-white px-[11px] text-[10.5px] font-semibold text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
        >
          {gettext("Re-run")}
        </button>
      </div>

      <div :for={{key, title, badge, items} <- @groups} id={"pb-audit-group-#{key}"}>
        <div class="mb-2 flex items-center gap-2">
          <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
            {title}
          </span>
          <span
            id={"pb-audit-badge-#{key}"}
            class={[
              "rounded-[20px] px-2 py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold",
              (issue_count(items) == 0 && "bg-[#e6f6ee] text-[#177a53]") ||
                "bg-[#fdf9ec] text-[#8a5514]"
            ]}
          >
            {badge}
          </span>
        </div>

        <div class="flex flex-col gap-[7px]">
          <div
            :for={finding <- items}
            class={[
              "flex items-start gap-[9px] rounded-[11px] border px-[11px] py-[10px]",
              severity_card(finding.severity)
            ]}
          >
            <span class={[
              "grid size-[18px] flex-none place-items-center rounded-full text-white",
              severity_dot(finding.severity)
            ]}>
              <.icon name={severity_icon(finding.severity)} size={11} />
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex min-w-0 flex-wrap items-center gap-1.5">
                <button
                  :if={finding.node_id}
                  type="button"
                  phx-click="select"
                  phx-value-id={finding.node_id}
                  class="block text-left text-[11.5px] font-semibold text-[#1b1a18] hover:text-[#4f4bcc]"
                >
                  {finding.message}
                </button>
                <span
                  :if={!finding.node_id}
                  class="block text-[11.5px] font-semibold text-[#1b1a18]"
                >
                  {finding.message}
                </span>
                <span
                  :if={sample?(finding)}
                  id={sample_badge_id(finding)}
                  data-role="pb-sample-badge"
                  class="flex-none rounded-[5px] bg-[#f4f3ef] px-1.5 py-0.5 font-['Space_Grotesk'] text-[9px] font-bold text-[#6d6a63]"
                >
                  {gettext("Sample")}
                </span>
              </div>
              <div class="mt-0.5 text-[10.5px] font-medium leading-[1.45] text-[#6d6a63]">
                {finding.detail}
              </div>
            </div>
            <button
              :if={finding.severity != :ok and !finding[:fixes]}
              type="button"
              id={fix_id(finding)}
              data-rule={finding.rule}
              phx-click={!fix_off?(finding, @ai_connected?) && "audit_fix"}
              phx-value-rule={finding.rule}
              phx-value-id={finding.node_id}
              disabled={fix_off?(finding, @ai_connected?)}
              title={fix_title(finding, @ai_connected?)}
              class="h-[22px] flex-none rounded-[6px] border border-[#ecebe6] bg-white px-2 text-[9.5px] font-bold text-[#4f4bcc] hover:bg-[#f2f1fc] disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:bg-white"
            >
              {gettext("Fix")}
            </button>
            <%!-- A finding with more than one way out offers each by name; the first keeps the
                  finding's own Fix id. --%>
            <div :if={finding[:fixes]} class="flex flex-none flex-col items-end gap-1">
              <button
                :for={{fix, at} <- Enum.with_index(finding[:fixes] || [])}
                type="button"
                id={(at == 0 && fix_id(finding)) || "#{fix_id(finding)}-#{fix.fix}"}
                data-rule={(at == 0 && finding.rule) || nil}
                data-fix={fix.fix}
                phx-click={!fix_off?(finding, @ai_connected?) && "audit_fix"}
                phx-value-rule={finding.rule}
                phx-value-id={finding.node_id}
                phx-value-fix={fix.fix}
                disabled={fix_off?(finding, @ai_connected?)}
                title={fix_title(finding, @ai_connected?)}
                class="h-[22px] rounded-[6px] border border-[#ecebe6] bg-white px-2 text-[9.5px] font-bold text-[#4f4bcc] hover:bg-[#f2f1fc] disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:bg-white"
              >
                {fix.label}
              </button>
            </div>
          </div>

          <p :if={items == []} class="text-[10.5px] font-medium text-[#6d6a63]">
            {gettext("Nothing to report.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # The prototype's three headings. Every group is shown, including a clean one — "nothing here" is a
  # result, and a group that vanishes when it passes reads as a check that never ran.
  defp audit_groups(findings) do
    for {key, title} <- [
          {:structure, gettext("Structure")},
          {:accessibility, gettext("Accessibility")},
          {:forms, gettext("Forms")},
          {:seo, gettext("SEO & Meta")},
          {:performance, gettext("Performance")}
        ],
        items = Enum.filter(findings, &(&1.group == key)),
        shown?(key, items) do
      {key, title, group_badge(items), items}
    end
  end

  # Forms is the one heading that is not always about this page: a document with no form and no
  # field raises nothing here and earns no ticks either, and an empty "Forms" group reads as a
  # warning about something that is not on the page.
  defp shown?(:forms, items), do: items != []

  # Structure asks a question only a layout has an answer to, so on a page there is nothing to show
  # and an empty heading would read as a check that failed to run.
  defp shown?(:structure, items), do: items != []

  # And SEO asks nothing at all of a record with no SEO fields — an error page, a component — so the
  # heading goes with the lines rather than standing over an empty box. Anything that DOES have them
  # keeps the group whether it is clean or not.
  defp shown?(:seo, items), do: items != []
  defp shown?(_group, _items), do: true

  # A passing row is not an issue, so it must not be counted as one — a group of four green ticks is
  # "healthy", not "4 issues". A note is not an issue either, and is counted on its own.
  defp group_badge(items),
    do: items |> issue_count() |> badge(Enum.count(items, &(&1.severity == :note)))

  defp issue_count(items), do: Enum.count(items, &(&1.severity in [:blocker, :warning]))

  defp badge(0, 0), do: gettext("healthy")
  defp badge(0, notes), do: ngettext("%{count} note", "%{count} notes", notes)
  defp badge(count, _notes), do: ngettext("%{count} issue", "%{count} issues", count)

  defp audit_summary(findings) do
    blockers = Enum.count(findings, &(&1.severity == :blocker))
    warnings = Enum.count(findings, &(&1.severity == :warning))

    case blockers + warnings do
      0 ->
        gettext("No blockers, no warnings")

      _any ->
        gettext("%{blockers} · %{warnings}",
          blockers: ngettext("%{count} blocker", "%{count} blockers", blockers),
          warnings: ngettext("%{count} warning", "%{count} warnings", warnings)
        )
    end
  end

  defp score_colour(findings) do
    case audit_score(findings) do
      score when score >= 90 -> "#1f9d6b"
      score when score >= 70 -> "#cf8a24"
      _low -> "#c3373c"
    end
  end

  defp severity_card(:blocker), do: "border-[#f5dcd8] bg-[#fdf3f1]"
  defp severity_card(:warning), do: "border-[#f0e6c8] bg-[#fdf9ec]"
  defp severity_card(:note), do: "border-[#dcdbf5] bg-[#f6f5ff]"
  defp severity_card(_ok), do: "border-[#d7eddf] bg-[#f2faf5]"

  defp severity_dot(:blocker), do: "bg-[#c3373c]"
  defp severity_dot(:warning), do: "bg-[#cf8a24]"
  defp severity_dot(:note), do: "bg-[#6d69e6]"
  defp severity_dot(_ok), do: "bg-[#1f9d6b]"

  defp severity_icon(:blocker), do: :close
  defp severity_icon(:warning), do: :minus
  defp severity_icon(:note), do: :code
  defp severity_icon(_ok), do: :check

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

  @doc """
  The page's real source, in a window big enough to work in.

  ## What it shows

  `Serializer.to_heex/1` — the exact bytes a save writes, formatted — and not the unformatted
  `serialize/1` output the bottom drawer shows. That difference is the whole point: this answers
  "what is actually stored", so it has to be the stored string and not something that merely looks
  like it. When formatting fails, the raw serialisation is shown with the reason above it; a page
  whose source you cannot see is worse than an ugly one.

  ## Why it is editable

  Reading is the common case, but the fastest way to fix a stray attribute, paste a section from
  somewhere else, or undo a mess is to edit the markup. Applying re-parses the text and replaces the
  working tree through `EditorSession.put_tree/3` — the same call a draft restore makes — so it is
  one undo step and every open frame follows. Nothing reaches the database until Save, exactly as
  with any other edit.

  Unparseable text is refused with the parser's own message and the window stays open with the text
  still in it. Losing what someone just typed is not an acceptable way to report a typo.

  This is the TOP bar's Code. The drawer under the canvas is a different surface with a different
  job and is deliberately left alone.
  """
  attr(:source, :string, required: true)
  attr(:error, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:tab, :atom, default: :template)
  attr(:fragments, :map, default: %{})
  attr(:fault, :any, default: nil)
  attr(:rules, :map, default: %{})
  attr(:tree, :any, default: nil)
  attr(:code_allowed?, :boolean, default: false)
  attr(:section, :string, default: "page")
  attr(:record, :any, default: nil)
  attr(:current_user, :any, default: nil)

  attr(:code_focus, :any,
    default: nil,
    doc:
      "what the Handlers tab puts in front of the reader: `{:entry, index}` or `{:form, node_id}`"
  )

  attr(:retagged, :map,
    default: %{},
    doc: "the stored handler names a pending rename moves onto its form's tagged names"
  )

  def source_modal(assigns) do
    ~H"""
    <div
      id="pb-source-modal"
      class="fixed inset-0 z-[92] flex items-center justify-center bg-[#17161a]/[.42] px-5 py-[4vh]"
      phx-mounted={modal_in("#pb-source-modal > section")}
      phx-remove={modal_out("#pb-source-modal > section")}
      phx-window-keydown="close_source"
      phx-key="escape"
    >
      <%!-- `phx-click-away` goes on the PANEL, not the backdrop: on a full-screen backdrop no click
            is ever "away" from it, so the overlay would never close. --%>
      <section
        phx-click-away="close_source"
        class="flex h-[min(92vh,860px)] w-full max-w-[1100px] flex-col overflow-hidden rounded-[18px] bg-white shadow-[0_30px_80px_rgba(20,18,26,.4)]"
      >
        <header class="flex items-center gap-3 border-b border-[#ecebe6] px-5 py-4">
          <span class="grid size-[34px] flex-none place-items-center rounded-[10px] bg-[#f2f1fc] text-[#4f4bcc]">
            <.icon name={:code} size={17} />
          </span>
          <div class="min-w-0">
            <%!-- A window headed "Page code" while it edits a COMPONENT is lying about what it
                  changes, and the Interface tab makes that worse: those columns belong to the
                  component and to nothing else. --%>
            <div class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
              {gettext("%{section} code", section: translate(Section.label(@section)))}
            </div>
            <div class="truncate text-[11px] font-medium text-[#6d6a63]">
              {gettext("%{label} — what is stored when you save", label: @label)}
            </div>
          </div>
          <span class="flex-1"></span>
          <button
            :if={@tab == :template}
            type="button"
            id="pb-source-copy"
            phx-hook="PbCopy"
            data-copy={@source}
            class="flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3 py-1.5 text-[11.5px] font-bold text-[#5c5a54] hover:border-[#dcdbf5] hover:text-[#4f4bcc]"
          >
            {gettext("Copy")}
          </button>
          <button
            type="button"
            id="pb-source-close"
            phx-click="close_source"
            title={gettext("Close")}
            class="grid size-8 flex-none place-items-center rounded-[9px] text-[#6d6a63] hover:bg-[#f4f3ee]"
          >
            <.icon name={:close} size={15} />
          </button>
        </header>

        <div class="flex gap-0.5 border-b border-[#ecebe6] bg-white px-5 py-3">
          <div class="flex flex-1 gap-0.5 rounded-[10px] bg-[#f2f1ec] p-[3px]">
            <button
              :for={
                {key, label, count} <-
                  source_tabs(@fragments, @rules, @code_allowed?, @section, @record)
              }
              id={"pb-sourcetab-#{key}"}
              {leaving(@tab, key)}
              class={[
                "flex h-[30px] min-w-0 flex-1 items-center justify-center gap-1.5 rounded-[8px] px-1.5 text-[11px] font-bold",
                (@tab == key && "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,.1)]") ||
                  "text-[#6d6a63]"
              ]}
            >
              {label}
              <span
                :if={count > 0}
                class="rounded-full bg-[#f2f1fc] px-1.5 text-[10px] font-bold text-[#4f4bcc]"
              >
                {count}
              </span>
            </button>
          </div>
        </div>

        <p
          :if={@error}
          id="pb-source-error"
          class="border-b border-[#f0dcd8] bg-[#fdf3f1] px-5 py-2.5 text-[11.5px] font-semibold text-[#c0473d]"
        >
          {@error}
        </p>

        <form
          :if={@tab == :template}
          id="pb-source-form"
          phx-auto-recover="ignore"
          phx-submit="apply_source"
          class="flex min-h-0 flex-1 flex-col"
        >
          <%!-- Keyed on the text, like the drawer's two panes: `phx-update="ignore"` keeps LiveView
                out of the DOM CodeMirror builds, and a changed key is the only way a new document
                gets in. A refused apply does not move the tree, so it does not move the key, so the
                markup somebody just typed stays where they typed it. --%>
          <div
            id={"pb-source-editor-#{:erlang.phash2(@source)}"}
            data-fill="true"
            data-role="pb-source-editor"
            phx-hook="PbCodeEditor"
            phx-update="ignore"
            data-language="heex"
            data-accent-panel
            class="min-h-0 flex-1 overflow-hidden bg-[#17161a] px-5 py-2 [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
          >
            <textarea
              id={"pb-source-text-#{:erlang.phash2(@source)}"}
              data-role="pb-source-text"
              name="source"
              spellcheck="false"
              class="h-full w-full resize-none border-0 bg-transparent font-['Space_Grotesk'] text-[12.5px] leading-[1.7] text-[#c9c7d1] outline-none"
            >{@source}</textarea>
          </div>

          <footer class="flex items-center gap-2 border-t border-[#ecebe6] px-5 py-3.5">
            <span class="min-w-0 flex-1 text-[11px] font-medium text-[#8a877f]">
              {gettext("Editing here replaces the whole document. It is one undo away.")}
            </span>
            <button
              type="button"
              phx-click="close_source"
              class="flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3.5 py-2 text-[12px] font-bold text-[#5c5a54]"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              id="pb-source-apply"
              class="flex-none rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white hover:bg-[#2a282f]"
            >
              {gettext("Apply to the page")}
            </button>
          </footer>
        </form>

        <.style_rules :if={@tab == :styles} rules={@rules} tree={@tree} />

        <.interface_editor
          :if={@tab == :interface}
          record={@record}
          source={@source}
          resource={Section.resource(@section)}
          record_id={@record && @record.id}
          current_user={@current_user}
        />

        <.code_entries
          :if={@tab not in [:template, :styles, :interface] and @code_allowed?}
          tab={@tab}
          entries={Map.get(@fragments, @tab, [])}
          fault={@fault}
          lifecycle={@tab == :helpers and live_record?(@record)}
          shared={global_document?(assigns)}
          forms={page_handler_forms(@tab, @tree, Map.get(@fragments, @tab, []), @retagged)}
          focus={@code_focus}
        />
      </section>
    </div>
    """
  end

  # The three tabs beside Template are the Page attributes the runtime already compiles — `events`
  # into `handle_event/3`, `infos` into `handle_info/2`, `helpers` into plain `def`s. They have been
  # storable since the resource was written and reachable only from the Pages form; the builder is
  # where someone is when they need them.
  #
  # STYLES IS AN INDEX, NOT A FIFTH CODE BOX. Six tabs of editable code in a visual builder is how a
  # page builder turns into a worse IDE, so this one only READS: the element rules this page owns,
  # each labelled with the element it belongs to and each a click away from being selected. The box
  # that edits one of them is in the Inspector, where the element is.
  #
  # It is here rather than on Runtime → Stylesheets because these rules are the PAGE's: one row per
  # document, keyed on classes in this page's markup. The site's own stylesheets are a different
  # thing with a different scope and they stay where they are.
  #
  # AND THERE IS NO SCRIPTS TAB, for the same test read the other way. A `JsHook` is a site-wide
  # resource, not a page column, so a window headed "Page code" that edited one would be lying about
  # what it changes. The Inspector's picker attaches an existing hook and its New hook link goes to
  # Runtime → JS hooks, which is the right amount of friction in front of shipping JavaScript.
  # WHAT IS TYPED IN A CODE TAB IS NOT ON THE SERVER YET. The boxes are form fields and nothing posts
  # them until Save, so a tab switch re-rendered the form from the last SAVED state and threw away
  # whatever was in it — the name, the code, all of it. Watched: fill in a handler, click Messages,
  # come back, and the handler is empty; Save then answers "this handler has no code" about a box
  # that was full a moment ago.
  #
  # So leaving a code tab submits the form, which is the only thing that carries those values to the
  # server, and `save_code` stashes them and moves the tab rather than writing anything. Where it is
  # going travels as the SUBMIT BUTTON'S OWN VALUE — a browser sends that only for the button that
  # submitted, so Save carries no destination and needs nothing reset afterwards. A hidden field
  # would: LiveView does not patch an input's value back, so the last tab clicked stayed in it and
  # the next press of Save switched tabs instead of saving.
  #
  # Not `phx-change`: the editor's element id contains a hash of the code — which is how a
  # server-side change reaches a box that is `phx-update="ignore"` — so feeding every keystroke back
  # would give the element a new id on every keystroke and remount CodeMirror under the cursor.
  defp leaving(from, to) when from in [:state, :events, :infos, :helpers],
    do: [type: "submit", form: "pb-code-form", name: "go", value: to]

  defp leaving(_from, to),
    do: [type: "button", "phx-click": "source_tab", "phx-value-tab": to]

  defp source_tabs(fragments, rules, code_allowed?, section, record) do
    # WHAT THIS RECORD IS, not what every record could be. Only a component has an interface to
    # declare — a page takes no attributes and has no slots — so the tab is not drawn anywhere it
    # would open onto columns the resource does not have.
    interface =
      case section do
        "component" ->
          [
            {:interface, gettext("Interface"),
             length(Interface.attrs(record)) + length(Interface.slots(record))}
          ]

        _other ->
          []
      end

    # AND ONLY THE ONES THE RECORD HAS A COLUMN FOR. `events` and `infos` are Page attributes; a
    # Layout, a Component and an error page have `helpers` and no handlers. The writer already knew
    # — `BuilderLive.code_keys/1` asks the resource and drops the rest — so a handler typed on a
    # layout was silently discarded and then flashed as "Saved to the layout". Asked of the resource
    # here too, so the window cannot offer a tab the save will throw away.
    code =
      case code_allowed? do
        true ->
          Enum.filter(
            [
              {:state, gettext("State"), length(Map.get(fragments, :state, []))},
              {:events, gettext("Handlers"), length(Map.get(fragments, :events, []))},
              {:infos, gettext("Messages"), length(Map.get(fragments, :infos, []))},
              {:helpers, gettext("Helpers"), length(Map.get(fragments, :helpers, []))}
            ],
            fn {key, _label, _count} -> holds_code?(section, record, key) end
          )

        # HIDDEN, NOT DISABLED. A greyed tab advertises a capability and invites asking for it; the
        # three that are gone are the ones that store Elixir, and Template and Styles are still here
        # because markup and CSS are what the editor is FOR.
        #
        # This is a courtesy rather than the security. `Validations.CodeChange` refuses the write
        # whatever this draws, which is what makes hiding safe to do here at all.
        false ->
          []
      end

    [{:template, gettext("Template"), 0}] ++
      interface ++ code ++ [{:styles, gettext("Styles"), map_size(rules)}]
  end

  # Asked of the resource rather than of a list of section names, so one that gains or loses a column
  # changes the window without anyone coming back here. A document being created has no record yet,
  # and the section it will be saved to answers the same question.
  defp holds_code?(section, record, key) do
    resource =
      case record do
        %resource{} -> resource
        _being_created -> Section.resource(Section.normalize(section))
      end

    not is_nil(Ash.Resource.Info.attribute(resource, key))
  end

  attr(:rules, :map, required: true)
  attr(:tree, :any, required: true)

  # Every element on this page that has CSS of its own, in one place — which nothing offered before:
  # an author who styled six elements had six panels to reopen to find out what they had written.
  defp style_rules(assigns) do
    assigns = assign(assigns, :rows, style_rows(assigns.tree, assigns.rules))

    ~H"""
    <div
      id="pb-source-styles"
      class={["min-h-0 flex-1 overflow-y-auto px-5 py-4", quiet_scroll(:light)]}
    >
      <p :if={@rows == []} class="text-[12px] font-medium text-[#6d6a63]">
        {gettext(
          "No element on this page has CSS of its own yet. Select one and open Custom CSS in the inspector to give it some."
        )}
      </p>

      <div class="flex flex-col gap-3">
        <section
          :for={{scope, body, node} <- @rows}
          id={"pb-style-rule-#{scope}"}
          class="overflow-hidden rounded-[12px] border border-[#ecebe6]"
        >
          <header class="flex items-center gap-2 border-b border-[#ecebe6] bg-[#faf9f6] px-3.5 py-2.5">
            <span class="font-['Space_Grotesk'] text-[11.5px] font-bold text-[#17161a]">
              {(node && Node.label(node)) || gettext("a deleted element")}
            </span>
            <code class="rounded-[5px] bg-[#f2f1fc] px-1.5 py-0.5 font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc]">
              .{scope}
            </code>
            <span class="flex-1"></span>
            <%!-- A rule whose element is gone is shown rather than hidden: it is still being served,
                  and saying so is the only warning before the save that prunes it. --%>
            <span :if={!node} class="text-[10.5px] font-semibold text-[#c0473d]">
              {gettext("gone — saving drops this rule")}
            </span>
            <button
              :if={node}
              type="button"
              id={"pb-style-rule-go-#{scope}"}
              phx-click="select_from_code"
              phx-value-id={node.id}
              class="flex-none rounded-[7px] border border-[#dcdbf5] bg-white px-2 py-1 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#f2f1fc]"
            >
              {gettext("Select it")}
            </button>
          </header>
          <pre
            phx-no-curly-interpolation
            class="overflow-x-auto bg-[#17161a] px-3.5 py-3 font-['Space_Grotesk'] text-[11.5px] leading-[1.7] text-[#c9c7d1] [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
          ><%= body %></pre>
        </section>
      </div>
    </div>
    """
  end

  # In document order rather than by scope, so the list reads the way the page does. A rule whose
  # element is no longer in the tree has nowhere to sort to and goes last, still shown.
  defp style_rows(nil, _rules), do: []

  defp style_rows(tree, rules) do
    placed =
      for node <- Tree.walk(tree),
          scope = Tree.scope(tree, node.id),
          body = rules[scope],
          do: {scope, body, node}

    seen = MapSet.new(placed, fn {scope, _body, _node} -> scope end)
    orphans = for {scope, body} <- rules, !MapSet.member?(seen, scope), do: {scope, body, nil}

    placed ++ Enum.sort(orphans)
  end

  attr(:record, :any, default: nil)
  attr(:source, :string, default: "")
  attr(:resource, :any, required: true)
  attr(:record_id, :string, default: nil)
  attr(:current_user, :any, default: nil)

  @doc false
  # A COMPONENT'S INTERFACE, WHICH THE BUILDER COULD NOT EDIT AT ALL.
  #
  # `attrs` and `slots` are columns on the component and they drive nearly everything the page
  # builder does with it — which controls the Inspector offers, what `.properties` and `.slots`
  # list, which properties are marked required, whether a drop into a slot is allowed. An author
  # could build the markup here and had to leave for the Components table form to say what the
  # markup takes.
  #
  # THE FORM IS THE RESOURCE'S OWN. `MishkaGervaz.Form.Web.Live` is a LiveComponent and this panel is
  # its sixth mount in this very file — the Snippet form, the Media upload, the new-document modal,
  # the folder modal and the review composer are the other five. The first version of this tab was
  # hand-rolled inputs beside a `field :attrs, :nested` the resource had declared all along, which is
  # two editors for one pair of columns and exactly the drift this codebase keeps paying for.
  #
  # `hidden_fields` is DERIVED rather than listed: every declared field except the two, read off the
  # form itself, so a field added to the resource tomorrow is hidden here without anyone remembering
  # to come back. Validation is the resource's too — see `Validations.InterfaceDeclaration`, which
  # refuses a declaration that will not compile whichever surface wrote it.
  defp interface_editor(assigns) do
    assigns =
      assigns
      |> assign(:attrs, Interface.attrs(assigns.record))
      |> assign(:slots, Interface.slots(assigns.record))
      |> then(&assign(&1, :missing, Interface.undeclared(&1.source, &1.attrs, &1.slots)))

    ~H"""
    <div class={["min-h-0 flex-1 overflow-y-auto px-5 py-4", quiet_scroll(:light)]}>
      <%!-- WHAT THE MARKUP ALREADY ASKS FOR, and the one thing here that is not a field. A template
            reading `@size` with no `attr :size` compiles and then raises `KeyError` the first time
            the component renders on somebody's page. It is ADVICE — half-finished work has to be
            storable, so this never refuses a save — which is why it sits above the form rather than
            inside it, and why each one is a button that writes the declaration rather than a
            sentence saying you should. --%>
      <section
        :if={@missing.attrs != [] or @missing.slots != []}
        id="pb-interface-missing"
        class="mb-4 rounded-[12px] border border-[#f0dcd8] bg-[#fdf3f1] px-3.5 py-3"
      >
        <div class="mb-2 text-[11.5px] font-bold text-[#c0473d]">
          {gettext("Your template reads these and the component does not declare them")}
        </div>
        <p class="mb-2.5 text-[11px] font-medium text-[#8a877f]">
          {gettext("Undeclared, each one raises the first time this component renders on a page.")}
        </p>
        <div class="flex flex-wrap gap-1.5">
          <button
            :for={name <- @missing.attrs}
            type="button"
            id={"pb-interface-declare-attr-#{name}"}
            phx-click="declare_missing"
            phx-value-kind="attr"
            phx-value-name={name}
            class="rounded-[8px] border border-[#f0dcd8] bg-white px-2.5 py-1.5 font-['Space_Grotesk'] text-[11.5px] font-bold text-[#c0473d] hover:border-[#c0473d]"
          >
            {gettext("+ attr @%{name}", name: name)}
          </button>
          <button
            :for={name <- @missing.slots}
            type="button"
            id={"pb-interface-declare-slot-#{name}"}
            phx-click="declare_missing"
            phx-value-kind="slot"
            phx-value-name={name}
            class="rounded-[8px] border border-[#f0dcd8] bg-white px-2.5 py-1.5 font-['Space_Grotesk'] text-[11.5px] font-bold text-[#c0473d] hover:border-[#c0473d]"
          >
            {gettext("+ slot :%{name}", name: name)}
          </button>
        </div>
      </section>

      <p class="mb-3 text-[11px] font-medium text-[#8a877f]">
        {gettext(
          "What a page can set on this component, and where content goes. Saved to the component itself — every page using it reads this."
        )}
      </p>

      <.live_component
        module={MishkaGervaz.Form.Web.Live}
        id="pb-interface-form"
        resource={@resource}
        record_id={@record_id}
        current_user={@current_user}
        hidden_fields={interface_hidden_fields(@resource)}
      />
    </div>
    """
  end

  @doc """
  Every field of a resource's form except the two that ARE the interface.

  Public because it is the whole contract between this panel and the resource, and a test that reads
  a hidden-field list from the markup is testing Gervaz rather than the decision made here.

  Asked of the form rather than listed: a list would be a second place to remember when the resource
  grows a column, and the one that forgets is this one.
  """
  @spec interface_hidden_fields(module()) :: [atom()]
  def interface_hidden_fields(resource) do
    resource
    |> MishkaGervaz.Resource.Info.Form.fields()
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in [:attrs, :slots]))
  end

  # The Handlers tab lists every form on the page, from the working tree.
  defp page_handler_forms(:events, %Tree{} = tree, entries, retagged),
    do: PageForms.handler_forms(tree, pending_entries(entries, tree, retagged))

  defp page_handler_forms(_tab, _tree, _entries, _retagged), do: []

  # The Handlers tab's entries under the names a Save stores them by (`PageForms.follow/3`).
  defp pending_entries(entries, tree, retagged),
    do: PageForms.follow(entries, PageForms.events(tree), retagged)

  attr(:forms, :list, required: true)
  attr(:focus, :any, default: nil)

  # Each form's On change and On submit, Automatic or Custom. Customize submits the code form, so
  # what was typed is kept, and adds the default code as a new entry.
  defp form_handlers(assigns) do
    ~H"""
    <section
      id="pb-form-handlers"
      class="mb-4 rounded-[12px] border border-[#ecebe6] bg-[#faf9f6] px-4 py-3"
    >
      <h3 class="mb-2 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
        {gettext("Forms on this page")}
      </h3>
      <div class="flex flex-col gap-2.5">
        <div
          :for={form <- @forms}
          id={"pb-form-handlers-#{form.node_id}"}
          data-focus={@focus == {:form, form.node_id}}
          phx-mounted={@focus == {:form, form.node_id} && JS.focus_first()}
        >
          <div class="mb-1 text-[12px] font-bold text-[#17161a]">{form.name}</div>
          <div
            :for={row <- form.handlers}
            id={"pb-form-handler-#{row.event}"}
            data-custom={to_string(row.custom?)}
            class="flex items-center gap-2.5 py-0.5 pl-2"
          >
            <span class="w-[74px] flex-none text-[11px] font-semibold text-[#6d6a63]">
              {handler_kind(row.kind)}
            </span>
            <code class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-bold text-[#3a382f]">
              {row.event}
            </code>
            <span class={[
              "flex-none rounded-full px-2 py-[1px] text-[10px] font-bold",
              (row.custom? && "bg-[#f2f1fc] text-[#4f4bcc]") || "bg-[#e6f6ee] text-[#177a53]"
            ]}>
              {handler_state(row.custom?)}
            </span>
            <button
              :if={!row.custom?}
              type="submit"
              id={"pb-form-customize-#{row.event}"}
              name="customize"
              value={row.event}
              class="flex-none rounded-[8px] border border-[#ecebe6] bg-white px-2.5 py-1 text-[11px] font-bold text-[#4f4bcc] hover:border-[#c3c1f0]"
            >
              {gettext("Customize")}
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp handler_kind(:validate), do: gettext("On change")
  defp handler_kind(:submit), do: gettext("On submit")

  defp handler_state(true), do: gettext("Custom")
  defp handler_state(false), do: gettext("Automatic")

  attr(:tab, :atom, required: true)
  attr(:entries, :list, required: true)
  attr(:fault, :any, default: nil)
  attr(:lifecycle, :boolean, default: false)
  attr(:shared, :boolean, default: false)

  attr(:forms, :list,
    default: [],
    doc: "the page's forms and their handlers, on the Handlers tab"
  )

  attr(:focus, :any, default: nil, doc: "`{:entry, index}` or `{:form, node_id}` to focus")

  # THE WRAPPER IS SHOWN AND NOT EDITABLE. The compiler splices what is typed here into
  # `def handle_event(name, params, socket) do … end`, so an author who writes the whole clause gets
  # a definition inside a definition and a page that will not compile — which is exactly what the
  # project's own API fixture did for years. Showing the two lines they are writing between is the
  # cheapest way to never have that conversation.
  defp code_entries(assigns) do
    ~H"""
    <form
      id="pb-code-form"
      phx-auto-recover="ignore"
      phx-submit="save_code"
      class="flex min-h-0 flex-1 flex-col"
    >
      <input type="hidden" name="tab" value={@tab} />

      <div class={["min-h-0 flex-1 overflow-y-auto px-5 py-4", quiet_scroll(:light)]}>
        <%!-- A LIVE COMPONENT'S LIFECYCLE IS WRITTEN HERE, and nothing said so. Its `mount/1`,
              `update/2` and `handle_event/3` ride the same `helpers` array as any other function —
              which is right, because that is the one place a `~H` fragment is also fed to the
              Tailwind scanner — but an author reading "a function the template can call" has no way
              to know that naming one `handle_event` is how their component answers a click. --%>
        <div
          :if={@lifecycle}
          data-role="pb-lifecycle-note"
          class="mb-3 rounded-[12px] border border-[#dcdbf5] bg-[#f6f5ff] px-4 py-3"
        >
          <div class="mb-1.5 flex items-center gap-1.5 text-[11.5px] font-bold text-[#4f4bcc]">
            <.icon name={:bolt} size={11} /> {gettext("This one keeps state")}
          </div>
          <p class="text-[11px] font-medium leading-[1.55] text-[#5c5a54]">
            <.sentence
              text={
                gettext_noop(
                  "Three names are its lifecycle rather than ordinary helpers. %{mount} starts its state, %{update} runs whenever the page passes it something, and %{handle_event} answers its own controls — the ones whose %{target} is %{myself}. Anything else here is a plain function the template can call."
                )
              }
              parts={
                %{
                  mount: {"code", nil, "mount(socket)"},
                  update: {"code", nil, "update(assigns, socket)"},
                  handle_event: {"code", nil, "handle_event(name, params, socket)"},
                  target: {"code", nil, "phx-target"},
                  myself: {"code", nil, "{@myself}"}
                }
              }
            />
          </p>
          <%!-- AND HOW FAR IT REACHES. A component's handler runs in whatever LiveView renders it,
                so a site-less one is one row executing inside every tenant's page process.
                Nothing can scope where shared code runs — that is what shared means — so the one
                place left to say it is where the code is written. --%>
          <p
            :if={@shared}
            data-role="pb-lifecycle-shared"
            class="mt-1.5 text-[11px] font-bold leading-[1.55] text-[#6d4fc0]"
          >
            {gettext("Shared with every site — this code runs on every site that places it.")}
          </p>
        </div>

        <.form_handlers :if={@forms != []} forms={@forms} focus={@focus} />

        <div class="flex flex-col gap-3">
          <section
            :for={{entry, index} <- Enum.with_index(@entries)}
            id={"pb-code-entry-#{@tab}-#{index}"}
            data-focus={@focus == {:entry, index}}
            class={[
              "overflow-hidden rounded-[12px] border bg-white",
              (fault_here?(@fault, @tab, index) && "border-[#f0dcd8]") || "border-[#ecebe6]"
            ]}
          >
            <div class="flex items-center gap-2 border-b border-[#f4f3ee] bg-[#faf9f6] px-3.5 py-2.5">
              <input
                type="text"
                name={"entry[#{index}][name]"}
                value={entry["name"]}
                placeholder={name_placeholder(@tab)}
                spellcheck="false"
                class="h-8 min-w-0 flex-1 rounded-[8px] border border-[#ecebe6] bg-white px-2.5 font-['Space_Grotesk'] text-[12px] font-bold text-[#17161a] outline-none focus:border-[#c3c1f0]"
              />
              <input
                :if={@tab == :helpers}
                type="text"
                name={"entry[#{index}][args]"}
                value={entry["args"]}
                placeholder="name, size"
                spellcheck="false"
                class="h-8 w-[180px] flex-none rounded-[8px] border border-[#ecebe6] bg-white px-2.5 font-['Space_Grotesk'] text-[12px] text-[#3a382f] outline-none focus:border-[#c3c1f0]"
              />
              <%!-- ONE BADGE, BESIDE THE CODE IT IS ABOUT. Read off the parsed snippet, so a mention
                    in a comment or inside a string does not raise it — see
                    `MishkaCmsCore.Runtime.PageBuilder.CodeFlags`. It says "read this one first" and
                    never "the rest are fine": anything it matches can be spelled another way. --%>
              <span
                :if={CodeFlags.badge(entry["code"])}
                id={"pb-code-flag-#{@tab}-#{index}"}
                title={
                  gettext("This calls something worth reading twice. It is a hint, not a verdict.")
                }
                class="flex-none rounded-[6px] bg-[#fdf3f1] px-2 py-1 text-[10.5px] font-bold text-[#c0473d]"
              >
                {CodeFlags.badge(entry["code"])}
              </span>
              <button
                type="button"
                id={"pb-code-remove-#{@tab}-#{index}"}
                phx-click="remove_code"
                phx-value-tab={@tab}
                phx-value-index={index}
                title={gettext("Remove")}
                class="grid size-8 flex-none place-items-center rounded-[8px] border border-[#ecebe6] text-[#6d6a63] hover:border-[#f0dcd8] hover:text-[#c0473d]"
              >
                <.icon name={:trash} size={13} />
              </button>
            </div>

            <div class="bg-[#17161a] px-4 pt-3">
              <span class="font-['Space_Grotesk'] text-[11.5px] text-[#a3a1ad]">
                {wrapper_head(@tab, entry)}
              </span>
            </div>
            <div
              id={"pb-code-editor-#{@tab}-#{index}-#{:erlang.phash2(entry["code"])}"}
              phx-hook="PbCodeEditor"
              phx-update="ignore"
              data-focus={@focus == {:entry, index}}
              data-language="elixir"
              data-accent-panel
              class={[
                "w-full resize-y overflow-hidden bg-[#17161a] px-4 pl-8 [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]",
                (@tab == :state && "min-h-[3.5rem]") || "min-h-[9rem]"
              ]}
            >
              <textarea
                name={"entry[#{index}][code]"}
                spellcheck="false"
                rows={(@tab == :state && "2") || "6"}
                class="w-full resize-none border-0 bg-transparent py-1 font-['Space_Grotesk'] text-[12.5px] leading-[1.7] text-[#c9c7d1] outline-none"
              >{entry["code"]}</textarea>
            </div>
            <%!-- A state value is one expression, not a function: there is no block to close. --%>
            <div class="bg-[#17161a] px-4 pb-3">
              <span
                :if={@tab != :state}
                class="font-['Space_Grotesk'] text-[11.5px] text-[#a3a1ad]"
              >
                end
              </span>
            </div>

            <p
              :if={fault_here?(@fault, @tab, index)}
              class="border-t border-[#f0dcd8] bg-[#fdf3f1] px-3.5 py-2 text-[11.5px] font-semibold text-[#c0473d]"
            >
              {@fault.message}
            </p>
          </section>

          <p
            :if={@entries == []}
            class="rounded-[12px] border border-dashed border-[#d9d7d0] px-4 py-8 text-center text-[12px] font-medium text-[#8a877f]"
          >
            {empty_note(@tab, @forms)}
          </p>

          <button
            type="button"
            id={"pb-code-add-#{@tab}"}
            phx-click="add_code"
            phx-value-tab={@tab}
            class="self-start rounded-[9px] border border-[#ecebe6] bg-white px-3 py-2 text-[12px] font-bold text-[#4f4bcc] hover:border-[#c3c1f0]"
          >
            {add_label(@tab)}
          </button>
        </div>
      </div>

      <footer class="flex items-center gap-2 border-t border-[#ecebe6] px-5 py-3.5">
        <span class="min-w-0 flex-1 text-[11px] font-medium text-[#8a877f]">
          {scope_note(@tab)}
        </span>
        <button
          type="button"
          phx-click="close_source"
          class="flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3.5 py-2 text-[12px] font-bold text-[#5c5a54]"
        >
          {gettext("Cancel")}
        </button>
        <button
          type="submit"
          id="pb-code-save"
          class="flex-none rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white hover:bg-[#2a282f]"
        >
          {gettext("Save")}
        </button>
      </footer>
    </form>
    """
  end

  attr(:node, :any, required: true)
  attr(:entry, :any, default: nil)
  attr(:state, :any, required: true)
  attr(:aimed, :string, default: nil, doc: "the scope class the saved action points at")

  attr(:opener, :map,
    default: %{},
    doc:
      "what the target being aimed at says it can do — see `MishkaCmsCore.Builder.PaletteEntry.opens/1`"
  )

  attr(:aiming, :string,
    default: nil,
    doc: "the node id picked in the target select but not saved yet, which outranks `aimed`"
  )

  attr(:openable, :list,
    default: [],
    doc: "the nodes in this document that hide their own content — see `openable/1`"
  )

  attr(:acting, :string,
    default: nil,
    doc: "the verb picked in the action select but not saved yet, which outranks the saved one"
  )

  @doc """
  What this element does when it is clicked, without anyone writing JavaScript.

  Sits under Custom CSS because the two are one idea: toggle `is-open` here, write `&.is-open { … }`
  there, and that is an accordion with no code in it. See
  `MishkaCmsCore.Runtime.PageBuilder.Interactions` for why a `<script>` is the wrong shape under
  LiveView.
  """
  def interactions(assigns) do
    assigns =
      assigns
      |> assign(:targetable?, targetable?(assigns.node, assigns.entry))
      |> then(&assign(&1, :verb, &1.acting || action_of(&1.state) || ""))
      |> then(&assign(&1, :fields, Interactions.needs(&1.verb)))
      |> then(&assign(&1, :hint, hint(&1.verb)))

    ~H"""
    <section :if={@node.kind in [:tag, :component] and @targetable?}>
      <button
        type="button"
        id="pb-act-toggle"
        phx-click={
          JS.toggle(to: "#pb-act-body", display: "flex")
          |> JS.toggle_class("rotate-90", to: "#pb-act-toggle > svg")
        }
        class="flex w-full items-center gap-2 rounded-[9px] px-1 py-1.5 text-left hover:bg-[#f6f5f2]"
      >
        <.icon name={:chevron} size={11} />
        <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("On click")}
        </span>
        <span class="flex-1"></span>
        <span
          :if={@state != :none}
          class="size-[6px] flex-none rounded-full bg-[#8580d8]"
          title={gettext("This element does something when clicked")}
        ></span>
      </button>

      <div id="pb-act-body" class="mt-1.5 hidden flex-col gap-2">
        <p
          :if={@state == :custom}
          id="pb-act-custom"
          class="rounded-[9px] bg-[#faf9f6] px-2.5 py-2 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]"
        >
          <.sentence
            text={
              gettext_noop(
                "This element already has a hand-written %{attribute}. It is left exactly as it is — edit it in Advanced."
              )
            }
            parts={%{attribute: {"code", nil, "phx-click"}}}
          />
        </p>

        <form
          :if={@state != :custom}
          id={"pb-act-form-#{@node.id}"}
          phx-auto-recover="ignore"
          phx-submit="save_interaction"
          class="flex flex-col gap-1.5"
        >
          <input type="hidden" name="node_id" value={@node.id} />

          <%!-- WHAT IT ACTS ON. Every interaction before this one landed on the element being
                clicked, which is right for "toggle a class on myself" and leaves out the commonest
                thing anybody wants a button for: opening something else. A modal, a drawer and
                twelve more render their own content closed, so "Show" pointed at one is the whole
                of "open that dialog" — and the list is the document's own concealing nodes rather
                than a free-text selector, so a click still cannot reach outside the page. --%>
          <div :if={@openable != []} class="relative">
            <select
              id="pb-act-target"
              name="target"
              phx-change="aim_interaction"
              class="h-[30px] w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[11.5px] font-semibold text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
            >
              <%!-- THE AUTHOR'S CHOICE OUTRANKS THE SAVED ONE, because picking a target re-renders this
                    list — the verbs a click can honour depend on what it points at — and a `selected`
                    computed only from what is in the document put the select straight back to "This
                    element" underneath them. Applying then wrote a command aimed at the button. --%>
              <option value="" selected={@aiming == ""}>{gettext("This element")}</option>
              <option
                :for={{id, label, scope} <- @openable}
                value={id}
                selected={
                  (@aiming && id == @aiming) ||
                    (is_nil(@aiming) and scope != nil and scope == @aimed)
                }
              >
                {label}
              </option>
            </select>
            <.select_chevron />
          </div>

          <div class="relative">
            <select
              id="pb-act-action"
              name="action"
              phx-change="pick_interaction"
              class="h-[30px] w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[11.5px] font-semibold text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
            >
              <option value="">{gettext("Nothing")}</option>
              <option
                :for={{value, label} <- interaction_actions(@opener)}
                value={value}
                selected={value == @verb}
              >
                {translate(label)}
              </option>
            </select>
            <.select_chevron />
          </div>

          <%!-- WHATEVER THE CHOSEN VERB ASKS FOR, AND NOTHING ELSE. The class box used to be drawn
                for all six verbs and does nothing for three of them, which left an author to work
                out on their own that typing in it changed nothing. It is also what keeps a package
                out of this file: an action says it wants a line of text called `message` and the
                box appears here, labelled, remembered and read back. See
                `MishkaCmsCore.Builder.Action`. --%>
          <div :for={field <- @fields} class="flex flex-col gap-1">
            <label
              for={"pb-act-#{field.name}"}
              class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8a877f]"
            >
              {translate(field.label)}
            </label>

            <input
              :if={field.type == :text}
              type="text"
              id={"pb-act-#{field.name}"}
              name={field.name}
              value={typed(@state, @verb, field)}
              placeholder={translate(field.placeholder)}
              maxlength="240"
              spellcheck="false"
              class="h-[30px] w-full rounded-[8px] border border-[#ecebe6] bg-white px-2 text-[11.5px] text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
            />

            <div :if={field.type == :select} class="relative">
              <select
                id={"pb-act-#{field.name}"}
                name={field.name}
                class="h-[30px] w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[11.5px] font-semibold text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
              >
                <option
                  :for={{value, label} <- field.options}
                  value={value}
                  selected={value == typed(@state, @verb, field)}
                >
                  {translate(label)}
                </option>
              </select>
              <.select_chevron />
            </div>
          </div>

          <%!-- The action's own words, so core does not hold a note about somebody else's verb. --%>
          <p :if={@hint} class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
            {translate(@hint)}
          </p>

          <button
            type="submit"
            id="pb-act-save"
            class="w-full rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] py-2 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            {gettext("Apply")}
          </button>
        </form>
      </div>
    </section>
    """
  end

  attr(:node, :any, required: true)
  attr(:state, :any, required: true)

  @doc """
  When this element is on the page at all — HEEx's own `:if`, chosen from a list.

  Sits above On click because it is the earlier question: whether the element is there, then what it
  does. See `MishkaCmsCore.Runtime.PageBuilder.Conditions` for what each choice writes.
  """
  def conditions(assigns) do
    ~H"""
    <section>
      <button
        type="button"
        id="pb-when-toggle"
        phx-click={
          JS.toggle(to: "#pb-when-body", display: "flex")
          |> JS.toggle_class("rotate-90", to: "#pb-when-toggle > svg")
        }
        class="flex w-full items-center gap-2 rounded-[9px] px-1 py-1.5 text-left hover:bg-[#f6f5f2]"
      >
        <.icon name={:chevron} size={11} />
        <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("Show when")}
        </span>
        <span class="flex-1"></span>
        <span
          :if={@state != :none}
          class="size-[6px] flex-none rounded-full bg-[#8580d8]"
          title={gettext("This element is only on the page sometimes")}
        ></span>
      </button>

      <div id="pb-when-body" class="mt-1.5 hidden flex-col gap-2">
        <p
          :if={@state == :custom}
          id="pb-when-custom"
          class="rounded-[9px] bg-[#faf9f6] px-2.5 py-2 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]"
        >
          <.sentence
            text={
              gettext_noop(
                "This element already has a hand-written %{attribute}. It is left exactly as it is — edit it in Advanced."
              )
            }
            parts={%{attribute: {"code", nil, ":if"}}}
          />
        </p>

        <form
          :if={@state != :custom}
          id={"pb-when-form-#{@node.id}"}
          phx-change="save_condition"
          class="flex flex-col gap-1.5"
        >
          <input type="hidden" name="node_id" value={@node.id} />

          <div class="relative">
            <select
              id="pb-when-rule"
              name="rule"
              class="h-[30px] w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[11.5px] font-semibold text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
            >
              <option value="" selected={@state == :none}>{gettext("Always")}</option>
              <option
                :for={{value, label} <- Conditions.rules()}
                value={value}
                selected={condition?(@state, value)}
              >
                {translate(label)}
              </option>
            </select>
            <.select_chevron />
          </div>

          <p class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
            {gettext(
              "The canvas always draws it, so it stays editable. The published page is where the condition decides."
            )}
          </p>
        </form>
      </div>
    </section>
    """
  end

  defp condition?({:ok, rule}, value), do: rule == value
  defp condition?(_state, _value), do: false

  attr(:node, :any, required: true)
  attr(:entry, :any, default: nil)
  attr(:hooks, :list, default: [])
  attr(:attached, :any, default: nil)

  @doc """
  Attaches this element to a runtime JS hook.

  A picker, not a code box. Writing a hook stays on Runtime → JS hooks, which is the right amount of
  friction for shipping executable JavaScript; this only selects from what is already compiled into
  the site's bundle, and saves someone hand-typing `phx-hook` into Advanced and getting the
  capitalisation wrong. See `MishkaCmsCore.Runtime.PageBuilder.Hooks`.
  """
  def hook_picker(assigns) do
    assigns = assign(assigns, :targetable?, targetable?(assigns.node, assigns.entry))

    ~H"""
    <section :if={@node.kind in [:tag, :component] and @targetable?}>
      <button
        type="button"
        id="pb-hook-toggle"
        phx-click={
          JS.toggle(to: "#pb-hook-body", display: "flex")
          |> JS.toggle_class("rotate-90", to: "#pb-hook-toggle > svg")
        }
        class="flex w-full items-center gap-2 rounded-[9px] px-1 py-1.5 text-left hover:bg-[#f6f5f2]"
      >
        <.icon name={:chevron} size={11} />
        <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("JS hook")}
        </span>
        <span class="flex-1"></span>
        <span
          :if={@attached}
          class="size-[6px] flex-none rounded-full bg-[#8580d8]"
          title={gettext("This element is attached to a hook")}
        ></span>
      </button>

      <div id="pb-hook-body" class="mt-1.5 hidden flex-col gap-2">
        <p
          :if={@hooks == []}
          id="pb-hook-empty"
          class="rounded-[9px] bg-[#faf9f6] px-2.5 py-2 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]"
        >
          {gettext(
            "This site has no JS hooks yet. Write one under Runtime → JS hooks and it appears here."
          )}
        </p>

        <form
          :if={@hooks != []}
          id={"pb-hook-form-#{@node.id}"}
          phx-auto-recover="ignore"
          phx-submit="save_hook"
          class="flex flex-col gap-1.5"
        >
          <input type="hidden" name="node_id" value={@node.id} />

          <div class="relative">
            <select
              id="pb-hook-select"
              name="hook"
              class="h-[30px] w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[11.5px] font-semibold text-[#1b1a18] focus:border-[#c3c1f0] focus:outline-none"
            >
              <option value="">{gettext("None")}</option>
              <option :for={hook <- @hooks} value={hook.name} selected={hook.name == @attached}>
                {(hook.global? && gettext("%{hook} (global)", hook: hook.hook)) || hook.hook}
              </option>
            </select>
            <.select_chevron />
          </div>

          <p class="text-[10px] font-medium leading-[1.5] text-[#6d6a63]">
            {gettext("A hook needs a unique id, so one is given to this element if it has none.")}
          </p>

          <button
            type="submit"
            id="pb-hook-save"
            class="w-full rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] py-2 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            {gettext("Apply")}
          </button>
        </form>
      </div>
    </section>
    """
  end

  defp attached_hook(node) do
    case Node.attr(node, "phx-hook") do
      {:string, name} -> name
      _expression_or_none -> nil
    end
  end

  defp action_of({:ok, key, _values}), do: key
  defp action_of(_state), do: nil

  # WHAT THE AUTHOR TYPED, FOUND BY THE NAME OF THE BOX IT WAS TYPED INTO.
  #
  # Keyed on the VERB instead, switching "Toggle a class" to "Add a class" emptied the class box —
  # both declare a field called `class`, so the author's own word was there a moment ago and gone the
  # instant they changed their mind about the verb. Pressing Apply then refused the whole thing for
  # want of a class.
  #
  # The name is the identity, which also gives for free the thing the verb check was there for:
  # "Show a message" names its boxes `message` and `kind`, so switching to it finds no `class` and
  # starts empty.
  defp typed({:ok, _key, values}, _verb, field),
    do: Map.get(values, field.name) || fallback(field)

  defp typed(_state, _verb, field), do: fallback(field)

  defp fallback(%{type: :select, options: [{value, _label} | _rest]}), do: value
  defp fallback(_field), do: nil

  defp hint(key) do
    Enum.find_value(Interactions.registry(), fn action ->
      Descriptor.key(action) == key and Map.get(action, :description)
    end)
  end

  # A TAG ALWAYS CARRIES ITS CLASS. A component carries one only if it declares `class` and puts it
  # somewhere its markup renders — declaring it is the part that can be checked, and a component that
  # does not is unreachable by a rule keyed on a class.
  @doc """
  Every node in this document a click can be pointed AT, as `{id, label, scope}`.

  ## What earns a place here

  A DECLARATION, not a guess. `PaletteEntry.opens/1` — the component's own `data-pb-open` and its
  two siblings — and nothing else.

  It was `concealed?/1` before, which asks a different question: does this render its own content
  closed? That is the right question for the layers glyph, where a wrong yes costs a glyph on a row
  that did not need one. It is the wrong question here, where a wrong yes costs the author a control
  that saves a flash reading "Click action set." and then does nothing when the page is clicked.

  The five it removes are not oversights: `chelekom-tabs` and `chelekom-carousel` open one of MANY —
  "open this" is not a whole sentence for them without naming which — and `chelekom-stepper`,
  `chelekom-rating` and `chelekom-scroll-area` have no open state at all and were only ever caught
  by a markup scan being deliberately generous. Every one of the eleven that remain was verified to
  open from a button on a rendered page.

  A third-party component joins this list by saying so, in one attribute on its own root; see
  `MishkaCmsCore.Builder.PaletteEntry.opens/1`.

  `scope` is the node's `pb-xxxxxxxx` class WHEN IT ALREADY HAS ONE, which is only how a saved
  action is matched back to the row that wrote it. A node with none is still offered; the scope is
  minted when the interaction is saved, not before, so browsing the list changes nothing.
  """
  @spec openable(map()) :: [{String.t(), String.t(), String.t() | nil}]
  def openable(%{tree: tree} = editor) do
    entries = Map.new(editor.components || [], &{&1.name, &1})

    tree
    |> Tree.walk()
    |> Enum.filter(&opens?(&1, entries))
    |> Enum.map(&{&1.id, openable_label(&1), Tree.scope(tree, &1.id)})
  end

  def openable(_editor), do: []

  @doc """
  What the target currently being aimed at says it can do, as `%{verb => attribute}`.

  `chosen` is the id in the target select RIGHT NOW — which is not yet the saved one, because the
  author is picking it. Without that the verb list would describe the previous target and go stale
  the moment somebody changed their mind, which is the state a form is in for the whole time it is
  being filled in.

  Falls back to what the saved command points at, so a panel rendered fresh describes the aim the
  document already holds. `%{}` for "aimed at this element" and for a target that declares nothing —
  both mean "offer everything", which is what `Interactions.actions/1` does with it.
  """
  @spec aimed_opener(map(), String.t() | nil, Node.t() | nil) :: map()
  def aimed_opener(editor, chosen, selected) do
    case chosen || saved_aim(editor, selected) do
      id when is_binary(id) and id != "" -> opener_of(editor, id)
      _self_or_none -> %{}
    end
  end

  defp saved_aim(%{tree: tree}, %Node{} = selected) do
    case Interactions.target(Node.attr(selected, "phx-click")) do
      scope when is_binary(scope) ->
        tree |> Tree.walk() |> Enum.find_value(&(Tree.scope(tree, &1.id) == scope && &1.id))

      _none ->
        nil
    end
  end

  defp saved_aim(_editor, _selected), do: nil

  defp opener_of(%{tree: tree} = editor, id) do
    with %Node{} = node <- Tree.get(tree, id),
         name when is_binary(name) <- Node.component_name(node),
         %{} = entry <- Enum.find(editor.components || [], &(&1.name == name)) do
      Map.get(entry, :opens) || %{}
    else
      _undeclared -> %{}
    end
  end

  defp opener_of(_editor, _id), do: %{}

  defp opens?(%Node{kind: :component} = node, entries) do
    case Map.get(entries, Node.component_name(node)) do
      nil -> false
      entry -> (Map.get(entry, :opens) || %{}) != %{}
    end
  end

  defp opens?(_node, _entries), do: false

  # THE AUTHOR'S OWN WORDS FIRST. Two dialogs on one page are told apart by what they say, not by the
  # eight characters of their id — and a `title` is the attribute the kit's own dialogs carry.
  defp openable_label(%Node{} = node) do
    name = Node.component_name(node) || node.tag || "component"

    case Node.literal(node, "title") do
      title when is_binary(title) and title != "" -> "#{name} — #{title}"
      _untitled -> "#{name} · #{String.slice(node.id, 0, 5)}"
    end
  end

  @doc "Whether this row's component renders its own content closed — a dialog, a drawer, a dropdown."
  @spec overlay?(map() | nil) :: boolean()
  def overlay?(entry) when is_map(entry), do: Map.get(entry, :concealed?, false) == true
  def overlay?(_entry), do: false

  @doc "Whether this overlay is being held open on the canvas."
  @spec pinned?(map(), String.t()) :: boolean()
  defdelegate pinned?(editor, id), to: MishkaCmsCore.Runtime.PageBuilder.EditorSession

  defp targetable?(%Node{kind: :tag}, _entry), do: true

  defp targetable?(%Node{kind: :component}, entry) when not is_nil(entry),
    do: entry |> Inspector.attrs() |> Enum.any?(&(Inspector.name(&1) == "class"))

  defp targetable?(_node, _entry), do: false

  # WHICH KIT, AND WHICH VERSION OF IT. A note that says "the component's own markup" tells a reader
  # nothing they can act on; `chelekom 0.0.9` tells them exactly what they are betting on and what to
  # re-check when it moves. Read off the palette entry, which carries the label and deliberately not
  # the `extra` it came from. Falls back to the plain words for a component somebody wrote by hand
  # here, which belongs to no kit and has no version to name.
  defp kit_label(%{} = entry),
    do: PaletteEntry.optional(entry, :kit) || gettext("this component's own markup")

  defp kit_label(_entry), do: gettext("this component's own markup")

  defp wrapper_head(:events, entry),
    do: ~s|def handle_event("#{entry["name"]}", params, socket) do|

  defp wrapper_head(:infos, entry), do: "def handle_info(#{entry["name"]}, socket) do"

  defp wrapper_head(:state, entry), do: "@#{entry["name"]} ="

  defp wrapper_head(:helpers, entry),
    do: "def #{entry["name"]}(#{entry["args"]}) do"

  defp name_placeholder(:events), do: "save"
  defp name_placeholder(:infos), do: ":tick"
  defp name_placeholder(:state), do: "count"
  defp name_placeholder(:helpers), do: "money"

  defp add_label(:events), do: gettext("+ Handler")
  defp add_label(:infos), do: gettext("+ Message")
  defp add_label(:state), do: gettext("+ Value")
  defp add_label(:helpers), do: gettext("+ Helper")

  defp empty_note(:events, [_form | _more]),
    do: gettext("No custom handlers. The forms above run on their own.")

  defp empty_note(tab, _forms), do: empty_note(tab)

  defp empty_note(:events),
    do: gettext("No handlers yet. One answers a phx-click, a form submit or a key press.")

  defp empty_note(:infos),
    do:
      gettext(
        "No messages yet. One answers something the server sends this page — a tick, a broadcast."
      )

  defp empty_note(:helpers),
    do: gettext("No helpers yet. One is a function the template can call.")

  defp empty_note(:state),
    do:
      gettext(
        "No state yet. Each value is an assign the page starts with, so @count is there from the first render."
      )

  # Whether the record being edited compiles to a `Phoenix.LiveComponent` — read off the row rather
  # than the compiled module, because the editor is looking at what will be saved rather than at
  # what was last built.
  defp live_record?(%{stateful: true}), do: true
  defp live_record?(_record), do: false

  defp scope_note(:helpers),
    do: gettext("Helpers belong to this page and its template can call them.")

  defp scope_note(:state),
    do:
      gettext(
        "Worked out for each visitor when the page opens. A handler changes a value with assign(socket, :count, 1)."
      )

  defp scope_note(_tab), do: gettext("Code is written on its own, not with the document.")

  defp fault_here?(%{tab: tab, index: index}, tab, index) when is_integer(index), do: true
  defp fault_here?(_fault, _tab, _index), do: false

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
          <button
            type="button"
            id="pb-reload-save"
            phx-click="save_and_reload"
            class="h-8 flex-none rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            {gettext("Save draft first")}
          </button>
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
            id="pb-leave-save"
            phx-click="draft_and_leave"
            class="flex w-full items-start gap-3 rounded-[11px] border border-[#dcdbf5] bg-[#f7f6fd] p-3 text-left hover:bg-[#f2f1fc]"
          >
            <span class="grid size-7 flex-none place-items-center rounded-[9px] bg-[#e4e2f7] text-[#4f4bcc]">
              <.icon name={:draft} size={14} />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block text-[12.5px] font-bold text-[#2e2b6b]">{gettext(
                "Keep it as a draft"
              )}</span>
              <span class="mt-0.5 block text-[11px] font-medium leading-[1.5] text-[#6d6a63]">
                {gettext(
                  "Saved under this sitting's name. Visitors see nothing until you publish it."
                )}
              </span>
            </span>
          </button>

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

  @doc """
  The examples modal: every variant the kit ships for a component, its source, and one button that
  inserts the whole parsed subtree.

  The kit carries roughly 3,000 of these. The old editor rendered twelve per component to build the
  palette, used one, and dropped every attribute on insert; here nothing is pre-rendered and the
  example arrives intact.
  """
  def examples_modal(assigns) do
    assigns =
      assigns
      |> assign(:example, Enum.at(assigns.entry.examples, assigns.example_index))
      |> assign(:docs_url, docs_url(assigns.entry))
      |> assign(:wizard?, Wizard.offers?(assigns.entry))
      |> assign_new(:preset?, fn -> false end)
      |> assign_new(:components, fn -> [] end)

    ~H"""
    <div
      id="pb-examples"
      class="fixed inset-0 z-[90] flex items-center justify-center bg-[#17161a]/[.42] px-5 py-[5vh]"
      phx-mounted={modal_in("#pb-examples > section")}
      phx-remove={modal_out("#pb-examples > section")}
      phx-window-keydown="close_examples"
      phx-key="escape"
    >
      <%!-- A HEIGHT, not a maximum. With only `max-h` the modal was as tall as its content, so the
            two tabs opened at different sizes: Examples listed six variants and filled the screen,
            the Wizard listed three option rows and shrank to a strip with the preview squeezed into
            what was left — the same component previewed at a third of the size depending on which
            tab you were on. Fixed height, capped so it does not tower on a large monitor. --%>
      <section
        phx-click-away="close_examples"
        class="flex h-[min(88vh,760px)] w-full max-w-[900px] flex-col overflow-hidden rounded-[18px] bg-white shadow-[0_30px_80px_rgba(20,18,26,.4)]"
      >
        <%!-- THE TITLE KEEPS ITS ROW. Docs and the tabs drop beneath it when both do not fit, and
              the close button stays top-right, centred on the title's two lines. --%>
        <header
          data-role="modal-head"
          class="flex flex-none items-start gap-2 border-b border-[#f0efea] px-5 py-3.5"
        >
          <div class="flex min-w-0 flex-1 flex-wrap items-center justify-between gap-2">
            <div data-role="modal-head-title" class="min-w-0 flex-auto">
              <h2 class="truncate font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]">
                {@entry.name}
              </h2>
              <p class="mt-0.5 text-[10.5px] font-medium text-[#6d6a63]">
                {(@example_tab == :wizard && gettext("Choose its options — the preview renders live")) ||
                  gettext("Pick an example — the preview renders live")}
              </p>
            </div>

            <div
              :if={@docs_url || @wizard?}
              data-role="modal-head-actions"
              class="flex flex-wrap items-center gap-2"
            >
              <a
                :if={@docs_url}
                id="pb-example-docs"
                href={@docs_url}
                target="_blank"
                rel="noopener noreferrer"
                title={gettext("Open this component's documentation")}
                class="inline-flex h-[26px] flex-none items-center gap-1.5 rounded-[8px] border border-[#ecebe6] bg-white px-2.5 text-[10.5px] font-bold text-[#6d6a63] hover:border-[#dcdbf5] hover:text-[#4f4bcc]"
              >
                {gettext("Docs")} <.icon name={:external} size={11} />
              </a>

              <%!-- Two ways to get the same component onto the page: one the kit already wrote, or one
                    built from its own options. They share the preview, the code pane and Insert. --%>
              <div :if={@wizard?} class="flex flex-none rounded-[9px] bg-[#f2f1ec] p-0.5">
                <button
                  type="button"
                  id="pb-example-tab-wizard"
                  phx-click="example_tab"
                  phx-value-tab="wizard"
                  class={[
                    "inline-flex h-[26px] items-center gap-1.5 rounded-[7px] px-[11px] text-[11px] font-bold",
                    (@example_tab == :wizard &&
                       "bg-white text-[#4f4bcc] shadow-[0_1px_2px_rgba(30,28,24,.12)]") ||
                      "text-[#6d6a63]"
                  ]}
                >
                  <.icon name={:sparkle} size={12} /> {gettext("Wizard")}
                </button>
                <button
                  type="button"
                  id="pb-example-tab-examples"
                  phx-click="example_tab"
                  phx-value-tab="examples"
                  class={[
                    "h-[26px] rounded-[7px] px-[11px] text-[11px] font-bold",
                    (@example_tab == :examples &&
                       "bg-white text-[#4f4bcc] shadow-[0_1px_2px_rgba(30,28,24,.12)]") ||
                      "text-[#6d6a63]"
                  ]}
                >
                  {gettext("Examples")}
                </button>
              </div>
            </div>
          </div>

          <button
            type="button"
            phx-click="close_examples"
            title={gettext("Close")}
            class="mt-[4.75px] grid size-[30px] flex-none place-items-center rounded-[9px] text-[#6d6a63] hover:bg-[#f6f5f2] hover:text-[#1b1a18]"
          >
            <.icon name={:close} size={16} />
          </button>
        </header>

        <%!-- ONE COLUMN on a phone. A 266px picker beside a preview leaves under 100px for the
              preview on a 375px screen, which is narrower than the phone frame the device toggle
              renders into. Stacked, the picker takes a third and the preview keeps the rest. --%>
        <div class="grid min-h-0 flex-1 grid-cols-[266px_minmax(0,1fr)] max-[720px]:grid-cols-1! max-[720px]:grid-rows-[minmax(0,34%)_minmax(0,1fr)]!">
          <%!-- Every variant the kit ships, named and described. Choosing one only changes what the
                preview renders — nothing is inserted until Insert is pressed. --%>
          <div
            :if={@example_tab == :wizard}
            class="flex min-h-0 flex-col gap-3 overflow-y-auto border-r border-[#f0efea] p-3 [scrollbar-width:none] max-[720px]:border-r-0! max-[720px]:border-b! [&::-webkit-scrollbar]:hidden"
          >
            <div :for={axis <- Wizard.axes(@entry)}>
              <span class="mb-1.5 flex items-center gap-1.5">
                <span class="min-w-0 flex-1 truncate text-[10.5px] font-bold text-[#3a382f]">
                  {axis.label}
                </span>
                <span
                  :if={@wizard[axis.name] not in [nil, ""]}
                  class="flex-none font-['Space_Grotesk'] text-[9.5px] font-medium text-[#a8a5a0]"
                >
                  {@wizard[axis.name]}
                </span>
              </span>

              <%!-- The panel's own rule: a short list reads as pills, a long one as a dropdown. --%>
              <div :if={length(axis.values) <= 5} class="flex flex-wrap gap-1">
                <button
                  :for={value <- axis.values}
                  type="button"
                  id={"pb-wizard-#{axis.name}-#{value}"}
                  phx-click="wizard_pick"
                  phx-value-name={axis.name}
                  value={value}
                  class={[
                    "h-[26px] flex-none rounded-[7px] border px-2.5 text-[10.5px] font-semibold",
                    (@wizard[axis.name] == value && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
                      "border-[#ecebe6] bg-white text-[#6d6a63] hover:border-[#dcdbf5]"
                  ]}
                >
                  {value}
                </button>
              </div>

              <form
                :if={length(axis.values) > 5}
                id={"pb-wizard-form-#{axis.name}"}
                phx-change="wizard_pick"
                phx-submit="wizard_pick"
              >
                <input type="hidden" name="name" value={axis.name} />
                <div class="relative">
                  <select
                    id={"pb-wizard-select-#{axis.name}"}
                    name="value"
                    class="h-8 w-full cursor-pointer appearance-none rounded-[8px] border border-[#ecebe6] bg-white ps-2 pe-8 text-[11.5px] font-medium text-[#3a382f]"
                  >
                    <option value="">
                      {(axis.default && gettext("%{value} (default)", value: axis.default)) ||
                        gettext("— default —")}
                    </option>
                    <option
                      :for={value <- axis.values}
                      value={value}
                      selected={@wizard[axis.name] == value}
                    >
                      {value}
                    </option>
                  </select>
                  <.select_chevron />
                </div>
              </form>
            </div>

            <button
              type="button"
              id="pb-wizard-reset"
              phx-click="wizard_reset"
              disabled={@wizard == %{}}
              class="mt-1 h-[28px] flex-none rounded-[8px] border border-[#ecebe6] bg-white text-[10.5px] font-semibold text-[#6d6a63] hover:bg-[#f6f5f2] disabled:cursor-not-allowed disabled:text-[#c9c7c1]"
            >
              {gettext("Back to the defaults")}
            </button>
          </div>

          <div
            :if={@example_tab == :examples}
            class="flex min-h-0 flex-col gap-1.5 overflow-y-auto border-r border-[#f0efea] p-3 [scrollbar-width:none] max-[720px]:border-r-0! max-[720px]:border-b! [&::-webkit-scrollbar]:hidden"
          >
            <button
              :for={{example, index} <- Enum.with_index(@entry.examples)}
              type="button"
              id={"pb-example-#{index}"}
              phx-click="pick_example"
              phx-value-index={index}
              class={[
                "flex flex-none items-center gap-[11px] rounded-[11px] border px-3 py-[11px] text-left hover:border-[#dcdbf5]",
                (@example_index == index && "border-[#dcdbf5] bg-[#f2f1fc]") ||
                  "border-[#ecebe6] bg-white"
              ]}
            >
              <span class={[
                "size-[15px] flex-none rounded-full border-2",
                (@example_index == index && "border-[#5b57d6] bg-[#5b57d6]") || "border-[#6d6a63]"
              ]}></span>
              <span class="min-w-0 flex-1">
                <span class={[
                  "block truncate text-[12px] font-bold",
                  (@example_index == index && "text-[#2e2b6b]") || "text-[#3a382f]"
                ]}>
                  {example.title}
                </span>
                <span class="mt-0.5 block line-clamp-2 text-[10.5px] font-medium leading-[1.4] text-[#6d6a63]">
                  {example_note(example)}
                </span>
              </span>
            </button>
          </div>

          <div class="flex min-h-0 min-w-0 flex-col">
            <div class="flex flex-none items-center gap-[9px] border-b border-[#f4f3ee] bg-[#faf9f6] px-4 py-2.5">
              <span class="text-[10px] font-bold uppercase tracking-[0.11em] text-[#6d6a63]">
                {gettext("Preview")}
              </span>
              <span class="rounded-[5px] border border-[#e4e2f7] bg-[#f2f1fc] px-[7px] py-0.5 font-['Space_Grotesk'] text-[9.5px] font-bold text-[#4f4bcc]">
                {preview_badge(@example_tab, @example, @example_index)}
              </span>
              <span class="flex-1"></span>
              <%!-- The stage narrows to a phone width rather than scaling: the point is how the
                    example reflows, and a scaled-down desktop render answers a different question. --%>
              <div class="flex rounded-[8px] bg-[#efeee9] p-0.5">
                <button
                  :for={{device, label, glyph} <- example_devices()}
                  type="button"
                  id={"pb-example-device-#{device}"}
                  phx-click="example_device"
                  phx-value-device={device}
                  title={label}
                  class={[
                    "grid h-6 w-7 place-items-center rounded-[6px]",
                    (@example_device == device && "bg-white text-[#4f4bcc]") || "text-[#6d6a63]"
                  ]}
                >
                  <.icon name={glyph} size={13} />
                </button>
              </div>
            </div>

            <%!-- The variant rendered by the canvas itself, in preview mode — same renderer, same
                  inlined site stylesheet, so this is the component the insert would actually place. --%>
            <div class="relative flex min-h-0 flex-1 justify-center overflow-y-auto bg-[#f6f5f2] px-5 py-6 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
              <.frame_pending
                frame={preview_id(@example_tab, @example_index, @example_device, @wizard)}
                label={gettext("Rendering the example…")}
              />
              <iframe
                id={preview_id(@example_tab, @example_index, @example_device, @wizard)}
                title={gettext("Example preview")}
                src={preview_src(@example_tab, @token, @entry, @example_index)}
                class={[
                  "relative h-full max-w-full flex-none rounded-[12px] border-0 bg-white transition-[width] duration-200",
                  example_stage_class(@example_device)
                ]}
              ></iframe>
            </div>

            <div class="flex-none border-t border-[#f0efea]">
              <button
                type="button"
                id="pb-example-code"
                phx-click={
                  JS.toggle(to: "#pb-example-code-body")
                  |> JS.toggle_class("is-open", to: "#pb-example-code")
                }
                class="flex w-full items-center gap-[9px] px-4 py-[11px] text-left hover:bg-[#faf9f6]"
              >
                <.icon name={:code} size={13} />
                <span class="text-[11.5px] font-bold text-[#3a382f]">{gettext("Code")}</span>
                <span class="font-['Space_Grotesk'] text-[10.5px] font-medium text-[#6d6a63]">heex</span>
                <span class="flex-1"></span>
                <.icon name={:chevron_up} size={14} class="[.is-open_&]:rotate-180" />
              </button>
              <pre
                id="pb-example-code-body"
                data-accent-panel
                class="m-0 hidden max-h-[150px] overflow-auto bg-[#17161a] px-4 py-3.5 font-['Space_Grotesk'] text-[11.5px] leading-[1.7] text-[#c9c7d1] [overflow-wrap:anywhere] [scrollbar-width:none] whitespace-pre-wrap [&::-webkit-scrollbar]:hidden [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)] [[data-theme=dark]_&]:!bg-[#141317] [[data-theme=dark]_&]:!border-[#232228]"
              >{preview_code(@example_tab, @example, @entry, @wizard, @site_name, @components)}</pre>
            </div>
          </div>
        </div>

        <footer class="flex flex-none items-center gap-2 border-t border-[#f0efea] px-5 py-3">
          <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63]">
            {(@example_tab == :wizard &&
                ngettext("%{count} option", "%{count} options", length(Wizard.axes(@entry)))) ||
              ngettext("%{count} variant", "%{count} variants", length(@entry.examples))}
          </span>
          <%!-- WHAT THIS COMPONENT SHOULD START AS, on this site. A kit ships one default for
                everyone; a site almost always has its own, and without somewhere to say so it is
                retyped in the inspector after every single drop. It sits beside Insert because this
                is the one screen where the choices are already made — see
                `MishkaCmsCore.Runtime.PageBuilder.Presets`. --%>
          <button
            :if={@example_tab == :wizard}
            type="button"
            id="pb-example-default"
            phx-click="save_preset"
            title={
              gettext("Every %{name} placed on this site will start with these options",
                name: @entry.name
              )
            }
            class="inline-flex h-8 flex-none items-center gap-[7px] rounded-[9px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[11.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            <.icon name={:star} size={13} />
            {(@preset? && gettext("Update the default")) || gettext("Make this the default")}
          </button>
          <button
            :if={@example_tab == :wizard and @preset?}
            type="button"
            id="pb-example-default-clear"
            phx-click="clear_preset"
            title={gettext("Go back to the kit's own default")}
            class="grid size-8 flex-none place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#6d6a63] hover:bg-[#f6f5f2]"
          >
            <.icon name={:close} size={13} />
          </button>
          <button
            type="button"
            phx-click="close_examples"
            class="h-8 flex-none rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[11.5px] font-semibold text-[#5c5a54] hover:bg-[#f6f5f2]"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            id="pb-example-insert"
            phx-click={(@example_tab == :wizard && "insert_wizard") || "insert_example"}
            phx-value-index={@example_index}
            class="inline-flex h-8 flex-none items-center gap-[7px] rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3 text-[11.5px] font-bold text-white"
          >
            <.icon name={:plus} size={14} />
            {(@example_tab == :wizard && gettext("Insert component")) || gettext("Insert example")}
          </button>
        </footer>
      </section>
    </div>
    """
  end

  # The examples pane keeps its stable id. The wizard's carries a hash of the choices, because
  # LiveView reuses an iframe with an unchanged id and the whole point of a pick is that the preview
  # re-renders.
  # STABLE across option changes. Hashing the wizard state into the id gave LiveView a different
  # element on every click, so it destroyed the iframe and built a new one — a fresh document load,
  # visible as a flash of half-painted frame. The preview inside subscribes to the session instead.
  defp preview_id(:wizard, _index, device, _wizard), do: "pb-wizard-preview-#{device}"

  defp preview_id(_tab, index, device, _wizard), do: "pb-example-preview-#{index}-#{device}"

  defp preview_src(:wizard, token, entry, _index),
    do: "/admin/dashboard/runtime/builder-canvas/#{token}/wizard/#{entry.name}"

  defp preview_src(_examples, token, entry, index),
    do: "/admin/dashboard/runtime/builder-canvas/#{token}/example/#{entry.name}/#{index}"

  defp preview_badge(:wizard, _example, _index), do: gettext("Your options")
  defp preview_badge(_tab, nil, index), do: gettext("Example %{number}", number: index + 1)
  defp preview_badge(_tab, example, _index), do: example.title

  defp preview_code(:wizard, _example, entry, wizard, site_name, components),
    do: Wizard.compose(entry, wizard, site_name, :blank, components)

  defp preview_code(_tab, example, _entry, _wizard, _site_name, _components),
    do: example && example.source

  # Desktop or phone width. The prototype offers these two and no more: a tablet column would show
  # the same reflow as one of them for almost every kit component.
  defp example_devices,
    do: [{"desktop", gettext("Desktop"), :desktop}, {"mobile", gettext("Mobile"), :mobile}]

  defp example_stage_class("mobile"), do: "w-[320px]"
  defp example_stage_class(_device), do: "w-full"

  # An example's own words when it has them, otherwise what it demonstrates — never a blank line. A
  # variant that pulls in another component says so, because inserting it brings that one too.
  # `Examples` already says what an example demonstrates; this adds the two things it cannot know
  # from the markup alone — that the preview is a real usage from the kit's docs, and what else has
  # to be installed for it to render.
  defp example_note(example) do
    [example.description, composed_note(example), requires(example)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp composed_note(%{composed?: true}), do: gettext("from the kit's docs")
  defp composed_note(_example), do: nil

  defp requires(%{requires: %{"components" => [_ | _] = components}}),
    do: gettext("also uses %{components}", components: Enum.join(components, ", "))

  defp requires(_example), do: nil

  @doc "The overlay sheets — Studio, Assets, Review and Record history."
  def sheet(assigns) do
    ~H"""
    <div
      id="pb-sheet"
      data-role="pb-sheet"
      class="fixed inset-0 z-[80] flex justify-end bg-[#17161a]/30"
      phx-mounted={overlay_in("#pb-sheet > section")}
      phx-remove={overlay_out("#pb-sheet > section")}
    >
      <section
        phx-click-away="close_sheet"
        class={[
          "flex h-full max-w-[94vw] flex-col border-l border-[#e6e4de] bg-white shadow-[-18px_0_50px_rgba(20,18,26,.18)]",
          sheet_width_class(@sheet)
        ]}
      >
        <header class="flex flex-none items-center gap-3 border-b border-[#f0efea] px-[18px] py-4">
          <h2 class="flex-1 font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
            {sheet_title(@sheet)}
          </h2>
          <button
            type="button"
            phx-click="close_sheet"
            title={gettext("Close")}
            class="grid size-[30px] flex-none place-items-center rounded-[9px] text-[#6d6a63] hover:bg-[#f7f6f3] hover:text-[#1b1a18]"
          >
            <.icon name={:close} size={18} />
          </button>
        </header>
        <%!-- REVIEW OWNS ITS OWN HEIGHT. Every other sheet is one scrolling column; Review is a
              thread that scrolls with a composer pinned under it, which cannot be done from inside
              a parent that already scrolls and pads. --%>
        <div class={[
          "min-h-0 flex-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
          (@sheet == :review && "flex flex-col") ||
            "overflow-y-auto px-[18px] pb-[18px] pt-3.5"
        ]}>
          <.history_tabs :if={@sheet == :history} {assigns} />
          <.history_sheet :if={@sheet == :history and @history_tab == :history} {assigns} />
          <.drafts_sheet :if={@sheet == :history and @history_tab == :drafts} {assigns} />
          <.studio_sheet :if={@sheet == :studio} {assigns} />
          <.assets_sheet :if={@sheet == :assets} {assigns} />
          <.review_sheet :if={@sheet == :review} {assigns} />
          <.translations_sheet :if={@sheet == :translations} {assigns} />
        </div>
      </section>
    </div>
    """
  end

  # The token export is a real generated file, not a preview of one — Copy gives you something you
  # can paste into a build.
  defp studio_sheet(assigns) do
    loaded = assigns[:studio_data]

    assigns =
      assigns
      |> assign(:loaded?, is_map(loaded))
      |> assign(:tokens, studio_list(loaded, :tokens))
      |> assign(:formats, Marketplace.formats())
      |> assign(:presets, studio_list(loaded, :presets))
      |> assign(
        :packages,
        matching_packages(studio_list(loaded, :packages), assigns.studio_query)
      )
      |> assign(:package_categories, ["all" | studio_list(loaded, :package_categories)])

    ~H"""
    <div class="flex flex-col gap-1 border-b border-[#f0efea] pb-3">
      <div class="flex gap-0.5 rounded-[10px] bg-[#f2f1ec] p-[3px]">
        <button
          :for={%{key: key, label: label} <- studio_tabs(@current_user)}
          type="button"
          id={"pb-studio-#{key}"}
          phx-click="studio_tab"
          phx-value-tab={key}
          class={[
            "h-[30px] min-w-0 flex-1 rounded-[8px] px-1.5 text-[11px] font-bold",
            (@studio_tab == key && "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,.1)]") ||
              "text-[#6d6a63]"
          ]}
        >
          {label}
        </button>
      </div>

      <%!-- Everything the Studio lists is either already here or comes from a registry, so the same
            scope filter sits above all of them. --%>
      <div :if={@studio_tab in [:presets, :registry]} class="mt-2 flex items-center gap-1.5">
        <button
          :for={
            {key, label} <- [
              {:all, gettext("All")},
              {:downloaded, gettext("Downloaded")},
              {:shop, gettext("Shop")}
            ]
          }
          type="button"
          id={"pb-studio-scope-#{key}"}
          phx-click="studio_scope"
          phx-value-scope={key}
          class={[
            "h-7 rounded-[8px] border px-3 text-[11px] font-bold",
            (@studio_scope == key && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
              "border-[#ecebe6] bg-white text-[#6d6a63]"
          ]}
        >
          {label}
        </button>
        <span class="flex-1"></span>
        <span class="text-[10.5px] font-semibold text-[#6d6a63]">
          {gettext("%{count} installed", count: installed_count(@packages))}
        </span>
      </div>
    </div>

    <%!-- WHAT IS COMING, AT THE SIZE IT WILL BE. The sheet used to read everything it shows before
          anything could paint — a stylesheet parse and a 10.8 MB bundle parse — so the Studio button
          did nothing at all until they finished. The tabs and the filters above are real and
          clickable from the first frame; only the list waits, and it waits as a shape rather than as
          an empty column that then jumps. --%>
    <div :if={!@loaded?} data-role="pb-studio-skeleton" class="pt-3">
      <div class="mb-3 h-[11px] w-[108px] animate-pulse rounded-[3px] bg-[#ecebe6]"></div>
      <div class="flex flex-col gap-[9px]">
        <div
          :for={row <- 1..6}
          id={"pb-studio-skel-#{row}"}
          class="h-[52px] animate-pulse rounded-[11px] border border-[#f0efea] bg-[#faf9f6]"
        >
        </div>
      </div>
    </div>

    <div :if={@loaded?}>
      <.studio_tokens :if={@studio_tab == :tokens} {assigns} />
      <.studio_classes :if={@studio_tab == :classes} {assigns} />
      <.studio_presets :if={@studio_tab == :presets} {assigns} />
      <.studio_snippets :if={@studio_tab == :snippets} {assigns} />
      <.studio_registry :if={@studio_tab == :registry} {assigns} />
      <.studio_settings :if={@studio_tab == :settings} {assigns} />
    </div>
    """
  end

  @doc """
  What the Studio shows before its data has arrived, and when the read fails.

  One definition so the two cannot drift: a key added to the loader and forgotten here is a `KeyError`
  in a render, which takes the whole editor down rather than one sheet.
  """
  @spec empty_studio_data() :: map()
  def empty_studio_data,
    do: %{tokens: [], token_categories: [], presets: [], packages: [], package_categories: []}

  # Read rather than matched, for the same reason: a partial map is an empty tab, never a crash.
  defp studio_list(nil, _key), do: []
  defp studio_list(loaded, key), do: Map.get(loaded, key) || []

  @doc "The Studio's tabs `user` may see, in the prototype's order — Classes sits beside Tokens
  because both are things a site defines once and every page then resolves through."
  def studio_tabs(user) do
    Events.collect(:studio_tabs, [
      %{key: :tokens, label: gettext("Tokens"), priority: 10},
      %{key: :classes, label: gettext("Classes"), priority: 20},
      %{key: :presets, label: gettext("Presets"), priority: 30},
      %{key: :snippets, label: gettext("Snippets"), priority: 40},
      %{key: :registry, label: gettext("Registry"), priority: 50},
      %{key: :settings, label: gettext("Settings"), priority: 60}
    ])
    |> Descriptor.permitted(user)
  end

  defp installed_count(packages), do: Enum.count(packages, &Map.get(&1, :installed?))

  # "All" plus every category that actually has a token, each with its own count.
  # The prototype's own groups, in its order, with its labels and dot colours. `screen` is shown as
  # "Breakpoints" because that is what a screen token is to the person reading the list, and `custom`
  # is a filter across the others rather than a group of its own.
  # `{key, chip label, group label, dot}`. The chip and the group heading differ on purpose, exactly
  # as they do in the prototype: a filter reads better short, a section heading reads better spelled
  # out.
  @token_groups [
    {"color", gettext_noop("Color"), gettext_noop("Color"), "#5b57d6"},
    {"type", gettext_noop("Type"), gettext_noop("Typography"), "#1f9d6b"},
    {"space", gettext_noop("Space"), gettext_noop("Spacing"), "#3a6cb5"},
    {"radius", gettext_noop("Radius"), gettext_noop("Radius"), "#7a5bd0"},
    {"shadow", gettext_noop("Shadow"), gettext_noop("Shadow"), "#c07a2a"},
    {"motion", gettext_noop("Motion"), gettext_noop("Motion"), "#0f8f86"},
    {"screen", gettext_noop("Breakpoints"), gettext_noop("Breakpoints"), "#b03a76"}
  ]

  def token_categories(tokens) do
    groups =
      for {key, chip, _label, _dot} <- @token_groups,
          count = Enum.count(tokens, &(&1.category == key)),
          count > 0,
          do: {key, chip, count}

    custom = Enum.count(tokens, &custom_token?/1)

    [{"all", gettext_noop("All"), length(tokens)}] ++
      groups ++ if(custom > 0, do: [{"custom", gettext_noop("Custom"), custom}], else: [])
  end

  def grouped_tokens(tokens, category) do
    selected = select_tokens(tokens, category)

    for {key, _chip, label, dot} <- @token_groups,
        items = Enum.filter(selected, &(&1.category == key)),
        items != [],
        do: {label, dot, items}
  end

  defp select_tokens(tokens, "all"), do: tokens
  defp select_tokens(tokens, "custom"), do: Enum.filter(tokens, &custom_token?/1)
  defp select_tokens(tokens, category), do: Enum.filter(tokens, &(&1.category == category))

  # Two shapes reach here: `Marketplace.Token`, which spells it `custom?`, and the Gervaz table's
  # `DesignToken`, which cannot — an Ash attribute may not end in `?`.
  defp custom_token?(%{custom?: custom}), do: custom == true
  defp custom_token?(%{custom: custom}), do: custom == true
  defp custom_token?(_token), do: false

  # The export is a real generated file, not a preview of one — Copy gives you something you can
  # paste into a build.
  # A collapsed row, like the prototype's: the generated file is the answer to a question most people
  # are not asking while they read the token list, so it opens on demand and names itself when shut.
  defp token_export(assigns) do
    assigns =
      assigns
      |> assign(:source, Marketplace.generate(assigns.token_format, assigns.tokens))
      |> assign(:file, token_file(assigns.formats, assigns.token_format))
      |> assign(:note, token_export_note(assigns.token_format))

    ~H"""
    <div class="-mx-3.5 border-t border-[#f0efea]">
      <button
        type="button"
        id="pb-token-export"
        phx-click={
          JS.toggle(to: "#pb-token-export-body")
          |> JS.toggle_class("is-open", to: "#pb-token-export")
        }
        class="flex w-full items-center gap-[9px] px-[18px] py-[11px] text-left hover:bg-[#faf9f6]"
      >
        <span class="text-[10px] font-bold uppercase tracking-[0.09em] text-[#6d6a63]">
          {gettext("Generated output")}
        </span>
        <span class="flex-1"></span>
        <span class="font-['Space_Grotesk'] text-[10px] font-semibold text-[#4f4bcc]">{@file}</span>
        <.icon
          name={:chevron_down}
          size={13}
          class="text-[#6d6a63] [.is-open_&]:rotate-180"
        />
      </button>

      <div id="pb-token-export-body" class="hidden px-[18px] pb-4">
        <pre
          data-accent-panel
          class="max-h-[190px] overflow-auto rounded-[11px] bg-[#17161a] px-[13px] py-3 font-['Space_Grotesk'] text-[10.5px] leading-[1.7] text-[#c9c7d1] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)] [[data-theme=dark]_&]:!bg-[#141317] [[data-theme=dark]_&]:!border-[#232228]"
        >{@source}</pre>
        <div class="mt-[9px] flex items-center gap-2">
          <span class="min-w-0 flex-1 text-[10px] font-medium text-[#6d6a63]">{@note}</span>
          <button
            type="button"
            id="pb-token-copy"
            phx-hook="PbCopy"
            data-copy={@source}
            class="h-7 flex-none rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-[11px] text-[10px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
          >
            {gettext("Copy")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp token_export_note(:tw), do: gettext("Merged into theme.extend on build.")
  defp token_export_note(:css), do: gettext("Injected into :root for every page.")
  defp token_export_note(:json), do: gettext("W3C format — import into Figma or another tool.")
  defp token_export_note(_ex), do: gettext("Compiled into your theme module.")

  defp token_file(formats, format) do
    case Enum.find(formats, fn {key, _label, _file, _hint} -> key == format end) do
      {_key, _label, file, _hint} -> file
      nil -> ""
    end
  end

  # STYLE ONCE, APPLY TO TWENTY, CHANGE IN ONE PLACE. The style panel writes utilities onto ONE
  # element, which is right for the card that needs to be a little wider and wrong for the twenty
  # that are meant to match — see `MishkaCmsCore.Runtime.PageBuilder.Classes`.
  defp studio_classes(assigns) do
    ~H"""
    <div class="pt-3">
      <form
        id="pb-class-form"
        phx-change="class_change"
        phx-submit="save_class"
        class="mb-3 flex gap-2 rounded-[12px] border border-[#ecebe6] bg-[#faf9f6] p-2.5"
      >
        <input
          type="text"
          name="name"
          id="pb-class-name"
          phx-debounce="blur"
          value={@class_draft[:name]}
          placeholder="card-shell"
          autocomplete="off"
          class="h-[34px] w-[150px] flex-none rounded-[9px] border border-[#ecebe6] bg-white px-2.5 font-['Space_Grotesk'] text-[11.5px] font-semibold text-[#1b1a18] outline-none focus:border-[#c3c1f0]"
        />
        <input
          type="text"
          name="utilities"
          id="pb-class-utilities"
          phx-debounce="blur"
          value={@class_draft[:utilities]}
          placeholder="rounded-xl bg-white p-6"
          autocomplete="off"
          class="h-[34px] min-w-0 flex-1 rounded-[9px] border border-[#ecebe6] bg-white px-2.5 text-[11.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0]"
        />
        <button
          type="submit"
          id="pb-class-save"
          class="h-[34px] flex-none rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3 font-['Space_Grotesk'] text-[11px] font-bold text-white"
        >
          {gettext("Save")}
        </button>
      </form>

      <%!-- Tailwind's own sentence about the utility it could not resolve, under the box that holds
            it. A class is refused before it is stored, because a stored one that does not compile
            takes the site's whole stylesheet with it. --%>
      <p
        :if={@class_error}
        id="pb-class-error"
        class="mb-3 rounded-[10px] border border-[#f0dcd8] bg-[#fdf3f1] px-[13px] py-2.5 text-[11px] font-bold leading-[1.55] text-[#c0473d]"
      >
        {@class_error}
      </p>

      <p
        :if={@classes == []}
        id="pb-classes-empty"
        class="px-2.5 py-9 text-center text-[12px] font-medium text-[#6d6a63]"
      >
        {gettext(
          "No reusable classes yet. Name one above, and it can go on as many elements as you like."
        )}
      </p>

      <div class="flex flex-col gap-[9px]">
        <%!-- Pressing a row loads it back into the form, which is the whole point of the feature:
              editing the class is how twenty elements change at once. --%>
        <article
          :for={class <- @classes}
          id={"pb-class-#{class.name}"}
          class="rounded-[12px] border border-[#ecebe6] bg-white px-[13px] py-2.5"
        >
          <div class="flex items-center gap-2.5">
            <button
              type="button"
              phx-click="edit_class"
              phx-value-name={class.name}
              class="min-w-0 flex-1 text-left"
            >
              <span class="block truncate font-['Space_Grotesk'] text-[12px] font-bold text-[#4f4bcc]">
                .{class.name}
              </span>
              <span class="mt-0.5 block truncate text-[10.5px] font-medium text-[#6d6a63]">
                {class.utilities}
              </span>
            </button>
            <button
              :if={@selection}
              type="button"
              id={"pb-class-apply-#{class.name}"}
              phx-click="apply_class"
              phx-value-name={class.name}
              title={gettext("Put this class on the selected element")}
              class="h-7 flex-none rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
            >
              {gettext("Apply")}
            </button>
            <button
              type="button"
              id={"pb-class-delete-#{class.name}"}
              phx-click="delete_class"
              phx-value-name={class.name}
              title={gettext("Delete this class")}
              class="grid size-7 flex-none place-items-center rounded-[8px] border border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"
            >
              <.icon name={:trash} size={13} />
            </button>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp studio_presets(assigns) do
    ~H"""
    <div class="pt-3">
      <.sample_catalogue_note :if={sample_catalogue?()} />
      <div class="mb-3 flex items-center gap-2">
        <span class="text-[11.5px] font-medium text-[#6d6a63]">
          {gettext("Applying a preset rewrites layout and tokens.")}
        </span>
        <span class="flex-1"></span>
        <%!-- Paid presets need a licence, and the tier says so once rather than on every card. --%>
        <span class="inline-flex flex-none items-center gap-[5px] rounded-full bg-[#fbf1df] px-[9px] py-[3px] text-[9.5px] font-bold text-[#8a5514]">
          {gettext("Free tier")}
        </span>
      </div>

      <div class="mb-3 flex gap-1.5 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button
          :for={
            {category, label} <- [
              {"all", gettext("All")},
              {"marketing", gettext("Marketing")},
              {"docs", gettext("Docs")},
              {"commerce", gettext("Commerce")},
              {"editorial", gettext("Editorial")}
            ]
          }
          type="button"
          id={"pb-preset-cat-#{category}"}
          phx-click="studio_cat"
          phx-value-cat={category}
          class={[
            "h-[27px] flex-none whitespace-nowrap rounded-full border px-[11px] text-[10.5px] font-semibold capitalize",
            (@studio_cat == category && "border-[#17161a] bg-[#17161a] text-white") ||
              "border-[#ecebe6] bg-[#f6f5f2] text-[#6d6a63]"
          ]}
        >
          {label}
        </button>
      </div>

      <%!-- Empty for a reason worth stating: a preset rewrites a page's layout AND its tokens
            together, and nothing on this server supplies one. The kits on disk answer the Registry
            tab, not this one. --%>
      <div
        :if={@presets == []}
        id="pb-presets-empty"
        class="px-4 py-9 text-center text-[12px] font-medium leading-[1.6] text-[#6d6a63]"
      >
        {gettext("No presets available.")}
        <span class="mt-1 block text-[11px] text-[#a8a5a0]">
          <.sentence
            text={
              gettext_noop(
                "A preset carries a whole layout and a token set. Connect a registry under %{setting} to install one."
              )
            }
            parts={%{setting: {"span", "font-bold", gettext("Settings → Registry source")}}}
          />
        </span>
      </div>

      <div data-role="preset-grid" class="grid grid-cols-2 gap-[11px] max-[620px]:grid-cols-1">
        <article
          :for={preset <- @presets}
          id={"pb-preset-#{preset.id}"}
          class={[
            "overflow-hidden rounded-[14px] border",
            (@applied_preset == preset.id && "border-[#dcdbf5] bg-[#faf9ff]") ||
              "border-[#ecebe6] bg-white"
          ]}
        >
          <%!-- The thumbnail is drawn from the preset's own palette rather than shipped as an image:
                a screenshot would be stale the moment the preset changed, and this says the one thing
                a thumbnail is for at this size — what the layout and the colours are. --%>
          <div
            class="relative flex h-[82px] items-center justify-center gap-1.5 p-3"
            style={"background:#{preset.thumb}"}
          >
            <span class="h-full w-[26%] rounded-[6px]" style={"background:#{bar(preset, 0)}"} />
            <span class="flex h-full flex-1 flex-col gap-[5px]">
              <span class="flex-1 rounded-[6px]" style={"background:#{bar(preset, 1)}"} />
              <span class="h-[36%] rounded-[6px]" style={"background:#{bar(preset, 2)}"} />
            </span>
            <span
              :if={preset.price}
              title={gettext("Needs a licence")}
              class="absolute right-[9px] top-[9px] grid size-6 place-items-center rounded-[8px] bg-[#14121a]/[.62] text-white"
            >
              <.icon name={:lock} size={12} />
            </span>
          </div>

          <div class="px-3.5 py-[13px]">
            <div class="flex items-center gap-2">
              <span class="min-w-0 font-['Space_Grotesk'] text-[12.5px] font-bold text-[#17161a]">
                {preset.name}
              </span>
              <span class={[
                "flex-none rounded-[5px] px-[7px] py-0.5 font-['Space_Grotesk'] text-[10px] font-bold",
                (preset.price && "bg-[#fbf1df] text-[#8a5514]") || "bg-[#e6f6ee] text-[#177a53]"
              ]}>
                {preset.price || gettext("Free")}
              </span>
              <span class="flex-1"></span>
              <span class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]">
                {gettext("%{count} sections", count: preset.sections)}
              </span>
              <span
                :if={preset[:installed?]}
                title={gettext("Downloaded")}
                class="grid size-[19px] flex-none place-items-center rounded-full bg-[#177a53] text-white"
              >
                <.icon name={:check} size={11} />
              </span>
              <span
                :if={!preset[:installed?]}
                title={gettext("Not downloaded")}
                class="grid size-[19px] flex-none place-items-center rounded-full border-[1.5px] border-dashed border-[#d5d3cc] text-[#b7b4ad]"
              >
                <.icon name={:download} size={10} />
              </span>
            </div>

            <p class="mt-1.5 text-[11.5px] font-medium leading-[1.5] text-[#6d6a63]">
              {preset.description}
            </p>

            <div class="mt-[9px] flex flex-wrap items-center gap-[9px] border-t border-[#f4f3ee] pt-[9px] text-[10px] font-semibold text-[#6d6a63]">
              <span class="inline-flex items-center gap-1">
                <span class="text-[#e6b422]">★</span>{preset.rating}
              </span>
              <span>{gettext("%{count} blocks", count: preset.blocks)}</span>
              <span>{preset.size}</span>
              <span>{preset.updated}</span>
            </div>
            <div class="mt-[5px] text-[10px] font-medium text-[#6d6a63]">
              {gettext("by %{author}", author: preset.author)}
            </div>

            <div class="mt-3 flex items-center gap-2">
              <span class="flex flex-none gap-1">
                <span
                  :for={colour <- preset[:palette] || []}
                  class="size-[15px] rounded-[5px] border border-[#14121a]/[.08]"
                  style={"background:#{colour}"}
                />
              </span>
              <span class="flex-1"></span>
              <span
                :if={@applied_preset == preset.id}
                class="flex-none rounded-[7px] bg-[#e6f6ee] px-[11px] py-[5px] text-[10.5px] font-bold text-[#177a53]"
              >
                {gettext("Applied")}
              </span>
              <button
                :if={!preset.price && @applied_preset != preset.id}
                type="button"
                id={"pb-preset-apply-#{preset.id}"}
                phx-click="apply_preset"
                phx-value-preset={preset.id}
                class="h-[31px] flex-none rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-[13px] text-[11px] font-bold text-white"
              >
                {gettext("Apply")}
              </button>
              <button
                :if={preset.price}
                type="button"
                id={"pb-preset-unlock-#{preset.id}"}
                phx-click="studio_tab"
                phx-value-tab="settings"
                class="inline-flex h-[31px] flex-none items-center gap-1.5 rounded-[9px] border border-[#f0e3c9] bg-[#fdf7ea] px-3 text-[11px] font-bold text-[#8a5514] hover:bg-[#faf0d9]"
              >
                <.icon name={:lock} size={12} /> {gettext("Unlock")}
              </button>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp bar(preset, index),
    do: preset |> Map.get(:bars, []) |> Enum.at(index) || preset.thumb

  # The save box is a Gervaz FORM and the list below it a Gervaz TABLE, each with its own custom
  # template so the markup is the one that shipped. What stays here is the pair of them and the one
  # value neither can carry: `source`, the serialised subtree, which changes on every canvas edit.
  # It rides on a hidden input associated with the form by id rather than through the component's
  # `defaults`, because changing `defaults` rebuilds the form and would wipe a half-typed name.
  defp studio_snippets(assigns) do
    ~H"""
    <div class="pt-3">
      <input
        type="hidden"
        form="pb-snippet-form"
        name="form[source]"
        value={@snippet_source}
      />

      <.live_component
        module={MishkaGervaz.Form.Web.Live}
        id="pb-snippet-form-component"
        resource={MishkaCmsCore.Runtime.Snippet}
        current_user={@current_user}
        defaults={@snippet_defaults}
      />

      <.live_component
        module={MishkaGervaz.Table.Web.Live}
        id="pb-snippets-table"
        resource={MishkaCmsCore.Runtime.Snippet}
        current_user={@current_user}
        url_state={@snippets_url_state}
      />
    </div>
    """
  end

  # Whichever of version and install-count the adapter supplied, and nothing where it supplied
  # neither.
  defp package_meta(package) do
    [
      package[:version],
      package[:installs] && gettext("%{count} installs", count: package[:installs])
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The registry search is a plain substring over what the card already shows, so what someone reads
  # is what they can search for.
  defp matching_packages(packages, query) when is_binary(query) do
    case String.trim(query) do
      "" -> packages
      needle -> Enum.filter(packages, &package_matches?(&1, String.downcase(needle)))
    end
  end

  defp matching_packages(packages, _query), do: packages

  defp package_matches?(package, needle) do
    [package[:name], package[:description], package[:author], package[:category]]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  defp studio_registry(assigns) do
    ~H"""
    <div class="pt-3">
      <.sample_catalogue_note :if={sample_catalogue?()} />
      <div class="relative">
        <.icon
          name={:search}
          size={14}
          class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[#a8a5a0]"
        />
        <input
          type="text"
          id="pb-registry-search"
          name="value"
          value={@studio_query}
          phx-keyup="studio_query"
          phx-debounce="120"
          placeholder={gettext("Search the component registry…")}
          autocomplete="off"
          class="peer h-10 w-full rounded-[11px] border border-[#ecebe6] bg-[#faf9f6] pl-[35px] pr-[30px] text-[12px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,.1)]"
        />
        <.clear_field field="pb-registry-search" event="studio_query" params={%{"value" => ""}} />
      </div>

      <div class="mt-2.5 flex gap-1.5 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button
          :for={category <- @package_categories}
          type="button"
          id={"pb-pkg-cat-#{category}"}
          phx-click="studio_cat"
          phx-value-cat={category}
          class={[
            "h-[27px] flex-none whitespace-nowrap rounded-full border px-[11px] text-[10.5px] font-semibold capitalize",
            (@studio_cat == category && "border-[#17161a] bg-[#17161a] text-white") ||
              "border-[#ecebe6] bg-[#f6f5f2] text-[#6d6a63]"
          ]}
        >
          {(category == "all" && gettext("All")) || category}
        </button>
      </div>

      <div class="mb-2.5 mt-2.5 flex items-center gap-2">
        <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#6d6a63]">
          registry.mishka.tools
        </span>
        <span class="flex-1"></span>
        <span class="text-[10.5px] font-semibold text-[#6d6a63]">
          {ngettext("%{count} package", "%{count} packages", length(@packages))}
        </span>
      </div>

      <p
        :if={!@registry_master? && @packages != []}
        class="mb-2.5 text-[10.5px] font-medium text-[#6d6a63]"
      >
        {gettext("Installs land on this site only.")}
      </p>

      <%!-- With the on-disk kits answering this tab, an empty list has a second meaning worth
            separating from "your search found nothing": every component the installed kits ship is
            already on this site. --%>
      <p
        :if={@packages == []}
        id="pb-registry-empty"
        class="px-4 py-10 text-center text-[12px] font-medium leading-[1.6] text-[#6d6a63]"
      >
        {(String.trim(@studio_query) != "" &&
            gettext("No packages match “%{query}”.", query: @studio_query)) ||
          gettext("Every component from the installed kits is already on this site.")}
      </p>

      <div class="flex flex-col gap-[9px]">
        <article
          :for={package <- @packages}
          id={"pb-pkg-#{package.id}"}
          class={[
            "rounded-[12px] border px-[13px] py-3",
            (package[:installed?] && "border-[#d7eddf] bg-[#fbfdfc]") || "border-[#ecebe6] bg-white"
          ]}
        >
          <div class="flex items-center gap-[9px]">
            <span class={[
              "grid size-7 flex-none place-items-center rounded-[9px]",
              (package[:installed?] && "bg-[#e6f6ee] text-[#177a53]") || "bg-[#f2f1fc] text-[#4f4bcc]"
            ]}>
              <.icon name={:box} size={15} />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block truncate font-['Space_Grotesk'] text-[12px] font-bold text-[#17161a]">
                {package.name}
              </span>
              <%!-- A registry supplies download counts and versions; the kits on disk do not, and a
                    bare "· installs" beside an empty star reads as data that failed to load. Each
                    figure is drawn only if there is one. --%>
              <span
                :if={package_meta(package) != []}
                class="mt-0.5 block truncate font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63]"
              >
                {Enum.join(package_meta(package), " · ")}
              </span>
            </span>
            <span
              :if={package[:installed?]}
              title={gettext("Downloaded")}
              class="grid size-5 flex-none place-items-center rounded-full bg-[#177a53] text-white"
            >
              <.icon name={:check} size={12} />
            </span>
            <span
              :if={!package[:installed?]}
              title={gettext("Not downloaded")}
              class="grid size-5 flex-none place-items-center rounded-full border-[1.5px] border-dashed border-[#d5d3cc] text-[#b7b4ad]"
            >
              <.icon name={:download} size={11} />
            </span>
          </div>

          <p class="mt-2 text-[11.5px] font-medium leading-[1.5] text-[#6d6a63]">
            {package[:description]}
          </p>

          <div class="mt-[9px] flex flex-wrap items-center gap-[9px] border-t border-[#f4f3ee] pt-[9px] text-[10px] font-semibold text-[#6d6a63]">
            <span :if={package[:rating]} class="inline-flex items-center gap-1">
              <span class="text-[#e6b422]">★</span>{package[:rating]}
            </span>
            <span :if={package[:size]}>{package[:size]}</span>
            <span>{ngettext("%{count} dependency", "%{count} dependencies", package[:deps] || 0)}</span>
            <span :if={package[:updated]}>{package[:updated]}</span>
            <span class="flex-1"></span>
            <span class="font-medium">{gettext("by %{author}", author: package[:author])}</span>
          </div>

          <div class="mt-2.5 flex items-center gap-2">
            <span class="font-['Space_Grotesk'] text-[10px] font-semibold text-[#6d6a63]">
              {package[:category]}
            </span>
            <span class="flex-1"></span>
            <span
              :if={package[:installed?]}
              class="inline-flex flex-none items-center gap-[5px] rounded-[7px] bg-[#e6f6ee] px-2.5 py-[5px] text-[10.5px] font-bold text-[#177a53]"
            >
              <.icon name={:check} size={11} /> {gettext("Installed")}
            </span>
            <%!-- WHERE THIS INSTALL LANDS, asked at the moment of installing. A master can share a
                  package with every site or keep it to the one they are editing, and the two
                  outcomes are far enough apart to be worth a deliberate click rather than a mode set
                  earlier in the panel and half-remembered. A tenant has one answer, so they get a
                  button and no question. `UiKitHandler.install_scope/2` reconciles either against
                  the actor — this is the affordance, never the guard. --%>
            <div
              :if={!package[:installed?] && @registry_master?}
              class="relative flex-none"
              phx-click-away={menu_close("#pb-pkg-install-menu-#{package.id}")}
            >
              <button
                type="button"
                id={"pb-pkg-install-#{package.id}"}
                phx-click={menu_toggle("#pb-pkg-install-menu-#{package.id}")}
                aria-haspopup="menu"
                class="inline-flex h-[29px] items-center gap-1.5 rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] pl-3 pr-2.5 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
              >
                <.icon name={:download} size={11} /> {gettext("Install")}
                <.icon name={:chevron_down} size={11} />
              </button>
              <div
                id={"pb-pkg-install-menu-#{package.id}"}
                role="menu"
                class="absolute right-0 top-[34px] z-[70] hidden w-[210px] rounded-[13px] border border-[#ecebe6] bg-white p-1.5 shadow-[0_18px_46px_rgba(20,18,26,.22)]"
              >
                <div class="px-2 pb-1 pt-1.5 text-[10px] font-bold uppercase tracking-[0.09em] text-[#6d6a63]">
                  {gettext("Install into")}
                </div>
                <button
                  :for={
                    {value, label, hint, glyph} <- [
                      {"site", gettext("This site"), gettext("Only the site you are editing"),
                       :window},
                      {"global", gettext("All sites"), gettext("Shared across every site"), :shield}
                    ]
                  }
                  type="button"
                  role="menuitem"
                  id={"pb-pkg-install-#{value}-#{package.id}"}
                  phx-click={
                    menu_close("#pb-pkg-install-menu-#{package.id}") |> JS.push("install_package")
                  }
                  phx-value-package={package.id}
                  phx-value-scope={value}
                  class="flex w-full items-start gap-2 rounded-[9px] px-2 py-[7px] text-left hover:bg-[#f7f6fd]"
                >
                  <span class="mt-[1px] grid size-[22px] flex-none place-items-center rounded-[7px] bg-[#f2f1fc] text-[#4f4bcc]">
                    <.icon name={glyph} size={12} />
                  </span>
                  <span class="min-w-0">
                    <span class="block text-[11.5px] font-bold text-[#3a382f]">{label}</span>
                    <span class="mt-[1px] block text-[10px] font-medium leading-[1.45] text-[#6d6a63]">
                      {hint}
                    </span>
                  </span>
                </button>
              </div>
            </div>

            <button
              :if={!package[:installed?] && !@registry_master?}
              type="button"
              id={"pb-pkg-install-#{package.id}"}
              phx-click="install_package"
              phx-value-package={package.id}
              phx-value-scope="site"
              class="inline-flex h-[29px] flex-none items-center gap-1.5 rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
            >
              <.icon name={:download} size={11} /> {gettext("Install")}
            </button>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp studio_settings(assigns) do
    ~H"""
    <div class="flex flex-col gap-4 pt-3">
      <div class="rounded-[13px] border border-[#e8e6f8] bg-[#f7f6fd] p-[13px]">
        <div class="flex items-center gap-[9px]">
          <span class="grid size-7 flex-none place-items-center rounded-[9px] bg-[#e4e2f7] text-[#4f4bcc]">
            <.icon name={:key} size={15} />
          </span>
          <div class="min-w-0">
            <div class="text-[12.5px] font-bold text-[#2e2b6b]">{gettext("License token")}</div>
            <div class="mt-0.5 text-[10.5px] font-medium text-[#7d79c4]">
              {gettext("Unlocks Pro presets and packages")}
            </div>
          </div>
        </div>

        <%!-- Read-only on purpose. A licence token is a credential, and a field that takes one here
              would be a field that throws it away: the token lives in Settings, which is where it is
              stored, scoped and audited. --%>
        <input
          type="text"
          id="pb-license-token"
          value={@license_token}
          readonly
          placeholder="mk_live_••••••••••••"
          class="mt-3 h-10 w-full cursor-default rounded-[10px] border border-[#dcdbf5] bg-white px-3 font-['Space_Grotesk'] text-[12px] font-medium text-[#1b1a18] outline-none"
        />

        <div class="mt-2.5 flex items-center gap-2">
          <span
            :if={@license_token != ""}
            class="inline-flex items-center gap-[5px] text-[10px] font-bold text-[#177a53]"
          >
            <span class="size-1.5 rounded-full bg-[#1f9d6b]"></span>{gettext(
              "Verified · Pro unlocked"
            )}
          </span>
          <span :if={@license_token == ""} class="text-[10px] font-semibold text-[#6d6a63]">
            {gettext("Not connected")}
          </span>
          <span class="flex-1"></span>
          <.link
            navigate="/admin/dashboard/settings"
            class="inline-flex h-[31px] flex-none items-center rounded-[9px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-3.5 text-[11px] font-bold text-white"
          >
            {(@license_token == "" && gettext("Connect")) || gettext("Change")}
          </.link>
        </div>
      </div>

      <div>
        <div class="mb-2.5 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("Registry source")}
        </div>
        <.form for={%{}} as={:registry} id="pb-registry-source-form" phx-change="registry_source">
          <div class="relative">
            <select
              name="registry[source]"
              class="h-10 w-full cursor-pointer appearance-none rounded-[10px] border border-[#ecebe6] bg-[#faf9f6] ps-3 pe-8 font-['Space_Grotesk'] text-[12px] font-semibold text-[#3a382f] outline-none"
            >
              <option
                :for={source <- registry_sources()}
                value={source}
                selected={@registry_source == source}
              >
                {(source == "self-hosted" && gettext("self-hosted")) || source}
              </option>
            </select>
            <.select_chevron />
          </div>
        </.form>
      </div>

      <div>
        <div class="mb-2.5 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#6d6a63]">
          {gettext("Options")}
        </div>
        <div class="flex flex-col">
          <%!-- Real switches over the site's own settings, not decoration: each one is read back
                through `MishkaCmsCore.Settings` on the next render. --%>
          <div
            :for={{key, label, note} <- studio_options()}
            class="flex items-center gap-2.5 border-b border-[#f4f3ee] py-2.5 last:border-b-0"
          >
            <span class="min-w-0 flex-1">
              <span class="block text-[11.5px] font-semibold text-[#3a382f]">{label}</span>
              <span class="mt-0.5 block text-[10px] font-medium text-[#6d6a63]">{note}</span>
            </span>
            <button
              type="button"
              id={"pb-studio-opt-#{key}"}
              phx-click="studio_option"
              phx-value-key={key}
              role="switch"
              aria-checked={to_string(@studio_options[key])}
              class={[
                "flex h-[23px] w-10 flex-none items-center rounded-full px-[3px] transition-colors",
                (@studio_options[key] && "justify-end bg-[#5b57d6]") || "justify-start bg-[#d9d7d0]"
              ]}
            >
              <span class="size-[17px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,.22)]"></span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  # Presets and packages come from whatever `Marketplace` adapter is configured. Until a host
  # configures a real one, the cards below are the shipped SAMPLE catalogue — and Install answers
  # truthfully that it cannot fetch them. Saying so above the cards is the difference between a demo
  # and a lie; the tokens and snippets tabs need no such note because they are this site's own data.
  defp sample_catalogue?,
    do: Marketplace.adapter() == MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock

  defp sample_catalogue_note(assigns) do
    ~H"""
    <MishkaCmsCore.CoreComponents.tip id="pb-sample-catalogue" class="mb-3">
      <span class="font-bold">{gettext("Sample catalogue.")}</span>
      <.sentence
        text={
          gettext_noop(
            "No registry is connected, so these are examples of what a registry would offer — Install and Apply have nothing to fetch. Point the Studio at a real one under %{setting}."
          )
        }
        parts={%{setting: {"span", "font-bold", gettext("Settings → Registry source")}}}
      />
    </MishkaCmsCore.CoreComponents.tip>
    """
  end

  defp registry_sources, do: ~w(registry.mishka.tools hex.pm/chelekom self-hosted)

  # Described rather than switched: each of these changes how tokens are compiled for every site, so
  # it belongs to the theme's own settings, not to a page being edited.
  @doc """
  The Studio's three theme options: setting key, label and the sentence under it.

  Public because `BuilderLive` writes them through `MishkaCmsCore.Settings` and has to know the same
  keys this draws — one list, two readers.
  """
  @spec studio_options() :: [{String.t(), String.t(), String.t()}]
  def studio_options do
    [
      {"studio.dark_pair", gettext("Generate dark pair"),
       gettext("Auto-derive a dark value for every color token")},
      {"studio.sync_tokens", gettext("Sync tokens across sites"),
       gettext("Push token edits to every site using this theme")},
      {"studio.lock_tokens", gettext("Lock tokens"),
       gettext("Prevent per-element color overrides")}
    ]
  end

  # The site's OWN tokens — declarations in its theme stylesheet, which `Tokens.put/4` writes back to
  # — and the marketplace's sample set only when it declares none. A site with no theme installed
  # then sees a demonstration of the panel rather than an empty one; a site with a theme sees itself.
  @doc """
  The site's own design tokens, falling back to whatever the marketplace adapter offers.

  Public because `BuilderLive` reads it off the click that opens the Studio rather than during the
  sheet's render — parsing every stylesheet the site has is not something to do while painting.
  """
  @spec studio_token_list(String.t() | nil) :: [
          MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token.t()
        ]
  def studio_token_list(site_id) do
    case Tokens.list(site_id) do
      [] -> Marketplace.tokens(site_id)
      tokens -> tokens
    end
  end

  defp studio_tokens(assigns) do
    ~H"""
    <div class="pt-3">
      <div class="mb-3 flex items-start gap-2">
        <div class="min-w-0 flex-1">
          <div class="text-[12.5px] font-bold text-[#17161a]">{gettext("Design tokens")}</div>
          <div class="mt-0.5 text-[10.5px] font-medium text-[#6d6a63]">
            {gettext("One source of truth — every component reads from these.")}
          </div>
        </div>
        <.link
          navigate="/admin/dashboard/runtime/stylesheets"
          class="inline-flex h-7 flex-none items-center gap-[5px] rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-[11px] text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
        >
          <.icon name={:plus} size={12} /> {gettext("New token")}
        </.link>
      </div>

      <div class="mb-2.5 flex gap-0.5 rounded-[9px] bg-[#f2f1ec] p-[3px]">
        <button
          :for={{key, label, _file, hint} <- @formats}
          type="button"
          id={"pb-tokfmt-#{key}"}
          phx-click="token_format"
          phx-value-format={key}
          title={translate(hint)}
          class={[
            "h-7 min-w-0 flex-1 truncate rounded-[7px] px-1.5 text-[10px] font-bold",
            (@token_format == key && "bg-white text-[#17161a] shadow-[0_1px_2px_rgba(30,28,24,.12)]") ||
              "text-[#6d6a63]"
          ]}
        >
          {translate(label)}
        </button>
      </div>

      <%!-- The list, its category chips and its load-more are a Gervaz table now — same markup,
            drawn by `MishkaCmsCoreWeb.Templates.StudioTokens`, which owns the whole of it. The
            heading and the export block above and below stay here: neither is a table. --%>
      <.live_component
        module={MishkaGervaz.Table.Web.Live}
        id="pb-tokens-table"
        resource={MishkaCmsCore.Runtime.PageBuilder.DesignToken}
        current_user={@current_user}
        url_state={@tokens_url_state}
      />

      <.token_export {assigns} />
    </div>
    """
  end

  # THE ASSETS SHEET IS THE MEDIA SYSTEM, not a second one.
  #
  # It used to be a read-only mirror: sixty records fetched by hand, tiles with a format badge and no
  # thumbnail, and a box that looked like a dropzone but was a link to the Media page. Anything an
  # author actually wanted to do here — upload, rename, delete, browse past sixty — meant leaving the
  # editor and losing the selection they came in with.
  #
  # Both halves are Gervaz components now, the same two the Media page mounts:
  #
  #   * `MishkaGervaz.Form.Web.Live` — the resource's own `uploads do … style :dropzone … end` block,
  #     so `allow_upload/3`, the drop target, per-entry progress, cancel, accept and size validation,
  #     and the write through `:form_upload` / `:master_form_upload` are all Gervaz's, not ours.
  #   * `MishkaGervaz.Table.Web.Live` — the `MediaGallery` template, with real thumbnails, the
  #     resource's filters, its row actions and its pagination.
  #
  # `editor_pick` is a PREFIXED path param on purpose: Gervaz turns any path param whose name matches
  # a resource attribute into an equality filter, so a key called `site_id` would silently drop every
  # row. It carries the node and attribute being filled, which is what makes the gallery's "Use"
  # action able to write straight back into the document.
  #
  # THE FORM HERE IS SHORTER THAN THE LIBRARY'S, and deliberately so. A page belongs to a site, so
  # the sheet must not ask which one — `hidden_fields` drops the Site field and `defaults` carries
  # the page's own `site_id` into the save, for a master exactly as for a tenant. And with no Site to
  # pick, Folder has nothing to wait for: it starts on the folder the rail has open, so a file dropped
  # there lands in it.
  #
  # `submit false` removes the Create button for the same reason: in 620px of overlay the dropzone IS
  # the action, so `UploadSubmitsItself` submits the moment a file is staged. Gervaz still allows the
  # `save` event — see `MishkaGervaz.Form.Web.State.apply_presentation/2` — and still draws the
  # button when the form is EDITING a record, because an edit has no dropzone to submit it.
  #
  # THE ID IS THE RESOURCE'S OWN, not one of ours. A card's Edit action does
  # `send_update(Form.Web.Live, id: Info.Form.component_id(resource), record_id: id)` — the id is
  # derived, not passed — so a form mounted under any other id simply never hears it. Prefixing this
  # one is what made Edit work on the Media page and do nothing here.
  defp assets_sheet(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1">
      <.assets_folders
        categories={@media_categories}
        selected={@assets_category}
        editor={@editor}
      />

      <div class="flex min-h-0 flex-1 flex-col">
        <div
          :if={@media_target}
          id="pb-media-target"
          class="mx-[18px] mt-3 flex flex-none items-center gap-2 rounded-[11px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 py-2.5"
        >
          <span class="grid size-6 flex-none place-items-center rounded-[8px] bg-[#e4e2f7] text-[#4f4bcc]">
            <.icon name={:image} size={13} />
          </span>
          <%!-- AND HOW. The banner used to name the target and stop there, which left the reader
                looking at a grid of files with a tick box on each and no way to tell that ticking
                one does nothing here — the tick is for Archive and Featured. The answer is the
                card's own wide button, so the banner points at it by name. --%>
          <span class="min-w-0 flex-1 text-[11.5px] font-semibold text-[#2e2b6b]">
            <.sentence
              text={gettext_noop("Choosing for %{target}")}
              parts={
                %{
                  target:
                    {"span", "font-['Space_Grotesk'] font-bold",
                     @media_target[:name] || @media_target[:prop]}
                }
              }
            />
            <span class="font-normal text-[#4f4bcc]">
              <.sentence
                text={gettext_noop("— press %{use} on a file below")}
                parts={%{use: {"b", nil, gettext("Use")}}}
              />
            </span>
          </span>
          <button
            type="button"
            id="pb-media-target-cancel"
            phx-click="cancel_media_pick"
            class="flex-none rounded-[7px] px-2 py-1 text-[10.5px] font-bold text-[#6d6a63] hover:bg-white"
          >
            {gettext("Cancel")}
          </button>
        </div>

        <%!-- A SWITCHED-OFF SITE'S FILES ARE HERE FOR THE MASTER TO WORK WITH, but nobody else sees
              them, or its pages, until the site is back on. Said here so a file that works in the
              editor is not taken for one that works on the site. --%>
        <div
          :if={site_off?(@editor)}
          id="pb-assets-site-off"
          class="mx-[18px] mt-3 flex flex-none items-center gap-2 rounded-[11px] border border-[#f0e3c9] bg-[#fbf1df] px-3 py-2.5"
        >
          <span class="grid size-6 flex-none place-items-center rounded-[8px] bg-[#f6e5c6] text-[#8a5514]">
            <.icon name={:alert} size={13} />
          </span>
          <span class="min-w-0 flex-1 text-[11.5px] font-semibold text-[#8a5514]">
            {gettext(
              "This site is switched off. Its files are here for you to work with, but visitors see none of its pages or files until it is turned back on."
            )}
          </span>
        </div>

        <div
          id="pb-media-upload"
          phx-hook="UploadSubmitsItself"
          class="flex-none px-[18px] pt-3.5"
        >
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={MishkaGervaz.Resource.Info.Form.component_id(Media)}
            resource={Media}
            current_user={@current_user}
            hidden_fields={(@editor.site_id && [:site_id]) || []}
            submit={false}
            defaults={%{site_id: @editor.site_id, media_category_id: @assets_category}}
          />
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto px-[18px] pb-[18px] pt-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          <.live_component
            module={MishkaGervaz.Table.Web.Live}
            id="pb-assets-gallery"
            resource={Media}
            current_user={@current_user}
            template={MishkaCmsCoreWeb.Templates.AssetsGrid}
            switchable_templates={[
              MishkaCmsCoreWeb.Templates.AssetsGrid,
              MishkaCmsCoreWeb.Templates.AssetsList
            ]}
            url_state={media_url_state(assigns)}
          />
        </div>
      </div>

      <.folder_modal
        :if={@folder_form?}
        site_id={@editor.site_id}
        parent_id={@assets_category}
        current_user={@current_user}
      />

      <.media_preview :if={@preview_media} media={@preview_media} />
    </div>
    """
  end

  defp section_glyph("layout"), do: :frame
  defp section_glyph("error-page"), do: :shield
  defp section_glyph("component"), do: :box
  defp section_glyph(_page), do: :page

  @doc """
  THE ESSENTIALS, BEFORE THE STRUCTURE. What the editor needs before there is a document to edit.

  "Create empty & open editor" is a link, so a reader who takes it has said they do not want the list
  page's form — and answering them with that form's validation would be answering a question they
  declined. This asks for the few things a record cannot exist without, and nothing else.

  IT IS THE RESOURCE'S OWN FORM, with everything but those few fields hidden. That is what makes the
  Site field a searchable relation picker rather than a `<select>` nobody could use against a hundred
  thousand sites, and what makes "required" mean what the resource says it means — a second little
  form of our own would have been a second set of rules to keep in step.

  A TENANT IS NEVER ASKED WHICH SITE, and this does nothing to arrange that: the resource declares
  the field `restricted true`, so Gervaz draws it for a master and for nobody else. Whether a site is
  REQUIRED is the resource's answer too — a page may be global, and its picker says so.

  IT ARRIVES INACTIVE. A document made here has nothing on it yet, and `active` is what puts it in
  front of visitors — a page that goes live the moment it is named is live while it is empty. The
  flag is one of the hidden fields, so `defaults` is what carries it: `hidden_fields` drops a field
  from the form but `merge_defaults/2` still fills the param it would have sent.

  On save the resource announces `{:form_saved, :create, record}` like any other Gervaz form, and the
  editor reopens on it — which is when the starter chooser appears, because from then on this is an
  ordinary empty document.
  """
  attr(:section, :string, required: true)
  attr(:current_user, :any, required: true)
  attr(:hidden_fields, :list, default: [])

  def new_document(assigns) do
    assigns =
      assigns
      |> assign(:label, Section.label(assigns.section))
      |> assign(:glyph, section_glyph(assigns.section))
      |> assign(:resource, Section.resource(assigns.section))

    ~H"""
    <div
      id="pb-new-document"
      class="fixed inset-0 z-[95] flex items-start justify-center overflow-y-auto bg-[#17161a]/45 p-6 py-[8vh] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      phx-mounted={modal_in("#pb-new-document > section")}
    >
      <section class="w-[680px] max-w-[94vw] rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_30px_80px_rgba(20,18,26,.3)]">
        <div class="flex items-start gap-3 border-b border-[#f0efea] px-5 py-[15px]">
          <span class="grid size-9 flex-none place-items-center rounded-[11px] bg-[#f2f1fc] text-[#4f4bcc]">
            <.icon name={@glyph} size={16} />
          </span>
          <div class="min-w-0 flex-1">
            <h2 class="font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]">
              {gettext("Name your %{label}", label: String.downcase(translate(@label)))}
            </h2>
            <p class="mt-1 text-[11.5px] font-medium text-[#6d6a63]">
              {gettext("Just enough to save it. You pick the structure next.")}
            </p>
          </div>
          <.link
            navigate={Section.list_path(@section)}
            title={gettext("Back to the list")}
            class="grid size-7 flex-none place-items-center rounded-[9px] text-[#a8a5a0] hover:bg-[#f6f5f2] hover:text-[#1b1a18]"
          >
            <.icon name={:close} size={14} />
          </.link>
        </div>

        <div class="px-6 py-5">
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={"pb-new-" <> @section}
            resource={@resource}
            current_user={@current_user}
            hidden_fields={@hidden_fields}
            defaults={%{"active" => false}}
          />
        </div>
      </section>
    </div>
    """
  end

  @doc """
  A document's own name, address and description, changed without leaving the editor. A page's
  description is the one search engines and link previews show; a page also picks here what each of
  its addresses shows, its layout and which permission names may open it.

  ## Why it exists

  A page is named and given a path once, on the way in — on the list page's form, or on the
  essentials step — and until now that was the only time. Changing either afterwards meant leaving
  the editor for the list, finding the row and opening its modal: a long way round for the two
  fields most likely to be wrong on a first draft, and one that costs the reader the editor they
  were working in.

  ## It is the resource's own form

  The same `MishkaGervaz.Form.Web.Live` the essentials step mounts, in edit mode over this record,
  with every other field hidden. The label, the validation, the uniqueness message and the action it
  saves through are the resource's — a small form of our own would be a second set of rules to keep
  in step with the list page's, and the one that drifts is always the second.

  ## Only where there is an address

  `settings?/1` is the gate, and it asks the resource rather than naming sections: a section has
  settings when its form declares a `path`. A component has none — it is reached by name from the
  markup that calls it, and its name is the key its compiled module is hashed from, so renaming one
  is not a settings change but a rename of every call site.

  ## What it does not offer

  The site. `update` accepts no `site_id` on any of these resources, so this could not move a
  document between sites even if it drew the field — and an editor left open on one that had just
  moved would be holding another site's palette, tokens and media.

  ## The SEO tab

  A section that stores SEO gets a second tab (`MishkaCmsCore.Runtime.PageBuilder.SeoSettings.mode/1`):
  a Gervaz form over `SeoSettings`, drawn by `MishkaCmsCoreWeb.Templates.SeoForm`. It mounts the
  first time the tab opens and stays, hidden, until the modal closes, so moving between the tabs
  loses nothing typed in either; it saves with its own Save. While the Media sheet is open for its
  share image the modal is `hidden?`.
  """
  attr(:section, :string, required: true)
  attr(:record, :map, required: true)

  attr(:draft, :map,
    default: nil,
    doc: "the draft the editor is writing, whose settings these are instead of the record's"
  )

  attr(:current_user, :any, required: true)
  attr(:tab, :atom, default: :general, doc: "`:general` or `:seo`")
  attr(:seo_form?, :boolean, default: false, doc: "whether the SEO tab's form is mounted")
  attr(:hidden?, :boolean, default: false, doc: "whether a sheet the SEO tab opened is over it")

  def settings_modal(assigns) do
    resource =
      (assigns.draft && Drafts.resource(assigns.section)) || Section.resource(assigns.section)

    assigns =
      assigns
      |> assign(:resource, resource)
      |> assign(:target, assigns.draft || assigns.record)
      |> assign(
        :form_id,
        "pb-settings-" <> assigns.section <> ((assigns.draft && "-draft") || "")
      )
      |> assign(:label, Section.label(assigns.section))
      |> assign(:seo_mode, SeoSettings.mode(assigns.section))

    ~H"""
    <div
      id="pb-settings-modal"
      class={[
        "fixed inset-0 z-[96] flex items-start justify-center overflow-y-auto bg-[#17161a]/40 p-6 py-[10vh] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
        @hidden? && "hidden"
      ]}
      phx-mounted={modal_in("#pb-settings-modal > section")}
      phx-remove={modal_out("#pb-settings-modal > section")}
      phx-window-keydown={!@hidden? && "close_settings"}
      phx-key="escape"
    >
      <section
        phx-click-away={!@hidden? && "close_settings"}
        class={[
          "max-w-[94vw] rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_30px_80px_rgba(20,18,26,.3)]",
          settings_width(@tab, @seo_mode)
        ]}
      >
        <div class="flex items-start gap-3 border-b border-[#f0efea] px-5 py-[15px]">
          <span class="grid size-9 flex-none place-items-center rounded-[11px] bg-[#f2f1fc] text-[#4f4bcc]">
            <.icon name={:sliders} size={16} />
          </span>
          <div class="min-w-0 flex-1">
            <h2 class="font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]">
              {gettext("%{label} settings", label: translate(@label))}
            </h2>
            <p :if={!@draft} class="mt-1 text-[11.5px] font-medium text-[#6d6a63]">
              {gettext("Saved to the %{label} itself. The design you have open is untouched.",
                label: String.downcase(translate(@label))
              )}
            </p>
            <p
              :if={@draft}
              id="pb-settings-draft-note"
              class="mt-1 text-[11.5px] font-medium text-[#6d6a63]"
            >
              {gettext(
                "Saved to the draft “%{draft}”. The %{label} takes them when the draft is published.",
                draft: Drafts.display_label(@draft.label),
                label: String.downcase(translate(@label))
              )}
            </p>
          </div>
          <button
            type="button"
            id="pb-settings-close"
            phx-click="close_settings"
            title={gettext("Close")}
            class="grid size-7 flex-none place-items-center rounded-[9px] text-[#a8a5a0] hover:bg-[#f6f5f2] hover:text-[#1b1a18]"
          >
            <.icon name={:close} size={14} />
          </button>
        </div>

        <div :if={@seo_mode} class="px-6 pt-4">
          <div role="tablist" class="flex gap-1 rounded-[9px] bg-[#f2f1ec] p-[3px]">
            <button
              :for={{key, label} <- [{:general, gettext("General")}, {:seo, gettext("SEO")}]}
              type="button"
              role="tab"
              id={"pb-settings-tab-#{key}"}
              aria-selected={to_string(@tab == key)}
              phx-click="settings_tab"
              phx-value-tab={key}
              class={[
                "h-7 flex-1 rounded-[7px] font-['Space_Grotesk'] text-[11.5px] font-bold",
                (@tab == key && "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,.1)]") ||
                  "text-[#6d6a63]"
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <%!-- Hidden rather than removed on the SEO tab, so what was typed here is still here. --%>
        <div class={["px-6 py-5", @tab != :general && "hidden"]}>
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={@form_id}
            resource={@resource}
            record_id={@target.id}
            current_user={@current_user}
            hidden_fields={settings_hidden_fields(@section, @resource)}
          />
        </div>

        <div :if={@seo_mode && @seo_form?} class={[@tab != :seo && "hidden"]}>
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id="pb-seo-settings"
            resource={SeoSettings}
            record_id={SeoSettings.id(@section, @target)}
            current_user={@current_user}
          />
        </div>
      </section>
    </div>
    """
  end

  # A page's SEO tab is two columns, its previews beside its fields; its General tab puts the title,
  # the path and the layout side by side. The other sections have a name and a path.
  defp settings_width(:seo, :page), do: "w-[1000px]"
  defp settings_width(_general, :page), do: "w-[760px]"
  defp settings_width(_tab, _not_a_page), do: "w-[520px]"

  # A page carries `:title`, the other sections carry `:name` — see `@essentials` in
  # `MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive`, which keeps the same two for the same reason.
  # A page's `:description` is its meta description — see `MishkaCmsCore.Runtime.Seo`.
  @settings_fields [:name, :title, :path, :description]

  @doc """
  Whether this section has an address to change — which is what the settings modal is for.

  Asked of the resource's own form rather than of a list of section names, so a fifth section
  arrives with the right answer and no list to remember.
  """
  @spec settings?(String.t()) :: boolean()
  def settings?(section), do: :path in form_fields(Section.resource(section))

  # A page edits its description on the SEO tab, beside the previews it feeds; the General tab showing
  # it too would be a second Save that writes back what the first one changed. The title stays on
  # General: it names the page, and the SEO tab's title is a stored tag over it.
  @seo_tab_fields [:description]

  # A page alone also picks, here, what each of its addresses shows, the layout it is drawn in and
  # who may open it — the other documents are not opened by visitors.
  @page_fields [:record, :layout_id, :permissions]

  @doc """
  Every field of the section's form except its name, its address and its description — and, for a
  page, its description, which its SEO tab edits, what each of its addresses shows, its layout and
  who may open it.

  Public because it is the whole contract between the modal and the resource: a test that read the
  hidden list out of the rendered markup would be testing Gervaz rather than the decision made here.
  """
  @spec settings_hidden_fields(String.t(), module() | nil) :: [atom()]
  def settings_hidden_fields(section, resource \\ nil) do
    shown =
      case SeoSettings.mode(section) do
        :page -> (@settings_fields -- @seo_tab_fields) ++ @page_fields
        _other -> @settings_fields
      end

    (resource || Section.resource(section)) |> form_fields() |> Enum.reject(&(&1 in shown))
  end

  defp form_fields(resource) do
    resource
    |> MishkaGervaz.Resource.Info.Form.fields()
    |> Enum.map(& &1.name)
  end

  @doc """
  A new folder, without leaving the page you are building.

  The same Gervaz form the Media library's Categories panel mounts —
  `MishkaCmsCore.Runtime.MediaCategory`'s own — so a folder made here is a folder made there, with
  the same actions, the same validation and the same `master_create` / `create` pair. Shorter by one
  field for the reason the upload form is: the page belongs to a site, so `hidden_fields` drops Site
  and `defaults` carries the answer. It starts inside the folder the rail has open, `parent_id`.

  Nothing here puts the new folder in the rail. `MediaCategory` publishes on `media_category:created`
  and `BuilderLive` re-reads the rail when it hears it — the same route a folder added in another tab
  arrives by, so there is one path to be right rather than two.

  ## It is drawn INSIDE the sheet, and that is load-bearing

  `fixed inset-0` puts it over everything regardless of where it sits in the DOM, but `phx-click-away`
  reads the DOM, not the screen. The sheet closes on click-away, so while this was a sibling of the
  sheet every click in it — including its own Close button — was a click AWAY from the sheet, and
  shutting the form shut the sheet behind it. Rendered inside, those clicks are contained.

  Escape needs the other half, and two handlers reach it: this one, and the editor's keyboard hook
  through `shortcut("escape", …)`. That is fine BECAUSE THEY AGREE — both close this form and
  neither touches the sheet. It was not fine when they disagreed: the sheet used to bind escape too,
  so one press pushed two events, the form's landed first and cleared the flag, and the sheet's
  arrived to find nothing stopping it. Escape shut both.

  Two are needed because neither covers the other's case. The hook stays quiet while the caret is in
  a field — correct for ⌘Z, wrong for escape in this form's Name box — and `phx-window-keydown` here
  answers wherever the caret is.

  And it is drawn LAST. Inserted as the sheet's first child it shifted every sibling by one, and
  morphdom pairs children by position — so opening the form destroyed and rebuilt the upload
  component and the gallery beside it, losing anything staged and re-running the query. Appended,
  the siblings keep their places and the new node is simply added.
  """
  attr(:site_id, :string, default: nil)
  attr(:parent_id, :string, default: nil)
  attr(:current_user, :map, required: true)

  def folder_modal(assigns) do
    ~H"""
    <div
      id="pb-folder-modal"
      class="fixed inset-0 z-[97] flex items-center justify-center bg-[#17161a]/40 p-6"
      phx-mounted={modal_in("#pb-folder-modal > section")}
      phx-remove={modal_out("#pb-folder-modal > section")}
      phx-window-keydown="close_folder"
      phx-key="escape"
    >
      <section
        phx-click-away="close_folder"
        class="w-[440px] max-w-[94vw] overflow-hidden rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_30px_80px_rgba(20,18,26,.3)]"
      >
        <div class="flex items-center gap-3 border-b border-[#f0efea] px-5 py-[14px]">
          <span class="grid size-9 flex-none place-items-center rounded-[11px] bg-[#f2f1fc] text-[#4f4bcc]">
            <.icon name={:folder} size={16} />
          </span>
          <div class="min-w-0 flex-1">
            <h2 class="font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]">
              {gettext("New folder")}
            </h2>
            <p class="mt-0.5 text-[11px] font-medium text-[#6d6a63]">
              {gettext("Files you upload here can be filed into it straight away.")}
            </p>
          </div>
          <button
            type="button"
            id="pb-folder-close"
            phx-click="close_folder"
            title={gettext("Close")}
            class="grid size-[30px] flex-none place-items-center rounded-[9px] border border-[#ecebe6] bg-white text-[#8a877f] hover:border-[#dcdbf5] hover:text-[#4f4bcc]"
          >
            <.icon name={:close} size={13} />
          </button>
        </div>

        <div class="px-5 py-[18px]">
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={MishkaGervaz.Resource.Info.Form.component_id(MediaCategory)}
            resource={MediaCategory}
            current_user={@current_user}
            hidden_fields={(@site_id && [:site_id]) || []}
            defaults={%{site_id: @site_id, parent_id: @parent_id}}
          />
        </div>
      </section>
    </div>
    """
  end

  @doc """
  The file, full size, without leaving the page you are building.

  The Media library's eye opens a preview there; here it used to open nothing — `BuilderLive`
  answered the row action and dropped it, because the editor had no overlay to put a file in. An
  action that is drawn and does nothing is worse than one that is not drawn.

  Escape is not bound here. `shortcut("escape", …)` closes this first, and one owner is what keeps
  the sheet from leaving with it.
  """
  attr(:media, :map, required: true)

  def media_preview(assigns) do
    ~H"""
    <div
      id="pb-media-preview"
      class="fixed inset-0 z-[98] flex items-center justify-center bg-[#17161a]/80 p-8"
      phx-click="close_media_preview"
      phx-mounted={modal_in("#pb-media-preview > div")}
      phx-remove={modal_out("#pb-media-preview > div")}
    >
      <div class="relative max-h-full max-w-3xl">
        <button
          type="button"
          id="pb-media-preview-close"
          phx-click="close_media_preview"
          title={gettext("Close")}
          class="absolute -top-9 right-0 grid size-8 place-items-center rounded-[9px] text-white hover:bg-white/10"
        >
          <.icon name={:close} size={16} />
        </button>

        <img
          :if={@media.image?}
          src={@media.url}
          alt={@media.name}
          class="max-h-[80vh] max-w-full rounded-[14px] object-contain"
        />

        <div
          :if={!@media.image?}
          class="grid h-[220px] w-[340px] place-items-center rounded-[14px] bg-white/10 text-white"
        >
          <.icon name={:page} size={40} />
        </div>

        <p class="mt-3 text-center text-[12px] font-semibold text-white">{@media.name}</p>
      </div>
    </div>
    """
  end

  attr(:categories, :any, required: true)
  attr(:selected, :string, default: nil)
  attr(:editor, :map, required: true)

  defp assets_folders(assigns) do
    ~H"""
    <nav
      data-role="pb-assets-folders"
      class="flex w-[168px] flex-none flex-col gap-2 overflow-y-auto border-r border-[#f0efea] p-[10px] max-[560px]:w-[54px]"
    >
      <span class="px-1.5 text-[9.5px] font-bold uppercase tracking-[0.11em] text-[#6d6a63] max-[560px]:hidden">
        {gettext("Folders")}
      </span>

      <div class="flex flex-col gap-[3px]">
        <button
          type="button"
          id="pb-folder-all"
          phx-click="select_asset_category"
          phx-value-id="__all__"
          title={gettext("All files")}
          class={[
            "flex items-center gap-2 rounded-[9px] border px-[9px] py-2 text-left max-[560px]:justify-center max-[560px]:px-0",
            (is_nil(@selected) && "border-[#dcdbf5] bg-[#f2f1fc]") ||
              "border-transparent hover:bg-[#f7f6f3]"
          ]}
        >
          <span class={[
            "grid size-5 flex-none place-items-center rounded-[6px]",
            (is_nil(@selected) && "bg-[#e4e2f7] text-[#4f4bcc]") || "bg-[#f4f3ee] text-[#6d6a63]"
          ]}>
            <.icon name={:folder} size={11} />
          </span>
          <span class={[
            "min-w-0 flex-1 truncate text-[10.5px] font-semibold max-[560px]:hidden",
            (is_nil(@selected) && "text-[#4f4bcc]") || "text-[#5c5a54]"
          ]}>
            {gettext("All files")}
          </span>
        </button>

        <.async_result :let={categories} assign={@categories}>
          <%!-- The rail is the sheet's sidebar and the gallery beside it is already drawing its own
                skeleton, so a word here would be the one thing in the sheet still saying it in
                prose. Three rows the shape of a folder, tile and all. --%>
          <:loading>
            <div
              :for={_row <- 1..3//1}
              data-role="pb-folder-skeleton"
              aria-hidden="true"
              class="flex items-center gap-2 rounded-[9px] border border-transparent px-[9px] py-2 max-[560px]:justify-center max-[560px]:px-0"
            >
              <span class="size-5 flex-none animate-pulse rounded-[6px] bg-[#f2f1ec]"></span>
              <span class="h-[8px] min-w-0 flex-1 animate-pulse rounded-full bg-[#f4f3ee] max-[560px]:hidden"></span>
            </div>
          </:loading>
          <:failed :let={_reason}>
            <span class="px-1.5 text-[10px] font-medium text-[#c0473d] max-[560px]:hidden">
              {gettext("Could not load folders")}
            </span>
          </:failed>

          <%!-- A folder inside another one sits under it, stepped in by how deep it is. --%>
          <button
            :for={{category, depth} <- nest_folders(categories)}
            type="button"
            id={"pb-folder-#{category.id}"}
            data-depth={depth}
            phx-click="select_asset_category"
            phx-value-id={category.id}
            title={category.name}
            class={[
              "flex items-center gap-2 rounded-[9px] border px-[9px] py-2 text-left max-[560px]:justify-center max-[560px]:px-0",
              folder_step(depth),
              (@selected == category.id && "border-[#dcdbf5] bg-[#f2f1fc]") ||
                "border-transparent hover:bg-[#f7f6f3]"
            ]}
          >
            <span class={[
              "grid size-5 flex-none place-items-center rounded-[6px]",
              (@selected == category.id && "bg-[#e4e2f7] text-[#4f4bcc]") ||
                "bg-[#f4f3ee] text-[#6d6a63]"
            ]}>
              <.icon name={:folder} size={11} />
            </span>
            <span class={[
              "min-w-0 flex-1 truncate text-[10.5px] font-semibold max-[560px]:hidden",
              (@selected == category.id && "text-[#4f4bcc]") || "text-[#5c5a54]"
            ]}>
              {category.name}
            </span>
            <span class="flex-none font-['Space_Grotesk'] text-[9px] font-semibold text-[#6d6a63] max-[560px]:hidden">
              {category.media_count}
            </span>
          </button>
        </.async_result>

        <button
          type="button"
          id="pb-folder-new"
          phx-click="new_folder"
          title={gettext("New folder")}
          class="mt-[3px] flex h-[30px] flex-none items-center justify-center rounded-[9px] border border-dashed border-[#d9d7d0] bg-white text-[10px] font-semibold text-[#5c5a54] hover:border-[#5b57d6] hover:text-[#4f4bcc]"
        >
          <span class="max-[560px]:hidden">{gettext("+ Folder")}</span>
          <span class="hidden max-[560px]:inline">+</span>
        </button>
      </div>
    </nav>
    """
  end

  # THE RAIL'S FOLDERS IN TREE ORDER, each with how deep it sits: a folder, then the folders inside
  # it, in the order they were read. A folder whose parent was not read stands at the top.
  defp nest_folders(folders) do
    read = MapSet.new(folders, & &1.id)

    folders
    |> Enum.group_by(&if(MapSet.member?(read, &1.parent_id), do: &1.parent_id))
    |> nest_under(nil, 0)
  end

  defp nest_under(inside, parent_id, depth) do
    inside
    |> Map.get(parent_id, [])
    |> Enum.flat_map(&[{&1, depth} | nest_under(inside, &1.id, depth + 1)])
  end

  # Four steps are enough to see the shape in a 168px rail; deeper folders stand at the fourth. The
  # icon-only rail of a narrow screen has no room to step at all.
  defp folder_step(0), do: nil
  defp folder_step(1), do: "ps-[19px] max-[560px]:ps-0"
  defp folder_step(2), do: "ps-[29px] max-[560px]:ps-0"
  defp folder_step(_deeper), do: "ps-[39px] max-[560px]:ps-0"

  # PATH PARAMS ARE THE ONLY CHANNEL INTO A GERVAZ TABLE that both filters the query and reaches a
  # row action's `visible` callback, and they arrive through `url_state`, not through an assign of
  # their own — `Table.Web.Live.update/2` reads `url_state[:path_params]`.
  #
  # Two different things ride in on it, and the difference matters:
  #
  #   * `site_id` MATCHES a Media attribute, so Gervaz turns it into an equality filter. That is the
  #     point: `:master_read` has no site argument, so a master editing one site would otherwise
  #     browse every site's library from inside that site's editor.
  #   * `editor_pick_*` do NOT match any attribute, so they filter nothing and are simply carried —
  #     which is what lets the "Use" action know whether there is anywhere to put the file, and
  #     where. Prefixed for exactly that reason: a key that collided with an attribute name would
  #     silently drop rows.
  #
  # Keys are ATOMS. Gervaz builds path params from the route pattern with `to_existing_atom`, and
  # the filter step tests membership against `Ash.Resource.Info.attributes/1`, whose names are atoms
  # — a string key matches nothing and is silently ignored.
  defp media_url_state(assigns),
    do: (assigns[:url_state] || %{}) |> Map.put(:path_params, media_scope_params(assigns))

  @doc """
  What the Assets gallery is scoped by: the site, the chosen folder, and — while something is waiting
  for a file — which node asked and what it can accept.

  Public because it is the whole contract between the editor and the gallery, and a test that reads
  it is asking the same question the table is.
  """
  @spec media_scope_params(map()) :: map()
  def media_scope_params(assigns) do
    %{
      site_id: assigns.editor.site_id,
      media_category_id: assigns[:assets_category],
      editor_open_only: is_nil(assigns.editor.site_id) || nil
    }
    |> Map.merge(media_pick_params(assigns[:media_target]))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # A length takes any CSS length; everything else here is its own kind of value and says nothing.
  defp length_hint(prop) do
    case prop in Styles.lengths() do
      true -> gettext("any length, e.g. 2rem")
      false -> gettext("unset")
    end
  end

  # Read from `SiteState` rather than the database: the sheet renders on every keystroke in its search
  # box, and this is an ETS lookup. A global document has no site and is never off.
  defp site_off?(%{site_id: site_id}) when is_binary(site_id) do
    match?({:ok, %{active: false}}, MishkaCmsCore.Runtime.States.SiteState.get(site_id))
  end

  defp site_off?(_no_site), do: false

  # Worth drawing a box for: an absolute path into this site, or a URL. Anything else is half-typed.
  defp previewable?(value),
    do: openable?(value) or String.starts_with?(to_string(value), "/")

  defp media_pick_params(nil), do: %{}

  defp media_pick_params(%{node_id: node_id, name: name} = target),
    do: %{editor_pick_node: node_id, editor_pick_attr: name} |> Map.merge(only(target))

  # A background carries a bucket and a style property rather than an attribute name. The gallery
  # only needs to know that SOMETHING is waiting for an answer — it shows its "Use" action on the
  # node param — so the property rides the attribute slot and `place_media/2` reads the real target
  # off the assign.
  defp media_pick_params(%{node_id: node_id, prop: prop} = target),
    do: %{editor_pick_node: node_id, editor_pick_attr: prop} |> Map.merge(only(target))

  # `type` IS a Media attribute, so this one becomes a real filter on the gallery — the same channel
  # `site_id` and `media_category_id` already ride. A field that can only show a picture is shown
  # only pictures, which is a door that cannot be walked through wrongly rather than a mistake
  # explained afterwards. `:any` adds nothing and the whole library stays listed.
  defp only(%{accepts: :images}), do: %{type: :images}
  defp only(_anything), do: %{}

  # A stable colour per author, from the prototype's own three. Deterministic rather than random so
  # the same person keeps the same dot between renders and between sessions.
  @avatar_colours ~w(#5b57d6 #1f9d6b #c07a2a #b5495f #2f7fb5)

  @doc """
  A stable colour for a name, for the Review thread's avatar discs.

  Public because `MishkaCmsCoreWeb.Templates.ReviewComments` draws the same discs — one answer, so
  the same person is the same colour in the sheet and anywhere else that shows them.
  """
  @spec avatar_tint(String.t() | nil) :: String.t()
  def avatar_tint(author), do: avatar_colour(author)

  @doc """
  The same disc colour as a whole Tailwind class, for a surface that paints it without a `style`.

  A class assembled around `avatar_tint/1` would be source text no Tailwind build can match, so the
  five colours are written out one clause each and the hash still chooses between them.
  """
  @spec avatar_tint_class(String.t() | nil) :: String.t()
  def avatar_tint_class(author), do: author |> avatar_colour() |> avatar_colour_class()

  defp avatar_colour(author) when is_binary(author),
    do: Enum.at(@avatar_colours, :erlang.phash2(author, length(@avatar_colours)))

  defp avatar_colour(_author), do: hd(@avatar_colours)

  defp avatar_colour_class("#1f9d6b"), do: "[background:#1f9d6b]"
  defp avatar_colour_class("#c07a2a"), do: "[background:#c07a2a]"
  defp avatar_colour_class("#b5495f"), do: "[background:#b5495f]"
  defp avatar_colour_class("#2f7fb5"), do: "[background:#2f7fb5]"
  defp avatar_colour_class(_violet), do: "[background:#5b57d6]"

  # THE REVIEW SHEET IS TWO GERVAZ COMPONENTS.
  #
  # It used to be hand-rolled markup over a list on the editing session — notes in ETS, swept after a
  # day idle, and three sample notes standing in whenever the list was empty, which meant the badge
  # read 3 on a page nobody had reviewed. Both halves are Gervaz now, over a real table:
  #
  #   * `Form.Web.Live` — the composer. Two fields, because the editor already knows which document,
  #     which element and who is writing; `Review.compose_defaults/1` hands it all of that.
  #   * `Table.Web.Live` — the thread, scoped by `Review.thread_params/1`.
  #
  # `defaults` is load-bearing and destructive: the form component rebuilds itself whenever
  # `defaults` changes, wiping anything half-typed. That is exactly right here — changing which
  # element you are commenting on SHOULD start a fresh note — but it is why nothing that changes
  # per keystroke may ever go through it.
  defp review_sheet(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div class="min-h-0 flex-1 overflow-y-auto px-[18px] pb-4 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <.live_component
          module={MishkaGervaz.Table.Web.Live}
          id="pb-review-thread"
          resource={PageComment}
          current_user={@current_user}
          url_state={
            %{
              path_params:
                Map.put(
                  Review.thread_params(review_scope(assigns)),
                  :revision,
                  @review_revision
                )
            }
          }
        />
      </div>

      <%!-- THE COMPOSER SITS AT THE BOTTOM, where a thread is written from. It used to be the first
            thing in the sheet, which put the newest note below a box nobody was using yet and made
            reading the thread mean scrolling past the form every time.

            `defaults` is load-bearing and destructive: the form component rebuilds itself whenever
            `defaults` changes, wiping anything half-typed. That is right here — changing which
            element you are commenting on SHOULD start a fresh note — but it is why nothing that
            changes per keystroke may ever go through it. --%>
      <div class="relative flex-none border-t border-[#f0efea] px-[18px] py-3">
        <.live_component
          module={MishkaGervaz.Form.Web.Live}
          id="pb-review-composer"
          resource={PageComment}
          current_user={@current_user}
          defaults={Review.compose_defaults(review_scope(assigns))}
        />

        <%!-- WHO `@` COULD MEAN.
              It lives out here rather than in the form template because the candidates change per
              keystroke, and `defaults` — the only way into a Gervaz form — is destructive: routing
              them through it would wipe the half-typed note that asked.

              AFTER THE COMPOSER IN THE DOM, ABOVE IT ON SCREEN. Inserting a node BEFORE a keyed
              sibling makes morphdom MOVE that sibling, and moving a focused element blurs it — so
              the list appeared and the blur that closed it fired in the same breath, about 200ms
              apart. Nothing before the form changes now, so the caret stays where it was typing. --%>
        <div
          :if={@mentions != []}
          id="pb-mention-list"
          phx-mounted={menu_in()}
          phx-remove={menu_out()}
          class="absolute bottom-full left-[18px] right-[18px] z-20 mb-1 overflow-hidden rounded-[10px] border border-[#e6e4de] bg-white shadow-[0_8px_24px_rgba(0,0,0,.10)]"
        >
          <%!-- PICKED BY THE HOOK, not by a round trip. `data-handle` is what it reads and
                `data-active` is what it paints — the class is in the markup, so the compiled
                stylesheet has a rule for it; only the attribute moves at runtime. `mousedown` with
                `preventDefault` is what keeps the caret in the note while the mouse is down.

                The id is the account's, not the handle's: two sites can hold a `@sara` each, and an
                id built from the handle would put two elements on one id. --%>
          <button
            :for={{person, index} <- Enum.with_index(@mentions)}
            type="button"
            id={"pb-mention-#{person.id}"}
            data-handle={person.handle}
            data-index={index}
            data-active={to_string(index == 0)}
            class="flex w-full items-center gap-2 px-2.5 py-1.5 text-left hover:bg-[#f7f6fd] data-[active=true]:bg-[#f2f1fc]"
          >
            <span class={[
              "grid size-[20px] flex-none place-items-center rounded-full text-[9px] font-bold text-white",
              avatar_tint_class(person.handle)
            ]}>
              {String.upcase(String.first(person.handle))}
            </span>
            <%!-- THE WHOLE ADDRESS, read in two weights. A list of four `master@` rows is told apart
                  by its domains, so the domain is the part that must not be dropped — the local part
                  leads because it is what is being looked for. --%>
            <span class="min-w-0 flex-1 truncate text-[11.5px]">
              <span class="font-bold text-[#17161a]">@{person.local}</span><span class="font-medium text-[#8a877f]">{person.domain}</span>
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  # WHAT THE EDITOR KNOWS, in the shape `Review` asks for. One place, so the composer's defaults, the
  # thread's scope and the top bar's counter can never disagree about which document is open or which
  # element is selected.
  @doc false
  def review_scope(assigns) do
    %{
      actor: assigns[:current_user],
      site_id: assigns.editor.site_id,
      section: section_atom(assigns.editor.section),
      document_id: assigns.editor.resource_id,
      author_id: assigns[:current_user] && assigns.current_user.id,
      node_id: assigns[:selected_node] && assigns.selected_node.id,
      # WHERE IT SITS, computed against the tree this session parsed. The id beside it is only good
      # here; this is what another session resolves the note with.
      node_path:
        assigns[:selected_node] &&
          MishkaCmsCore.Runtime.PageBuilder.Tree.address(
            assigns.editor.tree,
            assigns.selected_node.id
          ),
      node_label: assigns[:selected_node] && node_label(assigns.selected_node),
      revision: assigns[:review_revision],
      reply_to: assigns[:reply_to],
      on_page?: assigns[:note_on_page?] == true
    }
  end

  # ONE OWNER FOR THE THREE SPELLINGS. This did the conversion by hand, with a bare
  # `String.to_existing_atom/1` on a value that may not be a section at all.
  defp section_atom(section) do
    case Section.to_atom(section) do
      {:ok, atom} -> atom
      :error -> :page
    end
  end

  # An empty thread shows the sample notes when the demo flag is on; the first real note replaces
  # them, exactly like the history and the assistant.
  attr(:tiles, :integer, default: 4)

  @doc "The assets grid's own waiting shape — the tile, not a row."
  def loading_tiles(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2.5" aria-hidden="true">
      <div
        :for={_tile <- 1..@tiles}
        class="overflow-hidden rounded-[10px] border border-[#f0efea] bg-white"
      >
        <div class="h-[72px] animate-pulse bg-[#f6f5f2]"></div>
        <div class="px-2.5 py-2">
          <span class="block h-[8px] w-3/5 animate-pulse rounded-full bg-[#f2f1ec]"></span>
        </div>
      </div>
    </div>
    """
  end

  attr(:rows, :integer, default: 3)

  @doc """
  The shape of the answer while the answer is still coming — a panel that opens instantly and fills
  in beats one that opens when the database is ready.
  """
  def loading_rows(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5" aria-hidden="true">
      <div
        :for={_row <- 1..@rows}
        class="flex items-center gap-2.5 rounded-[10px] border border-[#f0efea] bg-white px-3 py-2.5"
      >
        <span class="size-[26px] flex-none animate-pulse rounded-[8px] bg-[#f2f1ec]"></span>
        <span class="min-w-0 flex-1">
          <span class="block h-[9px] w-2/5 animate-pulse rounded-full bg-[#f2f1ec]"></span>
          <span class="mt-1.5 block h-[7px] w-3/5 animate-pulse rounded-full bg-[#f6f5f2]"></span>
        </span>
      </div>
    </div>
    """
  end

  # Two views of "what other versions of this exist" — the edits made in this session, and the drafts
  # saved from it. Same segmented control the Studio sheet uses for its five.
  defp history_tabs(assigns) do
    ~H"""
    <div class="mb-3.5 flex gap-1 rounded-[9px] bg-[#f2f1ec] p-[3px]">
      <button
        :for={{key, label} <- [{:history, gettext("Record history")}, {:drafts, gettext("Drafts")}]}
        type="button"
        id={"pb-histtab-#{key}"}
        phx-click="history_tab"
        phx-value-tab={key}
        class={[
          "h-7 flex-1 rounded-[7px] font-['Space_Grotesk'] text-[11.5px] font-bold",
          (@history_tab == key && "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,.1)]") ||
            "text-[#6d6a63]"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  # Every draft of this document, plus the one being edited. The rule the whole sheet exists to make
  # visible: the editor writes to ONE target, and that target is named here and in the top bar. A
  # name already taken is never silently overwritten — it asks.
  #
  # The list itself is a Gervaz table drawn by `MishkaCmsCoreWeb.Templates.DraftList`; the naming
  # form and the collision banner are not a table and stay here.
  defp drafts_sheet(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <form
        id="pb-draft-form"
        phx-change="typed:pb-draft-form"
        phx-submit="save_as_draft"
        class="flex items-center gap-2"
      >
        <input type="hidden" name="base" value={@editor.draft_label} />
        <input
          id="pb-draft-name"
          name="label"
          phx-debounce="blur"
          value={typed_over(@typed, "pb-draft-form", "label", @editor.draft_label)}
          placeholder={gettext("Name this draft")}
          autocomplete="off"
          class="h-8 min-w-0 flex-1 rounded-[9px] border border-[#e6e4de] bg-white px-2.5 font-['Space_Grotesk'] text-[12px] font-medium text-[#1b1a18] placeholder:text-[#a8a5a0] focus:border-[#c3c1f0] focus:outline-none"
        />
        <button
          type="submit"
          id="pb-draft-save-as"
          class="h-8 flex-none rounded-[9px] bg-[#17161a] px-3 font-['Space_Grotesk'] text-[11.5px] font-bold text-white hover:bg-[#2e2c33]"
        >
          {gettext("Save as")}
        </button>
      </form>

      <div
        :if={@draft_conflict}
        id="pb-draft-conflict"
        class="rounded-[10px] border border-[#f0e3c9] bg-[#fbf1df] px-3 py-2.5"
      >
        <p class="text-[11.5px] font-semibold leading-[1.5] text-[#8a5514]">
          {gettext("A draft called “%{label}” already exists, saved %{ago}.",
            label: @draft_conflict.label,
            ago: ago(@draft_conflict.draft.updated_at)
          )}
        </p>
        <div class="mt-2 flex items-center gap-2">
          <button
            type="button"
            id="pb-draft-overwrite"
            phx-click="save_as_draft"
            phx-value-label={@draft_conflict.label}
            phx-value-draft_id={@draft_conflict.draft.id}
            class="h-7 rounded-[8px] bg-[#17161a] px-2.5 text-[11px] font-bold text-white hover:bg-[#2e2c33]"
          >
            {gettext("Update it")}
          </button>
          <button
            type="button"
            id="pb-draft-keep-both"
            phx-click="save_as_draft"
            phx-value-label={gettext("%{label} copy", label: @draft_conflict.label)}
            class="h-7 rounded-[8px] border border-[#e6e4de] bg-white px-2.5 text-[11px] font-bold text-[#5c5a54] hover:bg-[#f7f6f3]"
          >
            {gettext("Save as a copy")}
          </button>
        </div>
      </div>

      <.live_component
        :if={@drafts_enabled?}
        module={MishkaGervaz.Table.Web.Live}
        id="pb-drafts-table"
        resource={@drafts_resource}
        current_user={@current_user}
        url_state={@drafts_url_state}
      />

      <%!-- A component keeps no drafts, and a document that was never saved has none to keep — the
            tab is still reachable, and it says so rather than drawing a table over nothing. --%>
      <p
        :if={!@drafts_enabled?}
        class="py-8 text-center text-[12px] font-medium text-[#a8a5a0]"
      >
        {gettext("No drafts yet. “Save as” keeps one you can come back to.")}
      </p>
    </div>
    """
  end

  # THE DURABLE LOG, not the session's undo stack. This used to be a hand-rolled `<ol>` over
  # `editor.past`: one session's ops, every author rendered "You", and everything gone on reload.
  # It is a gervaz table over `MishkaCmsCore.Runtime.PageBuilderEvent` now, scoped by `url_state` to
  # whatever the editor is on — this record, this branch — exactly as the draft picker beside it is.
  #
  # Undo and redo did NOT move: they still walk `editor.past` in memory and stay instant, because
  # they never touch the database. The two lists answer different questions — what can I redo right
  # now, and what happened to this document.
  defp history_sheet(assigns) do
    ~H"""
    <p class="-mt-1 mb-3 text-[11px] font-medium text-[#6d6a63]">
      {gettext("Every change to this page")}
    </p>

    <%!-- A change is written when it settles, so one just made appears a moment later rather than
          instantly. Saying so beats a reader wondering whether it was recorded at all. --%>
    <div
      :if={!@history_recording?}
      class="mb-3 flex items-start gap-2 rounded-[10px] border border-[#f0e2c8] bg-[#fdfaf3] px-2.5 py-2"
    >
      <.icon name={:warning} size={12} class="mt-0.5 flex-none text-[#a5691a]" />
      <span class="min-w-0 text-[10.5px] font-medium leading-[1.5] text-[#3a382f]">
        {gettext(
          "Your document is fine and still being saved. Its history is not being recorded just now — it will catch up on its own."
        )}
      </span>
    </div>

    <.live_component
      module={MishkaGervaz.Table.Web.Live}
      id="pb-history-table"
      resource={MishkaCmsCore.Runtime.PageBuilderEvent}
      current_user={@current_user}
      url_state={@history_url_state}
    />

    <%!-- THE ONLY DELETE OFFERED, and it takes a whole document's history at once. Removing one
          entry and leaving its neighbours is the operation that lets somebody quietly delete the
          evidence of one change, which is what a record of what happened exists to prevent.
          The confirm says both halves: what goes, and that the page itself does not. --%>
    <div :if={@history_clearable?} class="mt-3 border-t border-[#f0efea] pt-3">
      <button
        type="button"
        id="pb-history-clear"
        phx-click="history_clear"
        data-confirm={
          gettext(
            "Deletes every recorded change for this page, including what can be restored from them. The page itself is untouched. This cannot be undone."
          )
        }
        class="h-[26px] rounded-[8px] border border-[#f0dcd8] bg-white px-2.5 text-[10px] font-bold text-[#a3554f] hover:bg-[#fdf2f1]"
      >
        {gettext("Clear this page’s editing history")}
      </button>
    </div>
    """
  end

  @doc """
  How long ago, in the reader's language — "2h ago", "yesterday" — and past two days the day and
  time, "Jul 3, 18:04".

  A draft picker is a list of moments, and a bare timestamp makes the reader do the arithmetic.
  Anything that is not a `DateTime` answers `""`, so a row with no timestamp shortens rather than
  raising. Shared with `MishkaCmsCoreWeb.Templates.DraftList`, which stamps the same rows.
  """
  @spec ago(DateTime.t() | term()) :: String.t()
  def ago(%DateTime{} = at) do
    if DateTime.diff(DateTime.utc_now(), at, :second) < 172_800,
      do: Localized.ago(at, format: :narrow),
      else: Localized.datetime(at, :MMMdHm)
  end

  def ago(_missing), do: ""

  # ONE BAR, TWO ARRIVALS, and the live page is underneath both of them — reopening a document
  # DETACHES the session from whatever draft it was in (`detach_draft/4` in `BuilderLive`), so the
  # canvas is the live page in either case and both sentences can say so.
  #
  # `:session` is news: the last sitting was in a draft and this visit did not ask for it.
  # `:chosen` is not news at all — the draft was picked in the preview modal's strip a click ago and
  # its id came in on the URL, so the bar's job is to open it, not to explain it. Telling somebody
  # they "were working in" a draft they chose ten seconds ago reads like the editor misunderstood
  # the click.
  defp inherited_question(%{source: :chosen, label: label}),
    do:
      gettext("You picked “%{label}” in the drafts list. Open it here, or stay on the live page?",
        label: label
      )

  defp inherited_question(%{label: label}),
    do:
      gettext(
        "You were working in “%{label}”. Carry on where you left off, or start again from the live page?",
        label: label
      )

  defp inherited_action(%{source: :chosen}), do: gettext("Open it")
  defp inherited_action(_inherited), do: gettext("Carry on")

  # "Start again from" is a MOVE — it re-reads the live template and reloads the frames. Declining a
  # draft that was only ever offered is not a move, and this does not say it is.
  defp inherited_decline(%{source: :chosen}), do: gettext("Stay on the live page")
  defp inherited_decline(_inherited), do: gettext("Start from the live page")

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

  # The dot is the draft light, so its tooltip is what the last write did.
  defp autosave_title(%{updated_at: %DateTime{} = at}),
    do:
      gettext("Saving as you work — kept %{time} · click to change status",
        time: Localized.time(at, :Hm)
      )

  defp autosave_title(_draft),
    do: gettext("Saving as you work — nothing changed yet · click to change status")

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
      {"layers", gettext("Layers")},
      {"inspector", gettext("Inspector")},
      {"assistant", gettext("Assistant")},
      {"audit", gettext("Audit")},
      {"assets", gettext("Assets")},
      {"studio", gettext("Studio")},
      {"palette", gettext("Search")},
      {"history", gettext("History")},
      {"dir", String.upcase(assigns.dir)}
    ]
  end

  # Assets is the widest because it lays out a grid of thumbnails; Review and Versions are columns of
  # text and read better narrow. `max-w-[94vw]` still caps all of them on a small screen.
  # THE WORDS THIS DOCUMENT ASKS `t/1` FOR, and nothing else of the site's. The table and the form
  # are Gervaz's — the same `MishkaCmsCore.Runtime.Translation` table and form the admin page shows —
  # scoped by `key`, which a list path param turns into `key in …`. Which sites' rows come back is the
  # resource's read policy, not this: a site admin gets their own and the global ones.
  #
  # `url_sync={false}` BECAUSE THIS TABLE IS NOT THE PAGE. The admin list writes its sort and filters
  # into the address; here that address is the editor's, so the table's patch crashed BuilderLive,
  # and every redraw replaced the page's flash with the table's empty one.
  defp translations_sheet(assigns) do
    ~H"""
    <div id="pb-translations-sheet" class="space-y-3.5">
      <div
        :if={@translation_keys == []}
        id="pb-translations-empty"
        class="rounded-[12px] border border-dashed border-[#e6e4de] bg-[#faf9f6] px-4 py-5 text-[12.5px] leading-[1.6] text-[#6d6a63]"
      >
        <p class="font-semibold text-[#3a382f]">
          {gettext("This document asks for no translated words yet.")}
        </p>
        <p class="mt-1.5">
          <.sentence
            text={
              gettext_noop(
                "Wrap a word in %{wrapper} and it appears here, in every language the site publishes in:"
              )
            }
            parts={%{wrapper: {"code", "font-mono text-[#4f4bcc]", ~S|t("…")|}}}
          />
        </p>
        <pre
          class="mt-2 rounded-[8px] bg-white px-3 py-2 font-mono text-[11.5px] text-[#3a382f]"
          phx-no-curly-interpolation
        >&lt;h2&gt;{t("Categories")}&lt;/h2&gt;</pre>
        <p class="mt-1.5">
          {gettext("Until a language has a translation, the page shows the word itself.")}
        </p>
      </div>

      <div :if={@translation_group} id="pb-translation-group-wrap" class="space-y-3">
        <button
          type="button"
          id="pb-translation-back"
          phx-click="translation_back"
          class="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#5b57d6] hover:text-[#4f4bcc]"
        >
          <.icon name={:chevron} size={13} class="rotate-180" /> {gettext("All words")}
        </button>
        <MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup.translation_group
          id="pb-translation-group"
          group={@translation_group}
          current_user={@current_user}
        />
      </div>

      <.live_component
        :if={@translation_keys != [] and is_nil(@translation_group)}
        module={MishkaGervaz.Table.Web.Live}
        id="pb-translations"
        resource={MishkaCmsCore.Runtime.Translation}
        current_user={@current_user}
        url_state={%{path_params: %{key: @translation_keys}}}
        url_sync={false}
      />
    </div>
    """
  end

  defp sheet_width_class(:assets), do: "w-[620px]"
  defp sheet_width_class(:studio), do: "w-[520px]"
  defp sheet_width_class(:review), do: "w-[420px]"
  defp sheet_width_class(:history), do: "w-[420px]"
  defp sheet_width_class(:translations), do: "w-[680px]"
  defp sheet_width_class(_sheet), do: "w-[470px]"

  defp sheet_title(:studio), do: gettext("Studio")
  defp sheet_title(:assets), do: gettext("Assets")
  defp sheet_title(:review), do: gettext("Review")
  defp sheet_title(:history), do: gettext("Versions")
  defp sheet_title(:translations), do: gettext("Translations")
  defp sheet_title(_sheet), do: ""

  # The prototype names the document being edited beside its state — "contact.heex · saved" reads as
  # a file, which is what a template is.
  # WHAT A CLASS CAN LAND ON. Only an element, a component or a slot carries attributes; a run of
  # text, an expression chip and both comment kinds are re-emitted verbatim by
  # `MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer`, which has nowhere to put a class — so every
  # override recorded against one was dropped on the way out and nothing on the canvas ever moved.
  # The panel offered the whole surface anyway, on `{@inner_content}` most of all: the one node every
  # layout has, and the first thing an author clicks.
  defp styleable?(%Node{} = node), do: Node.container?(node) and not raw_block?(node)
  defp styleable?(_node), do: false

  # A `<style>` or a `<script>` renders nothing the visitor sees, so it takes no styling — what it
  # takes is its attributes and a word on where its contents belong instead.
  defp raw_block?(%Node{kind: :tag, tag: tag}) when tag in ["style", "script"], do: true
  defp raw_block?(_node), do: false

  # And it says what CAN be done there instead, which is the half a hidden panel does not supply.
  defp unstyleable_note(%Node{kind: :text}),
    do:
      gettext(
        "A run of text takes no styling of its own — double-click it on the canvas to change the words."
      )

  defp unstyleable_note(%Node{kind: kind}) when kind in [:eex, :eex_block],
    do:
      gettext(
        "Dynamic content. What appears here is worked out when the page renders, so it carries no classes of its own."
      )

  defp unstyleable_note(%Node{tag: "style"}),
    do:
      gettext(
        "An inline style block. A class, this element's CSS box or a stylesheet does the same job, is cached, and needs no nonce."
      )

  defp unstyleable_note(%Node{tag: "script"}),
    do:
      gettext(
        "An inline script. It does not run after a live navigation and the security policy refuses it — behaviour belongs in a JS hook."
      )

  defp unstyleable_note(_comment),
    do: gettext("A comment renders nothing, so there is nothing to style.")

  defp raw_block_home(%Node{tag: "style"}), do: "/admin/dashboard/runtime/stylesheets"
  defp raw_block_home(%Node{tag: "script"}), do: "/admin/dashboard/runtime/js-hooks"

  defp raw_block_home_label(%Node{tag: "style"}), do: gettext("Open stylesheets")
  defp raw_block_home_label(%Node{tag: "script"}), do: gettext("Open JS hooks")

  # THE STATUS TRAVELS WITH THE LINK. An error page holds one template per status and the editor is
  # looking at exactly one of them, but the shareable URL carried no `?status=` — so
  # `MishkaCmsWeb.DraftPreviewLive` fell back to its default and the author previewing the 500 they
  # were editing was shown the 404. The offline page is an entry too, carried as `?status=offline`.
  # Every other section has one template and needs nothing.
  defp preview_href(section, draft, editor) do
    base = "/_preview/#{Drafts.preview_segment(section)}/#{draft.preview_token}"

    case editor_status(editor) do
      nil -> base
      status -> base <> "?status=#{status}"
    end
  end

  defp editor_status(%{status: status}) when is_integer(status) or status == :offline,
    do: status

  defp editor_status(_editor), do: nil

  # WHAT THE CHIP IS OFFERING TO LEAVE. "Live page" was written into the markup, so a layout, a
  # component and an error page all called their live record a page — in the one control whose whole
  # job is to say which document a save lands on. The section already names itself.
  defp live_label(section),
    do:
      gettext("Live %{section}",
        section: String.downcase(translate(Section.label(Section.normalize(section))))
      )

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

  # A RECORD AND AN ADDRESS. Without the first there is nothing to save to — the essentials step is
  # asking for these same two fields one layer up — and without the second there is nothing to ask.
  defp settable?(%{record: %{id: id}, section: section}) when is_binary(id),
    do: settings?(Section.normalize(section))

  defp settable?(_assigns), do: false

  defp seo_menu_description(:page),
    do: gettext("Search and share previews, tags and structured data")

  defp seo_menu_description(_tags_only), do: gettext("The tags every page on this layout carries")

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

  defp whitespace?(%Node{meta: %{whitespace?: true}}), do: true
  defp whitespace?(_node), do: false

  # How many are held BESIDE the ordinary selection. The bar counts them together, because "3
  # elements held" is what the reader sees on the canvas.
  defp marked_count(%MapSet{} = marked), do: MapSet.size(marked)
  defp marked_count(_none), do: 0

  # Only an http(s) address is offered. The value comes from a kit's own bundle, and a `javascript:`
  # in a link the admin renders is the one way a third-party kit could reach into this page.
  defp docs_url(%{doc_url: url}) when is_binary(url) do
    case MishkaCmsCore.Runtime.OriginValidator.web_url?(url) do
      true -> url
      false -> nil
    end
  end

  defp docs_url(_entry), do: nil

  # THE COMPONENT'S OWN EDITOR, AND THE WAY BACK TO THIS ONE. `return_to` is this document's builder,
  # which `Section.back_path/2` turns into the component editor's back link — without it, editing
  # what a page uses ended on the component list and the page had to be found all over again.
  #
  # `nil` where there is nowhere to go: an entry with no row behind it (a slot's declaration, lent by
  # its parent), or the document already open — a helper in a component's own prelude resolves to
  # that component, and a link to the editor the author is in would only reload it.
  #
  # AND `nil` WHERE THE EDITOR WOULD TURN THIS ACTOR AWAY. A shared component is every site's, so
  # `BuilderLive` refuses it to a tenant and lands them on the component list — without the page they
  # came from. A button that leads to a refusal is worse than no button, which is the rule
  # `PreviewHelpers` already keeps for the Visual Editor on the same rows. An entry that does not say
  # it is a site's own is treated as shared: only a master is sent to an editor nobody can vouch for.
  defp component_editor_path(%{id: id} = entry, %{resource_id: here} = editor, actor)
       when is_binary(id) and id != here do
    case editable_by?(entry, actor) do
      true -> Section.builder_path("component", id) <> return_to(editor)
      false -> nil
    end
  end

  defp component_editor_path(_entry, _editor, _actor), do: nil

  defp editable_by?(%{global?: false}, _actor), do: true
  defp editable_by?(_entry, %{site_id: nil}), do: true
  defp editable_by?(_entry, _actor), do: false

  # A document not saved yet has no address of its own to come back to, so it asks for none.
  defp return_to(%{resource_id: id, section: section, status: status}) when is_binary(id),
    do: "?" <> URI.encode_query(%{"return_to" => Section.builder_path(section, id, status)})

  defp return_to(_editor), do: ""

  defp held?(%{marked: %MapSet{} = marked}, id), do: MapSet.member?(marked, id)
  defp held?(_editor, _id), do: false

  defp folded?(%Node{} = node, %{hidden: %MapSet{} = hidden}), do: Node.hidden?(node, hidden)
  defp folded?(_node, _editor), do: false

  # The dynamic wrapper's own two attributes are not attributes of the component, so they are kept out
  # of the editable list and reported on their own, read-only.
  @wrapper_attrs ~w(component_name site)

  defp attr_rows(%Node{kind: :component, attrs: attrs} = node) do
    for {name, _value} <- attrs,
        is_binary(name),
        name not in @wrapper_attrs,
        do: attr_row(node, name)
  end

  defp attr_rows(%Node{attrs: attrs} = node) do
    for {name, _value} <- attrs, is_binary(name), do: attr_row(node, name)
  end

  # THE BOX HOLDS THE SOURCE, NOT THE BRACES AROUND IT. This list drew `phx-click={JS.toggle(…)}`
  # into an editable field, and the field posted the braces back as the value — so the stored source
  # became `{JS.toggle(…)}` and serialized to `phx-click={{JS.toggle(…)}}`. That is a one-tuple:
  # `Protocol.UndefinedError` where the page renders, and a `:if` condition that is truthy whatever
  # it was guarding, so an element hidden from signed-out visitors came back for everyone. Every
  # re-edit added another pair, and nothing between the field and the tree takes braces off again.
  #
  # `Node.attr_text/2` is the one reading of an attribute's text — the same one the property panel
  # asks, which is why that panel round-trips a binding and this list did not. The kind rides along
  # with the row so the write STATES it instead of leaving `Op` to re-read the tree for it.
  defp attr_row(node, name), do: {name, attr_kind(node, name), Node.attr_text(node, name)}

  # A bare attribute is offered as a string: typing into the empty box beside `disabled` is how it
  # becomes `disabled="true"`, where `:boolean` would throw away what was typed.
  defp attr_kind(node, name) do
    case Node.attr(node, name) do
      {:expr, _source} -> "expr"
      _string_or_bare -> "string"
    end
  end

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

  # The rail tabs carry a glyph each, like the palette's. A rail contributed by a plugin names its
  # own icon; the core's three are matched by key.
  defp rail_icon(%{icon: icon}) when is_binary(icon), do: icon_name(icon)
  defp rail_icon(%{key: "layers"}), do: :nav
  defp rail_icon(%{key: "assistant"}), do: :sparkle
  defp rail_icon(%{key: "audit"}), do: :shield
  defp rail_icon(_rail), do: :chevron

  # What kind of thing a layer row is, at a glance. The prototype gives every row an icon; here it
  # comes from the node's own kind rather than being authored per row.
  # Whether something may be DROPPED into this row.
  #
  # A plain tag takes children because HTML says so. A runtime component takes them only if it
  # declares a slot to put them in — 120 of the kit's 183 components do, and 82 of those name it
  # `inner_block`, which is Phoenix's own name for "whatever you write between the tags". A component
  # with no slot renders nothing you drop into it, so it is not a target and the tree does not
  # pretend otherwise. A slot is always a target: holding content is what a slot is.
  #
  # ASKED OF `Containment`, NOT ANSWERED HERE. This used to be its own reading of those rules and it
  # was a strictly narrower one — `entry != nil` made a palette row a requirement, so a component the
  # kit does not ship was a dead end no matter what it declared. The `<.form>` `FormPlacement` puts
  # around every loose field is exactly that: Phoenix declares its `inner_block`, the server accepts
  # drops into it, and the rail drew it as a row that takes nothing. `Containment` also counts a
  # component that ALREADY holds children, which no reading here ever did.
  #
  # The catalog is the one row this layer already resolved. `catalog_slots?/2` looks the component up
  # by name, and the row it would find is the row we have.
  defp drop_target?(node, entry),
    do: Containment.holds_children?(node, components: List.wrap(entry))

  @doc false
  # WHAT IS STILL MISSING, FOR EVERY ROW AT ONCE.
  #
  # A required property left blank refuses the Publish button (`BuilderLive.missing_required/1`) and
  # the rail said nothing about it, so the first anyone heard was a flash naming a field several rows
  # inside a component that may not even be open. `Inspector.unmet/3` is the one answer both take.
  #
  # Swept once for the whole tree rather than asked per row: this is O(nodes), where asking each row
  # about its own subtree would be O(nodes²) on a document that can be hundreds deep.
  #
  # `total` carries the subtree, which is what lets a SHUT component say that something inside it is
  # unfinished — the case the badge exists for. `attrs` and `slots` are this node's own, so the two
  # groups can each say how many of the number are theirs.
  def unmet_map(%Tree{} = tree, components) when is_list(components) do
    lookup = Map.new(components, &{&1.name, &1})

    Enum.reduce(tree.roots, %{}, fn root, acc ->
      acc |> roll_unmet(tree, root, lookup) |> elem(0)
    end)
  end

  def unmet_map(_tree, _components), do: %{}

  defp roll_unmet(acc, tree, id, lookup) do
    case Tree.get(tree, id) do
      nil ->
        {acc, 0}

      node ->
        {acc, beneath} =
          Enum.reduce(node.children, {acc, 0}, fn child, {acc, sum} ->
            {acc, count} = roll_unmet(acc, tree, child, lookup)
            {acc, sum + count}
          end)

        own = Inspector.unmet(node, tree, lookup)
        attrs = Enum.count(own, &match?({:attr, _name}, &1))
        slots = Enum.count(own, &match?({:slot, _name}, &1))
        total = attrs + slots + beneath

        {Map.put(acc, id, %{attrs: attrs, slots: slots, total: total}), total}
    end
  end

  # WHETHER THIS ROW IS SHUT OVER SOMETHING, which is what lets a drag open it on the way past.
  #
  # A tree of any depth is mostly shut — `default_expanded/1` opens the roots and one level below —
  # so a `<span>` four levels inside a `<p>` inside a `<div>` simply has no row to aim at, and the
  # only way to reach it was to let go of what you were holding, click your way down, and pick it up
  # again. The hook springs a shut row open after a dwell, and this is what tells it which rows are
  # worth waiting on: `nil` for a row with nothing under it at all, so the timer is never set for a
  # leaf.
  defp openness(assigns) do
    cond do
      not expandable?(assigns) -> nil
      MapSet.member?(assigns.expanded, assigns.id) -> "true"
      true -> "false"
    end
  end

  # A row opens when it has ANYTHING under it: children, properties, an unfilled slot, or a
  # component's own markup. The last one is checked without parsing — the parse only happens once the
  # row is actually open, and a chevron that depended on it could never appear.
  defp expandable?(%{kids: kids, node: node, ghosts: ghosts, props: props, entry: entry}) do
    kids != [] or ghosts != [] or props != [] or has_inside?(node, entry)
  end

  # WHAT THE PANEL WILL ACTUALLY DRAW. The indentation between two tags is a child like any other and
  # the rows have always hidden it, so counting it left a `div` announcing seven children above three
  # rows, and a chevron on a container that opens onto nothing.
  defp listed_children(%Node{children: children}, tree),
    do: Enum.reject(children, &whitespace?(Tree.get(tree, &1)))

  defp listed_children(_node, _tree), do: []

  defp has_inside?(%Node{kind: :component}, entry) when not is_nil(entry),
    do: is_binary(Map.get(entry, :template)) and Map.get(entry, :template) != ""

  defp has_inside?(_node, _entry), do: false

  # The component's own markup, parsed, so the tree can show what is in it without leaving the page.
  # Parsed only for a row that is open, because a page can carry a dozen components and none of their
  # internals matter until someone looks.
  defp component_inside(%Node{kind: :component}, entry, expanded, id) when not is_nil(entry) do
    with true <- MapSet.member?(expanded, id),
         template when is_binary(template) and template != "" <- Map.get(entry, :template),
         {:ok, tree} <- Tree.parse(template) do
      for root <- tree.roots, node = Tree.get(tree, root), node != nil, do: {node, tree}
    else
      _nothing -> []
    end
  end

  defp component_inside(_node, _entry, _expanded, _id), do: []

  # How many rows `.markup` will draw, so the heading can say so before it is opened — the same
  # promise `.properties` and `.slots` make. Whitespace between two tags is a node and is not a row,
  # which is why this counts what will be DRAWN rather than what is in the tree.
  defp inside_count(inside),
    do: Enum.reduce(inside, 0, fn {node, tree}, total -> total + drawn_rows(node, tree) end)

  defp drawn_rows(nil, _tree), do: 0

  defp drawn_rows(node, tree) do
    case whitespace?(node) do
      true -> 0
      false -> 1 + Enum.sum(Enum.map(node.children, &drawn_rows(Tree.get(tree, &1), tree)))
    end
  end

  # WHICH KIND OF SLOT THE GHOST WILL ADD, said before it is added rather than discovered after.
  #
  # "empty" and "add another" answer how MANY there are. They do not answer the question that
  # actually bites: thirteen of the kit's slots are read for their attributes and never rendered, so
  # adding one and putting something in it produces a row in the tree and nothing on the page.
  defp ghost_note(entry, slot, filled?) do
    cond do
      not filled? and required_slot?(entry, slot) -> gettext("required")
      not Inspector.renders_slot?(entry, slot) -> gettext("properties only")
      filled? -> gettext("add another")
      true -> gettext("empty")
    end
  end

  defp required_slot?(entry, slot) do
    entry
    |> Inspector.slots()
    |> Enum.any?(&(Inspector.name(&1) == slot and Inspector.required?(&1)))
  end

  # The badge names what is behind the number, so a count on a shut row is not a riddle. Two
  # sentences, because a row whose own properties are fine and whose CHILD is unfinished is the case
  # the badge mostly exists for, and "2 properties required here" would be a lie about where to look.
  defp needs_title(%{attrs: attrs, slots: slots, total: total}) do
    case Enum.reject([{attrs, :property}, {slots, :slot}], &(elem(&1, 0) == 0)) do
      [] ->
        ngettext(
          "%{count} required thing inside this is still empty",
          "%{count} required things inside this are still empty",
          total
        )

      here ->
        words =
          case here do
            [{count, kind}] ->
              needed_count(kind, count)

            [{first, first_kind}, {second, second_kind}] ->
              gettext("%{first} and %{second}",
                first: needed_count(first_kind, first),
                second: needed_count(second_kind, second)
              )
          end

        ngettext(
          "%{words} required here is still empty",
          "%{words} required here are still empty",
          attrs + slots,
          words: words
        )
    end
  end

  defp needed_count(:property, count),
    do: ngettext("%{count} property", "%{count} properties", count)

  defp needed_count(:slot, count), do: ngettext("%{count} slot", "%{count} slots", count)

  # WHAT AN EMPTY `.slots` GROUP MEANS, which is two different things.
  #
  # `Inspector.addable_slots/1` leaves out `inner_block`, because that is not a slot anybody adds —
  # it is whatever you write between the tags. So a component declaring only `inner_block` counted
  # zero and was told "this component takes no slots", which is the opposite of true: 69 of the
  # kit's 136 components are exactly that, they take content, the rail marks them as containers and
  # a drop into them lands. The line said the one thing that would stop an author trying.
  defp slots_note(entry) do
    case Enum.any?(Inspector.slots(entry), &Inspector.inner_block?/1) do
      true -> gettext("no named slots — what you drop in goes straight inside")
      false -> gettext("this component takes nothing inside")
    end
  end

  attr(:node, :any, required: true)
  attr(:tree, :any, required: true)
  attr(:depth, :integer, required: true)

  # One row of a component's INTERNALS. No drag handle, no delete, no click target: it is a window
  # into the component, and the ways to change it are on the component itself.
  defp inside_row(assigns) do
    ~H"""
    <div :if={!whitespace?(@node)}>
      <div
        class="flex items-center gap-2 rounded-[9px] py-[6px] pr-[9px] opacity-70"
        style={"padding-left:#{9 + @depth * 13}px"}
      >
        <span class="w-3.5 flex-none"></span>
        <span class="grid size-[15px] flex-none place-items-center text-[#a8a5a0]">
          <.icon name={layer_icon(@node)} size={12} />
        </span>
        <span class="min-w-0 flex-1 truncate font-['Space_Grotesk'] text-[11.5px] font-medium text-[#6d6a63]">
          {node_label(@node)}
        </span>
        <span
          :if={@node.children != []}
          class="flex-none font-['Space_Grotesk'] text-[10px] font-semibold text-[#a8a5a0]"
        >
          ({length(@node.children)})
        </span>
      </div>
      <.inside_row
        :for={child <- @node.children}
        node={Tree.get(@tree, child)}
        tree={@tree}
        depth={@depth + 1}
      />
    </div>
    """
  end

  # The palette entry behind a component node — what says which slots and properties it has.
  defp layer_entry(%Node{kind: :component} = node, _tree, editor),
    do: entry_named(Node.component_name(node), editor)

  # A slot borrows its parent component's entry: that is where its own declaration lives.
  defp layer_entry(%Node{kind: :slot, parent_id: parent_id}, tree, editor)
       when is_binary(parent_id) do
    case Tree.get(tree, parent_id) do
      %Node{kind: :component} = parent -> entry_named(Node.component_name(parent), editor)
      _other -> nil
    end
  end

  defp layer_entry(_node, _tree, _editor), do: nil

  defp entry_named(name, %{components: components}) when is_binary(name),
    do: Enum.find(components, &(&1.name == name))

  defp entry_named(_name, _editor), do: nil

  # Every property a component declares, with what this instance sets for it. A slot's properties come
  # from the slot's own declaration on the parent component, which is why the parent is looked up.
  defp layer_props(%Node{kind: :component} = node, entry, _tree) when not is_nil(entry),
    do:
      entry
      |> Inspector.grouped()
      |> Enum.flat_map(fn {_group, attrs} -> attrs end)
      |> prop_rows(node)

  # A slot's properties are declared on the component that owns it, so the parent's entry is what
  # says which they are. `layer_props/3` is given the parent's entry by the row above it.
  defp layer_props(%Node{kind: :slot} = node, entry, _tree) when not is_nil(entry) do
    name = Node.slot_name(node)

    entry
    |> Inspector.slots()
    |> Enum.find(&(Inspector.name(&1) == name))
    |> Inspector.attrs()
    |> prop_rows(node)
  end

  defp layer_props(_node, _entry, _tree), do: []

  defp prop_rows(attrs, node) do
    for attr <- attrs, name = Inspector.name(attr), not is_nil(name) do
      value = Node.attr_text(node, name)
      required? = Inspector.required?(attr)

      %{
        name: name,
        set?: !is_nil(value),
        required?: required?,
        missing?: required? and blank?(value),
        value: value || default_text(Inspector.default(attr)) || ""
      }
    end
  end

  @doc false
  # A DEFAULT IS NOT ALWAYS A WORD, and every control in this module used to assume it was.
  #
  # `chelekom-banner` declares `params` with a default of `%{kind: "banner"}`, which reaches here as
  # the bundle's encoded `%{"__atom_map__" => …}`. `to_string/1` on a map raises
  # `Protocol.UndefinedError`, and the raise is inside a render — so it did not show an error in the
  # panel, it killed the whole builder LiveView. The browser reconnected and remounted, which the
  # author sees as the canvas flashing and the inspector never opening.
  #
  # Seven components declare a map or list default this way: `banner`, `badge`, `toast`, `pagination`,
  # `flash`, `rating`, `simple-form`. It reached the author through EIGHT separate call sites — the
  # layers row, and every widget that shows the default as its placeholder — which is why this is one
  # function rather than a guard at each of them.
  #
  # `nil` means "nothing worth showing": a structured default has no one-line form, and the property
  # panel edits it through its own widget rather than through a text box.
  #
  # A BLANK DEFAULT IS NOT A DEFAULT WORTH NAMING, and treating it as one was visible. Several kit
  # attributes declare `default: ""` and derive their options from their helper clauses instead —
  # `chelekom-popover`'s `space` is one, and it is the component the question "how do I set this up"
  # was asked about. An empty string is truthy in Elixir, so the select's first option interpolated
  # it and read " (default)": a blank label, a stray space, and no way to tell it from a broken row.
  # It means exactly what "— default —" means, so it says that.
  def default_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _named -> value
    end
  end

  def default_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def default_text(value) when is_atom(value) and not is_nil(value), do: to_string(value)
  def default_text(_value), do: nil

  # Every slot the component declares, as `{name, already_there?}`. A Phoenix slot may be given more
  # than once — `slot :item` and three `<:item>` is ordinary — so a filled one keeps its row and
  # reads "add another" rather than disappearing. `inner_block` is not listed: it IS the inner
  # content, and a drop into the component lands there.
  defp addable_slots(%Node{kind: :component} = node, entry, tree) when not is_nil(entry) do
    filled = filled_slots(node, tree)

    entry
    |> Inspector.addable_slots()
    |> Enum.reject(&(Inspector.name(&1) == nil))
    |> Enum.map(fn slot ->
      name = Inspector.name(slot)
      {name, MapSet.member?(filled, name), slot_markup(slot)}
    end)
  end

  defp addable_slots(_node, _entry, _tree), do: []

  # WHAT `+ :source` ACTUALLY WRITES, which used to be `<:source></:source>` and nothing else.
  #
  # A slot declares attributes of its own, and eleven of the kit's slots declare REQUIRED ones. The
  # component reads them directly — `chelekom-video` does `src={source.src}` — so a bare slot is not
  # an empty slot, it is a missing key, and the page stopped rendering the instant the button was
  # pressed: "could not render — key :src not found". The one control in the editor whose whole job
  # is "add the thing this component asks for" was the one that broke the page.
  #
  # Every required attribute is written, using the value the kit declares as its default and an empty
  # one of the right shape when it declares none. Empty is not a guess about what the author wants —
  # it is the smallest thing that RENDERS, and the Inspector opens on the slot with those fields
  # ready to fill in. Optional attributes are left out: they are what the Inspector is for.
  defp slot_markup(slot) do
    name = Inspector.name(slot)

    attrs =
      slot
      |> Inspector.attrs()
      |> Enum.filter(&Inspector.required?/1)
      |> Enum.map_join("", &" #{Inspector.name(&1)}=#{attr_seed(&1)}")

    "<:#{name}#{attrs}></:#{name}>"
  end

  # Written the way HEEx takes it: a string in quotes, everything else in braces.
  defp attr_seed(attr) do
    case {Inspector.default(attr), Inspector.type(attr)} do
      {nil, "boolean"} -> "{false}"
      {nil, "integer"} -> "{0}"
      {nil, "float"} -> "{0.0}"
      {nil, "list"} -> "{[]}"
      {nil, _string} -> ~s("")
      {default, "string"} -> ~s("#{default}")
      {default, _other} -> "{#{inspect(default)}}"
    end
  end

  defp filled_slots(node, tree) do
    node.children
    |> Enum.map(&Tree.get(tree, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Node.slot_name/1)
    |> MapSet.new()
  end

  # `:item` when there is one, `:item 1` / `:item 2` when a component was given several — the number
  # is what tells two otherwise identical rows apart.
  #
  # Written the way the MARKUP writes it. These used to read `__item_slot_1`, which is the tree's own
  # bookkeeping: no author types that anywhere, and the rail's other slot rows now say `:item`, so
  # one screen had two names for one thing.
  defp slot_label(node, tree) do
    name = Node.slot_name(node) || "slot"
    siblings = same_named_slots(node, tree, name)

    case siblings do
      [_only] -> ":#{name}"
      many -> ":#{name} #{Enum.find_index(many, &(&1 == node.id)) + 1}"
    end
  end

  defp same_named_slots(node, tree, name) do
    case Tree.get(tree, node.parent_id) do
      nil ->
        [node.id]

      parent ->
        for id <- parent.children,
            child = Tree.get(tree, id),
            child != nil,
            child.kind == :slot,
            Node.slot_name(child) == name,
            do: id
    end
  end

  # "Delete <div> and the 12 elements inside it" — a branch is a lot to lose to a small button.
  defp delete_title(tree, id) do
    tree
    |> Tree.subtree(id)
    |> Tree.walk()
    |> Enum.count(&(!whitespace?(&1)))
    |> case do
      1 ->
        gettext("Delete this element")

      size ->
        ngettext(
          "Delete this element and the %{count} inside it",
          "Delete this element and the %{count} inside it",
          size - 1
        )
    end
  end

  defp layer_icon(%Node{kind: :text}), do: :text
  defp layer_icon(%Node{kind: :component}), do: :grid
  defp layer_icon(%Node{kind: :slot}), do: :layers
  defp layer_icon(%Node{kind: kind}) when kind in [:eex, :eex_block], do: :code
  defp layer_icon(%Node{kind: kind}) when kind in [:eex_comment, :html_comment], do: :comment
  defp layer_icon(%Node{tag: tag}) when tag in ~w(h1 h2 h3 h4 h5 h6 p span strong em), do: :text
  defp layer_icon(%Node{tag: tag}) when tag in ~w(a nav), do: :nav
  defp layer_icon(%Node{tag: tag}) when tag in ~w(img picture video figure), do: :image

  defp layer_icon(%Node{tag: tag}) when tag in ~w(button form input select textarea label),
    do: :form

  defp layer_icon(%Node{tag: tag}) when tag in ~w(table thead tbody tr td th), do: :table
  defp layer_icon(_node), do: :box

  # One template string serves both insertion gestures — the drag payload and the click-to-place
  # op — so the two can never disagree about what a palette card actually inserts.
  # THE SAME MARKUP A CLICK PRODUCES. A drag carries the template with it, so it has to go through
  # the site's preset too — otherwise dragging a Button and clicking it would place two different
  # buttons. See `MishkaCmsCore.Runtime.PageBuilder.Presets`.
  defp component_template(entry, site_name, presets, components),
    do: MishkaCmsCore.Runtime.PageBuilder.Presets.template(entry, site_name, presets, components)

  # The demo groups the palette under category headings with a count each, which is what makes 100+
  # components scannable; a flat grid is not. An installed extension's own components are one group
  # under its name, drawn before the categories.
  defp grouped_entries(entries) do
    entries
    |> Enum.group_by(&palette_group/1)
    |> Enum.sort_by(fn {group, [entry | _rest]} -> {not extension_group?(entry), group} end)
    |> Enum.map(fn {group, group_entries} -> {group, Enum.sort_by(group_entries, & &1.label)} end)
  end

  # The row is no longer one list: All is drawn first, the two browser-side chips sit right after it,
  # and the groups follow, the extensions' first — so this returns the groups WITHOUT "all".
  defp component_categories(components) do
    components
    |> Enum.uniq_by(&palette_group/1)
    |> Enum.sort_by(&{not extension_group?(&1), palette_group(&1)})
    |> Enum.map(&palette_group/1)
  end

  # The group a card is filed under: its extension's name, or its category — the builder sets
  # `group`, and an entry a plugin contributes carries its category alone.
  defp palette_group(entry), do: PaletteEntry.optional(entry, :group) || entry.type || "general"

  defp extension_group?(entry), do: PaletteEntry.optional(entry, :extension?) == true

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
      # A kit's own category, or an extension's name — `Blog` — translated where it has one.
      _named -> Gettext.gettext(MishkaCmsCore.Gettext, to_string(type))
    end
  end

  defp filter_palette(%{components: components, palette_query: query, palette_cat: cat}) do
    components
    |> Enum.filter(&(cat == "all" or palette_group(&1) == cat))
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

  # WHAT A FORM HOLDS WHILE IT IS BEING FILLED IN. A form with a `phx-change` is sent back through
  # that event when the page reconnects, and the page is drawn again from what the server then holds
  # — so the event stores the form's values under `typed:<form id>` (see the builder's handler), and
  # the input is drawn from them. `name` is the input's name as the form posts it (a list for
  # `attr[name]`); `default` is what it holds when nothing was typed.
  @doc false
  def typed_in(typed, form_id, name, default \\ "")

  def typed_in(typed, form_id, name, default) when is_map(typed) do
    case get_in(typed, [form_id | List.wrap(name)]) do
      value when is_binary(value) -> value
      _nothing -> default
    end
  end

  # The same for a box that already shows something stored: what was typed is kept only while the
  # stored text is still the text it was typed over (the form posts it as `base`), so an undo or a
  # control moving a line out of the box is not answered with the older text typed before it.
  @doc false
  def typed_over(typed, form_id, name, stored) when is_map(typed) do
    case get_in(typed, [form_id, "base"]) do
      ^stored -> typed_in(typed, form_id, name, stored)
      _moved_on -> stored
    end
  end

  attr(:text, :string, required: true, doc: "a `gettext_noop` sentence with a `%{name}` per part")

  attr(:parts, :map,
    required: true,
    doc: "`%{name => {tag, class, text}}`, drawn where `%{name}` stands in the sentence"
  )

  # A sentence with markup inside it, translated whole so a translation can put each part where its
  # own word order needs it.
  defp sentence(assigns) do
    assigns = assign(assigns, :pieces, sentence_pieces(assigns.text, assigns.parts))

    ~H"<.sentence_piece :for={piece <- @pieces} piece={piece} />"
  end

  attr(:piece, :any, required: true)

  defp sentence_piece(%{piece: text} = assigns) when is_binary(text), do: ~H"{@piece}"

  defp sentence_piece(%{piece: {tag, class, text}} = assigns) do
    assigns = assign(assigns, tag: tag, class: class, text: text)

    ~H"<.dynamic_tag tag_name={@tag} class={@class}>{@text}</.dynamic_tag>"
  end

  defp sentence_pieces(text, parts) do
    bindings = Map.new(parts, fn {name, _part} -> {name, "%{#{name}}"} end)
    by_name = Map.new(parts, fn {name, part} -> {to_string(name), part} end)

    MishkaCmsCore.Gettext
    |> Gettext.gettext(text, bindings)
    |> then(&Regex.split(~r/%\{\w+\}/, &1, include_captures: true, trim: true))
    |> Enum.map(fn piece ->
      with "%{" <> rest <- piece,
           {:ok, part} <- Map.fetch(by_name, String.trim_trailing(rest, "}")) do
        part
      else
        _plain -> piece
      end
    end)
  end

  @doc """
  The icon this panel draws for a descriptor's plain-string `icon`, so a plugin can name one without
  depending on this module's atoms. A name the set does not hold falls back to the chevron.
  """
  @spec icon_name(String.t() | nil) :: atom()
  def icon_name(name), do: Map.get(@icon_names, name, :chevron)

  defp drawer_source(%{code_tab: :html, tree: tree, selection: nil}),
    do: Serializer.serialize(tree)

  defp drawer_source(%{code_tab: :html, tree: tree, selection: id}),
    do: Serializer.serialize_node(tree, id)

  defp drawer_source(%{code_tab: :css, tree: tree, selection: id}), do: css_projection(tree, id)

  defp drawer_source(_assigns),
    do: gettext("This site's JavaScript hooks are managed under Runtime → JS hooks.")

  # The CSS pane is a projection of what the inspector has recorded, not a stylesheet: overrides
  # compile to Tailwind utilities on save (ADR-8), so this exists to be read, not to be applied.
  defp css_projection(tree, id) do
    case Tree.get(tree, id) do
      nil ->
        gettext("/* Select an element to see its recorded overrides. */")

      node ->
        node.meta
        |> Map.get(:styles, %{})
        |> Enum.map_join("\n\n", fn {bucket, props} -> bucket_rule(node, bucket, props) end)
        |> blank_to_note()
    end
  end

  # REAL CSS, NOT THE MAP WEARING CSS SYNTAX. `align` and `py` are the override map's own shorthand
  # and an enumerated value is a whole Tailwind class, so printing the map directly produced
  # `align: items-center` — a property no browser has. `Styles.declaration/2` owns the translation.
  #
  # `&` rather than the tag, because the tag was a lie: `header { … }` reads as a rule matching every
  # header on the page, and these overrides belong to one element. `&` is what the per-element CSS
  # editor will accept, so the projection and the editor speak the same language from the start.
  defp bucket_rule(_node, bucket, props) do
    body =
      Enum.map_join(props, "\n", fn {prop, value} ->
        {property, css_value} = Styles.declaration(prop, value)
        "  #{property}: #{css_value};"
      end)

    wrap_bucket(bucket, body)
  end

  defp wrap_bucket(bucket, body) when bucket in [:hover, :focus, :active],
    do: "&:#{bucket} {\n#{body}\n}"

  defp wrap_bucket(:tablet, body),
    do: "@media (max-width: 900px) {\n  & {\n  #{body}\n  }\n}"

  defp wrap_bucket(:mobile, body),
    do: "@media (max-width: 560px) {\n  & {\n  #{body}\n  }\n}"

  defp wrap_bucket(_bucket, body), do: "& {\n#{body}\n}"

  defp blank_to_note(""), do: gettext("/* No overrides recorded for this element. */")
  defp blank_to_note(css), do: css

  # Cheap, real checks over the server-side tree — the audit rail is honest from day one rather than
  # a score ring over nothing.
  # Real checks over the real tree, in the prototype's three groups. Each carries a severity, the
  # sentence a reader acts on, and the node it is about, so both the title and Fix can jump there.
  defp audit_findings(tree, record, editor) do
    nodes = Tree.walk(tree)

    issues =
      Events.collect(
        :audit_checks,
        Enum.flat_map(nodes, &node_findings/1) ++
          document_findings(nodes, editor) ++
          structure_findings(tree, editor) ++
          FormChecks.findings(tree, record, editor) ++
          seo_findings(record) ++ Demo.audit_findings()
      )

    issues ++
      passing_checks(
        nodes,
        issues,
        FormChecks.forms?(nodes, editor),
        %{outline?: outline_owned?(editor), seo?: seo_capable?(record)}
      ) ++
      performance_checks(editor)
  end

  # THE ONE CHECK THAT IS ABOUT WHAT THE DOCUMENT IS FOR. A layout exists to wrap a page, and it does
  # that through `@inner_content`; without it the layout renders perfectly and every page on it comes
  # out empty, which is the kind of breakage nobody looks for in the layout. Every other section has
  # nothing to answer here, so the group stays off their panel entirely — see `shown?/2`.
  defp structure_findings(tree, %{section: section}) do
    case Section.normalize(section) do
      "layout" -> [inner_content_finding(inner_content(tree))]
      _other -> []
    end
  end

  defp structure_findings(_tree, _editor), do: []

  defp inner_content(tree) do
    cond do
      LayoutSlot.renders_inner_content?(tree) -> true
      LayoutSlot.holds_inner_content?(tree) -> :hidden
      true -> false
    end
  end

  defp inner_content_finding(true),
    do:
      document_finding(
        :structure,
        :ok,
        "inner-content",
        gettext("The page renders inside this layout"),
        gettext("@inner_content is on the canvas, so pages wrapped in this layout keep theirs.")
      )

  defp inner_content_finding(:hidden),
    do:
      document_finding(
        :structure,
        :blocker,
        "inner-content",
        gettext("This layout renders no page"),
        gettext(
          "@inner_content is inside an element hidden from visitors — show it, or every page on this layout loses its content."
        )
      )

  defp inner_content_finding(false),
    do:
      document_finding(
        :structure,
        :blocker,
        "inner-content",
        gettext("This layout renders no page"),
        gettext(
          "Nothing renders @inner_content — publish this and every page on it loses its content."
        )
      )

  # SEO reads the page's OWN fields — `seo_tags`, `description` and `title` — so every line here is
  # about this record rather than about the markup in the canvas.
  #
  # WHICH IS THE WHOLE CONDITION FOR ASKING. `ErrorPage` and `Component` declare no `seo_tags` at
  # all, so the group used to ask a 404 for a meta description, an Open Graph image and a title
  # between 50 and 60 characters — none of which that record can hold, and the first of them is a
  # BLOCKER, so a perfectly good error page was the only red score ring in the editor. Asked of the
  # resource rather than of the section, because the resource is what actually knows.
  defp seo_findings(record) do
    case seo_capable?(record) do
      true -> seo_lines(record)
      false -> []
    end
  end

  defp seo_capable?(%resource{}),
    do: !is_nil(Ash.Resource.Info.attribute(resource, :seo_tags))

  defp seo_capable?(_record), do: false

  defp seo_lines(record) do
    tags = seo_tags(record)

    List.flatten([
      description_finding(meta_tag(tags, "description") || record_description(record)),
      og_finding(property_tag(tags, "og:image")),
      title_finding(record_title(record))
    ])
  end

  defp description_finding(nil),
    do: [
      document_finding(
        :seo,
        :blocker,
        "meta-description",
        gettext("Meta description missing"),
        gettext("No description set for this page.")
      )
    ]

  defp description_finding(_present), do: []

  defp og_finding(nil),
    do: [
      document_finding(
        :seo,
        :warning,
        "og-image",
        gettext("Open Graph image not set"),
        gettext("Add an og:image tag so link previews show a picture.")
      )
    ]

  defp og_finding(_present), do: []

  # 50–60 characters is the range a search result shows without truncating.
  defp title_finding(title) when is_binary(title) do
    length = String.length(title)

    case length in 50..60 do
      true -> []
      false -> [title_length_finding(length)]
    end
  end

  defp title_finding(:untitled), do: []

  defp title_finding(_missing),
    do: [
      document_finding(
        :seo,
        :blocker,
        "title",
        gettext("Page has no title"),
        gettext("A search result leads with the title; this page has none.")
      )
    ]

  defp title_length_finding(length) when length < 50,
    do:
      document_finding(
        :seo,
        :warning,
        "title-length",
        gettext("Title is short"),
        ngettext(
          "%{count} character — a search result shows 50–60.",
          "%{count} characters — a search result shows 50–60.",
          length
        )
      )

  defp title_length_finding(length),
    do:
      document_finding(
        :seo,
        :warning,
        "title-length",
        gettext("Title is long"),
        ngettext(
          "%{count} character — a search result truncates past 60.",
          "%{count} characters — a search result truncates past 60.",
          length
        )
      )

  # The one performance number this editor can actually measure: the site's compiled stylesheet, the
  # thing every page on it pays for.
  #
  # TODO: the rest of the prototype's performance panel — render-blocking scripts, image weight, the
  # per-template JS bundle — needs the compiled asset manifest per template, which the runtime does
  # not expose yet. Wire them here when it does.
  @css_budget 60_000

  # The site's own sheet plus the shared base, because that is what a visitor downloads. A component
  # or layout being edited has no site of its own, and then the base is the whole of it.
  defp performance_checks(%{site_name: site}) do
    ["__shared_base__", site]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&AssetsState.get_value(&1, "css"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&byte_size/1)
    |> Enum.sum()
    |> bundle_checks()
  end

  defp performance_checks(_editor), do: []

  defp bundle_checks(0), do: []
  defp bundle_checks(bytes), do: [bundle_finding(bytes)]

  defp bundle_finding(bytes) when bytes <= @css_budget,
    do:
      document_finding(
        :performance,
        :ok,
        "bundle",
        gettext("Bundle %{size}", size: kb(bytes)),
        gettext("Under the %{size} budget for this template.", size: kb(@css_budget))
      )

  defp bundle_finding(bytes),
    do:
      document_finding(
        :performance,
        :warning,
        "bundle",
        gettext("Bundle %{size}", size: kb(bytes)),
        gettext("Over the %{size} budget — every page on this site loads it.",
          size: kb(@css_budget)
        )
      )

  defp kb(bytes), do: "#{Float.round(bytes / 1000, 0) |> trunc()} KB"

  defp document_finding(group, severity, rule, message, detail) do
    %{
      node_id: nil,
      group: group,
      severity: severity,
      rule: rule,
      message: message,
      detail: detail
    }
  end

  defp seo_tags(%{seo_tags: tags}) when is_list(tags), do: tags
  defp seo_tags(_record), do: []

  defp record_description(%{description: description}) when is_binary(description),
    do: presence(description)

  defp record_description(_record), do: nil

  # `<title>` reads a page's `title`. A record without one — a layout — names no tab and is not asked.
  defp record_title(%{title: title}) when is_binary(title), do: presence(title)
  defp record_title(%{title: _missing}), do: nil
  defp record_title(_untitled), do: :untitled

  defp presence(""), do: nil
  defp presence(value), do: value

  defp meta_tag(tags, name), do: find_tag(tags, "name", name)
  defp property_tag(tags, property), do: find_tag(tags, "property", property)

  defp find_tag(tags, key, value) do
    Enum.find_value(tags, fn tag ->
      attrs = Map.get(tag, :attrs) || Map.get(tag, "attrs") || %{}
      content = Map.get(tag, :content) || Map.get(tag, "content")

      case Map.get(attrs, key) == value or Map.get(attrs, String.to_atom(key)) == value do
        true -> presence(to_string(content || ""))
        false -> nil
      end
    end)
  end

  # What PASSED, which is the other half of an audit: the prototype lists these in green under each
  # group, and without them a healthy group says "nothing to report" — which reads as "not checked".
  # Each one is a real check over the real document, and only appears when nothing in its group
  # contradicts it.
  defp passing_checks(nodes, issues, forms?, asks) do
    failed = MapSet.new(issues, & &1.rule)
    headings? = asks.outline? and Enum.any?(nodes, &(&1.tag in ~w(h1 h2 h3 h4 h5 h6)))

    [
      {:accessibility, "img-alt", gettext("Every image has alt text"),
       gettext("Screen readers have something to announce."),
       Enum.any?(nodes, &(&1.tag == "img"))},
      {:accessibility, "link-text", gettext("Interactive elements are labelled"),
       gettext("Every link and button has visible text."),
       Enum.any?(nodes, &(&1.tag in ~w(a button)))},
      {:accessibility, "heading-skip", gettext("Heading order is sound"),
       gettext("No level is skipped on the way down."), headings?},
      {:forms, "field-form", gettext("Every field is inside a form"),
       gettext("What the visitor types has somewhere to go."), forms?},
      {:forms, "form-destination", gettext("Every form reaches a handler"),
       gettext("A submission is received rather than discarded."), forms?},
      {:forms, "form-scope", gettext("Each form has a name of its own"),
       gettext("One form's values never land in another's."), forms?},
      {:seo, "no-h1", gettext("Page opens at h1"),
       gettext("The outline starts where a search result does."), headings? and asks.seo?}
    ]
    |> Enum.filter(fn {_group, rule, _message, _detail, applicable?} ->
      applicable? and not related_failure?(failed, rule)
    end)
    |> Enum.map(fn {group, rule, message, detail, _applicable?} ->
      %{
        node_id: nil,
        group: group,
        severity: :ok,
        rule: "ok-" <> rule,
        message: message,
        detail: detail
      }
    end)
  end

  # `img-alt` and `img-alt-empty` are the same check reported two ways, and either one means the
  # "every image has alt text" line has not earned its tick.
  defp related_failure?(failed, "img-alt"),
    do: MapSet.member?(failed, "img-alt") or MapSet.member?(failed, "img-alt-empty")

  defp related_failure?(failed, "link-text"),
    do: MapSet.member?(failed, "link-text") or MapSet.member?(failed, "button-text")

  defp related_failure?(failed, "no-h1"),
    do: MapSet.member?(failed, "no-h1") or MapSet.member?(failed, "no-heading")

  # A field with no name has nowhere for its value to go either, so it withdraws the same tick a
  # field with no form does.
  defp related_failure?(failed, "field-form"),
    do: any_failed?(failed, ~w(field-no-form field-no-key field-name-shadow))

  defp related_failure?(failed, "form-destination"),
    do: any_failed?(failed, ~w(form-no-destination))

  defp related_failure?(failed, "form-scope"),
    do:
      any_failed?(
        failed,
        ~w(form-no-as form-no-source form-duplicate-seed form-duplicate-source form-duplicate-token)
      )

  defp related_failure?(failed, rule), do: MapSet.member?(failed, rule)

  @doc """
  The DOM id of one finding's Fix button.

  A rule is not a finding. `field-no-form` fires once per loose field and `form-no-destination` once
  per form, so naming the button after the rule alone put two elements with one id in the document as
  soon as a page had two forms — reached on a stock install in three clicks. A duplicate id makes
  `document.getElementById` answer whichever came first, so the second row's Fix drove the first
  row's node.

  A document-level finding carries no node and there is at most one of it, so the rule alone is
  already unique there and the id it has always had is kept. `data-rule` is on every button either
  way, for anything that wants to find them by rule rather than by finding.
  """
  @spec fix_id(map()) :: String.t()
  def fix_id(%{rule: rule, node_id: nil}), do: "pb-audit-fix-#{rule}"
  def fix_id(%{rule: rule, node_id: node_id}), do: "pb-audit-fix-#{rule}-#{node_id}"

  defp any_failed?(failed, rules), do: Enum.any?(rules, &MapSet.member?(failed, &1))

  defp node_findings(%Node{tag: "img"} = node) do
    case Node.attr_text(node, "alt") do
      nil ->
        [
          finding(
            node,
            :accessibility,
            :blocker,
            "img-alt",
            gettext("Image missing alt text"),
            gettext(
              "This image has no alt attribute, so a screen reader has nothing to announce."
            )
          )
        ]

      "" ->
        [
          finding(
            node,
            :accessibility,
            :warning,
            "img-alt-empty",
            gettext("Image alt text is empty"),
            gettext(
              "An empty alt is only right for decoration. Describe it, or say so deliberately."
            )
          )
        ]

      _described ->
        []
    end
  end

  defp node_findings(%Node{tag: "a", children: []} = node) do
    [
      finding(
        node,
        :accessibility,
        :blocker,
        "link-text",
        gettext("Link has no visible text"),
        gettext("A link with nothing inside it is announced as a bare URL.")
      )
    ]
  end

  defp node_findings(%Node{tag: "button", children: []} = node) do
    [
      finding(
        node,
        :accessibility,
        :blocker,
        "button-text",
        gettext("Button has no label"),
        gettext("A control with no text has nothing to announce and nothing to read.")
      )
    ]
  end

  defp node_findings(%Node{tag: "html"} = node) do
    [
      finding(
        node,
        :performance,
        :blocker,
        "nested-html",
        gettext("A template should not contain <html>"),
        gettext("The layout already provides the document shell; a second one is invalid.")
      )
    ]
  end

  defp node_findings(_node), do: []

  # Checks about the page as a whole rather than about one element.
  # THE OUTLINE IS NOT A FRAGMENT'S TO OWN. A layout's headings are its site name and its footer
  # labels; the page's own h1 and h2 land between them at runtime, through `@inner_content`. So the
  # `h1 → h3` a layout reads as on its own is a gap the page fills, and reporting it is a certainty
  # this rail does not have — every seeded layout carried the warning. A component is a fragment for
  # the same reason. A page and an error page are whole documents and keep the checks.
  defp document_findings(nodes, editor) do
    case outline_owned?(editor) do
      true -> outline_findings(nodes)
      false -> []
    end
  end

  # A page and an error page are whole documents. A layout and a component are pieces of one, and
  # the outline they read as on their own is not theirs — which withholds the green tick as well as
  # the warning: "no level is skipped" is a claim about a document this rail is only holding half of.
  defp outline_owned?(%{section: section}),
    do: Section.normalize(section) not in ["layout", "component"]

  defp outline_owned?(_editor), do: true

  defp outline_findings(nodes) do
    headings =
      nodes
      |> Enum.filter(&(&1.tag in ~w(h1 h2 h3 h4 h5 h6)))
      |> Enum.map(&{&1, &1.tag |> String.trim_leading("h") |> String.to_integer()})

    heading_findings(headings) ++ title_findings(headings)
  end

  # h1 → h3 skips a level, and the heading order is the outline a screen reader navigates by.
  defp heading_findings(headings) do
    headings
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{_previous, from}, {node, to}] ->
      case to - from > 1 do
        true ->
          [
            finding(
              node,
              :accessibility,
              :warning,
              "heading-skip",
              gettext("Heading order skips a level"),
              gettext("h%{from} is followed directly by h%{to}.", from: from, to: to)
            )
          ]

        false ->
          []
      end
    end)
  end

  defp title_findings([]) do
    [
      %{
        node_id: nil,
        group: :seo,
        severity: :warning,
        rule: "no-heading",
        message: gettext("Page has no heading"),
        detail: gettext("Search results and screen readers both lead with the first heading.")
      }
    ]
  end

  defp title_findings([{node, level} | _rest]) when level > 1 do
    [
      finding(
        node,
        :seo,
        :warning,
        "no-h1",
        gettext("Page does not start with an h1"),
        gettext("The first heading is h%{level}; a page should open at the top level.",
          level: level
        )
      )
    ]
  end

  defp title_findings(_headings), do: []

  defp finding(node, group, severity, rule, message, detail) do
    %{
      node_id: node.id,
      group: group,
      severity: severity,
      rule: rule,
      message: message,
      detail: detail
    }
  end

  # A blocker costs more than a warning, and the score stays a number so the ring can sweep to it.
  defp audit_score([]), do: 100

  defp audit_score(findings) do
    penalty =
      Enum.reduce(findings, 0, fn
        %{severity: :blocker}, total -> total + 12
        %{severity: :warning}, total -> total + 6
        _ok, total -> total
      end)

    max(0, 100 - penalty)
  end

  # A MODULE, resolved by identity rather than by name. The event carries `inspect(library)` because
  # that is what survives a round trip through the DOM, and turning it back with
  # `String.to_existing_atom/1` would be taking a module name from a client. Matching against the
  # registered list can only ever yield a library that is already installed.
  defp library_module(nil), do: nil

  defp library_module(chosen) when is_binary(chosen),
    do: Enum.find(Icons.libraries(), &(inspect(&1) == chosen))

  defp library_module(chosen) when is_atom(chosen), do: chosen
end
