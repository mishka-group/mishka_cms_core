defmodule MishkaCmsCore.Runtime.PageBuilder.TreeTest do
  @moduledoc """
  The editor's model contract: a template parsed into a node tree and serialized back must be a
  fixed point, and must still contain what it started with.

  This is the suite that has to stay green forever. The React editor's save path corrupted every
  loaded page precisely because nothing here existed — its serializer understood one of the two
  record shapes it had invented, and the other degraded to `<div class="element-…">`. A fidelity
  assertion alongside the stability one is what stops "stable" from quietly meaning "stably empty".
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.CodeCheck
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  defp round_trip(heex) do
    heex |> Tree.parse!() |> Serializer.serialize()
  end

  defp assert_fixed_point(heex) do
    once = round_trip(heex)
    twice = round_trip(once)

    assert once == twice, """
    serialize(parse(x)) is not a fixed point.
      first:  #{inspect(once)}
      second: #{inspect(twice)}
    """

    once
  end

  defp assert_round_trip(heex, must_contain) do
    out = assert_fixed_point(heex)

    for fragment <- must_contain do
      assert out =~ fragment, "expected #{inspect(out)} to contain #{inspect(fragment)}"
    end

    out
  end

  describe "parse/1 — the corpus round-trips" do
    test "plain nested HTML" do
      assert_round_trip(~s(<div class="wrap"><p>Hello</p></div>), [
        ~s(<div class="wrap">),
        "<p>Hello</p>"
      ])
    end

    test "multiple roots" do
      tree = Tree.parse!(~s(<div>a</div><span>b</span>))
      assert length(tree.roots) == 2
      assert_round_trip(~s(<div>a</div><span>b</span>), ["<div>a</div>", "<span>b</span>"])
    end

    test "deep nesting" do
      heex = ~s(<div><div><div><div><div><em>deep</em></div></div></div></div></div>)
      assert_round_trip(heex, ["<em>deep</em>"])
    end

    test "local component with named slot" do
      assert_round_trip(~s(<.card title="T"><:header>H</:header>body</.card>), [
        "<.card",
        ~s(title="T"),
        "<:header>H</:header>",
        "</.card>"
      ])
    end

    test "remote component" do
      assert_round_trip(~s(<MyApp.Components.hero title="T" />), ["<MyApp.Components.hero"])
    end

    test "self-closing and void elements" do
      assert_round_trip(~s(<img src="a.png"><br><input type="text" required>), [
        "<img",
        "<br",
        "required"
      ])
    end

    test "inline eex, both markers" do
      assert_round_trip(~s(<%= @a %><% x = 1 %>), ["<%= @a %>", "<% x = 1 %>"])
    end

    test "body expression keeps curly form" do
      assert_round_trip(~s(<div id={@id}>{@name}</div>), ["id={@id}", "{@name}"])
    end

    test "html and eex comments" do
      out =
        assert_round_trip(~s(<!-- note --><%!-- hidden --%>), [
          "<!-- note -->",
          "<%!-- hidden --%>"
        ])

      refute out =~ "<!--<!--"
    end

    test "preserve mode keeps pre content verbatim" do
      assert_round_trip(~s(<pre>  keep   me  </pre>), ["  keep   me  "])
    end

    test "phx-no-format is preserved" do
      assert_round_trip(~s(<div phx-no-format>a   b</div>), ["phx-no-format", "a   b"])
    end

    test "html entities survive" do
      assert_round_trip(~s(<p>a &amp; b &lt; c</p>), ["&amp;", "&lt;"])
    end

    test "whitespace between inline elements is kept" do
      out = assert_fixed_point(~s(<b>a</b> <i>b</i>))
      assert out == ~s(<b>a</b> <i>b</i>)
    end

    test "an unknown component is kept, not dropped" do
      assert_round_trip(~s(<.totally_unknown_thing x="1" />), ["<.totally_unknown_thing"])
    end
  end

  describe "parse/1 — eex blocks are atomic and byte-identical" do
    test "if/else block" do
      heex = ~s(<%= if @ok do %><b>y</b><% else %><i>n</i><% end %>)
      out = assert_fixed_point(heex)
      assert out == heex
    end

    test "for comprehension" do
      heex = ~s(<%= for p <- @posts do %><li>{p.title}</li><% end %>)
      out = assert_fixed_point(heex)
      assert out == heex
    end

    test "a block is one leaf node, its children are not model nodes" do
      tree = Tree.parse!(~s(<%= for p <- @posts do %><li>x</li><% end %>))

      assert [root_id] = tree.roots
      node = Tree.get(tree, root_id)
      assert node.kind == :eex_block
      assert node.children == []
      assert node.text == "for p <- @posts do"
      assert Tree.size(tree) == 1
    end

    test "a block nested inside markup round-trips" do
      heex = ~s(<ul><%= for p <- @posts do %><li>{p.t}</li><% end %></ul>)
      assert assert_fixed_point(heex) == heex
    end
  end

  describe "parse/1 — attribute fidelity" do
    test "string, expression, boolean and root attrs stay distinct" do
      tree = Tree.parse!(~s(<.btn label="Go" color={@c} disabled {@rest} />))
      node = Tree.get(tree, hd(tree.roots))

      assert node.attrs == [
               {"label", {:string, "Go"}},
               {"color", {:expr, "@c"}},
               {"disabled", :boolean},
               {:root, {:expr, "@rest"}}
             ]
    end

    test "attribute order is preserved" do
      out = round_trip(~s(<div z="1" a="2" m="3"></div>))
      assert out == ~s(<div z="1" a="2" m="3"></div>)
    end

    test "svg camelCase attributes are emitted verbatim" do
      assert_round_trip(~s(<svg viewBox="0 0 24 24" preserveAspectRatio="xMidYMid"></svg>), [
        ~s(viewBox="0 0 24 24"),
        ~s(preserveAspectRatio="xMidYMid")
      ])
    end

    test "an expression attribute is never flattened to a string" do
      tree = Tree.parse!(~s(<div class={@klass}></div>))
      node = Tree.get(tree, hd(tree.roots))

      assert Node.attr(node, "class") == {:expr, "@klass"}
      refute Node.attr(node, "class") == {:string, "{@klass}"}
    end
  end

  describe "parse/1 — bad paths" do
    test "an unclosed tag reports line and column" do
      assert {:error, %{line: line, column: column, message: message}} =
               Tree.parse("<div><span></div>")

      assert is_integer(line)
      assert is_integer(column)
      assert message =~ "closing tag"
    end

    test "malformed eex does not crash the caller" do
      assert {:error, %{message: message}} = Tree.parse("<%= if true do %>")
      assert is_binary(message)
    end

    test "nil and empty templates give an empty tree" do
      assert {:ok, %Tree{nodes: nodes, roots: []}} = Tree.parse(nil)
      assert nodes == %{}
      assert {:ok, %Tree{roots: []}} = Tree.parse("")
    end

    test "parse!/1 raises with the reason" do
      assert_raise ArgumentError, ~r/unparseable template/, fn ->
        Tree.parse!("<div><span></div>")
      end
    end
  end

  describe "structure" do
    setup do
      %{tree: Tree.parse!(~s(<section><h1>T</h1><div><p>body</p></div></section>))}
    end

    test "every node knows its parent and children", %{tree: tree} do
      [section_id] = tree.roots
      section = Tree.get(tree, section_id)

      assert section.parent_id == nil
      assert length(section.children) == 2

      for child_id <- section.children do
        assert Tree.get(tree, child_id).parent_id == section_id
      end
    end

    test "ancestors run nearest-first", %{tree: tree} do
      p = Enum.find(Tree.walk(tree), &(&1.tag == "p"))
      assert Enum.map(Tree.ancestors(tree, p.id), & &1.tag) == ["div", "section"]
    end

    test "path runs outermost-first and ends at the node", %{tree: tree} do
      p = Enum.find(Tree.walk(tree), &(&1.tag == "p"))
      assert Enum.map(Tree.path(tree, p.id), & &1.tag) == ["section", "div", "p"]
    end

    test "descendant? sees through nesting", %{tree: tree} do
      [section_id] = tree.roots
      p = Enum.find(Tree.walk(tree), &(&1.tag == "p"))

      assert Tree.descendant?(tree, section_id, p.id)
      refute Tree.descendant?(tree, p.id, section_id)
    end

    test "walk is document order", %{tree: tree} do
      assert Enum.map(Tree.walk(tree), & &1.tag) == [
               "section",
               "h1",
               nil,
               "div",
               "p",
               nil
             ]
    end

    test "index_of locates a node among its siblings", %{tree: tree} do
      [section_id] = tree.roots
      [first, second] = Tree.get(tree, section_id).children

      assert Tree.index_of(tree, first) == 0
      assert Tree.index_of(tree, second) == 1
    end
  end

  describe "Node" do
    test "generated ids match the persisted id format" do
      for _ <- 1..50 do
        assert Node.generate_id() =~ ~r/^n[a-z0-9]{8}$/
      end
    end

    test "component_name strips the leading dot" do
      assert ".card" |> node_with_tag(:component) |> Node.component_name() == "card"
      assert "MyApp.hero" |> node_with_tag(:component) |> Node.component_name() == "MyApp.hero"
      assert "div" |> node_with_tag(:tag) |> Node.component_name() == nil
    end

    test "slot_name strips the leading colon" do
      assert ":item" |> node_with_tag(:slot) |> Node.slot_name() == "item"
      assert "div" |> node_with_tag(:tag) |> Node.slot_name() == nil
    end

    test "container kinds hold children, leaf kinds do not" do
      for kind <- [:tag, :component, :slot] do
        assert Node.container?(Node.new(kind))
      end

      for kind <- [:text, :eex, :eex_block, :eex_comment, :html_comment] do
        refute Node.container?(Node.new(kind))
      end
    end

    test "attr_text flattens every value form" do
      node = Tree.parse!(~s(<div a="x" b={@y} c></div>)) |> then(&Tree.get(&1, hd(&1.roots)))

      assert Node.attr_text(node, "a") == "x"
      assert Node.attr_text(node, "b") == "@y"
      assert Node.attr_text(node, "c") == ""
      assert Node.attr_text(node, "missing") == nil
    end

    defp node_with_tag(tag, kind), do: Node.new(kind, tag: tag)
  end

  describe "Node.builder/1 — the boundary check" do
    test "accepts a well-formed node" do
      assert {:ok, node} = Node.builder(%{id: Node.generate_id(), kind: :tag, tag: "div"})
      assert node.kind == :tag
    end

    test "rejects a malformed id" do
      assert {:error, _errors} = Node.builder(%{id: "../../etc/passwd", kind: :tag})
      assert {:error, _errors} = Node.builder(%{id: "nUPPERCASE", kind: :tag})
      assert {:error, _errors} = Node.builder(%{id: "n123", kind: :tag})
    end

    test "rejects an unknown kind" do
      assert {:error, _errors} = Node.builder(%{id: Node.generate_id(), kind: :script_tag})
    end

    test "rejects a missing enforced field" do
      assert {:error, _errors} = Node.builder(%{kind: :tag})
      assert {:error, _errors} = Node.builder(%{id: Node.generate_id()})
    end
  end

  describe "Serializer" do
    test "to_heex formats and proves the output re-parses" do
      tree = Tree.parse!(~s(<div class="a"><p>x</p></div>))
      assert {:ok, heex} = Serializer.to_heex(tree)
      assert heex =~ ~s(<div class="a">)
      assert {:ok, _tree} = Tree.parse(heex)
    end

    test "formatting is idempotent — the second save is a no-op" do
      tree = Tree.parse!(~s(<div   class="a"  ><p>x</p></div>))
      {:ok, once} = Serializer.to_heex(tree)
      {:ok, twice} = once |> Tree.parse!() |> Serializer.to_heex()

      assert once == twice
    end

    test "serialize_node emits one subtree" do
      tree = Tree.parse!(~s(<section><p>x</p></section>))
      p = Enum.find(Tree.walk(tree), &(&1.tag == "p"))

      assert Serializer.serialize_node(tree, p.id) == "<p>x</p>"
    end

    test "an empty tree serializes to an empty string" do
      assert Serializer.serialize(Tree.new()) == ""
    end
  end

  describe "blank?/2" do
    test "a container with no children at all is blank" do
      tree = Tree.parse!(~s(<div></div>))
      div = Enum.find(Tree.walk(tree), &(&1.tag == "div"))

      assert Tree.blank?(tree, div.id)
    end

    # The one that matters. Taking the last thing out of a container leaves the indentation that used
    # to sit around it, so the node still has children and still renders nothing.
    test "a container holding only indentation is blank" do
      tree =
        Tree.parse!("""
        <div>
        </div>
        """)

      div = Enum.find(Tree.walk(tree), &(&1.tag == "div"))

      assert Tree.get(tree, div.id).children != []
      assert Tree.blank?(tree, div.id)
    end

    test "a container holding anything real is not blank" do
      tree = Tree.parse!(~s(<div>\n  <p>x</p>\n</div>))
      div = Enum.find(Tree.walk(tree), &(&1.tag == "div"))

      refute Tree.blank?(tree, div.id)
    end

    test "an empty document is blank at the root" do
      assert Tree.blank?(Tree.new(), :root)
      refute Tree.blank?(Tree.parse!(~s(<p>x</p>)), :root)
    end
  end

  # FORMATTING IS NOT STRUCTURE, but a text node cannot tell you which it is. `to_heex/1` indents,
  # and parsing that back turns the indentation into text nodes — so a flat document that has been
  # through the serializer once has a whitespace sibling before every element, and every plain
  # address shifts. Anything anchoring across that round trip needs the address that does not move.
  describe "content_address/2 and at_content_address/2" do
    defp formatted(tree) do
      {:ok, heex} = Serializer.to_heex(tree)
      Tree.parse!(heex)
    end

    defp tagged(tree, tag), do: Enum.find(Tree.walk(tree), &(&1.tag == tag))

    test "a plain address moves when the formatter runs; this one does not" do
      flat = Tree.parse!(~s(<div id="root"><h1>Title</h1><p>hello</p></div>))
      h1 = tagged(flat, "h1")

      pretty = formatted(flat)
      moved = tagged(pretty, "h1")

      assert Tree.address(flat, h1.id) == "0.0"

      assert Tree.address(pretty, moved.id) == "0.1",
             "the drift this exists for is gone; re-check"

      assert Tree.content_address(flat, h1.id) == Tree.content_address(pretty, moved.id)
    end

    test "an element is found again on the other side of the round trip" do
      flat = Tree.parse!(~s(<section><h1>Title</h1><p>hello</p><span>x</span></section>))
      span = tagged(flat, "span")
      address = Tree.content_address(flat, span.id)

      pretty = formatted(flat)

      assert found = Tree.at_content_address(pretty, address)
      assert Tree.get(pretty, found).tag == "span"
    end

    test "it round-trips through itself at every depth" do
      tree = Tree.parse!(~s(<div><section><ul><li>one</li><li>two</li></ul></section></div>))

      for node <- Tree.walk(tree), address = Tree.content_address(tree, node.id), address do
        assert Tree.at_content_address(tree, address) == node.id
      end
    end

    test "whitespace has no address of its own" do
      pretty = formatted(Tree.parse!(~s(<div><h1>Title</h1></div>)))

      blank =
        Enum.find(Tree.walk(pretty), &(&1.kind == :text and String.trim(&1.text || "") == ""))

      assert blank, "the formatter left no whitespace node; this test proves nothing"
      refute Tree.content_address(pretty, blank.id)
    end

    test "text that says something keeps its place" do
      tree = Tree.parse!(~s(<p>hello <strong>you</strong></p>))
      hello = Enum.find(Tree.walk(tree), &(&1.kind == :text and String.trim(&1.text || "") != ""))

      assert Tree.content_address(tree, hello.id) == "0.0"
      assert Tree.at_content_address(tree, "0.1") == tagged(tree, "strong").id
    end

    test "a path past the end of a child list answers nothing, never the nearest sibling" do
      tree = Tree.parse!(~s(<div><h1>Title</h1></div>))

      refute Tree.at_content_address(tree, "0.4")
      refute Tree.at_content_address(tree, "9")
      refute Tree.at_content_address(tree, nil)
      refute Tree.at_content_address(tree, "")
    end

    test "an unknown id has no address" do
      refute Tree.content_address(Tree.parse!(~s(<p>x</p>)), "nzzzzzzzz")
    end
  end

  # AN INDEX ONLY MEANS SOMETHING WHEN BOTH DOCUMENTS AGREE ABOUT THE SHAPE. This is what stops a
  # position from quietly naming the neighbour after the document changed underneath it.
  describe "same_shape_at?/3" do
    test "a document that only changed what is inside its elements still agrees" do
      was = Tree.parse!(~s(<div><h1>Old</h1><p class="a">hello</p></div>))
      now = Tree.parse!(~s(<div><h1>New and longer</h1><p class="b">hello there</p></div>))

      assert Tree.same_shape_at?(was, now, "0.0")
      assert Tree.same_shape_at?(was, now, "0.1")
    end

    test "a sibling added above the address makes it disagree" do
      was = Tree.parse!(~s(<div><p>B</p></div>))
      now = Tree.parse!(~s(<div><p>A</p><p>B</p></div>))

      refute Tree.same_shape_at?(was, now, "0.0")
    end

    test "a sibling removed above the address makes it disagree" do
      was = Tree.parse!(~s(<ul><li>one</li><li>two</li><li>three</li></ul>))
      now = Tree.parse!(~s(<ul><li>two</li><li>three</li></ul>))

      refute Tree.same_shape_at?(was, now, "0.1")
    end

    test "a change deep in the path is caught, not only at the end" do
      was = Tree.parse!(~s(<div><section><p>x</p></section></div>))
      now = Tree.parse!(~s(<div><header></header><section><p>x</p></section></div>))

      refute Tree.same_shape_at?(was, now, "0.0.0")
    end

    test "a different tag at the address disagrees" do
      was = Tree.parse!(~s(<div><p>x</p></div>))
      now = Tree.parse!(~s(<div><section>x</section></div>))

      refute Tree.same_shape_at?(was, now, "0.0")
    end

    test "indentation is not shape, so a re-format still agrees" do
      was = Tree.parse!(~s(<div><h1>Title</h1><p>hello</p></div>))
      {:ok, heex} = Serializer.to_heex(was)
      now = Tree.parse!(heex)

      assert Tree.same_shape_at?(was, now, "0.1")
    end

    test "a document compared with itself always agrees" do
      tree = Tree.parse!(~s(<div><section><ul><li>one</li><li>two</li></ul></section></div>))

      for node <- Tree.walk(tree), address = Tree.content_address(tree, node.id), address do
        assert Tree.same_shape_at?(tree, tree, address)
      end
    end

    test "no address is not an agreement" do
      tree = Tree.parse!(~s(<p>x</p>))

      refute Tree.same_shape_at?(tree, tree, nil)
      refute Tree.same_shape_at?(tree, tree, "0.9")
      refute Tree.same_shape_at?(tree, tree, "-1")
    end
  end

  # A NODE HOLDS WHAT THE AUTHOR TYPED, and the editor's save path is tree, serialize, re-parse. A
  # double quote written back between double quotes closes the attribute early, so the re-parse fails
  # — and that does not surface as a rejected keystroke. The op is recorded and the history entry is
  # written, then the draft quietly stops being saved while the editor goes on saying it saved. A
  # regex in `pattern` and a quotation in a success message are both ordinary things to type.
  describe "an attribute value that contains a double quote" do
    defp quoted_round_trip(value) do
      {:ok, tree} = Tree.parse(~s(<input type="text" />))
      node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "input"))
      {:ok, tree} = Tree.set_attr(tree, node.id, "pattern", {:string, value})

      source = Serializer.serialize(tree)

      case Tree.parse(source) do
        {:ok, back} ->
          read = back |> Tree.walk() |> Enum.find(&(&1.tag == "input")) |> Node.attr("pattern")
          {source, read}

        {:error, reason} ->
          flunk("re-parse failed for #{inspect(value)}: #{inspect(reason)}\n#{source}")
      end
    end

    test "survives being written back out and read in again" do
      {_source, read} = quoted_round_trip(~s(^a"b$))

      assert read == {:string, ~s(^a"b$)}
    end

    test "and the source it is written into stays parseable" do
      {source, _read} = quoted_round_trip(~s(Thanks — we'll be "in touch"))

      assert source =~ "&quot;"
      refute source =~ ~s(pattern="Thanks — we'll be ")
    end

    test "a value with no quote is written exactly as it was" do
      {source, read} = quoted_round_trip("[0-9]{3}")

      assert source =~ ~s(pattern="[0-9]{3}")
      assert read == {:string, "[0-9]{3}"}
    end

    # Stable in both directions, so an author who really did type the entity keeps it and a value
    # does not gain an escape every time it is saved.
    test "and any number of round trips changes nothing" do
      once = quoted_round_trip(~s(a"b)) |> elem(1) |> elem(1)
      twice = quoted_round_trip(once) |> elem(1) |> elem(1)

      assert once == ~s(a"b)
      assert twice == once
    end
  end

  # THE ROUND TRIP THAT WAS ONE-WAY. `Serializer.computed_class/4` has always been able to WRITE an
  # override onto a node whose class is an expression; nothing could read it back, so the inspector
  # showed the field empty and the next save wrapped the list again — keeping the stale utility
  # beside the new one at equal specificity, where the old value can win.
  describe "a style override on a class written as a list" do
    alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

    defp restyled(markup, value) do
      {:ok, tree} = Tree.parse(markup)
      node = tree |> Tree.walk() |> Enum.find(&(&1.kind == :tag))
      {:ok, tree} = Tree.set_style(tree, node.id, :base, "width", value)
      Serializer.serialize(tree)
    end

    test "is lifted back out on the next parse" do
      {:ok, tree} = Tree.parse(~S|<div class={["w-[1000px]", "text-sm"]}>x</div>|)
      node = tree |> Tree.walk() |> Enum.find(&(&1.kind == :tag))

      assert node.meta[:styles] == %{base: %{"width" => "1000px"}}
      assert node.attrs == [{"class", {:expr, ~S|["text-sm"]|}}]
    end

    test "replaces rather than accumulating, however many times it is edited" do
      once = restyled(~S|<div class={["p-2", @flag && "x"]}>hi</div>|, "1000px")
      twice = restyled(once, "900px")
      thrice = restyled(twice, "800px")

      assert String.trim(thrice) == ~S|<div class={["p-2", @flag && "x", "w-[800px]"]}>hi</div>|

      refute thrice =~ "1000px", "an earlier width survived and can still win the cascade"
      refute thrice =~ "w-[900px]"
      refute thrice =~ "[[", "the list was wrapped instead of extended"
    end

    test "and the author's own elements keep their place" do
      out = restyled(~S|<div class={["p-2", @flag && "x"]}>hi</div>|, "1000px")

      assert out =~ ~S|"p-2", @flag && "x"|
    end

    # AN IMPORTANT UTILITY IS STILL ONE OF OURS. A component's override is written with a bang so it
    # beats the kit's own rules from inside its template, and nothing stripped it on the way back —
    # so every kit component wrote its override, replaced it correctly on the next edit, and showed
    # the field empty ever after. Reported as a width going missing on reopen; this is the half of
    # that which is real for components rather than for breakpoints.
    test "a component's important override is read back" do
      {:ok, tree} =
        Tree.parse(
          ~S|<.component component_name="chelekom-card" site="Global" class="shadow p-[8px]!" />|
        )

      node = tree |> Tree.walk() |> Enum.find(&(&1.kind == :component))

      assert node.meta[:styles] == %{base: %{"padding" => "8px"}}
      assert node.attrs |> List.keyfind("class", 0) == {"class", {:string, "shadow"}}
    end

    # AND A PLAIN TAG'S BANG IS THE AUTHOR'S. Lifting it would re-emit it without the bang, which
    # changes what it means, so a tag keeps it verbatim.
    test "a tag's own important class is left alone" do
      {:ok, tree} = Tree.parse(~S|<div class="p-[8px]!">x</div>|)
      node = tree |> Tree.walk() |> Enum.find(&(&1.kind == :tag))

      assert node.meta[:styles] == %{}
      assert node.attrs == [{"class", {:string, "p-[8px]!"}}]
    end

    # `class={@variant}` IS the class and is not ours to take apart — the old wrapping behaviour is
    # still right for it, because there is nothing to extend.
    test "an expression that is not a list is still wrapped, not rewritten" do
      out = restyled(~S|<div class={@variant}>hi</div>|, "1000px")

      assert String.trim(out) == ~S|<div class={[@variant, "w-[1000px]"]}>hi</div>|
    end

    # AND THE WRAP HAS TO BE ELIXIR. `class={if @x, do: "a", else: "b"}` ends in a keyword list
    # written without brackets, so the utility appended after it was a syntax error: one slider move
    # and the page could no longer be saved at all. The wrap is read back before it is kept, and
    # every later edit has to stay readable too or the stale width comes back beside the new one.
    test "and an expression a comma cannot follow is wrapped in something that still parses" do
      once = restyled(~S|<div class={if @x, do: "a", else: "b"}>hi</div>|, "1000px")
      twice = restyled(once, "900px")

      assert CodeCheck.template(once) == :ok
      assert CodeCheck.template(twice) == :ok

      assert twice =~ "w-[900px]"
      assert twice =~ "@x"
      refute twice =~ "w-[1000px]", "an earlier width survived and can still win the cascade"
    end

    # AND AN EXPRESSION THAT IS NOT ELIXIR KEEPS THE CLASS IT HAS. The attribute row takes whatever
    # the author types, half-finished expressions included; a utility appended to one is a guess,
    # and the guess writes over the only copy of what they were in the middle of typing.
    test "and an expression nothing can be added to keeps the class it has" do
      out = restyled(~S|<div class={@variant ++}>hi</div>|, "1000px")

      assert String.trim(out) == ~S|<div class={@variant ++}>hi</div>|
    end
  end
end
