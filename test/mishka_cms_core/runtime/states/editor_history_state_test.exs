defmodule MishkaCmsCore.Runtime.States.EditorHistoryStateTest do
  @moduledoc """
  What the undo history costs to keep, and what falls off when a session has kept too much.

  The budget is global configuration, so this runs alone rather than alongside the async suites —
  a sibling watching its own session dropped to a few kilobytes would fail for reasons that have
  nothing to do with it.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Patch
  alias MishkaCmsCore.Runtime.States.EditorHistoryState

  @moduletag :unit

  setup do
    token = "hist#{System.unique_integer([:positive])}" |> String.pad_trailing(32, "0")
    on_exit(fn -> EditorHistoryState.delete_all(token) end)
    %{token: token}
  end

  defp doc(cards) do
    Tree.parse!(
      "<section>" <> String.duplicate("<div><h3>a</h3><p>b</p></div>", cards) <> "</section>"
    )
  end

  defp edited(tree, value) do
    id = tree |> Tree.walk() |> Enum.find(&(&1.tag == "h3")) |> Map.get(:id)
    {:ok, next} = Tree.set_attr(tree, id, "data-x", value)
    next
  end

  describe "remembering a step" do
    test "a patch reads back and reconstructs the document exactly", %{token: token} do
      before = doc(5)
      during = edited(before, "1")

      ref = EditorHistoryState.put(token, make_ref(), before, during)

      assert {:ok, {:patch, patch}} = EditorHistoryState.fetch(token, ref)
      assert Patch.apply_to(during, patch) == before
    end

    test "it costs what changed, not what exists", %{token: token} do
      small = doc(5)
      large = doc(400)

      small_ref = EditorHistoryState.put(token, make_ref(), small, edited(small, "1"))
      small_bytes = EditorHistoryState.bytes(token)

      EditorHistoryState.delete(token, small_ref)
      _large_ref = EditorHistoryState.put(token, make_ref(), large, edited(large, "1"))
      large_bytes = EditorHistoryState.bytes(token)

      # The documents differ by eighty times; the same edit to each does not.
      assert Tree.size(large) > Tree.size(small) * 50
      assert large_bytes < small_bytes * 2

      # And both are a tiny fraction of the document they belong to.
      assert large_bytes * 100 < byte_size(:erlang.term_to_binary(large))
    end

    test "a document with no version after it is kept whole", %{token: token} do
      tree = doc(5)

      ref = EditorHistoryState.keep(token, make_ref(), tree)

      assert {:ok, {:tree, ^tree}} = EditorHistoryState.fetch(token, ref)
    end

    # A CHANGE TO A SESSION CAN BE TRIED TWICE, and writes its step under the reference it reserved
    # before the first try. The second write has to replace the first — in what it remembers and in
    # what it costs — or every retry would leave a row, or a charge, behind.
    test "writing a reference again rewrites what it remembers, and charges it once", %{
      token: token
    } do
      first = doc(5)
      second = edited(first, "1")
      third = edited(second, "2")
      ref = make_ref()
      before = EditorHistoryState.count()

      ^ref = EditorHistoryState.put(token, ref, first, second)
      ^ref = EditorHistoryState.put(token, ref, first, third)

      assert {:ok, {:patch, patch}} = EditorHistoryState.fetch(token, ref)
      assert Patch.apply_to(third, patch) == first
      assert EditorHistoryState.count() == before + 1
      assert EditorHistoryState.bytes(token) == EditorHistoryState.bytes(token, ref)
    end

    test "and so does a document kept whole", %{token: token} do
      tree = doc(5)
      ref = make_ref()

      ^ref = EditorHistoryState.keep(token, ref, tree)
      once = EditorHistoryState.bytes(token)
      ^ref = EditorHistoryState.keep(token, ref, tree)

      assert EditorHistoryState.bytes(token) == once
      assert EditorHistoryState.bytes(token, ref) == once
    end

    test "a reference nobody stored is not an answer", %{token: token} do
      assert :error = EditorHistoryState.fetch(token, make_ref())
      assert :error = EditorHistoryState.fetch(token, "not a reference")
    end
  end

  describe "what a session is holding" do
    test "the running total follows what is added, replaced and dropped", %{token: token} do
      tree = doc(5)
      assert EditorHistoryState.bytes(token) == 0

      one = EditorHistoryState.put(token, make_ref(), tree, edited(tree, "1"))
      after_one = EditorHistoryState.bytes(token)
      assert after_one > 0

      _two = EditorHistoryState.put(token, make_ref(), tree, edited(tree, "2"))
      assert EditorHistoryState.bytes(token) > after_one

      EditorHistoryState.delete(token, one)
      assert EditorHistoryState.bytes(token) < after_one * 2

      EditorHistoryState.delete_all(token)
      assert EditorHistoryState.bytes(token) == 0
    end

    test "one session's history is not another's", %{token: token} do
      other = "other#{System.unique_integer([:positive])}" |> String.pad_trailing(32, "0")
      on_exit(fn -> EditorHistoryState.delete_all(other) end)

      tree = doc(5)
      _mine = EditorHistoryState.put(token, make_ref(), tree, edited(tree, "1"))

      assert EditorHistoryState.bytes(other) == 0
      refute EditorHistoryState.bytes(token) == 0
    end

    test "the running total is not counted as a step", %{token: token} do
      tree = doc(5)
      before = EditorHistoryState.count()

      EditorHistoryState.put(token, make_ref(), tree, edited(tree, "1"))

      assert EditorHistoryState.count() == before + 1
    end
  end

  describe "the budget" do
    setup do
      original = Application.get_env(:mishka_cms_core, :builder_history_bytes)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :builder_history_bytes, original) end)
      :ok
    end

    test "it is what the store reports, and configuration moves it" do
      Application.put_env(:mishka_cms_core, :builder_history_bytes, 12_345)

      assert EditorHistoryState.max_bytes() == 12_345
    end

    test "a session under budget keeps every step", %{token: token} do
      Application.put_env(:mishka_cms_core, :builder_history_bytes, 8_388_608)

      tree = doc(5)

      refs =
        Enum.map(1..40, fn n ->
          EditorHistoryState.put(token, make_ref(), tree, edited(tree, to_string(n)))
        end)

      assert EditorHistoryState.bytes(token) < EditorHistoryState.max_bytes()
      assert Enum.all?(refs, &match?({:ok, _}, EditorHistoryState.fetch(token, &1)))
    end
  end
end
