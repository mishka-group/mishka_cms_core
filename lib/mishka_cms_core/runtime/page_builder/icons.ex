defmodule MishkaCmsCore.Runtime.PageBuilder.Icons do
  @moduledoc """
  Every icon set the inspector can offer, as one catalogue.

  ## What changed and why

  This module used to BE the heroicon set. It is now a facade over
  `MishkaCmsCore.Runtime.PageBuilder.IconLibrary` implementations, of which
  `MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons` is the first — because an install that wants
  Lucide as well as Heroicons had nowhere to say so, and the class name already namespaces itself
  (`hero-check`, `lucide-check`), so several sets can coexist in one document without colliding.

  With one library registered, every function here answers exactly what that library answers. The
  picker looks and behaves as it did.

      config :mishka_cms_core, :icon_libraries, [
        MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons,
        MyApp.Icons.Lucide
      ]

  ## Routing

  By longest matching PREFIX, so `svg/2` and `css/1` reach the set that owns the class and nothing
  else has to be told which set a value came from. A class no registered set claims is not an error:
  `known?/1` answers false and the control keeps the value anyway, because an author may be naming an
  icon from a set this editor has never been told about — see
  `MishkaCmsCoreWeb.Live.Admin.Builder.Panels`, where the icon control accepts free text for exactly
  that reason.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled
  alias MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons

  @default [Heroicons]

  @doc """
  Every icon class named anywhere in `source`, for callers holding markup rather than a tree.

  AN ICON IS A CLASS, NOT A GLYPH — `<span class="hero-bell">` plus a CSS mask — so a token in the
  text is all there is to find. Anchored on the REGISTERED prefixes rather than on "anything
  kebab-shaped": `css/1` would drop the unclaimed ones anyway, and scanning every hyphenated token
  means offering tens of thousands of utilities a chance to match.

  Shared by `MishkaCmsCore.Runtime.Compilers.TailwindCompiler`, which asks it of a site's templates
  to decide what the bundle carries, by `MishkaCmsCore.Runtime.RuntimePreview`, which asks it of
  one rendered component so the preview can carry its icons without borrowing a bundle, and by
  `MishkaCmsCore.Runtime.ContentComponents.icons/1`, which asks it of stored content.
  """
  @spec classes_in(String.t()) :: [String.t()]
  def classes_in(source) when is_binary(source) do
    case class_pattern() do
      nil -> []
      pattern -> pattern |> Regex.scan(source) |> Enum.map(&hd/1) |> Enum.uniq()
    end
  end

  def classes_in(_source), do: []

  defp class_pattern do
    libraries()
    |> Enum.flat_map(& &1.prefixes())
    |> Enum.map(&Regex.escape/1)
    |> case do
      [] -> nil
      prefixes -> Regex.compile!("\\b(?:#{Enum.join(prefixes, "|")})[a-z0-9-]+")
    end
  end

  @doc """
  The registered libraries, in the order the picker offers them.

  Read at runtime so a host can register its own; each library's catalogue is still built at compile
  time inside that library, for the reason in `MishkaCmsCore.Runtime.PageBuilder.IconLibrary`.
  """
  @spec libraries() :: [module()]
  def libraries do
    configured =
      :mishka_cms_core
      |> Application.get_env(:icon_libraries, @default)
      |> Enum.filter(&Code.ensure_loaded?/1)

    # A kit that shipped its own glyphs registers ITSELF — no module to write, no config to edit.
    # See `MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled`.
    #
    # But only for prefixes nothing else already claims. Chelekom's bundle ships the `hero-` set, and
    # this install also compiles `Heroicons` from `deps/` — appending both would list every heroicon
    # twice and put a library row in the picker offering a choice between two identical sets. A
    # configured library is the more specific answer for its own prefix, so it wins; the bundle fills
    # the gaps, which is what a host with no `deps/heroicons` relies on entirely.
    claimed = configured |> Enum.flat_map(& &1.prefixes()) |> MapSet.new()

    # AND WHATEVER AN EXTENSION REGISTERED. A kit that ships its own glyphs can announce itself
    # through the same registry every other section uses, instead of asking the host to edit config.
    MishkaCmsCore.Builder.Events.collect_appended(
      :icon_libraries,
      case Bundled.available?() and
             Enum.any?(Bundled.prefixes(), &(not MapSet.member?(claimed, &1))) do
        true -> configured ++ [Bundled]
        false -> configured
      end
    )
  end

  @doc "Every icon class every registered set ships."
  @spec all() :: [String.t()]
  def all, do: libraries() |> Enum.flat_map(& &1.all()) |> Enum.uniq()

  @doc "Whether any registered set has a catalogue. False means the picker degrades to a text box."
  @spec available?() :: boolean()
  def available?, do: Enum.any?(libraries(), &(&1.all() != []))

  @doc """
  The variant suffixes to offer, as `{suffix, label}`.

  One library's own variants when only one is registered. With several, only the suffixes they SHARE
  are offered, because a variant button that half the results cannot honour reads as broken — a set
  with a single weight answers `[{"", "All"}]` and narrows the row to that.
  """
  @spec variants() :: [{String.t(), String.t()}]
  def variants do
    case libraries() do
      [] -> [{"", gettext("All")}]
      [one] -> one.variants()
      many -> many |> Enum.map(& &1.variants()) |> Enum.reduce(&shared/2)
    end
  end

  defp shared(variants, acc) do
    suffixes = MapSet.new(variants, &elem(&1, 0))
    Enum.filter(acc, fn {suffix, _label} -> MapSet.member?(suffixes, suffix) end)
  end

  @doc "Whether a value names an icon some registered set actually ships."
  @spec known?(String.t() | nil) :: boolean()
  def known?(name) when is_binary(name) do
    case library_for(name) do
      nil -> false
      library -> name in library.all()
    end
  end

  def known?(_name), do: false

  @doc "One icon as inline SVG at `size` pixels — `nil` when no registered set ships it."
  @spec svg(String.t() | nil, pos_integer()) :: {:safe, iodata()} | nil
  def svg(name, size \\ 15)

  def svg(name, size) when is_binary(name) do
    case library_for(name) do
      nil -> nil
      library -> library.svg(name, size)
    end
  end

  def svg(_name, _size), do: nil

  @doc """
  CSS rules for these classes, each from the set that owns it, inside Tailwind's `components` layer.

  The canvas emits these for the icons it is about to render: the site's compiled stylesheet is
  generated from the classes its own pages RENDER, so a component's default icon — or one used only
  by an example in the modal — has no rule and draws as an empty box.

  In the `components` layer so any utility on the icon (`size-3`, `[&_.icon]:size-5`) beats the
  set's default size. Opens with `layer_order/0`, so the block keeps that order wherever it lands
  first; put it ahead of any CSS that may declare a layer. `""` when no set ships any of them.
  """
  @spec css([String.t()]) :: String.t()
  def css(names) do
    names
    |> Enum.uniq()
    |> Enum.group_by(&library_for/1)
    |> Enum.reject(fn {library, _names} -> is_nil(library) end)
    |> Enum.map(fn {library, owned} -> library.css(owned) end)
    |> Enum.reject(&(&1 == ""))
    |> layered()
  end

  defp layered([]), do: ""
  defp layered(rules), do: "#{layer_order()}\n@layer components{\n#{Enum.join(rules, "\n")}\n}"

  @doc """
  Tailwind's own cascade-layer order, the statement `@import "tailwindcss"` opens with.

  For CSS that declares layers before any Tailwind stylesheet does; after one it changes nothing.
  """
  @spec layer_order() :: String.t()
  def layer_order, do: "@layer theme, base, components, utilities;"

  @doc """
  The icons matching a query, capped, across every registered set.

  `:library` restricts to one set; `:limit` caps the result. The cap is applied to the MERGED list so
  a second set cannot push the first out of the picker.
  """
  @spec search(String.t() | nil, keyword()) :: [String.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 60)
    variant = Keyword.get(opts, :variant, "")

    # ROUND-ROBIN, not concatenate-then-cut. `flat_map |> take` spends the whole limit on the first
    # library, so with heroicons registered a second set was unbrowsable: the grid showed the same 60
    # heroicons whatever else was installed, and only a search narrow enough to exhaust them let the
    # other set appear. Interleaving gives every set a share of a limit none of them can fill alone.
    opts
    |> chosen()
    |> Enum.map(& &1.search(query, limit: limit, variant: variant))
    |> interleave()
    |> Enum.take(limit)
  end

  defp interleave([]), do: []
  defp interleave([single]), do: single

  defp interleave(lists) do
    lists
    |> Enum.map(&Enum.with_index/1)
    |> Enum.concat()
    |> Enum.sort_by(fn {_name, index} -> index end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "How many match, uncapped — what tells a reader their query is too broad."
  @spec count(String.t() | nil, String.t(), keyword()) :: non_neg_integer()
  def count(query, variant \\ "", opts \\ []) do
    opts |> chosen() |> Enum.map(& &1.count(query, variant)) |> Enum.sum()
  end

  defp chosen(opts) do
    case Keyword.get(opts, :library) do
      nil -> libraries()
      library -> Enum.filter(libraries(), &(&1 == library))
    end
  end

  # Longest prefix wins, so a set registering `hero-solid-` alongside `hero-` still resolves.
  defp library_for(name) when is_binary(name) do
    for library <- libraries(), prefix <- library.prefixes(), String.starts_with?(name, prefix) do
      {String.length(prefix), library}
    end
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_length, library} -> library
    end
  end

  defp library_for(_name), do: nil
end
