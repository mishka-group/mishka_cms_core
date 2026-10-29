# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Tree.Serializer do
  @moduledoc """
  Turns a `MishkaCmsCore.Runtime.Authoring.Tree` back into a HEEx template — the other half of the
  round trip `MishkaCmsCore.Runtime.Authoring.Tree.parse/1` opens.

  This is what the editor saves. The React editor's serializer only understood palette-dragged
  elements, so saving a *loaded* page rewrote every original node as `<div class="element-...">`;
  that whole failure mode is gone because there is only one node shape to emit.

  ## Two steps, deliberately separate

  `serialize/1` is total: it walks the tree and emits source, never raising and never consulting a
  parser. `format/1` then runs `Phoenix.LiveView.HTMLFormatter` over that source and returns
  `{:ok, binary} | {:error, reason}`.

  Keeping them apart is what lets the save path be safe without a `rescue` around the whole thing:
  serialize, re-parse to prove the output is readable, and only then format. A template that fails
  either check is refused with a message instead of being written over a working page.

  ADR-11: formatting on save is an explicit, documented normalization. A hand-written template will
  come back formatted the first time it is saved through the editor, and the round-trip tests assert
  that the second save is a fixed point.

  ## Attribute fidelity

  `name="literal"`, `name={expression}`, a bare `disabled`, and a root `{@rest}` are four different
  things and all four survive. The old JSON encoding collapsed the middle two into the string
  `"{expr}"` and recovered them with a `binary_part` guess, which is why `viewBox` and friends kept
  getting mangled.
  """

  alias MishkaCmsCore.Runtime.Authoring.Binding
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node
  alias MishkaCmsCore.Runtime.Authoring.Tree.Styles

  @doc """
  Emits the tree as HEEx source, unformatted. Total — an unreachable node or an unknown kind is
  skipped rather than raising.
  """
  @spec serialize(Tree.t()) :: String.t()
  def serialize(%Tree{} = tree) do
    tree.roots
    |> Enum.map(&node_source(tree, &1))
    |> IO.iodata_to_binary()
  end

  @doc "Emits one node and its descendants as HEEx source — what the code drawer shows for a selection."
  @spec serialize_node(Tree.t(), String.t()) :: String.t()
  def serialize_node(%Tree{} = tree, id), do: IO.iodata_to_binary(node_source(tree, id))

  @doc """
  Formats generated HEEx with the LiveView formatter.

  Returns `{:error, reason}` when the formatter cannot read the source. That only happens if we
  emitted something invalid, so the save path treats it as a refusal rather than writing the
  template anyway.
  """
  @spec format(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def format(source) when is_binary(source) do
    {:ok, Phoenix.LiveView.HTMLFormatter.format(source, heex_line_length: 100)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  The full save-time pipeline: serialize, prove the output re-parses, then format.

  Returns `{:error, reason}` if the emitted source cannot be read back, which is the guarantee that
  a save never replaces a working template with one the compiler would reject.
  """
  @spec to_heex(Tree.t()) :: {:ok, String.t()} | {:error, term()}
  def to_heex(%Tree{} = tree) do
    source = serialize(tree)

    with {:ok, _reparsed} <- Tree.parse(source) do
      format(source)
    end
  end

  defp node_source(tree, id) do
    case Tree.get(tree, id) do
      nil -> []
      node -> wrap_binding(node, emit(tree, node))
    end
  end

  # A node bound to a collection (the Data tab) is emitted inside a generated `:for`. The binding is
  # structured state, so the loop is written from it rather than being hand-authored source the
  # editor would then have to guess at on the way back in.
  defp wrap_binding(node, source) do
    case Binding.open(node) do
      nil -> source
      opening -> [opening, source, Binding.close(node)]
    end
  end

  defp emit(_tree, %Node{kind: :text, text: text}), do: text || ""

  defp emit(_tree, %Node{kind: :eex, text: expr, meta: %{form: :body}}), do: ["{", expr, "}"]

  defp emit(_tree, %Node{kind: :eex, text: expr, meta: %{opt: []}}), do: ["<% ", expr, " %>"]

  defp emit(_tree, %Node{kind: :eex, text: expr}), do: ["<%= ", expr, " %>"]

  defp emit(_tree, %Node{kind: :eex_comment, text: text}), do: ["<%!--", text || "", "--%>"]

  defp emit(_tree, %Node{kind: :html_comment, text: text}), do: ["<!--", text || "", "-->"]

  defp emit(_tree, %Node{kind: :eex_block, meta: %{source: source}}), do: source

  defp emit(_tree, %Node{kind: :eex_block, text: expr}), do: ["<%= ", expr || "", " %>"]

  defp emit(_tree, %Node{tag: tag, meta: %{self_close: true}} = node),
    do: ["<", tag, attrs_source(styled_attrs(node)), " />"]

  defp emit(tree, %Node{tag: tag, children: children} = node) do
    [
      "<",
      tag,
      attrs_source(node |> styled_attrs() |> nonced(tag)),
      ">",
      Enum.map(children, &node_source(tree, &1)),
      "</",
      tag,
      ">"
    ]
  end

  # A `<style>` IS REFUSED WITHOUT THE RESPONSE'S NONCE. `style-src-elem` names it, so a block the
  # author wrote would do nothing on the published page and say nothing about it. It is given
  # `csp_nonce()`, which every runtime template imports, unless it already carries a nonce. A
  # `<script>` is left as written: a nonce would also admit a `src` from anywhere, and behaviour
  # belongs in a JS hook, which the inspector says.
  defp nonced(attrs, "style") do
    case List.keymember?(attrs, "nonce", 0) do
      true -> attrs
      false -> attrs ++ [{"nonce", {:expr, "csp_nonce()"}}]
    end
  end

  defp nonced(attrs, _tag), do: attrs

  # Recorded overrides are compiled into the `class` attribute on the way out (ADR-8), after the
  # author's own classes and in a stable order, so the next parse lifts exactly the same map back.
  #
  # A SLOT NEEDS THE BANG AS MUCH AS THE COMPONENT AROUND IT, and it is the saved document that a
  # page is compiled from. The canvas draws a slot's override with `!` and `Tree.extract_styles/2`
  # reads one back with `!`; writing it without meant the padding an author set on a `<:item>` was
  # on the canvas and gone from the published page, losing 0-1-0 to the kit's own rule the same way
  # a component's would.
  defp styled_attrs(%Node{attrs: attrs, meta: meta} = node) do
    overrides = Map.get(meta, :styles, %{})
    opts = [important?: node.kind in [:component, :slot]]

    case List.keyfind(attrs, "class", 0) do
      {"class", {:expr, source}} -> computed_class(attrs, source, overrides, opts)
      _literal -> literal_class(attrs, overrides, opts)
    end
  end

  defp literal_class(attrs, overrides, opts) do
    case Styles.merge_class(authored_class(attrs), overrides, opts) do
      nil -> List.keydelete(attrs, "class", 0)
      class -> upsert_class(attrs, class)
    end
  end

  # `class={@variant}` IS the class, and it is not ours to read. Compiling overrides into a string
  # here would replace a value the component works out at render time with the literal text
  # `@variant` — and with no overrides to add, the old code dropped the attribute outright, so a
  # component with a computed class came back from its first save with no class at all.
  #
  # The utilities join it as a LIST instead. HEEx flattens a list `class`, filtering nils, so this
  # holds whatever the expression evaluates to, string or list.
  defp computed_class(attrs, source, overrides, opts) do
    case Styles.merge_class(nil, overrides, opts) do
      nil -> attrs
      utilities -> joined_class(attrs, source, utilities)
    end
  end

  # SPLICED INTO THE LIST, NOT WRAPPED AROUND IT. Wrapping produced a fresh nesting level on every
  # save — `[[["p-2", …], "w-[1000px]"], "w-[900px]"]` — which kept the stale utility beside the new
  # one at equal specificity, so the old value could win. A list is extended; anything else is still
  # wrapped, because `class={@variant}` is not ours to take apart.
  #
  # AND THE WRAP IS READ BACK BEFORE IT IS WRITTEN. Building it by hand wrote
  # `[if @x, do: "a", else: "b", "p-[8px]"]` for an expression ending in a bare keyword list — a
  # syntax error, so one slider move made the page refuse to save. `Styles.add_expr_classes/2` is
  # the one splice this and `Tree.ensure_scope/2` share, and an expression it cannot write keeps the
  # class it has rather than gaining one that will not compile.
  defp joined_class(attrs, source, utilities) do
    case joined_list(source, utilities) do
      nil -> attrs
      joined -> List.keyreplace(attrs, "class", 0, {"class", {:expr, joined}})
    end
  end

  defp joined_list(source, utilities) do
    case Styles.split_list_expr(source) do
      :not_a_list -> Styles.add_expr_classes(source, String.split(utilities))
      {parts, _styles} -> Styles.list_expr(parts ++ [{:classes, String.split(utilities)}])
    end
  end

  defp authored_class(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", {:string, class}} -> class
      _other -> nil
    end
  end

  defp upsert_class(attrs, class) do
    case List.keyfind(attrs, "class", 0) do
      nil -> attrs ++ [{"class", {:string, class}}]
      _existing -> List.keyreplace(attrs, "class", 0, {"class", {:string, class}})
    end
  end

  defp attrs_source([]), do: ""
  defp attrs_source(attrs), do: [" ", Enum.map_join(attrs, " ", &attr_source/1)]

  defp attr_source({:root, {:expr, value}}), do: ["{", value, "}"]
  defp attr_source({name, {:string, value}}), do: [name, ~s(="), Node.escape_attr(value), ~s(")]
  defp attr_source({name, {:expr, value}}), do: [name, "={", value, "}"]
  defp attr_source({name, :boolean}), do: name
end
