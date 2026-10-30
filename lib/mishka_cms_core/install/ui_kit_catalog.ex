# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.UiKitCatalog do
  @moduledoc """
  Pure view of a `mishka.ui_kit.bundle.v3` for the installer's component picker: groups the
  components by `type` (one group per category however a kit spelled it, see `file_categories/2`),
  keeps only the light fields the picker needs (name / label / deps — never
  the heavy body/template/examples), and computes the transitive COMPONENT-dependency closure of a
  selection so required components can be locked.

  The bundle JSON has no "required" flag and `UiKitHandler` does not resolve dependencies itself, so
  the picker must derive "required" = the closure of the user's picks. Picking `chelekom-card` pulls
  in `chelekom-icon` (depended on by ~80 components), which the user then cannot unmark. `*.js` hook
  deps are ignored here — js_hooks and the stylesheet install in full regardless of the component
  selection — and the `chelekom-scroll_area` (underscore) vs `chelekom-scroll-area` (hyphen) naming
  mismatch is normalized.

  Per-component narrowing is offered along the axes variant/color/size/padding/space/rounded/border
  (in that display order). An axis is shown for a component only when the kit enumerates string values
  for it AND declares a string default — components whose axis (e.g. `size`) is numeric simply skip it.
  The axis name is used verbatim as the `:selection` per-component key, which `UiKitHandler` accepts;
  the picker pre-checks and locks the kit-declared default. Components install minimal by default
  (their own default value), and `config_extras` widens chosen axes to `[default | extras]`.

  See `MishkaCmsCore.Runtime.Handlers.UiKitHandler` and `MishkaCmsWeb.InstallLive`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @config_axes ~w(variant color size padding space rounded border)

  @group_order ~w(general forms navigations media feedback overlays)
  @group_labels %{
    "general" => gettext_noop("General"),
    "forms" => gettext_noop("Forms"),
    "navigations" => gettext_noop("Navigation"),
    "media" => gettext_noop("Media"),
    "feedback" => gettext_noop("Feedback"),
    "overlays" => gettext_noop("Overlays")
  }

  @type axis_config :: %{values: [String.t()], default: String.t() | nil}
  @type entry :: %{
          name: String.t(),
          label: String.t(),
          kit: String.t() | nil,
          type: String.t(),
          deps: [String.t()],
          required?: boolean(),
          config: %{optional(String.t()) => axis_config()}
        }
  @type group :: %{key: String.t(), label: String.t(), entries: [entry()]}
  @type t :: %{groups: [group()], index: %{optional(String.t()) => entry()}, names: MapSet.t()}

  @doc "Builds the picker catalog (groups + name index + dependency graph) from a parsed v3 bundle."
  @spec build(map()) :: t()
  def build(bundle) do
    components = Map.get(bundle, "components", [])
    names = MapSet.new(components, &Map.get(&1, "name"))
    kit = Map.get(bundle, "name")

    entries =
      Enum.map(components, fn component ->
        name = Map.get(component, "name")

        %{
          name: name,
          label: label(name, kit),
          kit: kit,
          type: Map.get(component, "type", "general"),
          deps: component_deps(component, names),
          required?: Map.get(component, "required", false) == true,
          config: config_features(component)
        }
      end)

    %{
      groups: build_groups(entries),
      index: Map.new(entries, &{&1.name, &1}),
      names: names
    }
  end

  @doc """
  The transitive component-dependency closure of `selected` that the user did NOT explicitly pick —
  i.e. the components that must be installed and locked in the UI. `install_set/2` adds the picks back.
  """
  @spec required_closure(t(), Enum.t()) :: MapSet.t()
  def required_closure(catalog, selected) do
    selected = MapSet.new(selected)

    selected
    |> Enum.reduce(mandatory(catalog), &collect_deps(catalog, &1, &2))
    |> MapSet.difference(selected)
  end

  @doc """
  The components the kit declares the CMS cannot run without, whatever the operator picked.

  `deps` answers "this component needs that one"; `required` answers "this install needs it at all".
  An icon is drawn by half of Chelekom's other components and nothing in the markup says so, so
  deselecting it left the rest unable to render — and the picker had no way to know.

  Seeded into the dependency closure rather than checked separately, so it is locked in the UI and
  installed by the same path a dependency is.
  """
  @spec mandatory(t()) :: MapSet.t()
  def mandatory(catalog) do
    for {name, entry} <- catalog.index, entry[:required?], into: MapSet.new(), do: name
  end

  @doc "The full set of components to install: the user's picks plus their required closure."
  @spec install_set(t(), Enum.t()) :: MapSet.t()
  def install_set(catalog, selected) do
    selected = MapSet.new(selected)
    MapSet.union(selected, required_closure(catalog, selected))
  end

  @doc """
  Builds the `:selection` map for `UiKitHandler.install_chelekom!/1` from the picked components and the
  per-component variant config.

  Every component installs **minimal by default** — narrowed to its OWN default variant/color (the
  kit's defaults are not uniform: `color` defaults to `natural` for ~half the components, `base` for
  others — so a global "base only" would render those bare). `config_extras` (`%{component_name =>
  %{axis => [extra_values]}}`) widens individual components: e.g. adding `danger` to `button`'s color
  installs that component with `[natural, danger]`. Axes without a usable default, or with no extras
  on components that have no enumerable values, simply install full.
  """
  @spec install_selection(t(), Enum.t(), %{optional(String.t()) => map()}) :: map()
  def install_selection(catalog, selected, config_extras \\ %{}) do
    components = install_set(catalog, selected)

    per_component =
      Map.new(components, fn name ->
        entry = Map.get(catalog.index, name, %{config: %{}})
        extras = Map.get(config_extras, name, %{})
        {label(name), narrow_axes(entry.config, extras)}
      end)

    %{components: MapSet.to_list(components), per_component: per_component}
  end

  @doc """
  The same selection, split per kit — what `UiKitHandler.install_kits!/2` takes.

  With one kit installed this is the single-kit map under one key, and behaves exactly as before.
  With two, each kit gets only its own components: the labels a selection is keyed by (`alert`,
  `tree`) are unique per kit but not across kits, so a flat map would install one kit's narrowing
  onto another kit's component of the same name.
  """
  @spec install_selection_by_kit(t(), Enum.t(), %{optional(String.t()) => map()}) :: map()
  def install_selection_by_kit(catalog, selected, config_extras \\ %{}) do
    components = install_set(catalog, selected)

    components
    |> Enum.group_by(&kit_of(catalog, &1))
    |> Map.new(fn {kit, names} ->
      per_component =
        Map.new(names, fn name ->
          entry = Map.get(catalog.index, name, %{config: %{}})
          extras = Map.get(config_extras, name, %{})
          {label(name, kit), narrow_axes(entry.config, extras)}
        end)

      {kit, %{components: names, per_component: per_component}}
    end)
  end

  defp kit_of(catalog, name) do
    catalog.index
    |> Map.get(name, %{})
    |> Map.get(:kit)
  end

  @doc """
  One catalogue over several bundles, for an installer that offers more than one kit.

  Entries keep their FULL component name, which is unique across kits, so the picker's selection set
  and dependency closure keep working unchanged; only the labels and the install selection need to
  know which kit an entry came from.
  """
  @spec merge([map()]) :: t()
  def merge(bundles) do
    catalogs = Enum.map(bundles, &build/1)

    %{
      groups: merge_groups(catalogs),
      index: catalogs |> Enum.map(& &1.index) |> Enum.reduce(%{}, &Map.merge(&2, &1)),
      names: catalogs |> Enum.map(& &1.names) |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))
    }
  end

  # Each kit's groups are filed again over all the kits at once: one kit's `button` sits under
  # another's `buttons` only when both are on the table.
  defp merge_groups(catalogs) do
    groups = Enum.flat_map(catalogs, & &1.groups)
    filed = file_categories(Enum.map(groups, & &1.key), @group_order)

    groups
    |> Enum.group_by(&Map.fetch!(filed, &1.key))
    |> Enum.map(fn {key, groups} ->
      %{
        key: key,
        label: group_label(key),
        entries: groups |> Enum.flat_map(& &1.entries) |> Enum.sort_by(& &1.label)
      }
    end)
    |> Enum.sort_by(&group_position(&1.key))
  end

  defp group_position(key) do
    case Enum.find_index(@group_order, &(&1 == key)) do
      nil -> length(@group_order)
      index -> index
    end
  end

  @doc "The selected components that force `name` into the required set (for a 'required by …' hint)."
  @spec required_by(t(), Enum.t(), String.t()) :: [String.t()]
  def required_by(catalog, selected, name) do
    selected
    |> Enum.filter(fn picked ->
      name in MapSet.to_list(collect_deps(catalog, picked, MapSet.new()))
    end)
    |> Enum.map(&label/1)
    |> Enum.sort()
  end

  @doc "Strips the kit prefix for display (`chelekom-card` -> `card`)."
  @spec label(String.t()) :: String.t()
  def label(name), do: label(name, nil)

  @doc """
  The same, told which kit shipped the component.

  The kit's own name is the prefix, and `Component` SLUGIFIES what it stores — a bundle named
  `chelekom_headless` installs `chelekom-headless-tree`, so stripping at the first hyphen would
  leave "headless-tree". Given the kit, the whole prefix comes off and the label is "tree".
  """
  @spec label(String.t(), String.t() | nil) :: String.t()
  def label(name, nil) do
    case String.split(name, "-", parts: 2) do
      [_kit, rest] -> rest
      [only] -> only
    end
  end

  def label(name, kit) do
    prefix = slug(kit) <> "-"

    case String.starts_with?(name, prefix) do
      true -> String.replace_prefix(name, prefix, "")
      false -> label(name, nil)
    end
  end

  @doc """
  A kit's own name, as a person would read it: `chelekom_headless` -> "Chelekom Headless".

  Used by the installer's kit chips and the badge beside a component, both of which only appear once
  a second kit is on disk.
  """
  @spec kit_label(String.t() | atom() | nil) :: String.t()
  def kit_label(nil), do: ""

  def kit_label(kit) do
    kit
    |> to_string()
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp slug(kit), do: kit |> to_string() |> String.downcase() |> String.replace("_", "-")

  defp collect_deps(catalog, name, acc) do
    catalog.index
    |> Map.get(name, %{deps: []})
    |> Map.fetch!(:deps)
    |> Enum.reduce(acc, fn dep, acc ->
      if MapSet.member?(acc, dep) do
        acc
      else
        collect_deps(catalog, dep, MapSet.put(acc, dep))
      end
    end)
  end

  defp component_deps(component, names) do
    component
    |> Map.get("dependencies", [])
    |> Enum.map(&normalize/1)
    |> Enum.filter(&MapSet.member?(names, &1))
    |> Enum.uniq()
  end

  defp normalize(dep) do
    dep
    |> String.replace_suffix(".js", "")
    |> String.replace("_", "-")
  end

  defp config_features(component) do
    features = UiKitHandler.component_features(component)
    defaults = attr_defaults(component)

    # ELIGIBILITY IS STRUCTURAL, ORDER IS TASTE. `@config_axes` is Chelekom's seven most frequent
    # attribute names, and treating that list as the definition of "configurable" meant a kit whose
    # knobs are `tone`/`density` got no options panel at all — no sliders icon, no error, no
    # explanation — and therefore installed UNNARROWED, which is the opposite of what the list is
    # for. The guards below are what actually decide pickability, and they name nothing.
    for {axis, values} <- features,
        is_list(values),
        values != [],
        Enum.all?(values, &is_binary/1),
        default = Map.get(defaults, axis),
        is_binary(default),
        into: %{} do
      {axis, %{values: values, default: default}}
    end
  end

  @doc """
  The order the installer shows configurable axes in, most-recognised first.

  Kept as a SORT KEY rather than a filter — see `config_features/1`. An axis this list has never
  heard of sorts after the ones it has, which is the only thing the order was ever for. Public so
  the installer reads it here instead of holding a second copy.
  """
  @spec axis_order() :: [String.t()]
  def axis_order, do: @config_axes

  @doc "Sorts axes by `axis_order/0`, with anything unlisted after, then alphabetically."
  @spec sort_axes(Enum.t()) :: [{String.t(), term()}]
  def sort_axes(axes) do
    Enum.sort_by(axes, fn {axis, _config} ->
      {Enum.find_index(@config_axes, &(&1 == axis)) || length(@config_axes), axis}
    end)
  end

  defp attr_defaults(component) do
    for attr <- Map.get(component, "attrs", []), into: %{} do
      {attr["name"], get_in(attr, ["opts", "default"])}
    end
  end

  # NARROWING IS THE POINT, and it follows the picker exactly: every axis the installer OFFERS is cut
  # to its default plus whatever the operator added. Opening the eligible set in `config_features/1`
  # therefore widens what gets narrowed too — but an axis is only eligible once it has a real string
  # default, so the cut can never leave a component with no clause to match.
  defp narrow_axes(config, extras) do
    for {axis, %{default: default}} <- config, into: %{} do
      added = extras |> Map.get(axis, []) |> Enum.to_list()
      {axis, Enum.uniq([default | added])}
    end
  end

  defp group_label(type) do
    case Map.fetch(@group_labels, type) do
      {:ok, label} -> Gettext.gettext(MishkaCmsCore.Gettext, label)
      :error -> String.capitalize(type)
    end
  end

  defp build_groups(entries) do
    filed = file_categories(Enum.map(entries, & &1.type), @group_order)
    by_key = Enum.group_by(entries, &Map.fetch!(filed, &1.type))

    @group_order
    |> Enum.concat(Map.keys(by_key))
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(by_key, &1))
    |> Enum.map(fn key ->
      %{
        key: key,
        label: group_label(key),
        entries: by_key |> Map.fetch!(key) |> Enum.sort_by(& &1.label)
      }
    end)
  end

  @doc """
  Files each category under one spelling, decided over all of them at once: a map from every
  category as a kit wrote it to the key it is filed under.

  KITS DO NOT AGREE ON THE WORDS. Chelekom's headless kit wrote `data display` on eight components
  and `data-display` on four, and `navigation` where its styled kit writes `navigations`, so a
  picker or a palette that grouped by the word as written drew each category twice, each heading
  holding half of it.

  Case, spaces, hyphens and underscores are one spelling (`category_key/1`), and a category that
  sits beside its own plural is filed under the plural, the form most kits use. `known` are
  spellings that count as present whether or not a kit wrote them — the installer passes its own
  group order, so a kit that only ever says `navigation` still lands in the picker's `navigations`.

      iex> MishkaCmsCore.Install.UiKitCatalog.file_categories(["data-display", "Data display"])
      %{"data-display" => "data display", "Data display" => "data display"}

      iex> MishkaCmsCore.Install.UiKitCatalog.file_categories(["navigation", "navigations"])
      %{"navigation" => "navigations", "navigations" => "navigations"}
  """
  @spec file_categories(Enum.t(), Enum.t()) :: %{optional(term()) => String.t()}
  def file_categories(categories, known \\ []) do
    spellings = known |> Enum.concat(categories) |> MapSet.new(&category_key/1)

    Map.new(categories, fn category ->
      key = category_key(category)
      plural = key <> "s"
      {category, (MapSet.member?(spellings, plural) && plural) || key}
    end)
  end

  @doc """
  One category's spelling with case, spaces, hyphens and underscores folded: `Data-Display`,
  `data_display` and `data  display` are all `data display`. A component with no category is
  `general`, as the installer has always filed it.
  """
  @spec category_key(String.t() | atom() | nil) :: String.t()
  def category_key(category) do
    (category || "")
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[\s_-]+/u, trim: true)
    |> Enum.join(" ")
    |> case do
      "" -> "general"
      key -> key
    end
  end
end
