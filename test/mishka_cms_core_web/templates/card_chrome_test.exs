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

  import Phoenix.LiveViewTest

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

  describe "range_label/4 for a list opened past its first page" do
    test "starts at the first row shown, not at 1" do
      state = %{total_count: 136, page: 3, first_page: 3}

      assert CardChrome.range_label(state, 20, nil, :load_more) == "Showing 41–60 of 136"
    end

    test "grows upward as Load earlier brings the pages before it" do
      state = %{total_count: 136, page: 3, first_page: 2}

      assert CardChrome.range_label(state, 20, nil, :load_more) == "Showing 21–60 of 136"
    end

    test "ends at the rows the view really shows when the table keeps next_offset" do
      state = %{total_count: 73, page: 2, first_page: 1, next_offset: 38}

      assert CardChrome.range_label(state, 20, nil, :load_more) == "Showing 1–38 of 73"
    end

    test "falls back to the page slots when next_offset is missing or empty" do
      assert CardChrome.range_label(%{total_count: 73, page: 2}, 20, nil, :load_more) ==
               "Showing 1–40 of 73"

      assert CardChrome.range_label(
               %{total_count: 73, page: 2, next_offset: 0},
               20,
               nil,
               :load_more
             ) ==
               "Showing 1–40 of 73"
    end

    test "counts no rows of a page past the last" do
      state = %{loading: :loaded, total_count: 136, page: 999, first_page: 1}

      assert CardChrome.range_label(state, 20, nil, :load_more) == "Showing 0 of 136"
    end
  end

  describe "past_last_page?/2" do
    test "is true for a loaded page past the first that holds no row" do
      assert CardChrome.past_last_page?(%{loading: :loaded, page: 999, total_count: 136}, 20)
      assert CardChrome.past_last_page?(%{loading: :loaded, page: 2, total_count: 20}, 20)
    end

    test "is false while a load runs, on page 1 and on a page that holds rows" do
      refute CardChrome.past_last_page?(%{loading: :loading, page: 999, total_count: 136}, 20)
      refute CardChrome.past_last_page?(%{loading: :loaded, page: 1, total_count: 0}, 20)
      refute CardChrome.past_last_page?(%{loading: :loaded, page: 3, total_count: 45}, 20)
      refute CardChrome.past_last_page?(%{loading: :loaded, page: 2, total_count: nil}, 20)
    end

    test "reads what the last load found when the table records it" do
      read = fn empty? ->
        %{
          loading: :loaded,
          page: 3,
          total_count: 30,
          records_result: %{ok?: true, result: %{page: 3, empty?: empty?}}
        }
      end

      assert CardChrome.past_last_page?(read.(true), 20)
      refute CardChrome.past_last_page?(read.(false), 20)
    end
  end

  describe "earlier?/2" do
    test "is true for a Load more or infinite list opened past its first page" do
      assert CardChrome.earlier?(%{loading: :loaded, first_page: 3}, :load_more)
      assert CardChrome.earlier?(%{loading: :loaded, first_page: 2}, :infinite)
    end

    test "is false on the first page, while loading, on a numbered list and without first_page" do
      refute CardChrome.earlier?(%{loading: :loaded, first_page: 1}, :load_more)
      refute CardChrome.earlier?(%{loading: :loading, first_page: 3}, :load_more)
      refute CardChrome.earlier?(%{loading: :loaded, first_page: 3}, :numbered)
      refute CardChrome.earlier?(%{loading: :loaded, page: 3}, :load_more)
    end
  end

  describe "shown_rows/3" do
    test "counts from the first row shown" do
      assert CardChrome.shown_rows(%{page: 3, first_page: 3}, 20, 136) == 20
      assert CardChrome.shown_rows(%{page: 3, first_page: 1}, 20, 136) == 60
      assert CardChrome.shown_rows(%{page: 999, first_page: 999}, 20, 136) == 0
    end

    test "counts none on a page past the last, however far the capped total reaches" do
      state = %{loading: :loaded, page: 999, first_page: 1, total_count: 10_000}

      assert CardChrome.shown_rows(state, 20, 10_000) == 0
    end
  end

  describe "load_earlier/1 and empty_state/1" do
    @static %{
      ui_adapter: MishkaGervaz.UIAdapters.Tailwind,
      page_size: 20,
      config: %{pagination: %{type: :load_more}}
    }

    defp render_earlier(state) do
      render_component(&CardChrome.load_earlier/1, static: @static, state: state, myself: 1)
    end

    defp render_empty(state) do
      render_component(&CardChrome.empty_state/1,
        id: "rows-empty-state",
        static: @static,
        state: Map.put(state, :current_page_size, nil),
        myself: 1
      )
    end

    test "Load earlier sends the load_earlier event for a list opened past its first page" do
      html = render_earlier(%{loading: :loaded, first_page: 3})

      assert html =~ ~s(phx-click="load_earlier")
      assert html =~ "Load earlier"
    end

    test "Load earlier is not drawn on the first page or by a gervaz without first_page" do
      refute render_earlier(%{loading: :loaded, first_page: 1}) =~ "load_earlier"
      refute render_earlier(%{loading: :loaded, page: 3}) =~ "load_earlier"
    end

    test "a page past the last offers the way back to page 1 in place of the empty message" do
      html = render_empty(%{loading: :loaded, page: 999, total_count: 136})

      assert html =~ "No rows on this page"
      assert html =~ "go_to_page"
      assert html =~ "Go to page 1"
      refute html =~ "No records found"
    end

    test "an empty list keeps its own message" do
      html = render_empty(%{loading: :loaded, page: 1, total_count: 0})

      assert html =~ "No records found"
      refute html =~ "Go to page 1"
    end
  end
end
