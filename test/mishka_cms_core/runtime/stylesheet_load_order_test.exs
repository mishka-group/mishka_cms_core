# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.StylesheetLoadOrderTest do
  @moduledoc """
  Which stylesheet wins, and the two places that have to agree about it.

  `priority` documents itself as *lower loads first, so a higher value wins on equal specificity*,
  and the `:for_compiler` read already sorted that way. Then both consumers re-sorted the rows on
  `-priority`: `TailwindCompiler.format_stylesheets/1`, which decides what the browser sees, and
  `PageBuilder.Tokens.token_sheets/1`, which decides what Studio shows. Negating it emits the
  highest value FIRST, and CSS is last-wins — so the LOWEST priority sheet won.

  The two agreed with each other, which is exactly why it was invisible: Studio displayed the value
  the page really rendered. Both were the opposite of what an operator setting `priority: 90` asked
  for, and nothing said so.

  `Stylesheet.load_order/1` is now the single key both sort by, so they cannot drift apart again.

  `async: false` — global stylesheet rows are visible to every site.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  alias MishkaCmsCore.Runtime.Stylesheet

  defp sheet!(name, content, opts) do
    Stylesheet
    |> Ash.Changeset.for_create(
      :master_create,
      %{
        name: name,
        kind: Keyword.get(opts, :kind, :theme),
        content: content,
        site_id: nil,
        active: true,
        priority: Keyword.fetch!(opts, :priority)
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp ordered(sheets),
    do: sheets |> Enum.sort_by(&Stylesheet.load_order/1) |> Enum.map(& &1.name)

  describe "load_order/1" do
    # ASCENDING, because the LAST sheet emitted is the one the browser obeys.
    test "puts the higher priority last, so it wins" do
      sheets = [
        %{name: "high", kind: :theme, site_id: nil, priority: 90},
        %{name: "low", kind: :theme, site_id: nil, priority: 10}
      ]

      assert ordered(sheets) == ["low", "high"]
    end

    test "orders kinds the way the compiler emits them" do
      sheets =
        for {name, kind} <- [
              {"custom", :custom},
              {"theme", :theme},
              {"app_base", :app_base},
              {"base", :base}
            ],
            do: %{name: name, kind: kind, site_id: nil, priority: 0}

      assert ordered(sheets) == ["app_base", "theme", "base", "custom"]
    end

    # A site must be able to override what it inherited, whatever the priorities happen to be.
    test "a site's own sheet sorts after a global one of the same kind" do
      sheets = [
        %{name: "site", kind: :theme, site_id: "abc", priority: 0},
        %{name: "global", kind: :theme, site_id: nil, priority: 90}
      ]

      assert ordered(sheets) == ["global", "site"]
    end

    test "kind outranks priority" do
      sheets = [
        %{name: "late-kind", kind: :custom, site_id: nil, priority: 0},
        %{name: "early-kind", kind: :app_base, site_id: nil, priority: 100}
      ]

      assert ordered(sheets) == ["early-kind", "late-kind"]
    end
  end

  describe "Studio and the browser agree" do
    test "the token Studio reports is the one the higher-priority sheet declares" do
      run = System.unique_integer([:positive])
      key = "pri-#{run}"

      sheet!("pri-low-#{run}", ":root {\n  --#{key}: #111111;\n}\n", priority: 10)
      sheet!("pri-high-#{run}", ":root {\n  --#{key}: #de1135;\n}\n", priority: 90)

      token = Tokens.list(nil) |> Enum.find(&(&1.key == key))

      assert token, "both sheets were read, so the token must be listed"

      assert token.value == "#de1135",
             "priority 90 beats priority 10 — that is what the attribute promises"
    end

    # `put/4` writes into the sheet whose declaration WINS, so the value an operator edits is the
    # value they were shown. That falls out of the same ordering.
    test "writing a token edits the sheet whose declaration wins" do
      run = System.unique_integer([:positive])
      key = "priw-#{run}"

      low = sheet!("priw-low-#{run}", ":root {\n  --#{key}: #111111;\n}\n", priority: 10)
      high = sheet!("priw-high-#{run}", ":root {\n  --#{key}: #de1135;\n}\n", priority: 90)

      master = MishkaCmsCore.Test.Factory.create_user_with_permissions!(["*"])

      assert {:ok, _token} = Tokens.put(master, nil, "--" <> key, "#00ff00")

      reload = fn record ->
        Stylesheet
        |> Ash.get!(record.id, authorize?: false, action: :read_any)
        |> Map.fetch!(:content)
      end

      assert reload.(high) =~ "#00ff00"
      assert reload.(low) =~ "#111111", "the losing sheet is left alone"
    end
  end
end
