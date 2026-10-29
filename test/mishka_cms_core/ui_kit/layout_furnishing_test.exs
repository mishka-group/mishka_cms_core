# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.LayoutFurnishingTest do
  @moduledoc """
  What a freshly dropped LAYOUT component arrives holding.

  Furnishing exists so that dropping a component gives you something to look at — an empty container
  is an invisible box, and an author who drops one and sees nothing has no way to tell it worked.
  For a wrapper, "something to look at" is STRUCTURE: the columns, so you can aim at them. It is not
  prose, and it is not decoration.

  The grid shipped with both. Its three columns carried `rounded-lg border border-neutral-200 p-6`
  and the words *First column*, *Second column*, *Third column*, which produced three separate
  reports on one issue:

    * the placeholder prose renders to VISITORS, because nothing removes it on publish;
    * the border and padding make a bare wrapper look like three cards, and a real card dropped
      inside one then sits in a box with a box around it;
    * deleting the middle column leaves "First" and "Third", because the ordinals are hardcoded
      words rather than anything the tree counts.

  The canvas already draws an empty container as a dashed drop target (`@hollow_style` in
  `MishkaCmsBuilderWeb.Live.CanvasLive`) and that treatment is editing-only — it is never
  written to the document. So bare columns lose nothing on the canvas and take nothing to the page.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  defp furnishing(name) do
    @bundle
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("components")
    |> Enum.find(&(&1["name"] == name))
    |> get_in(["extra", "furnishing", "body"])
  end

  describe "the grid's furnishing" do
    test "is columns and nothing else" do
      assert furnishing("chelekom-grid") ==
               ~s(<div class="col-span-12 sm:col-span-4"></div>\n) <>
                 ~s(<div class="col-span-12 sm:col-span-4"></div>\n) <>
                 ~s(<div class="col-span-12 sm:col-span-4"></div>)
    end

    # The three reports, as three assertions, against the shipped file.
    test "carries no words for a visitor to read" do
      body = furnishing("chelekom-grid")

      refute body =~ ~r/>[^<]*\p{L}/u, "placeholder prose ships to the page: #{body}"
    end

    test "and no decoration on what is meant to be a bare wrapper" do
      body = furnishing("chelekom-grid")

      for class <- ~w(border rounded-lg p-6 bg-) do
        refute body =~ class, "the grid's columns still carry #{class}"
      end
    end

    # `col-span-*` IS the point — a grid whose columns do not span is not a grid.
    test "while keeping the spans that make it a grid" do
      assert furnishing("chelekom-grid") =~ "col-span-12"
      assert furnishing("chelekom-grid") =~ "sm:col-span-4"
    end
  end
end
