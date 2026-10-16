# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.AssetsState do
  @moduledoc """
  High-performance ETS-based state manager for multi-site asset storage and retrieval.

  Manages runtime asset data (themes, CSS, JavaScript, configurations) with optimized
  storage using composite keys for multi-tenant applications. Designed for fast asset
  retrieval, efficient memory usage, and concurrent read/write operations.

  ## Architecture

  Uses a single ETS table with composite key structure:
  - **Composite Key**: `{site_name, type}` ensures uniqueness per site and asset type
  - **Value Storage**: Arbitrary data structures (maps, strings, binaries)
  - **Metadata**: Hash validation and timestamp tracking
  - **Concurrent Access**: Optimized for high read concurrency

  ## Data Structure

  Each asset record contains:
  - `id`: Site identifier for multi-tenant isolation
  - `type`: Asset type classification (theme, css, js, config, etc.)
  - `value`: Asset content (maps, strings, or any serializable data)
  - `hash`: Content hash for validation and change detection
  - `updated_at`: Last modification timestamp

  ## Key Features

  - **O(1) Asset Lookups**: Direct access by site and type combination
  - **Multi-tenant Isolation**: Site-based asset separation
  - **Flexible Storage**: Support for any serializable data structure
  - **Batch Operations**: Efficient bulk asset loading
  - **Hash Validation**: Content integrity verification
  - **Memory Optimization**: Direct value access without full record retrieval
  - **Concurrent Safety**: Read/write concurrency optimization

  ## Performance Characteristics

  - Direct lookups: O(1)
  - Site-based queries: O(n) where n = assets per site
  - Memory usage: ~100-200 bytes per asset + content size
  - Concurrent reads: Fully optimized
  - Batch operations: ~5x faster than individual saves

  ## Usage Examples

  ```elixir
  # Save theme assets
  AssetsState.save(%{
    id: "myblog",
    type: "theme",
    value: %{
      css: "body { color: #333; }",
      js: "console.log('Theme loaded');",
      config: %{dark_mode: true}
    },
    hash: "abc123",
    updated_at: DateTime.utc_now()
  })

  # Fast asset retrieval
  {:ok, theme} = AssetsState.get("myblog", "theme")

  # Direct value access for performance
  css_content = AssetsState.get_value("myblog", "css")

  # Site-wide asset management
  all_assets = AssetsState.get_by_site("myblog")

  # Batch loading for performance
  AssetsState.save_batch([
    %{id: "site1", type: "theme", value: theme_data, hash: "hash1", updated_at: now},
    %{id: "site1", type: "config", value: config_data, hash: "hash2", updated_at: now}
  ])
  ```

  ## Asset Type Examples

  - **theme**: Complete theme packages with CSS, JS, and configuration
  - **css**: Compiled CSS stylesheets
  - **js**: JavaScript bundles and libraries
  - **config**: Site-specific configuration data
  - **templates**: Compiled template data
  - **metadata**: SEO and meta information
  - **cache**: Processed content cache

  ## Integration Patterns

  - **Theme Engine**: Dynamic theme loading and switching
  - **Asset Pipeline**: Runtime asset compilation and serving
  - **Multi-site Management**: Site-isolated asset storage
  - **CDN Integration**: Asset hash-based cache invalidation
  - **Development Tools**: Hot-reload asset updates

  ## Production Considerations

  - Monitor memory usage with `stats/0` function
  - Implement asset cleanup strategies for unused sites
  - Use hash validation for content integrity
  - Consider asset size limits for memory management
  - Leverage batch operations for bulk updates
  - Use direct value access for performance-critical paths
  """
  use GenServer

  # ETS table name
  @main_table :mishka_assets

  # Record structure: {{id(site_name), type}, value, hash, updated_at}
  # Composite key: {site_name, type} ensures uniqueness by both site and type

  ####################################################################################
  ########################### (▰˘◡˘▰) Client API (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Starts the MishkaCmsCore.Runtime.States.AssetsState GenServer and creates the ETS table.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves asset data to the ETS table with composite key (site_name, type).

  ## Examples

      MishkaCmsCore.Runtime.States.AssetsState.save(%{
        id: "example_site",
        type: "theme",
        value: %{css: "body { color: red; }", js: "console.log('hello');"},
        hash: "hash_value",
        updated_at: ~U[2024-01-01 10:00:00Z]
      })
  """
  def save(attrs) when is_map(attrs) do
    %{id: id, type: type, value: value, hash: hash, updated_at: updated_at} = attrs
    :ets.insert(@main_table, {{id, type}, value, hash, updated_at})

    MishkaInstaller.Event.Hook.call("runtime:state:assets:changed", %{op: :save, key: {id, type}},
      return: false
    )

    :ok
  end

  @doc """
  Batch save multiple assets for better performance.
  """
  def save_batch(assets) when is_list(assets) do
    records = Enum.map(assets, &{{&1.id, &1.type}, &1.value, &1.hash, &1.updated_at})
    :ets.insert(@main_table, records)
    :ok
  end

  @doc """
  Gets asset data by ID (site_name) and type using direct lookup (O(1)).
  Returns {:ok, asset} or {:error, :not_found}.
  """
  def get(id, type) do
    case :ets.lookup(@main_table, {id, type}) do
      [{{^id, ^type}, value, hash, updated_at}] ->
        {:ok, %{id: id, type: type, value: value, hash: hash, updated_at: updated_at}}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets asset data by ID (site_name) and type, returns nil if not found.
  Optimized for read performance.
  """
  def get!(id, type) do
    case :ets.lookup(@main_table, {id, type}) do
      [{{^id, ^type}, value, hash, updated_at}] ->
        %{id: id, type: type, value: value, hash: hash, updated_at: updated_at}

      [] ->
        nil
    end
  end

  @doc """
  Gets only the value field for maximum read performance.
  Returns the raw value or nil if not found.
  """
  def get_value(id, type) do
    case :ets.lookup(@main_table, {id, type}) do
      [{{^id, ^type}, value, _hash, _updated_at}] -> value
      [] -> nil
    end
  end

  @doc """
  Fast check if an asset exists by site_name and type.
  """
  def exists?(id, type), do: :ets.member(@main_table, {id, type})

  @doc """
  The `hash` of an asset without reading its (large) value — `nil` if absent.

  One lookup that copies the hash alone, for the paths that run on every page render.
  """
  @spec hash(String.t(), String.t()) :: String.t() | nil
  def hash(id, type), do: :ets.lookup_element(@main_table, {id, type}, 3, nil)

  @doc """
  The `updated_at` of an asset without reading its (large) value — `nil` if absent.
  """
  def updated_at(id, type), do: :ets.lookup_element(@main_table, {id, type}, 4, nil)

  @doc """
  Gets all assets for a specific site (all types).
  Returns a list of assets for the site.
  """
  def get_by_site(site_name) do
    :ets.match_object(@main_table, {{site_name, :_}, :_, :_, :_})
    |> Enum.map(fn {{id, type}, value, hash, updated_at} ->
      %{id: id, type: type, value: value, hash: hash, updated_at: updated_at}
    end)
  end

  @doc """
  Gets multiple assets by their composite keys {site_name, type}.
  Returns a list of found assets.
  """
  def get_many(keys) when is_list(keys) do
    Enum.reduce(keys, [], fn {id, type}, acc ->
      case :ets.lookup(@main_table, {id, type}) do
        [{{^id, ^type}, value, hash, updated_at}] ->
          [%{id: id, type: type, value: value, hash: hash, updated_at: updated_at} | acc]

        [] ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Gets all assets of a specific type across all sites.
  Note: This is less efficient than direct lookups.
  """
  def get_by_type(type) do
    :ets.match_object(@main_table, {{:_, type}, :_, :_, :_})
    |> Enum.map(fn {{id, type}, value, hash, updated_at} ->
      %{id: id, type: type, value: value, hash: hash, updated_at: updated_at}
    end)
  end

  @doc """
  Gets all assets in the table.
  Note: Use with caution for large datasets.
  """
  def get_all do
    :ets.tab2list(@main_table)
    |> Enum.map(fn {{id, type}, value, hash, updated_at} ->
      %{id: id, type: type, value: value, hash: hash, updated_at: updated_at}
    end)
  end

  @doc """
  Deletes an asset by ID and type. A no-op while this cache is not running.
  """
  def delete(id, type) do
    # DROPPING A CACHE ENTRY MUST NEVER FAIL ITS CALLER. The table lives and dies with this
    # GenServer, and the callers are write paths — saving a page purges the preview stylesheet that
    # save invalidated — so an unguarded `:ets.delete/2` turns a cache that is restarting, or a host
    # that never started one, into a failed save. Nothing is cached while the table is gone, so
    # there is no change to announce either. `clear/0` guards for the same reason.
    if :ets.whereis(@main_table) != :undefined do
      :ets.delete(@main_table, {id, type})

      MishkaInstaller.Event.Hook.call(
        "runtime:state:assets:changed",
        %{op: :delete, key: {id, type}},
        return: false
      )
    end

    :ok
  end

  @doc """
  Deletes all assets for a specific site.
  Returns the number of deleted assets.
  """
  def delete_by_site(site_name) do
    keys_to_delete = :ets.match(@main_table, {{site_name, :"$1"}, :_, :_, :_})
    Enum.each(keys_to_delete, fn [type] -> :ets.delete(@main_table, {site_name, type}) end)
    length(keys_to_delete)
  end

  @doc """
  Returns the number of assets in the table.
  """
  def count, do: :ets.info(@main_table, :size)

  @doc """
  Clears all data from the table.
  """
  def clear do
    if :ets.whereis(@main_table) != :undefined, do: :ets.delete_all_objects(@main_table)

    :ok
  end

  ####################################################################################
  ########################### (▰˘◡˘▰) Server API (▰˘◡˘▰) #############################
  ####################################################################################

  @impl true
  def init(_opts) do
    :ets.new(@main_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      table_size: :ets.info(@main_table, :size),
      memory: :ets.info(@main_table, :memory),
      table_info: :ets.info(@main_table)
    }

    {:reply, stats, state}
  end

  ####################################################################################
  ##################### (▰˘◡˘▰) Maintenance functions (▰˘◡˘▰) ########################
  ####################################################################################

  @doc """
  Returns detailed statistics about the assets table.
  """
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Updates only the value field of an existing asset.
  Returns :ok if updated, {:error, :not_found} if asset doesn't exist.
  """
  def update_value(id, type, new_value) do
    case :ets.lookup(@main_table, {id, type}) do
      [{{^id, ^type}, _old_value, hash, _updated_at}] ->
        :ets.insert(@main_table, {{id, type}, new_value, hash, DateTime.utc_now()})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates the updated_at timestamp for an asset.
  """
  def touch(id, type) do
    case :ets.lookup(@main_table, {id, type}) do
      [{{^id, ^type}, value, hash, _updated_at}] ->
        :ets.insert(@main_table, {{id, type}, value, hash, DateTime.utc_now()})
        :ok

      [] ->
        {:error, :not_found}
    end
  end
end
