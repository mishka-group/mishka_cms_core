# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.PlainTextTest do
  @moduledoc """
  `MishkaCmsCore.PlainText`: a plain-text field keeps what was typed, without its markup and with
  nothing escaped, and keeping it twice changes nothing.
  """
  use ExUnit.Case, async: true

  import ExUnitProperties

  alias MishkaCmsCore.PlainText

  doctest PlainText

  describe "text/1" do
    test "keeps the text, quotes, apostrophes and ampersands as typed, without the tags" do
      assert PlainText.text(~s(Tom & Jerry's <b>"cat"</b>)) == ~s(Tom & Jerry's "cat")
      assert PlainText.text("MCP & AI-Ready") == "MCP & AI-Ready"
    end

    test "keeps a < or a > that opens no tag" do
      assert PlainText.text("x < 3 && y > 2") == "x < 3 && y > 2"
      assert PlainText.text("I <3 Elixir") == "I <3 Elixir"
    end

    test "keeps an entity as the characters typed" do
      assert PlainText.text("1 &lt; 2 &amp; 3") == "1 &lt; 2 &amp; 3"
      assert PlainText.text("&lt;b&gt;x") == "&lt;b&gt;x"
      assert PlainText.text("&#99999999;") == "&#99999999;"
    end

    test "keeps a script's text and drops the script" do
      assert PlainText.text("<script>alert(1)</script>Hi") == "alert(1)Hi"
      assert PlainText.text("<SCRIPT>a & b</SCRIPT>c") == "a &amp; bc"
      assert PlainText.text("Forms: <textarea> & <input>") == "Forms:  &amp; "
    end

    test "takes out a tag hidden inside a tag" do
      assert PlainText.text("<<b>b>") == ""
      assert PlainText.text("<scr<script>ipt>alert(1)</script>") == "ipt>alert(1)"
    end

    test "takes out comments and a doctype, and keeps line breaks" do
      assert PlainText.text("<!-- note -->hey") == "hey"
      assert PlainText.text("<!DOCTYPE html>t") == "t"
      assert PlainText.text("<p>One</p>\n<p>Two</p>") == "One\nTwo"
    end

    test "returns anything but a string as it is" do
      assert PlainText.text(nil) == nil
      assert PlainText.text(42) == 42
    end

    property "is stable: a second pass changes nothing" do
      check all(value <- markup(), max_runs: 500) do
        once = PlainText.text(value)
        assert PlainText.text(once) == once
      end
    end

    property "leaves no element an HTML parser would read" do
      check all(value <- markup(), max_runs: 500) do
        assert value
               |> PlainText.text()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("*")
               |> Enum.empty?()
      end
    end

    property "changes nothing in a text without a <" do
      check all(
              value <- StreamData.string(:utf8, max_length: 80),
              not String.contains?(value, "<")
            ) do
        assert PlainText.text(value) == value
      end
    end
  end

  describe "field/2" do
    test "hands GuardedStruct the field's text" do
      assert PlainText.field(:title, "<i>Tom</i> & Jerry") == {:ok, :title, "Tom & Jerry"}
      assert PlainText.field(:title, nil) == {:ok, :title, nil}
    end
  end

  describe "from_html/1" do
    test "is the text the HTML shows, its entities read" do
      assert PlainText.from_html("<p>Tom &amp; Jerry &lt;3 it</p>") == "Tom & Jerry <3 it"
      assert PlainText.from_html(nil) == nil
    end
  end

  # Text built from the pieces markup is made of, so the generator reaches the parser's edges —
  # unclosed tags, entities, comments, processing instructions — far more often than random text.
  defp markup do
    [
      "<",
      ">",
      "&",
      "amp;",
      "lt;",
      "gt;",
      "#39;",
      "#x3c;",
      "/",
      "!--",
      "-->",
      " ",
      "\n",
      "\t",
      "\"",
      "'",
      "a",
      "é",
      "?",
      "=",
      "<b>",
      "</b>",
      "<script>",
      "</script>",
      "<textarea>",
      "</textarea>",
      "<style>",
      "&amp;",
      "<!--",
      "<?",
      "]]>",
      "<![CDATA[",
      "<!DOCTYPE html>",
      "<img src=x onerror=alert(1)>",
      "<p class='a>b'>",
      "&#99999999;"
    ]
    |> StreamData.member_of()
    |> StreamData.list_of(max_length: 30)
    |> StreamData.map(&Enum.join/1)
  end
end
