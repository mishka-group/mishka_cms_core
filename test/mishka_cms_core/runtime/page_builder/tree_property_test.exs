defmodule MishkaCmsCore.Runtime.PageBuilder.TreePropertyTest do
  @moduledoc """
  The laws the document model has to obey for any document and any sequence of edits.

  Each of these is a bug that shipped, restated as something that must hold for every input rather
  than for the cases somebody thought of:

    * `unwrap/2` skipped the children it could not promote and then deleted the node they were still
      inside, so "take the wrapper off" became "take the wrapper and its contents off" — one step,
      answering `{:ok, tree}`. The law is that a document is internally consistent after every
      operation, and that nothing but a delete makes it smaller.
    * carrying the selection across a revert landed on a same-tag neighbour when the document had
      changed shape, because an address is a position. The law is that it lands on the same element
      or on nothing, never on a stranger.
    * a plain address moves when the formatter runs, because indentation becomes text nodes. The law
      is that a content address does not.
  """
  use ExUnit.Case, async: true

  import ExUnitProperties
  import StreamData

  alias MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @moduletag :property

  defp document do
    gen all(
          sections <- integer(1..3),
          leaves <- integer(1..3),
          nested <- boolean()
        ) do
      Tree.parse!("<main>" <> Enum.map_join(1..sections, &block(&1, leaves, nested)) <> "</main>")
    end
  end

  defp block(index, leaves, false),
    do: ~s(<section id="s#{index}">) <> Enum.map_join(1..leaves, &"<p>t#{&1}</p>") <> "</section>"

  defp block(index, leaves, true),
    do:
      ~s(<section id="s#{index}"><div>) <>
        Enum.map_join(1..leaves, &"<span>t#{&1}</span>") <> "</div></section>"

  defp tags(tree), do: tree |> Tree.walk() |> Enum.filter(&(&1.kind == :tag))

  defp pick(tree, index) do
    candidates = tags(tree)
    Enum.at(candidates, rem(index, length(candidates)))
  end

  describe "a document stays internally consistent" do
    property "after any single operation the model offers" do
      check all(tree <- document(), index <- integer(0..30), max_runs: 60) do
        node = pick(tree, index)

        results = [
          Tree.set_attr(tree, node.id, "data-x", "1"),
          Tree.set_text(tree, node.id, "changed"),
          Tree.delete(tree, node.id),
          Tree.duplicate(tree, node.id),
          Tree.unwrap(tree, node.id)
        ]

        for result <- results, match?({:ok, _}, result) or match?({:ok, _, _}, result) do
          next = ok_or(result, tree)

          assert :ok = Strict.inspect_tree(next),
                 "an operation left the document inconsistent: #{inspect(Strict.inspect_tree(next))}"
        end
      end
    end

    property "after a whole sequence of them" do
      check all(tree <- document(), steps <- list_of(integer(0..30), length: 1..8), max_runs: 40) do
        final =
          Enum.reduce(steps, tree, fn index, acc ->
            node = pick(acc, index)

            case rem(index, 3) do
              0 -> ok_or(Tree.set_attr(acc, node.id, "data-#{index}", "1"), acc)
              1 -> ok_or(Tree.duplicate(acc, node.id), acc)
              _other -> ok_or(Tree.set_text(acc, node.id, "t#{index}"), acc)
            end
          end)

        assert :ok = Strict.inspect_tree(final)
      end
    end

    # THE ONE THAT WAS FALSE. Unwrapping deleted the children it could not promote.
    property "unwrapping never loses what was inside" do
      check all(tree <- document(), index <- integer(0..30), max_runs: 60) do
        node = pick(tree, index)
        inside = Tree.descendant_ids(tree, node.id)

        case Tree.unwrap(tree, node.id) do
          {:ok, unwrapped} ->
            assert :ok = Strict.inspect_tree(unwrapped)

            for id <- inside do
              assert Tree.get(unwrapped, id), "unwrapping lost #{id}"
            end

          {:error, _refused} ->
            # A refused unwrap must leave the document alone, which is the whole point of refusing.
            assert :ok = Strict.inspect_tree(tree)
        end
      end
    end
  end

  describe "serializing" do
    property "a document survives the round trip it is saved through" do
      check all(tree <- document(), max_runs: 60) do
        once = Serializer.serialize(tree)
        twice = once |> Tree.parse!() |> Serializer.serialize()

        assert once == twice
      end
    end

    property "and everything that was in it is still in it" do
      check all(tree <- document(), max_runs: 60) do
        reparsed = tree |> Serializer.serialize() |> Tree.parse!()

        assert Enum.map(tags(tree), & &1.tag) == Enum.map(tags(reparsed), & &1.tag)
      end
    end
  end

  describe "addressing" do
    property "a content address finds the same element again after formatting" do
      check all(tree <- document(), max_runs: 60) do
        {:ok, formatted} = Serializer.to_heex(tree)
        pretty = Tree.parse!(formatted)

        for node <- tags(tree), address = Tree.content_address(tree, node.id), address do
          assert found = Tree.at_content_address(pretty, address),
                 "#{node.tag} at #{address} was not there after formatting"

          assert Tree.get(pretty, found).tag == node.tag
        end
      end
    end

    property "and it round-trips within one document, at every depth" do
      check all(tree <- document(), max_runs: 60) do
        for node <- Tree.walk(tree), address = Tree.content_address(tree, node.id), address do
          assert Tree.at_content_address(tree, address) == node.id
        end
      end
    end

    property "two documents agree about a path only when their shapes agree" do
      check all(tree <- document(), index <- integer(0..30), max_runs: 60) do
        node = pick(tree, index)
        address = Tree.content_address(tree, node.id)

        # Formatting is not shape.
        {:ok, heex} = Serializer.to_heex(tree)
        assert Tree.same_shape_at?(tree, Tree.parse!(heex), address)

        # Removing something is.
        case Tree.delete(tree, node.id) do
          {:ok, shorter} -> refute Tree.same_shape_at?(tree, shorter, address)
          {:error, _refused} -> :ok
        end
      end
    end
  end

  # `duplicate/2` answers with the new id alongside the document; the rest answer with the document.
  defp ok_or({:ok, next}, _fallback), do: next
  defp ok_or({:ok, next, _focus}, _fallback), do: next
  defp ok_or({:error, _reason}, fallback), do: fallback
end
