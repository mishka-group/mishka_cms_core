defmodule MishkaCmsCore.Runtime.PageBuilder.IconLibrary do
  @moduledoc """
  What an icon set has to answer so the inspector can offer it.

  ## Why a behaviour rather than one hardcoded set

  An icon attribute's value is a **class name** — `hero-check`, and tomorrow `lucide-check` or
  `tabler-check`. The class already carries its own namespace, so several sets can coexist in one
  document without colliding; what was missing was anywhere for the editor to learn about the second
  one. `MishkaCmsCore.Runtime.PageBuilder.Icons` is now a facade over every registered set, and
  `MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons` is simply the first.

  ## Registering one

      config :mishka_cms_core, :icon_libraries, [
        MishkaCmsCore.Runtime.PageBuilder.Icons.Heroicons,
        MyApp.Icons.Lucide
      ]

  The list is read at runtime, but each library's own catalogue must be built at COMPILE time. That
  is not a style preference: `deps/` is a build artefact that a release does not ship, while the
  class names a release renders are baked into its CSS. A library that walks `deps/` at runtime works
  in dev and returns an empty picker in production.

  ## What a library owes the editor

  Two things the panel cannot do for itself. `svg/2` draws the glyph in the picker — the picker
  cannot render `<span class="hero-check">` and hope, because that class comes from a Tailwind plugin
  that runs over the SITE's pages and the admin chrome has no reason to carry it. And `css/1` emits
  the rule for a class the canvas is about to render, for the same reason: a component's *default*
  icon appears in no page's HTML, so the site stylesheet never learned it.

  ## Prefixes

  The facade routes by LONGEST matching prefix, so two libraries claiming `hero-` and `hero-solid-`
  resolve unambiguously — the more specific one wins. Use the prefix the set's own Tailwind plugin
  emits.
  """

  @doc """
  The class-name prefixes this library owns — `["hero-"]`.

  A LIST because one module may serve several sets: `MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled`
  answers for every set that arrived inside an installed kit, and there is no reason for each of those
  to need a module of its own.
  """
  @callback prefixes() :: [String.t()]

  @doc "What to call the set in the picker when more than one is installed — `\"Heroicons\"`."
  @callback label() :: String.t()

  @doc "Every class this set ships, sorted."
  @callback all() :: [String.t()]

  @doc """
  The weight variants, as `{suffix, label}` — `{\"\", \"Outline\"}`, `{\"-solid\", \"Solid\"}`.

  A set with one weight answers `[{\"\", \"All\"}]`.
  """
  @callback variants() :: [{String.t(), String.t()}]

  @doc "One icon as inline SVG at `size` pixels, or `nil` when this set does not ship it."
  @callback svg(String.t(), pos_integer()) :: {:safe, iodata()} | nil

  @doc "CSS rules for these classes, mirroring what the set's own Tailwind plugin emits."
  @callback css([String.t()]) :: String.t()

  @doc "The classes matching a query in one variant, capped by `:limit`."
  @callback search(String.t() | nil, keyword()) :: [String.t()]

  @doc "How many match, uncapped — the picker's counter cannot be derived from a capped list."
  @callback count(String.t() | nil, String.t()) :: non_neg_integer()
end
