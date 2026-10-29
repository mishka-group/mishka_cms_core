# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.StylesheetLoadOrderTest do
  @moduledoc """
  Which stylesheet wins, and the two places that have to agree about it.

  `priority` documents itself as *lower loads first, so a higher value wins on equal specificity*,
  and the `:for_compiler` read already sorted that way. Then both consumers re-sorted the rows on
  `-priority`: `TailwindCompiler.format_stylesheets/1`, which decides what the browser sees, and
  `MishkaCmsBuilder.Tokens.token_sheets/1`, which decides what Studio shows. Negating it emits the
  highest value FIRST, and CSS is last-wins — so the LOWEST priority sheet won.

  The two agreed with each other, which is exactly why it was invisible: Studio displayed the value
  the page really rendered. Both were the opposite of what an operator setting `priority: 90` asked
  for, and nothing said so.

  `Stylesheet.load_order/1` is now the single key both sort by, so they cannot drift apart again.

  `async: false` — global stylesheet rows are visible to every site.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Stylesheet

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
end
