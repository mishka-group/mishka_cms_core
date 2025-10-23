defmodule MishkaCmsCore.Runtime.PageBuilder.Tree.Shadow do
  @moduledoc """
  A box shadow as the five things an author is actually choosing, and back again.

  `box-shadow` is one string holding four lengths, a colour and a keyword, and a control that offers
  it as one string offers nothing: `0 10px 24px -4px rgba(15,23,42,.18)` is not a value anyone reads
  or edits, it is a value they paste. So the panel takes the shadow apart — how far right, how far
  down, how soft, how much bigger, what colour, and whether it falls inside the box — and puts it
  back together on every change. That is the same decomposition Chrome's own shadow editor makes,
  and it is what turns "which side is the shadow on" into two numbers you can nudge.

  ## What survives

  Only the shape the panel can express: `[inset] <x> <y> <blur> <spread> <colour>`. A shadow with a
  second layer, or a colour this cannot recognise, `parse/1` refuses rather than half-reads — the
  author keeps the string they wrote, in the element's own CSS, instead of watching a control
  silently throw half of it away.

  Anything omitted comes back as its CSS default: a missing blur is `0`, a missing colour is
  `currentColor`'s stand-in here, `rgba(0,0,0,.2)`, chosen because a shadow with no colour at all is
  the one thing nobody means.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @type t :: %{
          x: String.t(),
          y: String.t(),
          blur: String.t(),
          spread: String.t(),
          color: String.t(),
          inset: boolean()
        }

  @default %{
    x: "0",
    y: "4px",
    blur: "12px",
    spread: "0",
    color: "rgba(15,23,42,0.12)",
    inset: false
  }

  @fields ~w(x y blur spread)a

  @doc """
  The parts a shadow is made of, or `:error` when this cannot hold the whole of it.

  A blank string is `:error` too: nothing to take apart is not a shadow with default parts, and
  offering one would make an unset control look set.
  """
  @spec parse(String.t() | nil) :: {:ok, t()} | :error
  def parse(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> split_layers()
    |> from_tokens()
  end

  def parse(_value), do: :error

  @doc """
  The shadow a set of parts means, or `nil` when they mean no shadow at all.

  `nil` rather than `"none"`: the panel clears an override by writing an empty value, and a control
  that wrote `box-shadow: none` instead would leave a real declaration behind for the next reader to
  wonder about.
  """
  @spec to_value(map()) :: String.t() | nil
  def to_value(parts) when is_map(parts) do
    parts = normalise(parts)

    case blank?(parts) do
      true -> nil
      false -> parts |> tokens() |> Enum.join(" ")
    end
  end

  @doc "The parts a control starts from when the element has no shadow yet."
  @spec default() :: t()
  def default, do: @default

  @doc """
  One part changed, as the whole shadow.

  The panel edits a single number at a time and the property holds all of them, so every control
  reads the current value, replaces its own part and writes the string back.
  """
  @spec put(String.t() | nil, atom(), String.t() | boolean()) :: String.t() | nil
  def put(value, field, part) do
    value
    |> parse()
    |> case do
      {:ok, parts} -> parts
      :error -> @default
    end
    |> Map.put(field, part)
    |> to_value()
  end

  @doc """
  The named shadows a row of one-click presets offers.

  Elevation is a scale, not a number people invent: "none, small, medium, large" is how every design
  system already talks about it, and the fields underneath still take anything.
  """
  @spec presets() :: [{String.t(), String.t()}]
  def presets do
    [
      {gettext_noop("S"), "0 1px 2px 0 rgba(15,23,42,0.08)"},
      {gettext_noop("M"), "0 4px 12px -2px rgba(15,23,42,0.12)"},
      {gettext_noop("L"), "0 10px 24px -4px rgba(15,23,42,0.18)"},
      {gettext_noop("XL"), "0 24px 48px -12px rgba(15,23,42,0.25)"}
    ]
    |> Enum.map(fn {label, value} -> {Gettext.gettext(MishkaCmsCore.Gettext, label), value} end)
  end

  # A COMMA MEANS A SECOND SHADOW, and one set of controls cannot hold two. Commas inside `rgba(…)`
  # are not that comma, so the split has to respect brackets rather than the character.
  defp split_layers(value) do
    case depth_split(value) do
      [single] -> String.split(single, ~r/\s+/, trim: true)
      _layered -> :layered
    end
  end

  defp depth_split(value) do
    value
    |> String.graphemes()
    |> Enum.reduce({[""], 0}, fn
      "(", {[head | rest], depth} -> {["(" <> head | rest], depth + 1}
      ")", {[head | rest], depth} -> {[")" <> head | rest], depth - 1}
      ",", {acc, 0} -> {["" | acc], 0}
      char, {[head | rest], depth} -> {[char <> head | rest], depth}
    end)
    |> elem(0)
    |> Enum.map(&String.reverse/1)
  end

  defp from_tokens(:layered), do: :error
  defp from_tokens([]), do: :error

  defp from_tokens(tokens) do
    {inset, tokens} = take_inset(tokens)
    {lengths, rest} = Enum.split_while(tokens, &length?/1)

    with true <- length(lengths) in 2..4,
         {:ok, colour} <- colour_of(rest) do
      {:ok, build(lengths, colour, inset)}
    else
      _unreadable -> :error
    end
  end

  defp take_inset(tokens) do
    case Enum.split_with(tokens, &(&1 == "inset")) do
      {[], rest} -> {false, rest}
      {[_inset], rest} -> {true, rest}
      _twice -> {false, tokens}
    end
  end

  defp colour_of([]), do: {:ok, @default.color}
  defp colour_of([colour]), do: {:ok, colour}
  defp colour_of(_several), do: :error

  defp build(lengths, colour, inset) do
    given = Enum.zip(@fields, lengths) |> Map.new()

    @default
    |> Map.take(@fields)
    |> Map.merge(%{blur: "0", spread: "0"})
    |> Map.merge(given)
    |> Map.merge(%{color: colour, inset: inset})
  end

  # `0`, `4px`, `-0.5rem`, `.25em` — a length, and never a colour or the `inset` keyword.
  defp length?(token) do
    Regex.match?(~r/^-?(\d+\.?\d*|\.\d+)(px|rem|em|%|vh|vw|ch)?$/, token)
  end

  defp normalise(parts) do
    Map.merge(@default, Map.take(parts, [:x, :y, :blur, :spread, :color, :inset]))
  end

  # NO OFFSET, NO BLUR AND NO SPREAD IS NOT A SHADOW. Writing `0 0 0 0 <colour>` puts a declaration
  # on the page that paints nothing, which reads to the next author as a shadow that is broken
  # rather than as one nobody set.
  defp blank?(parts), do: Enum.all?(@fields, &zero?(Map.get(parts, &1)))

  defp zero?(value) do
    case Float.parse(to_string(value)) do
      {number, unit} when number == 0 -> unit in ["", "px", "rem", "em", "%"]
      _other -> to_string(value) == ""
    end
  end

  defp tokens(parts) do
    lengths = Enum.map(@fields, &to_string(Map.get(parts, &1)))

    case parts.inset do
      true -> ["inset" | lengths] ++ [to_string(parts.color)]
      false -> lengths ++ [to_string(parts.color)]
    end
  end
end
