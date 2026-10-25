# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Presets do
  @moduledoc """
  What a component should look like the moment it lands on a page — this site's answer, not the
  kit's.

  A kit ships one default per component and it is the same default for everyone. A site almost
  always has its own: every button here is outlined, every alert is `danger`, every card is large.
  Without somewhere to say so, that is retyped in the inspector after every single drop, and the one
  that gets forgotten is the one that ships.

  ## What a preset is

  Exactly the wizard's choices — `%{"variant" => "outline", "size" => "large"}` — kept per site and
  per component, and handed to `MishkaCmsCore.Runtime.PageBuilder.Wizard.compose/3` when the
  component is placed. So a preset can only ever say things the kit already understands: an option
  the component does not declare is dropped by the wizard rather than written into the page as
  markup nothing can render.

  ## Where it lives

  In `MishkaCmsCore.Settings`, under `builder:preset:<component>`, scoped to the site. That buys the
  RAM cache, the per-site override, the authorization and the audit trail without a resource of its
  own — and a preset is exactly what settings are for: a small, site-wide preference that changes
  what the software does next time.

  Global components are keyed by name like any other. Two sites therefore keep separate presets for
  the same shared component, which is the point of them.
  """

  alias MishkaCmsCore.Runtime.PageBuilder.Wizard
  alias MishkaCmsCore.Settings

  @prefix "builder:preset:"

  @doc "Setting key one component's preset is stored under."
  @spec key(String.t()) :: String.t()
  def key(name), do: @prefix <> name

  @doc """
  This site's preset for a component, or `%{}` when it has none.

  Never raises and never returns anything but a map: a hand-edited setting holding a list, a number
  or malformed JSON reads as "no preset", because placing a component must not depend on a settings
  row being well formed.
  """
  @spec get(String.t() | nil, String.t()) :: map()
  def get(site_id, name) when is_binary(name) do
    case Settings.get(key(name), nil, site_id) do
      value when is_map(value) -> strings(value)
      value when is_binary(value) -> decode(value)
      _absent -> %{}
    end
  end

  def get(_site_id, _name), do: %{}

  @doc """
  Records the choices a component should start from on this site.

  An empty map CLEARS it rather than storing "nothing chosen" — pressing the button with everything
  back at its kit default plainly means "forget my default", and a stored empty map would answer
  every later read with a preset that does nothing.
  """
  @spec put(map(), String.t() | nil, String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(actor, site_id, name, choices) when is_map(choices) do
    case usable(choices) do
      empty when map_size(empty) == 0 -> clear(actor, site_id, name)
      kept -> write(actor, site_id, name, kept)
    end
  end

  @doc "Forgets this site's preset for a component."
  @spec clear(map(), String.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def clear(actor, site_id, name), do: write(actor, site_id, name, %{})

  @doc """
  The HEEx to place for a component, with this site's preset applied.

  The one place that decides what a drop produces. `Wizard.compose/3` is what writes the attributes,
  so a preset goes through the same validation an author's own wizard choice does — and a component
  with no preset, or one the wizard has nothing to say about, falls back to the plain template.

  `components` is the palette, which decides whether a component calling another owns a form.
  """
  @spec template(map(), String.t() | nil, String.t() | nil | map(), [map()]) :: String.t()
  def template(entry, site_name, site_id_or_presets, components \\ [])

  def template(entry, site_name, site_id, components) when is_binary(site_id) or is_nil(site_id),
    do: with_choices(entry, site_name, get(site_id, entry.name), components)

  # THE PALETTE PASSES THE WHOLE MAP. A card's `data-template` is what a DRAG carries, and LiveView
  # only recomputes it when an assign it reads has changed — reading the settings cache per card
  # would leave the drag on a stale template until something else happened to re-render the panel,
  # so the presets arrive as one assign that changes when a preset is saved.
  def template(entry, site_name, %{} = presets, components),
    do: with_choices(entry, site_name, Map.get(presets, entry.name, %{}), components)

  @doc "Every preset for a list of palette entries, as `%{name => choices}` — one assign, one render."
  @spec for_entries([map()], String.t() | nil) :: map()
  def for_entries(entries, site_id) do
    entries
    |> Enum.map(&{&1.name, get(site_id, &1.name)})
    |> Enum.reject(fn {_name, choices} -> choices == %{} end)
    |> Map.new()
  end

  defp with_choices(entry, site_name, choices, components) when map_size(choices) == 0,
    do: MishkaCmsCore.Builder.PaletteEntry.template(entry, site_name, components)

  defp with_choices(entry, site_name, choices, components),
    do: Wizard.compose(entry, choices, site_name, :blank, components)

  # A setting's value column is a map, so the choices go in as they are. The string clause on `get/2`
  # is for a row someone hand-edited into JSON, not for anything written here.
  defp write(actor, site_id, name, choices) do
    Settings.put_as(actor, key(name), choices,
      site_id: site_id,
      category: "builder",
      description: "How #{name} starts on this site",
      editable?: false
    )
  end

  # The wizard posts every axis, including the ones left alone. Storing those would freeze today's
  # kit default into the site's preset, so tomorrow's kit update would not reach the page.
  defp usable(choices) do
    choices
    |> strings()
    |> Enum.reject(fn {_name, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp strings(map) do
    Map.new(map, fn {name, value} -> {to_string(name), value} end)
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> strings(map)
      _unreadable -> %{}
    end
  end
end
