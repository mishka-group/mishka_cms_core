# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.ElementCssTest do
  @moduledoc """
  CSS an author writes for one element: the scope class that names it, the row that holds the rule,
  and the one structural rule that keeps the text from reaching anything else on the page.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles

  @scope "pb-11112222"
  @other "pb-33334444"
  @owner "page-x"

  defp tree_with_p do
    {:ok, tree} = Tree.parse(~s(<div><p>hi</p></div>))
    node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
    {tree, node.id}
  end

  # WHAT THE VISITOR ENDS UP WITH. The row's content IS `css/1`, and every later read of it — the
  # panel reopening, the next element's save, the pruning that runs when the document is saved — is
  # `parse/1`. A body that comes back out of that pair unchanged is a body the author keeps and the
  # browser is served; one that does not is lost the first time anything reads the row again, however
  # correctly it was written.
  defp kept(rules), do: rules |> ElementCss.css() |> ElementCss.parse()

  defp kept_body(body), do: kept(%{@scope => body})[@scope]

  # `put/5` validates before it writes, so a refusal is reachable with no row to write into. The
  # message, not the tuple: a body that is taken goes on to the database, which this test has none of.
  defp refused(body) do
    case ElementCss.put(nil, nil, @owner, @scope, body) do
      {:error, message} when is_binary(message) -> message
      _taken -> nil
    end
  end

  describe "the scope class" do
    test "an element has none until it is given one" do
      {tree, id} = tree_with_p()
      assert Tree.scope(tree, id) == nil
    end

    test "minting adds a class to the markup, so it survives a save and a re-parse" do
      {tree, id} = tree_with_p()
      {tree, scope} = Tree.ensure_scope(tree, id)

      assert scope =~ ~r/^pb-[a-f0-9]{8}$/

      html = Serializer.serialize(tree)
      assert html =~ scope

      {:ok, reparsed} = Tree.parse(html)
      again = reparsed |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
      assert Tree.scope(reparsed, again.id) == scope
    end

    test "minting twice gives the same class" do
      {tree, id} = tree_with_p()
      {tree, first} = Tree.ensure_scope(tree, id)
      {_tree, second} = Tree.ensure_scope(tree, id)

      assert first == second
    end

    test "two elements never share one" do
      {:ok, tree} = Tree.parse(~s(<div><p>a</p><p>b</p></div>))
      [one, two] = tree |> Tree.walk() |> Enum.filter(&(&1.tag == "p"))

      {tree, a} = Tree.ensure_scope(tree, one.id)
      {_tree, b} = Tree.ensure_scope(tree, two.id)

      refute a == b
    end

    test "it sits alongside the author's own classes, and dropping it leaves them" do
      {:ok, tree} = Tree.parse(~s(<div><p class="lead big">hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {tree, scope} = Tree.ensure_scope(tree, node.id)
      html = Serializer.serialize(tree)
      assert html =~ "lead big #{scope}"

      dropped = Tree.drop_scope(tree, node.id)
      assert Tree.scope(dropped, node.id) == nil

      html = Serializer.serialize(dropped)
      assert html =~ ~s(class="lead big")
      refute html =~ scope
    end

    # AN EXPRESSION IS THE CLASS, and naming the element is not a licence to flatten it. The writer
    # rebuilt the attribute as a string from the classes it could read, so `class={@variant}` came
    # back as the literal text `pb-…`: the value the component works out at render time destroyed by
    # opening the Custom CSS box. The name joins the expression as a list element instead — the shape
    # an override already uses, and one HEEx flattens — and the reader has to find it there, or the
    # next visit mints a second name beside the first.
    test "an element whose class is an expression keeps it when it is named" do
      {:ok, tree} = Tree.parse(~s(<div><p class={@variant}>hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {tree, scope} = Tree.ensure_scope(tree, node.id)
      html = Serializer.serialize(tree)
      assert html =~ ~s(class={[@variant, "#{scope}"]})

      {:ok, reparsed} = Tree.parse(html)
      again = reparsed |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
      assert Tree.scope(reparsed, again.id) == scope
      assert Tree.ensure_scope(reparsed, again.id) == {reparsed, scope}

      dropped = Tree.drop_scope(tree, node.id)
      assert Tree.scope(dropped, node.id) == nil
      assert Serializer.serialize(dropped) =~ "@variant"
      refute Serializer.serialize(dropped) =~ scope
    end

    # AND NOT EVERY EXPRESSION IS ONE A COMMA CAN FOLLOW. `class={if @x, do: "a", else: "b"}` ends
    # in a keyword list written without brackets, so a name spliced in after it is a syntax error:
    # the page stops compiling and can no longer be saved at all, and the name it was just given
    # reads back as no name — invisible to its own rule, impossible to drop, and minted again one
    # list deeper on every visit to the Custom CSS box.
    test "a name joins an expression a comma cannot follow, and the page still compiles" do
      {:ok, tree} = Tree.parse(~s(<div><p class={if @x, do: "a", else: "b"}>hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {tree, scope} = Tree.ensure_scope(tree, node.id)
      html = Serializer.serialize(tree)

      assert CodeCheck.template(html) == :ok
      assert html =~ "@x"

      {:ok, reparsed} = Tree.parse(html)
      again = reparsed |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      assert Tree.scope(reparsed, again.id) == scope
      assert Tree.ensure_scope(reparsed, again.id) == {reparsed, scope}

      dropped = Tree.drop_scope(reparsed, again.id)
      assert Tree.scope(dropped, again.id) == nil
      assert CodeCheck.template(Serializer.serialize(dropped)) == :ok
      refute Serializer.serialize(dropped) =~ scope
    end

    # AND A NAME THAT COULD NOT BE WRITTEN IS NO NAME. The attribute row takes whatever the author
    # types, half-finished expressions included, and nothing can be spliced into one that is not
    # Elixir. Answering with the minted class anyway files the rule under a class that is nowhere on
    # the page, so the name is read back off the element rather than assumed.
    test "an expression nothing can be spliced into is left alone, and named nothing" do
      {:ok, tree} = Tree.parse(~s(<div><p>hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))
      {:ok, tree} = Tree.set_attr(tree, node.id, "class", {:expr, "@variant ++"})

      assert Tree.ensure_scope(tree, node.id) == {tree, nil}
      assert Serializer.serialize(tree) =~ "@variant ++"
    end

    # The class is a CSS key AND the handle an interaction points at. Taking it off because the CSS
    # box is now empty would leave a `JS.toggle_class(to: ".pb-…")` naming an element that no longer
    # answers to the name.
    test "it stays while an interaction on the same element still names it" do
      {tree, id} = tree_with_p()
      {tree, scope} = Tree.ensure_scope(tree, id)

      {:ok, tree} =
        Tree.set_attr(tree, id, "phx-click", {:expr, ~s|JS.toggle_class("on", to: ".#{scope}")|})

      assert Tree.scope(Tree.drop_scope(tree, id), id) == scope

      {:ok, tree} = Tree.delete_attr(tree, id, "phx-click")
      assert Tree.scope(Tree.drop_scope(tree, id), id) == nil
    end

    # AND WHAT THE ROW KEEPS IS THE AUTHOR'S EXPRESSION WITH IT. This branch exists precisely
    # because the row must NOT clear, so rebuilding it as the bare name — how a string class clears
    # down to the one it may not lose — turned `class={[@variant, "pb-…"]}` into the string
    # `class="pb-…"`: protecting the handle destroyed the class the component works out.
    test "clearing the class row keeps the name in the expression, and the expression" do
      {:ok, tree} = Tree.parse(~s(<div><p class={[@variant, "lead", "#{@scope}"]}>hi</p></div>))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "p"))

      {:ok, tree} =
        Tree.set_attr(
          tree,
          node.id,
          "phx-click",
          {:expr, ~s|JS.toggle_class("on", to: ".#{@scope}")|}
        )

      {:ok, cleared} = Tree.delete_attr(tree, node.id, "class")

      assert Tree.scope(cleared, node.id) == @scope
      assert Serializer.serialize(cleared) =~ ~s(class={[@variant, "#{@scope}"]})
    end

    test "an unrelated attribute does not keep it alive" do
      {tree, id} = tree_with_p()
      {tree, _scope} = Tree.ensure_scope(tree, id)
      {:ok, tree} = Tree.set_attr(tree, id, "title", {:string, "a note"})

      assert Tree.scope(Tree.drop_scope(tree, id), id) == nil
    end

    # A RULE IS FILED UNDER A MINTED CLASS OR NOT AT ALL. `Tree.scope/2` never answers with one of
    # the author's own classes, so a rule keyed on one is a rule nothing reads back and the pruning
    # on the next save cannot tell from a rule whose element is gone.
    test "a rule may not be filed under anything but a minted class" do
      assert {:error, "That element has no style scope."} =
               ElementCss.put(nil, nil, @owner, "lede", "color: red;")

      assert {:error, "That element has no style scope."} =
               ElementCss.put(nil, nil, @owner, "#{@scope} lede", "color: red;")

      assert {:error, "That element has no style scope."} =
               ElementCss.put(nil, nil, @owner, nil, "color: red;")
    end
  end

  describe "css/1 and parse/1 are inverses" do
    test "a flat body" do
      rules = %{"pb-11112222" => "padding: 20px;"}

      assert ElementCss.css(rules) =~ ".pb-11112222 {"
      assert ElementCss.parse(ElementCss.css(rules)) == rules
    end

    # THE CASE A REGULAR EXPRESSION GETS WRONG. A body nests — that is the point of the feature — and
    # a pattern that stopped at the first `}` would truncate every rule that used `&:hover`.
    test "a nested body survives the round trip whole" do
      body = "padding: 20px;\n\n&:hover {\n  transform: translateY(-2px);\n}"
      rules = %{"pb-aaaabbbb" => body}

      assert ElementCss.parse(ElementCss.css(rules)) == rules
    end

    test "a media query survives too" do
      body = "@media (max-width: 900px) {\n  padding: 12px;\n}"

      assert ElementCss.parse(ElementCss.css(%{"pb-ccccdddd" => body})) == %{
               "pb-ccccdddd" => body
             }
    end

    test "several rules, in a stable order so the row does not churn" do
      rules = %{"pb-22223333" => "gap: 4px;", "pb-11112222" => "gap: 8px;"}

      css = ElementCss.css(rules)
      assert :binary.match(css, "pb-11112222") < :binary.match(css, "pb-22223333")
      assert ElementCss.parse(css) == rules
    end

    test "an empty set is an empty string, and anything unrecognised parses to nothing" do
      assert ElementCss.css(%{}) == ""
      assert ElementCss.parse("/* nothing here */") == %{}
      assert ElementCss.parse(nil) == %{}
    end
  end

  describe "live_rules/2" do
    # What prunes the rule for an element somebody deleted, without anything having to notice the
    # deletion.
    test "keeps what the tree still points at and drops the rest" do
      {tree, id} = tree_with_p()
      {tree, scope} = Tree.ensure_scope(tree, id)

      rules = %{scope => "gap: 4px;", "pb-deadbeef" => "gap: 9px;"}

      assert ElementCss.live_rules(tree, rules) == %{scope => "gap: 4px;"}
    end

    # A NAME INSIDE A LIST EXPRESSION IS ONE THE ELEMENT WEARS. It is where the name goes when the
    # author's class is computed, so a reader that saw only `class="…"` took the element's own rule
    # for a dead one — and this is what the save prunes with.
    test "a name spliced into a list expression is one the tree still points at" do
      {:ok, tree} = Tree.parse(~s(<div><p class={[@variant, "#{@scope}"]}>hi</p></div>))

      assert ElementCss.live_rules(tree, %{@scope => "gap: 4px;", "pb-deadbeef" => "gap: 9px;"}) ==
               %{@scope => "gap: 4px;"}
    end
  end

  describe "what a body may say" do
    setup do
      {tree, id} = tree_with_p()
      {_tree, scope} = Tree.ensure_scope(tree, id)
      %{scope: scope}
    end

    # `put/5` reaches the database, so the rules themselves are asserted through `css/1` and the
    # refusals through the error tuple — the validation is the part worth pinning.
    test "an unmatched brace is refused", %{scope: scope} do
      assert {:error, message} = ElementCss.put(nil, nil, "page-x", scope, "padding: 1px; }")
      assert message =~ "unmatched"

      assert {:error, _message} = ElementCss.put(nil, nil, "page-x", scope, "&:hover { gap: 1px;")
    end

    # THE ONE WAY OUT OF THE WRAPPER is a `}` typed at the top level, which closes it early and
    # leaves everything after it loose on the whole site. A nested selector cannot escape: under CSS
    # nesting `body { … }` inside the braces means `.pb-xxxxxxxx body { … }`.
    #
    # An earlier version of this test asserted `{:error, _}` for a bare nested selector and passed —
    # not because a guard refused it, but because the write reached the database and failed there.
    # Asserting on the message is what makes the difference visible, and what showed that the rule
    # demanding `&` refused `body { … }` written first while allowing it after a declaration.
    test "a `}` typed at the top level is refused, wherever it is", %{scope: scope} do
      for body <- [
            "gap: 1px; } body { display: none; ",
            "} &:hover { gap: 1px; }",
            "&:hover { gap: 1px; } } .evil { gap: 2px; }"
          ] do
        assert {:error, "That CSS has an unmatched { or }."} =
                 ElementCss.put(nil, nil, "page-x", scope, body),
               "#{body} escaped the wrapper"
      end
    end

    test "a descendant selector is allowed, because nesting keeps it inside", %{scope: scope} do
      for body <- [
            "body { display: none; }",
            "gap: 1px;\n.other { gap: 2px; }",
            "& > .badge { color: red; }"
          ] do
        refute match?(
                 {:error, message} when is_binary(message),
                 ElementCss.put(nil, nil, "page-x", scope, body)
               ),
               "#{body} was refused by the guard"
      end
    end

    test "an element with no scope is refused" do
      assert {:error, message} = ElementCss.put(nil, nil, "page-x", nil, "gap: 1px;")
      assert message =~ "scope"

      assert {:error, _message} = ElementCss.put(nil, nil, "page-x", "not-a-scope", "gap: 1px;")
    end
  end

  describe "the row" do
    test "is named for the document it belongs to" do
      assert ElementCss.row_name("page-abc") == "builder-elements-page-abc"
      refute ElementCss.row_name("page-abc") == ElementCss.row_name("page-def")
    end
  end

  describe "reading declarations back out" do
    test "a top-level declaration competes with the base bucket" do
      assert [%{bucket: :base, property: "padding", value: "20px"}] =
               ElementCss.declarations("padding: 20px;")
    end

    test "the last declaration needs no semicolon" do
      assert [%{property: "gap", value: "4px"}] = ElementCss.declarations("gap: 4px")
    end

    test "a pseudo block competes with its own bucket, not with base" do
      body = "padding: 1px;\n&:hover { opacity: .8; }\n&:focus { color: red }"

      assert [
               %{bucket: :base, property: "padding"},
               %{bucket: :hover, property: "opacity"},
               %{bucket: :focus, property: "color"}
             ] = ElementCss.declarations(body)
    end

    # A media query an author wrote by hand need not use the panel's breakpoints, and `& > .badge`
    # styles something that is not this element at all. Claiming either as a collision would be a
    # guess dressed as a fact.
    test "a media query and a descendant selector are not claimed" do
      body = """
      @media (max-width: 900px) { padding: 12px; }
      & > .badge { position: absolute; }
      &:hover { & .deep { color: red; } }
      """

      assert ElementCss.declarations(body) == []
    end

    test "a comment holding a semicolon does not split a declaration" do
      body = "/* one; two: three */\ngap: 8px;"

      assert [%{property: "gap", value: "8px"}] = ElementCss.declarations(body)
    end

    test "custom properties and at-rules are not declarations a control could hold" do
      assert ElementCss.declarations("--brand: red;\n@apply p-4;\ngap: 2px;")
             |> Enum.map(& &1.property) == ["gap"]
    end

    test "half-typed CSS is read without crashing" do
      assert [%{property: "padding"}] = ElementCss.declarations("padding: 2px; &:hover {")
      assert ElementCss.declarations("") == []
      assert ElementCss.declarations(nil) == []
    end

    test "a multi-byte value survives the byte offsets" do
      assert [%{value: ~s|"héllo"|}] = ElementCss.declarations(~s|content: "héllo"|)
    end

    # `url("a;b.png")` holds a `;` that ends nothing. Splitting on it would cut a declaration in two.
    test "a semicolon inside a quoted value ends nothing" do
      body = ~s|background-image: url("a;b.png");\ngap: 4px;|

      assert [%{property: "background-image"}, %{property: "gap", value: "4px"}] =
               ElementCss.declarations(body)

      assert ElementCss.without(body, 1) == ~s|background-image: url("a;b.png");|
    end

    test "an escaped quote does not end the string early" do
      assert [%{property: "content"}, %{property: "gap"}] =
               ElementCss.declarations(~s|content: "a\\";b"; gap: 1px;|)
    end
  end

  # On a plain tag `& > .badge` is ordinary CSS about the author's own markup. On a COMPONENT it aims
  # a rule at markup the kit owns and the next version of the kit is free to rename.
  describe "selectors that reach past the element" do
    test "a descendant or child selector is one" do
      assert ElementCss.reaching_selectors("& > .badge { color: red }") == ["& > .badge"]
      assert ElementCss.reaching_selectors("& .title { color: red }") == ["& .title"]
      assert ElementCss.reaching_selectors(".loose { color: red }") == [".loose"]
    end

    test "the element itself is not" do
      assert ElementCss.reaching_selectors("padding: 2px;") == []
      assert ElementCss.reaching_selectors("&:hover { opacity: .5 }") == []
      assert ElementCss.reaching_selectors("&:focus { opacity: .5 }") == []
      assert ElementCss.reaching_selectors("&.is-open { opacity: 1 }") == []
      assert ElementCss.reaching_selectors("&[data-x] { opacity: 1 }") == []
    end

    # `@media (…)` styles this element at a width. It is not a selector and reaches nothing.
    test "an at-rule is not one" do
      assert ElementCss.reaching_selectors("@media (max-width: 900px) { padding: 2px; }") == []
    end

    test "each is named once however often it is written" do
      body = "& .title { color: red }\n& .title { font-weight: 700 }\n& .sub { color: blue }"

      assert ElementCss.reaching_selectors(body) == ["& .title", "& .sub"]
    end

    test "blank and half-typed bodies answer nothing rather than crashing" do
      assert ElementCss.reaching_selectors(nil) == []
      assert ElementCss.reaching_selectors("") == []
      assert ElementCss.reaching_selectors("& > .badge {") == ["& > .badge"]
    end
  end

  describe "taking one declaration out" do
    test "removes exactly that line and leaves the rest alone" do
      body = "padding: 20px;\n/* keep me */\ngap: 4px;"

      assert ElementCss.without(body, 0) == "/* keep me */\ngap: 4px;"
      assert ElementCss.without(body, 1) == "padding: 20px;\n/* keep me */"
    end

    test "reaches inside a pseudo block" do
      body = "padding: 1px;\n&:hover {\n  opacity: .8;\n  color: red;\n}"

      assert ElementCss.without(body, 1) == "padding: 1px;\n&:hover {\n  color: red;\n}"
    end

    # A panel rendered against an older body must never delete a different rule than the one whose
    # button was pressed.
    test "an index that is not there changes nothing" do
      body = "padding: 20px;"

      assert ElementCss.without(body, 9) == body
      assert ElementCss.without(body, -1) == body
    end

    test "what is left still reads back as the declarations that remain" do
      body = "padding: 20px;\ngap: 4px;\n&:hover { opacity: .5; }"

      assert body |> ElementCss.without(0) |> ElementCss.declarations() |> Enum.map(& &1.property) ==
               ["gap", "opacity"]
    end
  end

  # THE MISTAKE THIS BOX INVITES. The pane is titled with the element — `main — this element's own` —
  # so an author writes what looks like the rule for it, gets a rule for a `main` INSIDE it, is told
  # "Style applied.", and watches the page not change. Valid CSS, saved correctly, and
  # indistinguishable from a broken feature.
  describe "advice about CSS that is valid and probably not what was meant" do
    test "a bare element selector is named, with what to write instead" do
      advice = ElementCss.advice("main {color: red}")

      assert advice =~ "`main`"
      assert advice =~ "INSIDE this element"
      assert advice =~ "&"
    end

    test "several of them are named together" do
      advice = ElementCss.advice("main { color: red } span { color: blue }")

      assert advice =~ "`main`"
      assert advice =~ "`span`"
    end

    # The rule this replaces was a regex anchored on `^` or `}`, which could not see a selector that
    # followed a declaration — it refused the mistake written first and allowed it written second.
    test "including one written after a declaration" do
      assert ElementCss.advice("padding: 4px;\nmain { color: red }") =~ "`main`"
    end

    test "plain declarations are what the box is for, and draw nothing" do
      assert ElementCss.advice("color: red;") == nil
      assert ElementCss.advice("padding: 20px;\n\nmargin: 0;") == nil
    end

    test "and neither does a selector that really does mean this element" do
      assert ElementCss.advice("padding: 20px;\n\n&:hover { opacity: .8; }") == nil
      assert ElementCss.advice("& > .child { color: red }") == nil
    end

    # An at-rule carries declarations for this element, so it is not a descendant.
    test "nor an at-rule" do
      assert ElementCss.advice("@media (max-width: 900px) { padding: 12px; }") == nil
    end

    test "nothing to say about nothing" do
      assert ElementCss.advice("") == nil
      assert ElementCss.advice(nil) == nil
    end
  end

  # THE WHOLE TRIP, FOR THE CASES SOMEBODY ACTUALLY TYPES. Every test below asks the three questions
  # the author cannot ask for themselves: does the box take it, does the compiler ship it, and is it
  # still there the next time anything reads the row.
  describe "plain declarations" do
    test "one is wrapped in the element's own class and nothing else" do
      assert ElementCss.css(%{@scope => "padding: 20px;"}) ==
               ".pb-11112222 {\n  padding: 20px;\n}\n"
    end

    test "several survive, with a trailing semicolon and without" do
      for body <- [
            "padding: 20px;",
            "padding: 20px",
            "padding: 20px;\nmargin: 0;\ngap: 4px;",
            "padding: 20px;\nmargin: 0;\ngap: 4px"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end

    test "and read back as the lines a control could hold" do
      assert "padding: 20px;\nmargin: 0;\ngap: 4px"
             |> ElementCss.declarations()
             |> Enum.map(&{&1.bucket, &1.property, &1.value}) ==
               [{:base, "padding", "20px"}, {:base, "margin", "0"}, {:base, "gap", "4px"}]
    end
  end

  describe "the selectors that still mean this element" do
    test "a state, a child and a class all survive the row" do
      for body <- [
            "&:hover { transform: translateY(-2px); }",
            "& > .child { color: red; }",
            "&.is-open { display: block; }"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
        assert ElementCss.advice(body) == nil, body
      end
    end

    test "a state block competes with the control wearing the same selector" do
      assert [%{bucket: :hover, property: "opacity", value: ".8"}] =
               ElementCss.declarations("&:hover { opacity: .8; }")
    end

    # `&.is-open` is this element with a class on it, which is exactly what an interaction toggles —
    # so it reaches nothing, while `& > .child` reaches markup that may not be the author's.
    test "only the ones that leave the element are named as reaching" do
      assert ElementCss.reaching_selectors("&.is-open { display: block; }") == []
      assert ElementCss.reaching_selectors("& > .child { color: red; }") == ["& > .child"]
    end
  end

  describe "at-rules" do
    test "@media and @supports keep what they hold for this element" do
      for body <- [
            "@media (max-width: 900px) {\n  padding: 12px;\n}",
            "@supports (display: grid) {\n  display: grid;\n}",
            "@media (max-width: 900px) {\n  padding: 12px;\n\n  &:hover {\n    opacity: .8;\n  }\n}"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
        assert ElementCss.advice(body) == nil, body
        assert ElementCss.reaching_selectors(body) == [], body
      end
    end

    # A media query written by hand need not use the panel's breakpoints, so nothing inside one is
    # claimed as competing with a control: saying Padding is overridden at a width the panel cannot
    # name would be a guess dressed as a fact. The declaration is still in the rule the visitor gets.
    test "and nothing inside one is claimed by a control" do
      assert ElementCss.declarations("@media (max-width: 900px) { padding: 12px; }") == []
      assert ElementCss.css(%{@scope => "@media (max-width: 900px) { padding: 12px; }"}) =~ "12px"
    end
  end

  # THE DEFECT THESE FOUND. Every one of them was refused with "That CSS has an unmatched { or }." —
  # the author counts their braces, finds them matched, and the box has nothing more to say. The
  # check counted the braces inside strings and comments; so did the read-back, so a body that got
  # past it would have been truncated at the quote the next time the row was read.
  describe "a brace or a semicolon that is text" do
    test "inside a string it opens, closes and ends nothing" do
      for body <- [
            ~s|content: "}";|,
            ~s|content: "{";|,
            ~s|background-image: url("a}b.png");|,
            ~s|background-image: url("a;b.png");\ngap: 4px;|
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end

    test "inside a comment it does the same" do
      for body <- ["/* } */\ngap: 1px;", "/* { */\ngap: 1px;", "&:hover { /* } */ opacity: .5; }"] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end

    # `\"` is a character, not the end of the string, so the `;` after it splits nothing. If it did,
    # the tail of the line would be read as a second declaration and offered to a control as one.
    test "and an escaped quote holds all the way through the row" do
      body = ~s|content: "a\\";b";\ngap: 1px;|

      refute refused(body)
      assert kept_body(body) == body

      assert [%{property: "content"}, %{property: "gap", value: "1px"}] =
               ElementCss.declarations(body)
    end

    # The scanner that finds where a block ends reads strings too, or `opacity` here is read as a
    # top-level declaration and offered to the base control it never belonged to.
    test "a quoted brace does not end the block it sits in" do
      assert [%{bucket: :hover, property: "content"}, %{bucket: :hover, property: "opacity"}] =
               ElementCss.declarations(~s|&:hover { content: "}"; opacity: .5 }|)
    end

    # The advice used to read the quote as the start of a block and tell the author they had styled
    # an element called `content: "` inside their own one.
    test "and it is not advice about an element inside this one" do
      assert ElementCss.advice(~s|content: "{";|) == nil
      assert ElementCss.advice("/* { */\ngap: 1px;") == nil
    end

    # Skipping them must not cost the advice the mistake it is there for: the bare tag written after
    # one is still a rule for something inside this element, and is still named.
    test "though the mistake written after one is still caught" do
      assert ElementCss.advice(~s|content: "{"; main { color: red }|) =~ "`main`"
      assert ElementCss.advice("/* { */ main { color: red }") =~ "`main`"
    end

    # Skipping a string must not become the way out of the wrapper: a `}` written after one still
    # closes it early, and is still refused.
    test "but a real closing brace is not smuggled past on the back of one" do
      assert refused(~s|content: "{"; } .evil { color: red }|) ==
               "That CSS has an unmatched { or }."

      assert refused("/* } */ } .evil { color: red }") == "That CSS has an unmatched { or }."
    end

    # A COMMENT NOBODY CLOSED IS NOT THE SAME MISTAKE, and refusing it with the brace message would
    # send the author looking for a brace that is fine. It swallows the `}` that ends the wrapper, so
    # everything after it in the stylesheet is eaten until the next `*/`.
    test "a comment left open is refused, and says so in its own words" do
      assert refused("/* never closed\ngap: 1px;") == "That CSS has a /* that is never closed."
    end

    # `css/1` indents every line of a body, so a line inside a string can never look like the start
    # of the next rule when the row is split back up again.
    test "a body that quotes a whole rule does not split the row" do
      body = ~s|content: ".pb-abcdabcd {";\ngap: 1px;|

      refute refused(body)
      assert kept_body(body) == body
    end
  end

  describe "values that stay in the text" do
    test "a custom property and the var that reads it both survive" do
      body = "--brand: red;\ncolor: var(--brand);"

      refute refused(body)
      assert kept_body(body) == body
      assert ElementCss.declarations(body) |> Enum.map(& &1.property) == ["color"]
    end

    # The index a Move button carries is a position in `declarations/1`, and the custom property is
    # not one of them. Cutting by that index has to take the line the author was shown and leave the
    # property the value it moves still reads.
    test "moving the var takes the var's line and leaves the property above it" do
      body = "--brand: red;\ncolor: var(--brand);"

      assert Styles.from_declaration("color", "var(--brand)") == {:ok, {"color", "var(--brand)"}}
      assert ElementCss.without(body, 0) == "--brand: red;"
    end

    # A utility carries no `!important`, so a value leaning on one would quietly stop winning the
    # moment it moved. It stays in the text, where it does win, and the control is marked as taken
    # over rather than offered.
    test "!important is kept, and is not offered to a control" do
      body = "color: red !important;"

      refute refused(body)
      assert kept_body(body) == body
      assert [%{property: "color", value: "red !important"}] = ElementCss.declarations(body)
      assert Styles.from_declaration("color", "red !important") == :error
      assert Styles.controls_for("color") == ["color"]
    end
  end

  # WHAT MOVING A LINE LEAVES THE VISITOR WITH. The declaration comes out of the text, where it beat
  # everything, and goes on as a utility, which only beats the classes it supersedes — so the classes
  # it supersedes have to go with it.
  describe "a line moved into a control" do
    test "the utility replaces the authored classes it swallows" do
      assert Styles.from_declaration("padding", "20px") == {:ok, {"padding", "20px"}}

      assert Styles.merge_class("px-6 py-16 rounded", %{base: %{"padding" => "20px"}}) ==
               "rounded p-[20px]"
    end

    test "a shorthand marks every control it covers, not only its own" do
      assert Styles.controls_for("padding") == ["padding", "py", "px", "pt", "pb", "pl", "pr"]
      assert Styles.controls_for("padding-block") == ["py", "pt", "pb"]
      assert Styles.controls_for("padding-inline") == ["px", "pl", "pr"]
    end

    # The spacing box splits margin four ways too, so a hand-written `margin` in this box overrules
    # eight controls rather than the two it used to.
    test "and the same holds for the margin the box now splits" do
      assert Styles.controls_for("margin") == ["margin", "my", "mx", "mt", "mb", "ml", "mr"]
      assert Styles.controls_for("margin-block") == ["my", "mt", "mb"]
      assert Styles.controls_for("margin-inline") == ["mx", "ml", "mr"]
    end

    test "a property no control owns is neither moved nor marked" do
      assert Styles.from_declaration("border-image", "url(x.png)") == :error
      assert Styles.controls_for("border-image") == []
      assert Styles.from_declaration("content", ~s|"}"|) == :error
      assert Styles.controls_for("content") == []
    end
  end

  describe "emptying the box" do
    # The rule and the class are two halves of one thing: leaving the class behind names a rule that
    # is gone, and leaving the rule behind styles an element nothing points at.
    test "clears the rule and takes the class back off the element" do
      {tree, id} = tree_with_p()
      {tree, scope} = Tree.ensure_scope(tree, id)

      assert kept(%{scope => "gap: 4px;"}) == %{scope => "gap: 4px;"}

      assert {:ok, rules} = ElementCss.put(nil, nil, @owner, scope, "")
      refute Map.has_key?(rules, scope)

      assert {:ok, blank} = ElementCss.put(nil, nil, @owner, scope, "  \n  ")
      refute Map.has_key?(blank, scope)

      dropped = Tree.drop_scope(tree, id)
      assert Tree.scope(dropped, id) == nil
      refute Serializer.serialize(dropped) =~ scope
      assert ElementCss.live_rules(dropped, %{scope => "gap: 4px;"}) == %{}
    end
  end

  # ONE ROW HOLDS THE WHOLE DOCUMENT, so the only thing keeping one element's CSS out of another's is
  # the scope each rule is keyed on — including when the first body is full of braces that are text.
  describe "more than one element, and more than one edit" do
    test "two elements keep their own rule and neither reads the other's" do
      rules = %{@scope => ~s|content: "}";\ngap: 4px;|, @other => "gap: 9px;"}

      assert kept(rules) == rules

      css = ElementCss.css(rules)
      assert css =~ ".#{@scope} {"
      assert css =~ ".#{@other} {"
      refute ElementCss.css(%{@scope => "gap: 4px;"}) =~ @other
    end

    test "the second body replaces the first rather than joining it" do
      first = kept(%{@scope => "gap: 4px;"})
      second = kept(Map.put(first, @scope, "gap: 9px;"))

      assert second == %{@scope => "gap: 9px;"}
      refute ElementCss.css(second) =~ "4px"
    end

    test "and editing one element leaves the other's rule alone" do
      rules = kept(%{@scope => "gap: 4px;", @other => "gap: 9px;"})
      edited = kept(Map.put(rules, @scope, "gap: 1px;"))

      assert edited == %{@scope => "gap: 1px;", @other => "gap: 9px;"}
    end
  end
end
