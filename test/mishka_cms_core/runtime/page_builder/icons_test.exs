defmodule MishkaCmsCore.Runtime.PageBuilder.IconsTest do
  @moduledoc """
  The heroicon catalogue the picker offers and the canvas paints from.

  The list and the markup are read at COMPILE time from the same directory the Tailwind plugin reads,
  because `deps/` is a build artefact a release does not ship while the class names a release renders
  are baked into its CSS.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Icons

  describe "the catalogue" do
    test "carries all four weights the set ships" do
      assert Icons.available?()

      assert "hero-academic-cap" in Icons.all()
      assert "hero-academic-cap-solid" in Icons.all()
      assert "hero-academic-cap-mini" in Icons.all()
      assert "hero-academic-cap-micro" in Icons.all()
    end

    test "known?/1 answers for a real class and refuses anything else" do
      assert Icons.known?("hero-bell")
      refute Icons.known?("hero-not-an-icon")
      refute Icons.known?(nil)
    end
  end

  describe "search/2" do
    test "matches on the bare name, whichever way it is typed" do
      assert "hero-arrow-up" in Icons.search("arrow-up")
      assert "hero-arrow-up" in Icons.search("hero-arrow-up")
      assert "hero-arrow-up" in Icons.search("  Arrow Up  ")
    end

    test "searches within a weight and suffixes what it returns" do
      results = Icons.search("check", variant: "-solid", limit: 5)

      assert Enum.all?(results, &String.ends_with?(&1, "-solid"))
    end

    # An empty picker looks broken; the first page of icons is a reasonable place to start browsing.
    test "an empty query returns the head of the list rather than nothing" do
      assert length(Icons.search("", limit: 10)) == 10
    end

    test "the count is of everything matching, not of what was returned" do
      assert Icons.count("arrow") > length(Icons.search("arrow", limit: 5))
    end
  end

  describe "css/1" do
    # The site's compiled stylesheet is generated from the classes its own pages RENDER, so a
    # component's DEFAULT icon has no rule and drew an empty box where the glyph belongs.
    test "emits the plugin's own rule for a class" do
      css = Icons.css(["hero-bell"])

      assert css =~ ".hero-bell{"
      assert css =~ "mask:url('data:image/svg+xml;utf8,"
      assert css =~ "background-color:currentColor"
      assert css =~ "display:inline-block"
    end

    test "sizes each weight the way the plugin does" do
      assert Icons.css(["hero-bell"]) =~ "width:1.5rem"
      assert Icons.css(["hero-bell-mini"]) =~ "width:1.25rem"
      assert Icons.css(["hero-bell-micro"]) =~ "width:1rem"
    end

    test "a name the set does not ship contributes nothing" do
      assert Icons.css(["hero-not-an-icon"]) == ""
    end

    test "duplicates are emitted once" do
      css = Icons.css(["hero-bell", "hero-bell"])

      assert css |> String.split(".hero-bell{") |> length() == 2
    end
  end

  describe "svg/2" do
    test "returns safe markup at the size asked for" do
      assert {:safe, iodata} = Icons.svg("hero-bell", 15)
      html = IO.iodata_to_binary(iodata)

      assert html =~ "<svg"
      assert html =~ ~s(width="15")
      assert html =~ "</svg>"
    end

    test "answers nil for a class the set does not ship" do
      refute Icons.svg("hero-not-an-icon")
    end
  end
end
