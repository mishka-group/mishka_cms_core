defmodule MishkaCmsCore.Runtime.PageBuilder.ComponentOverrideTest do
  @moduledoc """
  Whether a style the Inspector writes actually WINS on a kit component.

  `Styles.merge_class/3` already wins the ordinary tie by dropping the authored class an override
  claims — two single-class selectors tie on specificity, and the loser is decided by whichever rule
  the compiled bundle happens to list last, so the only safe move is to remove one of them.

  That works while both classes are in the same attribute. On a kit component they are not: the
  component renders `bg-white` from its own `variant`, inside its own template, where nothing here
  can reach it. Setting a background then put `bg-[#ff0000]` on the element, left `bg-white` beside
  it, and painted white — reported on the editor issue as "the background doesn't take a colour".

  Tailwind v4 spells important as a suffix, and it goes after the whole utility so a variant keeps
  its prefix.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Styles

  @red %{base: %{"background" => "#ff0000"}}

  describe "an override on a component" do
    test "is marked important, because the class it must beat is out of reach" do
      assert Styles.to_classes(@red, important?: true) == ["bg-[#ff0000]!"]
    end

    test "and a variant keeps its prefix, with the mark after the whole utility" do
      [tablet] = Styles.to_classes(%{tablet: %{"background" => "#ff0000"}}, important?: true)
      [hover] = Styles.to_classes(%{hover: %{"background" => "#ff0000"}}, important?: true)

      assert String.ends_with?(tablet, "bg-[#ff0000]!")
      assert String.contains?(tablet, ":"), "a breakpoint override lost its prefix: #{tablet}"
      assert hover == "hover:bg-[#ff0000]!"
    end

    test "and merge_class carries it through" do
      assert Styles.merge_class("p-4", @red, important?: true) =~ "bg-[#ff0000]!"
    end
  end

  describe "an override on an ordinary tag" do
    # Nothing to beat that this module cannot see, so the class stays plain: `!important` on every
    # utility an author sets would make the document harder to reason about for no gain.
    test "is left plain" do
      assert Styles.to_classes(@red) == ["bg-[#ff0000]"]
      assert Styles.to_classes(@red, important?: false) == ["bg-[#ff0000]"]
    end

    test "and the authored class it replaces is still dropped rather than joined" do
      merged = Styles.merge_class("bg-[#000000] p-4", @red)

      assert merged =~ "bg-[#ff0000]"
      refute merged =~ "bg-[#000000]"
    end
  end
end
