# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Marketplace.Kits do
  @moduledoc """
  A `MishkaCmsCore.Runtime.PageBuilder.Marketplace` adapter over the registry this install actually
  has: the UI-kit bundles sitting on disk.

  The Studio's Registry tab was written against a catalogue of things to fetch, and with no remote
  registry configured its Install button had nothing to install. But an install DOES have a real
  set of components it could add and has not — a site is normally set up with a subset of a kit,
  and the other 100 components of that kit are exactly "a package available to install".

  So a package here is one uninstalled kit component, and installing it is the same operation the
  first-run wizard performs: the component **plus its dependency closure**, through
  `MishkaCmsCore.Install.UiKitCatalog.install_set/2` and `UiKitHandler.install_kits!/2`. Picking
  `card` brings `icon` with it, because a card that cannot draw its icon is not installed.

  What this adapter does NOT do is invent presets. A preset is a page layout and a token set, and
  nothing on disk supplies one — `presets/1` and `snippets/1` therefore return nothing, and the
  Studio says so rather than showing sample cards.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  @behaviour MishkaCmsCore.Runtime.PageBuilder.Marketplace

  alias MishkaCmsCore.Install.UiKitCatalog
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token
  alias MishkaCmsCore.Runtime.PageBuilder.Tokens

  require Ash.Query

  # The registry list is a browsing surface, not an inventory: a kit has 136 components and a page of
  # them is what someone reads before they search.
  @page 60

  @impl true
  def tokens(site_id), do: Enum.map(Tokens.list(site_id), &to_token/1)

  # A preset rewrites layout AND tokens together, and no bundle on disk carries one.
  @impl true
  def presets(_filters), do: []

  # Snippets have their own store — `MishkaCmsCore.Runtime.PageBuilder.Snippets` — because they are
  # this install's own content rather than something a registry offers.
  @impl true
  def snippets(_filters), do: []

  @impl true
  def packages(filters) do
    site_id = Map.get(filters, :site_id) || Map.get(filters, "site_id")
    installed = installed_names(site_id)
    catalog = catalog()

    catalog
    |> entries()
    |> Enum.reject(&MapSet.member?(installed, &1.name))
    |> filter_category(filters)
    |> Enum.sort_by(& &1.name)
    |> Enum.take(@page)
    |> Enum.map(&package(&1, catalog))
  end

  @impl true
  def install(:package, id, site_id, actor) do
    catalog = catalog()

    case MapSet.member?(catalog.names, id) do
      false ->
        {:error,
         {:not_available, gettext("%{id} is not in any kit installed on this server.", id: id)}}

      true ->
        closure = UiKitCatalog.install_set(catalog, [id])
        selection = UiKitCatalog.install_selection_by_kit(catalog, closure, %{})

        UiKitHandler.install_kits!(Map.keys(selection),
          site_id: site_id,
          selection: selection,
          actor: actor
        )

        {:ok, %{installed: MapSet.to_list(closure)}}
    end
  end

  def install(kind, id, _site_id, _actor),
    do:
      {:error,
       {:not_available,
        gettext("%{kind} %{id} is not something a kit bundle can install.", kind: kind, id: id)}}

  @catalog_key {__MODULE__, :catalog}

  # `resolve_kits/1` rather than `ensure_bundles!/1`, which RAISES when nothing resolves. This runs
  # inside `studio_sheet/1`'s render, with nothing above it catching — so an unreachable package took
  # the whole Visual Editor LiveView down and the author lost the sheet, not just the Registry tab.
  # An empty catalogue renders as "nothing to install", which is the truth and is survivable.
  #
  # The Chelekom bundle alone is 10.8 MB of JSON, and the Studio sheet re-renders on every keystroke
  # in its search box — parsing per call made opening the Registry tab take seconds. Cached in
  # `:persistent_term` (read-only, no copy) and keyed by the bundle files' own mtimes and sizes, so a
  # kit dropped beside the others still appears without a restart, which is the point of on-disk
  # discovery.
  #
  # FROM DISK ONLY. The kits were fetched when the site was installed, at the version the operator
  # chose there; the Studio offers the rest of THOSE, and never looks up or downloads a newer one.
  #
  # The stamp is taken again AFTER resolving, so a kit file written meanwhile — by an install running
  # beside it — is read on the next look instead of being keyed as already read.
  defp catalog do
    stamp = kit_stamp()

    case :persistent_term.get(@catalog_key, nil) do
      {^stamp, catalog} ->
        catalog

      _stale ->
        catalog = UiKitCatalog.merge(UiKitHandler.resolve_kits(local_only: true).bundles)
        :persistent_term.put(@catalog_key, {kit_stamp(), catalog})
        catalog
    end
  end

  # Read from the files' stats alone, so a cached catalogue costs no bundle parse.
  defp kit_stamp do
    Enum.map(UiKitHandler.bundle_files(), fn path ->
      case File.stat(path) do
        {:ok, %{mtime: mtime, size: size}} -> {path, mtime, size}
        {:error, _reason} -> {path, nil, nil}
      end
    end)
  end

  @doc false
  # Installing writes no bundle, but it does change what "not yet installed" means. The catalogue
  # itself is unchanged, so only the caller's view needs redoing — this exists for tests that plant a
  # kit mid-run.
  def forget_catalog, do: :persistent_term.erase(@catalog_key)

  @doc """
  Every category the installed kits actually use, in the catalogue's own order.

  Read off the whole catalogue rather than off `packages/1`, which stops at `@page` — a category
  whose components all sort late would otherwise have no chip.
  """
  @spec package_categories(map()) :: [String.t()]
  def package_categories(_filters) do
    catalog()
    |> entries()
    |> Enum.map(&entry_category/1)
    |> Enum.uniq()
  end

  defp entries(catalog), do: Enum.flat_map(catalog.groups, & &1.entries)

  defp package(entry, catalog) do
    deps = UiKitCatalog.required_closure(catalog, [entry.name])

    %{
      id: entry.name,
      name: UiKitCatalog.label(entry.name, entry[:kit]),
      category: entry_category(entry),
      installed?: false,
      version: nil,
      installs: nil,
      rating: nil,
      size: nil,
      deps: MapSet.size(deps),
      updated: nil,
      author: UiKitCatalog.kit_label(entry[:kit]),
      description: describe(entry, deps)
    }
  end

  defp describe(entry, deps) do
    kit = UiKitCatalog.kit_label(entry[:kit])

    case MapSet.size(deps) do
      0 ->
        gettext("From %{kit}. Installs on its own.", kit: kit)

      count ->
        ngettext(
          "From %{kit}. Brings 1 component it depends on.",
          "From %{kit}. Brings %{count} components it depends on.",
          count,
          kit: kit
        )
    end
  end

  # The entry's own `type` IS the group key the picker sorts it into, which is what the Studio's
  # category chips filter on.
  defp entry_category(%{type: type}) when is_binary(type) and type != "", do: type
  defp entry_category(_entry), do: "general"

  # Filtering the ENTRIES rather than the built packages, because building one walks the dependency
  # graph and doing that for components about to be discarded is the difference between a snappy tab
  # and a slow one.
  defp filter_category(entries, filters) do
    case Map.get(filters, :category) || Map.get(filters, "category") do
      nil -> entries
      "all" -> entries
      value -> Enum.filter(entries, &(entry_category(&1) == value))
    end
  end

  # What the SITE already has, which is what turns 136 components into "the ones you could add".
  defp installed_names(site_id) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> then(
      &if(site_id, do: Ash.Query.filter(&1, site_id == ^site_id or is_nil(site_id)), else: &1)
    )
    |> Ash.Query.select([:name])
    |> Ash.read(page: [limit: 1000])
    |> case do
      {:ok, %{results: rows}} -> MapSet.new(rows, & &1.name)
      {:ok, rows} when is_list(rows) -> MapSet.new(rows, & &1.name)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp to_token(%Token{} = token), do: token
  defp to_token(token), do: Token.new!(token)
end
