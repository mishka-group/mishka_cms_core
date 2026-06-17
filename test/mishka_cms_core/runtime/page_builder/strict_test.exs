defmodule MishkaCmsCore.Runtime.PageBuilder.StrictTest do
  @moduledoc """
  The checks that turn a silent wrong answer into a loud one, and the documents they catch.

  Every case here is a real shape that reached production undetected: a `children` list naming an id
  that is not in the document, which costs that subtree at the next save because the serializer is
  total and the save's own check only proves the output parses; a node claiming a parent that does
  not claim it back; a cycle, which turns a walk into a hang.
  """
  use ExUnit.Case, async: true

  require MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @moduletag :unit

  defp doc, do: Tree.parse!(~s(<section><h1>Title</h1><p>hello</p></section>))

  defp tagged(tree, tag), do: Enum.find(Tree.walk(tree), &(&1.tag == tag))

  describe "a document that is internally consistent" do
    test "passes" do
      assert :ok = Strict.inspect_tree(doc())
    end

    test "so does an empty one" do
      assert :ok = Strict.inspect_tree(Tree.new())
    end

    test "and anything that is not a document is refused rather than crashing" do
      assert {:error, _reason} = Strict.inspect_tree(%{nodes: %{}, roots: []})
    end
  end

  describe "what it catches" do
    # THE ONE THAT COSTS DATA. The serializer skips a child it cannot find, so the subtree simply
    # does not appear in what the save writes — and the result parses perfectly, which is all the
    # save's own guard checks.
    test "a child that is not in the document" do
      tree = doc()
      section = tagged(tree, "section")
      broken = put_in(tree.nodes[section.id].children, section.children ++ ["nmissing1"])

      assert {:error, reason} = Strict.inspect_tree(broken)
      assert reason =~ "nmissing1"
    end

    test "and the save it would have made is quietly smaller" do
      tree = doc()
      section = tagged(tree, "section")
      heading = tagged(tree, "h1")

      # The heading is gone from the map but still listed as a child.
      broken = %Tree{tree | nodes: Map.delete(tree.nodes, heading.id)}

      assert {:error, _reason} = Strict.inspect_tree(broken)

      # This is the damage the check exists to prevent: valid markup, one element short.
      written = Serializer.serialize(broken)
      refute written =~ "Title"
      assert {:ok, _reparsed} = Tree.parse(written)
      assert section.id
    end

    test "a root that is not in the document" do
      tree = doc()

      assert {:error, reason} =
               Strict.inspect_tree(%Tree{tree | roots: tree.roots ++ ["nghost12"]})

      assert reason =~ "nghost12"
    end

    test "a node whose parent does not claim it" do
      tree = doc()
      heading = tagged(tree, "h1")
      section = tagged(tree, "section")

      orphaned =
        put_in(tree.nodes[section.id].children, List.delete(section.children, heading.id))

      assert {:error, reason} = Strict.inspect_tree(orphaned)
      assert reason =~ heading.id
    end

    test "a node with no parent that is not a root" do
      tree = doc()
      heading = tagged(tree, "h1")
      loose = put_in(tree.nodes[heading.id].parent_id, nil)

      assert {:error, reason} = Strict.inspect_tree(loose)
      assert reason =~ "not a root"
    end

    # A CYCLE THE OTHER CHECKS CANNOT SEE. Every node still names one parent that lists it, so the
    # parent rule is satisfied — what is wrong is that a second node lists it as well, which closes
    # a loop and turns any walk from the root into a hang.
    test "a node that is its own ancestor" do
      tree = Tree.parse!(~s(<section><h1></h1></section>))
      section = tagged(tree, "section")
      heading = tagged(tree, "h1")

      cyclic = put_in(tree.nodes[heading.id].children, [section.id])

      assert {:error, reason} = Strict.inspect_tree(cyclic)
      assert reason =~ "own ancestor"
    end
  end

  describe "the raising forms" do
    test "tree! passes a good document through" do
      assert :ok = Strict.tree!(doc(), "a test")
    end

    test "tree! raises on a broken one, naming where" do
      tree = doc()
      broken = %Tree{tree | roots: ["nghost12"]}

      assert_raise Strict.Violation, ~r/somewhere specific/, fn ->
        Strict.tree!(broken, "somewhere specific")
      end
    end

    test "check! raises only when the condition fails" do
      assert :ok = Strict.check!(1 + 1 == 2, "arithmetic", "two and two")

      assert_raise Strict.Violation, ~r/arithmetic/, fn ->
        Strict.check!(1 + 1 == 3, "arithmetic", "two and two")
      end
    end

    test "violation! always raises, and says both halves" do
      assert_raise Strict.Violation, ~r/a place: a reason/, fn ->
        Strict.violation!("a place", "a reason")
      end
    end
  end

  describe "what it costs a release" do
    # A release compiles the checks out entirely rather than testing a flag at runtime — there is no
    # branch to take in production, so there is nothing to switch off there either.
    test "it is on here" do
      assert Strict.enabled?()
    end
  end

  describe "the mutation funnel is checked" do
    test "an ordinary edit leaves a consistent document" do
      {:ok, session} =
        MishkaCmsCore.Runtime.PageBuilder.EditorSession.open(%{
          section: "page",
          template: ~s(<section><h1>Title</h1><p>hello</p></section>)
        })

      id = tagged(session.tree, "h1").id

      {:ok, edited} =
        MishkaCmsCore.Runtime.PageBuilder.EditorSession.apply_op(session.token, %{
          kind: :set_text,
          node_id: id,
          text: "Changed"
        })

      assert :ok = Strict.inspect_tree(edited.tree)
    end

    test "unwrapping keeps the children it cannot promote, rather than deleting them" do
      tree = Tree.parse!(~s(<div><section><p>kept</p></section></div>))
      section = tagged(tree, "section")

      assert {:ok, unwrapped} = Tree.unwrap(tree, section.id)
      assert :ok = Strict.inspect_tree(unwrapped)
      assert Serializer.serialize(unwrapped) =~ "kept"
    end
  end
end
