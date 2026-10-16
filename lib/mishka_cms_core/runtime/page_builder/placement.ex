# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Placement do
  @moduledoc """
  Where a thing lands — the answer shared by a click, a drag, and a template that arrives on its own.

  This sits beside `MishkaCmsCore.Runtime.PageBuilder.Containment`, which answers a different
  question: containment says whether a child MAY go in a parent, and placement decides which parent
  and which index a gesture actually meant. Every route into the document goes through one function
  here, which is what stops three doors disagreeing about the same drop.

  ## The two rules

  A **leaf** — a kit component, a heading, an image — goes inside the element that was clicked when
  it will take one, and immediately after it when it will not. The fallback is the point rather than
  a consolation: clicking a `<.component>` with no slot, an `<img>` or an `<input>` is not a mistake,
  it is someone pointing at the place they want the new thing to appear. Webflow, Elementor and
  Bricks all land there too.

  A **band** — a `<section>`, a `<main>`, anything dropped from the Blocks library — is a horizontal
  slice of the page and belongs beside the other slices. A click pointing into one climbs out of the
  whole branch. Without that, a call-to-action clicked while the page header was selected became a
  third item in the header's flex row and rendered at a quarter width. Bricks documents Section as
  root-level; Elementor's containers refuse `section` outright.

  ## What counts as a place to put a band

  `@band_hosts` is the two obvious tags plus the two cases that matter on a real page: anything that
  already holds a band, and anything still empty. A page wrapped in `<div id="app">` keeps its bands
  in that div, and a rule that knew only the tag names would lift every new section out of the
  wrapper. An empty box is a hole to put things in — the one container that cannot squeeze a band
  into a narrow third column, because there is nothing beside it. The canvas already draws exactly
  these hollow.

  ## Hints are not decisions

  `hints/3` answers every node at once so the canvas can paint the whole tree at `dragstart`, and it
  asks `Containment` directly. It deliberately does NOT go through `EditorSession`'s own gate, which
  fires the `builder:containment` plugin event — that runs on the drop, once, where a plugin author's
  code belongs; running it here would put it on the drag's critical path several hundred times.

  A hint can also go stale: a collaborator can move the tree under a drag in flight. The drop decides.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Containment
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @bands ~w(section main)
  @band_hosts ~w(body main)

  # A WRAPPER IS NOT A PLACE. "Placed in div" names the markup rather than anywhere an author can
  # picture, and the div a page keeps its bands in IS the top level as far as they are concerned.
  @landmarks ~w(main body header footer section article aside nav)

  @doc """
  Which nodes will accept `dragged`, keyed by node id — every node in the tree, so the canvas can
  colour all of them from one answer.

  `opts` takes `:components` (the palette, for resolving a component's own containment),
  `:dragged_tree` (the tree `dragged` belongs to, so a Block's own form is visible to the
  form-nesting rule) and `:locked` (a `MapSet` of ids the author has pinned). A locked node refuses
  even when the rules would allow it, and dragging something locked refuses everywhere at once:
  nowhere will take it, and saying so up front is what stops the canvas painting a line it would
  then have to withdraw.
  """
  @spec hints(Tree.t(), term(), keyword()) :: %{String.t() => boolean()}
  def hints(%Tree{} = tree, dragged, opts \\ []) do
    locked = Keyword.get(opts, :locked, MapSet.new())

    case Keyword.get(opts, :dragged_id) do
      id when is_binary(id) ->
        case MapSet.member?(locked, id) do
          true -> Map.new(tree.nodes, fn {node_id, _node} -> {node_id, false} end)
          false -> allowed(tree, dragged, opts, locked)
        end

      _none ->
        allowed(tree, dragged, opts, locked)
    end
  end

  defp allowed(tree, dragged, opts, locked) do
    tree
    |> Containment.accepts_map(dragged, Keyword.take(opts, [:components, :dragged_tree]))
    |> Map.new(fn {id, allowed?} -> {id, allowed? and !MapSet.member?(locked, id)} end)
  end

  @doc """
  The `{parent_id, index}` a click on `node_id` means for `head`, the first root of the template
  being placed.

  `nil` for `node_id` — or an id that is no longer in the tree — means the end of the document, which
  is what a click on empty canvas is. `opts` takes `:components`, `:dragged_tree` (the template's own
  tree, so a Block's own form is visible to the form-nesting rule) and `:band?`, the last for a
  Block, which is a band whatever its markup happens to open with.
  """
  @spec target(Tree.t(), Node.t() | nil, String.t() | nil, keyword()) ::
          {String.t() | :root, non_neg_integer()}
  def target(tree, head, node_id, opts \\ [])

  def target(%Tree{} = tree, _head, nil, _opts), do: {:root, length(tree.roots)}

  def target(%Tree{} = tree, head, node_id, opts) do
    case Tree.get(tree, node_id) do
      nil -> {:root, length(tree.roots)}
      node -> target_for(tree, head, node, opts)
    end
  end

  defp target_for(tree, head, node, opts) do
    case band?(head, Keyword.get(opts, :band?, false)) do
      true -> band_target(tree, head, node, opts)
      false -> inside_or_after(tree, head, node, opts)
    end
  end

  defp inside_or_after(tree, head, %Node{id: id, children: children} = node, opts) do
    case accepts?(tree, head, id, opts) do
      true -> {id, length(children)}
      false -> tree |> welcoming(head, node, opts) |> then(&after_node(tree, &1))
    end
  end

  # The clicked node, or its first ancestor whose parent takes `head`: a form clicked while a field
  # inside another form is selected lands after that form, not inside it.
  defp welcoming(tree, head, node, opts) do
    Enum.find(
      [node | Tree.ancestors(tree, node.id)],
      node,
      &parent_accepts?(tree, head, &1, opts)
    )
  end

  defp parent_accepts?(tree, head, %Node{parent_id: nil}, opts),
    do: accepts?(tree, head, :root, opts)

  defp parent_accepts?(tree, head, %Node{parent_id: parent}, opts),
    do: accepts?(tree, head, parent, opts)

  defp band_target(tree, head, node, opts) do
    case band_host?(tree, node) and accepts?(tree, head, node.id, opts) do
      true -> {node.id, length(node.children)}
      false -> after_branch(tree, node)
    end
  end

  defp after_branch(tree, node) do
    case Tree.get(tree, node.parent_id) do
      nil -> after_node(tree, node)
      parent -> climb(tree, parent, node)
    end
  end

  defp climb(tree, parent, child) do
    case band_host?(tree, parent) do
      true -> after_node(tree, child)
      false -> after_branch(tree, parent)
    end
  end

  defp band?(_head, true), do: true

  defp band?(%Node{kind: :tag, tag: tag}, _block?) when is_binary(tag),
    do: String.downcase(tag) in @bands

  defp band?(_head, _block?), do: false

  defp band_host?(tree, %Node{kind: :tag, tag: tag} = node) when is_binary(tag) do
    String.downcase(tag) in @band_hosts or holds_band?(tree, node) or Tree.blank?(tree, node.id)
  end

  defp band_host?(_tree, _node), do: false

  defp holds_band?(tree, node) do
    tree
    |> Tree.children(node.id)
    |> Enum.any?(&band?(&1, false))
  end

  defp accepts?(_tree, nil, _target_id, _opts), do: false

  defp accepts?(tree, head, target_id, opts) do
    Containment.can_drop?(
      tree,
      head,
      target_id,
      Keyword.take(opts, [:components, :dragged_tree])
    ) == :ok
  end

  @doc """
  The template's own tree.

  A caller that only needs the head can hand this straight to `head/1`, and one asking `target/4`
  where a Block may land needs the whole thing: a block opens with a band tag by design, so its
  `<.form>` is a CHILD of the head and the form-nesting rule cannot see it from the head alone.

  `nil` when the template will not parse.
  """
  @spec subtree(String.t()) :: Tree.t() | nil
  def subtree(template) do
    case Tree.parse(template) do
      {:ok, tree} -> tree
      {:error, _unparseable} -> nil
    end
  end

  @doc """
  The first root of `template`, which is what the containment rules get asked about and what decides
  whether this is a band.

  `nil` when the template will not parse — the insert is about to fail on the same parse, so the
  failure stays in one place rather than being guessed at twice.
  """
  @spec head(String.t() | Tree.t() | nil) :: Node.t() | nil
  def head(%Tree{roots: [root | _rest]} = tree), do: Tree.get(tree, root)
  def head(%Tree{}), do: nil
  def head(template) when is_binary(template), do: template |> subtree() |> head()
  def head(nil), do: nil

  @doc """
  The `{parent_id, index}` immediately after `node` among its own siblings.
  """
  @spec after_node(Tree.t(), Node.t()) :: {String.t() | :root, non_neg_integer()}
  def after_node(%Tree{} = tree, %Node{} = node),
    do: {node.parent_id || :root, (Tree.index_of(tree, node.id) || 0) + 1}

  @doc """
  The index immediately after `target` among its siblings, or `nil` when it has no place there.

  Separate from `after_node/2` because the caller that retries a refused drop needs the index on its
  own, to merge into a payload that already names the parent.
  """
  @spec index_after(Tree.t(), Node.t()) :: non_neg_integer() | nil
  def index_after(%Tree{} = tree, %Node{} = target) do
    tree
    |> Tree.child_ids(target.parent_id || :root)
    |> Enum.find_index(&(&1 == target.id))
    |> then(&(&1 && &1 + 1))
  end

  @doc """
  A sentence for a landing place the selection ring does not explain on its own, or `nil` when it
  needs no words.

  Landing beside the element that was clicked is visible: the insert makes the new node the selection
  and the canvas scrolls to it. Landing somewhere else entirely, because the click was on a box buried
  inside a band, is not — so that one says where it went, in the words the drag path already uses.
  """
  @spec note(Tree.t(), String.t() | nil, String.t() | :root) :: String.t() | nil
  def note(%Tree{} = tree, node_id, parent_id) do
    case relocated?(tree, node_id, parent_id) do
      true -> sectioned(tree, parent_id)
      false -> nil
    end
  end

  @doc """
  The sentence for where a click placed `head`, or `nil` when the landing explains itself: a band's
  `note/3`, or for a leaf that landed further out than beside the clicked node, why the clicked
  node's parent refused it.

  `opts` are `target/4`'s.
  """
  @spec relocation(Tree.t(), Node.t() | nil, String.t() | nil, String.t() | :root, keyword()) ::
          String.t() | nil
  def relocation(tree, head, node_id, parent_id, opts \\ []) do
    case band?(head, Keyword.get(opts, :band?, false)) do
      true -> note(tree, node_id, parent_id)
      false -> climb_note(tree, head, node_id, opts)
    end
  end

  defp climb_note(tree, head, node_id, opts) do
    with %Node{} = clicked <- Tree.get(tree, node_id),
         false <- is_nil(head) or accepts?(tree, head, clicked.id, opts),
         %Node{} = climbed when climbed.id != clicked.id <- welcoming(tree, head, clicked, opts),
         {:error, reason} <- refusal(tree, head, clicked.parent_id || :root, opts) do
      gettext("%{reason} Placed after %{target} instead.",
        reason: reason,
        target: spoken(climbed, opts)
      )
    else
      _explained -> nil
    end
  end

  @doc """
  A node in a sentence about where something was placed: a working form by its people name, a form
  that does not work yet as "the form", anything else as `:other` (default "the element around
  it"). `:components` is the palette.
  """
  @spec spoken(Node.t(), keyword()) :: String.t()
  def spoken(node, opts) do
    form? = Fields.form_node?(node, Fields.roles([node], Keyword.get(opts, :components, [])))

    case {FormPlacement.form_name(node), form?} do
      {nil, true} -> FormPlacement.phrase(nil)
      {nil, false} -> opts |> Keyword.get(:other) |> other_phrase()
      {name, _form?} -> FormPlacement.phrase(name)
    end
  end

  defp refusal(tree, head, target_id, opts),
    do:
      Containment.can_drop?(
        tree,
        head,
        target_id,
        Keyword.take(opts, [:components, :dragged_tree])
      )

  defp relocated?(tree, node_id, parent_id) do
    case Tree.get(tree, node_id) do
      nil -> false
      clicked -> parent_id != node_id and parent_id != (clicked.parent_id || :root)
    end
  end

  defp other_phrase(text) when is_binary(text) and text != "",
    do: Gettext.gettext(MishkaCmsCore.Gettext, text)

  defp other_phrase(_none), do: gettext("the element around it")

  defp sectioned(_tree, :root),
    do: gettext("Sections sit beside each other. Placed at the top level.")

  defp sectioned(tree, parent_id) do
    case Tree.get(tree, parent_id) do
      %Node{kind: :tag, tag: tag} when is_binary(tag) -> named_spot(String.downcase(tag))
      _other -> gettext("Sections sit beside each other. Placed at the top level.")
    end
  end

  defp named_spot(tag) when tag in @landmarks,
    do: gettext("Sections sit beside each other. Placed inside %{tag}.", tag: tag)

  defp named_spot(_tag), do: gettext("Sections sit beside each other. Placed at the top level.")
end
