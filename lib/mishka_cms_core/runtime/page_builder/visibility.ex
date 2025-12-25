defmodule MishkaCmsCore.Runtime.PageBuilder.Visibility do
  @moduledoc """
  An element kept in the page but shown to nobody: hidden from visitors, the way a line of code is
  commented out.

  ## The marker is markup

  A hidden element carries the bare attribute `data-pb-hidden`. Node ids are minted per parse and
  never written to the template (see `MishkaCmsCore.Runtime.PageBuilder.Tree`), so the state has to
  live in the markup itself; there it survives every save, duplicate, copy, paste, draft, snapshot
  and revert with nothing to anchor. Presence is what counts, as with every switch the Inspector
  reads; a value someone types is ignored.

  ## Kept in the source, gone from the output

  Every compiler — page, layout, component, error page — and
  `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.render_template/2` compile `strip/1` of the
  template rather than the template: each hidden element and everything inside it is removed, so a
  visitor's HTML carries no trace of it. A template that holds no marker is compiled exactly as
  stored, without being parsed. The checks that run when a template is saved compile it as stored,
  so a hidden element must still be valid markup and showing it again cannot break the page.

  ## Not the eye

  The layers rail's eye folds an element away on the canvas for the editing session only; it is
  view state and is never saved. Hiding from visitors is document state: it is saved, published, and
  shown on every surface of the editor.

  ## Nested

  An element inside a hidden one is hidden with it, and is shown by showing its container. One hidden
  on its own before its container was stays hidden when the container is shown again.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.{Node, Serializer}

  @attribute "data-pb-hidden"

  @doc "The attribute a hidden element carries: `\"data-pb-hidden\"`."
  @spec attribute() :: String.t()
  def attribute, do: @attribute

  @doc "Whether `node` is hidden from visitors itself, whatever its ancestors are."
  @spec hidden?(Node.t() | nil) :: boolean()
  def hidden?(%Node{} = node), do: Node.attr(node, @attribute) != nil
  def hidden?(_none), do: false

  @doc """
  Whether `node` can be hidden: an element, a component or a slot — what carries attributes — but
  never a document's root, a layout's `<body>`. A run of text or an expression is hidden by hiding
  the element around it.
  """
  @spec hideable?(Node.t() | nil) :: boolean()
  def hideable?(%Node{kind: kind} = node),
    do: kind in [:tag, :component, :slot] and not Node.document?(node)

  def hideable?(_none), do: false

  @doc """
  What hides the node `id` from visitors: the node itself when it is hidden, else its nearest hidden
  ancestor; `nil` when it is on the page.
  """
  @spec hidden_by(Tree.t(), String.t() | nil) :: Node.t() | nil
  def hidden_by(tree, id) do
    case Tree.get(tree, id) do
      nil -> nil
      node -> Enum.find([node | Tree.ancestors(tree, id)], &hidden?/1)
    end
  end

  @doc "The hidden nodes no hidden ancestor already covers, in document order."
  @spec hidden_roots(Tree.t()) :: [Node.t()]
  def hidden_roots(%Tree{roots: roots} = tree), do: Enum.flat_map(roots, &roots_under(tree, &1))

  defp roots_under(tree, id) do
    case Tree.get(tree, id) do
      nil ->
        []

      node ->
        if hidden?(node), do: [node], else: Enum.flat_map(node.children, &roots_under(tree, &1))
    end
  end

  @doc "`tree` without its hidden elements and everything inside them."
  @spec prune(Tree.t()) :: Tree.t()
  def prune(tree) do
    Enum.reduce(hidden_roots(tree), tree, fn node, acc ->
      {:ok, pruned} = Tree.delete(acc, node.id)
      pruned
    end)
  end

  @doc """
  The template a compiler compiles: `template` without its hidden elements. One that holds no
  marker is returned as it is, unparsed. One that cannot be parsed is returned as it is, logged:
  a compile never fails because of this step.
  """
  @spec strip(term()) :: term()
  def strip(template) when is_binary(template) do
    case String.contains?(template, @attribute) do
      true -> pruned(template)
      false -> template
    end
  end

  def strip(other), do: other

  defp pruned(template) do
    case Tree.parse(template) do
      {:ok, tree} ->
        tree |> prune() |> Serializer.serialize()

      {:error, reason} ->
        Logger.warning(
          "Hidden elements were kept in a template that does not parse: #{inspect(reason)}"
        )

        template
    end
  end

  @doc """
  The edit that hides the node `id` from visitors, or shows it again: one bare attribute set or
  removed, the shape every Inspector switch writes, so it takes the editor's one funnel — undo, the
  history, the lock, the plugin hooks. Refused for a node that cannot be hidden, and for one hidden
  only because its container is, which is shown by showing the container.
  """
  @spec toggle_op(Tree.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def toggle_op(tree, id) do
    node = Tree.get(tree, id)

    cond do
      not hideable?(node) ->
        {:error, gettext("Only an element can be hidden. Hide the element around it.")}

      hidden?(node) ->
        {:ok, %{kind: :delete_attr, node_id: id, name: @attribute}}

      hidden_by(tree, id) != nil ->
        {:error, gettext("It is hidden with the element around it. Show that one.")}

      true ->
        {:ok, %{kind: :set_attr, node_id: id, name: @attribute, value: "", value_kind: :boolean}}
    end
  end
end
