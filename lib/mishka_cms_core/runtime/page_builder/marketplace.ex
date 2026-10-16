# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Marketplace do
  @moduledoc """
  Everything the Studio sheet shows — design tokens, presets, the package registry and snippets —
  behind one behaviour, so the panel is written once and the source can change underneath it.

  ADR-10. The default is `MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits`, which answers out of
  what is really on this server: its tokens are the site's own stylesheet declarations, its packages
  are the kit components on disk this site has NOT installed, and installing one runs the same
  dependency closure the first-run wizard does.

  It used to default to `Mock` — the design prototype's seed data — on the reasoning that a tab
  rendering its real, empty answer looks broken rather than unfinished. That reasoning outlived its
  truth. Three of the four questions now have real answers, so the sample catalogue was showing
  invented packages with prices beside an Install button that refuses, and invented presets beside an
  Apply that only flashes. An honest empty state is worth more than a convincing one that lies; the
  Presets tab says what it is missing and why.

  `Mock` is still here and still opt-in, because the prototype's seed data is what the design was
  drawn against:

      config :mishka_cms_core, :builder_marketplace,
        MishkaCmsCore.Runtime.PageBuilder.Marketplace.Mock

  A remote registry later is the same config change, not a UI change. The precedent is
  `UiKitHandler.ensure_bundle!/1`, which already does local-first-then-fetch for the component
  bundles.

      config :mishka_cms_core, :builder_marketplace, MyApp.RealMarketplace

  ## Token generators are real

  The four export formats are not mock-ups. `generate/2` emits a genuine `tailwind.config.js`
  theme.extend, a `:root` custom-property block, a W3C design-tokens JSON document and an Elixir
  theme module — ported line-for-line from the prototype's own generators. That is what makes the
  Studio's Copy button worth having before any backend exists.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token

  @callback tokens(String.t() | nil) :: [Token.t()]
  @callback presets(map()) :: [map()]
  @callback packages(map()) :: [map()]
  @callback snippets(map()) :: [map()]
  @callback install(atom(), String.t(), String.t() | nil, map() | nil) ::
              {:ok, map()} | {:error, term()}

  @formats [
    {:tw, gettext_noop("Tailwind"), "tailwind.config.js",
     gettext_noop("tailwind.config.js theme.extend")},
    {:css, gettext_noop("CSS vars"), "tokens.css", gettext_noop(":root custom properties")},
    {:json, gettext_noop("Tokens JSON"), "tokens.json", gettext_noop("W3C design-tokens format")},
    {:ex, gettext_noop("Elixir"), "theme.ex", gettext_noop("Generated module attributes")}
  ]

  @doc "The configured adapter — what is really on this server unless a host swaps it."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(
      :mishka_cms_core,
      :builder_marketplace,
      MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits
    )
  end

  @doc "The export formats the Studio offers: `{key, label, filename, hint}`."
  @spec formats() :: [{atom(), String.t(), String.t(), String.t()}]
  def formats do
    Enum.map(@formats, fn {key, label, filename, hint} ->
      {key, Gettext.gettext(MishkaCmsCore.Gettext, label), filename,
       Gettext.gettext(MishkaCmsCore.Gettext, hint)}
    end)
  end

  @doc "The design tokens the ADAPTER offers — sample data unless a host swaps it."
  @spec tokens(String.t() | nil) :: [Token.t()]
  def tokens(site_id \\ nil), do: adapter().tokens(site_id)

  @doc "Page presets available to install."
  @spec presets(map()) :: [map()]
  def presets(filters \\ %{}), do: adapter().presets(filters)

  @doc "Registry packages available to install."
  @spec packages(map()) :: [map()]
  def packages(filters \\ %{}), do: adapter().packages(filters)

  @doc """
  The categories the registry's packages actually fall into, in display order.

  Asked of the adapter when it can answer — `Kits` reads the kit catalogue's own groups — and
  derived from the packages themselves when it cannot, so an adapter written before this existed
  still gets chips that match its data. The Studio used to draw a list written out by hand; four of
  its six chips named categories no component has ever had, and picking one showed an empty registry
  under the words "everything is already installed".
  """
  @spec package_categories(map()) :: [String.t()]
  def package_categories(filters \\ %{}) do
    adapter = adapter()

    case MishkaGervaz.Helpers.exports?(adapter, :package_categories, 1) do
      true -> adapter.package_categories(filters)
      false -> filters |> packages() |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
    end
  end

  @doc "Saved snippets."
  @spec snippets(map()) :: [map()]
  def snippets(filters \\ %{}), do: adapter().snippets(filters)

  @doc """
  Installs a preset or a package.

  `actor` is who pressed it, and every row the install writes is written as them — see
  `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2`. `nil` is a real answer: a caller
  with no session behind it, such as a boot-time install, writes as the system, which is what this
  did for everybody before.

  WHICH SITE is not this argument's to decide on its own — see `install_scope/2` on the handler,
  which derives it from the actor, and which the Visual Editor calls before it gets here.
  """
  @spec install(atom(), String.t(), String.t() | nil, map() | nil) ::
          {:ok, map()} | {:error, term()}
  def install(kind, id, site_id \\ nil, actor \\ nil),
    do: adapter().install(kind, id, site_id, actor)

  @doc "The token categories present in a token list, in display order."
  @spec categories([Token.t()]) :: [String.t()]
  def categories(tokens) do
    order = ~w(color type space radius shadow motion screen)
    present = tokens |> Enum.map(& &1.category) |> Enum.uniq()
    Enum.filter(order, &(&1 in present)) ++ Enum.reject(present, &(&1 in order))
  end

  @doc """
  How a token is referenced in a given format — what the Studio shows beside each swatch so an
  author can paste it straight into the right place.
  """
  @spec reference(atom(), Token.t()) :: String.t()
  def reference(:css, token), do: "--" <> token.key
  def reference(:ex, token), do: "@" <> String.replace(token.key, "-", "_")
  def reference(:json, token), do: "{#{token.category}.#{short_key(token.key)}}"
  def reference(:tw, token), do: "theme.#{tailwind_group(token)}.#{short_key(token.key)}"

  defp tailwind_group(%{category: "color"}), do: "colors"
  defp tailwind_group(%{category: "space"}), do: "spacing"
  defp tailwind_group(%{category: "radius"}), do: "borderRadius"
  defp tailwind_group(%{category: "shadow"}), do: "boxShadow"
  defp tailwind_group(%{category: "screen"}), do: "screens"

  defp tailwind_group(%{category: "type", key: "font-" <> _rest}), do: "fontFamily"
  defp tailwind_group(%{category: "type"}), do: "fontSize"

  defp tailwind_group(%{category: "motion", key: "ease" <> _rest}),
    do: "transitionTimingFunction"

  defp tailwind_group(%{category: "motion"}), do: "transitionDuration"
  defp tailwind_group(_token), do: "extend"

  defp short_key(key), do: String.replace(key, ~r/^(radius|space|screen|duration|font)-/, "")

  @doc """
  Generates the export file for `format` from `tokens`.

  Returns the file's text. Ported from the prototype's own generators, so what the Studio copies is
  what the demo promised — a real config, not a screenshot of one.
  """
  @spec generate(atom(), [Token.t()]) :: String.t()
  def generate(:tw, tokens) do
    group = fn category -> Enum.filter(tokens, &(&1.category == category)) end

    entries = fn category, strip ->
      category
      |> group.()
      |> Enum.map_join("\n", fn token ->
        ~s(        '#{String.replace(token.key, strip, "")}': '#{token.value}',)
      end)
    end

    """
    module.exports = {
      theme: {
        extend: {
          colors: {
    #{entries.("color", "")}
          },
          spacing: {
    #{entries.("space", "space-")}
          },
          borderRadius: {
    #{entries.("radius", "radius-")}
          },
          screens: {
    #{entries.("screen", "screen-")}
          },
        },
      },
    }
    """
  end

  def generate(:css, tokens) do
    vars = Enum.map_join(tokens, "\n", &"  --#{&1.key}: #{&1.value};")

    """
    :root {
    #{vars}
    }

    /* usage */
    .btn { background: var(--iris); border-radius: var(--radius-md); }
    """
  end

  def generate(:json, tokens) do
    body =
      ~w(color space radius motion)
      |> Enum.map_join(",\n", fn category ->
        entries =
          tokens
          |> Enum.filter(&(&1.category == category))
          |> Enum.map_join(",\n", fn token ->
            ~s(    "#{short_key(token.key)}": { "$value": "#{token.value}", "$type": "#{json_type(category)}" })
          end)

        ~s(  "#{category}": {\n#{entries}\n  })
      end)

    "{\n#{body}\n}\n"
  end

  def generate(:ex, tokens) do
    attrs =
      tokens
      |> Enum.filter(&(&1.category in ["color", "radius"]))
      |> Enum.map_join("\n", &~s(  @#{String.replace(&1.key, "-", "_")} "#{&1.value}"))

    """
    defmodule MishkaWeb.Theme do
      @moduledoc "Generated from Studio tokens."
    #{attrs}

      def token(name), do: Map.get(tokens(), name)
    end
    """
  end

  defp json_type("color"), do: "color"
  defp json_type(_category), do: "dimension"
end
