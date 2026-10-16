# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Tree.Patch do
  @moduledoc """
  What you apply to one version of a document to get an earlier one back.

  ## Values, not operations

  A patch holds the nodes as they actually were — not an instruction for undoing what happened. That
  distinction is the whole reason this is safe:

    * nothing has to be invertible. "Delete this section", "replace the whole document", "paste forty
      elements" all reverse the same way, because reversing them is just putting the old nodes back.
    * no operation is ever re-run. Re-running is how a replay scheme mints fresh node ids and quietly
      detaches every id the session was holding.

  ## Why the editor stores these instead of documents

  An undo entry used to hold a whole tree. In memory that is nearly free — fifty versions of a
  document share almost every node — but ETS flattens what it stores, so fifty entries landed as
  fifty independent copies. Measured on a 5,001-node document: **1.2 MB per entry**, and the fifty
  the editor kept came to 57.5 MB for one person's session.

  The same edit as a patch is **290 bytes**, whatever the document's size, because a patch is
  proportional to what CHANGED rather than to what exists. Measured against whole trees: 84× smaller
  on a 101-node document, 1,041× on 1,251 nodes, 4,160× on 5,001. Building one is also cheaper than
  flattening a tree was — 3 ms against 5.7 ms on that largest document — because comparing two
  versions that share their nodes is pointer comparison, not a walk.

  That is what makes the depth of the history a question about memory rather than an arbitrary count.

  ## Reading one back

  A patch is relative: it reverses exactly one step, from the version that came after it. So getting
  to a version several steps away means applying each patch between here and there, which
  `MishkaCmsCore.Runtime.PageBuilder.EditorSession` does because it is the thing that knows the
  order. Measured at 79 µs to walk back a hundred of them.
  """
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @enforce_keys [:restore, :drop, :roots]
  defstruct restore: %{}, drop: [], roots: []

  @type t :: %__MODULE__{
          restore: %{String.t() => Node.t()},
          drop: [String.t()],
          roots: [String.t()]
        }

  @doc """
  The patch that turns `during` back into `before`.

  `restore` carries every node that differs, as it was; `drop` names the nodes that did not exist
  yet; `roots` is the root list, which a move or a delete at the top level changes on its own.

  Compared by identity first (`!==`), so two versions that share a node — which is nearly all of them
  — cost a pointer comparison rather than a structural one.
  """
  @spec build(Tree.t(), Tree.t()) :: t()
  def build(%Tree{} = before, %Tree{} = during) do
    %__MODULE__{
      restore:
        for(
          {id, node} <- before.nodes,
          Map.get(during.nodes, id) !== node,
          into: %{},
          do: {id, node}
        ),
      drop: for({id, _node} <- during.nodes, !is_map_key(before.nodes, id), do: id),
      roots: before.roots
    }
  end

  @doc "Applies a patch, giving back the document it was built from."
  @spec apply_to(Tree.t(), t()) :: Tree.t()
  def apply_to(%Tree{} = tree, %__MODULE__{restore: restore, drop: drop, roots: roots}) do
    %Tree{tree | nodes: tree.nodes |> Map.drop(drop) |> Map.merge(restore), roots: roots}
  end

  @doc "How many nodes this patch carries — what the history's memory budget is spent on."
  @spec weight(t()) :: non_neg_integer()
  def weight(%__MODULE__{restore: restore, drop: drop}), do: map_size(restore) + length(drop)

  @doc "Roughly what this patch costs to keep, in bytes."
  @spec bytes(t()) :: non_neg_integer()
  def bytes(%__MODULE__{} = patch), do: byte_size(:erlang.term_to_binary(patch))
end
