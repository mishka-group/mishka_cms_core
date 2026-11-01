# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.ElementCssTest do
  @moduledoc """
  CSS an author writes for one element: the scope class that names it, the row that holds the rule,
  and the one structural rule that keeps the text from reaching anything else on the page.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.Authoring.CodeCheck
  alias MishkaCmsCore.Runtime.Authoring.ElementCss
  alias MishkaCmsCore.Runtime.Authoring.ElementScopes
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Serializer
  alias MishkaCmsCore.Runtime.Authoring.Tree.Styles

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

  # The parser's verdict, `place/3`: `put/5` also builds a body holding an `@apply` with Tailwind,
  # which reads the site's stylesheets from the database this test has none of. That build is
  # `element_css_apply_test.exs`.
  defp refused(body) do
    case ElementCss.place(%{}, @scope, body) do
      {:error, message} when is_binary(message) -> message
      {:ok, _rules} -> nil
    end
  end

  # Where the parser put the first error, as the refusal names it.
  defp at(line, column), do: "That CSS has an error on line #{line}, column #{column}"

  @closes "This `}` closes the block it is written in; everything after it is outside."

  defp closed_early(line, column), do: "#{at(line, column)}, at `}`: #{@closes}"

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

    # EIGHT DIGITS ARE A TAILWIND UTILITY. This id hashes to `29496066…`, and `pb-29496066` is
    # padding-bottom of 29496066 spacing steps to the run that builds the site's stylesheet.
    test "a hash with no letter in it is given one" do
      {_tree, scope} = "nh2wv4v6l" |> lone_p() |> Tree.ensure_scope("nh2wv4v6l")

      assert scope == "pb-c9496066"
      assert ElementScopes.scope?(scope)
      assert ElementScopes.scope_for(<<0x29, 0x49, 0x60, 0x66>>) == scope
    end

    # Every element named before keeps the class its rule is filed under.
    test "a hash with a letter in it is the class it always was" do
      {_tree, scope} = "nabcdefgh" |> lone_p() |> Tree.ensure_scope("nabcdefgh")

      assert scope == "pb-c0f920e3"
      assert ElementScopes.scope_for(<<0x7F, 0x3A, 0x91, 0xB2>>) == "pb-7f3a91b2"
    end
  end

  # One element under the id given, which is what its scope is hashed from.
  defp lone_p(id) do
    {:ok, tree} = Tree.parse(~s(<p class="lead"></p>))
    [root] = tree.roots
    %Tree{nodes: %{id => %{Tree.get(tree, root) | id: id}}, roots: [id]}
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
      assert message == closed_early(1, 15)

      assert {:error, message} = ElementCss.put(nil, nil, "page-x", scope, "&:hover { gap: 1px;")
      assert message == "#{at(1, 20)}: Expected a `}` to close the `{` on line 1, column 9."
    end

    # A BODY TAILWIND CANNOT PARSE STOPS EVERY STYLESHEET IT IS IN, not just its own rule: the site's
    # CSS build fails and keeps its last good bundle, the draft preview cannot build its styles, and
    # the canvas stops generating for the whole page. Its braces all match, so a brace check let each
    # of these through. The parser reads a word with no colon as the start of a nested selector, and
    # igniter_css names it as the declaration it is, where the author wrote it.
    test "a declaration with no colon is refused, where it starts" do
      for {body, line, column, property} <- [
            {"color crimson", 1, 1, "color"},
            {"color crimson;", 1, 1, "color"},
            {"gap: 1px;\n/* note */ color crimson;\nmargin: 0;", 2, 12, "color"},
            {"color: red; background", 1, 13, "background"},
            {"--brand;", 1, 1, "--brand"},
            {"&:hover { color navy }", 1, 11, "color"},
            {"@media (max-width: 600px) { color red }", 1, 29, "color"}
          ] do
        message = refused(body)
        assert message =~ at(line, column), body
        assert message =~ ": Expected a `:` after the property name `#{property}`.", body
      end
    end

    # A CSS string cannot run onto the next line: the newline ends it unclosed, and Tailwind refuses
    # the stylesheet over it however far away the closing quote is.
    test "a string whose line ends before its closing quote is refused" do
      for {body, column, string} <- [
            {~s|content: "abc\ncolor: red;|, 10, ~s|"abc|},
            {"content: 'abc", 10, "'abc"},
            {~s|&:hover { content: "a\nb" }|, 20, ~s|"a|},
            {~s|&[data-x="a\nb"] { gap: 1px; }|, 10, ~s|"a|},
            {~s|&[data-x="a\nb"] {\n  gap: 1px;\n}|, 10, ~s|"a|}
          ] do
        assert refused(body) == "#{at(1, column)}, at `#{string}`: Missing closing quote.", body
      end
    end

    test "a `;` or a `:` inside a value, a selector or an at-rule's prelude ends nothing" do
      for body <- [
            ~s|content: "a:b";|,
            ~s|font-family: "A:B", serif;|,
            ~s|content: "a;b"; gap: 1px;|,
            ~s|content: "a\\\nb";|,
            "background: url(http://x.test/y.png);",
            "background: url(data:image/png;base64,AAA);\ngap: 1px;",
            "color: var(--x);",
            "color: color-mix(in srgb, red 50%, blue);",
            ~s|grid-template-areas: "a b" "c d";|,
            "grid-area: a\\:b;",
            "&:hover { color: navy }",
            "& > a:hover { color: navy; }",
            "a:not(.x) { color: navy; }",
            "@media (min-width: 600px) { padding: 1px; }",
            "@supports (display: grid) { display: grid; }",
            "@container card (min-width: 400px) { gap: 1px; }",
            "@layer x { gap: 1px; }",
            "@apply p-4;",
            "gap: 1px;;\n/* a:b; c */"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end

    # A MISSING `;` BUILDS, and that is the trouble with it: the browser reads
    # `letter-spacing: 2pxcolor: teal` as one declaration whose value no property takes and drops
    # it, while the box says the rule was applied. The second colon is where the next one began, and
    # it is where the parser points.
    test "a missing `;` is refused at the colon of the declaration after it" do
      for {body, line, column, rest} <- [
            {"letter-spacing: 2pxcolor: teal", 1, 25, ": teal"},
            {"color: red color: blue", 1, 17, ": blue"},
            {"color: red\nbackground: blue;", 2, 11, ": blue"},
            {"gap: 1px;\ncolor: red /* x */ opacity: .5;", 2, 27, ": .5"},
            {"&:hover { color: red opacity: .5 }", 1, 29, ": .5"},
            {"@media (max-width: 600px) { padding: 1px\nmargin: 0; }", 2, 7, ": 0"}
          ] do
        assert refused(body) ==
                 "#{at(line, column)}, at `#{rest}`: Unexpected value or character.",
               body
      end
    end

    test "a custom property, an at-rule and a legacy filter keep a second colon" do
      for body <- [
            "--x: a:b;",
            "--x: a:b",
            "@apply hover:bg-red-500 md:p-4;",
            "&:hover { @apply hover:underline md:p-2; }",
            "filter: progid:DXImageTransform.Microsoft.gradient(startColorstr='#80000000');",
            "-ms-filter: PROGID:DXImageTransform.Microsoft.Alpha(Opacity=80);"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end

    # THE ONE WAY OUT OF THE WRAPPER is a `}` typed at the top level, which closes it early and
    # leaves everything after it loose on the whole site. A nested selector cannot escape: under CSS
    # nesting `body { … }` inside the braces means `.pb-xxxxxxxx body { … }`.
    #
    # An earlier version of this test asserted `{:error, _}` for a bare nested selector and passed —
    # not because a guard refused it, but because the write reached the database and failed there.
    # Asserting on the message is what makes the difference visible, and what showed that the rule
    # demanding `&` refused `body { … }` written first while allowing it after a declaration.
    #
    # The first of these parses once wrapped: its `}` closes the wrapper and the wrapper's own `}`
    # closes `body {`, so nothing is unbalanced and only where the wrapper closes gives it away.
    test "a `}` typed at the top level is refused, wherever it is", %{scope: scope} do
      for {body, column} <- [
            {"gap: 1px; } body { display: none; ", 11},
            {"} &:hover { gap: 1px; }", 1},
            {"&:hover { gap: 1px; } } .evil { gap: 2px; }", 23}
          ] do
        expected = closed_early(1, column)

        assert {:error, ^expected} = ElementCss.put(nil, nil, "page-x", scope, body),
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
      assert refused(~s|content: "{"; } .evil { color: red }|) == closed_early(1, 15)
      assert refused("/* } */ } .evil { color: red }") == closed_early(1, 9)
    end

    # A COMMENT NOBODY CLOSED IS NOT THE SAME MISTAKE, and refusing it with the brace message would
    # send the author looking for a brace that is fine. It swallows the `}` that ends the wrapper, so
    # everything after it in the stylesheet is eaten until the next `*/`.
    test "a comment left open is refused, and says so in its own words" do
      assert refused("/* never closed\ngap: 1px;") ==
               "#{at(1, 1)}, at `/* never closed gap: 1px;`: Unterminated block comment."
    end

    # `css/1` indents every line of a body, so a line inside a string can never look like the start
    # of the next rule when the row is split back up again.
    test "a body that quotes a whole rule does not split the row" do
      body = ~s|content: ".pb-abcdabcd {";\ngap: 1px;|

      refute refused(body)
      assert kept_body(body) == body
    end
  end

  # A `(` OR A `[` NOBODY CLOSED IS THE SAME ESCAPE. CSS reads everything up to the match as part
  # of it, braces included, so `calc(1px` takes the wrapper's `}` and every rule after it in the
  # stylesheet. Counting only braces let all of these through.
  describe "a parenthesis or a square bracket" do
    test "left open, or closed with nothing open, is refused where the parser finds it" do
      for {body, column, text} <- [
            {"width: calc(1px + 2px;", 22, ";"},
            {"&:hover { width: calc(1px + 2px; }", 32, ";"},
            {"width: 1px);", 11, ")"},
            {"& a:not(.x { color: red; }", 12, "{"},
            {"&[data-open { gap: 1px; }", 13, "{"},
            {"gap: 1px ];", 10, "]"},
            {"&:hover { & a[href { color: red; } }", 20, "{"}
          ] do
        assert refused(body) =~ "#{at(1, column)}, at `#{text}`: ", body
      end
    end

    test "a stray brace beside an open bracket is still refused" do
      assert refused("width: calc(1px } .evil { color: red }") =~ "#{at(1, 17)}, at `}`: "
      assert refused("&:hover { gap: 1px; ] }") =~ "#{at(1, 21)}, at `]`: "
    end

    test "a valid rule with functions, selectors and escapes is kept" do
      for body <- [
            ~s|background-image: url("a(b.png");|,
            "background-image: url(data:image/png;base64,AAAA);",
            "width: calc(100% - var(--gap, 4px));",
            ~s|&[data-state="open"] { gap: 1px; }|,
            ~s|& a[href^="http"]:not(.x) { color: red; }|,
            "@media (max-width: 900px) { padding: 12px; }",
            ~s|content: "(";\ngap: 1px;|,
            ~s|content: "]";|,
            "/* ( [ */\ngap: 1px;",
            "& .w-\\[10px\\] { gap: 1px; }",
            "& .a\\( { gap: 1px; }"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end
  end

  # THE BODIES THE TAILWIND CLI WAS RUN AGAINST, each wrapped as `css/1` writes it. The valid ones
  # build, and the box keeps them. The refused ones either stop the build, or build into a rule the
  # browser drops (`2pxcolor: teal`, a missing `;`), which the box must not announce as applied.
  describe "the parser's verdict on bodies Tailwind was run against" do
    test "what builds is kept" do
      for body <- [
            ~S|display:grid; grid-template-areas: "a b" "c d";|,
            ~S|content: "a:b";|,
            ~S|content: 'it\'s: x'|,
            ~S|background: url(http://x.test/a.png);|,
            ~S|background: url(data:image/png;base64,iVBOR)|,
            ~S|background: var(--x)|,
            ~S|--foo: a:b;|,
            ~S|@apply hover:bg-red-500 md:p-4;|,
            ~S|&:hover { color: red }|,
            ~S|& > a:hover { color: blue }|,
            ~S|a:not(.x) { color: red }|,
            ~S|@media (min-width: 600px) { color: red }|,
            ~S|@supports (display: grid) { display: grid }|,
            ~S|@container card (min-width: 400px) { color: red }|,
            ~S|color: red !important;|,
            ~S|font-family: "A:B", serif;|,
            ~S|grid-template-columns: [full-start] minmax(1rem, 1fr) [content-start] 3fr;|,
            ~S|filter: progid:DXImageTransform.Microsoft.gradient(startColorstr='#80000000', endColorstr='#80000000');|,
            ~S|/* note: x */ color: red; /* a:b */|,
            ~S|transition: opacity .2s ease-in-out, transform .2s;|,
            ~S|&:is(.a, .b):hover { color: red }|,
            ~S|&:hover { color: red; background: blue }|,
            ~S|@layer base { color: red }|,
            ~S|anchor-name: --x; position-anchor: --x;|,
            ~S|color: color-mix(in srgb, red 50%, blue);|,
            ~S|grid-area: a\:b;|,
            ~S|src: url("x:y.woff2") format("woff2")|,
            ~S|quotes: "\201C" "\201D";|,
            ~S|inset: 0; &::before { content: ""; }|,
            ~S|&[data-x="a:b"] { color: red }|,
            ~S|color: red;;|,
            "padding: 20px;\n\n&:hover {\n  transform: translateY(-2px);\n}\n@media (max-width: 900px) { padding: 12px; }",
            ~S|content: "}"; color: red|,
            ~S|background-image: url("a;b.png")|,
            "@apply bg-[#fff] w-[calc(100%-2rem)] data-[state=open]:block;",
            "@media (width >= 40rem) { @apply p-2; }",
            "--x: [a:b];",
            "&:hover { --x: a:b; }",
            "--x: a:b !important;",
            "color: red;;; gap: 1px"
          ] do
        refute refused(body), body
        assert kept_body(body) == body, body
      end
    end

    test "what stops the build, or builds into a dropped rule, is refused" do
      for body <- [
            ~S|color crimson|,
            ~S|color crimson;|,
            ~S|&:hover { color navy }|,
            ~S|@media (max-width: 600px) { color red }|,
            ~S|letter-spacing: 2pxcolor: teal|,
            ~S|--foo;|,
            ~S|color: red color: blue|,
            "content: \"abc\ncolor: red;",
            ~S|color: red; background|
          ] do
        assert refused(body) =~ "That CSS has an error on line ", body
      end
    end

    # Valid only at the top of a stylesheet, and Tailwind refuses to build one written inside a rule.
    test "an @import is refused" do
      assert refused(~s|@import "x.css";|) ==
               ~s|#{at(1, 1)}, at `@import "x.css";`: `@import` is valid only at the top level of a stylesheet.|
    end

    # Internet Explorer 7's star hack. Tailwind passes it through and every current browser drops
    # it; the parser reads it as a selector with no block.
    test "a star hack is refused" do
      assert refused("*zoom: 1;") ==
               "#{at(1, 1)}, at `*zoom: 1`: Expected a `{` after the selector `*zoom: 1`."
    end

    # `//` starts no comment in a browser or in Tailwind, so what follows it is read as CSS.
    test "a // line is refused" do
      assert refused("color: red; // note") =~ "#{at(1, 13)}, at `//`: "
    end

    # The box shows what was typed, blank lines above the CSS included.
    test "a line and a column are counted in the text as it was typed" do
      assert refused("\n\n  color crimson") =~ "#{at(3, 3)}, at `color crimson`: "
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
