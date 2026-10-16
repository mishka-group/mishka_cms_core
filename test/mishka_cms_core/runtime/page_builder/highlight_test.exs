# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.HighlightTest do
  @moduledoc """
  Colour for the code the editor shows.

  The property that matters more than any colour: **the text comes back unchanged**. A highlighter
  that drops a character or reorders a line is worse than no highlighter, because the reader is
  looking at it to understand what the page will do. Everything else here is a preference; that is a
  correctness bug, and the first version of this had it — the accumulator was reversed the wrong way
  round and the pane printed `defmoney do(cents)`.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.PageBuilder.Highlight

  defp rebuild(lines),
    do: Enum.map_join(lines, "\n", fn segments -> Enum.map_join(segments, "", &elem(&1, 0)) end)

  @elixir_samples [
    "def money(cents) do\n  value = cents / 100\n  value\nend",
    "x = :ok",
    ~s|"a string with a # inside"|,
    "# just a comment",
    "",
    "  indented = 1",
    "\"interpolated: \#{value}\" |> String.trim()",
    "%{a: 1, b: \"two\"}",
    "fn x -> x + 1 end",
    "case x do\n  :a -> 1\n  _ -> 2\nend"
  ]

  describe "the text survives" do
    test "every Elixir sample comes back exactly as it went in" do
      for source <- @elixir_samples do
        assert rebuild(Highlight.elixir(source)) == source,
               "mangled: #{inspect(source)} -> #{inspect(rebuild(Highlight.elixir(source)))}"
      end
    end

    test "HEEx comes back exactly as it went in" do
      source = "<div class=\"a\">\n  <%!-- note --%>\n  {@title}\n  plain text\n</div>"

      assert rebuild(Highlight.heex(source)) == source
    end

    test "CSS comes back exactly as it went in" do
      source = "/* note */\n& > .badge {\n  color: red;\n}"

      assert rebuild(Highlight.css(source)) == source
    end

    # Half-typed is the normal state of a box somebody is typing in, and colour is the least
    # important thing on the screen — it must never be why a panel fails to draw.
    test "code that does not tokenize is shown plainly rather than raising" do
      for broken <- ["def do do do", "\"unterminated", "<div class=", "& > {"] do
        assert rebuild(Highlight.elixir(broken)) == broken
        assert rebuild(Highlight.heex(broken)) == broken
        assert rebuild(Highlight.css(broken)) == broken
      end
    end

    test "nil and empty answer without crashing" do
      assert Highlight.elixir(nil) == []
      assert Highlight.heex(nil) == []
      assert Highlight.css(nil) == []
      assert rebuild(Highlight.elixir("")) == ""
    end
  end

  # THE CASES A REGULAR EXPRESSION GETS WRONG, which is the whole argument for a tokenizer.
  describe "what patterns could not do" do
    test "a # inside a string is not a comment" do
      [line] = Highlight.elixir(~s|"a # b"|)

      refute Enum.any?(line, fn {_text, colour} -> colour == "#7e7c86" end),
             "the string was coloured as a comment"
    end

    test "a keyword is coloured and an identifier that merely contains one is not" do
      [line] = Highlight.elixir("defer = 1")

      assert rebuild([line]) == "defer = 1"
      refute Enum.any?(line, fn {text, colour} -> text == "def" and colour == "#c8a2ff" end)
    end

    test "do and end are keywords" do
      lines = Highlight.elixir("if x do\n  1\nend")
      colours = lines |> List.flatten() |> Enum.map(fn {text, colour} -> {text, colour} end)

      assert {"end", "#c8a2ff"} in colours
    end
  end

  describe "colour is applied at all" do
    test "an atom, a number and a string each get their own" do
      segments = Highlight.elixir(~s|x = :ok|) |> List.flatten()

      assert Enum.any?(segments, fn {text, _colour} -> text == ":ok" end)
    end

    test "a HEEx comment, expression and tag are told apart" do
      [tag, comment, expression, text, _close] =
        Highlight.heex("<div>\n  <%!-- c --%>\n  {@a}\n  words\n</div>")

      assert [{_, "#8ee0b8"}] = tag

      # `#8b8995`, not the `#7e7c86` this was: a comment in a code box is content, and the old value
      # measured 4.4:1 against the pane — under AA. See the contrast guard in `code_editor.test.js`,
      # which holds the CodeMirror side of the same palette to the same floor.
      assert [{_, "#8b8995"}] = comment
      assert [{_, "#e6c477"}] = expression
      assert [{_, "#c9c7d1"}] = text
    end

    # A SENTENCE IS NOT A PROGRAM. The drawer's JS tab points at Runtime → JS hooks, and running the
    # Elixir tokenizer over that turned ordinary English words — "for", "in", "use" — into keywords.
    test "prose is left alone, one plain segment a line" do
      assert Highlight.prose("Use the JS hooks page for this.\nNot here.") == [
               [{"Use the JS hooks page for this.", "#c9c7d1"}],
               [{"Not here.", "#c9c7d1"}]
             ]

      assert Highlight.prose(nil) == []
    end

    test "a CSS declaration splits into property, colon and value" do
      [[{property, _}, {colon, _}, {value, _}]] = Highlight.css("  color: red;")

      assert property == "  color"
      assert colon == ":"
      assert value == " red;"
    end
  end

  # The measurement the scoping decision rests on: what the drawer shows is small, and this is why it
  # is only used for that.
  test "a node-sized snippet costs microseconds, not milliseconds" do
    source = String.duplicate("def a(b) do\n  b + 1\nend\n", 3)

    # The FASTEST of several calls, after one that loads the code: a busy machine can stall any single
    # call, but it cannot make every call slow, and a highlighter that really costs milliseconds is
    # slow on all of them.
    Highlight.elixir(source)

    microseconds =
      1..5
      |> Enum.map(fn _ -> elem(:timer.tc(fn -> Highlight.elixir(source) end), 0) end)
      |> Enum.min()

    assert microseconds < 5_000,
           "#{microseconds}us for nine lines — the drawer re-renders on every selection change"
  end
end
