defmodule MishkaCmsCore.Runtime.PageBuilder.ShadowTest do
  @moduledoc """
  Taking a box shadow apart so it can be edited, and putting it back together unharmed.

  A control that offers `box-shadow` as one string offers nothing: nobody reads
  `0 10px 24px -4px rgba(15,23,42,.18)`, they paste it. Six controls — right, down, soft, bigger,
  colour, inside — is the same shadow as something a person can nudge, which is the decomposition
  Chrome's own editor makes.

  The bound that matters is the REFUSAL. A shadow this cannot hold whole must come back `:error`, so
  the author keeps the string they wrote instead of watching half of it disappear into a control.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Shadow

  @moduletag :unit

  describe "taking one apart" do
    test "the four lengths and the colour" do
      assert {:ok, parts} = Shadow.parse("0 10px 24px -4px rgba(15,23,42,0.18)")

      assert parts == %{
               x: "0",
               y: "10px",
               blur: "24px",
               spread: "-4px",
               color: "rgba(15,23,42,0.18)",
               inset: false
             }
    end

    # The two-length form is the one CSS actually requires, and the one a hand-written shadow most
    # often is. What is missing is zero, not the panel's own default — a shadow that gained a 12px
    # blur on being opened would be a control editing something the page never said.
    test "a shorter shadow fills the rest in with zero, not with a default" do
      assert {:ok, parts} = Shadow.parse("2px 4px")

      assert parts.blur == "0"
      assert parts.spread == "0"
      assert parts.x == "2px"
      assert parts.y == "4px"
    end

    test "a shadow with no colour keeps a colour anyway, because none is not a thing anyone means" do
      assert {:ok, parts} = Shadow.parse("0 2px 4px")
      assert parts.color == Shadow.default().color
    end

    test "inset is found wherever it sits" do
      assert {:ok, %{inset: true, y: "2px"}} = Shadow.parse("inset 0 2px 4px rgba(0,0,0,0.1)")
      assert {:ok, %{inset: true, y: "2px"}} = Shadow.parse("0 2px 4px rgba(0,0,0,0.1) inset")
      assert {:ok, %{inset: false}} = Shadow.parse("0 2px 4px")
    end

    test "case and stray whitespace do not matter" do
      assert {:ok, %{color: "rgba(0,0,0,0.1)"}} =
               Shadow.parse("  0   2PX  4px   RGBA(0,0,0,0.1) ")
    end
  end

  describe "refusing the ones it cannot hold" do
    # ONE SET OF CONTROLS CANNOT HOLD TWO SHADOWS. Reading the first and dropping the second would
    # delete a layer the author wrote the moment they touched any control.
    test "a second layer" do
      assert Shadow.parse("0 1px 2px #000, 0 8px 16px #333") == :error
    end

    # And the comma inside `rgba(…)` is not that comma.
    test "but a comma inside a colour is not a second layer" do
      assert {:ok, %{color: "rgba(15,23,42,0.18)"}} =
               Shadow.parse("0 1px 2px rgba(15,23,42,0.18)")
    end

    test "nothing at all" do
      assert Shadow.parse("") == :error
      assert Shadow.parse("   ") == :error
      assert Shadow.parse(nil) == :error
    end

    test "a keyword this has no control for" do
      assert Shadow.parse("none") == :error
      assert Shadow.parse("inherit") == :error
    end

    test "more lengths than a shadow has" do
      assert Shadow.parse("1px 2px 3px 4px 5px") == :error
    end

    test "two things that are not lengths" do
      assert Shadow.parse("0 2px red blue") == :error
    end
  end

  describe "putting one back together" do
    test "the parts become the declaration" do
      value =
        Shadow.to_value(%{
          x: "0",
          y: "10px",
          blur: "24px",
          spread: "-4px",
          color: "rgba(15,23,42,0.18)",
          inset: false
        })

      assert value == "0 10px 24px -4px rgba(15,23,42,0.18)"
    end

    test "inset leads, the way CSS writes it" do
      assert Shadow.to_value(%{Shadow.default() | inset: true}) =~ ~r/^inset /
    end

    # A shadow with no offset, no blur and no spread paints nothing. Written out it is a declaration
    # on the page that does nothing, which the next reader has to test to discover.
    test "a shadow that would paint nothing is no shadow" do
      assert Shadow.to_value(%{x: "0", y: "0", blur: "0", spread: "0", color: "#000"}) == nil

      assert Shadow.to_value(%{x: "0px", y: "0", blur: "0%", spread: "0rem", color: "#000"}) ==
               nil
    end

    test "and one non-zero length is enough to be one" do
      assert Shadow.to_value(%{Shadow.default() | x: "0", y: "1px", blur: "0", spread: "0"})
    end
  end

  describe "the round trip" do
    # ONE CANONICAL SHAPE, always four lengths. A shadow written `0 2px 4px` comes back
    # `0 2px 4px 0` — the same shadow, and the only way the Spread control has a value to show
    # instead of a blank that means zero. So what has to survive is the SHADOW, not the spelling.
    test "every shadow this accepts survives being taken apart and rebuilt" do
      for value <- [
            "0 10px 24px -4px rgba(15,23,42,0.18)",
            "inset 0 2px 4px rgba(0,0,0,0.12)",
            "2px 4px 0 0 #ff0000",
            "0 0 0 3px #4f4bcc"
          ] do
        assert {:ok, parts} = Shadow.parse(value)
        assert {:ok, ^parts} = parts |> Shadow.to_value() |> Shadow.parse()
      end
    end

    test "and a shadow already in that shape comes back byte for byte" do
      value = "0 10px 24px -4px rgba(15,23,42,0.18)"

      assert {:ok, parts} = Shadow.parse(value)
      assert Shadow.to_value(parts) == value
    end

    test "and every preset is one of them" do
      for {name, value} <- Shadow.presets() do
        assert {:ok, parts} = Shadow.parse(value), "#{name} does not parse"
        assert Shadow.to_value(parts) == value
      end
    end
  end

  describe "changing one part" do
    test "leaves the others where they were" do
      assert Shadow.put("0 10px 24px -4px rgba(15,23,42,0.18)", :y, "20px") ==
               "0 20px 24px -4px rgba(15,23,42,0.18)"
    end

    test "turns inset on and off" do
      assert Shadow.put("0 2px 4px 0 #000", :inset, true) == "inset 0 2px 4px 0 #000"
      assert Shadow.put("inset 0 2px 4px 0 #000", :inset, false) == "0 2px 4px 0 #000"
    end

    # THE FIRST NUDGE ON AN ELEMENT WITH NO SHADOW. There is nothing to read, so the other five
    # parts have to come from somewhere — and coming from zero would mean dragging Y up and seeing
    # nothing happen, because a shadow with no colour and no blur is invisible.
    test "an element with no shadow starts from one worth seeing" do
      value = Shadow.put(nil, :y, "8px")

      assert {:ok, parts} = Shadow.parse(value)
      assert parts.y == "8px"
      assert parts.blur == Shadow.default().blur
      assert parts.color == Shadow.default().color
    end

    # Half-reading a two-layer shadow would keep one layer and silently delete the other. Refusing it
    # in `parse/1` means the control starts clean instead, and the author can see that it did.
    test "and a shadow this cannot read is replaced rather than half-kept" do
      value = Shadow.put("0 1px 2px #000, 0 8px 16px #333", :y, "8px")

      assert {:ok, %{y: "8px"}} = Shadow.parse(value)
      refute value =~ "#333"
      refute value =~ "#000"
    end
  end
end
