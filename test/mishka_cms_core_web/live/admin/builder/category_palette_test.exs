# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Admin.Builder.CategoryPaletteTest do
  @moduledoc """
  The palette's colour coding surviving a taxonomy nobody hardcoded.

  Ten category names carried a colour each — `layout`, `text`, `nav`, `form`, `media`, `feedback`,
  `data`, `overlay`, `general` — and every other name took the same grey. Those ten are Chelekom's,
  so a kit filing its components under `widgets`/`charts`/`commerce` got a palette where the dot
  beside every group heading and the tile behind every card were the same colour: the coding still
  drawn, still spending the space, carrying nothing. Chelekom's palette read by colour and theirs
  did not, in the same screen.

  A derived hue is not as good as a designed one. It is much better than one grey for everybody, and
  it needs no table to maintain as kits arrive.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  defp hue(hex) do
    <<"#", r::binary-2, g::binary-2, b::binary-2>> = hex
    [red, green, blue] = Enum.map([r, g, b], &(String.to_integer(&1, 16) / 255))

    high = Enum.max([red, green, blue])
    low = Enum.min([red, green, blue])
    span = high - low

    cond do
      span == 0 -> 0.0
      high == red -> 60 * :math.fmod((green - blue) / span + 6, 6)
      high == green -> 60 * ((blue - red) / span + 2)
      true -> 60 * ((red - green) / span + 4)
    end
  end

  defp lightness(hex) do
    <<"#", r::binary-2, g::binary-2, b::binary-2>> = hex
    [red, green, blue] = Enum.map([r, g, b], &(String.to_integer(&1, 16) / 255))

    (Enum.max([red, green, blue]) + Enum.min([red, green, blue])) / 2
  end

  describe "a category the CMS has never heard of" do
    test "is not handed the grey everything else got" do
      refute Panels.category_dot("commerce") == Panels.category_dot("widgets")
      refute Panels.category_tint("commerce") == Panels.category_tint("widgets")
    end

    test "gets a colour at all, in the form the template interpolates" do
      assert Panels.category_dot("commerce") =~ ~r/^#[0-9a-f]{6}$/
      assert Panels.category_tint("commerce") =~ ~r/^#[0-9a-f]{6}$/
    end

    # STABLE, or the dot beside a heading changes colour every time the panel re-renders and the
    # coding is worse than no coding.
    test "keeps the same colour across calls" do
      assert Panels.category_dot("charts") == Panels.category_dot("charts")
      assert Panels.category_tint("charts") == Panels.category_tint("charts")
    end

    test "is case-insensitive, like the hardcoded names are" do
      assert Panels.category_dot("Charts") == Panels.category_dot("charts")
    end

    # The derived pair must look like it came from the same palette as the authored ten: a readable
    # foreground and a tint pale enough to sit a glyph on. Same hue, so the tile reads as one object.
    test "sits in the same lightness range the authored colours occupy" do
      dot = Panels.category_dot("commerce")
      tint = Panels.category_tint("commerce")

      assert lightness(dot) < 0.6, "a foreground dark enough to read on white"
      assert lightness(tint) > 0.88, "a tint pale enough to sit a glyph on"
      assert_in_delta hue(dot), hue(tint), 1.0
    end
  end

  describe "the authored categories" do
    test "are untouched" do
      assert Panels.category_dot("layout") == "#4f4bcc"
      assert Panels.category_tint("layout") == "#eef1fc"
      assert Panels.category_icon("layout") == :layers
    end

    test "still answer for a nil type" do
      assert Panels.category_dot(nil) == Panels.category_dot("general")
    end

    # `:bell` was not in the icon set, so `shapes/1` fell to its own `box` default and the feedback
    # category drew a plain square. `:tip` is the glyph alert/toast/banner already resolve to.
    test "feedback names a glyph that exists" do
      assert Panels.category_icon("feedback") == :tip
      assert Panels.entry_icon(%{name: "chelekom-toast", type: "feedback"}) == :tip
    end
  end
end
