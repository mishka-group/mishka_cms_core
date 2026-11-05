# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.CardChromeTest do
  @moduledoc """
  `MishkaCmsCoreWeb.Templates.CardChrome.range_label/3` is the count over every card list, so what it
  says has to be true of the page under the reader's eyes.

  The last page holds a remainder rather than a full page, so the upper bound is clamped by the total.
  A page past the last one (`?bloggers_page=2` over 14 bloggers) holds none of the set, and the empty
  label is the wrong answer there: the set is not empty, so "0 bloggers" or "No drafts yet" would be
  false. It counts no rows of the total instead, and never a range whose start is past its end.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCoreWeb.Templates.CardChrome

  defp range(state), do: CardChrome.range_label(state, 20, "0 bloggers")

  describe "range_label/3" do
    test "counts the slice on a full first page" do
      assert range(%{total_count: 48, page: 1}) == "Showing 1–20 of 48"
    end

    test "counts the slice on a middle page" do
      assert range(%{total_count: 48, page: 2}) == "Showing 21–40 of 48"
    end

    test "clamps the last page to the remainder rather than a full page" do
      assert range(%{total_count: 48, page: 3}) == "Showing 41–48 of 48"
    end

    test "handles a single partial page" do
      assert range(%{total_count: 7, page: 1}) == "Showing 1–7 of 7"
    end

    test "a last page that is exactly full still counts its rows" do
      assert range(%{total_count: 40, page: 2}) == "Showing 21–40 of 40"
    end

    test "a page past the last counts no rows of a set that is not empty" do
      assert range(%{total_count: 14, page: 2}) == "Showing 0 of 14"
      assert range(%{total_count: 40, page: 3}) == "Showing 0 of 40"
      assert range(%{total_count: 14, page: 9}) == "Showing 0 of 14"
    end

    test "a page before the first counts no rows either" do
      assert range(%{total_count: 14, page: 0}) == "Showing 0 of 14"
      assert range(%{total_count: 14, page: -3}) == "Showing 0 of 14"
    end

    test "says nothing was found rather than counting from one" do
      assert range(%{total_count: 0, page: 1}) == "0 bloggers"
      assert range(%{total_count: nil, page: 1}) == "0 bloggers"
      assert range(%{total_count: 0, page: 2}) == "0 bloggers"
    end

    test "a Load more list counts from its first row, as every loaded page is on screen" do
      assert CardChrome.range_label(%{total_count: 136, page: 2}, 20, nil, :load_more) ==
               "Showing 1–40 of 136"

      assert CardChrome.range_label(%{total_count: 48, page: 3}, 20, nil, :load_more) ==
               "Showing 1–48 of 48"

      assert CardChrome.range_label(%{total_count: 136, page: 2}, 20, nil, :numbered) ==
               "Showing 21–40 of 136"
    end

    test "falls back to its own words when the card gives no empty label" do
      assert CardChrome.range_label(%{total_count: 0, page: 1}, 20) == "Nothing found"
    end

    test "survives a state that has not counted yet" do
      assert range(%{}) == "0 bloggers"
      assert range(%{total_count: 14}) == "0 bloggers"
    end
  end
end
