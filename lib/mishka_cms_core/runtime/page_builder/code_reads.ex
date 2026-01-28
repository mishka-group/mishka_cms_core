defmodule MishkaCmsCore.Runtime.PageBuilder.CodeReads do
  @moduledoc """
  What a snippet reads and what it calls, read off the parsed code.

  The sibling of `MishkaCmsCore.Runtime.PageBuilder.CodeFlags`, which answers a different question
  the same way: parse it, walk it, and let the shape of the tree say what a thing is. An assign is
  the node `{:@, meta, [{name, meta, context}]}` — so `@flash` inside a string, inside a comment, or
  written out in a code sample is not one, and neither is `@moduledoc "…"`, whose context is the
  text rather than an atom.

      iex> alias MishkaCmsCore.Runtime.PageBuilder.CodeReads
      iex> CodeReads.assigns(~S|[@size, "@colour is not one"]|) |> MapSet.to_list()
      ["size"]

  For a template rather than a snippet, `MishkaCmsCore.Runtime.PageBuilder.Markup.expressions/1`
  gives the expressions to hand here.

  ## What it does with code it cannot parse

  Nothing found. An author is mid-sentence in a box they are typing into, and `CodeCheck` is what
  tells them the code will not compile — a half-typed line is not this module's news to break.
  """

  @doc """
  Every assign a snippet reads, by name and without the `@`.

      iex> MishkaCmsCore.Runtime.PageBuilder.CodeReads.assigns("@a <> @b") |> MapSet.to_list()
      ["a", "b"]
  """
  @spec assigns(String.t() | nil) :: MapSet.t(String.t())
  def assigns(code), do: code |> walked(&assign/1) |> MapSet.new()

  @doc """
  Every call a snippet makes by a bare name, as `{name, arguments}` with the arguments still quoted.

  Bare-name and nothing else: `String.trim(x)` is a call on a module and is not one of these, which
  is what makes this the right question to ask about a component's own helpers.
  """
  @spec calls(String.t() | nil) :: [{atom(), [Macro.t()]}]
  def calls(code), do: walked(code, &call/1)

  defp assign({:@, _meta, [{name, _name_meta, context}]})
       when is_atom(name) and is_atom(context),
       do: [Atom.to_string(name)]

  defp assign(_node), do: []

  # A CALL AND A VARIABLE ARE THE SAME SHAPE BUT FOR THE LAST ELEMENT: `foo()` quotes with an empty
  # argument list and `foo` with `nil`, so a list is what tells them apart. Operators quote this way
  # too and are left in — every caller matches on a name it already knows.
  defp call({name, _meta, args}) when is_atom(name) and is_list(args), do: [{name, args}]

  defp call(_node), do: []

  defp walked(code, fun) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> collected(ast, fun)
      {:error, _half_typed} -> []
    end
  end

  defp walked(_code, _fun), do: []

  defp collected(ast, fun) do
    {_ast, found} = Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ fun.(node)} end)

    found
  end
end
