defmodule MishkaCmsCore.Runtime.PageBuilder.IdsTest do
  @moduledoc """
  Placing an example twice must not put two elements in the document answering to one id.

  ## What was wrong

  Every palette entry is a worked example, and an example names things. The kit's delete dialog
  ships `id="modal-delete-page"` with `id="btn-delete-cancel"` inside it; its newsletter dialog
  ships an `<input id="modal-newsletter-email">` with a label pointing `for` at it. Placing one of
  those twice — the ordinary way to build a second dialog — produced two `#modal-delete-page`, and
  from then on the author's second button opened the first dialog, `getElementById` answered the
  wrong element, and LiveView raised trying to patch a container it could not tell apart.

  Duplicate had a different answer to the same question and it was worse: it replaced the written id
  with a random one, so the author's name for the element was thrown away AND the copy's own button
  was left pointing at the original.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Ids
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @moduletag :unit

  defp tree!(source) do
    {:ok, tree} = Tree.parse(source)
    tree
  end

  defp ids(tree) do
    for node <- Tree.walk(tree),
        {:string, value} <- [Node.attr(node, "id")],
        do: value
  end

  defp node_with_id(tree, id) do
    Enum.find(Tree.walk(tree), &(Node.attr(&1, "id") == {:string, id}))
  end

  defp attr(tree, id, name) do
    tree |> node_with_id(id) |> Node.attr(name)
  end

  # The ids a second parse of the same markup produced — which is what "placed it again" means to
  # the tree: brand new node ids, the example's own DOM ids carried in verbatim.
  defp place(tree, source) do
    added = tree!(source)
    {:ok, merged} = Tree.insert(tree, added, :root, length(tree.roots))
    {merged, MapSet.new(Map.keys(added.nodes))}
  end

  describe "dedupe/2" do
    test "a second copy of an example is renumbered, the one already placed is left alone" do
      first = tree!(~S|<div id="modal-delete-page">One</div>|)
      {merged, arrived} = place(first, ~S|<div id="modal-delete-page">Two</div>|)

      settled = Ids.dedupe(merged, arrived)

      assert ids(settled) == ["modal-delete-page", "modal-delete-page-2"]
    end

    test "the arrival yields even when it was dropped above the element already there" do
      first = tree!(~S|<div id="hero">incumbent</div>|)
      added = tree!(~S|<div id="hero">arrival</div>|)
      {:ok, merged} = Tree.insert(first, added, :root, 0)

      settled = Ids.dedupe(merged, MapSet.new(Map.keys(added.nodes)))

      # Document order now puts the arrival first, and it is still the one renamed.
      assert ids(settled) == ["hero-2", "hero"]
    end

    test "numbering fills a gap rather than counting copies" do
      first = tree!(~S|<div id="box">a</div><div id="box-3">b</div>|)
      {merged, arrived} = place(first, ~S|<div id="box">c</div>|)

      assert ids(Ids.dedupe(merged, arrived)) == ["box", "box-3", "box-2"]
    end

    test "a third copy takes the next free number, not the same one again" do
      first = tree!(~S|<div id="box">a</div><div id="box-2">b</div>|)
      {merged, arrived} = place(first, ~S|<div id="box">c</div>|)

      assert ids(Ids.dedupe(merged, arrived)) == ["box", "box-2", "box-3"]
    end
  end

  describe "references inside the arrival" do
    test "a selector in an expression follows the rename" do
      first =
        tree!(
          ~S|<div id="modal-x">one</div><button phx-click={JS.exec("data-pb-open", to: "#modal-x")}>open</button>|
        )

      {merged, arrived} =
        place(
          first,
          ~S|<div id="modal-x">two</div><button phx-click={JS.exec("data-pb-open", to: "#modal-x")}>open</button>|
        )

      settled = Ids.dedupe(merged, arrived)

      openers =
        for node <- Tree.walk(settled),
            {:expr, source} <- [Node.attr(node, "phx-click")],
            do: source

      assert openers == [
               ~S|JS.exec("data-pb-open", to: "#modal-x")|,
               ~S|JS.exec("data-pb-open", to: "#modal-x-2")|
             ]
    end

    test "a bare id reference — a label's for — follows the rename" do
      first = tree!(~S|<div><label for="email">Email</label><input id="email" /></div>|)

      {merged, arrived} =
        place(first, ~S|<div><label for="email">Email</label><input id="email" /></div>|)

      settled = Ids.dedupe(merged, arrived)

      fors =
        for node <- Tree.walk(settled),
            {:string, value} <- [Node.attr(node, "for")],
            do: value

      assert fors == ["email", "email-2"]
    end

    test "one id in a space-separated list is swapped and its neighbours are not" do
      first = tree!(~S|<div id="note">n</div><td headers="note total">1</td>|)
      {merged, arrived} = place(first, ~S|<div id="note">n</div><td headers="note total">1</td>|)

      settled = Ids.dedupe(merged, arrived)

      headers =
        for node <- Tree.walk(settled),
            {:string, value} <- [Node.attr(node, "headers")],
            do: value

      assert headers == ["note total", "note-2 total"]
    end

    test "a longer id that merely starts with the renamed one is left alone" do
      first =
        tree!(
          ~S|<div id="modal-x">a</div><h2 id="modal-x-title">t</h2><a href="#modal-x-title">go</a>|
        )

      {merged, arrived} =
        place(
          first,
          ~S|<div id="modal-x">a</div><h2 id="modal-x-title">t</h2><a href="#modal-x-title">go</a>|
        )

      settled = Ids.dedupe(merged, arrived)

      # `modal-x` becomes `modal-x-2`; the anchor still points at the title, whatever the title is
      # now called, and never at `#modal-x-2-title`.
      hrefs =
        for node <- Tree.walk(settled),
            {:string, value} <- [Node.attr(node, "href")],
            do: value

      assert hrefs == ["#modal-x-title", "#modal-x-title-2"]
      assert "modal-x-2" in ids(settled)
    end

    test "an element already on the page keeps pointing at the id it still owns" do
      first = tree!(~S|<div id="modal-x">a</div><a href="#modal-x">go</a>|)
      {merged, arrived} = place(first, ~S|<div id="modal-x">b</div>|)

      settled = Ids.dedupe(merged, arrived)

      assert attr(settled, "modal-x", "id") == {:string, "modal-x"}

      hrefs =
        for node <- Tree.walk(settled),
            {:string, value} <- [Node.attr(node, "href")],
            do: value

      assert hrefs == ["#modal-x"], "the incumbent link must not be repointed at the copy"
    end
  end

  describe "what it refuses to touch" do
    test "an id bound to an expression is not a collision and is not renamed" do
      first = tree!(~S|<div id={@row.id}>a</div>|)
      {merged, arrived} = place(first, ~S|<div id={@row.id}>b</div>|)

      settled = Ids.dedupe(merged, arrived)

      bound =
        for node <- Tree.walk(settled),
            {:expr, source} <- [Node.attr(node, "id")],
            do: source

      assert bound == ["@row.id", "@row.id"]
    end

    test "a document arriving whole is the author's own text and is left as written" do
      tree = tree!(~S|<div id="dup">a</div><div id="dup">b</div>|)

      assert ids(Ids.dedupe(tree, [])) == ["dup", "dup"]
    end

    test "a blank id is not a name and claims nothing" do
      first = tree!(~S|<div id="">a</div>|)
      {merged, arrived} = place(first, ~S|<div id="">b</div>|)

      assert ids(Ids.dedupe(merged, arrived)) == ["", ""]
    end
  end
end
