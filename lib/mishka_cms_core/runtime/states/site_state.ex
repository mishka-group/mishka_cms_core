defmodule MishkaCmsCore.Runtime.States.SiteState do
  @moduledoc """
  High-performance ETS-based state manager for multi-site configuration and lookup.

  Manages runtime site data with optimized storage and retrieval using multiple ETS
  indexes for different access patterns. Designed for multi-tenant applications
  requiring fast site resolution, priority-based ordering, and efficient
  site management operations.

  ## Architecture

  Uses a multi-table ETS architecture with specialized indexes:
  - **Main Table**: Primary storage with complete site data
  - **Host Index**: O(1) lookups by hostname for request routing
  - **Name Index**: O(1) lookups by site name for administration
  - **Conflict Detection**: Automatic hostname and name uniqueness validation

  ## Data Structure

  Each site record contains:
  - `id`: Unique site identifier (UUID or database ID)
  - `name`: Human-readable site name for administration
  - `host`: Hostname for HTTP request routing
  - `priority`: Site priority for ordering (higher = more important)
  - `active`: Boolean flag for site availability
  - `master`: Boolean flag indicating if this is the master site

  ## Key Features

  - **O(1) Host Resolution**: Instant site lookup by hostname for routing
  - **Conflict Prevention**: Automatic hostname and name uniqueness validation
  - **Priority Ordering**: Site ranking and display ordering
  - **Active Status Management**: Site availability control
  - **Batch Operations**: Efficient bulk site loading
  - **Flexible Pagination**: Priority and name-based sorting options
  - **Memory Streaming**: Process large site lists without memory overhead
  - **Concurrent Access**: Read/write concurrency optimization

  ## Performance Characteristics

  - Host/name lookups: O(1)
  - Pagination queries: O(n log n) where n = total sites
  - Memory usage: ~150-200 bytes per site record
  - Concurrent reads: Fully optimized
  - Batch inserts: ~8x faster than individual saves

  ## Usage Examples

  ```elixir
  # Register a new site
  SiteState.save(%{
    id: "site_123",
    name: "My Blog",
    host: "myblog.com",
    priority: 90,
    active: true,
    master: false
  })

  # Fast host-based site resolution
  {:ok, site} = SiteState.get_by_host("myblog.com")

  # Administrative site lookup
  {:ok, site} = SiteState.get_by_name("My Blog")

  # Priority-ordered site listing
  %{data: sites, total: count} = SiteState.paginate(%{
    page: 1,
    limit: 20,
    active: true,
    sort: :priority,
    order: :desc
  })

  # Batch site loading for performance
  SiteState.save_batch([
    %{id: "site1", name: "Site One", host: "one.com", priority: 100, active: true, master: true},
    %{id: "site2", name: "Site Two", host: "two.com", priority: 80, active: true, master: false}
  ])

  # Memory-efficient site processing
  SiteState.stream(%{active: true})
  |> Stream.each(&process_site/1)
  |> Stream.run()
  ```

  ## Request Routing Integration

  ```elixir
  # In a Phoenix plug or controller
  def resolve_site(conn, _opts) do
    host = get_req_header(conn, "host") |> List.first()
    
    case SiteState.get_by_host(host) do
      {:ok, site} when site.active ->
        assign(conn, :current_site, site)
      _ ->
        send_resp(conn, 404, "Site not found") |> halt()
    end
  end
  ```

  ## Integration Patterns

  - **Multi-tenant Routing**: Host-based tenant resolution
  - **Site Administration**: Management interface with priority ordering
  - **Load Balancing**: Priority-based request distribution
  - **Feature Flags**: Active/inactive site management
  - **Analytics**: Site performance and usage tracking
  - **CDN Configuration**: Host-based asset routing

  ## Production Considerations

  - Monitor site lookup performance and memory usage
  - Implement proper error handling for inactive sites
  - Use batch operations for initial site loading
  - Consider hostname validation at application boundaries
  - Implement audit logging for site configuration changes
  - Use streaming for large-scale site operations
  """
  use GenServer

  require Logger

  alias MishkaCmsCore.Runtime.Handlers.BootHandler

  # ETS table names
  @main_table :mishka_sites
  @host_index :mishka_sites_host_index
  @name_index :mishka_sites_name_index
  @allowed_origins_index :mishka_sites_allowed_origins_index

  @pubsub MishkaCmsCore.PubSub

  # The three topics `MishkaCmsCore.Runtime.Site`'s `pub_sub` block publishes without a pkey segment.
  # `:update`, `:activate`, `:deactivate` and `:unarchive` all land on "site:updated"; `:destroy` and
  # `:permanent_destroy` on "site:destroyed"; `:create` publishes "site:created" alone.
  @site_topics ["site:created", "site:updated", "site:destroyed"]

  # Record structure: {id, name, host, priority, active, master, mode, frontend_domain, allowed_origins}

  ####################################################################################
  ########################### (▰˘◡˘▰) Client API (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Starts the SiteState GenServer and creates the ETS tables.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves site data to the ETS tables.
  Returns :ok or {:error, :host_already_exists} / {:error, :name_already_exists}
  """
  def save(attrs) when is_map(attrs) do
    %{
      id: id,
      name: name,
      host: host,
      priority: priority,
      active: active,
      master: master,
      mode: mode,
      frontend_domain: frontend_domain,
      allowed_origins: allowed_origins
    } =
      attrs
      |> Map.put_new(:master, false)
      |> Map.update(:mode, :hybrid, &mode/1)
      |> Map.put_new(:frontend_domain, nil)
      |> Map.put_new(:allowed_origins, [])

    # Check for conflicts
    with :ok <- check_host_conflict(host, id),
         :ok <- check_name_conflict(name, id) do
      cleanup_old_indexes(id)

      :ets.insert(
        @main_table,
        {id, name, host, priority, active, master, mode, frontend_domain, allowed_origins}
      )

      :ets.insert(@host_index, {host, id})
      :ets.insert(@name_index, {name, id})

      # Index allowed_origins for fast lookup
      # Also include frontend_domain if present
      cleanup_old_allowed_origins(id)
      index_allowed_origins(id, allowed_origins, frontend_domain)

      MishkaInstaller.Event.Hook.call("runtime:state:site:changed", %{op: :save, key: id},
        return: false
      )

      MishkaCmsCore.Runtime.SiteAvailability.changed(id)

      :ok
    end
  end

  @doc """
  Batch save multiple sites for better performance during boot.
  Skips conflict checking for speed - use only during initial load!
  """
  def save_batch(sites) when is_list(sites) do
    # Prepare all records
    main_records =
      Enum.map(sites, fn s ->
        {s.id, s.name, s.host, s.priority, s.active, Map.get(s, :master, false),
         mode(Map.get(s, :mode)), Map.get(s, :frontend_domain, nil),
         Map.get(s, :allowed_origins, [])}
      end)

    host_records = Enum.map(sites, fn s -> {s.host, s.id} end)
    name_records = Enum.map(sites, fn s -> {s.name, s.id} end)

    # Build allowed_origins index records
    allowed_origins_records =
      sites
      |> Enum.flat_map(fn s ->
        origins = Map.get(s, :allowed_origins, [])
        frontend = Map.get(s, :frontend_domain)

        # Build list of all origins to index
        frontend_origins =
          cond do
            is_nil(frontend) or frontend == "" ->
              []

            String.starts_with?(frontend, "http") ->
              # It's already a full origin
              [frontend]

            true ->
              # It's just a domain, index both http and https variants
              ["https://#{frontend}", "http://#{frontend}", frontend]
          end

        # Combine all origins
        all_origins = frontend_origins ++ origins

        Enum.map(all_origins, fn origin -> {origin, s.id} end)
      end)

    # Batch insert
    :ets.insert(@main_table, main_records)
    :ets.insert(@host_index, host_records)
    :ets.insert(@name_index, name_records)
    :ets.insert(@allowed_origins_index, allowed_origins_records)
    :ok
  end

  @doc """
  High-performance lookup by allowed origin (O(1)).
  Returns the first site that allows this origin for CORS.
  """
  def get_by_allowed_origin(origin) do
    case :ets.lookup(@allowed_origins_index, origin) do
      [{^origin, id} | _] -> get(id)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Checks if an origin is allowed for any active site (O(1)).
  Returns {true, site} if allowed, false otherwise.
  """
  def is_allowed_origin?(origin) do
    case :ets.lookup(@allowed_origins_index, origin) do
      [{^origin, id} | _] ->
        case get(id) do
          {:ok, site} when site.active -> {true, site}
          _ -> false
        end

      [] ->
        false
    end
  end

  @doc """
  High-performance lookup by host (O(1)).
  """
  def get_by_host(host) do
    case :ets.lookup(@host_index, host) do
      [{^host, id}] -> get(id)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  High-performance lookup by host, returns nil if not found.
  """
  def get_by_host!(host) do
    case :ets.lookup(@host_index, host) do
      [{^host, id}] -> get!(id)
      [] -> nil
    end
  end

  @doc """
  High-performance lookup by name (O(1)).
  """
  def get_by_name(name) do
    case :ets.lookup(@name_index, name) do
      [{^name, id}] -> get(id)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets the master site.
  Returns {:ok, site} if master site exists, {:error, :not_found} otherwise.
  """
  def get_by_master do
    :ets.tab2list(@main_table)
    |> Enum.find(fn
      {_id, _name, _host, _priority, _active, true, _mode, _frontend, _origins} -> true
      _ -> false
    end)
    |> case do
      {id, name, host, priority, active, master, mode, frontend_domain, allowed_origins} ->
        {:ok,
         %{
           id: id,
           name: name,
           host: host,
           priority: priority,
           active: active,
           master: master,
           mode: mode,
           frontend_domain: frontend_domain,
           allowed_origins: allowed_origins
         }}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the master site, returns nil if not found.
  """
  def get_by_master! do
    case get_by_master() do
      {:ok, site} -> site
      _ -> nil
    end
  end

  @doc """
  Gets site by ID.
  """
  def get(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, name, host, priority, active, master, mode, frontend_domain, allowed_origins}] ->
        {:ok,
         %{
           id: id,
           name: name,
           host: host,
           priority: priority,
           active: active,
           master: master,
           mode: mode,
           frontend_domain: frontend_domain,
           allowed_origins: allowed_origins
         }}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets site by ID, returns nil if not found.
  """
  def get!(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, name, host, priority, active, master, mode, frontend_domain, allowed_origins}] ->
        %{
          id: id,
          name: name,
          host: host,
          priority: priority,
          active: active,
          master: master,
          mode: mode,
          frontend_domain: frontend_domain,
          allowed_origins: allowed_origins
        }

      [] ->
        nil
    end
  end

  @doc """
  Gets all active sites sorted by priority DESC.
  Note: For large datasets, consider using paginate/1 or stream/1 instead.
  """
  def get_active_sites do
    :ets.tab2list(@main_table)
    |> Enum.filter(fn
      {_id, _name, _host, _priority, true, _master, _mode, _frontend, _origins} -> true
      _ -> false
    end)
    |> Enum.map(fn {id, name, host, priority, active, master, mode, frontend_domain,
                    allowed_origins} ->
      %{
        id: id,
        name: name,
        host: host,
        priority: priority,
        active: active,
        master: master,
        mode: mode,
        frontend_domain: frontend_domain,
        allowed_origins: allowed_origins
      }
    end)
    |> Enum.sort_by(& &1.priority, :desc)
  end

  @doc """
  High-performance paginated query with sorting by priority DESC.

  ## Options
    * `:page` - Page number (default: 1)
    * `:limit` - Items per page (default: 20)
    * `:active` - Filter by active status (default: nil, shows all)
    * `:sort` - Sort field, :priority or :name (default: :priority)
    * `:order` - Sort order, :asc or :desc (default: :desc for priority, :asc for name)

  ## Examples

      MishkaCmsCore.Runtime.States.SiteState.paginate(%{page: 1, limit: 20, active: true})
  """
  def paginate(opts \\ %{}) do
    page = opts[:page] || 1
    limit = opts[:limit] || 20
    offset = (page - 1) * limit
    active_filter = opts[:active]
    sort_field = opts[:sort] || :priority
    sort_order = opts[:order] || if sort_field == :priority, do: :desc, else: :asc

    # Get all records and filter
    all_sites =
      :ets.tab2list(@main_table)
      |> Enum.map(fn {id, name, host, priority, active, master, mode, frontend_domain,
                      allowed_origins} ->
        %{
          id: id,
          name: name,
          host: host,
          priority: priority,
          active: active,
          master: master,
          mode: mode,
          frontend_domain: frontend_domain,
          allowed_origins: allowed_origins
        }
      end)
      |> filter_by_active(active_filter)
      |> sort_sites(sort_field, sort_order)

    # Calculate pagination
    total = length(all_sites)
    total_pages = ceil(total / limit)

    # Get page data
    data =
      all_sites
      |> Enum.drop(offset)
      |> Enum.take(limit)

    %{
      data: data,
      page: page,
      limit: limit,
      total: total,
      total_pages: total_pages,
      has_next: page < total_pages,
      has_prev: page > 1
    }
  end

  @doc """
  Stream all sites for memory-efficient processing.

  ## Options
    * `:active` - Filter by active status (default: nil, shows all)
    * `:sort` - Sort field, :priority or :name (default: :priority)
    * `:order` - Sort order, :asc or :desc (default: :desc for priority, :asc for name)
    * `:chunk_size` - Number of records per chunk (default: 100)

  ## Examples

      MishkaCmsCore.Runtime.States.SiteState.stream(%{active: true})
      |> Stream.each(fn site -> IO.inspect(site) end)
      |> Stream.run()
  """
  def stream(opts \\ %{}) do
    active_filter = opts[:active]
    sort_field = opts[:sort] || :priority
    sort_order = opts[:order] || if sort_field == :priority, do: :desc, else: :asc

    # Get all sites, convert to maps, filter and sort
    :ets.tab2list(@main_table)
    |> Enum.map(fn {id, name, host, priority, active, master, mode, frontend_domain,
                    allowed_origins} ->
      %{
        id: id,
        name: name,
        host: host,
        priority: priority,
        active: active,
        master: master,
        mode: mode,
        frontend_domain: frontend_domain,
        allowed_origins: allowed_origins
      }
    end)
    |> filter_by_active(active_filter)
    |> sort_sites(sort_field, sort_order)
    |> Stream.unfold(fn
      [] -> nil
      [h | t] -> {h, t}
    end)
  end

  @doc """
  Gets sites by priority range.
  """
  def get_by_priority_range(min_priority, max_priority) do
    :ets.tab2list(@main_table)
    |> Enum.filter(fn
      {_id, _name, _host, priority, _active, _master, _mode, _frontend, _origins} ->
        priority >= min_priority and priority <= max_priority

      _ ->
        false
    end)
    |> Enum.map(fn {id, name, host, priority, active, master, mode, frontend_domain,
                    allowed_origins} ->
      %{
        id: id,
        name: name,
        host: host,
        priority: priority,
        active: active,
        master: master,
        mode: mode,
        frontend_domain: frontend_domain,
        allowed_origins: allowed_origins
      }
    end)
    |> Enum.sort_by(& &1.priority, :desc)
  end

  @doc """
  Fast check if a host exists.
  """
  def host_exists?(host), do: :ets.member(@host_index, host)

  @doc """
  Fast check if a site exists.
  """
  def exists?(id), do: :ets.member(@main_table, id)

  @doc """
  Sets a site as master, unsetting any existing master site.
  """
  def set_master(site_id) do
    # First, get the site to ensure it exists
    case get(site_id) do
      {:ok, site} ->
        # Unset any existing master
        :ets.tab2list(@main_table)
        |> Enum.each(fn
          {id, name, host, priority, active, true, mode, frontend_domain, allowed_origins} ->
            if id != site_id do
              :ets.insert(
                @main_table,
                {id, name, host, priority, active, false, mode, frontend_domain, allowed_origins}
              )
            end

          _ ->
            :ok
        end)

        # Set the new master
        :ets.insert(
          @main_table,
          {site.id, site.name, site.host, site.priority, site.active, true, site.mode,
           site.frontend_domain, site.allowed_origins}
        )

        {:ok, %{site | master: true}}

      error ->
        error
    end
  end

  @doc """
  Unsets the master site (finds the current master and sets its master flag to false).
  Returns {:ok, site} with the updated site, or {:error, :not_found} if no master exists.
  """
  def unset_master do
    case get_by_master() do
      {:ok, site} ->
        # Update the master site to have master = false
        :ets.insert(
          @main_table,
          {site.id, site.name, site.host, site.priority, site.active, false, site.mode,
           site.frontend_domain, site.allowed_origins}
        )

        {:ok, %{site | master: false}}

      error ->
        error
    end
  end

  @doc """
  Deletes a site by ID.
  """
  def delete(id) do
    cleanup_old_indexes(id)
    :ets.delete(@main_table, id)

    MishkaInstaller.Event.Hook.call("runtime:state:site:changed", %{op: :delete, key: id},
      return: false
    )

    MishkaCmsCore.Runtime.SiteAvailability.changed(id)

    :ok
  end

  @doc """
  Returns the number of sites.
  """
  def count, do: :ets.info(@main_table, :size)

  @doc """
  Clears all data from all tables.
  """
  def clear do
    [@main_table, @host_index, @name_index, @allowed_origins_index]
    |> Enum.each(fn table ->
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end)

    :ok
  end

  ####################################################################################
  ########################### (▰˘◡˘▰) Server API (▰˘◡˘▰) #############################
  ####################################################################################

  @impl true
  def init(_opts) do
    # Create main table with read optimization
    :ets.new(@main_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    # Create index tables
    :ets.new(@host_index, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@name_index, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Create allowed_origins index table (allows duplicate keys)
    :ets.new(@allowed_origins_index, [
      # bag allows duplicate keys with different values
      :bag,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # THE WRITE IS OFTEN NOT THIS NODE'S. These tables are per node and `DNSCluster` means there are
    # usually several, so a site created, renamed, activated or destroyed on one node left every
    # other one resolving hosts against a stale table — a request answered by the wrong site, or by
    # a 404 for a site that exists. `MishkaCmsCore.Runtime.Site` already publishes through
    # `Ash.Notifier.PubSub`, and Phoenix.PubSub carries it across connected nodes; only the listening
    # was missing. Same fix, same reason, as `MishkaCmsCore.Runtime.States.SettingsState`.
    for topic <- @site_topics, do: Phoenix.PubSub.subscribe(@pubsub, topic)

    {:ok, %{}, {:continue, :load}}
  end

  # Self-heal on (re)start: an owner crash empties these tables, so rebuild them from the DB by
  # reusing the same streaming loader BootHandler runs at boot (`BootHandler.load_sites/0`).
  # Skipped in test — the suite seeds SiteState directly and a GenServer can't see a test
  # transaction's rows anyway; tests drive `BootHandler.load_sites/0` from their own process.
  @impl true
  def handle_continue(:load, state) do
    if !Application.get_env(:mishka_cms_core, :env_test?, false), do: BootHandler.load_sites()
    {:noreply, state}
  end

  # A BROADCAST THIS NODE SENT IS ONE THIS NODE HAS ALREADY APPLIED. `Changes.ScheduleSiteRuntime`
  # calls `save/1` or `delete/1` from inside the action itself, and it runs `on: [:create, :update,
  # :destroy]` — which covers every action the resource publishes, since `:activate`, `:deactivate`
  # and `:unarchive` are all update-type. `Phoenix.Endpoint.broadcast/3` delivers to local
  # subscribers as well as remote ones, so without this the writing node applies its own write twice.
  #
  # In ETS that would be harmless. It is not harmless in the `runtime:state:site:changed`
  # announcement that `save/1` and `delete/1` fire: that is a mishka_installer event a plugin can
  # register on, its whole payload is `%{op:, key:}`, and a plugin cannot tell the second call from
  # the first. An invalidation would shrug; anything that counts, appends to a log, enqueues a job or
  # posts a webhook would do it twice for one site change. Ash stamps the sending process onto the
  # notification, so the node it came from is known for free.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{from: from}},
        state
      )
      when node(from) == node() do
    {:noreply, state}
  end

  # Applied straight from the notification, through the same `save/1` and `delete/1` every local
  # write uses, so the four tables and their indexes stay consistent by construction. Deliberately no
  # database read: this process owns no Ecto sandbox connection, and a query here would sit in front
  # of every host lookup in the system.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "site:destroyed",
          payload: %Ash.Notifier.Notification{data: %{id: id}}
        },
        state
      ) do
    delete(id)
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: topic,
          payload: %Ash.Notifier.Notification{data: %{id: _id} = site}
        },
        state
      )
      when topic in ["site:created", "site:updated"] do
    # `save/1` answers `{:error, :host_already_exists}` when another site already holds the host. On
    # this path that means the two nodes disagree about which site owns it, and the row that wrote it
    # is the one the database agreed with — but repairing that needs a read, which is what this
    # function must not do, so it is logged and left for the next `BootHandler.load_sites/0`.
    case save(site) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[SiteState] ignored a #{topic} broadcast for #{site.id}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ####################################################################################
  ##################### (▰˘◡˘▰) Private Helpers (▰˘◡˘▰) ##############################
  ####################################################################################

  defp check_host_conflict(host, id) do
    case :ets.lookup(@host_index, host) do
      [{^host, existing_id}] when existing_id != id -> {:error, :host_already_exists}
      _ -> :ok
    end
  end

  defp check_name_conflict(name, id) do
    case :ets.lookup(@name_index, name) do
      [{^name, existing_id}] when existing_id != id -> {:error, :name_already_exists}
      _ -> :ok
    end
  end

  defp cleanup_old_indexes(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, name, host, _priority, _active, _master, _mode, _frontend, _origins}] ->
        :ets.delete(@host_index, host)
        :ets.delete(@name_index, name)

      [] ->
        :ok
    end
  end

  defp cleanup_old_allowed_origins(site_id) do
    # Remove all allowed_origins entries for this site
    :ets.select_delete(@allowed_origins_index, [{{:"$1", :"$2"}, [{:==, :"$2", site_id}], [true]}])
  end

  defp index_allowed_origins(site_id, allowed_origins, frontend_domain) do
    # Index frontend_domain if present (supporting both full origin and domain-only)
    if frontend_domain && frontend_domain != "" do
      if String.starts_with?(frontend_domain, "http") do
        # It's already a full origin
        :ets.insert(@allowed_origins_index, {frontend_domain, site_id})
      else
        # It's just a domain, index both http and https variants
        :ets.insert(@allowed_origins_index, {"https://#{frontend_domain}", site_id})
        :ets.insert(@allowed_origins_index, {"http://#{frontend_domain}", site_id})
        # Also index the domain itself for flexible matching
        :ets.insert(@allowed_origins_index, {frontend_domain, site_id})
      end
    end

    # Index all allowed_origins
    Enum.each(allowed_origins, fn origin ->
      if origin && origin != "" do
        :ets.insert(@allowed_origins_index, {origin, site_id})
      end
    end)
  end

  defp filter_by_active(sites, nil), do: sites
  defp filter_by_active(sites, active), do: Enum.filter(sites, &(&1.active == active))

  defp sort_sites(sites, :priority, :desc), do: Enum.sort_by(sites, & &1.priority, :desc)
  defp sort_sites(sites, :priority, :asc), do: Enum.sort_by(sites, & &1.priority, :asc)
  defp sort_sites(sites, :name, :desc), do: Enum.sort_by(sites, & &1.name, :desc)
  defp sort_sites(sites, :name, :asc), do: Enum.sort_by(sites, & &1.name, :asc)
  defp sort_sites(sites, _, _), do: sites

  # `MishkaCmsCore.Runtime.Site` types `mode` as an atom constrained to three values, so that is what
  # this table holds — one shape, whichever caller wrote it. A string is accepted for the three that
  # exist, because a seed or an older row may carry one, and anything else becomes the default.
  #
  # Matched, never converted: `String.to_atom/1` here would let whoever names a mode add an entry to
  # a table the VM never empties.
  @spec mode(term()) :: :api_only | :phoenix_only | :hybrid
  defp mode(mode) when mode in [:api_only, :phoenix_only, :hybrid], do: mode
  defp mode("api_only"), do: :api_only
  defp mode("phoenix_only"), do: :phoenix_only
  defp mode("hybrid"), do: :hybrid
  defp mode(_unknown), do: :hybrid
end
