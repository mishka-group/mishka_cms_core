defmodule MishkaCmsCore.Runtime.PageBuilder.OpenCommandTest do
  @moduledoc """
  A component says how it is opened, and a click aimed at it runs that.

  ## What was wrong

  "Show" pointed at a dialog compiled to `JS.show(to: ".pb-xxxxxxxx")`. That sets `display` on the
  one element carrying the class and does nothing else — and the kit's modal is `hidden` on its ROOT
  and `hidden` again on the panel a level down, with the backdrop in between carrying no `hidden` at
  all. Revealing the root therefore painted a full-page backdrop over the page and showed no dialog:
  measured on a real page, root `display: block`, backdrop 720px tall, dialog `display: none`,
  height 0.

  For most of the others it was worse than half-right — it was nothing. A drawer is fully displayed
  and held off-screen by `-translate-x-full`; a dropdown, an accordion and a collapse are opened by
  a JavaScript hook; a navbar wants a class toggled on the very element the click already points at.
  Their roots were never `display:none`, and LiveView's `show` returns early on an element that is
  already visible.

  ## The shape of the answer

  Not a longer list of special cases in the editor — the editor cannot know, and the next kit will
  be different again. The component declares its own command as an attribute on its root, and the
  click executes it:

      <div id={@id} data-pb-open={show_modal(@id)} data-pb-close={hide_modal(@id)}>

      <button phx-click={JS.exec("data-pb-open", to: ".pb-xxxxxxxx")}>

  The kit invented this before we did: `chelekom-mega-menu` already carries `phx-open-mega` on its
  root and runs it from its own trigger with `JS.exec/2`. This gives that pattern a name the builder
  knows, and leaves every component that declares nothing exactly as it was.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @moduletag :unit

  @declaring ~S|<div id={@id} data-pb-open={show_modal(@id)} data-pb-close={hide_modal(@id)}>Body</div>|
  @kit_modal ~S|<div id={@id} class={["relative z-50 hidden", @class]}><div role="dialog" aria-modal="true">Body</div></div>|

  describe "what a component declares" do
    test "both verbs are read off its root" do
      assert PaletteEntry.opens(%{"template" => @declaring}) ==
               %{"show" => "data-pb-open", "hide" => "data-pb-close"}
    end

    test "a component that says nothing declares nothing" do
      assert PaletteEntry.opens(%{"template" => @kit_modal}) == %{}
      assert PaletteEntry.opens(%{"template" => nil}) == %{}
      assert PaletteEntry.opens(%{}) == %{}
    end

    # THE SCOPE CLASS LANDS ON THE ROOT, so `JS.exec(attr, to: ".pb-xxxxxxxx")` reads the attribute
    # from the root and nowhere else. Reporting a declaration the click can never reach would trade
    # a command that does nothing for a command that does nothing loudly.
    test "a declaration on a child is not one this editor can reach" do
      inner = ~S|<div id={@id}><section data-pb-open={open_it(@id)}>Body</section></div>|

      assert PaletteEntry.opens(%{"template" => inner}) == %{}
    end

    test "an unparseable template costs the declaration, not the palette" do
      assert PaletteEntry.opens(%{"template" => ~S|<div data-pb-open={oops(</div>|}) == %{}
    end

    test "the toggle verb is declarable on its own" do
      navbar = ~S|<nav id={@id} data-pb-toggle={JS.toggle_class("show-nav-menu")}>Menu</nav>|

      assert PaletteEntry.opens(%{"template" => navbar}) == %{"toggle" => "data-pb-toggle"}
    end
  end

  # A DECLARATION IS ALSO THE ANSWER TO "DOES THIS RENDER CLOSED", and a better one than the markup
  # scan: the scan is a guess about what a `hidden` in a class list means, and this is the component
  # saying so. It wins; the guess stays for the hundred and thirty-six written before there was
  # anything to say it with.
  describe "declaring an opener says the component renders closed" do
    test "even when its markup hides nothing the scan would recognise" do
      plain = ~S|<div id={@id} data-pb-open={open_it(@id)}>Body</div>|

      refute PaletteEntry.concealed?(%{"template" => ~s(<div class="p-2">Body</div>)})
      assert PaletteEntry.concealed?(%{"template" => plain})
    end

    # A FLOATING PANEL IS ITS OWN COMPONENT. A dropdown's content, a popover's and a tooltip's are
    # each dropped separately, and each hides itself with a bare `hidden` and nothing else the scan
    # recognised — the dialog role, the click-away and the keydown all live on the PARENT. So the
    # panel never counted as concealed, never got the overlay wrapper the canvas reveals through,
    # and an author who selected one saw a trigger and no panel: "we cannot add any content inside".
    test "a floating content panel counts, on the kit's own marker" do
      panel =
        ~S|<div class="hidden" data-floating-content role="menu">{render_slot(@inner_block)}</div>|

      assert PaletteEntry.concealed?(%{"template" => panel})
    end

    # AND A HIDDEN FORM CONTROL STILL DOES NOT. Half the kit hides something: a checkbox hides its
    # real `<input>` behind a drawn box. Counting those is what the second signal exists to prevent.
    test "a hidden input is still not an overlay" do
      refute PaletteEntry.concealed?(%{
               "template" => ~S|<input type="checkbox" class="hidden" id={@id} />|
             })
    end

    test "and a component with neither is still not concealed" do
      refute PaletteEntry.concealed?(%{"template" => ~s(<p class="text-sm">Hello</p>)})
    end

    test "the inference is untouched for everything that declares nothing" do
      assert PaletteEntry.concealed?(%{"template" => @kit_modal})
    end
  end

  describe "what the click compiles to" do
    test "a declared verb runs the component's own command" do
      opener = %{"show" => "data-pb-open", "hide" => "data-pb-close"}

      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener}) ==
               ~s|JS.exec("data-pb-open", to: ".pb-bbbb2222")|

      assert Interactions.source("hide", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener}) ==
               ~s|JS.exec("data-pb-close", to: ".pb-bbbb2222")|
    end

    # A COMPONENT DECLARING "OPEN" HAS NOT DECLARED "TOGGLE", and the plain verb is not a safe
    # substitute: `JS.toggle` on a dialog reveals its root, which paints a `fixed inset-0` backdrop
    # over the page and leaves the dialog hidden a level down. Refused — see the describe below.
    test "a verb the component did not declare is refused, not substituted" do
      refute Interactions.source("toggle", "pb-aaaa1111", %{
               target: "pb-bbbb2222",
               opener: %{
                 "show" => "data-pb-open"
               }
             })
    end

    test "a component that declares nothing compiles exactly as it did before" do
      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: %{}}) ==
               ~s|JS.show(to: ".pb-bbbb2222")|

      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222"}) ==
               ~s|JS.show(to: ".pb-bbbb2222")|
    end

    test "an action carrying a class is class work, not opening work" do
      opener = %{"show" => "data-pb-open", "toggle" => "data-pb-toggle"}

      assert Interactions.source("toggle_class", "pb-aaaa1111", %{
               class: "is-open",
               target: "pb-bbbb2222",
               opener: opener
             }) ==
               ~s|JS.toggle_class("is-open", to: ".pb-bbbb2222")|
    end

    # THE MAP ARRIVES FROM SOMEBODY ELSE'S MARKUP and is about to be written into generated source.
    # A verb answers only with the attribute this module names for it — and a component that
    # declared SOMETHING has still said it does not open the ordinary way, so the plain verb is not
    # the answer either. Nothing is written.
    test "an attribute this editor did not name is refused" do
      refute Interactions.source("show", "pb-aaaa1111", %{
               target: "pb-bbbb2222",
               opener: %{"show" => "onclick"}
             })
    end
  end

  # THE VERB LIST IS PART OF THE CONTRACT. A verb the target cannot honour does not fail quietly — it
  # writes a command that runs and does the wrong visible thing, which is how "Show or hide" aimed at
  # a dialog put a full-page backdrop over a page with no dialog under it.
  describe "which verbs a target is offered" do
    test "a component that declares open and close is not offered a toggle" do
      offered = Interactions.actions(%{"show" => "data-pb-open", "hide" => "data-pb-close"})
      verbs = Enum.map(offered, &elem(&1, 0))

      assert "show" in verbs
      assert "hide" in verbs
      refute "toggle" in verbs
    end

    test "a component that declares only a toggle is not offered show or hide" do
      verbs =
        %{"toggle" => "data-pb-toggle"} |> Interactions.actions() |> Enum.map(&elem(&1, 0))

      assert "toggle" in verbs
      refute "show" in verbs
      refute "hide" in verbs
    end

    test "the class actions are offered whatever the target is" do
      for opener <- [%{}, %{"show" => "data-pb-open"}, %{"toggle" => "data-pb-toggle"}] do
        verbs = opener |> Interactions.actions() |> Enum.map(&elem(&1, 0))

        assert "toggle_class" in verbs
        assert "add_class" in verbs
        assert "remove_class" in verbs
      end
    end

    test "a target that declares nothing is offered every one, exactly as before" do
      assert Interactions.actions(%{}) == Interactions.actions()
      assert length(Interactions.actions()) == 7
    end

    # THE BACKSTOP. The panel does not offer the verb, but a form rendered before it knew the target
    # can still post one, and falling through to the plain command is the bug this exists to stop.
    test "and a verb it cannot honour is refused rather than guessed at" do
      opener = %{"show" => "data-pb-open", "hide" => "data-pb-close"}

      refute Interactions.source("toggle", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener})

      assert Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener}) ==
               ~s|JS.exec("data-pb-open", to: ".pb-bbbb2222")|
    end

    test "a target that declares nothing still gets the plain verb" do
      assert Interactions.source("toggle", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: %{}}) ==
               ~s|JS.toggle(to: ".pb-bbbb2222")|
    end
  end

  describe "reading it back" do
    test "the panel sees the verb the author picked, not hand-written code" do
      written = {:expr, ~s|JS.exec("data-pb-open", to: ".pb-bbbb2222")|}

      assert Interactions.read(written) == {:ok, "show", %{}}
      assert Interactions.target(written) == "pb-bbbb2222"
    end

    test "close reads back as hide, and toggle as toggle" do
      assert Interactions.read({:expr, ~s|JS.exec("data-pb-close", to: ".pb-x")|}) ==
               {:ok, "hide", %{}}

      assert Interactions.read({:expr, ~s|JS.exec("data-pb-toggle", to: ".pb-x")|}) ==
               {:ok, "toggle", %{}}
    end

    # SOMEBODY ELSE'S `JS.exec` IS STILL SOMEBODY ELSE'S. The kit's own dialogs carry
    # `phx-click={JS.exec("data-cancel", to: "#id")}` on their close button; reading that as one of
    # these six verbs would offer to rewrite a command this editor did not write.
    test "an exec of anything else is left alone as custom" do
      assert Interactions.read({:expr, ~s|JS.exec("data-cancel", to: "#modal")|}) == :custom
      assert Interactions.read({:expr, ~s|JS.exec("phx-remove", to: ".pb-x")|}) == :custom
    end

    test "a full round trip through source and back" do
      opener = %{"show" => "data-pb-open"}

      source =
        Interactions.source("show", "pb-aaaa1111", %{target: "pb-bbbb2222", opener: opener})

      assert Interactions.read({:expr, source}) == {:ok, "show", %{}}
      assert Interactions.target({:expr, source}) == "pb-bbbb2222"
    end
  end

  # WHAT THE PANEL OFFERS AS A TARGET. Not "does this render closed" — that is the layers glyph's
  # question, and a generous answer there costs a glyph. Here a generous answer costs the author a
  # control that says "Click action set." and then does nothing on the page.
  describe "the target list" do
    setup do
      {:ok, tree} =
        Tree.parse("""
        <div>
          <button>Open</button>
          <.component component_name="acme-dialog" site="Global" id="a"></.component>
          <.component component_name="acme-tabs" site="Global" id="b"></.component>
        </div>
        """)

      by_name =
        tree
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :component))
        |> Map.new(&{Node.component_name(&1), &1})

      assert map_size(by_name) == 2,
             "the fixture did not parse as components: #{inspect(by_name)}"

      {:ok, tree: tree, dialog: by_name["acme-dialog"], tabs: by_name["acme-tabs"]}
    end

    defp editor(tree, entries), do: %{tree: tree, components: entries}

    @declares %{name: "acme-dialog", opens: %{"show" => "data-pb-open"}}
    @conceals %{name: "acme-tabs", concealed?: true, opens: %{}}

    test "offers a component that declares an opener", %{tree: tree, dialog: dialog} do
      assert [{id, _label, _scope}] = Panels.openable(editor(tree, [@declares]))
      assert id == dialog.id
    end

    test "does not offer one that only renders closed", %{tree: tree} do
      assert Panels.openable(editor(tree, [@conceals])) == []
    end

    test "offers the declaring one and skips the concealing one, side by side", %{
      tree: tree,
      dialog: dialog
    } do
      assert [{id, _label, _scope}] = Panels.openable(editor(tree, [@declares, @conceals]))
      assert id == dialog.id
    end

    test "a component the palette does not know is not offered", %{tree: tree} do
      assert Panels.openable(editor(tree, [])) == []
    end
  end

  # THE KIT ITSELF, because a contract nothing ships against is a contract that has never run. These
  # read the JSON the installer seeds from rather than a fixture, so a template edit that drops the
  # declaration fails here rather than in somebody's page.
  describe "the components that ship a declaration" do
    setup do
      path =
        Application.app_dir(:mishka_cms_core, "priv/cms_ui_kits/chelekom.json")

      kit =
        case File.read(path) do
          {:ok, raw} -> Jason.decode!(raw)
          {:error, _missing} -> %{"components" => []}
        end

      {:ok, by_name: Map.new(kit["components"] || [], &{&1["name"], &1})}
    end

    test "the modal, the drawer and the sidebar name their own helpers", %{by_name: by_name} do
      for name <- ~w(chelekom-modal chelekom-drawer chelekom-sidebar) do
        component = Map.fetch!(by_name, name)

        assert PaletteEntry.opens(component) ==
                 %{"show" => "data-pb-open", "hide" => "data-pb-close"},
               "#{name} lost its declaration"

        helpers = Enum.map(component["helpers"] || [], & &1["name"])

        for verb <- ~w(show hide) do
          helper = String.replace_prefix(name, "chelekom-", "#{verb}_")

          assert helper in helpers,
                 "#{name} declares #{verb} but ships no #{helper}/1"
        end
      end
    end

    test "the three that open by toggling a class they own declare the toggle", %{
      by_name: by_name
    } do
      for name <- ~w(chelekom-navbar chelekom-mega-menu chelekom-speed-dial) do
        assert PaletteEntry.opens(Map.fetch!(by_name, name)) == %{"toggle" => "data-pb-toggle"},
               "#{name} lost its declaration"
      end
    end

    test "the five opened by a hook declare all three", %{by_name: by_name} do
      for name <- ~w(chelekom-dropdown chelekom-popover chelekom-tooltip
                     chelekom-accordion chelekom-collapse) do
        assert PaletteEntry.opens(Map.fetch!(by_name, name)) ==
                 %{
                   "show" => "data-pb-open",
                   "hide" => "data-pb-close",
                   "toggle" => "data-pb-toggle"
                 },
               "#{name} lost its declaration"
      end
    end

    # THE HALF THAT CANNOT BE READ OFF THE TEMPLATE. A hook method is not a `JS` command, so those
    # five declare a `JS.dispatch` and the hook listens for it — two files, one contract, and
    # nothing at either end fails loudly when they drift. A component dispatching an event nothing
    # listens for is a button that does nothing, which is the exact failure this whole change is
    # about.
    test "every event a component dispatches is one a shipped hook answers", %{by_name: by_name} do
      listened = MapSet.new(hook_events())

      dispatched =
        for {name, component} <- by_name,
            opens = PaletteEntry.opens(component),
            opens != %{},
            event <- dispatched_events(component["template"]),
            do: {name, event}

      assert dispatched != [], "no component dispatches anything — the contract is not shipping"

      for {name, event} <- dispatched do
        assert MapSet.member?(listened, event),
               "#{name} dispatches #{event}, which no shipped hook listens for"
      end
    end

    # The exporter stamps the kit's prefix onto a hook name on the way out — `Floating` in the
    # component's own source is the row `chelekom-floating`, which `format_hook_name/2` rebuilds as
    # `GlobalChelekomFloating` — so this reads the shipped name.
    test "the hooks that answer are the ones those components mount", %{by_name: by_name} do
      for name <- ~w(chelekom-dropdown chelekom-popover chelekom-tooltip) do
        assert Map.fetch!(by_name, name)["template"] =~ ~s(phx-hook="GlobalChelekomFloating")
      end

      for name <- ~w(chelekom-accordion chelekom-collapse) do
        assert Map.fetch!(by_name, name)["template"] =~ ~s(phx-hook="GlobalChelekomCollapsible")
      end
    end

    # AND NOBODY ELSE, YET. What is left is opened per-ITEM (a tab panel, a carousel slide): "open
    # this" is not a whole sentence for them without naming which one, and a control that silently
    # picks for the author is worse than no control.
    test "every declaration in the kit is one of the three attributes", %{by_name: by_name} do
      declared =
        by_name
        |> Enum.map(fn {name, component} -> {name, PaletteEntry.opens(component)} end)
        |> Enum.reject(fn {_name, opens} -> opens == %{} end)
        |> Map.new()

      assert declared |> Map.keys() |> Enum.sort() ==
               ~w(chelekom-accordion chelekom-collapse chelekom-drawer chelekom-dropdown
                  chelekom-mega-menu chelekom-modal chelekom-navbar chelekom-popover
                  chelekom-sidebar chelekom-speed-dial chelekom-tooltip)

      for {name, opens} <- declared, {verb, attribute} <- opens do
        assert Interactions.openers()[verb] == attribute, "#{name} declares #{verb} wrongly"
      end
    end
  end

  # The events named in a `JS.dispatch(...)` inside a declaration, and the events the shipped hooks
  # add listeners for. Both read out of the bundle rather than out of a list kept here, so a rename
  # on either side has to happen on both.
  defp dispatched_events(template) when is_binary(template) do
    ~r/data-pb-(?:open|close|toggle)=\{JS\.dispatch\("([^"]+)"/
    |> Regex.scan(template)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
  end

  defp dispatched_events(_absent), do: []

  defp hook_events do
    path = Application.app_dir(:mishka_cms_core, "priv/cms_ui_kits/chelekom.json")

    case File.read(path) do
      {:ok, raw} ->
        raw
        |> Jason.decode!()
        |> Map.get("js_hooks", [])
        |> Enum.flat_map(&Regex.scan(~r/"(chelekom:[a-z]+)"/, &1["content"] || ""))
        |> Enum.map(&List.last/1)
        |> Enum.uniq()

      {:error, _missing} ->
        []
    end
  end
end
