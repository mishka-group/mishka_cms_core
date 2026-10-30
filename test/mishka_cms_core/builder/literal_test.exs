# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Builder.LiteralDocTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.Literal

  doctest MishkaCmsCore.Builder.Literal

  describe "expression?/1" do
    # What a binding is made of: an assign, a field or a key of something, or a call.
    test "a source that reads an assign, a variable or a call is an expression" do
      for source <- [
            "@icon",
            "f[:email].value",
            "item.title",
            "assigns[:contact_form]",
            "@count + 1",
            ~S|"Hello " <> @name|,
            ~S|t("Hello")|,
            "Phoenix.Naming.humanize(:a)",
            ~S|"Hi #{name}"|,
            ~S|~p"/about"|
          ] do
        assert Literal.expression?(source), "#{source} reads something and is an expression"
      end
    end

    # WHAT TYPED WORDS PARSE AS. `E2E-0` is the alias `E2E` minus zero: valid Elixir, nothing to
    # read, and an ArithmeticError the moment a page evaluates it. `my-page` is `my` minus `page` and
    # `hello world` the call `hello(world)`. None of these is an expression.
    test "a literal, arithmetic, a bare name, words and unparseable text are not" do
      for source <- [
            "E2E-0",
            "E2E",
            "1-2",
            "Foo/Bar",
            "42",
            ~S|"plain"|,
            ":danger",
            "[1, 2]",
            ~S|%{"a" => 1}|,
            "hello world!",
            "hello world",
            "my-page",
            "hello",
            "10%",
            ""
          ] do
        refute Literal.expression?(source), "#{inspect(source)} reads nothing"
      end
    end

    test "anything that is not a string is not source" do
      refute Literal.expression?(nil)
      refute Literal.expression?(42)
    end
  end
end
