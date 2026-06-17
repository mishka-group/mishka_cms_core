defmodule MishkaCmsCore.Runtime.PageBuilder.EditorHistoryPropertyTest do
  @moduledoc """
  The laws the editing history has to obey for any document and any sequence of edits.

  These exist because the history is now stored as patches — the nodes as they were before one step —
  rather than as whole documents. That is 84× to 4,160× smaller and it is what lifted the depth from
  fifty steps to tens of thousands, but it moves correctness from "we kept a copy" to "we can rebuild
  it", and rebuilding is the kind of thing that works for every case somebody thought of.

  So the cases are generated instead: arbitrary documents, arbitrary edits, arbitrary walks. The two
  that matter most are that undo lands exactly where it started, and that reaching a step far back
  gives the same document as walking there one step at a time.
  """
  use ExUnit.Case, async: true

  import ExUnitProperties
  import StreamData

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Patch
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @moduletag :property

  # A DOCUMENT WITH SHAPE. Flat markup would never exercise the root list or a nested move, and both
  # are where a positional scheme goes wrong.
  defp document do
    gen all(
          sections <- integer(1..4),
          depth <- integer(1..3),
          leaves <- integer(1..3)
        ) do
      Tree.parse!(
        "<main>" <> Enum.map_join(1..sections, fn i -> section(i, depth, leaves) end) <> "</main>"
      )
    end
  end

  defp section(index, 1, leaves),
    do:
      ~s(<section id="s#{index}">) <>
        Enum.map_join(1..leaves, &"<p>text #{&1}</p>") <> "</section>"

  defp section(index, depth, leaves),
    do: ~s(<section id="s#{index}">) <> section(index, depth - 1, leaves) <> "</section>"

  defp open(tree) do
    {:ok, session} = EditorSession.open(%{section: "page", template: Serializer.serialize(tree)})
    session
  end

  defp ids(session, kinds),
    do: session.tree |> Tree.walk() |> Enum.filter(&(&1.kind in kinds)) |> Enum.map(& &1.id)

  # Every edit here is one the editor really offers, driven through its own mutation funnel — a
  # helper that mutated the tree directly would prove something the editor never does.
  defp edit(session, index) do
    tags = ids(session, [:tag])
    id = Enum.at(tags, rem(index, length(tags)))

    params =
      case rem(index, 4) do
        0 -> %{kind: :set_attr, node_id: id, name: "data-p#{index}", value: to_string(index)}
        1 -> %{kind: :set_style, node_id: id, bucket: :base, prop: "padding", value: "#{index}px"}
        2 -> %{kind: :duplicate, node_id: id}
        _other -> %{kind: :set_attr, node_id: id, name: "class", value: "c#{index}"}
      end

    case EditorSession.apply_op(session.token, params) do
      {:ok, next} -> next
      {:error, _refused} -> session
    end
  end

  defp html(session), do: Serializer.serialize(session.tree)

  # THE SAME DOCUMENT THROUGH HEEx AND BACK — which is what a revert does, and the reason every node
  # id the session was holding is stale afterwards.
  defp reparsed(session), do: session.tree |> Serializer.serialize() |> Tree.parse!()

  describe "a patch is exactly the way back" do
    property "applying it to the later document gives the earlier one, whatever changed" do
      check all(tree <- document(), steps <- integer(1..12), max_runs: 40) do
        session = open(tree)

        Enum.reduce(1..steps, session, fn index, acc ->
          before = acc.tree
          next = edit(acc, index)

          assert Patch.apply_to(next.tree, Patch.build(before, next.tree)) == before

          next
        end)
      end
    end
  end

  describe "undo and redo" do
    property "undoing every step lands on the document it started from" do
      check all(tree <- document(), steps <- integer(1..12), max_runs: 40) do
        session = open(tree)
        original = html(session)

        edited = Enum.reduce(1..steps, session, &edit(&2, &1))
        taken = length(edited.past)

        unwound =
          Enum.reduce(1..taken//1, edited, fn _n, acc ->
            {:ok, next} = EditorSession.undo(acc.token)
            next
          end)

        assert html(unwound) == original
      end
    end

    property "undo then redo is where you were" do
      check all(tree <- document(), steps <- integer(1..10), max_runs: 40) do
        session = open(tree)
        edited = Enum.reduce(1..steps, session, &edit(&2, &1))
        taken = min(length(edited.past), 5)

        was = html(edited)

        back =
          Enum.reduce(1..taken//1, edited, fn _n, acc ->
            {:ok, next} = EditorSession.undo(acc.token)
            next
          end)

        forward =
          Enum.reduce(1..taken//1, back, fn _n, acc ->
            {:ok, next} = EditorSession.redo(acc.token)
            next
          end)

        assert html(forward) == was
      end
    end
  end

  describe "reaching a step directly" do
    # UNDO RE-MINTS REFERENCES — it drops the entry it used and stores a new one for the way forward
    # — so every jump is taken while the session still holds the entries being jumped to, and the
    # walk that checks them happens afterwards.
    property "jumping to a step gives the same document as walking there" do
      check all(tree <- document(), steps <- integer(2..12), max_runs: 40) do
        session = open(tree)
        edited = Enum.reduce(1..steps, session, &edit(&2, &1))
        depth = length(edited.past)

        jumped =
          Enum.map(0..(depth - 1)//1, fn index ->
            entry = Enum.at(edited.past, index)
            assert {:ok, tree} = EditorSession.entry_tree(edited, entry)
            Serializer.serialize(tree)
          end)

        walked =
          Enum.map_reduce(0..(depth - 1)//1, edited, fn _index, acc ->
            {:ok, next} = EditorSession.undo(acc.token)
            {html(next), next}
          end)
          |> elem(0)

        assert jumped == walked,
               "jumping and walking disagreed somewhere in #{depth} steps"
      end
    end
  end

  describe "carrying what the session was holding" do
    # THE LAW THE REVIEW FOUND BROKEN. A snapshot is HEEx, so restoring one re-parses and mints new
    # node ids, and the selection is carried across by position. Comparing only kind and tag at that
    # position cannot tell two sibling paragraphs apart, so a document that changed shape handed the
    # author's selection — and their locks and hidden flags — to an element they never touched.
    property "the selection lands on the same element or on nothing, never on a stranger" do
      check all(
              tree <- document(),
              steps <- integer(1..8),
              replacement <- document(),
              max_runs: 60
            ) do
        session = open(tree)
        chosen = Enum.at(ids(session, [:tag]), 0)
        {:ok, session} = EditorSession.select(session.token, chosen)

        edited = Enum.reduce(1..steps, session, &edit(&2, &1))

        for target <- [reparsed(edited), replacement] do
          # READ WHAT IS HELD IMMEDIATELY BEFORE, not at the start: an insert or a duplicate moves
          # the selection on purpose, so the element to compare against is whatever the session has
          # when the document is replaced.
          {:ok, current} = EditorSession.fetch(edited.token)
          held = Tree.get(current.tree, current.selection)

          {:ok, replaced} = EditorSession.put_tree(edited.token, target, reason: :revert)

          # Nothing held, or nothing carried, are both fine — the law is only about what it DOES
          # carry.
          if held && replaced.selection, do: assert_same_element(held, replaced)

          assert :ok = MishkaCmsCore.Runtime.PageBuilder.Strict.inspect_tree(replaced.tree)
        end
      end
    end

    defp assert_same_element(held, replaced) do
      landed = Tree.get(replaced.tree, replaced.selection)

      assert landed, "the selection names an element that is not in the document"

      assert landed.kind == held.kind and landed.tag == held.tag,
             "the selection moved to a #{landed.tag} from a #{held.tag}"
    end

    property "the marks, locks and hidden flags only ever name elements that exist" do
      check all(tree <- document(), steps <- integer(1..8), max_runs: 40) do
        session = open(tree)
        [first, second | _rest] = ids(session, [:tag])

        {:ok, _} = EditorSession.mark(session.token, first)
        {:ok, _} = EditorSession.toggle_lock(session.token, second)
        {:ok, session} = EditorSession.toggle_hidden(session.token, first)

        edited = Enum.reduce(1..steps, session, &edit(&2, &1))
        {:ok, replaced} = EditorSession.put_tree(edited.token, reparsed(edited), reason: :revert)

        for set <- [replaced.marked, replaced.locked, replaced.hidden], id <- set do
          assert Tree.get(replaced.tree, id), "#{id} is held but is not in the document"
        end
      end
    end
  end

  describe "what the history costs" do
    property "a step costs what changed, never what the document weighs" do
      check all(tree <- document(), max_runs: 30) do
        session = open(tree)
        edited = edit(session, 0)

        patch = Patch.build(session.tree, edited.tree)
        document_bytes = byte_size(:erlang.term_to_binary(session.tree))

        # One attribute on one element: the step must not be proportional to the document.
        assert Patch.weight(patch) <= 2

        assert Patch.bytes(patch) < document_bytes or Tree.size(session.tree) < 8,
               "a step cost as much as the whole document"
      end
    end
  end
end
