defmodule MishkaCmsCore.Runtime.PageBuilder.BindingTest do
  @moduledoc """
  The Data tab: repeating a node over a CMS collection.

  The point of holding the binding as structured state rather than as authored source is that it can
  be read back. A loop the editor generated must reopen as a picker set to the right collection —
  not as an opaque chip — while a loop a human wrote by hand must stay opaque, because guessing at
  arbitrary comprehensions is exactly how the old editor corrupted templates.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Binding
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  defp bound_tree(source_key, opts \\ []) do
    tree = Tree.parse!(~s(<article class="card">Post</article>))
    id = hd(tree.roots)
    {:ok, bound} = Binding.put(tree, id, source_key, opts)
    {bound, id}
  end

  describe "sources" do
    test "every source names an assign and a singular item" do
      for source <- Binding.sources() do
        assert String.starts_with?(source.assign, "@")
        assert source.item != ""
        assert source.label != ""
      end
    end

    test "lookup by key" do
      assert Binding.source("posts").label == "Blog posts"
      assert Binding.source("nope") == nil
    end
  end

  describe "put/4 and delete/2" do
    test "binds a node to a collection" do
      {tree, id} = bound_tree("posts")
      binding = tree |> Tree.get(id) |> Binding.get()

      assert binding.source == "posts"
      assert binding.assign == "@posts"
      assert binding.item == "post"
      assert is_nil(binding.limit)
    end

    test "an unknown source is refused rather than written" do
      tree = Tree.parse!("<div></div>")
      assert {:error, :unknown_source} = Binding.put(tree, hd(tree.roots), "spreadsheets")
    end

    test "the item name and a limit can be overridden" do
      {tree, id} = bound_tree("posts", item: "entry", limit: 3)
      binding = tree |> Tree.get(id) |> Binding.get()

      assert binding.item == "entry"
      assert binding.limit == 3
    end

    test "delete stops the node repeating" do
      {tree, id} = bound_tree("posts")
      assert {:ok, cleared} = Binding.delete(tree, id)

      refute cleared |> Tree.get(id) |> Binding.bound?()
    end

    test "deleting on an unknown node is refused" do
      assert {:error, :unknown_node} = Binding.delete(Tree.parse!("<div></div>"), "nzzzzzzzz")
    end
  end

  describe "serialization" do
    test "a bound node is emitted inside a generated :for" do
      {tree, _id} = bound_tree("posts")

      assert Serializer.serialize(tree) ==
               ~s(<%= for post <- @posts do %><article class="card">Post</article><% end %>)
    end

    test "a limit becomes Enum.take" do
      {tree, _id} = bound_tree("posts", limit: 3)
      assert Serializer.serialize(tree) =~ "for post <- Enum.take(@posts, 3) do"
    end

    test "an unbound node is untouched" do
      tree = Tree.parse!(~s(<article>Post</article>))
      assert Serializer.serialize(tree) == ~s(<article>Post</article>)
    end

    test "the generated loop is valid HEEx" do
      {tree, _id} = bound_tree("documents", limit: 5)
      assert {:ok, _formatted} = Serializer.to_heex(tree)
    end
  end

  describe "parse/1 — reading a binding back" do
    test "recognises a loop this module generated" do
      assert {:ok, binding} = Binding.parse("for post <- @posts do")
      assert binding.source == "posts"
      assert binding.item == "post"
      assert is_nil(binding.limit)
    end

    test "recognises a limited loop" do
      assert {:ok, binding} = Binding.parse("for item <- Enum.take(@media, 4) do")
      assert binding.source == "media"
      assert binding.item == "item"
      assert binding.limit == 4
    end

    # ADR-9: anything the editor did not write stays an opaque atomic chip.
    test "a hand-written comprehension is not claimed" do
      assert Binding.parse("for x <- @something_else do") == :error
      assert Binding.parse("for {k, v} <- @map do") == :error
      assert Binding.parse("if @ok do") == :error
      assert Binding.parse("for post <- @posts |> Enum.sort() do") == :error
      assert Binding.parse(nil) == :error
    end

    test "a generated loop round-trips through parse" do
      for source <- Binding.sources() do
        {tree, id} = bound_tree(source.key)
        text = tree |> Tree.get(id) |> Binding.open()
        inner = text |> String.replace_prefix("<%= ", "") |> String.replace_suffix(" %>", "")

        assert {:ok, binding} = Binding.parse(inner)
        assert binding.source == source.key
      end
    end
  end
end
