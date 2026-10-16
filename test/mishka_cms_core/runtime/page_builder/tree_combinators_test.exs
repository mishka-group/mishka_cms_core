# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.TreeCombinatorsTest do
  @moduledoc """
  The edit combinators — every mutation the editor can perform, as pure functions.

  The reorder cases are ported from the React editor's `logic.test.js` (`moveElementInList`), which
  is the only part of that implementation with a tested specification. Its guarantees are the ones
  users feel: a same-parent reorder must not drift by one, and a container must never be dropped
  into its own descendant.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  defp roots_tree do
    Tree.parse!(~s(<a-one></a-one><b-two></b-two><c-three></c-three>))
  end

  defp tags(tree, parent), do: tree |> Tree.children(parent) |> Enum.map(& &1.tag)

  defp find(tree, tag), do: Enum.find(Tree.walk(tree), &(&1.tag == tag))

  describe "move/4 — the logic.test.js contract" do
    test "reorders roots without off-by-one: A to index 1 gives B A C" do
      tree = roots_tree()
      a = find(tree, "a-one")

      assert {:ok, moved} = Tree.move(tree, a.id, :root, 1)
      assert tags(moved, :root) == ["b-two", "a-one", "c-three"]
    end

    test "reorders roots: C to index 0 gives C A B" do
      tree = roots_tree()
      c = find(tree, "c-three")

      assert {:ok, moved} = Tree.move(tree, c.id, :root, 0)
      assert tags(moved, :root) == ["c-three", "a-one", "b-two"]
    end

    test "moving into a container detaches from the old parent" do
      tree =
        Tree.parse!(~s(<div id="root"><a-one></a-one><div id="cont"><b-two></b-two></div></div>))

      a = find(tree, "a-one")
      cont = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == "cont"))
      root = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == "root"))

      assert {:ok, moved} = Tree.move(tree, a.id, cont.id, 0)
      assert tags(moved, cont.id) == ["a-one", "b-two"]
      assert Tree.get(moved, a.id).parent_id == cont.id
      refute a.id in Tree.child_ids(moved, root.id)
    end

    test "moving out to the root detaches from the container" do
      tree = Tree.parse!(~s(<div id="cont"><b-two></b-two></div>))
      b = find(tree, "b-two")
      cont = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == "cont"))

      assert {:ok, moved} = Tree.move(tree, b.id, :root, 0)
      assert Tree.child_ids(moved, cont.id) == []
      assert Tree.get(moved, b.id).parent_id == nil
      assert b.id in moved.roots
    end

    test "refuses to move a node into itself" do
      tree = roots_tree()
      a = find(tree, "a-one")

      assert {:error, :cyclic_move} = Tree.move(tree, a.id, a.id, 0)
    end

    test "refuses to move a node into its own descendant" do
      tree = Tree.parse!(~s(<div id="outer"><div id="inner"></div></div>))
      outer = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == "outer"))
      inner = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == "inner"))

      assert {:error, :cyclic_move} = Tree.move(tree, outer.id, inner.id, 0)
    end

    test "an out-of-range index appends rather than failing" do
      tree = roots_tree()
      a = find(tree, "a-one")

      assert {:ok, moved} = Tree.move(tree, a.id, :root, 99)
      assert tags(moved, :root) == ["b-two", "c-three", "a-one"]
    end

    test "moving into a leaf is refused" do
      tree = Tree.parse!(~s(<p>text</p><div></div>))
      text = Enum.find(Tree.walk(tree), &(&1.kind == :text))
      div = find(tree, "div")

      assert {:error, :invalid_parent} = Tree.move(tree, div.id, text.id, 0)
    end

    test "moving an unknown node is refused" do
      assert {:error, :unknown_node} = Tree.move(roots_tree(), "nzzzzzzzz", :root, 0)
    end

    test "a move preserves the serialized content, only its order" do
      tree = roots_tree()
      a = find(tree, "a-one")
      {:ok, moved} = Tree.move(tree, a.id, :root, 2)

      assert Serializer.serialize(moved) == ~s(<b-two></b-two><c-three></c-three><a-one></a-one>)
    end
  end

  describe "insert/4" do
    test "inserts a node at an index" do
      tree = roots_tree()
      node = Node.new(:tag, tag: "x-new")

      assert {:ok, inserted} = Tree.insert(tree, node, :root, 1)
      assert tags(inserted, :root) == ["a-one", "x-new", "b-two", "c-three"]
      assert Tree.get(inserted, node.id).parent_id == nil
    end

    test "inserts into a container and sets the parent" do
      tree = Tree.parse!(~s(<div></div>))
      div = find(tree, "div")
      node = Node.new(:tag, tag: "x-new")

      assert {:ok, inserted} = Tree.insert(tree, node, div.id, 0)
      assert Tree.get(inserted, node.id).parent_id == div.id
      assert Serializer.serialize(inserted) == ~s(<div><x-new></x-new></div>)
    end

    test "inserts a whole subtree" do
      tree = Tree.parse!(~s(<div></div>))
      div = find(tree, "div")
      subtree = Tree.parse!(~s(<section><p>x</p></section>))

      assert {:ok, inserted} = Tree.insert(tree, subtree, div.id, 0)
      assert Serializer.serialize(inserted) == ~s(<div><section><p>x</p></section></div>)
      assert Tree.size(inserted) == 1 + Tree.size(subtree)
    end

    test "refuses a missing parent" do
      node = Node.new(:tag, tag: "x-new")
      assert {:error, :invalid_parent} = Tree.insert(roots_tree(), node, "nzzzzzzzz", 0)
    end

    test "refuses a leaf parent" do
      tree = Tree.parse!(~s(<p>text</p>))
      text = Enum.find(Tree.walk(tree), &(&1.kind == :text))

      assert {:error, :invalid_parent} = Tree.insert(tree, Node.new(:tag, tag: "b"), text.id, 0)
    end
  end

  describe "delete/1" do
    test "removes a node and every descendant" do
      tree = Tree.parse!(~s(<div><section><p>x</p></section></div>))
      section = find(tree, "section")
      before = Tree.size(tree)

      assert {:ok, deleted} = Tree.delete(tree, section.id)
      assert Serializer.serialize(deleted) == ~s(<div></div>)
      assert Tree.size(deleted) == before - 3
    end

    test "removes the node from its parent's child list" do
      tree = Tree.parse!(~s(<div><a-one></a-one><b-two></b-two></div>))
      div = find(tree, "div")
      a = find(tree, "a-one")

      assert {:ok, deleted} = Tree.delete(tree, a.id)
      refute a.id in Tree.child_ids(deleted, div.id)
    end

    test "deleting a root removes it from roots" do
      tree = roots_tree()
      a = find(tree, "a-one")

      assert {:ok, deleted} = Tree.delete(tree, a.id)
      refute a.id in deleted.roots
    end

    test "deleting an unknown node is refused" do
      assert {:error, :unknown_node} = Tree.delete(roots_tree(), "nzzzzzzzz")
    end
  end

  describe "duplicate/2" do
    test "deep-copies with fresh ids and inserts after the source" do
      tree = Tree.parse!(~s(<div><section class="s"><p>x</p></section></div>))
      section = find(tree, "section")

      assert {:ok, duped, copy_id} = Tree.duplicate(tree, section.id)
      assert copy_id != section.id

      assert Serializer.serialize(duped) ==
               ~s(<div><section class="s"><p>x</p></section><section class="s"><p>x</p></section></div>)
    end

    test "the copy shares no ids with the source" do
      tree = Tree.parse!(~s(<section><p>x</p><p>y</p></section>))
      section = find(tree, "section")
      original_ids = MapSet.new(Map.keys(tree.nodes))

      {:ok, duped, copy_id} = Tree.duplicate(tree, section.id)
      copy_ids = MapSet.new([copy_id | Tree.descendant_ids(duped, copy_id)])

      assert MapSet.disjoint?(original_ids, copy_ids)
    end

    test "the copy keeps attributes and children" do
      tree = Tree.parse!(~s(<.card variant="bordered"><:item>x</:item></.card>))
      card = find(tree, ".card")

      {:ok, duped, copy_id} = Tree.duplicate(tree, card.id)
      copy = Tree.get(duped, copy_id)

      assert Node.attr(copy, "variant") == {:string, "bordered"}
      assert length(copy.children) == length(card.children)
    end

    test "duplicating a root appends after it" do
      tree = roots_tree()
      a = find(tree, "a-one")

      {:ok, duped, _copy_id} = Tree.duplicate(tree, a.id)
      assert tags(duped, :root) == ["a-one", "a-one", "b-two", "c-three"]
    end
  end

  describe "subtree/2 and refresh_ids/1" do
    test "subtree detaches the root from its parent" do
      tree = Tree.parse!(~s(<div><section><p>x</p></section></div>))
      section = find(tree, "section")
      sub = Tree.subtree(tree, section.id)

      assert sub.roots == [section.id]
      assert Tree.get(sub, section.id).parent_id == nil
      assert Tree.size(sub) == 3
    end

    test "a subtree serializes on its own" do
      tree = Tree.parse!(~s(<div><section><p>x</p></section></div>))
      section = find(tree, "section")

      assert tree |> Tree.subtree(section.id) |> Serializer.serialize() ==
               ~s(<section><p>x</p></section>)
    end

    test "refresh_ids rewrites every id and keeps the structure" do
      original = Tree.parse!(~s(<section><p>x</p></section>))
      fresh = Tree.refresh_ids(original)

      assert MapSet.disjoint?(
               MapSet.new(Map.keys(original.nodes)),
               MapSet.new(Map.keys(fresh.nodes))
             )

      assert Serializer.serialize(fresh) == Serializer.serialize(original)
    end

    test "a pasted subtree can be re-inserted into its own source tree" do
      tree = Tree.parse!(~s(<div><p>x</p></div>))
      div = find(tree, "div")
      p = find(tree, "p")

      clipboard = tree |> Tree.subtree(p.id) |> Tree.refresh_ids()

      assert {:ok, pasted} = Tree.insert(tree, clipboard, div.id, 1)
      assert Serializer.serialize(pasted) == ~s(<div><p>x</p><p>x</p></div>)
    end
  end

  describe "set_attr/4 and delete_attr/3" do
    setup do
      tree = Tree.parse!(~s(<div class="a" id="b"></div>))
      %{tree: tree, id: hd(tree.roots)}
    end

    test "replaces an existing attribute in place", %{tree: tree, id: id} do
      assert {:ok, edited} = Tree.set_attr(tree, id, "class", {:string, "z"})
      assert Serializer.serialize(edited) == ~s(<div class="z" id="b"></div>)
    end

    test "appends a new attribute at the end", %{tree: tree, id: id} do
      assert {:ok, edited} = Tree.set_attr(tree, id, "role", {:string, "main"})
      assert Serializer.serialize(edited) == ~s(<div class="a" id="b" role="main"></div>)
    end

    test "can set an expression or a boolean attribute", %{tree: tree, id: id} do
      {:ok, edited} = Tree.set_attr(tree, id, "hidden", :boolean)
      {:ok, edited} = Tree.set_attr(edited, id, "phx-value", {:expr, "@v"})

      assert Serializer.serialize(edited) ==
               ~s(<div class="a" id="b" hidden phx-value={@v}></div>)
    end

    test "an unset attribute serializes to nothing", %{tree: tree, id: id} do
      assert {:ok, edited} = Tree.delete_attr(tree, id, "class")
      assert Serializer.serialize(edited) == ~s(<div id="b"></div>)
    end

    test "editing an unknown node is refused", %{tree: tree} do
      assert {:error, :unknown_node} = Tree.set_attr(tree, "nzzzzzzzz", "a", {:string, "b"})
      assert {:error, :unknown_node} = Tree.delete_attr(tree, "nzzzzzzzz", "a")
    end
  end

  describe "set_text/3" do
    test "replaces text content" do
      tree = Tree.parse!(~s(<p>old</p>))
      text = Enum.find(Tree.walk(tree), &(&1.kind == :text))

      assert {:ok, edited} = Tree.set_text(tree, text.id, "new")
      assert Serializer.serialize(edited) == ~s(<p>new</p>)
    end

    test "text that was whitespace stops being marked as whitespace" do
      tree = Tree.parse!(~s(<div> </div>))
      text = Enum.find(Tree.walk(tree), &(&1.kind == :text))
      assert Tree.get(tree, text.id).meta.whitespace?

      {:ok, edited} = Tree.set_text(tree, text.id, "content")
      refute Map.has_key?(Tree.get(edited, text.id).meta, :whitespace?)
    end
  end

  describe "set_style/5 — the responsive cascade" do
    setup do
      tree = Tree.parse!(~s(<div></div>))
      %{tree: tree, id: hd(tree.roots)}
    end

    test "records an override in its bucket", %{tree: tree, id: id} do
      assert {:ok, styled} = Tree.set_style(tree, id, :tablet, "padding", "14px")
      assert Tree.get(styled, id).meta.styles == %{tablet: %{"padding" => "14px"}}
    end

    test "a tablet write does not touch base", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :base, "gap", "8px")
      {:ok, styled} = Tree.set_style(styled, id, :tablet, "gap", "4px")

      assert Tree.get(styled, id).meta.styles == %{
               base: %{"gap" => "8px"},
               tablet: %{"gap" => "4px"}
             }
    end

    test "setting nil clears just that property", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :base, "gap", "8px")
      {:ok, styled} = Tree.set_style(styled, id, :base, "padding", "2px")
      {:ok, styled} = Tree.set_style(styled, id, :base, "gap", nil)

      assert Tree.get(styled, id).meta.styles == %{base: %{"padding" => "2px"}}
    end

    test "emptying a bucket removes the bucket", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :hover, "color", "red")
      {:ok, styled} = Tree.set_style(styled, id, :hover, "color", nil)

      assert Tree.get(styled, id).meta.styles == %{}
    end

    test "reset_styles clears only the named bucket", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :base, "gap", "8px")
      {:ok, styled} = Tree.set_style(styled, id, :mobile, "gap", "2px")
      {:ok, reset} = Tree.reset_styles(styled, id, :mobile)

      assert Tree.get(reset, id).meta.styles == %{base: %{"gap" => "8px"}}
    end

    # ADR-8: an override is not editor-only state — it compiles to a Tailwind utility on the way
    # out, which is the only form the runtime Tailwind pass (server-rendered classes only) can see.
    test "an override compiles into the class attribute on save", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :mobile, "padding", "14px")
      assert Serializer.serialize(styled) == ~s(<div class="max-[560px]:p-[14px]"></div>)
    end

    test "an override round-trips back into the same map", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :mobile, "padding", "14px")
      {:ok, styled} = Tree.set_style(styled, id, :hover, "background", "#17161a")

      reparsed = styled |> Serializer.serialize() |> Tree.parse!()
      node = Tree.get(reparsed, hd(reparsed.roots))

      assert node.meta.styles == %{
               mobile: %{"padding" => "14px"},
               hover: %{"background" => "#17161a"}
             }
    end

    test "the author's own classes survive alongside generated ones" do
      tree = Tree.parse!(~s(<div class="card shadow"></div>))
      id = hd(tree.roots)

      {:ok, styled} = Tree.set_style(tree, id, :base, "gap", "20px")

      assert Serializer.serialize(styled) == ~s(<div class="card shadow gap-[20px]"></div>)
    end

    test "clearing every override removes the class attribute it created", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :base, "gap", "20px")
      {:ok, cleared} = Tree.reset_styles(styled, id, :base)

      assert Serializer.serialize(cleared) == ~s(<div></div>)
    end

    test "a property with no utility is kept in state but emits nothing", %{tree: tree, id: id} do
      {:ok, styled} = Tree.set_style(tree, id, :base, "backdrop-filter", "blur(4px)")

      assert Tree.get(styled, id).meta.styles == %{base: %{"backdrop-filter" => "blur(4px)"}}
      assert Serializer.serialize(styled) == ~s(<div></div>)
    end
  end

  describe "wrap/3 and unwrap/2" do
    test "wrap puts a node inside a new parent in its own place" do
      tree = Tree.parse!(~s(<section><p>x</p><span>y</span></section>))
      p = find(tree, "p")

      assert {:ok, wrapped} = Tree.wrap(tree, p.id, Node.new(:tag, tag: "figure"))

      assert Serializer.serialize(wrapped) ==
               ~s(<section><figure><p>x</p></figure><span>y</span></section>)
    end

    test "unwrap promotes children into the node's place, in order" do
      tree = Tree.parse!(~s(<section><figure><p>x</p><em>y</em></figure><span>z</span></section>))
      figure = find(tree, "figure")

      assert {:ok, unwrapped} = Tree.unwrap(tree, figure.id)

      assert Serializer.serialize(unwrapped) ==
               ~s(<section><p>x</p><em>y</em><span>z</span></section>)
    end

    test "unwrap of a childless node just deletes it" do
      tree = Tree.parse!(~s(<section><figure></figure><span>z</span></section>))
      figure = find(tree, "figure")

      assert {:ok, unwrapped} = Tree.unwrap(tree, figure.id)
      assert Serializer.serialize(unwrapped) == ~s(<section><span>z</span></section>)
    end

    test "wrap and unwrap round-trip to the original" do
      original = ~s(<section><p>x</p></section>)
      tree = Tree.parse!(original)
      p = find(tree, "p")

      {:ok, wrapped} = Tree.wrap(tree, p.id, Node.new(:tag, tag: "figure"))
      figure = find(wrapped, "figure")
      {:ok, unwrapped} = Tree.unwrap(wrapped, figure.id)

      assert Serializer.serialize(unwrapped) == original
    end
  end

  describe "invariants after arbitrary edits" do
    test "every child's parent_id agrees with its parent's child list" do
      tree = Tree.parse!(~s(<div><section><p>x</p><em>y</em></section><span>z</span></div>))
      section = find(tree, "section")
      em = find(tree, "em")
      span = find(tree, "span")

      {:ok, tree} = Tree.move(tree, em.id, :root, 0)
      {:ok, tree} = Tree.duplicate(tree, section.id) |> then(fn {:ok, t, _id} -> {:ok, t} end)
      {:ok, tree} = Tree.delete(tree, span.id)

      for node <- Tree.walk(tree) do
        siblings = Tree.child_ids(tree, node.parent_id || :root)
        assert node.id in siblings, "#{node.id} is missing from its parent's children"
      end
    end

    test "no orphan ids remain after a cascading delete" do
      tree = Tree.parse!(~s(<div><section><p>x</p></section></div>))
      section = find(tree, "section")
      {:ok, tree} = Tree.delete(tree, section.id)

      reachable = MapSet.new(Tree.walk(tree), & &1.id)
      assert MapSet.new(Map.keys(tree.nodes)) == reachable
    end
  end

  # This combinator had no test at all, which is how it shipped rewriting every component's scope to
  # the page's site — including global ones, whose compiled module is hashed with "Global". Every
  # global component inserted from a kit example came out as the runtime's red "failed to render".
  describe "rewrite_site/3" do
    defp palette do
      [
        %{name: "tenant-hero", global?: false},
        %{name: "global-footer", global?: true}
      ]
    end

    defp site_of(tree, name) do
      tree
      |> Tree.walk()
      |> Enum.find(&(Node.component_name(&1) == name))
      |> Node.attr_text("site")
    end

    test "a tenant component is bound to the page's site" do
      tree =
        ~s(<.component component_name="tenant-hero" site="Global" />)
        |> Tree.parse!()
        |> Tree.rewrite_site("acme", palette())

      assert site_of(tree, "tenant-hero") == "acme"
    end

    test "a global component stays Global on a tenant page" do
      tree =
        ~s(<.component component_name="global-footer" site="acme" />)
        |> Tree.parse!()
        |> Tree.rewrite_site("acme", palette())

      assert site_of(tree, "global-footer") == "Global"
    end

    test "both are corrected in one pass, however they were authored" do
      tree =
        ~s(<div><.component component_name="global-footer" site="acme" /><.component component_name="tenant-hero" site="Global" /></div>)
        |> Tree.parse!()
        |> Tree.rewrite_site("acme", palette())

      assert site_of(tree, "global-footer") == "Global"
      assert site_of(tree, "tenant-hero") == "acme"
    end

    test "a component the palette has never heard of is left exactly as authored" do
      tree =
        ~s(<.component component_name="from-somewhere-else" site="other" />)
        |> Tree.parse!()
        |> Tree.rewrite_site("acme", palette())

      assert site_of(tree, "from-somewhere-else") == "other"
    end

    test "a component with no site attribute gains none" do
      tree =
        ~s(<.component component_name="tenant-hero" />)
        |> Tree.parse!()
        |> Tree.rewrite_site("acme", palette())

      assert site_of(tree, "tenant-hero") == nil
    end

    test "with no site at all, a tenant component falls back to Global" do
      tree =
        ~s(<.component component_name="tenant-hero" site="acme" />)
        |> Tree.parse!()
        |> Tree.rewrite_site(nil, palette())

      assert site_of(tree, "tenant-hero") == "Global"
    end

    test "an empty palette changes nothing" do
      source = ~s(<.component component_name="tenant-hero" site="acme" />)
      tree = source |> Tree.parse!() |> Tree.rewrite_site("other", [])

      assert Serializer.serialize(tree) == source
    end

    test "plain tags are untouched" do
      source = ~s(<div class="x"><p>hi</p></div>)
      tree = source |> Tree.parse!() |> Tree.rewrite_site("acme", palette())

      assert Serializer.serialize(tree) == source
    end
  end
end
