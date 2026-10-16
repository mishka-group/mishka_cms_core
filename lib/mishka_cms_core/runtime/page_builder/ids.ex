# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Ids do
  @moduledoc """
  One DOM id per element, and the references inside a snippet follow when one has to change.

  ## Why a second copy is not the same document twice

  Everything the palette offers is a worked EXAMPLE, and an example names things: the kit's delete
  dialog ships `id="modal-delete-page"` with `id="btn-delete-cancel"` beside it, and its newsletter
  dialog ships an `<input id="modal-newsletter-email">` with a `<label for="modal-newsletter-email">`
  pointing at it. Those names are most of what makes an example readable. Placing one twice — which
  is the ordinary way to build a second dialog — put two elements in the document answering to one
  id, and a duplicate id is not a cosmetic fault:

    * `JS.exec("data-pb-open", to: "#modal-delete-page")` reaches whichever came first, so the
      author's second button opens the first dialog
    * `document.getElementById` and every `phx-target` behave the same way
    * LiveView refuses to patch a container it cannot tell apart and raises

  ## The arrival yields

  `arrived` is the node ids the op just created, and they are the ones renamed — the same rule, and
  for the same reason, that `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming.dedupe/2` follows.
  Renaming in document order would rewrite the dialog already on the page whenever the new one was
  dropped above it, and that dialog is the one whose id an author has already written a handler,
  a link or an interaction against.

  Numbering fills gaps rather than counting: `modal-delete-page` beside `modal-delete-page-3` mints
  `modal-delete-page-2`, so deleting the second of three copies does not push the next to `-4`.

  ## References move with the name

  Renaming the copy's dialog and leaving the copy's button pointing at the original would be worse
  than the collision — the author would have two buttons that both open the first dialog and no
  visible reason why. So every reference to the old id is rewritten, in three shapes, and only
  WITHIN the nodes that arrived:

    * a selector anywhere in a value, string or expression — `to: "#modal-delete-page"`, `href`,
      `data-cancel`
    * a quoted literal inside an expression — `show_modal("modal-delete-page")`
    * a bare id in an attribute that takes one — `for`, `aria-controls`, `headers` and friends,
      including the space-separated lists three of them accept

  Nodes that were already on the page are never touched: they point at the original id, the original
  still has it, and they are right.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  # Attributes whose value is a bare id rather than a selector. `for`, `form`, `list` and
  # `popovertarget` name exactly one; `headers` and the three `aria-*` relations take a
  # space-separated list, which is why the match is per token rather than on the whole value.
  @bare ~w(for form list popovertarget headers aria-controls aria-labelledby aria-describedby
           aria-owns aria-activedescendant aria-flowto aria-details aria-errormessage)

  @doc """
  Renames every arrived element that claimed an id something else already answers to, rewriting the
  arrivals' own references to it in the same pass.

  With nothing arrived there is nothing to rename: a document that came in whole — a hand edit in
  the code drawer, a draft restore — is the author's own text, and silently renumbering ids they
  typed is a rewrite they did not ask for. The collision is theirs to see and theirs to fix.
  """
  @spec dedupe(Tree.t(), Enumerable.t()) :: Tree.t()
  def dedupe(tree, arrived) do
    arrived = MapSet.new(arrived)

    case MapSet.size(arrived) do
      0 -> tree
      _some -> settle(tree, arrived)
    end
  end

  defp settle(tree, arrived) do
    tree
    |> written()
    |> yielding(arrived)
    |> Enum.reduce({tree, MapSet.new()}, &claim(&1, &2, arrived))
    |> elem(0)
  end

  # Every literal id in the tree, in document order. An EXPRESSION is not a name this can compare —
  # `id={@row.id}` is bound to the author's data and two of them are not a collision — so it is left
  # out of both the taken set and the rename candidates.
  defp written(tree) do
    for node <- Tree.walk(tree),
        {:string, value} <- [Node.attr(node, "id")],
        trimmed = String.trim(value),
        trimmed != "",
        do: {node.id, trimmed}
  end

  defp yielding(pairs, arrived) do
    {arrivals, incumbents} =
      Enum.split_with(pairs, fn {node_id, _id} -> MapSet.member?(arrived, node_id) end)

    incumbents ++ arrivals
  end

  defp claim({node_id, id}, {tree, taken}, arrived) do
    case MapSet.member?(taken, id) do
      false -> {tree, MapSet.put(taken, id)}
      true -> rename(tree, node_id, id, free(id, taken), arrived, taken)
    end
  end

  defp rename(tree, node_id, old, new, arrived, taken) do
    tree
    |> write(node_id, "id", new)
    |> repoint(old, new, arrived)
    |> then(&{&1, MapSet.put(taken, new)})
  end

  defp repoint(tree, old, new, arrived) do
    Enum.reduce(arrived, tree, fn node_id, acc -> repoint_node(acc, node_id, old, new) end)
  end

  defp repoint_node(tree, node_id, old, new) do
    case Tree.get(tree, node_id) do
      nil -> tree
      node -> Enum.reduce(node.attrs, tree, &rewrite(&2, node_id, &1, old, new))
    end
  end

  # The node's OWN `id` is already written; rewriting it again here would turn `modal-x-2` back into
  # whatever a reference rule made of it.
  defp rewrite(tree, _node_id, {"id", _value}, _old, _new), do: tree

  defp rewrite(tree, node_id, {name, {kind, value}}, old, new)
       when kind in [:string, :expr] and is_binary(name) and is_binary(value) do
    case repointed(name, value, old, new) do
      ^value -> tree
      changed -> write(tree, node_id, name, changed, kind)
    end
  end

  defp rewrite(tree, _node_id, _attr, _old, _new), do: tree

  defp repointed(name, value, old, new) do
    value
    |> selectors(old, new)
    |> quoted(old, new)
    |> bare(name, old, new)
  end

  # `#old` wherever it appears, as long as what follows is not more of an id — otherwise renaming
  # `modal-x` would corrupt a sibling reference to `#modal-x-title`, which every Chelekom dialog has.
  defp selectors(value, old, new),
    do: Regex.replace(~r/##{Regex.escape(old)}(?![\w-])/, value, "#" <> new)

  # `show_modal("modal-x")` — a whole quoted literal, so a longer id that merely starts with this one
  # is left alone.
  defp quoted(value, old, new),
    do: String.replace(value, ~s("#{old}"), ~s("#{new}"))

  defp bare(value, name, old, new) do
    case name in @bare do
      false -> value
      true -> value |> String.split(" ") |> Enum.map_join(" ", &swap(&1, old, new))
    end
  end

  defp swap(token, old, new), do: (token == old && new) || token

  defp write(tree, node_id, name, value, kind \\ :string) do
    tree
    |> Tree.set_attr(node_id, name, {kind, value})
    |> applied(tree)
  end

  defp applied({:ok, tree}, _previous), do: tree
  defp applied({:error, _missing}, previous), do: previous

  defp free(base, taken), do: Enum.find(candidates(base), &(!MapSet.member?(taken, &1)))

  # The family is the base with any number stripped off it, so a second copy of `modal-x-2` looks for
  # `modal-x-3` rather than `modal-x-2-2`. Unbounded, because a bounded stream has to answer `nil` at
  # the end and a nil id is an element nothing can reach.
  defp candidates(base), do: Stream.concat([base], family(strip(base)))

  defp family(base), do: Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base}-#{&1}")

  defp strip(id), do: Regex.replace(~r/-\d+$/, id, "")
end
