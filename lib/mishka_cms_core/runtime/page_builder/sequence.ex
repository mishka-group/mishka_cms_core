# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Sequence do
  @moduledoc """
  A number that says which one of these this is, kept in step when another arrives.

  ## What it is for

  `chelekom-stepper-section` declares `step_number` with a default of 1, and the stepper's own
  furnishing writes 1, 2, 3. Drop a fourth section and it says 1; duplicate the second and there are
  two 2s. The author edits the title, sees it change, looks for the number and finds nothing to
  change it with — which is what it was reported as: "it doesnt matter how many of them we have they
  alwas will show the number 1".

  ## The rule, and why it is not a list of attribute names

  A positional number is recognisable from the document rather than from anything a kit declares:

    * at least TWO siblings sharing the arriving node's component name, in document order,
    * every one of them holding an INTEGER LITERAL in that attribute,
    * and those integers forming a consecutive ascending run.

  Three ones in a row are not a sequence and are left alone. `step_number={@index}` is the author
  binding it to their own data and is left alone. A component with no such siblings has no run to
  join. What is renumbered is the arriving node and everything after it, so inserting between two
  and three gives three, and the old three becomes four.

  TWO, because one number is not counting. Twenty-eight attributes across the shipped kit are whole
  numbers and most of them are measurements — an image's width, a tooltip's delay, a clipboard's
  timeout. One image beside another with `width={100}` would have made the second 101; two steps
  reading 1 and 2 are people counting, and that is the evidence this acts on.

  Only `integer` and `pos_integer`. A float is a measurement, and a string that happens to hold
  digits is a label.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @numeric ~w(integer pos_integer)

  @doc """
  The tree with the arriving node's positional numbers settled, or the tree unchanged.

  `components` is the palette, which is where the attribute's declared type is read from.
  """
  @spec settle(Tree.t(), String.t() | nil, [map()]) :: Tree.t()
  def settle(tree, node_id, components) when is_binary(node_id) do
    with %Node{kind: :component} = node <- Tree.get(tree, node_id),
         name when is_binary(name) <- Node.component_name(node),
         %{} = entry <- Enum.find(components || [], &(&1.name == name)) do
      entry
      |> positional_names()
      |> Enum.reduce(tree, &renumber(&2, node, &1))
    else
      _not_a_component -> tree
    end
  end

  def settle(tree, _node_id, _components), do: tree

  defp positional_names(entry) do
    for attr <- Inspector.attrs(entry),
        Inspector.type(attr) in @numeric,
        do: Inspector.name(attr)
  end

  defp renumber(tree, node, attr) do
    siblings = siblings(tree, node)

    with [_one, _two | _more] = others <- Enum.reject(siblings, &(&1.id == node.id)),
         {:ok, run} <- consecutive(others, attr),
         index when is_integer(index) <- Enum.find_index(siblings, &(&1.id == node.id)) do
      write(tree, siblings, attr, run, index)
    else
      _no_run -> tree
    end
  end

  defp siblings(tree, %Node{parent_id: parent_id} = node) do
    tree
    |> Tree.children(parent_id || :root)
    |> Enum.filter(&(&1.kind == :component))
    |> Enum.filter(&(Node.component_name(&1) == Node.component_name(node)))
  end

  # Every one an integer literal, and every step exactly one. `[2, 3]` is a run and so is `[1]`;
  # `[1, 1, 1]` is three components that were never numbered and `[10, 20]` is somebody counting in
  # tens, and neither is this module's business.
  defp consecutive(nodes, attr) do
    values = Enum.map(nodes, &number(&1, attr))

    with false <- Enum.any?(values, &is_nil/1),
         [first | _rest] <- values,
         true <- values == Enum.to_list(first..(first + length(values) - 1)//1) do
      {:ok, first}
    else
      _not_a_run -> :error
    end
  end

  defp number(node, attr) do
    case Node.attr(node, attr) do
      {:expr, source} -> integer(String.trim(source))
      {:string, value} -> integer(String.trim(value))
      _absent -> nil
    end
  end

  defp integer(text) do
    case Integer.parse(text) do
      {number, ""} -> number
      _other -> nil
    end
  end

  # WRITTEN THE WAY THE KIT WRITES IT. `step_number={4}` is an expression, which is how an integer
  # reaches a component that does arithmetic with it; a string would be the bug the number control
  # was fixed for.
  defp write(tree, siblings, attr, first, from) do
    siblings
    |> Enum.with_index()
    |> Enum.drop(from)
    |> Enum.reduce(tree, fn {sibling, index}, acc ->
      case Tree.set_attr(acc, sibling.id, attr, {:expr, to_string(first + index)}) do
        {:ok, updated} -> updated
        _refused -> acc
      end
    end)
  end
end
