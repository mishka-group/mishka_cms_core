defmodule MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState do
  @moduledoc """
  High-performance ETS-based state manager for web page metadata with multi-index support.

  Manages runtime metadata for web pages, posts, and content with optimized storage and
  retrieval using multiple ETS tables for different access patterns. Designed for
  high-concurrency web applications requiring fast page lookups, pagination,
  and content organization.

  ## Architecture

  Uses a multi-table ETS architecture with specialized indexes:
  - **Main Table**: Primary storage with full page data
  - **Path Index**: O(1) lookups by path and site combination
  - **Site Index**: Efficient site-based filtering
  - **Section Index**: Content organization by site and section
  - **Sort Index**: Ordered set for priority-based pagination

  ## Data Structure

  Each page record contains:
  - `id`: Unique page identifier
  - `site`: Site identifier for multi-tenant support
  - `path`: URL path for routing
  - `title`: Page title for display
  - `created_at`: Timestamp for ordering
  - `section`: Content category (Page, Blog, etc.)
  - `priority`: Sort priority (higher = more important)

  ## Key Features

  - **O(1) Path Lookups**: Instant page resolution by path/site
  - **Optimized Pagination**: Priority-based sorting with efficient offset/limit
  - **Memory Streaming**: Process large datasets without memory overhead
  - **Conflict Prevention**: Automatic path uniqueness validation
  - **Batch Operations**: High-performance bulk data operations
  - **Multi-tenant Support**: Site-based data isolation
  - **Concurrent Access**: Read/write concurrency optimization

  ## Performance Characteristics

  - Path lookups: O(1)
  - Pagination queries: O(n log n) where n = matching records
  - Memory usage: ~200-300 bytes per page record
  - Concurrent reads: Fully optimized
  - Batch inserts: ~10x faster than individual saves

  ## Usage Examples

  ```elixir
  # Save a page
  WebRunTimeMetaDataState.save(%{
    id: "blog_post_123",
    site: "myblog",
    path: "/posts/hello-world",
    title: "Hello World",
    created_at: DateTime.utc_now(),
    section: "Blog",
    priority: 90
  })

  # Fast path lookup
  {:ok, page} = WebRunTimeMetaDataState.find_by_path_and_site("/posts/hello-world", "myblog")

  # Paginated results
  %{data: pages, total: count} = WebRunTimeMetaDataState.paginate(%{
    site: "myblog",
    section: "Blog",
    page: 1,
    limit: 10
  })

  # Memory-efficient streaming
  WebRunTimeMetaDataState.stream_paginated(%{site: "myblog"})
  |> Stream.each(&process_page/1)
  |> Stream.run()
  ```

  ## Integration Patterns

  - **Router Integration**: Fast route resolution for dynamic pages
  - **SEO Management**: Title and metadata organization
  - **Content Management**: Section-based content organization
  - **Analytics**: Priority-based content ranking
  - **Multi-site CMSs**: Tenant-isolated page management

  ## Production Considerations

  - Monitor memory usage with `stats/0` function
  - Use batch operations for initial data loading
  - Consider streaming for large dataset processing
  - Implement cleanup strategies for unused pages
  - Path conflicts are prevented automatically
  """
  use GenServer

  alias MishkaCmsCore.Runtime.Languages

  # ETS table names
  @main_table :mishka_web_run_time_meta_data
  @path_index :mishka_web_run_time_meta_data_path_index

  # Pages whose path carries `:param` or `*rest` segments, as `{site, {pattern, id}}`. Small by
  # construction — only dynamic pages are in it — which is what makes a linear match affordable.
  @dynamic_index :mishka_web_run_time_meta_data_dynamic_index
  @site_index :mishka_web_run_time_meta_data_site_index
  @section_index :mishka_web_run_time_meta_data_section_index
  @sort_index :mishka_web_run_time_meta_data_sort_index

  # WRITES WAIT THEIR TURN, READS NEVER DO. Every read is an ETS lookup in the caller; only `save/1`
  # and `delete/1` pass through this process — from boot, the compile jobs and site changes — and a
  # boot writing a very large pages table queues them past `GenServer.call/2`'s 5 s.
  @write_timeout :timer.seconds(30)

  # Record structure: {id, site, path, title, created_at, section, priority, language}
  # Sort key structure for ordered_set: {{site, section, -priority, created_at}, id}

  ####################################################################################
  ########################### (▰˘◡˘▰) Client API (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Starts the MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState GenServer and creates the ETS tables.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves page data to the ETS tables with all fields.

  ## Examples

      MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.save(%{
        id: "page_123",
        site: "example",
        path: "/about",
        title: "About Us",
        created_at: ~U[2024-01-01 10:00:00Z],
        section: "Page",
        priority: 80
      })
  """
  def save(attrs) when is_map(attrs) do
    %{
      id: id,
      site: site,
      path: path,
      title: title,
      created_at: created_at,
      section: section,
      priority: priority
    } = attrs

    # A LAYOUT AND AN ERROR PAGE HAVE NO LANGUAGE, so this is read rather than matched. `nil` means
    # "this row is not an edition of anything", and `edition?/2` below lets such a row answer any
    # language — which is what a layout has always done.
    language = Map.get(attrs, :language)

    case GenServer.call(
           __MODULE__,
           {:save, {id, site, path, title, created_at, section, priority, language}},
           @write_timeout
         ) do
      :ok ->
        MishkaInstaller.Event.Hook.call("runtime:state:metadata:changed", %{op: :save, key: id},
          return: false
        )

        :ok

      error ->
        error
    end
  end

  @doc """
  Batch save multiple pages for better performance.
  """
  def save_batch(pages) when is_list(pages) do
    Enum.each(pages, fn %{id: id} -> cleanup_old_indexes(id) end)

    # Prepare all records
    main_records =
      Enum.map(pages, fn attrs ->
        {attrs.id, attrs.site, attrs.path, attrs.title, attrs.created_at, attrs.section,
         attrs.priority, Map.get(attrs, :language)}
      end)

    path_records = Enum.map(pages, fn attrs -> {{attrs.path, attrs.site}, attrs.id} end)
    site_records = Enum.map(pages, fn attrs -> {attrs.site, attrs.id} end)
    section_records = Enum.map(pages, fn attrs -> {{attrs.site, attrs.section}, attrs.id} end)

    sort_records =
      Enum.map(pages, fn attrs ->
        {{attrs.site, attrs.section, -attrs.priority, attrs.created_at}, attrs.id}
      end)

    # Batch insert
    :ets.insert(@main_table, main_records)
    :ets.insert(@path_index, path_records)

    Enum.each(pages, fn attrs -> maybe_index_dynamic(attrs.path, attrs.site, attrs.id) end)
    :ets.insert(@site_index, site_records)
    :ets.insert(@section_index, section_records)
    :ets.insert(@sort_index, sort_records)

    :ok
  end

  @doc """
  Gets page data by ID using direct lookup (O(1)).
  """
  def get(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, site, path, title, created_at, section, priority, language}] ->
        {:ok,
         %{
           id: id,
           site: site,
           path: path,
           title: title,
           created_at: created_at,
           section: section,
           priority: priority,
           language: language
         }}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets page data by ID, returns nil if not found.
  """
  def get!(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, site, path, title, created_at, section, priority, language}] ->
        %{
          id: id,
          site: site,
          path: path,
          title: title,
          created_at: created_at,
          section: section,
          priority: priority,
          language: language
        }

      [] ->
        nil
    end
  end

  @doc """
  High-performance paginated query with sorting by priority DESC, created_at ASC.

  ## Examples

      MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.paginate(%{
        site: "example",
        section: "blog",
        page: 1,
        limit: 20
      })
  """
  def paginate(opts) do
    page = opts[:page] || 1
    limit = opts[:limit] || 20
    offset = (page - 1) * limit
    pattern = build_sort_pattern(opts[:site], opts[:section])
    result = paginate_select(pattern, limit, offset)
    total = count_matching(opts[:site], opts[:section])
    total_pages = ceil(total / limit)

    %{
      data: result,
      page: page,
      limit: limit,
      total: total,
      total_pages: total_pages,
      has_next: page < total_pages,
      has_prev: page > 1
    }
  end

  @doc """
  Stream paginated results for memory-efficient processing.
  """
  def stream_paginated(opts) do
    site = opts[:site]
    section = opts[:section]
    pattern = build_sort_pattern(site, section)

    Stream.resource(
      fn -> :ets.match_object(@sort_index, pattern, 100) end,
      fn
        :"$end_of_table" ->
          {:halt, nil}

        {matches, continuation} ->
          pages = fetch_pages_from_sort_results(matches)
          {pages, :ets.match_object(continuation)}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  The record STORED at this path, for a caller naming one it already knows.

  A layout is reached by the path the page names it with and an error page by the path its row
  carries; neither is a URL a visitor typed. So this looks the path up as written — a pattern path
  included — which is what separates it from `resolve/2`.
  """
  def find_by_path_and_site(path, site) do
    case stored_or_dynamic(path, site) do
      {:ok, record, _captured} -> {:ok, record}
      error -> error
    end
  end

  @doc """
  The page for a REQUEST path, and whatever its pattern captured.

  `%{}` for a literal page, which is almost all of them.

  A REQUEST NEVER CARRIES PATTERN SYNTAX, and refusing it here is the whole of this clause. A
  pattern page is stored under its pattern — `/:lang/blog` — and the path index is keyed by the
  stored string, so typing that pattern into the address bar matched the index EXACTLY and was
  served as though it were a literal page: `/:lang/blog` and `/:lang/blog/tags` answered 200, in
  no language, from a row nobody could reach that way on purpose. The dynamic matcher was never
  consulted, which is why `Languages.admits?/3` did not stop it — `/xyz/blog` was refused all
  along, and only the pattern's own text got through.

  Every capture is refused, not just `lang`: `/post/:slug` would otherwise answer with `:slug` as
  the slug, and `*rest` the same. `dynamic_path?/1` is the same predicate that decides what earns a
  dynamic row, so a path is a pattern here exactly when it is one there.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, map(), map()} | {:error, :not_found}
  def resolve(path, site) do
    case dynamic_path?(path) do
      true -> {:error, :not_found}
      false -> stored_or_dynamic(path, site)
    end
  end

  defp stored_or_dynamic(path, site) do
    case :ets.lookup(@path_index, {path, site}) do
      [{{^path, ^site}, id}] ->
        case get(id) do
          {:ok, record} -> {:ok, record, %{}}
          error -> error
        end

      [] ->
        find_by_dynamic_path(path, site)
    end
  end

  @doc """
  The page whose stored path PATTERN matches this request, with the segments it captured.

  A page stored at `/post/:category/:slug` answers `/post/elixir/hello-world` and captures
  `%{"category" => "elixir", "slug" => "hello-world"}`. `*rest` captures everything left, joined,
  which is how one page serves a whole subtree.

  ## Why this is ours and not Phoenix's

  `Phoenix.Router` compiles its routes: the match is generated at BUILD time from macros, so it
  cannot know a path an admin typed into the editor this morning. That is exactly why this app
  routes `live "/*path"` and resolves the rest itself. There is no Phoenix or Plug function that
  matches a runtime pattern STRING against runtime segments — `Plug.Router.Utils.build_path_match/1`
  returns AST for the compiler — so the matcher below is the part that genuinely has to be ours.

  `MishkaCmsCore.Runtime.Resources.Validations.PathFormat` has always allowed these paths, naming
  "route params like `:id`, and wildcards like `*rest`". Until now nothing matched them.

  ## Precedence

  An exact path always wins: `find_by_path_and_site/2` only reaches this after the literal ETS
  lookup misses, so no URL that resolves today resolves differently.

  Between two patterns that both match, the one with FEWER captures wins — `/post/new` beats
  `/post/:slug`, and `/post/:slug` beats `/*rest`. Ties break on the page's own `priority`, which is
  the field `Page`'s `:by_priority` read already exists to order by, and then on id so the answer is
  stable rather than dependent on ETS order.

  ## A capture named `lang`

  Matches only one of the site's languages, in whichever segment it sits — see
  `MishkaCmsCore.Runtime.Languages`. `/:lang/about` does not answer `/xyz/about`: that pattern is
  passed over as though it had not matched, so the request goes to the next pattern or to the 404.
  The site's languages are read only when some pattern of the site captures `lang`.
  """
  @spec find_by_dynamic_path(String.t(), String.t()) ::
          {:ok, map(), map()} | {:error, :not_found}
  def find_by_dynamic_path(path, site) do
    segments = split(path)
    patterns = :ets.lookup(@dynamic_index, site)

    languages =
      case Enum.any?(patterns, &captures_language?/1) do
        true -> Languages.site_named(site)
        false -> []
      end

    patterns
    |> Enum.flat_map(fn {^site, {pattern, id}} ->
      with {:ok, captured} <- match(pattern, segments, languages),
           true <- edition?(id, captured) do
        [{specificity(pattern), id, captured}]
      else
        _not_this_one -> []
      end
    end)
    |> Enum.sort_by(fn {score, id, _captured} -> {score, priority_of(id), id} end)
    |> case do
      [] ->
        {:error, :not_found}

      [{_score, id, captured} | _rest] ->
        case get(id) do
          {:ok, found} -> {:ok, found, captured}
          _gone -> {:error, :not_found}
        end
    end
  end

  @doc "Whether a stored path is a pattern rather than a literal."
  @spec dynamic_path?(String.t()) :: boolean()
  def dynamic_path?(path) when is_binary(path),
    do: Enum.any?(split(path), &(String.starts_with?(&1, ":") or String.starts_with?(&1, "*")))

  def dynamic_path?(_path), do: false

  # `[]` is a match only when the pattern is spent too — `/post/:slug` must not answer `/post`.
  defp match([], [], _languages), do: {:ok, %{}}

  defp match(["*" <> name | _rest_of_pattern], rest, languages) when rest != [] do
    value = Enum.join(rest, "/")

    case Languages.admits?(name, value, languages) do
      true -> {:ok, %{name => value}}
      false -> :error
    end
  end

  defp match([":" <> name | pattern], [value | rest], languages) when value != "" do
    with true <- Languages.admits?(name, value, languages),
         {:ok, captured} <- match(pattern, rest, languages) do
      {:ok, Map.put(captured, name, value)}
    else
      _no_match -> :error
    end
  end

  defp match([same | pattern], [same | rest], languages), do: match(pattern, rest, languages)

  defp match(_pattern, _segments, _languages), do: :error

  defp captures_language?({_site, {pattern, _id}}),
    do: Languages.captures?(Enum.join(pattern, "/"))

  # Fewer captures is more specific. A `*rest` is the least specific thing a pattern can hold, so it
  # sorts behind every `:param` no matter how many of those there are.
  defp specificity(pattern) do
    Enum.reduce(pattern, 0, fn
      "*" <> _name, score -> score + 1_000
      ":" <> _name, score -> score + 1
      _literal, score -> score
    end)
  end

  # A PAGE ANSWERS ITS OWN LANGUAGE AND NO OTHER. `/:lang/about` written in English IS the English
  # edition — it says so in its `language` — and for as long as `fa` was one of the site's languages
  # it answered `/fa/about` with English text. Its Persian edition is a row of its own, and
  # `MishkaCmsCore.Runtime.PageEditions.translation_path/2` gives that row the LITERAL path
  # `/fa/about`, which `stored_or_dynamic/2` answers before this function is ever reached. So the
  # rule needs no sibling lookup: a pattern speaks for one language, its own.
  #
  # REJECTED IS NOT FOUND-AND-REFUSED. Returning `[]` leaves the candidate out of the sort, so a
  # request still falls through to a less specific pattern — `/fa/guide` can still reach
  # `/:slug/guide` — which is the fall-through `find_by_dynamic_path/2` has always had.
  #
  # A ROW WITH NO LANGUAGE ANSWERS ANY OF THEM: a layout and an error page are not editions of
  # anything, and a pattern that captured no `lang` was not asked about one.
  defp edition?(id, captured) do
    case Map.get(captured, Languages.capture()) do
      nil -> true
      language -> language_of(id) in [nil, language]
    end
  end

  defp language_of(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, _site, _path, _title, _created_at, _section, _priority, language}] -> language
      [] -> nil
    end
  end

  defp priority_of(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, _site, _path, _title, _created_at, _section, priority, _language}] -> -priority
      [] -> 0
    end
  end

  defp split(path), do: path |> String.split("/", trim: true)

  # Only a pattern earns a row here. A literal page is found by the literal index and would only
  # make every miss slower.
  defp maybe_index_dynamic(path, site, id) do
    case dynamic_path?(path) do
      true -> :ets.insert(@dynamic_index, {site, {split(path), id}})
      false -> :ok
    end
  end

  def find_by_path_and_site!(path, site, section \\ "Page") do
    {record, _captured} = found!(stored_or_dynamic(path, site), section)
    record
  end

  @doc """
  `find_by_path_and_site!/3` with the captured segments beside the page.

  Raises the same `NotFoundError`, so a caller that wants the captures does not have to handle a
  different failure than one that does not.
  """
  @spec resolve!(String.t(), String.t(), String.t()) :: {map(), map()}
  def resolve!(path, site, section \\ "Page") do
    found!(resolve(path, site), section)
  end

  defp found!({:ok, %{section: section} = result, captured}, section), do: {result, captured}

  defp found!(_missing, _section) do
    raise MishkaCmsCore.ErrorsExceptions.NotFoundError,
      message: "Sorry, the page you are looking for does not exist or has been moved."
  end

  @doc """
  Fast check if a page exists.
  """
  def exists?(id), do: :ets.member(@main_table, id)

  @doc """
  Fast check if a path exists for a site.
  """
  def path_exists?(path, site), do: :ets.member(@path_index, {path, site})

  @doc """
  Deletes a page by ID and removes from all indexes.
  """
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id}, @write_timeout)

    MishkaInstaller.Event.Hook.call("runtime:state:metadata:changed", %{op: :delete, key: id},
      return: false
    )

    :ok
  end

  @doc """
  Deletes every routing entry for a site and returns the count removed.
  """
  def delete_by_site(site) do
    ids = @site_index |> :ets.match({site, :"$1"}) |> List.flatten()
    Enum.each(ids, &delete/1)
    length(ids)
  end

  @doc """
  Returns the number of pages in the registry.
  """
  def count, do: :ets.info(@main_table, :size)

  @doc """
  Returns the number of pages for a specific site.
  """
  def count_by_site(site) do
    :ets.match(@site_index, {site, :_}) |> length()
  end

  @doc """
  Returns the number of pages for a specific site and section.
  """
  def count_by_site_and_section(site, section) do
    :ets.match(@section_index, {{site, section}, :_}) |> length()
  end

  @doc """
  Clears all data from all tables.
  """
  def clear do
    [@main_table, @path_index, @dynamic_index, @site_index, @section_index, @sort_index]
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
    # Create main table
    :ets.new(@main_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    # Create index tables
    :ets.new(@path_index, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # A BAG KEYED BY SITE, holding only the pages whose path is a pattern. Every request that misses
    # the literal index scans this one, so keeping the non-dynamic pages out of it is what makes the
    # scan a handful of comparisons rather than a walk of the whole site.
    :ets.new(@dynamic_index, [
      :bag,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@site_index, [
      :bag,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@section_index, [
      :bag,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Ordered set for efficient sorting and pagination
    :ets.new(@sort_index, [
      :ordered_set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      main_table_size: :ets.info(@main_table, :size),
      path_index_size: :ets.info(@path_index, :size),
      site_index_size: :ets.info(@site_index, :size),
      section_index_size: :ets.info(@section_index, :size),
      sort_index_size: :ets.info(@sort_index, :size),
      memory: %{
        main_table: :ets.info(@main_table, :memory),
        path_index: :ets.info(@path_index, :memory),
        site_index: :ets.info(@site_index, :memory),
        section_index: :ets.info(@section_index, :memory),
        sort_index: :ets.info(@sort_index, :memory)
      }
    }

    {:reply, stats, state}
  end

  # Serialized routing-write critical section: conflict check + cleanup + the five index writes run
  # atomically in the owner, so two concurrent same-id saves can't leave orphan sort-index rows.
  def handle_call(
        {:save, {id, site, path, title, created_at, section, priority, language}},
        _from,
        state
      ) do
    case :ets.lookup(@path_index, {path, site}) do
      [{{^path, ^site}, existing_id}] when existing_id != id ->
        {:reply, {:error, :path_already_exists}, state}

      _ ->
        cleanup_old_indexes(id)
        :ets.insert(@main_table, {id, site, path, title, created_at, section, priority, language})
        :ets.insert(@path_index, {{path, site}, id})
        maybe_index_dynamic(path, site, id)
        :ets.insert(@site_index, {site, id})
        :ets.insert(@section_index, {{site, section}, id})
        :ets.insert(@sort_index, {{site, section, -priority, created_at}, id})
        {:reply, :ok, state}
    end
  end

  # Serialized delete: cleanup + main-row removal are atomic; the hook fires in the caller.
  def handle_call({:delete, id}, _from, state) do
    cleanup_old_indexes(id)
    :ets.delete(@main_table, id)
    {:reply, :ok, state}
  end

  ####################################################################################
  ##################### (▰˘◡˘▰) Private Helpers (▰˘◡˘▰) ##############################
  ####################################################################################

  defp cleanup_old_indexes(id) do
    case :ets.lookup(@main_table, id) do
      [{^id, site, path, _title, created_at, section, priority, _language}] ->
        :ets.delete(@path_index, {path, site})
        :ets.delete_object(@dynamic_index, {site, {split(path), id}})
        :ets.delete_object(@site_index, {site, id})
        :ets.delete_object(@section_index, {{site, section}, id})
        :ets.delete(@sort_index, {site, section, -priority, created_at})

      [] ->
        :ok
    end
  end

  defp build_sort_pattern(nil, nil) do
    {:"$1", :"$2"}
  end

  defp build_sort_pattern(site, nil) do
    {{site, :"$1", :"$2", :"$3"}, :"$4"}
  end

  defp build_sort_pattern(nil, section) do
    {{:"$1", section, :"$2", :"$3"}, :"$4"}
  end

  defp build_sort_pattern(site, section) do
    {{site, section, :"$1", :"$2"}, :"$3"}
  end

  defp paginate_select(pattern, limit, offset) do
    :ets.match_object(@sort_index, pattern)
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> fetch_pages_from_sort_results()
  end

  defp fetch_pages_from_sort_results(sort_results) do
    sort_results
    |> Enum.map(fn {_sort_key, id} -> id end)
    |> get_many()
  end

  defp get_many(ids) when is_list(ids) do
    Enum.reduce(ids, [], fn id, acc ->
      case :ets.lookup(@main_table, id) do
        [{^id, site, path, title, created_at, section, priority, language}] ->
          [
            %{
              id: id,
              site: site,
              path: path,
              title: title,
              created_at: created_at,
              section: section,
              priority: priority,
              language: language
            }
            | acc
          ]

        [] ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp count_matching(nil, nil) do
    :ets.info(@sort_index, :size)
  end

  defp count_matching(site, nil) do
    :ets.match(@site_index, {site, :_}) |> length()
  end

  # This is less efficient but necessary for counting across all sites
  defp count_matching(nil, section) do
    :ets.match_object(@sort_index, {{:"$1", section, :"$2", :"$3"}, :"$4"})
    |> length()
  end

  defp count_matching(site, section) do
    :ets.match(@section_index, {{site, section}, :_}) |> length()
  end

  ####################################################################################
  ##################### (▰˘◡˘▰) Maintenance functions (▰˘◡˘▰) ########################
  ####################################################################################

  @doc """
  Returns detailed statistics about the registry.
  """
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Rebuilds all indexes from the main table (useful for maintenance).
  """
  def rebuild_indexes do
    [@path_index, @dynamic_index, @site_index, @section_index, @sort_index]
    |> Enum.each(&:ets.delete_all_objects/1)

    :ets.foldl(
      fn {id, site, path, _title, created_at, section, priority, _language}, acc ->
        :ets.insert(@path_index, {{path, site}, id})
        :ets.insert(@site_index, {site, id})
        :ets.insert(@section_index, {{site, section}, id})
        :ets.insert(@sort_index, {{site, section, -priority, created_at}, id})
        acc
      end,
      :ok,
      @main_table
    )
  end
end
