# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.BootHandler do
  @moduledoc """
  Application boot handler for MishkaCms runtime system initialization and asset compilation.

  The `BootHandler` orchestrates the complete startup sequence for the MishkaCms runtime system,
  managing the loading of sites, compilation of templates and modules, and initialization of
  various runtime states. It ensures all essential components are properly loaded and compiled
  before the application becomes available to serve requests.

  ## Features

  * **Parallel Boot Process**: Executes multiple initialization tasks concurrently for optimal startup time
  * **Site Management**: Loads and caches site configurations in optimized batches
  * **Template Compilation**: Compiles pages, layouts, components, and error pages into runtime modules
  * **Asset Pipeline Integration**: Creates compilation jobs for CSS and JavaScript assets
  * **Error Recovery**: Provides detailed error reporting and graceful failure handling
  * **Performance Optimization**: Uses adaptive batch sizing based on dataset size
  * **Resource Cleanup**: Manages temporary files and cleans up stale Oban jobs

  ## Boot Process Overview

  The boot process executes the following tasks in parallel:

  1. **Site Loading**: Loads all active sites into `SiteState` for efficient lookups
  2. **Component Compilation**: Compiles reusable UI components into runtime modules
  3. **Error Page Compilation**: Builds error handling pages for each site
  4. **Layout Compilation**: Compiles page layouts and templates
  5. **JavaScript Hooks**: Processes JS hooks for Phoenix LiveView integration
  6. **Page Compilation**: Compiles individual content pages
  7. **Asset Jobs**: Schedules CSS and JavaScript compilation jobs

  Once they are done, every open site's sitemap is built on this node (`build_sitemaps/0`), and
  every open site's warm job is queued for this node: it builds the modules of the components the
  site reaches that are not precompiled, so no visitor's first request compiles them
  (`warm_components/2`).

  ## Architecture Integration

  The BootHandler integrates with several MishkaCms subsystems:

  * **SiteState**: Caches site configurations for runtime lookups
  * **WebRunTimeMetaDataState**: Stores page metadata and routing information
  * **ModuleCompilerHandler**: Handles dynamic module compilation
  * **RuntimeCompilerWorker**: Manages background asset compilation via Oban
  * **TailwindCompiler**: Generates CSS assets for each site

  ## Performance Configuration

  The boot process automatically adapts to dataset sizes:

      # Batch configuration scales with data volume
      # <= 1,000 items:    batch_size: 1,000,  chunk_size: 250
      # <= 5,000 items:    batch_size: 2,000,  chunk_size: 500
      # <= 20,000 items:   batch_size: 5,000,  chunk_size: 1,000
      # <= 100,000 items:  batch_size: 10,000, chunk_size: 2,000
      # > 100,000 items:   batch_size: 20,000, chunk_size: 5,000

  ## Template and Asset Management

  The BootHandler creates template files for Tailwind CSS compilation:

      # Template files are organized by site and type:
      # priv/static/temp/runtime/
      # ├── site1/
      # │   ├── page/
      # │   ├── layout/
      # │   ├── component/
      # │   └── error/
      # ├── site2/
      # │   └── ...
      # └── __global__/
      #     └── ...

  ## Production Considerations

  * **Startup Time**: Boot time scales with data volume; typical startup: 1-5 seconds
  * **Memory Usage**: Sites and metadata are cached in memory for performance
  * **Concurrency**: Uses all available CPU cores for parallel compilation
  * **Resource Cleanup**: Automatically cleans up stale Oban jobs and temporary files
  * **Error Recovery**: Failed individual items don't prevent overall boot success
  * **Asset Pipeline**: Integrates with background job processing for asset compilation
  """
  use GenServer
  require Ash.Query
  require Logger

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.States.CompileFailureState
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.Helpers
  alias MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState
  alias MishkaCmsCore.Runtime.Compilers.CssClosure
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.CodeAudit
  alias MishkaCmsCore.Runtime.PageLanguageBackfill
  alias MishkaCmsCore.Runtime.ShareCardQueue
  import Ecto.Query
  ####################################################################################
  ########################### (▰˘◡˘▰) Client API (▰˘◡˘▰) #############################
  ####################################################################################
  @doc """
  Starts the BootHandler GenServer as part of the application supervision tree.

  This function is typically called automatically by the application supervisor.
  The BootHandler runs as a named process and immediately begins the boot sequence
  upon initialization.

  ## Parameters

  * `opts` - Optional GenServer options (defaults to empty list)

  ## Return Values

  * `{:ok, pid}` - Successfully started the GenServer
  * `{:error, reason}` - Failed to start the GenServer

  ## Examples

      # Manual start (usually not needed as it's supervised)
      {:ok, pid} = BootHandler.start_link()

      # Start with custom GenServer options
      {:ok, pid} = BootHandler.start_link(debug: [:trace])

  ## Supervision Tree Integration

      # In your application.ex
      children = [
        # ... other processes
        MishkaCmsCore.Runtime.Handlers.BootHandler
      ]
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieves the current boot status of the application.

  This function provides real-time information about the boot process state,
  which is essential for health checks, monitoring systems, and ensuring the
  application is ready to serve requests.

  ## Return Values

  * `:ready` - Boot process completed successfully, application is ready
  * `:initializing` - Boot process is currently running
  * `{:failed, reason}` - Boot process failed with specific error information

  ## Monitoring Integration

      # Continuous monitoring in a GenServer
      def handle_info(:check_status, state) do
        status = BootHandler.get_status()

        # Update external monitoring systems
        :telemetry.execute([:boot, :status], %{}, %{status: status})

        {:noreply, %{state | boot_status: status}}
      end
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  ####################################################################################
  ########################### (▰˘◡˘▰) Server API (▰˘◡˘▰) #############################
  ####################################################################################
  @doc """
  When this node started — the moment every compile job created before it stopped describing
  anything: the boot cancels those still pending (`cancel_leftover_jobs/0`) and compiles from the
  database itself, without a job.
  """
  @spec booted_at() :: DateTime.t()
  def booted_at do
    {since_boot, _since_last_call} = :erlang.statistics(:wall_clock)
    DateTime.add(DateTime.utc_now(), -since_boot, :millisecond)
  end

  @boot_id_key {__MODULE__, :boot_id}

  @doc """
  This running instance's own id, made when `:mishka_cms_core` starts (`new_boot_id/0`) and `nil`
  before then.

  Every bundle job carries it (`asset_job/4`), and `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker`
  builds the job on the instance it names: the CSS, JS and sitemap a bundle job builds go into that
  instance's own `MishkaCmsCore.Runtime.States.AssetsState`. A deploy that starts the next instance
  beside the old one gives both the same `node()` and the same Oban queue; this id is what tells them
  apart.
  """
  @spec boot_id() :: String.t() | nil
  def boot_id, do: :persistent_term.get(@boot_id_key, nil)

  @doc """
  Gives this instance a new `boot_id/0`. Called once, by `MishkaCmsCore.Application.start/2`.
  """
  @spec new_boot_id() :: :ok
  def new_boot_id, do: :persistent_term.put(@boot_id_key, Ecto.UUID.generate())

  @doc """
  Cancels every runtime compile job a previous run left pending or executing, in whichever queue it
  was put — the boot rebuilds what they would have. Other workers' jobs (mail, notifications) are
  left to `Oban.Lifeline`.
  """
  @spec cancel_leftover_jobs() :: {:ok, non_neg_integer()}
  def cancel_leftover_jobs do
    Oban.Job
    |> where([j], j.state in ["available", "scheduled", "retryable", "executing"])
    |> where(worker: "MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker")
    |> Oban.cancel_all_jobs()
  end

  @doc """
  Whether the running Oban rescues jobs a stopped node left executing (`lifeline:` in the app's
  Oban config). Without it, a mail or notification job interrupted by a restart stays `executing`.
  """
  @spec lifeline?() :: boolean()
  def lifeline?, do: Enum.any?(Oban.config().plugins, &match?({Oban.Lifeline, _opts}, &1))

  @impl true
  def init(_opts) do
    {:ok, %{status: :initializing, started_at: System.monotonic_time(:millisecond)},
     {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    Logger.info("[BootHandler] Starting boot process...")

    _ = cancel_leftover_jobs()

    if Oban.config().testing == :disabled and not lifeline?(),
      do:
        Logger.warning(
          "[BootHandler] Oban runs without Lifeline: a job a restart interrupts stays executing. Add `lifeline: [rescue_after: {30, :minutes}]` to the app's Oban config."
        )

    new_state =
      case perform_boot() do
        :ok ->
          boot_time = System.monotonic_time(:millisecond) - state.started_at
          Logger.notice("[BootHandler] Boot completed in #{boot_time}ms")
          %{state | status: :ready}

        {:error, reason} ->
          Logger.error("[BootHandler] Boot failed: #{inspect(reason)}")

          %{state | status: {:failed, reason}}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################
  defp perform_boot do
    boot_start = System.monotonic_time(:millisecond)

    MishkaCmsCore.Install.refresh!()
    MishkaCmsCore.Settings.load_definitions()

    # The `:share_cards` queue starts paused, and draws once the stored number of workers is read.
    _ = ShareCardQueue.boot()

    # BEFORE THE COMPILES, because a compiled page carries its language group. A failure is reported
    # and the boot goes on: a page with no group still serves, and is given one when it is next saved
    # or first translated.
    case PageLanguageBackfill.run() do
      {:ok, 0} ->
        :ok

      {:ok, changed} ->
        Logger.info("[BootHandler] #{changed} pages given a language group of their own")

      {:error, reason} ->
        Logger.error("[BootHandler] Page language groups: #{inspect(reason)}")
    end

    toolchain = ensure_asset_toolchain()

    tasks = [
      Task.async(fn -> {:sites, load_sites()} end),
      Task.async(fn -> {:components, compile_components()} end),
      Task.async(fn -> {:error_pages, compile_error_pages()} end),
      Task.async(fn -> {:layouts, compile_layouts()} end),
      Task.async(fn -> {:js_hooks, create_js_hooks_template()} end),
      Task.async(fn -> {:pages, compile_pages()} end),
      Task.async(fn -> {:stylesheets, load_stylesheets()} end)
    ]

    results = Task.await_many(tasks, :timer.minutes(5))

    {_successful, failed} =
      Enum.split_with(results, fn
        {_name, :ok} -> true
        _ -> false
      end)

    _ = TailwindCompiler.compile_and_store_shared_base()
    _ = create_assets_compilation_jobs()

    # AFTER the passes that write every template file and fill `SiteState`, which is what the warm
    # walk reads. On its own queue, so it starts beside the bundle build rather than behind it.
    _ = create_assets_compilation_jobs("warm")

    # AFTER `load_sites`, the only pass that fills `SiteState`, and here rather than in a job so
    # every node fills its own cache.
    _ = build_sitemaps()

    # AFTER the compiles, because `CodeSignature` names each unverified snippet as it turns it into
    # an inert clause and this is the total of those lines rather than a separate opinion. Reads
    # nothing at all unless a signing key is configured.
    _ = CodeAudit.report()

    boot_time = System.monotonic_time(:millisecond) - boot_start
    site_count = MishkaCmsCore.Runtime.States.SiteState.count()

    Logger.info(
      "[BootHandler] #{site_count} sites queued for CSS/JS compilation in #{boot_time}ms"
    )

    failed_names = Enum.map(failed, fn {name, _} -> name end) ++ toolchain

    if failed_names == [] do
      Logger.info("[BootHandler] All boot tasks completed successfully")
      :ok
    else
      Logger.error("[BootHandler] Boot tasks failed: #{inspect(failed_names)}")
      {:error, {:boot_tasks_failed, failed_names}}
    end
  end

  # AN ASSET TOOLCHAIN THAT WILL NOT INSTALL MUST NOT TAKE THE BOOT WITH IT. Both `ensure_installed/0`
  # calls download on a machine that has no binary yet, and both raise on a non-200, a bad checksum
  # or a DNS failure — so on an airgapped or proxied host an unguarded call crashed this GenServer,
  # and `:one_for_one` turned that into a restart loop that took the supervisor down. Everything the
  # site serves that is not a fresh bundle was fine.
  #
  # So the failure is recorded and the boot goes on: sites, pages and components still load, and the
  # compiles that actually need the binary fail on their own and say which one is missing. The names
  # ride out with the other boot failures, so the status is still `{:failed, _}` and nobody reads a
  # half-built runtime as a healthy one.
  defp ensure_asset_toolchain do
    [
      {:tailwind, &TailwindCompiler.ensure_installed/0},
      {:esbuild, &JavaScriptCompiler.ensure_installed/0}
    ]
    |> Enum.flat_map(fn {name, ensure} ->
      try do
        _ = ensure.()
        []
      rescue
        error ->
          Logger.error(
            "[BootHandler] #{name} is unavailable, continuing without it: #{Exception.message(error)}"
          )

          [name]
      end
    end)
  end

  @doc """
  Streams every site from the DB in tuned batches and upserts them into `SiteState`'s ETS cache.

  This is the single site-cache loader: `perform_boot/0` runs it at startup, and
  `SiteState.handle_continue/2` reuses it to self-heal after an owner crash. Streaming (rather than
  materializing all rows at once) keeps memory bounded and startup fast even with tens of thousands
  of sites. A load error is logged and returned as `{:error, reason}` — a failure here must not
  abort boot or crash-loop the cache owner.
  """
  @spec load_sites() :: :ok | {:error, term()}
  def load_sites do
    try do
      site_count = Ash.count!(MishkaCmsCore.Runtime.Site, authorize?: false)

      if site_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(site_count)

        process_site_chunk =
          fn sites ->
            site_maps =
              Enum.map(sites, fn site ->
                %{
                  id: site.id,
                  name: site.name,
                  host: site.host,
                  priority: site.priority,
                  active: site.active,
                  master: site.master,
                  mode: site.mode,
                  frontend_domain: site.frontend_domain,
                  allowed_origins: site.allowed_origins
                }
              end)

            SiteState.save_batch(site_maps)
          end

        MishkaCmsCore.Runtime.Site
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)
        |> Ash.stream!(batch_size: batch_size, authorize?: false)
        |> Stream.chunk_every(chunk_size)
        |> Stream.each(process_site_chunk)
        |> Stream.run()

        :ok
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading sites: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Builds one routing-metadata row for `WebRunTimeMetaDataState` from a Page/Layout/ErrorPage
  record (its `:site` must be loaded). `section` is the row kind — `"Page"`, `"Layout"`, or
  `"ErrorPage"`. Shared by the boot passes and `load_web_metadata/0`.

  ## Examples

      web_metadata_row(page, "Page")
      #=> %{id: page.id, site: "example", path: "/about", title: "About", ...}
  """
  def web_metadata_row(record, section) do
    %{
      id: record.id,
      site: (record.site && record.site.name) || "Global",
      path: record.path,
      title: record.name,
      created_at: record.updated_at,
      section: section,
      priority: record.priority,
      # ONLY A PAGE IS AN EDITION OF ANYTHING, and not even every page. A layout and an error page
      # carry no language; neither does a page built from components that read the captured one —
      # see `MishkaCmsCore.Runtime.PageProvision.serves_all_languages?/1`. `nil` reaches
      # `WebRunTimeMetaDataState`'s `edition?/2` as "answers whichever language the URL captured",
      # which is what all three want.
      language: MishkaCmsCore.Runtime.PageProvision.routing_language(record)
    }
  end

  @doc """
  Repopulates `WebRunTimeMetaDataState`'s routing rows from the DB — the crash/boot self-heal path
  reused by `WebRunTimeMetaDataState.handle_continue/2`.

  Streams active Page/Layout/ErrorPage rows in tuned batches and upserts ONLY their routing
  metadata (id/site/path/title/section/priority) via `save_batch/1` — it never writes templates or
  recompiles modules (that stays in the boot passes). A DB error is logged and returned rather than
  raised: this runs once per (re)start, not on the hot path, so a transient outage must not
  crash-loop the owner.

  ## Examples

      # after a WebRunTimeMetaDataState crash wiped the routing tables, or at boot
      BootHandler.load_web_metadata()
      #=> :ok
  """
  @spec load_web_metadata() :: :ok | {:error, term()}
  def load_web_metadata do
    # BEFORE THE ROUTING ROWS ARE BUILT FROM THEM, because the mark is what decides the `language`
    # each row is stored with — see `MishkaCmsCore.Runtime.PageProvision.routing_language/1`. A
    # site provisioned before extensions carried the mark would otherwise boot with `/fa/blog`
    # answering nothing until it was provisioned again. It is a no-op on the second boot and every
    # boot after it.
    case MishkaCmsCore.Runtime.PageLanguageBackfill.mark_extension_pages() do
      {:ok, 0} ->
        :ok

      {:ok, marked} ->
        Logger.info("[BootHandler] #{marked} extension pages marked all-language")

      {:error, reason} ->
        Logger.error("[BootHandler] language scope backfill: #{inspect(reason)}")
    end

    stream_metadata(MishkaCmsCore.Runtime.Page, "Page")
    stream_metadata(MishkaCmsCore.Runtime.Layout, "Layout")
    stream_metadata(MishkaCmsCore.Runtime.ErrorPage, "ErrorPage")
    :ok
  rescue
    error ->
      Logger.error("[BootHandler] Error loading web metadata: #{inspect(error)}")
      {:error, error}
  end

  defp stream_metadata(resource, section) do
    query =
      resource
      |> Ash.Query.for_read(:read_any)
      |> Ash.Query.filter(active == true)
      |> Ash.Query.load([:site])
      |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

    count = Ash.count!(query, authorize?: false)

    if count == 0 do
      :ok
    else
      {batch_size, chunk_size} = get_optimal_batch_config(count)

      query
      |> Ash.stream!(batch_size: batch_size, authorize?: false)
      |> Stream.chunk_every(chunk_size)
      |> Stream.each(fn chunk ->
        WebRunTimeMetaDataState.save_batch(Enum.map(chunk, &web_metadata_row(&1, section)))
      end)
      |> Stream.run()

      :ok
    end
  end

  @doc """
  Maps one `Task.async_stream` element from a boot compile pass to a compile outcome.

  Every pass runs with `on_timeout: :kill_task`, so an item that exceeds the pass timeout arrives
  here as `{:exit, :timeout}` (never a raised crash) — this keeps one pathological template from
  aborting the whole boot. A successful item is either `nil` (compiled cleanly, nothing to report)
  or an `{:error, _}` tuple for a broken-but-skipped item.

  ## Examples

      classify_compile_stream_result({:ok, nil})
      #=> nil

      classify_compile_stream_result({:ok, {:error, :not_found}})
      #=> {:error, :not_found}

      classify_compile_stream_result({:exit, :timeout})
      #=> {:compilation_exit, :timeout}
  """
  @spec classify_compile_stream_result({:ok, term()} | {:exit, term()}) :: term()
  def classify_compile_stream_result({:ok, nil}), do: nil
  def classify_compile_stream_result({:ok, error_tuple}), do: error_tuple
  def classify_compile_stream_result({:exit, reason}), do: {:compilation_exit, reason}

  @doc """
  Recompiles every active dependent part of a single site — the per-site
  counterpart to the boot passes. Writes templates + routing for active records,
  compiles the precompiled modules, and rebuilds the site's CSS/JS bundle and its
  sitemap. Used by the Site runtime worker on activate / unarchive / rename.
  """
  def compile_site(site_id, site_name) do
    MishkaInstaller.Event.Hook.call(
      "runtime:boot:before_compile_site",
      %{site_id: site_id, site_name: site_name},
      return: false
    )

    compile_components(site_id)
    compile_layouts(site_id)
    compile_error_pages(site_id)
    compile_pages(site_id)
    load_stylesheets(site_id)
    create_js_hooks_template(site_id)

    site_name |> asset_job(site_id, "asset") |> Oban.insert()
    site_name |> asset_job(site_id, "sitemap") |> Oban.insert()

    MishkaInstaller.Event.Hook.call(
      "runtime:boot:after_compile_site",
      %{site_id: site_id, site_name: site_name},
      return: false
    )

    :ok
  end

  # Scopes a boot pass to one site. `nil` keeps the all-sites boot behaviour;
  # a site_id restricts to that site's own (non-global) records.
  defp maybe_filter_site(query, nil), do: query
  defp maybe_filter_site(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp compile_error_pages(site_id \\ nil) do
    try do
      query =
        MishkaCmsCore.Runtime.ErrorPage
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true)
        |> maybe_filter_site(site_id)
        |> Ash.Query.load([:error_module, :site])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      error_page_count = Ash.count!(query, authorize?: false)

      if error_page_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(error_page_count)

        failed_compilations =
          query
          |> Ash.stream!(batch_size: batch_size, authorize?: false)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn err ->
                # Create .template file for error page
                build_error_template_content(err)
                |> then(&create_template_file(err.site && err.site.name, "error", err.name, &1))

                WebRunTimeMetaDataState.save(web_metadata_row(err, "ErrorPage"))

                if err.precompile do
                  result =
                    ModuleCompilerHandler.boot_compile_or_return_module(
                      {err.error_module, err},
                      err.path,
                      err.site && err.site.name,
                      err.site && err.site.id
                    )

                  case result do
                    {:ok, _module} -> nil
                    {:error, reason} -> {err.id, reason}
                  end
                else
                  nil
                end
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: :timer.minutes(5),
              on_timeout: :kill_task
            )
            |> Enum.map(&classify_compile_stream_result/1)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed_compilations == [] do
          Logger.info("[BootHandler] All #{error_page_count} error pages compiled successfully")
          :ok
        else
          Logger.warning(
            "[BootHandler] Skipped #{length(failed_compilations)} broken error page(s) — fix and re-save to recompile"
          )

          :ok
        end
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading error pages: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc false
  # Writes a template file for every ACTIVE component, remembers its name in
  # `SiteState`, and compiles a module for the PRECOMPILED ones. Used at boot and
  # by `RuntimeOrchestrator` after a bulk install.
  #
  # The two halves are deliberately independent. The template file is what
  # `CssClosure` walks and what Tailwind scans, so it is written for every active
  # component whether or not a module is ever built — otherwise a component
  # reached only at render time would come up unstyled. The module is what a
  # render calls, and a non-precompiled one is built by the site's warm job when
  # the site reaches it (`warm_components/2`), or else by
  # `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` on the first render that
  # needs it.
  def compile_components(site_id \\ nil) do
    try do
      query =
        MishkaCmsCore.Runtime.Component
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true)
        |> maybe_filter_site(site_id)
        |> Ash.Query.load([:component_module, :site])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      components_count = Ash.count!(query, authorize?: false)

      if components_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(components_count)

        failed_compilations =
          query
          |> Ash.stream!(batch_size: batch_size, authorize?: false)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn component ->
                # Aggregate every field that may contain Tailwind class
                # strings — template, body, helpers' code, and clauses
                # buried in `extra`. Tailwind regex-scans the file for
                # class-shaped tokens, so syntax doesn't have to match.
                create_template_file(
                  component.site && component.site.name,
                  "component",
                  component.name,
                  build_component_class_content(component)
                )

                SiteState.put_component(component.site_id, component.name)

                boot_compile_component(component, component.precompile)
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: :timer.minutes(5),
              on_timeout: :kill_task
            )
            |> Enum.map(&classify_compile_stream_result/1)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed_compilations == [] do
          Logger.info("[BootHandler] All #{components_count} active components prepared")
          :ok
        else
          Logger.warning(
            "[BootHandler] Skipped #{length(failed_compilations)} broken component(s) — fix and re-save to recompile"
          )

          :ok
        end
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading components: #{inspect(error)}")
        {:error, error}
    end
  end

  defp boot_compile_component(component, true) do
    result =
      ModuleCompilerHandler.boot_compile_or_return_module(
        {component.component_module, component},
        component.name,
        nil,
        component.site && component.site.id
      )

    Phoenix.PubSub.broadcast(
      MishkaCmsCore.PubSub,
      "runtime:bulk_compile",
      {:bulk_compile, %{kind: :component, name: component.name, ok?: match?({:ok, _}, result)}}
    )

    case result do
      {:ok, _module} -> nil
      {:error, reason} -> {component.id, reason}
    end
  end

  # Lazy, and an unset flag reads as lazy: the component contributes its template and nothing more
  # here, and the site's warm job builds the module once a site reaches it.
  defp boot_compile_component(_component, _lazy), do: nil

  defp compile_layouts(site_id \\ nil) do
    try do
      query =
        MishkaCmsCore.Runtime.Layout
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true)
        |> maybe_filter_site(site_id)
        |> Ash.Query.load([:layout_module, :site])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      layouts_count = Ash.count!(query, authorize?: false)

      if layouts_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(layouts_count)

        failed_compilations =
          query
          |> Ash.stream!(batch_size: batch_size, authorize?: false)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn layout ->
                create_template_file(
                  layout.site && layout.site.name,
                  "layout",
                  layout.name,
                  build_resource_class_content(layout)
                )

                WebRunTimeMetaDataState.save(web_metadata_row(layout, "Layout"))

                if layout.precompile do
                  result =
                    ModuleCompilerHandler.boot_compile_or_return_module(
                      {layout.layout_module, layout},
                      layout.path,
                      layout.site && layout.site.name,
                      layout.site && layout.site.id
                    )

                  case result do
                    {:ok, _module} -> nil
                    {:error, reason} -> {layout.id, reason}
                  end
                else
                  nil
                end
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: :timer.minutes(5),
              on_timeout: :kill_task
            )
            |> Enum.map(&classify_compile_stream_result/1)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed_compilations == [] do
          Logger.info("[BootHandler] All #{layouts_count} layouts compiled successfully")
          :ok
        else
          Logger.warning(
            "[BootHandler] Skipped #{length(failed_compilations)} broken layout(s) — fix and re-save to recompile"
          )

          :ok
        end
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading layouts: #{inspect(error)}")
        {:error, error}
    end
  end

  # Add these placeholder functions for now
  defp compile_pages(site_id \\ nil) do
    try do
      query =
        MishkaCmsCore.Runtime.Page
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true)
        |> maybe_filter_site(site_id)
        |> Ash.Query.load([:page_module, :site, :loaded_layout])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      pages_count = Ash.count!(query, authorize?: false)

      if pages_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(pages_count)

        failed_compilations =
          query
          |> Ash.stream!(batch_size: batch_size, authorize?: false)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn page ->
                create_template_file(
                  page.site && page.site.name,
                  "page",
                  page.name,
                  build_resource_class_content(page)
                )

                WebRunTimeMetaDataState.save(web_metadata_row(page, "Page"))

                if page.precompile do
                  result =
                    ModuleCompilerHandler.boot_compile_or_return_module(
                      {page.page_module, page},
                      page.path,
                      page.site && page.site.name,
                      page.site && page.site.id
                    )

                  case result do
                    {:ok, _module} -> nil
                    {:error, reason} -> {page.id, reason}
                  end
                else
                  nil
                end
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: :timer.minutes(5),
              on_timeout: :kill_task
            )
            |> Enum.map(&classify_compile_stream_result/1)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed_compilations == [] do
          Logger.info("[BootHandler] All #{pages_count} pages compiled successfully")
          :ok
        else
          Logger.warning(
            "[BootHandler] Skipped #{length(failed_compilations)} broken page(s) — fix and re-save to recompile"
          )

          :ok
        end
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading pages: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Boot-time pass for `Runtime.Stylesheet` rows.

  CSS content lives in the DB and is inlined at compile time by
  `TailwindCompiler.read_global_stylesheets/0` and `read_site_stylesheets/1`.
  This pass:

    1. Streams every active stylesheet row (global + per-site).
    2. Writes the CSS content to a `.template` file under
       `priv/static/temp/runtime/<site>/stylesheet/<name>.template`.
       Tailwind scans those files via `@source` directives, so any
       utility-class references inside the CSS (e.g. `@apply bg-primary-light`,
       or class names mentioned in comments) get picked up. Without this
       step, classes only present in stylesheet content would be missing
       from the compiled CSS.
    3. Logs the count.

  This runs in parallel with `compile_components`, so total boot time is
  unchanged.
  """
  def load_stylesheets(site_id \\ nil) do
    try do
      query =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true)
        |> maybe_filter_site(site_id)
        |> Ash.Query.load([:site])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      count = Ash.count!(query, authorize?: false)

      if count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(count)

        failed =
          query
          |> Ash.stream!(batch_size: batch_size, authorize?: false)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn sheet ->
                create_template_file(
                  sheet.site && sheet.site.name,
                  "stylesheet",
                  sheet.name,
                  sheet.content
                )

                nil
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: :timer.minutes(5),
              on_timeout: :kill_task
            )
            |> Enum.map(fn
              {:ok, nil} -> nil
              {:exit, reason} -> {:stylesheet_template_exit, reason}
            end)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed == [] do
          Logger.info("[BootHandler] All #{count} stylesheets loaded successfully")
          :ok
        else
          Logger.error("[BootHandler] Failed to load #{length(failed)} stylesheets")
          {:error, {:stylesheet_load_failed, failed}}
        end
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading stylesheets: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Processes JavaScript hooks and creates template files for CSS class extraction.

  This function handles Phoenix LiveView JavaScript hooks by creating template files
  that allow the Tailwind compiler to discover CSS classes used within the JavaScript
  code. This ensures that styles referenced in JS hooks are included in the compiled CSS.

  ## Return Values

  * `:ok` - All JS hooks processed successfully
  * `{:error, reason}` - Processing failed with error details
  """
  def create_js_hooks_template(site_id \\ nil) do
    try do
      query =
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true)
        |> maybe_filter_site(site_id)
        |> Ash.Query.load([:site])
        |> Ash.Query.sort(priority: :desc, inserted_at: :asc)

      js_hooks_count = Ash.count!(query, authorize?: false)

      if js_hooks_count == 0 do
        :ok
      else
        {batch_size, chunk_size} = get_optimal_batch_config(js_hooks_count)

        failed_compilations =
          query
          |> Ash.stream!(batch_size: batch_size, authorize?: false)
          |> Stream.chunk_every(chunk_size)
          |> Stream.flat_map(fn chunk ->
            chunk
            |> Task.async_stream(
              fn js_hook ->
                # Create .template file for JS hook
                create_template_file(
                  js_hook.site && js_hook.site.name,
                  "js_hook",
                  js_hook.name,
                  js_hook.content
                )

                nil
              end,
              max_concurrency: System.schedulers_online(),
              ordered: false,
              timeout: :timer.minutes(5),
              on_timeout: :kill_task
            )
            |> Enum.map(fn
              {:ok, nil} -> nil
              {:exit, reason} -> {:js_hook_creation_exit, reason}
            end)
            |> Enum.reject(&is_nil/1)
          end)
          |> Enum.to_list()

        if failed_compilations == [] do
          Logger.info("[BootHandler] All #{js_hooks_count} JS hooks processed successfully")
          :ok
        else
          Logger.error("[BootHandler] Failed to process #{length(failed_compilations)} JS hooks")
          {:error, {:js_hook_processing_failed, failed_compilations}}
        end
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error loading JS hooks: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Creates background jobs for asset compilation across all active sites.

  This function schedules Oban jobs to compile CSS and JavaScript assets for all
  active sites in the system. It provides a scalable approach to asset generation
  by distributing the work across background workers, preventing boot process delays.

  ## Parameters

  * `type` - String indicating the asset type to compile (defaults to "asset")
    * `"asset"` - Standard asset compilation (CSS, JS)
    * `"css"` - CSS-only compilation
    * `"js"` - JavaScript-only compilation
    * `"sitemap"` - the site's sitemap (`MishkaCmsCore.Runtime.Compilers.SitemapCompiler`)
    * `"warm"` - the modules of the components the site reaches (`warm_components/2`)

  ## Return Values

  * `:ok` - Compilation jobs successfully created
  * `{:error, reason}` - Job creation failed with error details

  ## Job Creation Process

  1. **Site Discovery**: Queries all active sites from SiteState
  2. **Batch Processing**: Processes sites in optimal chunks for job creation
  3. **Job Scheduling**: Creates Oban jobs for each site's asset compilation
  4. **Queue Management**: Distributes jobs across available worker queues

  ## Examples

      # Create standard asset compilation jobs
      :ok = BootHandler.create_assets_compilation_jobs()

      # Create CSS-only compilation jobs
      :ok = BootHandler.create_assets_compilation_jobs("css")

      # Handle job creation failures
      case BootHandler.create_assets_compilation_jobs("js") do
        :ok ->
          Logger.info("JavaScript compilation jobs scheduled")

        {:error, reason} ->
          Logger.error("Failed to schedule JS jobs: \#{inspect(reason)}")
      end

  ## Job Configuration

      # Each job is configured with:
      %{
        resource: "MishkaCmsCore.Runtime.Handlers.BootHandler",
        action: "boot_handler",
        boot_id: BootHandler.boot_id(),
        data: %{site_name: "example_site", site_id: "<uuid>", type: "asset"}
      }

  ## Worker Integration

      # Jobs are processed by RuntimeCompilerWorker
      # Worker handles actual asset compilation using:
      # - TailwindCompiler for CSS generation
      # - JavaScript bundling and minification
      # - Asset optimization and compression
  """
  def create_assets_compilation_jobs(type \\ "asset") do
    try do
      sites_count = SiteState.count()

      if sites_count == 0 do
        :ok
      else
        {_batch_size, chunk_size} = get_optimal_batch_config(sites_count)

        SiteState.stream(%{active: true})
        |> Stream.chunk_every(chunk_size)
        |> Stream.each(fn site_chunk ->
          Enum.each(site_chunk, fn site ->
            site.name
            |> asset_job(site.id, type, priority: site_priority_to_oban(site.priority))
            |> Oban.insert()
          end)
        end)
        |> Stream.run()

        Logger.info("[BootHandler] Compilation jobs created for active sites (#{type})")
        :ok
      end
    rescue
      error ->
        Logger.error("[BootHandler] Error creating compilation jobs: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Builds every open site's sitemap into THIS node's `AssetsState` — the boot counterpart of the
  site's `"sitemap"` job (see `MishkaCmsCore.Runtime.Compilers.SitemapCompiler`).

  Two sites at a time, whatever the node's size, so a node booting with many sites reads their rows
  a couple at a time instead of all at once. Each is built in its own task under
  `MishkaCmsCore.Runtime.TaskSupervisor`, unlinked, so a site whose build raises or runs past a
  minute is left without one and the rest are still built. The first request for it enqueues its
  job.

  ## Return Values

  * `:ok` - Every open site's sitemap is stored
  * `{:error, {:sitemaps_failed, failed}}` - One entry per site not built: `{:ok, {name, {:error,
    reason}}}`, or `{:exit, {name, reason}}` for a build that raised or timed out
  """
  @spec build_sitemaps() :: :ok | {:error, {:sitemaps_failed, [term()]}}
  def build_sitemaps do
    names = Enum.map(SiteState.stream(%{active: true}), & &1.name)

    MishkaCmsCore.Runtime.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      names,
      &{&1, SitemapCompiler.compile_and_store(&1)},
      max_concurrency: 2,
      ordered: false,
      timeout: :timer.minutes(1),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reject(&match?({:ok, {_name, {:ok, _sitemap}}}, &1))
    |> case do
      [] ->
        Logger.info("[BootHandler] Sitemaps built for active sites")
        :ok

      failed ->
        Logger.warning("[BootHandler] Sitemaps not built: #{inspect(failed)}")
        {:error, {:sitemaps_failed, failed}}
    end
  end

  @warm_event "runtime:compile:warm_components"
  @warmed_event "runtime:compile:after_warm_components"

  @doc """
  Builds, on THIS node, the module of every component the site `site_name` reaches that nothing has
  built yet — so the first visitor after a boot or a change does not wait for it.

  What a site reaches is what its stylesheet is built from: its pages and error pages, the layouts
  those pages use, the components they name transitively, and the components its stored content
  names (`MishkaCmsCore.Runtime.Compilers.CssClosure.reached_components/2`). A component nothing
  reaches is not built. One named in a way the walk cannot resolve is built by the first render that
  names it, as every component was before (`MishkaCmsCore.Runtime.LiveViewHelpers.component/1`).

  A module already loaded and one whose last compile failed are passed over. The rest are read in
  one query and compiled `:max_concurrency` at a time, through the registry and the
  `MishkaCmsCore.Runtime.Handlers.CompileGate` every compile goes through: a visitor asking for one
  of them meanwhile waits for that compile rather than starting another.

  Run by the site's `"warm"` job (`asset_job/4`), which the boot queues for every open site and the
  site's stylesheet build queues after it is built.

  ## Options

    * `:runtime_dir` — the template tree to walk. Defaults to
      `MishkaCmsCore.Runtime.Compilers.CssClosure.default_runtime_dir/0`.
    * `:max_concurrency` — how many compile at once. Defaults to
      `config :mishka_cms_core, :component_warm_concurrency`, or half the node's schedulers and at
      least one.

  ## Events

    * `runtime:compile:warm_components` — before anything is built, with
      `%{site: site_name, site_id: site_id, components: [%{name: name, site: site}]}`, `site` the
      site's name for a component of its own and `"Global"` for a global one — what a
      `<.component site="…">` tag names. A plugin answers the map with other `components` to build
      more or fewer; only the site's own and global ones are built.
    * `runtime:compile:after_warm_components` — once they are built, with
      `%{site: site_name, site_id: site_id, warmed: [component], failed: [failure],
      complete?: complete?}`, each failure `%{name: name, site: site, reason: reason}`.
      `complete?` is `false` when a reference the walk could not resolve may name more.

  ## Return Values

    * `{:ok, %{warmed: [component], failed: [failure], complete?: boolean()}}`
    * `{:error, :no_site}` — `SiteState` knows no site of that name
  """
  @spec warm_components(String.t(), keyword()) :: {:ok, map()} | {:error, :no_site}
  def warm_components(site_name, opts \\ []) do
    case SiteState.get_by_name(site_name) do
      {:ok, site} -> {:ok, warm_site(site, opts)}
      {:error, :not_found} -> {:error, :no_site}
    end
  end

  defp warm_site(site, opts) do
    started = System.monotonic_time(:millisecond)
    runtime = Keyword.get_lazy(opts, :runtime_dir, &CssClosure.default_runtime_dir/0)

    reached =
      CssClosure.reached_components(site.name,
        runtime_dir: runtime,
        roots: TailwindCompiler.closure_roots(site.name, runtime_dir: runtime),
        content_components: TailwindCompiler.content_components(site.name)
      )

    asked = %{site: site.name, site_id: site.id, components: reached.components}

    answered =
      case MishkaInstaller.Event.Hook.call(@warm_event, asked, meta: %{site: site.name}) do
        %{components: components} when is_list(components) -> components
        _unchanged -> asked.components
      end

    cold =
      answered
      |> Enum.filter(&warmable?(&1, site.name))
      |> Enum.uniq()
      |> Enum.reject(&built_or_failed?/1)

    {warmed, failed} = cold |> cold_rows(site.id) |> compile_cold(warm_concurrency(opts))

    result = %{warmed: warmed, failed: failed, complete?: reached.complete?}
    log_warmed(site.name, result, System.monotonic_time(:millisecond) - started)

    MishkaInstaller.Event.Hook.call(
      @warmed_event,
      Map.merge(result, %{site: site.name, site_id: site.id}),
      return: false
    )

    result
  end

  defp warmable?(%{name: name, site: site}, site_name) when is_binary(name),
    do: site in [site_name, "Global"]

  defp warmable?(_component, _site_name), do: false

  defp built_or_failed?(%{name: name, site: site}) do
    module = CompilerHelpers.module_name(name, site, "Component")
    CompilerHelpers.loaded?(module) or CompileFailureState.failed?(module)
  end

  # ONE QUERY for every cold component of both scopes, streamed, so a site reaching a whole kit holds
  # a batch of rows at a time rather than all of them.
  defp cold_rows([], _site_id), do: []

  defp cold_rows(cold, site_id) do
    {own, global} = Enum.split_with(cold, &(&1.site != "Global"))
    own = Enum.map(own, & &1.name)
    global = Enum.map(global, & &1.name)

    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(
      active == true and
        ((site_id == ^site_id and name in ^own) or (is_nil(site_id) and name in ^global))
    )
    |> Ash.Query.load([:component_module, :site])
    |> Ash.Query.sort(priority: :desc, name: :asc)
    |> Ash.stream!(batch_size: 100, authorize?: false)
  end

  defp compile_cold(rows, max_concurrency) do
    MishkaCmsCore.Runtime.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(rows, &warm_one/1,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {component, {:ok, _module}}}, {warmed, failed} ->
        {[warmed_entry(component) | warmed], failed}

      {:ok, {component, {:error, reason}}}, {warmed, failed} ->
        {warmed, [failed_entry(component, reason) | failed]}

      {:exit, {component, reason}}, {warmed, failed} ->
        {warmed, [failed_entry(component, {:exit, reason}) | failed]}
    end)
    |> then(fn {warmed, failed} -> {Enum.reverse(warmed), Enum.reverse(failed)} end)
  end

  defp warm_one(component) do
    {component,
     ModuleCompilerHandler.boot_compile_or_return_module(
       {component.component_module, component},
       component.name,
       nil,
       component.site_id
     )}
  end

  defp warmed_entry(component), do: %{name: component.name, site: scope_name(component)}

  defp failed_entry(component, reason),
    do: %{name: component.name, site: scope_name(component), reason: reason}

  defp scope_name(%{site: %{name: name}}), do: name
  defp scope_name(_global), do: "Global"

  defp warm_concurrency(opts) do
    Keyword.get_lazy(opts, :max_concurrency, fn ->
      Application.get_env(
        :mishka_cms_core,
        :component_warm_concurrency,
        max(1, div(System.schedulers_online(), 2))
      )
    end)
  end

  defp log_warmed(_site_name, %{warmed: [], failed: []}, _ms), do: :ok

  defp log_warmed(site_name, %{warmed: warmed, failed: failed}, ms) do
    Logger.info(
      "[BootHandler] #{length(warmed)} components warmed for site #{site_name} in #{ms}ms"
    )

    if failed != [] do
      Logger.warning(
        "[BootHandler] #{length(failed)} component(s) of site #{site_name} did not compile: " <>
          Enum.map_join(failed, ", ", & &1.name)
      )
    end

    :ok
  end

  # Per-site asset (css/js/sitemap/warm) build job: unique + debounced (3s `schedule_in` coalesces a
  # burst, each insert moving a pending one later; `replace: []` leaves it where it is instead, and
  # `states:` widens which jobs already there count). `site_id` lives in `data` so the Oban→PubSub
  # bridge broadcasts on the per-site topic, letting that site's admins see the rebuild live.
  # `boot_id` names the instance that inserted it, which is the one `RuntimeCompilerWorker` builds it
  # on, and is part of the unique args, so a job one instance inserts never merges into another's.
  # `Oban.insert/1` (not insert_all) is required for uniqueness on the Basic engine.
  @doc false
  def asset_job(site_name, site_id, type, opts \\ []) do
    rules = job_rules(type)

    Oban.Job.new(
      %{
        resource: "MishkaCmsCore.Runtime.Handlers.BootHandler",
        action: "boot_handler",
        boot_id: boot_id(),
        data: %{site_name: site_name, site_id: site_id, type: type}
      },
      queue: rules.queue,
      priority: Keyword.get(opts, :priority, 1),
      max_attempts: rules.max_attempts,
      worker: MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker,
      schedule_in: 3,
      unique: [
        period: rules.period,
        fields: [:worker, :args],
        states: Keyword.get(opts, :states, rules.states)
      ],
      replace: Keyword.get(opts, :replace, rules.replace)
    )
  end

  # A SITEMAP READS EVERY ROW OF ITS SITE, so it has a queue of its own, where a large site's build
  # holds up no stylesheet an editor is waiting on, and one job per site however long it has been
  # waiting: a build that failed and waits to retry is pending too, brought forward by a change
  # rather than joined by another, and given up after three tries.
  defp job_rules("sitemap") do
    %{
      queue: :sitemaps,
      max_attempts: 3,
      period: :infinity,
      states: [:available, :scheduled, :retryable],
      replace: [scheduled: [:scheduled_at], retryable: [:scheduled_at]]
    }
  end

  # A WARM JOB BUILDS MODULES, NOT A BUNDLE, so it waits on `:maintenance`, the small queue a host
  # keeps for whole-site work: it holds up no stylesheet and no editor's save, and a node runs only
  # as many at once as that queue allows.
  defp job_rules("warm") do
    %{
      queue: :maintenance,
      max_attempts: 3,
      period: 120,
      states: [:available, :scheduled],
      replace: [scheduled: [:scheduled_at]]
    }
  end

  defp job_rules(_asset) do
    %{
      queue: :assets,
      max_attempts: 20,
      period: 120,
      states: [:available, :scheduled],
      replace: [scheduled: [:scheduled_at]]
    }
  end

  @doc """
  Determines optimal batch and chunk sizes based on dataset size for performance tuning.

  This function provides adaptive batch configuration that scales with the number of items
  being processed. It optimizes memory usage and processing time by selecting appropriate
  batch sizes for different dataset volumes.

  ## Parameters

  * `site_count` - Integer representing the total number of items to process

  ## Return Value

  Returns a tuple `{batch_size, chunk_size}` where:
  * `batch_size` - Number of items to load from database in each query
  * `chunk_size` - Number of items to process together in parallel tasks

  ## Scaling Strategy

  * **≤ 1,000 items**: `{1_000, 250}` - Small datasets, conservative batching
  * **≤ 5,000 items**: `{2_000, 500}` - Medium datasets, moderate batching
  * **≤ 20,000 items**: `{5_000, 1_000}` - Large datasets, aggressive batching
  * **≤ 100,000 items**: `{10_000, 2_000}` - Very large datasets, high-volume batching
  * **> 100,000 items**: `{20_000, 5_000}` - Massive datasets, maximum batching

  ## Examples

      # Small site configuration
      {batch_size, chunk_size} = BootHandler.get_optimal_batch_config(500)
      # Returns: {1_000, 250}

      # Large enterprise configuration
      {batch_size, chunk_size} = BootHandler.get_optimal_batch_config(50_000)
      # Returns: {10_000, 2_000}

  ## Performance Considerations

  * **Memory Usage**: Larger batch sizes use more memory but reduce database roundtrips
  * **Concurrency**: Smaller chunk sizes enable better parallelization
  * **Database Load**: Batch sizes balance query efficiency with resource usage
  * **System Resources**: Configuration adapts to available CPU cores and memory
  """
  def get_optimal_batch_config(site_count) do
    cond do
      site_count <= 1_000 ->
        {1_000, 250}

      site_count <= 5_000 ->
        {2_000, 500}

      site_count <= 20_000 ->
        {5_000, 1_000}

      site_count <= 100_000 ->
        {10_000, 2_000}

      true ->
        # For very large datasets, use larger batches
        {20_000, 5_000}
    end
  end

  @doc """
  Maps a site priority value to an Oban job priority (0–9, lower = higher priority).

  Site priorities are positive integers where higher values mean more important.
  Oban priorities are 0–9 where 0 is the most important.

  ## Mapping

  * Site priority >= 100 → Oban 0 (highest)
  * Site priority >= 50  → Oban 1
  * Site priority >= 20  → Oban 2
  * Site priority >= 10  → Oban 3
  * Site priority >= 5   → Oban 4
  * Site priority >= 1   → Oban 5
  * Everything else      → Oban 6
  """
  def site_priority_to_oban(priority) when is_integer(priority) and priority >= 100, do: 0
  def site_priority_to_oban(priority) when is_integer(priority) and priority >= 50, do: 1
  def site_priority_to_oban(priority) when is_integer(priority) and priority >= 20, do: 2
  def site_priority_to_oban(priority) when is_integer(priority) and priority >= 10, do: 3
  def site_priority_to_oban(priority) when is_integer(priority) and priority >= 5, do: 4
  def site_priority_to_oban(priority) when is_integer(priority) and priority >= 1, do: 5
  def site_priority_to_oban(_), do: 6

  @doc """
  Creates a template file in the appropriate directory structure for CSS compilation.

  This function organizes template files by site and type, creating the necessary
  directory structure and writing template content to disk. The files are used
  by the Tailwind compiler to scan for CSS classes during asset generation.

  ## Parameters

  * `site_name` - String name of the site (nil becomes "__global__")
  * `type` - String indicating template type ("page", "layout", "component", etc.)
  * `name` - String name of the template (will be slugified for filename)
  * `content` - String content of the template

  ## Directory Structure

  Templates are organized in the following structure:
  ```
  priv/static/temp/runtime/
  ├── site_name/
  │   ├── page/
  │   ├── layout/
  │   ├── component/
  │   ├── error/
  │   └── js_hook/
  └── __global__/
      └── ...
  ```
  """
  def create_template_file(site_name, type, name, content) do
    site_name = if is_nil(site_name), do: "__global__", else: site_name
    dir_path = Helpers.static_temp_dir(["runtime", site_name, type])

    _ = File.mkdir_p!(dir_path)

    file_path = Path.join(dir_path, "#{Slug.slugify(name)}.template")
    File.write!(file_path, content)
  end

  @doc """
  Deletes a template file from the organized directory structure.

  This function removes template files that are no longer needed, such as when
  pages, components, or layouts are deleted from the CMS. It helps maintain
  a clean template directory and prevents stale CSS classes from being included
  in compiled assets.

  ## Parameters

  * `site_name` - String name of the site (nil becomes `__global__`)
  * `type` - String indicating template type (`page`, `layout`, `component`, etc.)
  * `name` - String name of the template to delete (will be slugified)

  ## Return Value

  * `:ok` - File successfully deleted or didn't exist
  * `{:error, reason}` - File deletion failed

  ## File Safety

  This function is safe to call multiple times or on non-existent files.
  It will not raise exceptions for missing files, making it suitable for
  cleanup operations where the file state is uncertain.
  """
  def delete_template_file(site_name, type, name) do
    site_name = if is_nil(site_name), do: "__global__", else: site_name
    dir_path = Helpers.static_temp_dir(["runtime", site_name, type])

    file_path = Path.join(dir_path, "#{Slug.slugify(name)}.template")
    File.rm(file_path)
  end

  @doc """
  Builds comprehensive template content for error pages by aggregating all related templates.

  This function constructs the complete template content for error pages by combining
  the error page templates with their associated layouts. This ensures that Tailwind
  CSS compilation captures all classes used across the entire error page rendering chain.

  ## Parameters

  * `err` - Error page struct containing error page data and associated layouts

  ## Return Value

  * `binary()` - Combined template content as a single string

  ## Template Aggregation Process

  1. **Root Layout Template**: Includes the base layout template
  2. **Error Page Templates**: Adds all error page template variants
  3. **Associated Layouts**: Includes templates from nested layout structures
  4. **Content Filtering**: Removes nil/empty templates and combines valid content

  ## Template Structure Processing

  The function handles nested template structures and extracts content from:
  * Direct template strings
  * Nested layout template references
  * Complex error page hierarchies
  * Multiple error page variants per error configuration
  """
  def build_error_template_content(err) do
    err = MishkaCmsCore.Runtime.Helpers.atomize_keys(err)
    helpers_blob = helpers_to_text(Map.get(err, :helpers, []))

    # THE LIST IS ATOMIZED ON ITS OWN. A record read at boot is a struct, which `atomize_keys/1`
    # leaves as it is, and a status's `layout` is a plain map stored as JSON: its key stays
    # "template", and the layout's classes would be left out of the site's stylesheet.
    err.error_pages
    |> MishkaCmsCore.Runtime.Helpers.atomize_keys()
    |> Enum.flat_map(fn error_page ->
      [error_page.template, get_in(error_page, [:layout, :template])]
    end)
    |> then(&[err.root_layout_template, helpers_blob | &1])
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Aggregates every class-bearing field of a Component into one blob for
  Tailwind to scan: `template`, `body`, helper code, the templates
  + bodies of multi-clause variants stored in `extra.clauses`, and the content
  an author places with it — its `examples` and the `extra.furnishing` it
  arrives with, which the content editor offers as ready blocks.

  It ends with the attribute lines the CSS closure reads to follow a component named through an
  attribute — `MishkaCmsCore.Runtime.Compilers.CssClosure.attribute_marks/1`.
  """
  def build_component_class_content(component) do
    extra = field(component, :extra) || %{}

    clauses_blob =
      case field(extra, :clauses) do
        list when is_list(list) ->
          list
          |> Enum.flat_map(fn clause -> [field(clause, :template), field(clause, :body)] end)
          |> Enum.filter(&is_binary/1)
          |> Enum.join("\n\n")

        _ ->
          ""
      end

    [
      field(component, :template),
      field(component, :body),
      helpers_to_text(field(component, :helpers)),
      clauses_blob,
      placed_to_text(field(component, :examples), field(extra, :furnishing)),
      defaults_to_text(field(component, :attrs)),
      defaults_to_text(field(component, :slots)),
      MishkaCmsCore.Runtime.Compilers.CssClosure.attribute_marks(component)
    ]
    |> Enum.filter(fn s -> is_binary(s) and s != "" end)
    |> Enum.join("\n\n")
  end

  @doc """
  Aggregate template + helper code for Page/Layout resources. Tailwind
  scans the result, so unparsed Elixir snippets are fine.

  It is the COMPILED template, not the stored one. A page carrying a form compiles with the
  confirmation region in front of it
  (`MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.confirmable/2`), and a class that only ever
  exists after this file is written gets no rule — the visitor read the success message as bare
  unstyled body text with no box, no padding and no centring.
  """
  def build_resource_class_content(resource) do
    [
      resource
      |> field(:template)
      |> MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.confirmable(),
      helpers_to_text(field(resource, :helpers))
    ]
    |> Enum.filter(fn s -> is_binary(s) and s != "" end)
    |> Enum.join("\n\n")
  end

  # AN ATTRIBUTE'S DEFAULT IS THE ONE CLASS NO CALL SITE EVER WRITES DOWN.
  #
  #     attr :font_weight, :string, default: "font-normal"   # in `attrs`
  #     <p class={[@font_weight]}>                           # in `template`
  #
  # Tailwind matches class-shaped TEXT; it cannot follow `@font_weight` to its default. Set the
  # attribute at a call site and the value is written literally in the PAGE's template, which is
  # scanned — so an override has always worked. Leave it alone and the default renders with no rule
  # at all, which is why `font-normal` and `leading-5` were missing from every site's stylesheet
  # while every colour and size an author had chosen was present.
  #
  # DEFAULTS ONLY, never the `values` list beside them. An author who picks a value writes it at the
  # call site; generating rules for every option of every reachable component would put the whole
  # kit's variants back into the bundle this work exists to shrink.
  defp defaults_to_text(entries) when is_list(entries) do
    entries
    |> Enum.map(fn entry -> entry |> field(:opts) |> field(:default) end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp defaults_to_text(_entries), do: ""

  # Boot reads Ash structs; the compile worker reads the same record decoded from an Oban job, where
  # every key is a string. Both call the two builders above, so both key shapes are read here.
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, "#{key}")
  defp field(_map, _key), do: nil

  defp helpers_to_text(helpers) when is_list(helpers) do
    helpers
    |> Enum.map(fn h ->
      code = if is_map(h), do: Map.get(h, :code) || Map.get(h, "code"), else: nil
      if is_binary(code), do: code, else: ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp helpers_to_text(_), do: ""

  # What the content editor places with a component: its examples, and the body and slot entries of
  # the furnishing it arrives with — HTML carrying classes of its own, which a page drawing that
  # content needs as much as the component's.
  defp placed_to_text(examples, furnishing) do
    slots =
      case field(furnishing, :slots) do
        list when is_list(list) -> Enum.map(list, &field(&1, :body))
        _none -> []
      end

    [field(furnishing, :body) | slots]
    |> Enum.concat(List.wrap(examples))
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end
end
