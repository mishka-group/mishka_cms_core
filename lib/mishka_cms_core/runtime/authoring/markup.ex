# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.Markup do
  @moduledoc """
  Every Elixir expression a HEEx template contains, found by tokenising it.

  ## Why it exists

  Because the questions worth asking about a template — does it read this assign, does it call that
  helper — are questions about its EXPRESSIONS, and a pattern over the source cannot tell an
  expression from the text around it. `@flash` in a comment, in a string, in a `<pre>` showing
  somebody a code sample: a pattern finds all three, and a tokeniser finds none of them.

  What comes back is source, one string per expression, for `Code.string_to_quoted/1` to turn into
  something walkable — see `MishkaCmsCore.Runtime.Authoring.CodeReads`.

      iex> MishkaCmsCore.Runtime.Authoring.Markup.expressions(~S|<div id={@id}>{@flash}</div>|)
      ["@id", "@flash"]

  ## Tokens, not the tree

  `EEx.tokenize/1` and Phoenix.LiveView.TagEngine.Tokenizer directly, rather than the tree
  `MishkaCmsCore.Runtime.Authoring.HtmlTokenizer` builds on top of them. Nesting is a
  question this module does not ask, and asking it fails on templates this one can answer for: a
  fragment like `<div class={paint(@tone)}>` has no closing tag, so the tree is an error — while the
  attribute was tokenised perfectly well on the way to finding that out.

  ## What it does with a template it cannot read

  Answers `[]`, which every caller has to read as "nothing found" rather than "nothing there".
  `component_arguments/1` is the exception: its caller decides what a component can reach from the
  answer, so an unreadable template there is `:dynamic` rather than an empty list.
  """

  alias Phoenix.LiveView.TagEngine.Tokenizer

  @eex_expression [:start_expr, :expr, :end_expr, :middle_expr]

  @doc """
  Every `~H` template written inside Elixir code — a helper's, a component's `body`, a prelude — as
  source, in the order they are written. Code that does not parse answers `[]`.

      iex> MishkaCmsCore.Runtime.Authoring.Markup.sigils(~S|def tip(assigns), do: ~H"<b>{@x}</b>"|)
      ["<b>{@x}</b>"]
  """
  @spec sigils(String.t() | nil) :: [String.t()]
  def sigils(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, quoted} ->
        quoted
        |> Macro.prewalk([], fn
          {:sigil_H, _meta, [{:<<>>, _parts, [template]}, _modifiers]} = node, found
          when is_binary(template) ->
            {node, [template | found]}

          node, found ->
            {node, found}
        end)
        |> elem(1)
        |> Enum.reverse()

      {:error, _unparseable} ->
        []
    end
  end

  def sigils(_code), do: []

  @doc "Every Elixir expression in a template: attribute values, interpolations and EEx tags."
  @spec expressions(String.t() | nil) :: [String.t()]
  def expressions(template) when is_binary(template) do
    case tokens(template) do
      {:ok, tokens} -> tokens |> Enum.flat_map(&found/1) |> Enum.uniq()
      :unreadable -> []
    end
  end

  def expressions(_template), do: []

  @doc """
  Every expression a template HANDS TO a `<.component …/>` tag — the values a runtime component can
  be given, as source.

  A literal attribute is not among them. `component_name="card"` is a string written in the
  template, so it can carry nothing the template does not already say itself.

  `:dynamic` when what a tag hands over cannot be read off the template at all: a tag that spreads a
  map built while the page renders, or a template that cannot be tokenised. A caller must read that
  as "anything could have been handed over", never as "nothing was" — which is the opposite of what
  `expressions/1` promises for the same unreadable template, and the reason the two answers have
  different shapes.

      iex> MishkaCmsCore.Runtime.Authoring.Markup.component_arguments(~S|<.component component_name="card" bag={assigns} />|)
      {:ok, ["assigns"]}

      iex> MishkaCmsCore.Runtime.Authoring.Markup.component_arguments(~S|<.component {@attrs} />|)
      :dynamic
  """
  @spec component_arguments(String.t() | nil) :: {:ok, [String.t()]} | :dynamic
  def component_arguments(template) when is_binary(template) do
    case tokens(template) do
      {:ok, tokens} -> handed(tokens)
      :unreadable -> :dynamic
    end
  end

  # No template hands over nothing, which is a decided answer rather than an unreadable one.
  def component_arguments(nil), do: {:ok, []}
  def component_arguments(_template), do: :dynamic

  defp handed(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, found} ->
      case arguments(token) do
        :dynamic -> {:halt, :dynamic}
        given -> {:cont, {:ok, found ++ given}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.uniq(found)}
      :dynamic -> :dynamic
    end
  end

  # NO `finalize/4`, which is the step that refuses an unclosed tag. Everything this module wants is
  # in the accumulator by then.
  defp tokens(template) do
    case EEx.tokenize(template) do
      {:ok, parts} ->
        {:ok,
         parts
         |> Enum.reduce({[], {:text, :enabled}}, &part(&1, &2, template))
         |> elem(0)
         |> Enum.reverse()}

      _unreadable ->
        :unreadable
    end
  rescue
    _unreadable -> :unreadable
  catch
    _kind, _reason -> :unreadable
  end

  defp part({:text, text, meta}, {tokens, cont}, template) do
    state = Tokenizer.init(0, "nofile", template, Phoenix.LiveView.HTMLEngine)

    Tokenizer.tokenize(
      List.to_string(text),
      [line: meta.line, column: meta.column],
      tokens,
      cont,
      state
    )
  end

  defp part({type, _opt, expression, _meta}, {tokens, cont}, _template)
       when type in @eex_expression,
       do: {[{:eex, type, expression |> List.to_string() |> String.trim()} | tokens], cont}

  defp part(_other, accumulator, _template), do: accumulator

  # EVERY KIND OF OPEN TAG AT ONCE — tag, slot, local component, remote component — because what they
  # have in common is the only thing being asked for. A closing tag is the same size of tuple with a
  # name where the attributes would be, so the guard is what tells them apart.
  defp found({_type, _name, attrs, _meta}) when is_list(attrs),
    do: Enum.flat_map(attrs, &of_attr/1)

  defp found({:body_expr, source, _meta}) when is_binary(source), do: [source]

  # A BLOCK OPENER IS HALF A FORM. `<%= if @flash != %{} do %>` tokenises as `if @flash != %{} do`,
  # which `Code.string_to_quoted/1` refuses, because the `end` is four tokens and a `<p>` away. It is
  # closed here rather than guessed at later: the token says it opened a block, so what is missing is
  # always exactly that word.
  defp found({:eex, :start_expr, source}) when is_binary(source), do: [source <> "\nend"]

  # `else`, and a `case` arm's pattern. Neither is a form on its own, and an assign named ONLY in an
  # arm's pattern is therefore not reported — a miss rather than a wrong answer.
  defp found({:eex, :middle_expr, _source}), do: []

  defp found({:eex, _type, source}) when is_binary(source), do: [source]

  defp found(_token), do: []

  # `{@rest}` arrives named `:root` and is an attribute like any other here.
  defp of_attr({_name, {:expr, source, _value_meta}, _attr_meta}) when is_binary(source),
    do: [source]

  defp of_attr(_attr), do: []

  # ONLY `<.component …/>`, the one local component a compiled runtime template can call — every
  # other tag of this shape is HTML, a slot or a remote component, and hands nothing to a runtime
  # component. A CLOSING `</.component>` carries its name where the attributes would be, which is
  # what the list guard tells apart.
  defp arguments({:local_component, "component", attrs, _meta}) when is_list(attrs) do
    # `<.component {@attrs} />` HANDS OVER WHATEVER THAT MAP TURNS OUT TO HOLD. It is built while the
    # page renders, so a tag carrying one is read as handing over anything at all — a tag read as
    # handing over nothing would be exactly the wrong answer.
    case Enum.any?(attrs, &spread?/1) do
      true -> :dynamic
      false -> Enum.flat_map(attrs, &of_attr/1)
    end
  end

  defp arguments(_token), do: []

  # A named attribute's name is a string; `{@rest}` arrives as `:root`.
  defp spread?({name, _value, _meta}) when not is_binary(name), do: true
  defp spread?(_attr), do: false
end
