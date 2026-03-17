defmodule MishkaCmsCore.Runtime.Compilers.SitemapCompiler do
  @moduledoc """
  A site's sitemap, built ahead of the request with `Sitemapper` and kept in
  `MishkaCmsCore.Runtime.States.AssetsState` under `{site.name, "sitemap"}` as
  `%{index: index, files: files}`. `MishkaCmsCoreWeb.SeoController` serves it and never builds it.

  ## What goes in it

  Its addresses, each once, the first to name a path keeping it:

    1. the site's pages a search engine may be sent to
       (`MishkaCmsCore.Runtime.PageEditions.indexable/1`), each at its own path when that path is
       literal, and a page whose only capture is the language at one address per language it
       answers (`PageEditions.served_languages/2`);
    2. the site's `seo.sitemap.paths` setting;
    3. what a plugin on `seo:sitemap:urls` adds, below.

  None is listed at the path of a literal page `indexable/1` leaves out — a login-only or a noindex
  one — whichever of them names it: the resolver answers that page there before any pattern. Nor at
  a path a route in front of the pages answers — every `:public` GET or live route of the
  configured extensions (`MishkaCmsCore.ExtensionRouter`), `/robots.txt`, `/sitemap.xml` and this
  sitemap's own files among them — since a page stored there is never served. A `path` that does
  not start with `/` is left out too.

  Every address is absolute, on the site's `host` (`MishkaCmsCore.Helpers.site_url/2`), and so is
  every image: one at a path on the site is made absolute there, one with no scheme
  (`//cdn.example.com/a.jpg`) takes the site's, an `http(s)://` one is kept as it is, and anything
  else, or one with no host, is left out. What a URL may not hold as it is — a space, a control
  character, anything past ASCII — is percent-encoded in both, and an escape already in them is
  kept, so no address breaks the file it is in. A `lastmod` is written to the second.

  ## What is stored

    * `files` — `"sitemap-00001.xml.gz"`, `"sitemap-00002.xml.gz"`… by name, each a gzipped
      `<urlset>` of up to 50,000 addresses and 50 MB, served at `/<name>` as it is stored. At the
      root, because a sitemap may list only the addresses under the folder it is served from;
    * `index` — the plain `<sitemapindex>` of them, served at `/sitemap.xml`, each file listed at
      `https://<host>/<name>` with the time this node first stored those files as its `lastmod`.

  A build that makes the files already stored keeps what is stored, index and all, so a file's
  `lastmod` moves only when its bytes do, and a rebuild that changed nothing — a layout's, a plugin
  chain's — tells a crawler nothing changed. Gzip writes no time into a file, so the same addresses
  make the same bytes. A node that starts again dates its files from its first build.

  A site with nothing to list has no file, and its `index` is a `<sitemapindex>` with no `<sitemap>`
  in it. The sitemaps.org schemas want at least one entry in an index and in a `<urlset>` alike, so
  no document for an empty site validates against them, and Google reports either as an "Empty
  sitemap" rather than failing to fetch it; the index keeps `/sitemap.xml` the same kind of document
  at every size, and a `<urlset>` listed in it would be a second empty one.

  ## seo:sitemap:urls

  A plugin is handed `%{site: site, pages: pages, urls: urls}`:

    * `site` — the site as `MishkaCmsCore.Runtime.States.SiteState` holds it;
    * `pages` — the list of the site's indexable pattern pages holding a capture only their owner can
      fill, `/:lang/blog/:slug`;
    * `urls` — the addresses so far, an `Enumerable` of
      `%{path: String.t(), lastmod: DateTime.t() | nil, images: [String.t()] | nil}`, `images`
      optional.

  It returns the map with its own addresses after them, as a stream read a batch at a time, so a
  site of any size is built without holding its rows — `stream_rows/2` reads a query that way:

      def call(%{site: site, urls: urls} = data),
        do: {:reply, %{data | urls: Stream.concat(urls, posts(site))}}

      defp posts(site) do
        MyExt.Post
        |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
        |> Ash.Query.select([:slug, :updated_at, :cover])
        |> SitemapCompiler.stream_rows(tenant: site.id, authorize?: false)
        |> Stream.map(&%{path: "/posts/" <> &1.slug, lastmod: &1.updated_at, images: [&1.cover]})
      end

  A plugin lists each of its paths once, and none another plugin lists: only a path core lists
  itself is looked for again, so what a build remembers while it reads the stream is core's own
  list, however many rows the plugins add.

  Nothing is read while the chain runs: the build reads the stream once, after it, so a stream that
  raises then fails the build — the job is retried as Oban retries any, and the sitemap stored
  before is served meanwhile. A chain that ends in a `urls` that is not an `Enumerable` is ignored,
  and core's own addresses are built alone.

  ## When it is built

  At boot, by every node for every open site, two at a time
  (`MishkaCmsCore.Runtime.Handlers.BootHandler.build_sitemaps/0`). After that, by the site's
  `"sitemap"` job, on a `:sitemaps` queue of its own, that `schedule/1` enqueues when what it lists
  changes:

    * a page or a layout — `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker`, after its own;
    * the site switched on, renamed or installed — `BootHandler.compile_site/2`; its host —
      `MishkaCmsCore.Runtime.Resources.Changes.ScheduleSiteRuntime`;
    * its languages or its `seo.sitemap.paths`, and a row an extension lists —
      `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`;
    * a `seo:sitemap:urls` plugin started or stopped — every open site's (`attach/0`).

  A site has one such job pending at a time — a build that failed and waits to retry counts — and
  each enqueue moves it later, so a burst of changes is one build. A build is given ten minutes and
  three tries. A request that finds no sitemap enqueues it too, but leaves a pending or running one
  where it is, so requests coming faster than it is due cannot keep putting it off or start a
  second.

  An extension whose `seo:sitemap:urls` plugin lists rows of its own resources adds
  `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh` to those resources' `notifiers:`, or
  calls `schedule/1` with the row's site where no notifier sees the change.

  Each node keeps its own copy. A job rebuilds it only on the node that runs it, so another node
  serves its previous one until its own next build (`ROADMAP_DISTRIBUTED_CMS.md`, row 17).

  ## Hooks

    * `runtime:compile:before_sitemap` — `%{site: site_name}`, before a build;
    * `seo:sitemap:urls` — the addresses a plugin adds, above;
    * `runtime:compile:after_sitemap` — `%{site: site_name, urls: count, files: count}`, once it is
      stored or the stored one is kept.

  Storing a changed one fires `runtime:state:assets:changed` (`AssetsState.save/1`).
  """
  require Ash.Query

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Hook, ModuleStateCompiler}

  # Sitemapper writes nothing at all for no address, so a site with nothing to list gets this.
  @empty_index """
  <?xml version="1.0" encoding="UTF-8"?>
  <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  </sitemapindex>
  """

  @handler_id "mishka-cms-core-sitemap-plugins"
  @event [:mishka_installer, :event, :compile]
  @urls_event "seo:sitemap:urls"

  # The `seo:sitemap:urls` chain this node last rebuilt every sitemap for.
  @chain_key {__MODULE__, :chain}

  # The most rows `stream_rows/2` reads at a time.
  @batch 100

  @typedoc "A site's stored sitemap: its plain index, and its gzipped files by name."
  @type sitemap :: %{index: binary(), files: %{String.t() => binary()}}

  @doc """
  Builds the sitemap of the site named `site_name` and stores it in this node's `AssetsState`.

  `{:error, :no_site}` when `SiteState` holds no open site by that name, before the build or once it
  is done: a site switched off, removed or renamed while it was built has nothing stored.
  """
  @spec compile_and_store(String.t()) :: {:ok, sitemap()} | {:error, :no_site}
  def compile_and_store(site_name) do
    case SiteState.get_by_name(site_name) do
      {:ok, %{active: true} = site} -> store(site)
      _not_open -> {:error, :no_site}
    end
  end

  @doc """
  Enqueues the `"sitemap"` job of the site `site_id` names, or of every open site for `nil` — a
  global row.

  A switched-off or unknown site has nothing to build, and is `:ok`. So is every call under the
  `:env_test?` flag, as for every other runtime job.

  ## Options

    * `:replace` — what an enqueue changes on the site's job already pending, as Oban's `:replace`.
      Unset, it moves the job later; `[]` leaves it where it is.
    * `:states` — the states of a job already there that this enqueue leaves as it is instead of
      adding one, as Oban's `unique: [states: ...]`. Unset, a pending one or one waiting to retry;
      `:incomplete` a running one too.
  """
  @spec schedule(String.t() | nil, keyword()) :: :ok | {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(site_id, opts \\ []) do
    if Application.get_env(:mishka_cms_core, :env_test?, false),
      do: :ok,
      else: enqueue(site_id, opts)
  end

  @doc """
  Every row `query` reads, as a stream that reads `#{@batch}` at a time: each read starts after the
  last `id` the one before it returned, one indexed step however many rows come before it, where an
  offset would walk them all again on every page.

  `query` is an `Ash.Query.for_read/4` of an action that paginates, on a resource whose primary key
  is `id`. It is read in `id` order whatever order it asks for, with `id` selected beside what it
  selects. `opts` are `Ash.read!/2`'s — the tenant, `authorize?`.
  """
  @spec stream_rows(Ash.Query.t(), keyword()) :: Enumerable.t()
  def stream_rows(%Ash.Query{} = query, opts) do
    query =
      query
      |> Ash.Query.ensure_selected([:id])
      |> Ash.Query.unset(:sort)
      |> Ash.Query.sort(id: :asc)

    Stream.resource(fn -> :first end, &next_rows(&1, query, opts), fn _last -> :ok end)
  end

  defp next_rows(:done, _query, _opts), do: {:halt, :done}

  defp next_rows(last, query, opts) do
    case query |> after_id(last) |> Ash.read!(Keyword.put(opts, :page, limit: @batch)) do
      %{results: [_ | _] = rows, more?: true} -> {rows, List.last(rows).id}
      %{results: rows} -> {rows, :done}
    end
  end

  defp after_id(query, :first), do: query
  defp after_id(query, id), do: Ash.Query.filter(query, id > ^id)

  @doc "Attach the rebuild to mishka_installer's compile telemetry. Idempotent."
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_telemetry/4, nil)
    :ok
  end

  # A `seo:sitemap:urls` CHAIN CHANGED IS EVERY SITE'S SITEMAP CHANGED. `Hook.call/3` hands the
  # payload back unchanged while an event's chain is not compiled, so a sitemap built before a plugin
  # registered leaves its addresses out, and a plugin started or stopped adds or takes away its own.
  #
  # ONLY A CHAIN THAT CHANGED: mishka_installer reports a compile of every event whenever a node
  # joins, whether or not anything was rebuilt, and the chain it compiled is compared with the one
  # this node last rebuilt for. The jobs are enqueued in a task, never in its event handler, which
  # every other compile waits on.
  #
  # Only while `BootHandler` is up, because then Oban, `SiteState` and the task supervisor are: it
  # starts last, and never under test. A guard, not a rescue — `:telemetry` detaches a handler that
  # raises.
  @doc false
  def handle_telemetry(@event, _measurements, %{event: @urls_event, result: :ok}, _config) do
    chain = chain()

    if chain != :persistent_term.get(@chain_key, :none_yet) do
      :persistent_term.put(@chain_key, chain)

      if Process.whereis(BootHandler) do
        _ =
          Task.Supervisor.start_child(MishkaCmsCore.Runtime.TaskSupervisor, fn ->
            schedule(nil)
          end)
      end
    end

    :ok
  end

  def handle_telemetry(_event, _measurements, _meta, _config), do: :ok

  # What the compiled chain holds — its plugins and whether it can call them — as mishka_installer
  # decides whether to rebuild it.
  defp chain do
    module = ModuleStateCompiler.module_event_name(@urls_event)

    if Code.ensure_loaded?(module) and function_exported?(module, :initialize, 0),
      do: :erlang.phash2({module.mode(), module.initialize().plugins})
  end

  defp enqueue(nil, _opts), do: BootHandler.create_assets_compilation_jobs("sitemap")

  defp enqueue(site_id, opts) do
    case SiteState.get(site_id) do
      {:ok, %{active: true} = site} ->
        site.name
        |> BootHandler.asset_job(site.id, "sitemap", Keyword.take(opts, [:replace, :states]))
        |> Oban.insert()

      _nothing_to_build ->
        :ok
    end
  end

  defp store(site) do
    Hook.call("runtime:compile:before_sitemap", %{site: site.name},
      meta: %{site: site.name},
      return: false
    )

    counted = :counters.new(1, [])

    # The one pass over the addresses: each file is gzipped as it fills, and only the files are kept.
    sitemap =
      site
      |> urls()
      |> Stream.each(fn _url -> :counters.add(counted, 1, 1) end)
      |> Sitemapper.generate(
        sitemap_url: Helpers.site_url(site.host, "/"),
        gzip: true,
        index_lastmod: DateTime.truncate(DateTime.utc_now(), :second)
      )
      |> Enum.reduce(%{index: @empty_index, files: %{}}, &collect/2)

    save(SiteState.get(site.id), site, sitemap, :counters.get(counted, 1))
  end

  # The index comes last, gzipped like the files; it is unzipped here once, so no request does.
  defp collect({"sitemap.xml.gz", index}, sitemap), do: %{sitemap | index: :zlib.gunzip(index)}
  defp collect({name, file}, sitemap), do: %{sitemap | files: Map.put(sitemap.files, name, file)}

  # THE SITE IS LOOKED UP AGAIN ONCE IT IS BUILT, because a large one takes seconds and it may be
  # switched off, removed or renamed meanwhile, its parts purged by name
  # (`MishkaCmsCore.Runtime.Handlers.SiteRuntime.purge_parts/3`). Stored after that, the sitemap
  # would outlive it, and a site given its name later would be served this one.
  defp save({:ok, %{name: name, active: true}}, %{name: name} = site, sitemap, urls) do
    sitemap = kept_or_stored(site.name, sitemap)

    Hook.call(
      "runtime:compile:after_sitemap",
      %{site: site.name, urls: urls, files: map_size(sitemap.files)},
      meta: %{site: site.name},
      return: false
    )

    {:ok, sitemap}
  end

  defp save(_gone, _site, _sitemap, _urls), do: {:error, :no_site}

  # THE FILES ALREADY STORED KEEP THEIR INDEX, whose `lastmod` is when they were stored.
  defp kept_or_stored(name, %{files: files} = sitemap) do
    case AssetsState.get_value(name, "sitemap") do
      %{index: _index, files: ^files} = stored ->
        stored

      _changed ->
        :ok =
          AssetsState.save(%{
            id: name,
            type: "sitemap",
            value: sitemap,
            hash: nil,
            updated_at: DateTime.utc_now()
          })

        sitemap
    end
  end

  defp urls(site) do
    {own, pages, hidden} = own_urls(site)

    urls =
      case Hook.call(@urls_event, %{site: site, pages: pages, urls: own}) do
        %{urls: added} -> if Enumerable.impl_for(added), do: added, else: own
        _refused -> own
      end

    rules = %{own: MapSet.new(own, & &1.path), hidden: hidden, routes: routed()}

    urls
    |> Stream.filter(&match?(%{path: "/" <> _}, &1))
    |> Stream.transform(MapSet.new(), &once(&1, &2, rules))
    |> Stream.map(&url(&1, site.host))
  end

  # Core's own addresses, each once: the site's pages, then its `seo.sitemap.paths`. A list, because
  # they come from one read of its pages already held, and their paths are all `once/3` remembers.
  defp own_urls(site) do
    {page_urls, pages, hidden} = page_urls(site.id)

    listed =
      for path <- List.wrap(Settings.get("seo.sitemap.paths", [], site.id)),
          is_binary(path),
          do: %{path: path, lastmod: nil}

    {Enum.uniq_by(page_urls ++ listed, & &1.path), pages, hidden}
  end

  # A literal page at its path; a page whose only capture is the language at one address per
  # language it answers; any other pattern page goes to the plugins, which own what fills it.
  defp page_urls(site_id) do
    {indexable, hidden} = PageEditions.indexable(site_id)
    {literals, patterns} = Enum.split_with(indexable, &PageEditions.path(&1.path, %{}))

    {swappable, pages} = Enum.split_with(patterns, &PageEditions.language_only?(&1.path))

    urls =
      Enum.map(literals, &%{path: PageEditions.path(&1.path, %{}), lastmod: &1.updated_at}) ++
        Enum.flat_map(swappable, fn page ->
          for language <- PageEditions.served_languages(page, site_id) do
            path = PageEditions.path(page.path, %{Languages.capture() => language})
            %{path: path, lastmod: page.updated_at}
          end
        end)

    {urls, pages, hidden}
  end

  # Each address where a visitor is sent to it, and once. ONLY CORE'S OWN PATHS ARE REMEMBERED, the
  # first to name one keeping it: a plugin lists each of its own once, so what this holds while the
  # stream is read is core's own list, and never grows with the rows.
  defp once(%{path: path} = entry, seen, rules) do
    cond do
      MapSet.member?(rules.hidden, path) or routed?(path, rules.routes) -> {[], seen}
      not MapSet.member?(rules.own, path) -> {[entry], seen}
      MapSet.member?(seen, path) -> {[], seen}
      true -> {[entry], MapSet.put(seen, path)}
    end
  end

  # The paths a route in front of the pages answers, each as its segments: every `:public` GET or
  # live route of the configured extensions, which the router mounts before its page catch-all.
  defp routed do
    for extension <- Application.get_env(:mishka_cms_core, :extensions, []),
        routes <- [Module.concat(extension, Routes)],
        Code.ensure_loaded?(routes) and function_exported?(routes, :routes, 1),
        route <- routes.routes(:public),
        elem(route, 0) in [:get, :live],
        do: String.split(elem(route, 1), "/", trim: true)
  end

  defp routed?(_path, []), do: false

  defp routed?(path, routes) do
    [path | _query] = String.split(path, ["?", "#"], parts: 2)
    segments = String.split(path, "/", trim: true)
    Enum.any?(routes, &answers?(&1, segments))
  end

  # As Phoenix matches a path: a `:param` segment takes any one, one with text before its `:` any
  # that starts with that text, and a `*glob` the rest.
  defp answers?([], []), do: true
  defp answers?(["*" <> _glob | _rest], _segments), do: true

  defp answers?([pattern | patterns], [segment | segments]),
    do: segment_answers?(pattern, segment) and answers?(patterns, segments)

  defp answers?(_patterns, _segments), do: false

  defp segment_answers?(pattern, segment) do
    case String.split(pattern, ":", parts: 2) do
      [literal] -> literal == segment
      [prefix, _param] -> String.starts_with?(segment, prefix)
    end
  end

  defp url(entry, host) do
    %Sitemapper.URL{
      loc: host |> Helpers.site_url(entry.path) |> encoded(),
      lastmod: lastmod(Map.get(entry, :lastmod)),
      images: for(image <- List.wrap(Map.get(entry, :images)), loc <- image(image, host), do: loc)
    }
  end

  defp lastmod(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp lastmod(_unknown), do: nil

  defp image(image, host) when is_binary(image) do
    case encoded(image) do
      "//" <> _ = url -> hosted(URI.to_string(URI.merge(Helpers.site_url(host, "/"), url)))
      "/" <> _ = path -> hosted(Helpers.site_url(host, path))
      "http://" <> _ = url -> hosted(url)
      "https://" <> _ = url -> hosted(url)
      _not_an_address -> []
    end
  end

  defp image(_not_an_address, _host), do: []

  # An http(s) URL naming a host, as Sitemapper takes an image.
  defp hosted(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        [%{loc: url}]

      _not_one ->
        []
    end
  end

  # Every character a URL may not hold as it is, percent-encoded, and every escape already in it
  # kept: a control character left in would make the whole file invalid XML.
  defp encoded(url), do: URI.encode(url, &(&1 == ?% or URI.char_unescaped?(&1)))
end
