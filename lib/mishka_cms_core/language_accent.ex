# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.LanguageAccent do
  @moduledoc """
  The colour a language's badge wears on an admin card.

  The design names five — EN indigo, FA green, RU amber, FR pink, DE blue — but `language` is a free
  ISO-639-1 string, so an unnamed one (`ar`, `zh`, `pt`) is *hashed* into the same five rather than all
  falling back to one. `:erlang.phash2/2` is stable, so a language keeps its colour for good (the same
  trick `MishkaCmsCore.Activity.Helpers.avatar_tone/1` uses for actor avatars).

  Colour is what makes an editions row legible: `EN · Primary` beside `FA · 100%` only reads if the two
  differ. An archived record ignores its language and goes grey — archived reads as inactive before it
  reads as Farsi.

  Every value is a Tailwind class, not a hex string: the runtime CSS compiler only emits a class it can
  see written out, so the palette has to be literal.

      iex> MishkaCmsCore.LanguageAccent.of(%{language: "en"}).chip
      "border-[#dcdbf5] bg-[#eeedfb] text-[#5b57d6]"

  Used by `MishkaDocument.WorkspaceAccent` and `MishkaBlogWeb.Templates.CollectionCard`. See
  `MishkaCmsCore.LanguageEditions`, which finds the siblings these colour.
  """

  @palette [
    %{
      bar: "bg-[#5b57d6]",
      solid: "text-[#5b57d6]",
      tile: "bg-[#eeedfb] text-[#5b57d6]",
      chip: "border-[#dcdbf5] bg-[#eeedfb] text-[#5b57d6]",
      track: "bg-[#edecfa]",
      fill: "bg-[#5b57d6]",
      stroke: "#5b57d6"
    },
    %{
      bar: "bg-[#1f9d6b]",
      solid: "text-[#1f9d6b]",
      tile: "bg-[#e6f6ee] text-[#1f9d6b]",
      chip: "border-[#cdeadb] bg-[#e6f6ee] text-[#1f9d6b]",
      track: "bg-[#e6f6ee]",
      fill: "bg-[#1f9d6b]",
      stroke: "#1f9d6b"
    },
    %{
      bar: "bg-[#c17d1a]",
      solid: "text-[#c17d1a]",
      tile: "bg-[#fbf1df] text-[#c17d1a]",
      chip: "border-[#f0e2c4] bg-[#fbf1df] text-[#c17d1a]",
      track: "bg-[#f6ecd6]",
      fill: "bg-[#c17d1a]",
      stroke: "#c17d1a"
    },
    %{
      bar: "bg-[#c94f86]",
      solid: "text-[#c94f86]",
      tile: "bg-[#fbe8f0] text-[#c94f86]",
      chip: "border-[#f3d3e2] bg-[#fbe8f0] text-[#c94f86]",
      track: "bg-[#fbe8f0]",
      fill: "bg-[#c94f86]",
      stroke: "#c94f86"
    },
    %{
      bar: "bg-[#2f86c4]",
      solid: "text-[#2f86c4]",
      tile: "bg-[#e6f1fa] text-[#2f86c4]",
      chip: "border-[#cfe3f4] bg-[#e6f1fa] text-[#2f86c4]",
      track: "bg-[#e6f1fa]",
      fill: "bg-[#2f86c4]",
      stroke: "#2f86c4"
    }
  ]

  # The five the design names, in palette order; everything else hashes.
  @named %{"en" => 0, "fa" => 1, "ru" => 2, "fr" => 3, "de" => 4}

  @archived %{
    bar: "bg-[#9a978f]",
    solid: "text-[#9a978f]",
    tile: "bg-[#eceae4] text-[#9a978f]",
    chip: "border-[#e0ddd6] bg-[#eceae4] text-[#9a978f]",
    track: "bg-[#e7e5df]",
    fill: "bg-[#9a978f]",
    stroke: "#9a978f"
  }

  @doc "The grey every archived record wears, whatever language it is in."
  @spec archived() :: map()
  def archived, do: @archived

  @doc "The accent a record's language badge wears — its language's colour, or grey once archived."
  @spec of(map()) :: map()
  def of(%{status: :archived}), do: @archived
  def of(%{archived_at: at}) when not is_nil(at), do: @archived
  def of(%{language: language}), do: for_language(language)
  def of(_record), do: for_language(nil)

  @doc """
  The colour a language code wears, whether or not the design names it.

  Blank falls back to English, as the design does (`LANGC[c.lang] || LANGC.EN`) and as the attribute's
  own default says.
  """
  @spec for_language(String.t() | atom() | nil) :: map()
  def for_language(language) do
    case language |> to_string() |> String.trim() |> String.downcase() do
      "" -> Enum.at(@palette, 0)
      key -> Enum.at(@palette, Map.get(@named, key) || :erlang.phash2(key, length(@palette)))
    end
  end
end
