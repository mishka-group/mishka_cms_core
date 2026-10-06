defmodule MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled do
  @moduledoc """
  Icon sets that arrived INSIDE an installed kit, needing no code and no configuration.

  ## Why this exists

  `MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons` reads `deps/heroicons` at compile time, which
  means a second icon set needed a second module and a line of config. That is the wrong shape for a
  CMS: installing a kit should be enough. Nobody adding Lucide to their site should have to write an
  Elixir module to see its glyphs in the picker.

  A kit that ships its glyphs in its bundle needs neither. `mix mishka.ui.export` writes them under a
  top-level `icons` key, `MishkaCmsCore.Runtime.Handlers.UiKitHandler` leaves that file in
  `priv/cms_ui_kits/`, and this module reads it.

  ## Why reading a file at runtime is safe here, and was not for heroicons

  The constraint that forced heroicons to compile-time is that `deps/` is a BUILD artefact — it does
  not exist in a release. `priv/` does: it is shipped, it is exactly where the installed bundles
  already live, and the CMS reads them at runtime anyway. So the same instinct that was right for
  `deps/` is unnecessary here.

  ## Caching

  The glyphs are ~0.7 MB per set and the picker asks on every keystroke, so the parse happens once
  into `:persistent_term`. That is the right store rather than ETS: written once at first read,
  read from every process with no copy, and the cost of a write — a global GC — is paid one time.
  `refresh/0` clears it, which is what an install calls after replacing a bundle.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @behaviour MishkaCmsCore.Runtime.PageBuilder.IconLibrary

  @key {__MODULE__, :sets}

  @all_variants gettext_noop("All")

  @impl true
  def prefixes, do: Enum.map(sets(), & &1.prefix)

  @impl true
  def label do
    case sets() do
      [set] -> set.label
      _many -> gettext("Bundled")
    end
  end

  @impl true
  def all, do: Enum.flat_map(sets(), &Map.keys(&1.glyphs)) |> Enum.sort()

  @impl true
  def variants do
    case sets() do
      [] -> []
      [set | _rest] -> Enum.map(set.variants, &translate_variant/1)
    end
  end

  defp translate_variant({suffix, @all_variants}),
    do: {suffix, Gettext.gettext(MishkaCmsCore.Gettext, @all_variants)}

  defp translate_variant(variant), do: variant

  @impl true
  def svg(name, size \\ 15)

  def svg(name, size) when is_binary(name) do
    case glyph(name) do
      nil -> nil
      raw -> {:safe, [sized(raw, size)]}
    end
  end

  def svg(_name, _size), do: nil

  @impl true
  def css(names) do
    names
    |> Enum.uniq()
    |> Enum.filter(&glyph/1)
    |> Enum.map_join("\n", &rule/1)
  end

  @impl true
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 60)
    variant = Keyword.get(opts, :variant, "")

    # A SHARE PER SET, not one sorted list cut at the limit. Every bundle's glyphs live behind this
    # one library, and Chelekom's bundle carries 1,288 heroicons — so a kit adding a dozen of its own
    # under a prefix sorting after `hero-` never appeared in a 60-icon grid however many it shipped.
    # Its own author would search its prefix and find them, and everyone else would conclude the kit
    # had no icons.
    sets()
    |> Enum.map(fn set ->
      set.glyphs
      |> Map.keys()
      |> Enum.sort()
      |> Enum.filter(&matches?(&1, variant, normalize(query)))
    end)
    |> interleave()
    |> Enum.take(limit)
  end

  defp interleave([]), do: []
  defp interleave([single]), do: single

  defp interleave(lists) do
    lists
    |> Enum.flat_map(&Enum.with_index/1)
    |> Enum.sort_by(fn {_name, index} -> index end)
    |> Enum.map(&elem(&1, 0))
  end

  @impl true
  def count(query, variant \\ "") do
    all() |> Enum.count(&matches?(&1, variant, normalize(query)))
  end

  @doc """
  Whether any installed kit shipped an icon set at all.

  False on a stock install, which is why the facade must not offer this library then — an empty set
  in the picker's library row is a button that finds nothing.
  """
  @spec available?() :: boolean()
  def available?, do: sets() != []

  @doc "Drops the cache, so the next read sees a bundle that has just been installed or replaced."
  @spec refresh() :: :ok
  def refresh, do: :persistent_term.erase(@key) && :ok

  # A name matches when it sits in the asked-for WEIGHT and contains the needle with its prefix and
  # suffix stripped, so "arrow" finds `lucide-arrow-up` and someone typing the whole class still
  # finds it. The empty variant means "no suffix", not "any".
  defp matches?(name, variant, needle) do
    weight_of(name) == variant and String.contains?(bare(name), needle)
  end

  defp weight_of(name) do
    suffixes =
      sets()
      |> Enum.flat_map(& &1.variants)
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort_by(&(-String.length(&1)))

    Enum.find(suffixes, "", &String.ends_with?(name, &1))
  end

  defp bare(name) do
    stripped = String.replace_suffix(name, weight_of(name), "")

    Enum.reduce(prefixes(), stripped, &String.replace_prefix(&2, &1, ""))
  end

  defp normalize(nil), do: ""

  defp normalize(query) do
    query |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "-")
  end

  defp glyph(name) when is_binary(name) do
    Enum.find_value(sets(), fn set -> Map.get(set.glyphs, name) end)
  end

  defp glyph(_name), do: nil

  # The source file's own `<svg>` attributes are kept — viewBox, fill, stroke-width — because a 20px
  # solid glyph and a 24px outline one are drawn differently and one hardcoded viewBox squashes half
  # the set. Only the dimensions are replaced.
  defp sized(raw, size) do
    raw
    |> String.replace(~r/\s(width|height)="[^"]*"/, "")
    |> String.replace(~r/^<svg/, ~s(<svg width="#{size}" height="#{size}"))
  end

  # The rule a Tailwind icon plugin emits, restated: the SVG as a data-URI mask painted with
  # `currentColor`. Without it the class renders as an empty box on the canvas.
  defp rule(name) do
    uri =
      "url('data:image/svg+xml;utf8,#{URI.encode(glyph(name), &URI.char_unreserved?/1)}')"

    ".#{name}{-webkit-mask:#{uri};mask:#{uri};" <>
      "-webkit-mask-repeat:no-repeat;mask-repeat:no-repeat;" <>
      "background-color:currentColor;vertical-align:middle;display:inline-block;" <>
      "width:1.5rem;height:1.5rem;}"
  end

  defp sets do
    case :persistent_term.get(@key, nil) do
      nil ->
        loaded = load()
        :persistent_term.put(@key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp load do
    kits_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&read/1)
  end

  # A bundle is a third party's file — see `MishkaCmsCore.UiKit.Contract`. One that cannot be read,
  # or whose `icons` block is the wrong shape, costs its own icon set and nothing else.
  defp read(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"icons" => icons}} <- Jason.decode(raw),
         %{"prefix" => prefix, "glyphs" => glyphs} when is_binary(prefix) and is_map(glyphs) <-
           icons,
         true <- map_size(glyphs) > 0 do
      [
        %{
          prefix: prefix,
          label: Map.get(icons, "label", prefix),
          glyphs: glyphs,
          variants: variants_of(icons)
        }
      ]
    else
      _no_icons -> []
    end
  end

  # Written as pairs because the order is meaningful — outline first, since it is the default weight.
  defp variants_of(%{"variants" => variants}) when is_list(variants) do
    for [suffix, label] <- variants, is_binary(suffix), is_binary(label), do: {suffix, label}
  end

  defp variants_of(_icons), do: [{"", @all_variants}]

  defp kits_dir, do: MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()
end
