# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.MarketplaceTest do
  @moduledoc """
  The Studio's data source and its four export generators.

  The generators are the part worth testing hard: the demo promised a Copy button that hands you a
  real `tailwind.config.js`, a real `:root` block, real W3C tokens JSON and a real Elixir module. If
  any of them emitted something that would not parse, the button would be a lie.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token

  # The SAMPLE adapter, named rather than reached through `Marketplace`, for two reasons: this file
  # asserts the prototype's exact seed data, and the configured default is now the on-disk kits —
  # which read the database and would make an `async: true`, DB-free file into neither.
  defp tokens, do: Mock.tokens(nil)

  describe "the mock adapter" do
    test "returns the prototype's full token set" do
      assert length(tokens()) == 32
    end

    test "every token is a validated struct" do
      for token <- tokens() do
        assert %Token{} = token
        assert is_binary(token.key) and token.key != ""
        assert is_binary(token.value) and token.value != ""
        assert is_integer(token.usage)
      end
    end

    test "categories come back in display order" do
      assert Marketplace.categories(tokens()) ==
               ~w(color type space radius shadow motion screen)
    end

    test "custom tokens are marked" do
      custom = tokens() |> Enum.filter(& &1.custom?) |> Enum.map(& &1.key)
      assert custom == ["brand-teal", "screen-xl"]
    end

    test "presets, packages and snippets are seeded" do
      assert length(Mock.presets(%{})) == 6
      assert length(Mock.packages(%{})) == 9
      assert length(Mock.snippets(%{})) == 3
    end

    test "one package is pre-installed, as the demo shows" do
      installed = Mock.packages(%{}) |> Enum.filter(& &1.installed?) |> Enum.map(& &1.id)
      assert installed == ["chelekom-datatable"]
    end

    test "filters narrow the registry" do
      data = Mock.packages(%{category: "data"})
      assert length(data) == 3
      assert Enum.all?(data, &(&1.category == "data"))
    end

    # A mock must not pretend to install. A caller wiring the button up has to be able to tell.
    test "install refuses honestly rather than faking success" do
      assert {:error, {:not_available, message}} = Mock.install(:preset, "editorial", nil, nil)
      assert message =~ "mock registry"
    end
  end

  describe "Token.matches?/2" do
    test "all, custom and a category name" do
      color = Enum.find(tokens(), &(&1.category == "color" and not &1.custom?))
      custom = Enum.find(tokens(), & &1.custom?)

      assert Token.matches?(color, "all")
      assert Token.matches?(color, "color")
      refute Token.matches?(color, "custom")
      refute Token.matches?(color, "space")
      assert Token.matches?(custom, "custom")
    end
  end

  describe "reference/2 — how a token is cited in each format" do
    setup do
      by_key = Map.new(tokens(), &{&1.key, &1})
      %{t: by_key}
    end

    test "tailwind maps each category to its theme group", %{t: t} do
      assert Marketplace.reference(:tw, t["iris"]) == "theme.colors.iris"
      assert Marketplace.reference(:tw, t["space-4"]) == "theme.spacing.4"
      assert Marketplace.reference(:tw, t["radius-md"]) == "theme.borderRadius.md"
      assert Marketplace.reference(:tw, t["screen-lg"]) == "theme.screens.lg"
      assert Marketplace.reference(:tw, t["shadow-md"]) == "theme.boxShadow.shadow-md"
    end

    test "type splits families from sizes, motion splits easings from durations", %{t: t} do
      assert Marketplace.reference(:tw, t["font-sans"]) == "theme.fontFamily.sans"
      assert Marketplace.reference(:tw, t["body"]) == "theme.fontSize.body"

      assert Marketplace.reference(:tw, t["ease-out"]) ==
               "theme.transitionTimingFunction.ease-out"

      assert Marketplace.reference(:tw, t["duration-fast"]) == "theme.transitionDuration.fast"
    end

    test "the other three formats", %{t: t} do
      assert Marketplace.reference(:css, t["radius-md"]) == "--radius-md"
      assert Marketplace.reference(:json, t["radius-md"]) == "{radius.md}"
      assert Marketplace.reference(:ex, t["radius-md"]) == "@radius_md"
    end
  end

  describe "generate/2 — the exports are real files" do
    test "the Tailwind config is valid JavaScript with balanced braces" do
      out = Marketplace.generate(:tw, tokens())

      assert out =~ "module.exports = {"
      assert out =~ "colors: {"
      assert out =~ "'iris': '#5b57d6',"
      # Spacing keys are stripped of their `space-` prefix, as the demo's generator does.
      assert out =~ "'4': '16px',"
      assert out =~ "'md': '13px',"
      assert count(out, "{") == count(out, "}")
    end

    test "the CSS export declares every token and closes :root" do
      out = Marketplace.generate(:css, tokens())

      assert out =~ ":root {"
      assert out =~ "  --iris: #5b57d6;"
      assert out =~ "  --shadow-lg: 0 18px 46px rgba(20,18,26,.22);"
      assert count(out, "--") >= 32
      assert out =~ "var(--radius-md)"
    end

    test "the tokens JSON is valid W3C-shaped JSON" do
      out = Marketplace.generate(:json, tokens())

      assert {:ok, decoded} = Jason.decode(out)
      assert Map.keys(decoded) |> Enum.sort() == ~w(color motion radius space)
      assert decoded["color"]["iris"] == %{"$value" => "#5b57d6", "$type" => "color"}
      assert decoded["radius"]["md"] == %{"$value" => "13px", "$type" => "dimension"}
    end

    test "the Elixir export is a module that actually compiles" do
      out = Marketplace.generate(:ex, tokens())

      assert out =~ "defmodule MishkaWeb.Theme do"
      assert out =~ ~s(@iris "#5b57d6")
      assert out =~ ~s(@radius_md "13px")
      assert {:ok, _ast} = Code.string_to_quoted(out)
    end

    test "every format produces something for an empty token list without crashing" do
      for {format, _label, _file, _hint} <- Marketplace.formats() do
        assert is_binary(Marketplace.generate(format, []))
      end
    end

    test "all four formats are offered" do
      assert Marketplace.formats() |> Enum.map(&elem(&1, 0)) == [:tw, :css, :json, :ex]
    end
  end

  defp count(string, needle), do: length(String.split(string, needle)) - 1
end
