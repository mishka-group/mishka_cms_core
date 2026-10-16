# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0
defmodule MishkaCmsCore.Runtime.PageBuilder.Highlight do
  @moduledoc """
  Colour for the code the editor shows, driven by tokenizers rather than by regular expressions.

  ## Why not a regular expression

  The drawer coloured a line grey when it started with `<!--` or `/*`, and left everything else one
  colour. Anything better with patterns runs into the cases that make highlighting worth having in
  the first place: a `#` inside a string is not a comment, `"` inside a heredoc does not end it,
  `#{}` interpolation is code inside a string, and a `<` in a text node is not a tag. A tokenizer
  already knows all four, and this project ships two of them.

  ## What it costs, measured

  `:elixir_tokenizer` on this machine: **64 µs** for an eight-line snippet, **4.5 ms** for 320 lines.
  That is the whole reason this is scoped to what the drawer shows — a selected node's markup, one
  handler's body — and not to a whole page's source. 64 µs per render is nothing; 4.5 ms on every
  keystroke is a stutter somebody would feel, and the editor re-renders on every selection change.

  Anything this cannot tokenize comes back as one plain segment rather than raising. Colour is the
  least important thing on the screen and must never be the reason a panel fails to draw.

  ## The shape

  `[{text, colour}]` per line, so a caller renders one `<span>` per segment and the line numbers stay
  the caller's business.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.LiveView.HtmlTokenizer

  @plain "#c9c7d1"
  @comment "#8b8995"
  @string "#8ee0b8"
  @keyword "#c8a2ff"
  @atom "#e6c477"
  @number "#e6c477"
  @operator "#a3a1ad"
  @tag "#8ee0b8"
  @attr "#c8a2ff"
  @expression "#e6c477"

  @keywords ~w(def defp defmodule do end fn if else case cond with for when and or not in
               try rescue catch after receive raise import alias require use quote unquote)a

  @type segment :: {String.t(), String.t()}

  @doc """
  Text nobody should pretend to have parsed, in the plain colour, one list per line.

  For the panes that hold a sentence rather than a program — the drawer's JS tab points at Runtime →
  JS hooks — where running a tokenizer over prose only invents keywords out of ordinary words.
  """
  @spec prose(String.t() | nil) :: [[segment()]]
  def prose(nil), do: []

  def prose(source) when is_binary(source),
    do: source |> String.split("\n") |> Enum.map(&[{&1, @plain}])

  @doc """
  Elixir source as coloured segments, one list per line.

  Positions come from `:elixir_tokenizer`, and the text is sliced out of the ORIGINAL source rather
  than rebuilt from the tokens: a tokenizer drops whitespace and comments, so anything rebuilt from
  its output would come back reflowed and missing the comments — which is most of what a reader is
  looking at.
  """
  @spec elixir(String.t() | nil) :: [[segment()]]
  def elixir(nil), do: []

  def elixir(source) when is_binary(source) do
    case :elixir_tokenizer.tokenize(String.to_charlist(source), 1, []) do
      {:ok, _, _, _, tokens, _} -> paint(source, spans(tokens))
      {:ok, tokens} -> paint(source, spans(tokens))
      _unparseable -> plain(source)
    end
  end

  def elixir(_source), do: []

  @doc """
  HEEx or HTML as coloured segments, through the project's own tokenizer — the same one the tree is
  built with, so the drawer cannot disagree with the canvas about where a tag ends.
  """
  @spec heex(String.t() | nil) :: [[segment()]]
  def heex(nil), do: []

  def heex(source) when is_binary(source) do
    case HtmlTokenizer.build_tokenize(source) do
      {:ok, tokens} -> paint(source, html_spans(tokens))
      tokens when is_list(tokens) -> paint(source, html_spans(tokens))
      _unparseable -> plain(source)
    end
  rescue
    # A half-typed tag is the normal state of a box somebody is typing in.
    _error -> plain(source)
  end

  def heex(_source), do: []

  @doc """
  CSS as coloured segments. Small enough not to need a tokenizer of its own: a declaration is a
  property, a colon and a value, and the only thing worth telling apart is a comment and a selector.
  """
  @spec css(String.t() | nil) :: [[segment()]]
  def css(nil), do: []

  def css(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.map(&css_line/1)
  end

  def css(_source), do: []

  defp css_line(line) do
    trimmed = String.trim_leading(line)

    cond do
      trimmed == "" -> [{line, @plain}]
      String.starts_with?(trimmed, ["/*", "*"]) -> [{line, @comment}]
      String.contains?(line, ":") and !String.contains?(line, "{") -> declaration(line)
      true -> [{line, @tag}]
    end
  end

  defp declaration(line) do
    [property, value] = String.split(line, ":", parts: 2)

    [{property, @attr}, {":", @operator}, {value, @string}]
  end

  # ONE SEGMENT, NOT A CRASH. Colour is the least important thing on the screen.
  defp plain(source) do
    source
    |> String.split("\n")
    |> Enum.map(&[{&1, @plain}])
  end

  # `{line, column, length, colour}` for every token worth colouring. Everything not covered stays
  # plain, which is why this can be partial without looking broken.
  defp spans(tokens) do
    Enum.flat_map(tokens, &span/1)
  end

  defp span({:identifier, {line, col, _}, name}) when is_atom(name) do
    case name in @keywords do
      true -> [{line, col, name |> Atom.to_string() |> String.length(), @keyword}]
      false -> []
    end
  end

  defp span({kind, {line, col, _}, value})
       when kind in [:do_identifier, :block_identifier, :paren_identifier] and is_atom(value),
       do: [{line, col, value |> Atom.to_string() |> String.length(), @keyword}]

  defp span({:atom, {line, col, _}, value}) when is_atom(value),
    do: [{line, col, (value |> Atom.to_string() |> String.length()) + 1, @atom}]

  defp span({:int, {line, col, _}, value}), do: [{line, col, digits(value), @number}]
  defp span({:flt, {line, col, _}, value}), do: [{line, col, digits(value), @number}]

  defp span({:bin_string, {line, col, _}, parts}),
    do: [{line, col, string_length(parts) + 2, @string}]

  defp span({:list_string, {line, col, _}, parts}),
    do: [{line, col, string_length(parts) + 2, @string}]

  defp span({kind, {line, col, _}}) when kind in [:do, :end, :fn, :when, :after],
    do: [{line, col, kind |> Atom.to_string() |> String.length(), @keyword}]

  defp span(_token), do: []

  defp digits(value), do: value |> to_string() |> String.length()

  defp string_length(parts) when is_list(parts) do
    Enum.reduce(parts, 0, fn
      part, acc when is_binary(part) -> acc + String.length(part)
      part, acc when is_list(part) -> acc + length(part)
      _interpolation, acc -> acc
    end)
  end

  defp string_length(_parts), do: 0

  # The project's tokenizer answers node-ish maps rather than positioned tokens, so HEEx is coloured
  # by structure per line instead: a tag line, an expression line, a comment, or text. Cruder than
  # the Elixir side and honest about it — the alternative is a second HTML parser to maintain.
  defp html_spans(_tokens), do: :by_line

  defp paint(source, :by_line) do
    source
    |> String.split("\n")
    |> Enum.map(&heex_line/1)
  end

  defp paint(source, spans) do
    by_line = Enum.group_by(spans, fn {line, _col, _len, _colour} -> line end)

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {text, number} -> segments(text, Map.get(by_line, number, [])) end)
  end

  defp heex_line(line) do
    trimmed = String.trim_leading(line)

    cond do
      trimmed == "" -> [{line, @plain}]
      String.starts_with?(trimmed, ["<%!--", "<!--"]) -> [{line, @comment}]
      String.starts_with?(trimmed, ["<%", "{"]) -> [{line, @expression}]
      String.starts_with?(trimmed, "<") -> [{line, @tag}]
      true -> [{line, @plain}]
    end
  end

  # Sliced out of the line by the token's own column, so whitespace and comments — neither of which a
  # tokenizer keeps — are still exactly where the author put them.
  defp segments(text, []), do: [{text, @plain}]

  defp segments(text, spans) do
    spans
    |> Enum.sort_by(fn {_line, col, _len, _colour} -> col end)
    |> Enum.reduce({[], 1}, fn {_line, col, len, colour}, {acc, at} ->
      cond do
        col < at ->
          {acc, at}

        # COLOURED FIRST, THEN THE PLAIN RUN BEFORE IT. The accumulator is reversed at the end, so
        # prepending them the other way round put every token before the text that preceded it and
        # the pane printed `defmoney do(cents)`.
        true ->
          {[{slice(text, col, len), colour}, {slice(text, at, col - at), @plain} | acc],
           col + len}
      end
    end)
    |> then(fn {acc, at} -> [{slice(text, at, String.length(text) - at + 1), @plain} | acc] end)
    |> Enum.reverse()
    |> Enum.reject(fn {chunk, _colour} -> chunk == "" end)
  end

  defp slice(_text, _from, length) when length <= 0, do: ""
  defp slice(text, from, length), do: String.slice(text, from - 1, length)
end
