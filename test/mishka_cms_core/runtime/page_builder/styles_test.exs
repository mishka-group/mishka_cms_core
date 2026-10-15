defmodule MishkaCmsCore.Runtime.PageBuilder.StylesTest do
  @moduledoc """
  The override→Tailwind compilation, in both directions (ADR-8).

  The bidirectional property is the one that matters: what the inspector records must serialize to a
  class the runtime Tailwind pass can see, and re-parsing that class must give the inspector back
  the same map. Anything less and a saved page reopens with an empty responsive panel over classes
  the editor cannot read.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles

  # A value the property will actually accept: enumerated properties (display) only compile one of
  # their own options, a colour control a colour — `text-[7px]` is a font size to Tailwind — and
  # everything else a free-form length.
  defp sample(prop) when prop in ~w(color background border-color), do: "#123456"

  defp sample(prop) do
    case Styles.options(prop) do
      [] -> "7px"
      [first | _rest] -> first
    end
  end

  describe "to_classes/1" do
    test "base overrides have no variant prefix" do
      assert Styles.to_classes(%{base: %{"gap" => "20px"}}) == ["gap-[20px]"]
    end

    test "breakpoints become max-width variants at the prototype's widths" do
      assert Styles.to_classes(%{tablet: %{"py" => "14px"}}) == ["max-[900px]:py-[14px]"]
      assert Styles.to_classes(%{mobile: %{"py" => "14px"}}) == ["max-[560px]:py-[14px]"]
    end

    test "states become state variants" do
      assert Styles.to_classes(%{hover: %{"background" => "#17161a"}}) == ["hover:bg-[#17161a]"]
      assert Styles.to_classes(%{focus: %{"color" => "#fff"}}) == ["focus:text-[#fff]"]
      assert Styles.to_classes(%{active: %{"opacity" => "0.5"}}) == ["active:opacity-[0.5]"]
    end

    # A NUMBER TYPED INTO A LENGTH BOX MEANS PIXELS. `p-[8]` is not a Tailwind class — it compiles to
    # nothing, so the panel showed 8 and the element kept its zero padding. Everything that already
    # carries a unit is left exactly as it was written.
    test "a bare number in a length becomes pixels" do
      assert Styles.to_classes(%{base: %{"padding" => "8"}}) == ["p-[8px]"]
      assert Styles.to_classes(%{base: %{"gap" => "12"}}) == ["gap-[12px]"]
      assert Styles.to_classes(%{base: %{"max-width" => "64.5"}}) == ["max-w-[64.5px]"]
      assert Styles.to_classes(%{hover: %{"radius" => "4"}}) == ["hover:rounded-[4px]"]
    end

    test "a value that already says what it is keeps saying it" do
      for value <- ["8px", "2rem", "50%", "auto", "100vh", "calc(100%-2rem)"] do
        assert Styles.to_classes(%{base: %{"width" => value}}) == ["w-[#{value}]"]
      end
    end

    # AND ONLY LENGTHS. A bare number is exactly what opacity and z-index want, and adding px there
    # would break the two properties that were right all along.
    test "the unitless properties are left alone" do
      assert Styles.to_classes(%{base: %{"opacity" => "0.5"}}) == ["opacity-[0.5]"]
      assert Styles.to_classes(%{base: %{"z-index" => "10"}}) == ["z-[10]"]
      assert Styles.to_classes(%{base: %{"background" => "#fff"}}) == ["bg-[#fff]"]
    end

    # Tailwind spells display as `flex`, never `display-[flex]`, so the value is the whole utility.
    test "an enumerated property emits its value as the utility" do
      assert Styles.to_classes(%{base: %{"display" => "flex"}}) == ["flex"]
      assert Styles.to_classes(%{mobile: %{"display" => "block"}}) == ["max-[560px]:block"]
      assert Styles.to_classes(%{hover: %{"display" => "grid"}}) == ["hover:grid"]
    end

    test "a value the enumerated property does not offer emits nothing rather than a wrong class" do
      assert Styles.to_classes(%{base: %{"display" => "table-row-group"}}) == []
    end

    test "a hand-written display utility is absorbed so the panel can edit it" do
      assert Styles.from_classes("card flex max-[900px]:block") ==
               {["card"], %{base: %{"display" => "flex"}, tablet: %{"display" => "block"}}}
    end

    test "buckets are emitted in a stable order regardless of map ordering" do
      styles = %{mobile: %{"gap" => "2px"}, base: %{"gap" => "8px"}, hover: %{"gap" => "4px"}}

      assert Styles.to_classes(styles) == [
               "gap-[8px]",
               "max-[560px]:gap-[2px]",
               "hover:gap-[4px]"
             ]
    end

    test "several properties in one bucket are sorted so output never churns" do
      assert Styles.to_classes(%{base: %{"py" => "1px", "gap" => "2px", "px" => "3px"}}) == [
               "gap-[2px]",
               "px-[3px]",
               "py-[1px]"
             ]
    end

    test "a value containing a space is escaped the way Tailwind expects" do
      assert Styles.to_classes(%{base: %{"background" => "rgb(0 0 0)"}}) == ["bg-[rgb(0_0_0)]"]
    end

    test "an unmapped property emits nothing rather than an invented utility" do
      assert Styles.to_classes(%{base: %{"backdrop-filter" => "blur(2px)"}}) == []
    end

    test "an empty or malformed map yields no classes" do
      assert Styles.to_classes(%{}) == []
      assert Styles.to_classes(nil) == []
      assert Styles.to_classes(%{base: nil}) == []
    end
  end

  describe "from_classes/1" do
    test "splits authored classes from generated ones" do
      assert Styles.from_classes("card shadow gap-[20px]") ==
               {["card", "shadow"], %{base: %{"gap" => "20px"}}}
    end

    test "recognises every variant" do
      {authored, styles} =
        Styles.from_classes("max-[900px]:py-[14px] max-[560px]:py-[8px] hover:bg-[#111]")

      assert authored == []

      assert styles == %{
               tablet: %{"py" => "14px"},
               mobile: %{"py" => "8px"},
               hover: %{"background" => "#111"}
             }
    end

    test "a multi-dash utility splits on the bracket, not the first dash" do
      assert Styles.from_classes("max-w-[40rem]") == {[], %{base: %{"max-width" => "40rem"}}}
      assert Styles.from_classes("min-h-[10vh]") == {[], %{base: %{"min-height" => "10vh"}}}
    end

    test "an unknown utility stays an authored class" do
      assert Styles.from_classes("translate-x-[1rem]") == {["translate-x-[1rem]"], %{}}
      assert Styles.from_classes("text-red-500") == {["text-red-500"], %{}}
    end

    # A raw declaration is only ours when the property inside it is one of the two whose Tailwind
    # namespace was already taken. Anything else in that shape is somebody's own arbitrary property.
    test "an arbitrary property this module does not own stays authored" do
      assert Styles.from_classes("[mask-type:alpha]") == {["[mask-type:alpha]"], %{}}
      assert Styles.from_classes("[font-size:3rem]") == {[], %{base: %{"font-size" => "3rem"}}}

      assert Styles.from_classes("max-[900px]:[font-size:2rem]") ==
               {[], %{tablet: %{"font-size" => "2rem"}}}
    end

    test "an unknown variant stays authored" do
      assert Styles.from_classes("lg:gap-[4px]") == {["lg:gap-[4px]"], %{}}
    end

    test "authored order is preserved" do
      {authored, _styles} = Styles.from_classes("zeta alpha gap-[1px] middle")
      assert authored == ["zeta", "alpha", "middle"]
    end

    test "nil and blank input" do
      assert Styles.from_classes(nil) == {[], %{}}
      assert Styles.from_classes("   ") == {[], %{}}
    end

    test "an escaped space is decoded back" do
      assert Styles.from_classes("bg-[rgb(0_0_0)]") ==
               {[], %{base: %{"background" => "rgb(0 0 0)"}}}
    end
  end

  describe "the round trip" do
    # `from_classes/1` inverts the property→utility map, so two properties sharing one utility would
    # silently make the inverse ambiguous and one of them would decode as the other. This is the
    # guard that keeps the map injective as it grows.
    test "no two properties claim the same Tailwind utility" do
      utilities =
        Enum.map(Styles.properties(), fn prop ->
          [class] = Styles.to_classes(%{base: %{prop => sample(prop)}})
          class
        end)

      assert length(Enum.uniq(utilities)) == length(utilities)
    end

    # An enumerated property's values ARE its classes, so two properties offering the same value
    # would decode as each other exactly the way two properties sharing a utility would.
    test "no two enumerated properties offer the same value" do
      values =
        Enum.flat_map(Styles.properties(), fn prop ->
          Enum.map(Styles.options(prop), &{&1, prop})
        end)

      assert length(Enum.uniq_by(values, &elem(&1, 0))) == length(values)
    end

    test "every mappable property survives a full cycle" do
      styles =
        Map.new(Styles.buckets(), fn bucket ->
          {bucket, Map.new(Styles.properties(), &{&1, sample(&1)})}
        end)

      {authored, recovered} =
        styles |> Styles.to_classes() |> Enum.join(" ") |> Styles.from_classes()

      assert authored == []
      assert recovered == styles
    end

    test "merge_class keeps authored classes ahead of generated ones" do
      assert Styles.merge_class("card", %{base: %{"gap" => "2px"}}) == "card gap-[2px]"
    end

    test "merge_class returns nil when there is nothing at all to write" do
      assert Styles.merge_class(nil, %{}) == nil
      assert Styles.merge_class("", %{}) == nil
    end

    test "merge_class does not duplicate a class already compiled into the attribute" do
      once = Styles.merge_class("card", %{base: %{"gap" => "2px"}})

      assert Styles.merge_class(once, %{base: %{"gap" => "2px"}}) == "card gap-[2px]"
    end

    test "a changed override replaces rather than stacks" do
      once = Styles.merge_class("card", %{base: %{"gap" => "2px"}})

      assert Styles.merge_class(once, %{base: %{"gap" => "9px"}}) == "card gap-[9px]"
    end
  end

  describe "overrides that stop meaning anything" do
    # `flex-col-reverse` and `items-center` do nothing to a `block` element. Left behind they are
    # dead classes in the page and settings the Inspector still shows as chosen — and they spring
    # back, unasked, the moment the element is made a row again.
    test "leaving flex orphans the flex-only properties" do
      assert Styles.dependents("display", "block") == ~w(direction justify align wrap grid-cols)
      assert Styles.dependents("display", "grid") == ~w(direction justify align wrap)
    end

    # And the column track list is the same kind of dead weight on something that is no longer a
    # grid — including on a flex row, which is why staying flex no longer orphans nothing.
    test "leaving grid orphans the column count" do
      assert Styles.dependents("display", "flex") == ~w(grid-cols)
      assert Styles.dependents("display", "block") |> Enum.member?("grid-cols")
      refute Styles.dependents("display", "grid") |> Enum.member?("grid-cols")
    end

    test "an unrelated property orphans nothing" do
      assert Styles.dependents("gap", "16px") == []
      assert Styles.dependents("padding", nil) == []
    end
  end

  describe "Tree.set_style drops what it orphans" do
    alias MishkaCmsCore.Runtime.PageBuilder.Tree

    defp flex_node do
      {:ok, tree} = Tree.parse(~s(<div id="a">x</div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.kind == :tag))

      tree =
        Enum.reduce(
          [
            {"display", "flex"},
            {"direction", "flex-col-reverse"},
            {"justify", "justify-around"},
            {"align", "items-center"}
          ],
          tree,
          fn {prop, value}, acc ->
            {:ok, next} = Tree.set_style(acc, node.id, :base, prop, value)
            next
          end
        )

      {tree, node.id}
    end

    # ONE undoable step, and every writer gets it — the toolbar panel and the Inspector both go
    # through `set_style/5`.
    test "switching away from flex clears direction, spread, align and wrap" do
      {tree, id} = flex_node()

      {:ok, tree} = Tree.set_style(tree, id, :base, "display", "block")

      assert Tree.get(tree, id).meta.styles == %{base: %{"display" => "block"}}
    end

    test "staying on flex keeps them" do
      {tree, id} = flex_node()

      {:ok, tree} = Tree.set_style(tree, id, :base, "display", "flex")

      assert map_size(Tree.get(tree, id).meta.styles[:base]) == 4
    end

    # Only the bucket being written — Mobile going back to block must not disturb Desktop.
    test "another bucket is left alone" do
      {tree, id} = flex_node()
      {:ok, tree} = Tree.set_style(tree, id, :mobile, "direction", "flex-col")

      {:ok, tree} = Tree.set_style(tree, id, :mobile, "display", "block")

      assert Tree.get(tree, id).meta.styles[:mobile] == %{"display" => "block"}
      assert map_size(Tree.get(tree, id).meta.styles[:base]) == 4
    end
  end

  # WHAT THE AUTHOR IS SHOWN HAS TO BE CSS. The drawer printed the override map directly, so an
  # element laid out as a centred flex row read `align: items-center` — an internal shorthand and a
  # Tailwind class, dressed as a declaration no browser has ever accepted.
  describe "declaration/2" do
    test "an internal shorthand becomes the CSS property it means" do
      assert Styles.declaration("py", "16px") == {"padding-block", "16px"}
      assert Styles.declaration("radius", "8px") == {"border-radius", "8px"}
      assert Styles.declaration("background", "#fff") == {"background-color", "#fff"}
    end

    test "an enumerated value becomes the CSS value it means" do
      assert Styles.declaration("align", "items-center") == {"align-items", "center"}

      assert Styles.declaration("justify", "justify-between") ==
               {"justify-content", "space-between"}

      assert Styles.declaration("direction", "flex-col") == {"flex-direction", "column"}
      assert Styles.declaration("wrap", "flex-nowrap") == {"flex-wrap", "nowrap"}
    end

    test "a property CSS already names the same way passes through" do
      assert Styles.declaration("gap", "4px") == {"gap", "4px"}
      assert Styles.declaration("opacity", "0.5") == {"opacity", "0.5"}
      assert Styles.declaration("display", "flex") == {"display", "flex"}
    end

    # The guard against the whole class of bug: every property the inspector can record has to come
    # out as something a browser would accept, so a new one cannot be added without being translated.
    test "every recordable property translates to a plausible CSS property" do
      for prop <- Styles.properties() do
        {property, _value} = Styles.declaration(prop, sample(prop))

        assert property =~ ~r/^[a-z-]+$/, "#{prop} produced #{property}"

        refute property in ~w(py px pt pb my mx radius background align justify direction wrap),
               "#{prop} was left as an internal name"
      end
    end

    test "every enumerated value translates to a plausible CSS value" do
      for prop <- Styles.properties(), value <- Styles.options(prop) do
        {_property, css_value} = Styles.declaration(prop, value)

        refute String.starts_with?(css_value, ["items-", "justify-", "flex-col", "flex-row"]),
               "#{prop}: #{value} was left as a Tailwind class"
      end
    end
  end

  describe "Tree.set_attr lifts a typed class the same way parsing does" do
    alias MishkaCmsCore.Runtime.PageBuilder.Tree
    alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

    @klass "items-center gap-4 text-red-500 mine"

    defp typed(class) do
      {:ok, tree} = Tree.parse(~s(<div><p>hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
      {:ok, tree} = Tree.set_attr(tree, node.id, "class", {:string, class})
      {tree, node.id}
    end

    # THE BUG THIS DESCRIBE EXISTS FOR. A recognised utility typed into the class box was absorbed on
    # the way out and never recorded on the way in, so it simply disappeared — nothing to undo, no
    # message, and the same string pasted into the page source worked fine.
    test "a typed class ends up exactly where a parsed one does" do
      {:ok, parsed} = Tree.parse(~s(<div><p class="#{@klass}">hi</p></div>))
      parsed_p = parsed |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {tree, id} = typed(@klass)

      assert Serializer.serialize(tree) == Serializer.serialize(parsed)
      assert Tree.get(tree, id).meta.styles == Tree.get(parsed, parsed_p.id).meta.styles
      assert Serializer.serialize(tree) =~ "items-center"
    end

    test "the recognised half is recorded and the rest stays authored" do
      {tree, id} = typed(@klass)

      assert Tree.get(tree, id).meta.styles == %{base: %{"align" => "items-center"}}
      assert Node.attr(Tree.get(tree, id), "class") == {:string, "gap-4 text-red-500 mine"}
    end

    # The box shows the authored half only, so what a control recorded is not in the text being
    # edited — and retyping the box must not erase it.
    test "retyping the box keeps what the controls recorded" do
      {tree, id} = typed(@klass)
      {:ok, tree} = Tree.set_style(tree, id, :base, "padding", "16px")

      {:ok, tree} = Tree.set_attr(tree, id, "class", {:string, "mine only"})

      html = Serializer.serialize(tree)
      assert html =~ "p-[16px]", "the slider's padding survived"
      assert html =~ "items-center", "the earlier typed utility survived"
      assert html =~ "mine only"
    end

    test "an expression class is left alone" do
      {:ok, tree} = Tree.parse(~s(<div><p>hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {:ok, tree} = Tree.set_attr(tree, node.id, "class", {:expr, "@variant"})

      assert Tree.get(tree, node.id).meta[:styles] in [nil, %{}]
      assert Serializer.serialize(tree) =~ "class={@variant}"
    end

    test "an attribute that is not class is untouched" do
      {:ok, tree} = Tree.parse(~s(<div><p class="items-center">hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
      before = Tree.get(tree, node.id).meta.styles

      {:ok, tree} = Tree.set_attr(tree, node.id, "title", {:string, "items-center"})

      assert Tree.get(tree, node.id).meta.styles == before
    end
  end

  describe "which control a hand-written CSS property overrules" do
    test "the control that owns the property outright" do
      assert Styles.controls_for("align-items") == ["align"]
      assert Styles.controls_for("border-radius") == ["radius"]
      assert Styles.controls_for("gap") == ["gap"]
      assert Styles.controls_for("background-color") == ["background"]
    end

    test "a shorthand also overrules the longhands the panel splits it into" do
      assert Styles.controls_for("padding") == ["padding", "py", "px", "pt", "pb", "pl", "pr"]
      assert Styles.controls_for("padding-block") == ["py", "pt", "pb"]
      assert Styles.controls_for("padding-inline") == ["px", "pl", "pr"]
      assert Styles.controls_for("margin") == ["margin", "my", "mx", "mt", "mb", "ml", "mr"]
      assert Styles.controls_for("margin-block") == ["my", "mt", "mb"]
      assert Styles.controls_for("margin-inline") == ["mx", "ml", "mr"]
    end

    test "a property no control expresses claims nothing" do
      assert Styles.controls_for("border-image") == []
      assert Styles.controls_for("transform") == []
      assert Styles.controls_for("radius") == []
    end

    test "spelling and spacing do not decide it" do
      assert Styles.controls_for("  ALIGN-ITEMS ") == ["align"]
      assert Styles.controls_for(nil) == []
    end

    # Every control has to be reachable from the CSS name it writes, or a collision it really loses
    # would go unmarked. Walks the whole vocabulary rather than the handful spelled out above.
    test "every property the panel can write is reachable by its CSS name" do
      for prop <- Styles.properties() do
        {css, _value} = Styles.declaration(prop, "")

        assert prop in Styles.controls_for(css),
               "#{prop} writes #{css}, which no control claims back"
      end
    end
  end

  describe "moving a hand-written declaration into a control" do
    test "a free-form value passes straight through" do
      assert Styles.from_declaration("padding-block", "16px") == {:ok, {"py", "16px"}}
      assert Styles.from_declaration("color", "rgb(1, 2, 3)") == {:ok, {"color", "rgb(1, 2, 3)"}}
    end

    test "an enumerated value comes back as the class the control holds" do
      assert Styles.from_declaration("align-items", "center") == {:ok, {"align", "items-center"}}

      assert Styles.from_declaration("justify-content", "space-between") ==
               {:ok, {"justify", "justify-between"}}

      assert Styles.from_declaration("display", "flex") == {:ok, {"display", "flex"}}
    end

    test "a value no control can spell is refused rather than mangled" do
      assert Styles.from_declaration("align-items", "safe center") == :error
      assert Styles.from_declaration("display", "inline-grid") == :error
      assert Styles.from_declaration("border-image", "url(x)") == :error
      assert Styles.from_declaration("padding", "") == :error
    end

    # The panel writes a plain utility, which carries no such weight — moving the line would quietly
    # stop it winning. Left in the text, where it still does.
    test "!important cannot survive the move, so it is not offered" do
      assert Styles.from_declaration("gap", "4px !important") == :error
    end

    # A shorthand fans out for the DOT — it really does overrule Padding top — but moving it into one
    # longhand would change what the page looks like.
    test "a shorthand moves to its own control and never to the longhands it covers" do
      assert Styles.from_declaration("padding", "20px") == {:ok, {"padding", "20px"}}
      assert Styles.from_declaration("background", "red") == :error
    end

    # THE MOVE THE SWATCHES COULD NOT HOLD. `#dadada` is none of the five the panel paints, so the
    # control that receives it has to take any colour at all — which is why Background is a field
    # with the swatches over it rather than the swatches alone. See `Panels.appearance_props/0`.
    test "a colour the palette does not name moves like any other value" do
      assert Styles.from_declaration("background-color", "#dadada") ==
               {:ok, {"background", "#dadada"}}

      assert Styles.to_classes(%{base: %{"background" => "#dadada"}}) == ["bg-[#dadada]"]
    end
  end

  # THE BUG THE EDITOR WAS JUDGED ON. Setting a background on `<header class="bg-indigo-600">` used
  # to produce `bg-indigo-600 … bg-[#17161a]` and change nothing anybody could see: two single-class
  # selectors tie on specificity, and the winner is whichever the stylesheet lists last — the
  # compiled bundle. It read as "background does not work in Normal, but works on hover", because a
  # hover override compiles to a two-part selector that outranks the tie rather than joining it.
  describe "an override replacing the utility it collides with" do
    test "a background replaces a hand-written one" do
      assert Styles.merge_class("bg-indigo-600 py-4", %{base: %{"background" => "#17161a"}}) ==
               "py-4 bg-[#17161a]"
    end

    test "and the element's other classes are left alone" do
      assert Styles.merge_class("rounded-lg shadow-md bg-white", %{
               base: %{"background" => "#000000"}
             }) == "rounded-lg shadow-md bg-[#000000]"
    end

    # `text-` is colour, size AND alignment. Dropping every `text-*` for a colour would take the
    # other two with it.
    #
    # ALIGNMENT IS A CONTROL NOW, so it no longer survives by staying in the authored half — it is
    # absorbed and re-emitted, which is the same promise kept a different way. Every caller hands
    # `merge_class/2` a node's WHOLE style map, and this is why: given a partial one it cannot know
    # the alignment it just absorbed was ever written.
    test "a colour drops only the colour, not the size or the alignment" do
      class = "text-lg text-white text-center"
      {_authored, styles} = Styles.from_classes(class)

      merged = Styles.merge_class(class, put_in(styles, [:base, "color"], "#ff0000"))

      assert merged == "text-lg text-[#ff0000] text-center"
    end

    # The same thing through the door the editor actually uses, because the guarantee is about a
    # page and not about a function: setting a colour on an element whose author centred it must
    # leave it centred.
    test "and the same holds through a real parse, edit and serialize" do
      alias MishkaCmsCore.Runtime.PageBuilder.Tree
      alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

      {:ok, tree} = Tree.parse(~s(<div><p class="text-lg text-white text-center">hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
      {:ok, tree} = Tree.set_style(tree, node.id, :base, "color", "#ff0000")

      html = Serializer.serialize(tree)

      assert html =~ "text-center"
      assert html =~ "text-[#ff0000]"
      refute html =~ "text-white"
    end

    # `border-` is colour and width, the same way.
    test "a border colour leaves the border width" do
      assert Styles.merge_class("border-2 border-red-500", %{
               base: %{"border-color" => "#00ff00"}
             }) == "border-2 border-[#00ff00]"
    end

    # This once asserted that an authored axis SURVIVED the panel's Padding — `p-4 px-8` answering
    # `px-8 p-[20px]`. It reads like restraint and is the bug the author reports as "Padding does
    # nothing": Tailwind orders `px-*` after `p-*`, so the surviving `px-8` beat the value that had
    # just been typed on the left and right edges. An override that is present in the class attribute
    # and has no effect is the worst way for a control to fail, because it looks set.
    #
    # Unlike the border case above, these are not two properties: `px` IS padding on two of the four
    # edges. A narrower AUTHORED class is exactly what an override is for.
    test "padding takes over the axis it contains" do
      assert Styles.merge_class("p-4 px-8", %{base: %{"padding" => "20px"}}) == "p-[20px]"
    end

    # Longest match first, or `min-h-screen` would be read as the `min` utility, which is nothing.
    test "a two-part utility is matched whole" do
      assert Styles.merge_class("min-h-screen", %{base: %{"min-height" => "40rem"}}) ==
               "min-h-[40rem]"
    end

    # A state override is ADDITIONAL to the resting look — that is the whole point of one.
    test "a hover override leaves the base class in place" do
      assert Styles.merge_class("bg-indigo-600", %{hover: %{"background" => "#111111"}}) ==
               "bg-indigo-600 hover:bg-[#111111]"
    end

    test "and a base override leaves a hand-written hover class in place" do
      assert Styles.merge_class("hover:bg-red-500", %{base: %{"background" => "#111111"}}) ==
               "hover:bg-red-500 bg-[#111111]"
    end

    test "a class for a property nobody overrode survives" do
      assert Styles.merge_class("bg-indigo-600", %{base: %{"gap" => "2px"}}) ==
               "bg-indigo-600 gap-[2px]"
    end
  end

  # A SHORTHAND HAS TO DROP THE LONGHANDS IT CONTAINS, and the check compared utility prefixes for
  # exact equality — `p` is not `px`. So the panel's Padding wrote `p-[40px]` onto a block already
  # reading `px-6 py-16`, kept both, and lost on every edge, because Tailwind orders `px-*` after
  # `p-*`. The value was in the class attribute and did nothing, which is the worst way for a control
  # to fail: it looks set.
  describe "a shorthand override against the longhands already on the element" do
    test "Padding takes over from an authored px and py" do
      assert Styles.merge_class("mx-auto px-6 py-16 text-slate-900", %{
               base: %{"padding" => "40px"}
             }) == "mx-auto text-slate-900 p-[40px]"
    end

    test "Margin takes over from an authored mx" do
      assert Styles.merge_class("mx-auto px-6", %{base: %{"margin" => "32px"}}) ==
               "px-6 m-[32px]"
    end

    test "Padding Y takes over from an authored pt and pb" do
      assert Styles.merge_class("pt-2 pb-2", %{base: %{"py" => "60px"}}) == "py-[60px]"
    end

    test "and a class the override has no say in is left where it was" do
      assert Styles.merge_class("text-slate-900 rounded-lg", %{base: %{"padding" => "40px"}}) ==
               "text-slate-900 rounded-lg p-[40px]"
    end
  end

  # THE VOCABULARY THE BLOCKS ARE ACTUALLY WRITTEN IN. Counted across the eleven starter blocks: 54
  # font sizes, 37 weights, 33 `mt-*`, 12 `grid-cols-*`, 10 letter-spacings, 7 alignments. Every one
  # of them was a class the panel could see on the element and not offer a control for, so the only
  # way to change a heading's size was to hand-write CSS beside it.
  describe "typography" do
    test "size and border width are written as the CSS property, because their utility is taken" do
      assert Styles.to_classes(%{base: %{"font-size" => "3rem"}}) == ["[font-size:3rem]"]
      assert Styles.to_classes(%{base: %{"border-width" => "2px"}}) == ["[border-width:2px]"]
    end

    # `text-` is colour here and `border-` is border colour. A second property claiming either would
    # make `from_classes/1` guess, and a guess in an inverse is a page that reopens wrong.
    test "and they do not collide with the colour that owns their utility" do
      classes = Styles.to_classes(%{base: %{"font-size" => "3rem", "color" => "#fff"}})

      assert "[font-size:3rem]" in classes
      assert "text-[#fff]" in classes

      assert Styles.from_classes(Enum.join(classes, " ")) ==
               {[], %{base: %{"font-size" => "3rem", "color" => "#fff"}}}
    end

    test "a bare number in a size still means pixels" do
      assert Styles.to_classes(%{base: %{"font-size" => "18"}}) == ["[font-size:18px]"]
      assert Styles.to_classes(%{base: %{"border-width" => "2"}}) == ["[border-width:2px]"]
    end

    # Line height is a ratio far more often than a length, so it is deliberately NOT a length.
    test "line height and letter spacing take Tailwind's own utilities" do
      assert Styles.to_classes(%{base: %{"line-height" => "1.6"}}) == ["leading-[1.6]"]

      assert Styles.to_classes(%{base: %{"letter-spacing" => "-0.02em"}}) == [
               "tracking-[-0.02em]"
             ]

      assert Styles.from_classes("leading-[1.6]") == {[], %{base: %{"line-height" => "1.6"}}}
    end

    test "a breakpoint carries a raw property the same way it carries a utility" do
      assert Styles.to_classes(%{mobile: %{"font-size" => "1.5rem"}}) ==
               ["max-[560px]:[font-size:1.5rem]"]

      assert Styles.from_classes("max-[560px]:[font-size:1.5rem]") ==
               {[], %{mobile: %{"font-size" => "1.5rem"}}}
    end

    # THE PAYOFF. A block ships `text-5xl font-bold tracking-tight text-slate-900`; the weight and
    # the alignment are recognised words, so they arrive in the panel as settings rather than as
    # classes the reader has to retype somewhere else to change.
    test "a block's own weight, alignment and case become editable settings" do
      {authored, styles} =
        Styles.from_classes("mx-auto max-w-3xl font-bold text-center uppercase text-slate-900")

      assert styles == %{
               base: %{
                 "font-weight" => "font-bold",
                 "text-align" => "text-center",
                 "text-transform" => "uppercase"
               }
             }

      assert authored == ["mx-auto", "max-w-3xl", "text-slate-900"]
    end

    test "and every one of them names a real CSS declaration" do
      assert Styles.declaration("font-weight", "font-bold") == {"font-weight", "700"}
      assert Styles.declaration("text-align", "text-center") == {"text-align", "center"}
      assert Styles.declaration("text-transform", "normal-case") == {"text-transform", "none"}
      assert Styles.declaration("font-size", "3rem") == {"font-size", "3rem"}
    end

    # `from_declaration/2` is what **Move to controls** asks, so a hand-written declaration in the
    # element CSS box has somewhere to land instead of staying there for ever.
    test "a hand-written declaration has a control to move into" do
      assert Styles.from_declaration("font-size", "3rem") == {:ok, {"font-size", "3rem"}}

      assert Styles.from_declaration("text-align", "center") ==
               {:ok, {"text-align", "text-center"}}

      assert Styles.from_declaration("font-weight", "700") == {:ok, {"font-weight", "font-bold"}}
      assert Styles.controls_for("letter-spacing") == ["letter-spacing"]
    end
  end

  describe "the four sides" do
    test "each edge of padding and margin has its own utility" do
      for {prop, util} <- [
            {"pt", "pt"},
            {"pb", "pb"},
            {"pl", "pl"},
            {"pr", "pr"},
            {"mt", "mt"},
            {"mb", "mb"},
            {"ml", "ml"},
            {"mr", "mr"}
          ] do
        assert Styles.to_classes(%{base: %{prop => "12px"}}) == ["#{util}-[12px]"]
        assert Styles.from_classes("#{util}-[12px]") == {[], %{base: %{prop => "12px"}}}
      end
    end

    # A SHORTHAND STILL BEATS ITS EDGES. Tailwind orders `pl-*` after `p-*`, so an authored `pl-4`
    # left in place would win on the left edge over the Padding somebody had just typed — present in
    # the class attribute, and doing nothing.
    test "the shorthand takes over every edge it contains" do
      assert Styles.merge_class("p-4 pl-8", %{base: %{"padding" => "20px"}}) == "p-[20px]"
      assert Styles.merge_class("m-4 mt-8", %{base: %{"margin" => "20px"}}) == "m-[20px]"
    end

    test "and one edge does not disturb the others" do
      assert Styles.merge_class("pl-8", %{base: %{"pt" => "20px"}}) == "pl-8 pt-[20px]"
    end
  end

  # AN EDGE COULD NOT WIN AGAINST THE AXIS THE AUTHOR HAD ALREADY WRITTEN. On a `<main>` carrying
  # `mx-auto py-16 px-8`, `mr-[300px]` measured 63px and `pb-[20px]` measured 64px while `mt-[50px]`
  # measured 50px — which is what "only the top margin works" was: `mt` was the one edge with no axis
  # over it.
  #
  # IT WAS NEVER THIS MODULE'S BUG. The canvas rendered the site's compiled bundle in `<body>` while
  # the browser generator injects what it makes into `<head>`, so the bundle overruled every class
  # the editor produced. The bundle is in `<head>` now, above the generator, which is the order the
  # published page always had — one Tailwind pass, correctly sorted.
  #
  # So what this module owes is the plainest thing: append the override and leave the author's own
  # classes exactly as they were. No `!important`, and no rewriting an axis into its edges — two
  # things that were tried here and are gone.
  describe "an override beside the axis the author already wrote" do
    test "the authored classes are left untouched" do
      assert Styles.merge_class("max-w-2xl mx-auto py-16 px-8", %{
               base: %{"mr" => "300px", "pb" => "20px"}
             }) == "max-w-2xl mx-auto py-16 px-8 mr-[300px] pb-[20px]"
    end

    test "including the shorthand, which the edge does not disturb" do
      assert Styles.merge_class("p-4", %{base: %{"pl" => "30px"}}) == "p-4 pl-[30px]"
      assert Styles.merge_class("px-8", %{base: %{"pl" => "30px"}}) == "px-8 pl-[30px]"
    end

    test "and a mobile override leaves the desktop class alone" do
      assert Styles.merge_class("px-8", %{mobile: %{"pl" => "30px"}}) ==
               "px-8 max-[560px]:pl-[30px]"
    end

    # NOTHING FROM THIS PANEL SHOUTS. An `!important` utility would ship in every published page and
    # would outrank the element's own Custom CSS, turning the marker that says "your CSS wins here"
    # into a lie.
    test "and nothing is written important" do
      for prop <- ~w(py px pt pb pl pr my mx mt mb ml mr padding margin gap width radius) do
        assert [class] = Styles.to_classes(%{base: %{prop => "10px"}})
        refute String.contains?(class, "!"), "#{prop} writes an important utility"
      end
    end

    # A control whose utility IS the authored one still replaces it, which is the collision this
    # module does settle — and the only one it should.
    test "the same utility is still replaced rather than joined" do
      assert Styles.merge_class("p-4 px-8", %{base: %{"padding" => "20px"}}) == "p-[20px]"
      assert Styles.merge_class("pl-8", %{base: %{"pl" => "30px"}}) == "pl-[30px]"
      assert Styles.merge_class("gap-8", %{base: %{"gap" => "20px"}}) == "gap-[20px]"
    end
  end

  describe "shadow and grid columns" do
    # A shadow is four numbers and a colour, and the spaces between them cannot survive in a class.
    test "a shadow's spaces are escaped and decoded back" do
      shadow = "0 10px 24px -4px rgba(15,23,42,0.18)"

      assert Styles.to_classes(%{base: %{"shadow" => shadow}}) ==
               ["shadow-[0_10px_24px_-4px_rgba(15,23,42,0.18)]"]

      assert Styles.from_classes("shadow-[0_10px_24px_-4px_rgba(15,23,42,0.18)]") ==
               {[], %{base: %{"shadow" => shadow}}}
    end

    test "an inset shadow round trips too" do
      assert Styles.from_classes("shadow-[inset_0_2px_4px_rgba(0,0,0,0.12)]") ==
               {[], %{base: %{"shadow" => "inset 0 2px 4px rgba(0,0,0,0.12)"}}}
    end

    # `grid-cols-[3]` is `grid-template-columns: 3`, which is not a track list and lays out nothing.
    # The count has to reach the page as Tailwind's own utility — which is also how the blocks are
    # written, so reading one back gives the panel a real column count.
    test "a column count is Tailwind's own utility, not an arbitrary value" do
      assert Styles.to_classes(%{base: %{"grid-cols" => "3"}}) == ["grid-cols-3"]
      assert Styles.from_classes("grid-cols-3") == {[], %{base: %{"grid-cols" => "3"}}}
      assert Styles.to_classes(%{mobile: %{"grid-cols" => "1"}}) == ["max-[560px]:grid-cols-1"]
    end

    test "a count past Tailwind's scale falls back to a track list rather than an invented class" do
      assert Styles.to_classes(%{base: %{"grid-cols" => "16"}}) == ["grid-cols-[16]"]
      assert Styles.from_classes("grid-cols-16") == {["grid-cols-16"], %{}}
    end

    # THE THREE-COLUMN BLOCK, OPENED. `Features ×3` ships `grid grid-cols-3 gap-8`, and until now
    # every one of those words was a class the panel could see and not offer a control for.
    #
    # `gap-8` and `mt-10` stay authored, as every value on Tailwind's numeric scale does: this module
    # round-trips the shapes it EMITS, and reading `8` back as `2rem` would rewrite a page nobody
    # edited. The override still wins over them — see the shorthand tests above — it simply does not
    # pretend to have read them.
    test "the features block arrives as settings" do
      assert Styles.from_classes("mt-10 grid grid-cols-3 gap-8") ==
               {["mt-10", "gap-8"], %{base: %{"display" => "grid", "grid-cols" => "3"}}}

      assert Styles.merge_class("mt-10 grid grid-cols-3 gap-8", %{
               base: %{"display" => "grid", "grid-cols" => "2", "gap" => "48px"}
             }) == "mt-10 grid gap-[48px] grid-cols-2"
    end

    test "a track list survives its spaces" do
      assert Styles.to_classes(%{base: %{"grid-cols" => "2fr 1fr"}}) == ["grid-cols-[2fr_1fr]"]

      assert Styles.from_classes("grid-cols-[2fr_1fr]") ==
               {[], %{base: %{"grid-cols" => "2fr 1fr"}}}
    end
  end

  # `bg-[…]` TAKES ONE TYPE AT A TIME. Handed the `background` shorthand — which is what a picture
  # needs, `url(…) center/cover no-repeat` — Tailwind generates a rule that sets nothing: the class
  # is in the sheet, the element carries it, and `background-image` still reads `none`. A control
  # that looks applied and paints nothing is the worst way for one to fail.
  describe "a background that is a picture rather than a colour" do
    test "a colour keeps the utility Tailwind has for it" do
      assert Styles.to_classes(%{base: %{"background" => "#ff0000"}}) == ["bg-[#ff0000]"]

      assert Styles.to_classes(%{base: %{"background" => "var(--danger-light)"}}) ==
               ["bg-[var(--danger-light)]"]
    end

    test "and a shorthand is written as the property itself" do
      shorthand = "url(/uploads/hero.png) center/cover no-repeat"

      assert Styles.to_classes(%{base: %{"background" => shorthand}}) ==
               ["[background:url(/uploads/hero.png)_center/cover_no-repeat]"]
    end

    test "both come back as the same control" do
      for value <- [
            "#ff0000",
            "var(--danger-light)",
            "url(/uploads/hero.png) center/cover no-repeat",
            "url(/uploads/a.png)"
          ] do
        [class] = Styles.to_classes(%{base: %{"background" => value}})

        assert Styles.from_classes(class) == {[], %{base: %{"background" => value}}},
               "#{value} did not survive as #{class}"
      end
    end

    test "and a breakpoint carries the picture too" do
      assert Styles.to_classes(%{mobile: %{"background" => "url(/a.png) center/cover no-repeat"}}) ==
               ["max-[560px]:[background:url(/a.png)_center/cover_no-repeat]"]
    end
  end

  # The class attribute of the one `<p>` in a serialized tree, as a sorted list.
  defp p_classes(tree) do
    [_match, class] = Regex.run(~r/<p class="([^"]*)"/, Serializer.serialize(tree))
    class |> String.split() |> Enum.sort()
  end

  defp p_node(tree), do: tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

  # `text-[14px]` is a font size and `text-[#9a96c4]` a colour. Tailwind tells them apart by the type
  # of the value in the brackets, and so does this module, or one of the two is lost on every parse.
  describe "a prefix Tailwind shares between properties" do
    test "a size beside a colour stays the author's, and the colour is read" do
      assert Styles.from_classes("text-[14px] text-[#9a96c4] leading-6") ==
               {["text-[14px]", "leading-6"], %{base: %{"color" => "#9a96c4"}}}
    end

    test "a length, a percentage, a size keyword, a maths function or a bare number is a size" do
      for value <- ~w|14px 1.5rem 2em 120% 10vw 5vh 40ch 1lh .5rem 1e1px -2px 14 1.5 larger medium
                      xx-large clamp(1rem,2vw,2rem) calc(1rem_+_2px) min(2rem,5vw) max(1rem,2vw)| do
        class = "text-[#{value}]"

        assert Styles.from_classes(class) == {[class], %{}}, "#{class} was read as a colour"

        assert Styles.merge_class(class, %{base: %{"color" => "#000"}}) == "#{class} text-[#000]",
               "a colour took #{class}"

        assert Styles.merge_class(class, %{base: %{"font-size" => "2rem"}}) == "[font-size:2rem]",
               "a size left #{class}"
      end
    end

    test "a hex, a colour function, a colour word or a bare variable is a colour" do
      for value <- ~w|#9a96c4 #fff rgb(0_0_0) rgba(0,0,0,.5) hsl(210_40%_50%) hsla(0,0%,0%,.2)
                      oklch(.7_.1_200) oklab(.5_.1_.1) lab(50%_40_59) lch(50%_40_59)
                      color(display-p3_1_0_0) color-mix(in_oklab,red,blue) light-dark(#000,#fff)
                      hwb(0_0%_0%) transparent currentColor red rebeccapurple var(--brand)| do
        class = "text-[#{value}]"

        assert {[], %{base: %{"color" => _colour}}} = Styles.from_classes(class),
               "#{class} was not read as a colour"

        tree = Tree.parse!(~s(<div><p class="text-[14px] #{class}">hi</p></div>))
        {:ok, sized} = Tree.set_style(tree, p_node(tree).id, :base, "font-size", "2rem")

        assert p_classes(sized) == Enum.sort([class, "[font-size:2rem]"]),
               "a size took #{class}"
      end
    end

    test "a type hint wins over the guess, and a hinted class stays as the author wrote it" do
      for class <- ~w|text-[length:var(--x)] text-[size:var(--x)]| do
        assert Styles.from_classes(class) == {[class], %{}}
        assert Styles.merge_class(class, %{base: %{"color" => "#000"}}) == "#{class} text-[#000]"
        assert Styles.merge_class(class, %{base: %{"font-size" => "2rem"}}) == "[font-size:2rem]"
      end

      assert Styles.from_classes("text-[color:var(--x)]") == {["text-[color:var(--x)]"], %{}}

      assert Styles.merge_class("text-[color:var(--x)] text-[14px]", %{
               base: %{"color" => "#000"}
             }) == "text-[14px] text-[#000]"
    end

    # The editor's two controls on one element, through the door the editor uses.
    test "setting a colour keeps the size, and setting a size keeps the colour" do
      tree = Tree.parse!(~s(<div><p class="text-[14px] text-[#9a96c4]">hi</p></div>))
      id = p_node(tree).id

      {:ok, coloured} = Tree.set_style(tree, id, :base, "color", "#ff0000")
      assert p_classes(coloured) == ["text-[#ff0000]", "text-[14px]"]

      {:ok, sized} = Tree.set_style(tree, id, :base, "font-size", "2rem")
      assert p_classes(sized) == ["[font-size:2rem]", "text-[#9a96c4]"]

      {:ok, both} = Tree.set_style(sized, id, :base, "color", "#ff0000")
      assert p_classes(both) == ["[font-size:2rem]", "text-[#ff0000]"]
      assert p_classes(Tree.parse!(Serializer.serialize(both))) == p_classes(both)
    end

    test "a border width is not a border colour" do
      assert Styles.from_classes("border-[2px] border-[#ccc]") ==
               {["border-[2px]"], %{base: %{"border-color" => "#ccc"}}}

      for value <- ~w|2px thin medium thick 2 calc(1px+1px) length:var(--x) line-width:var(--x)| do
        class = "border-[#{value}]"

        assert Styles.from_classes(class) == {[class], %{}}, "#{class} was read as a colour"

        assert Styles.merge_class(class, %{base: %{"border-color" => "#00f"}}) ==
                 "#{class} border-[#00f]"

        assert Styles.merge_class(class, %{base: %{"border-width" => "4px"}}) ==
                 "[border-width:4px]"
      end

      for value <- ~w|#ccc red var(--line)| do
        assert {[], %{base: %{"border-color" => _colour}}} =
                 Styles.from_classes("border-[#{value}]")
      end
    end

    test "setting a border width keeps the colour, and setting a colour keeps the width" do
      tree = Tree.parse!(~s(<div><p class="border-[2px] border-[#ccc]">hi</p></div>))
      id = p_node(tree).id

      {:ok, wider} = Tree.set_style(tree, id, :base, "border-width", "4px")
      assert p_classes(wider) == ["[border-width:4px]", "border-[#ccc]"]

      {:ok, recoloured} = Tree.set_style(tree, id, :base, "border-color", "#00f")
      assert p_classes(recoloured) == ["border-[#00f]", "border-[2px]"]
    end

    test "a background position or size is not a colour, and a colour leaves it" do
      class = "bg-[length:200px_100px] bg-[center_top] bg-[50%] bg-[cover] bg-[#fff]"

      assert Styles.from_classes(class) ==
               {~w(bg-[length:200px_100px] bg-[center_top] bg-[50%] bg-[cover]),
                %{base: %{"background" => "#fff"}}}

      assert Styles.merge_class(class, %{base: %{"background" => "#000"}}) ==
               "bg-[length:200px_100px] bg-[center_top] bg-[50%] bg-[cover] bg-[#000]"
    end

    # The Background control holds a picture as well as a colour, so it replaces an authored one.
    test "a gradient is read as the background, and a picture is replaced by one" do
      assert Styles.from_classes("bg-[linear-gradient(90deg,_red,_blue)]") ==
               {[], %{base: %{"background" => "linear-gradient(90deg, red, blue)"}}}

      assert Styles.merge_class("bg-[url(/a.png)] bg-cover", %{base: %{"background" => "#000"}}) ==
               "bg-cover bg-[#000]"
    end

    # Tailwind paints an arbitrary shadow in `--tw-shadow-color`, so a shadow colour left behind
    # would recolour the shadow the panel just set.
    test "a shadow colour is not a shadow, and setting a shadow replaces it" do
      assert Styles.from_classes("shadow-[#f00]") == {["shadow-[#f00]"], %{}}
      assert Styles.from_classes("shadow-[red]") == {["shadow-[red]"], %{}}

      assert Styles.from_classes("shadow-[0_0_4px_#000]") ==
               {[], %{base: %{"shadow" => "0 0 4px #000"}}}

      assert Styles.merge_class("rounded shadow-lg shadow-[#f00] shadow-indigo-500/50", %{
               base: %{"shadow" => "0 1px 2px #000"}
             }) == "rounded shadow-[0_1px_2px_#000]"
    end

    test "a palette colour with an opacity is still a colour" do
      assert Styles.merge_class("text-white/80 bg-black/50 text-lg", %{
               base: %{"color" => "#111", "background" => "#222"}
             }) == "text-lg bg-[#222] text-[#111]"
    end
  end

  # One value in the panel cannot give back two classes, so neither is read, and a class an
  # override would drop is not read past either.
  describe "two classes for one control" do
    test "both stay the author's, and come back as they were" do
      for class <- [
            "text-[#fff] text-[#000]",
            "bg-white bg-[#000]",
            "bg-[url(/hero.jpg)] bg-cover bg-[#111]",
            "p-[20px] px-8",
            "text-[14px] [font-size:2rem]",
            "shadow-lg shadow-[0_0_4px_#000]",
            "flex grid"
          ] do
        assert Styles.from_classes(class) == {String.split(class), %{}}, class
        assert Styles.merge_class(class, %{}) == class
      end
    end

    test "and the control replaces them all once it is set" do
      assert Styles.merge_class("bg-white bg-[#000]", %{base: %{"background" => "#123"}}) ==
               "bg-[#123]"

      assert Styles.merge_class("text-[14px] [font-size:2rem]", %{base: %{"font-size" => "3rem"}}) ==
               "[font-size:3rem]"
    end

    test "a class in another bucket is no rival" do
      assert Styles.from_classes("bg-white hover:bg-[#000]") ==
               {["bg-white"], %{hover: %{"background" => "#000"}}}
    end

    test "the editor's own shorthand beside its own edge is still one class each" do
      assert Styles.from_classes("p-[20px] px-[8px]") ==
               {[], %{base: %{"padding" => "20px", "px" => "8px"}}}
    end

    test "a list's literal elements are read together" do
      source = ~s(["text-[#fff]", @x && "a", "text-[#000]"])

      assert {parts, %{}} = Styles.split_list_expr(source)
      assert Styles.list_expr(parts) == source

      assert {parts, %{base: %{"gap" => "4px"}}} =
               Styles.split_list_expr(~s(["p-2", @x && "a", "gap-[4px]"]))

      assert Styles.list_expr(parts) == ~s(["p-2", @x && "a"])
    end
  end

  # Reading a class and writing it back must not change the page, so a class this module would
  # spell differently is left as the author wrote it.
  describe "only a class written back the same is read" do
    test "a picture in the bg utility is not rewritten as the shorthand" do
      assert Styles.from_classes("bg-[url(/a.png)]") == {["bg-[url(/a.png)]"], %{}}
    end

    test "nor is a bare number in a length, a bracketed count, or a colour in the shorthand" do
      for class <- ~w(p-[8] w-[1000] [font-size:18] grid-cols-[3] [background:#fff]) do
        assert Styles.from_classes(class) == {[class], %{}}, class
      end
    end
  end

  # The class list of the one `<.link>` in a serialized tree, in its written order.
  defp link_classes(tree) do
    [_match, class] = Regex.run(~r/<\.link[^>]*class="([^"]*)"/, Serializer.serialize(tree))
    String.split(class)
  end

  defp link_node(tree), do: tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))

  defp link(class),
    do: Tree.parse!(~s(<nav><.link navigate="/" class="#{class}">Go</.link></nav>))

  # A component's override is written with a bang so it beats the kit's own classes. A class the
  # author wrote without one is the author's: read and written back, it gained the bang, and an
  # important base utility beats the variant beside it.
  describe "a class passed to a component" do
    test "comes back as written, so its variants still win" do
      for class <- [
            "ml-auto min-[1026px]:hidden inline-flex items-center gap-2 text-[#ece6ff] " <>
              "hover:text-[#ffb86b] border-[rgba(180,150,240,0.32)]! hover:border-[#ff8a3a]!",
            "text-[#e9e7ff] transition-colors hover:text-white",
            "text-[#9994c8] hover:text-white focus-visible:text-white " <>
              "focus-visible:border-[var(--acc)]",
            "flex items-center gap-3 h-[14px] w-[14px] [font-size:14px]"
          ] do
        tree = link(class)

        assert Enum.sort(link_classes(tree)) == Enum.sort(String.split(class)),
               "#{class} came back as #{Enum.join(link_classes(tree), " ")}"

        if not String.contains?(class, "!") do
          assert link_node(tree).meta[:styles] in [nil, %{}],
                 "#{class} was read as the editor's own"
        end
      end
    end

    test "while the editor's own important override is still read back" do
      assert Styles.from_classes("p-[8px]! text-[#fff] flex!", important?: true) ==
               {["text-[#fff]"], %{base: %{"padding" => "8px", "display" => "flex"}}}

      tree = link("px-[14px]! py-[10px]! text-[13px]!")
      assert link_node(tree).meta[:styles] == %{base: %{"px" => "14px", "py" => "10px"}}
      assert Enum.sort(link_classes(tree)) == ~w(px-[14px]! py-[10px]! text-[13px]!)
    end

    test "setting a colour makes the author's colour variants important too" do
      tree = link("text-[#e9e7ff] hover:text-white focus-visible:text-white rounded-md")
      {:ok, coloured} = Tree.set_style(tree, link_node(tree).id, :base, "color", "#abcdef")

      assert Enum.sort(link_classes(coloured)) ==
               Enum.sort(
                 ~w(text-[#abcdef]! hover:text-white! focus-visible:text-white! rounded-md)
               )
    end

    # Made important, `hover:text-[#ffb86b]!` is spelt the way the editor writes its own hover
    # colour, and must survive being read back as one rather than vanish between the two.
    test "and a variant spelt like the editor's own survives the next save and the one after" do
      tree = link("text-[#e9e7ff] hover:text-[#ffb86b] focus-visible:border-[var(--acc)]")
      {:ok, coloured} = Tree.set_style(tree, link_node(tree).id, :base, "color", "#abcdef")

      expected =
        Enum.sort(~w|text-[#abcdef]! hover:text-[#ffb86b]! focus-visible:border-[var(--acc)]|)

      assert Enum.sort(link_classes(coloured)) == expected

      saved = coloured |> Serializer.serialize() |> Tree.parse!()
      assert Enum.sort(link_classes(saved)) == expected
      assert link_node(saved).meta[:styles][:hover] == %{"color" => "#ffb86b"}
    end

    test "a class written as a list gets the same, with the author's logic left in place" do
      tree =
        Tree.parse!(
          ~S(<nav><.link navigate="/" class={["text-[#e9e7ff] hover:text-white", @on && "underline"]}>Go</.link></nav>)
        )

      {:ok, coloured} = Tree.set_style(tree, link_node(tree).id, :base, "color", "#abcdef")
      html = Serializer.serialize(coloured)

      assert html =~ ~S(class={["hover:text-white!", @on && "underline", "text-[#abcdef]!"]})
    end

    test "setting the display does the same for a display variant, and replaces the base one" do
      tree = link("ml-auto min-[1026px]:hidden inline-flex items-center")
      {:ok, shown} = Tree.set_style(tree, link_node(tree).id, :base, "display", "flex")

      assert Enum.sort(link_classes(shown)) ==
               Enum.sort(~w(ml-auto min-[1026px]:hidden! flex! items-center))
    end

    test "on a plain element nothing is made important" do
      tree = Tree.parse!(~s(<div><p class="text-[#e9e7ff] hover:text-white">hi</p></div>))
      {:ok, coloured} = Tree.set_style(tree, p_node(tree).id, :base, "color", "#abcdef")

      assert p_classes(coloured) == Enum.sort(~w(text-[#abcdef] hover:text-white))
    end
  end

  describe "every option explains itself" do
    # The compile-time guard in `Styles` already refuses a value with neither, so this is about the
    # panel being able to FIND the description: it asks both and draws whichever answers.
    test "an enumerated property is either pictured or labelled, never neither and never both" do
      for prop <- Styles.properties(), Styles.options(prop) != [] do
        described = Styles.pictures(prop) ++ Styles.labels(prop)

        assert Enum.map(described, &elem(&1, 0)) |> Enum.sort() == Enum.sort(Styles.options(prop)),
               "#{prop} is not fully described"

        assert Styles.pictures(prop) == [] or Styles.labels(prop) == [],
               "#{prop} is described twice"
      end
    end

    test "and a labelled value answers with its words, not with its Tailwind class" do
      assert Styles.value_title("font-weight", "font-extrabold") == "Black"
      assert Styles.value_title("text-transform", "normal-case") == "As typed"
      assert Styles.value_title("border-style", "border-dashed") == "Dashed"
      assert Styles.value_title("align", "items-center") == "Align to the middle"
    end

    test "a free-form property has nothing to draw and says so" do
      assert Styles.labels("font-size") == []
      assert Styles.pictures("font-size") == []
      assert Styles.value_title("font-size", "3rem") == "3rem"
    end
  end

  # A BUCKET IS A WIDTH AND A STATE, NOT ONE OR THE OTHER. It used to be either — the panel wrote to
  # the breakpoint while Normal was selected and to the state otherwise — so `:hover` meant "hovered,
  # at every width". Set a hover colour with the panel on Mobile and the desktop changed with it, and
  # "on a phone, when touched" could not be said at all.
  describe "a state at a width" do
    test "the two axes compose, and a state at the widest width keeps its own name" do
      assert Styles.bucket(:base, :base) == :base
      assert Styles.bucket(:mobile, :base) == :mobile
      assert Styles.bucket(:base, :hover) == :hover
      assert Styles.bucket(:mobile, :hover) == :mobile_hover
      assert Styles.bucket(:tablet, :active) == :tablet_active
    end

    test "and every bucket says which two it came from" do
      for breakpoint <- [:base, :tablet, :mobile], pseudo <- [:base, :hover, :focus, :active] do
        bucket = Styles.bucket(breakpoint, pseudo)

        assert Styles.axes(bucket) == {breakpoint, pseudo},
               "#{bucket} does not read back as #{breakpoint}/#{pseudo}"
      end
    end

    # THE BUG, AS A CLASS. Tailwind composes the two the same way, so the pair is one variant chain.
    test "a hover at a width is a query AND a pseudo-class" do
      assert Styles.to_classes(%{mobile_hover: %{"background" => "#f00"}}) ==
               ["max-[560px]:hover:bg-[#f00]"]

      assert Styles.to_classes(%{tablet_focus: %{"color" => "#00f"}}) ==
               ["max-[900px]:focus:text-[#00f]"]
    end

    # AND A STATE WITH NO WIDTH IS STILL EVERY WIDTH, which is what keeps the common case cheap: one
    # hover on Desktop holds on a phone unless the phone says otherwise.
    test "a plain state is unchanged" do
      assert Styles.to_classes(%{hover: %{"background" => "#f00"}}) == ["hover:bg-[#f00]"]
    end

    test "the two live side by side without touching each other" do
      classes =
        Styles.to_classes(%{
          hover: %{"background" => "#111"},
          mobile_hover: %{"background" => "#222"}
        })

      assert classes == ["hover:bg-[#111]", "max-[560px]:hover:bg-[#222]"]
    end

    # ORDER IS THE CASCADE. Both are one class and one pseudo-class — the same specificity — so on a
    # phone the one written LAST wins, and the pair has to be it.
    test "and the pair is emitted after the plain state it narrows" do
      classes =
        Styles.to_classes(%{
          base: %{"gap" => "1px"},
          mobile: %{"gap" => "2px"},
          hover: %{"gap" => "3px"},
          mobile_hover: %{"gap" => "4px"}
        })

      assert classes == [
               "gap-[1px]",
               "max-[560px]:gap-[2px]",
               "hover:gap-[3px]",
               "max-[560px]:hover:gap-[4px]"
             ]
    end

    # PARSING HAS TO TAKE THE WHOLE CHAIN. Splitting on the first colon read `max-[560px]:hover:…` as
    # the plain breakpoint and left `hover:` sitting on the utility, where nothing recognises it — so
    # a page saved with a mobile hover reopened with that override simply gone.
    test "and it comes back as the pair it was" do
      assert Styles.from_classes("max-[560px]:hover:bg-[#f00]") ==
               {[], %{mobile_hover: %{"background" => "#f00"}}}

      assert Styles.from_classes("max-[900px]:active:p-[4px]") ==
               {[], %{tablet_active: %{"padding" => "4px"}}}
    end

    test "every pair survives a full cycle" do
      for breakpoint <- [:base, :tablet, :mobile],
          pseudo <- [:base, :hover, :focus, :active],
          prop <- Styles.properties() do
        bucket = Styles.bucket(breakpoint, pseudo)
        styles = %{bucket => %{prop => sample(prop)}}

        assert [class] = Styles.to_classes(styles)
        assert Styles.from_classes(class) == {[], styles}, "#{bucket}/#{prop} died as #{class}"
      end
    end

    # A raw property carries its own colon, and the variant split must not mistake it for one.
    test "a raw property inside a pair is still one class" do
      assert Styles.to_classes(%{mobile_hover: %{"font-size" => "2rem"}}) ==
               ["max-[560px]:hover:[font-size:2rem]"]

      assert Styles.from_classes("max-[560px]:hover:[font-size:2rem]") ==
               {[], %{mobile_hover: %{"font-size" => "2rem"}}}
    end

    test "and an unprefixed raw property is still not a variant" do
      assert Styles.from_classes("[font-size:3rem]") == {[], %{base: %{"font-size" => "3rem"}}}
    end
  end

  # A LIST IS THE SHAPE THE GUIDANCE ASKS FOR, so it is where an override really lands: every kit
  # component writes `class={[...]}`. Reading only the string form made the round trip one-way.
  describe "a class written as a list" do
    test "gives up its utilities and keeps the author's own elements" do
      assert Styles.split_list_expr(~S|["w-[1000px]", "text-sm"]|) ==
               {[{:classes, []}, {:classes, ["text-sm"]}], %{base: %{"width" => "1000px"}}}
    end

    test "passes anything that is not a literal through untouched, in place" do
      assert {parts, %{base: %{"width" => "1000px"}}} =
               Styles.split_list_expr(~S|["p-2", @flag && "x", "w-[1000px]"]|)

      assert parts == [{:classes, ["p-2"]}, {:logic, ~S|@flag && "x"|}, {:classes, []}]
    end

    test "and refuses an expression it cannot take apart" do
      assert Styles.split_list_expr("@variant") == :not_a_list
      assert Styles.split_list_expr("classes(@x)") == :not_a_list
    end

    test "an empty list leaves nothing of the author's" do
      assert Styles.split_list_expr(~S|["w-[1000px]"]|) ==
               {[{:classes, []}], %{base: %{"width" => "1000px"}}}

      assert Styles.split_list_expr(~S|["w-[1000px]"]|)
             |> elem(0)
             |> Styles.list_expr() == nil
    end

    # A CLASS IN A LIST IS A CLASS THE ELEMENT WEARS, and the minted `pb-xxxxxxxx` that names it to
    # its own CSS rule is spliced in here when the author's class is computed. So the classes have
    # to be readable where they sit, and writable back, with the author's logic left where it stands.
    test "its literal classes come out, and its logic comes out as it was written" do
      assert Styles.list_parts(~S|["a b", @flag && "x", "pb-11112222"]|) ==
               [{:classes, ["a", "b"]}, {:logic, ~S|@flag && "x"|}, {:classes, ["pb-11112222"]}]

      assert Styles.list_parts("@variant") == :not_a_list
      assert Styles.list_parts("classes(@x)") == :not_a_list
    end

    test "and the parts spell the expression back, or nothing when none is left of them" do
      parts = [{:classes, ["a", "b"]}, {:logic, "@variant"}]

      assert Styles.list_expr(parts) == ~S|["a b", @variant]|

      assert Styles.list_expr(parts ++ [{:classes, ["pb-11112222"]}]) ==
               ~S|["a b", @variant, "pb-11112222"]|

      assert Styles.list_expr([{:classes, []}]) == nil
      assert Styles.list_expr([]) == nil
    end

    # A COMMA CANNOT FOLLOW EVERY EXPRESSION. Splicing the name in by hand wrote
    # `[if @x, do: "a", else: "b", "pb-11112222"]`, which is a syntax error — a page that will not
    # compile, wearing a name nothing reads back. So the splice is parsed again before it is kept.
    test "a class joins an expression only in a form that reads back as a list" do
      assert Styles.add_expr_classes("@variant", ["pb-11112222"]) ==
               ~S|[@variant, "pb-11112222"]|

      assert Styles.add_expr_classes(~S|["a"]|, ["pb-11112222"]) == ~S|["a", "pb-11112222"]|

      spliced = Styles.add_expr_classes(~S|if @x, do: "a", else: "b"|, ["pb-11112222"])

      assert Styles.list_parts(spliced) != :not_a_list
      assert {:classes, ["pb-11112222"]} == List.last(Styles.list_parts(spliced))
    end

    test "and an expression that is not one answers nothing rather than a guess" do
      assert Styles.add_expr_classes(~S|@variant ++|, ["pb-11112222"]) == nil
    end
  end
end
