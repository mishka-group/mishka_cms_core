# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons do
  @moduledoc """
  The heroicon set, as a `MishkaCmsCore.Runtime.PageBuilder.IconLibrary`.

  ## Why this exists

  An `icon` attribute's value is a **class name** — `hero-check`, `hero-check-solid` — resolved by
  the Tailwind heroicons plugin at `priv/static/temp/js_assets/vendor/heroicons.js`, which reads the
  SVGs out of `deps/heroicons/optimized` and emits one `hero-*` component class per file. Nothing in
  the kit bundle carries that list: Chelekom's `icon` component declares `attr :name, :string` with
  no values and no docs, so the editor's only options were to guess or to make the author type
  `hero-exclamation-triangle` from memory, with a typo producing a silently missing glyph.

  So the list is read from the same directory the plugin reads, **at compile time**: the `heroicons`
  dependency in the deps of the project being built (`Mix.Project.deps_path/0`) — this library's
  own when it is built alone, its host's when it is a dependency. Compile time is the point: `deps/`
  is a build-time artefact and a release does not ship it, while the class names the release renders
  are baked into its CSS — reading at runtime would work in dev and return an empty picker in
  production.

  ## The four variants

  The plugin's own table, which this mirrors exactly:

      ""       → 24/outline    (the default weight)
      "-solid" → 24/solid
      "-mini"  → 20/solid
      "-micro" → 16/solid

  A name is offered in every variant the set actually ships it in — `16/solid` carries eight fewer
  icons than the others, so a blanket suffix list would advertise glyphs that render as nothing.

  ## When the catalogue is empty

  If the directory cannot be found the module compiles to an empty catalogue rather than failing the
  build, and `available?/0` answers false for this set: every variant lists no names, `svg/2` is
  `nil` and `css/1` is `""`. The picker then falls back to a plain text box — a host that does not
  use heroicons loses the picker, not the editor.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @behaviour MishkaCmsCore.Runtime.PageBuilder.IconLibrary

  @impl true
  def prefixes, do: ["hero-"]

  @impl true
  def label, do: "Heroicons"

  @variants [
    {"", "24/outline"},
    {"-solid", "24/solid"},
    {"-mini", "20/solid"},
    {"-micro", "16/solid"}
  ]

  @root Path.join(Mix.Project.deps_path(), "heroicons/optimized")
  @found File.dir?(@root)

  # Every variant is a key, with no names when the set was not found.
  @catalogue (for {suffix, dir} <- @variants, into: %{} do
                names =
                  case @found do
                    true ->
                      @root
                      |> Path.join(dir)
                      |> File.ls!()
                      |> Enum.filter(&String.ends_with?(&1, ".svg"))
                      |> Enum.map(&Path.basename(&1, ".svg"))
                      |> Enum.sort()

                    false ->
                      []
                  end

                {suffix, names}
              end)

  # The glyph files are read at compile time, here and in `@markup` below, so each is an external
  # resource: a `mix deps.update heroicons` then recompiles this module.
  for {suffix, dir} <- @variants, name <- Map.fetch!(@catalogue, suffix) do
    @external_resource @root |> Path.join(dir) |> Path.join(name <> ".svg")
  end

  @all for({suffix, names} <- @catalogue, name <- names, do: "hero-" <> name <> suffix)
       |> Enum.sort()

  @doc """
  Every icon class the set ships, sorted — `hero-academic-cap`, `hero-academic-cap-micro`, …
  """
  @spec all() :: [String.t()]
  @impl true
  def all, do: @all

  @doc "The bare names in one variant, without the `hero-` prefix or the suffix."
  @spec names(String.t()) :: [String.t()]
  def names(suffix \\ ""), do: Map.get(@catalogue, suffix, [])

  @doc "The variant suffixes, in the plugin's own order — outline first, because it is the default."
  @spec variants() :: [{String.t(), String.t()}]
  @impl true
  def variants do
    [
      {"", gettext("Outline")},
      {"-solid", gettext("Solid")},
      {"-mini", gettext("Mini")},
      {"-micro", gettext("Micro")}
    ]
  end

  @doc "Whether a catalogue was found at compile time. False means the picker degrades to a text box."
  @spec available?() :: boolean()
  def available?, do: @all != []

  @doc """
  One icon as inline SVG, sized to `size` pixels — `nil` when the set does not ship it.

  The source file's own `<svg>` attributes are kept (viewBox, fill, stroke-width), because a 20px
  solid icon and a 24px outline icon are drawn differently and a single hardcoded viewBox would
  squash half the set.
  """
  @spec svg(String.t(), pos_integer()) :: {:safe, iodata()} | nil
  @impl true
  def svg(name, size \\ 15)

  case @found do
    true ->
      # The MARKUP for each icon, read at compile time from the same files.
      #
      # The picker cannot render `<span class="hero-check">` and hope: those classes come from the
      # Tailwind heroicons plugin, which runs over the SITE's pages — the admin chrome's own CSS has no
      # reason to carry all 1,288 of them, and the grid rendered as a wall of filled squares. A picker
      # that cannot show what you are choosing is not a picker. The value it WRITES is still the class
      # name, because that is what the component renders with.
      @markup (for {suffix, dir} <- @variants,
                   name <- Map.fetch!(@catalogue, suffix),
                   into: %{} do
                 raw = @root |> Path.join(dir) |> Path.join(name <> ".svg") |> File.read!()

                 inner =
                   raw
                   |> String.replace(~r/^.*?<svg[^>]*>/s, "")
                   |> String.replace(~r{</svg>\s*$}, "")
                   |> String.trim()

                 attrs =
                   case Regex.run(~r/<svg([^>]*)>/, raw) do
                     [_all, found] -> found
                     _none -> ""
                   end

                 {"hero-" <> name <> suffix, {attrs, inner}}
               end)

      def svg(name, size) do
        case Map.get(@markup, name) do
          nil ->
            nil

          {attrs, inner} ->
            {:safe,
             [
               "<svg",
               attrs,
               ~s( width="#{size}" height="#{size}" aria-hidden="true">),
               inner,
               "</svg>"
             ]}
        end
      end

    false ->
      def svg(_name, _size), do: nil
  end

  @doc """
  CSS rules for the named icon classes, mirroring what the Tailwind heroicons plugin emits.

  The editor cannot rely on the site's compiled stylesheet for these. That stylesheet is generated
  from the classes the site's own pages RENDER, and a component's *default* icon appears in no page's
  HTML — so `chelekom-alert`'s `hero-chat-bubble-bottom-center-text` had a 28×28 box on the canvas
  with `mask-image: none` inside it, which reads as "the icon is broken" rather than "this class was
  never compiled".

  The rule is the plugin's own, restated: the SVG as a data URI mask, `currentColor` as the paint, and
  the plugin's size table (24px, or 20px for `-mini`, 16px for `-micro`). Only the classes actually
  in front of the reader are emitted — a few per page, not all 1,288.
  """
  @spec css([String.t()]) :: String.t()
  @impl true
  def css(names)

  case @found do
    true ->
      def css(names) do
        names
        |> Enum.uniq()
        |> Enum.filter(&Map.has_key?(@markup, &1))
        |> Enum.map_join("\n", &rule/1)
      end

      defp rule(name) do
        {attrs, inner} = Map.fetch!(@markup, name)
        svg = "<svg#{attrs}>#{inner}</svg>"
        uri = "url('data:image/svg+xml;utf8,#{URI.encode(svg, &URI.char_unreserved?/1)}')"
        size = size_for(name)

        ".#{name}{" <>
          "-webkit-mask:#{uri};mask:#{uri};" <>
          "-webkit-mask-repeat:no-repeat;mask-repeat:no-repeat;" <>
          "background-color:currentColor;vertical-align:middle;display:inline-block;" <>
          "width:#{size};height:#{size};}"
      end

      # The plugin's own table: 24px by default, 20px for `-mini`, 16px for `-micro`.
      defp size_for(name) do
        cond do
          String.ends_with?(name, "-mini") -> "1.25rem"
          String.ends_with?(name, "-micro") -> "1rem"
          true -> "1.5rem"
        end
      end

    false ->
      def css(_names), do: ""
  end

  @doc "Whether a value names an icon this set actually ships."
  @spec known?(String.t() | nil) :: boolean()
  def known?(name) when is_binary(name), do: name in @all
  def known?(_name), do: false

  @doc """
  The icons matching a query, capped.

  The query is matched against the name with its `hero-` prefix and variant suffix stripped, so
  "arrow" finds `hero-arrow-up` and `hero-arrow-up-solid` alike, and a reader who types the whole
  class name still finds it. An empty query returns the head of the list rather than nothing: an
  empty picker looks broken, and the first page of icons is a reasonable place to start browsing.
  """
  @spec search(String.t() | nil, keyword()) :: [String.t()]
  @impl true
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 60)
    variant = Keyword.get(opts, :variant, "")

    @catalogue
    |> Map.get(variant, [])
    |> filter(normalize(query))
    |> Enum.take(limit)
    |> Enum.map(&("hero-" <> &1 <> variant))
  end

  defp filter(names, ""), do: names
  defp filter(names, needle), do: Enum.filter(names, &String.contains?(&1, needle))

  defp normalize(nil), do: ""

  defp normalize(query) do
    query
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("hero-", "")
    |> String.replace(~r/\s+/, "-")
  end

  @doc """
  How many icons the query matches in a variant, for the picker's counter.

  Counted rather than `length(search(...))` because the search is capped — the count is what tells a
  reader their query is too broad, and a capped list cannot say so.
  """
  @spec count(String.t() | nil, String.t()) :: non_neg_integer()
  @impl true
  def count(query, variant \\ "") do
    @catalogue
    |> Map.get(variant, [])
    |> filter(normalize(query))
    |> length()
  end
end
