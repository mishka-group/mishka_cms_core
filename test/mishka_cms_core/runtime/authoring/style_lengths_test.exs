# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.StyleLengthsTest do
  @moduledoc """
  What a length box in the Inspector actually accepts — and whether it says so.

  Reported on the editor issue as "these fields ... don't accept %, rem or the other options —
  apparently you can only give them a px number". They always did: `Styles.set/4` passes any CSS
  length through untouched and only a BARE number is read as pixels, because `w-[1000]` compiles to
  nothing at all and a number typed into a box labelled Width plainly means pixels.

  So the fault was not the field, it was the label. Every one of these boxes said "unset", so an
  author who typed `1000`, got pixels, and had no reason to try anything else concluded pixels were
  all it took. Gap has always said "any length, e.g. 2rem".
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.Authoring.Tree.Styles

  # The classes the panel writes for one property, which is where the unit decision is made.
  defp width(value), do: %{base: %{"width" => value}} |> Styles.to_classes() |> Enum.join(" ")

  describe "a length box takes any CSS length" do
    test "a percentage is kept as written" do
      assert width("50%") =~ "w-[50%]"
    end

    test "and rem, and every other unit" do
      assert width("2rem") =~ "w-[2rem]"
      assert width("40ch") =~ "w-[40ch]"
      assert width("60vw") =~ "w-[60vw]"
    end

    test "and an explicit px is not doubled" do
      assert width("600px") =~ "w-[600px]"
      refute width("600px") =~ "pxpx"
    end

    # `w-[1000]` compiles to nothing: the class lands, the panel shows 1000, the width stays put.
    test "while a bare number means pixels, because it cannot mean anything else" do
      assert width("1000") =~ "w-[1000px]"
      assert width("12.5") =~ "w-[12.5px]"
    end
  end

  describe "which properties are lengths" do
    test "the sizes an author types into are all there" do
      for prop <- ~w(width height min-height max-width gap padding margin radius) do
        assert prop in Styles.lengths(), "#{prop} is a length and should read a bare number as px"
      end
    end

    # A bare number is exactly right for these, and appending px would break them.
    test "and the ones that are numbers rather than lengths are not" do
      for prop <- ~w(opacity z-index) do
        refute prop in Styles.lengths()
      end
    end
  end
end
