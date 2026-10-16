# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.AssetsGridTest do
  @moduledoc """
  Which action the builder's file card puts in the one slot that carries WORDS.

  A media card has room for exactly one labelled button; everything else is a glyph. On the Media
  page that button is Edit, which is right — you went there to manage files. In the builder's Assets
  sheet it was Edit too, which is wrong: you did not come to edit a file, you came to put one in the
  document, and `Use` sat unlabelled between Preview and Archive. The sheet said "Choosing for image"
  and then gave no visible answer to "how?".
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCoreWeb.Templates.AssetsGrid

  describe "the card's one labelled button" do
    test "is Use while something in the editor is waiting for a file" do
      options = AssetsGrid.picking_options(%{path_params: %{editor_pick_node: "nabc123"}})

      assert options[:primary_action] == :use_in_editor
    end

    # The star over the thumbnail is named too, because naming only one of the two would hand the
    # other back to `MediaGallery`'s default through a `template_options` list that no longer
    # mentions it.
    test "and the star stays the star" do
      options = AssetsGrid.picking_options(%{path_params: %{editor_pick_node: "nabc123"}})

      assert options[:overlay_action] == :toggle_featured
    end

    # NO OPINION IS THE ANSWER MOST OF THE TIME. With nothing picking, `Use` is not rendered at all —
    # the resource hides it — so the slot goes back to Edit and this is the Media page's card again.
    test "is left alone when nothing is picking" do
      assert AssetsGrid.picking_options(%{path_params: %{}}) == []
    end

    test "and when the param is there but empty" do
      assert AssetsGrid.picking_options(%{path_params: %{editor_pick_node: nil}}) == []
    end
  end
end
