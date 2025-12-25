defmodule MishkaCmsCore.Runtime.PageBuilder.LayoutSlot do
  @moduledoc """
  Whether a layout still renders the page it wraps.

  A layout is not a page with a header on it: its whole job is to put something *around*
  `@inner_content`, the assign `MishkaCmsCore.Runtime.Compilers.LayoutCompiler` hands its `render/2`.
  Take that expression out and the layout compiles, saves and previews perfectly — and every page
  using it serves the layout's own chrome with the page's content missing. Nothing said so: the
  editor let the chip be deleted like any other node, the audit reported no blockers, and publishing
  went through.

  So the question gets one answer, asked by the audit rail and again by the publish gate, and it is
  asked of the *tree* rather than of the text: `@inner_content` written inside a comment or a string
  is not a rendering of it, and `{@inner_content}`, `<%= @inner_content %>` and
  `<%= render_slot(@inner_content) %>` are all the same thing to the compiler.

  See `MishkaCmsCore.Runtime.PageBuilder.PageStarter`, whose blank layout ships with the slot already
  in it for the same reason.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.LiveView.HtmlTokenizer
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility

  @assign :inner_content

  @doc "The assign a layout renders the page through."
  @spec assign() :: atom()
  def assign, do: @assign

  @doc """
  Whether `tree` renders `@inner_content` for a visitor: somewhere outside every element hidden from
  visitors (`MishkaCmsCore.Runtime.PageBuilder.Visibility`), which the layout compiler leaves out.

  Total: an expression Elixir cannot read answers `false` rather than raising, because a template
  the compiler will reject is not one that renders the page either.
  """
  @spec renders_inner_content?(Tree.t()) :: boolean()
  def renders_inner_content?(%Tree{} = tree),
    do: tree |> Visibility.prune() |> holds_inner_content?()

  @doc """
  Whether anything in `tree` evaluates `@inner_content`, hidden from visitors or not. With
  `renders_inner_content?/1` false, true means the slot is inside a hidden element.
  """
  @spec holds_inner_content?(Tree.t()) :: boolean()
  def holds_inner_content?(%Tree{} = tree), do: tree |> Tree.walk() |> Enum.any?(&node_renders?/1)

  defp node_renders?(%Node{kind: :eex, text: text}), do: references?(text)

  # ADR-9 keeps a block atomic, so its body is source rather than child nodes — the one place the
  # tree cannot be walked. The same tokenizer that built the tree reads it back, which is what keeps
  # `<%= if @wrapped do %>{@inner_content}<% end %>` from reading as a layout that renders nothing.
  defp node_renders?(%Node{kind: :eex_block, meta: %{source: source}}),
    do: source_renders?(source)

  defp node_renders?(%Node{attrs: attrs}), do: Enum.any?(attrs, &attr_renders?/1)

  defp attr_renders?({_name, {:expr, source}}), do: references?(source)
  defp attr_renders?(_attr), do: false

  defp source_renders?(source) when is_binary(source) do
    case HtmlTokenizer.build_tokenize(source) do
      {:ok, tokens} -> tokens |> Enum.flat_map(&expressions/1) |> Enum.any?(&references?/1)
      _unreadable -> false
    end
  rescue
    _error -> false
  end

  defp source_renders?(_source), do: false

  defp expressions({:tag_block, _tag, attrs, children, _meta}),
    do: attr_expressions(attrs) ++ Enum.flat_map(children, &expressions/1)

  defp expressions({:tag_self_close, _tag, attrs}), do: attr_expressions(attrs)
  defp expressions({:body_expr, expr, _meta}), do: [expr]
  defp expressions({:eex, expr, _meta}), do: [expr]

  defp expressions({:eex_block, expr, block, _meta}) do
    [
      expr
      | Enum.flat_map(block, fn {children, _clause} -> Enum.flat_map(children, &expressions/1) end)
    ]
  end

  defp expressions(_token), do: []

  defp attr_expressions(attrs) do
    for {_name, {:expr, source, _meta}, _ameta} <- attrs, do: source
  end

  defp references?(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> assign_in?(ast)
      _unreadable -> false
    end
  end

  defp references?(_source), do: false

  defp assign_in?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _meta, [{@assign, _ameta, context}]} = node, _found when is_atom(context) ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found?
  end
end
