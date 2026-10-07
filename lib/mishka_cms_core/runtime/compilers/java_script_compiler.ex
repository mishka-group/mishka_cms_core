defmodule MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler do
  # The application this library is installed into: its priv holds the assets the compilers read,
  # and its esbuild profile is the one they run. Named by configuration, never hardcoded.
  @host_app Application.compile_env!(:mishka_cms_core, :host_app)
  @moduledoc """
  Production-ready JavaScript compiler for runtime JS generation.

  This module provides comprehensive JavaScript compilation functionality for MishkaCMS,
  combining application JS files, vendor dependencies, and database-stored JavaScript
  hooks into optimized, site-specific bundles.

  ## Features

  - **Runtime JS Hook Compilation**: Dynamically compiles JavaScript hooks from database
  - **Site-specific Bundling**: Creates optimized JS bundles per site configuration
  - **Phoenix Colocated Integration**: Supports Phoenix colocated JavaScript hooks
  - **ESBuild Integration**: Uses ESBuild for fast, modern JavaScript bundling
  - **Asset Compression**: Automatic Brotli and Gzip compression for optimal delivery
  - **Asset State Management**: Caches compiled JS in memory for fast serving
  - **Automatic Cleanup**: Manages temporary files and build artifacts
  - **Error Handling**: Comprehensive error reporting and recovery

  ## JavaScript Architecture

  The compiler creates a hierarchical JavaScript structure:

  ```
  Entry File (app.js + runtime hooks)
  ├── Base Application JavaScript (app.js)
  ├── Phoenix Colocated Hooks (phoenix-colocated/mishka_cms.js)
  └── Site-specific Runtime Components
      ├── Global JavaScript Hooks (database)
      └── Site-specific JavaScript Hooks (database)
  ```

  ## Compilation Process

  1. **Prepare Environment**: Creates temporary directories and asset structure
  2. **Generate Runtime Hooks**: Fetches JS hooks from database and creates component files
  3. **Ensure Colocated Hooks**: Sets up Phoenix colocated JavaScript integration
  4. **Create Entry File**: Combines app.js with runtime components
  5. **Execute ESBuild**: Bundles and minifies JavaScript using ESBuild
  6. **Compress Assets**: Creates Brotli and Gzip versions for optimal delivery
  7. **Store Results**: Caches compiled JS in AssetsState for fast serving
  8. **Cleanup**: Removes temporary files and build artifacts

  ## Usage

      # Compile JavaScript for a specific site
      {:ok, js} = JavaScriptCompiler.compile("my_site")

      # Compile and store in cache
      {:ok, js} = JavaScriptCompiler.compile_and_store("my_site")

      # Retrieve cached JavaScript
      js = JavaScriptCompiler.get_compiled_js("my_site")

      # Check if JavaScript exists
      exists = JavaScriptCompiler.js_exists?("my_site")

      # Refresh JavaScript (recompile and update cache)
      {:ok, js} = JavaScriptCompiler.refresh_js("my_site")

  ## ESBuild Configuration

  The compiler uses ESBuild with the following configuration:
  - **Target**: ES2022 for modern browser support
  - **Format**: IIFE (Immediately Invoked Function Expression) for browser compatibility
  - **Platform**: Browser-specific optimizations
  - **Minification**: Enabled for production builds
  - **External Resources**: Excludes fonts and images from bundling
  - **Alias Support**: Uses @ alias for cleaner imports

  ## Error Handling

  Compilation failures are handled gracefully with:
  - A hook that does not build is left out and the rest of the bundle is built without it; the
    reason is read with `left_out/1` and sent as `runtime:compile:js_hook_skipped`
  - Detailed error messages including ESBuild output
  - Automatic cleanup of temporary files
  - Logging of compilation status and errors
  - Fallback behavior for missing JavaScript

  ## Integration with Phoenix

      # In your layout template
      <script>
        <%= raw(MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.get_compiled_js(@site_name)) %>
      </script>

      # Or serve as static asset with compression
      defmodule MyAppWeb.AssetController do
        def javascript(conn, %{"site" => site_name}) do
          js = JavaScriptCompiler.get_compiled_js(site_name)

          conn
          |> put_resp_content_type("application/javascript")
          |> put_resp_header("cache-control", "public, max-age=31536000")
          |> send_resp(200, js)
        end
      end
  """

  require Logger
  require Ash.Query
  alias MishkaCmsCore.Runtime.States.{AssetsState, CompileFailureState, SiteState}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Compilers.NpmPackages
  alias IgniterJs.Parsers.Javascript.{Parser, Formatter}

  @esbuild_verified_key :mishka_cms_esbuild_verified
  @shared_base_id "__shared_base__"

  @doc """
  Ensures the configured ESBuild is installed and runnable, caching the answer in `:persistent_term`
  so the check costs one `--version` run per node rather than one per compile.

  It asks the binary, not the path. `Esbuild.bin_path/0` BUILDS a string and returns it whether or
  not a file sits at the end of it, so testing it told us only that esbuild has a name — a missing
  binary then reached `System.cmd` and came back as `ErlangError :enoent`, an error naming neither
  esbuild nor a path, underneath a log line saying the binary had been found.

  The version is checked too, and not as a formality: `bin_path/0` puts no version in the filename,
  and `Esbuild.configured_version/0` falls back to the library's own `@latest_version` when this
  project's config is not loaded. So anything that installs esbuild from outside this config leaves
  a differently-versioned binary at exactly the path we look at, and it stays there. That is how
  0.25.0 came to sit where 0.25.4 was pinned.

  Raises when esbuild is still unusable after installing, rather than caching a verification that is
  not true. `MishkaCmsCore.Runtime.Handlers.BootHandler` expects that and boots without it.
  """
  def ensure_installed do
    case :persistent_term.get(@esbuild_verified_key, false) do
      true -> :ok
      false -> alone(&verify_and_install/0)
    end
  end

  # THE SAME RACE `TailwindCompiler.ensure_installed/0` carries, for the same reason: the flag is set
  # only by a SUCCESSFUL probe, so every caller arriving before the first one finishes runs the probe
  # itself — and at boot the assets watcher is compiling a site's CSS and its JS at once. Two probes
  # over one binary path, each failing because the other is writing it, each answering that by
  # downloading again.
  #
  # THIS NODE'S LOCK, AND A BOUNDED WAIT. The binary sits on this node's disk, so another node has no
  # part in it. The download has no timeout of its own, so a stalled one would hold the lock for
  # good: a waiter gives up with an error after `:asset_install_wait` — ten minutes unless set, room
  # for a slow first download — instead of waiting for ever. See `Helpers.install_lock_retries/1`.
  defp alone(fun) do
    case :global.trans(
           {{__MODULE__, :install}, self()},
           fun,
           [node()],
           Helpers.install_lock_retries()
         ) do
      :aborted -> {:error, "could not take the esbuild install lock"}
      result -> result
    end
  end

  defp verify_and_install do
    # Asked again inside the lock — the pass this caller waited on was probably the install itself.
    if !:persistent_term.get(@esbuild_verified_key, false) do
      wanted = Esbuild.configured_version()

      case probe_esbuild(wanted) do
        :ok ->
          :persistent_term.put(@esbuild_verified_key, true)

        {:unusable, why} ->
          Logger.info("[JavaScriptCompiler] ESBuild #{why}, installing #{wanted}...")
          Esbuild.install()

          case probe_esbuild(wanted) do
            :ok ->
              Logger.info(
                "[JavaScriptCompiler] ESBuild #{wanted} installed at #{Esbuild.bin_path()}"
              )

              :persistent_term.put(@esbuild_verified_key, true)

            {:unusable, why} ->
              # Deliberately not cached: the next compile has to look again rather than trust a
              # flag that says verified over a binary that will not run.
              raise "ESBuild #{wanted} is unusable after installing — #{why}"
          end
      end
    end

    :ok
  end

  # Every way esbuild can be unusable, folded into one answer that carries WHICH way.
  #
  # `Esbuild.bin_version/0` covers most of them by running the file — absent, a directory, and a
  # truncated download all come back `:error`. One does not: a file present without its exec bit
  # makes `System.cmd` RAISE `:eacces` instead of returning, and a raise would skip the case
  # entirely and wedge the compile permanently. Hence the rescue.
  defp probe_esbuild(wanted) do
    path = Esbuild.bin_path()

    case Esbuild.bin_version() do
      {:ok, ^wanted} -> :ok
      {:ok, found} -> {:unusable, "#{found} is installed at #{path} but #{wanted} is configured"}
      :error -> {:unusable, "is not installed at #{path}"}
    end
  rescue
    e -> {:unusable, "at #{Esbuild.bin_path()} is not runnable (#{Exception.message(e)})"}
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################
  @doc """
  Compiles JavaScript from app.js, vendor files, and hooks for a specific site.

  This is the main compilation function that orchestrates the entire JavaScript
  bundling process for a specific site. It handles temporary file management,
  runtime hook generation, and ESBuild execution.

  ## Parameters

  - `site_name` - The name/identifier of the site to compile JavaScript for

  ## Returns

  - `{:ok, compiled_js}` - On successful compilation, returns the bundled JavaScript string
  - `{:error, reason}` - On failure, returns an error with descriptive message

  ## Compilation Steps

  1. Creates temporary directories for build process
  2. Generates runtime hooks from database-stored JavaScript
  3. Ensures Phoenix colocated hooks are available
  4. Executes ESBuild bundling with optimizations
  5. Cleans up temporary files

  ## Error Handling

  Failures at any step will result in automatic cleanup of temporary files
  and return a descriptive error message. Common failure points:
  - Missing app.js file
  - ESBuild compilation errors
  - Database connection issues when fetching hooks
  - File system permission errors

  ## Example

      # Compile JavaScript for main site
      case JavaScriptCompiler.compile("main") do
        {:ok, js} ->
          IO.puts("Compiled JS size: \#{byte_size(js)} bytes")
        {:error, reason} ->
          IO.puts("Compilation failed: \#{reason}")
      end
  """
  def compile(site_name, opts \\ []) do
    global_only? = Keyword.get(opts, :global_only, false)

    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :javascript],
      %{site: site_name, global_only: global_only?},
      fn ->
        tmp_dir = get_temp_dir()
        js_assets_dir = get_js_assets_dir()

        _ = File.mkdir_p!(tmp_dir)
        _ = File.mkdir_p!(js_assets_dir)

        site_js_dir = Path.join([js_assets_dir, "js", site_name])
        _ = File.mkdir_p!(site_js_dir)

        result =
          try do
            ensure_installed()

            hooks = runtime_hooks(site_name, global_only?, js_assets_dir)

            _ = ensure_colocated_hooks(js_assets_dir)

            bundle(hooks, site_name, tmp_dir)
          rescue
            e -> {:error, Exception.message(e)}
          after
            cleanup_runtime_files(site_js_dir)
          end

        {result, %{}}
      end
    )
  end

  @doc """
  Compiles and stores the JS in AssetsState for a specific site.

  This function combines compilation with caching, storing the compiled JavaScript
  along with compressed versions (Brotli and Gzip) in the AssetsState for fast serving.

  ## Parameters

  - `site_name` - The name/identifier of the site to compile JavaScript for

  ## Returns

  - `{:ok, compiled_js}` - On success, returns the compiled JavaScript string
  - `{:error, reason}` - On failure, returns compilation error

  ## Storage Details

  Creates three entries in AssetsState:
  - `"js"` - Original compiled JavaScript
  - `"brotli_js"` - Brotli-compressed version (best compression)
  - `"gzip_js"` - Gzip-compressed version (wide compatibility)

  Each entry includes:
  - MD5 hash for cache validation
  - Timestamp for cache invalidation
  - Compressed content for optimal delivery

  ## Example

      # Compile and cache JavaScript
      case JavaScriptCompiler.compile_and_store("main") do
        {:ok, js} ->
          Logger.info("JavaScript compiled and cached: \#{byte_size(js)} bytes")
        {:error, reason} ->
          Logger.error("Failed to compile: \#{reason}")
      end
  """
  def compile_and_store(site_name) do
    MishkaInstaller.Event.Hook.call("runtime:compile:before_js", %{site: site_name},
      meta: %{site: site_name},
      return: false
    )

    previous_hash = AssetsState.get!(site_name, "js")[:hash]

    result =
      if reuse_shared_base?(site_name) do
        reuse_shared_base_for(site_name)
      else
        store_compiled(site_name, compile(site_name))
      end

    case result do
      {:ok, _js} ->
        hash = AssetsState.get!(site_name, "js")[:hash]

        if hash != previous_hash do
          MishkaCmsCore.PubSub
          |> Phoenix.PubSub.broadcast("site:#{site_name}:assets", {:js_updated, hash})
        end

      _ ->
        :ok
    end

    result
  end

  # Reuse only when the site has no own hooks. Disabled under `env_test?` so
  # the JS compiler's pure unit tests (no DB sandbox) never run the global-hooks
  # query; the shared-base integration test flips the flag to exercise reuse.
  defp reuse_shared_base?(site_name) do
    !Application.get_env(:mishka_cms_core, :env_test?, false) and
      !site_has_own_hooks?(site_name)
  end

  @doc """
  Compiles + stores the shared base JS (`app.js` + global hooks only) under
  `#{@shared_base_id}`. Built once and reused by every global-only site.
  """
  def compile_and_store_shared_base do
    store_compiled(@shared_base_id, compile(@shared_base_id, global_only: true))
  end

  @doc "Cached shared base JS, compiling + caching it on first use."
  def get_or_compile_shared_base do
    case AssetsState.get_value(@shared_base_id, "js") do
      nil ->
        case compile_and_store_shared_base() do
          {:ok, js} -> js
          {:error, _} -> ""
        end

      js ->
        js
    end
  end

  @doc "Drops the cached shared base JS (all formats)."
  def delete_shared_base_js do
    AssetsState.delete(@shared_base_id, "js")
    AssetsState.delete(@shared_base_id, "brotli_js")
    AssetsState.delete(@shared_base_id, "gzip_js")
  end

  defp store_compiled(id, {:ok, js}) do
    js = MishkaInstaller.Event.Hook.call("runtime:compile:js", js, meta: %{site: id})

    {brotli, gzip} = Helpers.compress_asset(js)
    updated_at = DateTime.utc_now()
    hash = Base.encode16(:crypto.hash(:md5, js), case: :lower)

    [
      %{id: id, type: "js", value: js, hash: hash, updated_at: updated_at},
      %{id: id, type: "brotli_js", value: brotli, hash: hash, updated_at: updated_at},
      %{id: id, type: "gzip_js", value: gzip, hash: hash, updated_at: updated_at}
    ]
    |> AssetsState.save_batch()

    Logger.debug("JavaScript compiled and stored in AssetsState for site: #{id}")
    {:ok, js}
  end

  defp store_compiled(id, {:error, reason} = error) do
    Logger.error("Failed to compile JavaScript for site #{id}: #{reason}")
    error
  end

  # Copy the (lazily built) shared base bundle into a global-only site's cache
  # key so serving stays per-site and unchanged. If the base can't be built,
  # fall back to a direct per-site compile — the optimization must never break
  # compilation.
  defp reuse_shared_base_for(site_name) do
    case get_or_compile_shared_base() do
      "" ->
        store_compiled(site_name, compile(site_name))

      js ->
        brotli = AssetsState.get_value(@shared_base_id, "brotli_js")
        gzip = AssetsState.get_value(@shared_base_id, "gzip_js")
        hash = Base.encode16(:crypto.hash(:md5, js), case: :lower)
        updated_at = DateTime.utc_now()

        [
          %{id: site_name, type: "js", value: js, hash: hash, updated_at: updated_at},
          %{id: site_name, type: "brotli_js", value: brotli, hash: hash, updated_at: updated_at},
          %{id: site_name, type: "gzip_js", value: gzip, hash: hash, updated_at: updated_at}
        ]
        |> AssetsState.save_batch()

        {:ok, js}
    end
  end

  defp site_has_own_hooks?(site_name) do
    case SiteState.get_by_name(site_name) do
      {:ok, data} ->
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true and site_id == ^data.id)
        |> Ash.count!(authorize?: false) > 0

      _ ->
        false
    end
  end

  ####################################################################################
  ##################### (▰˘◡˘▰) Maintenance functions (▰˘◡˘▰) ########################
  ####################################################################################
  @doc """
  Retrieves compiled JS from AssetsState for a specific site.

  Fast retrieval of cached JavaScript without recompilation. Returns
  a fallback comment if JavaScript is not found for the specified site.

  ## Parameters

  - `site_name` - The site identifier to retrieve JavaScript for

  ## Returns

  - Compiled JavaScript string if found in cache
  - Fallback comment string if not found: `"// JS not found for site: {site_name}"`

  ## Usage

      js = JavaScriptCompiler.get_compiled_js("main")

      # In Phoenix template
      <script><%= raw(js) %></script>
  """
  def get_compiled_js(site_name) do
    case AssetsState.get_value(site_name, "js") do
      nil -> "// JS not found for site: #{site_name}"
      js -> js
    end
  end

  @doc """
  Checks if compiled JS exists for a site.

  Quick boolean check to determine if JavaScript has been compiled
  and cached for the specified site.

  ## Parameters

  - `site_name` - The site identifier to check

  ## Returns

  - `true` if compiled JavaScript exists in cache
  - `false` if no JavaScript found for the site

  ## Usage

      if JavaScriptCompiler.js_exists?("main") do
        js = JavaScriptCompiler.get_compiled_js("main")
      else
        JavaScriptCompiler.compile_and_store("main")
      end
  """
  def js_exists?(site_name), do: AssetsState.exists?(site_name, "js")

  @doc """
  Deletes compiled JS for a site.

  Removes all cached JavaScript assets for the specified site from AssetsState.
  This includes the original JS and all compressed versions.

  ## Parameters

  - `site_name` - The site identifier to delete JavaScript for

  ## Returns

  - `:ok` on successful deletion
  - Error tuple if deletion fails

  ## Usage

      # Clean up old JavaScript
      JavaScriptCompiler.delete_compiled_js("old_site")

      # Force recompilation by deleting and recompiling
      JavaScriptCompiler.delete_compiled_js("main")
      JavaScriptCompiler.compile_and_store("main")
  """
  def delete_compiled_js(site_name), do: AssetsState.delete(site_name, "js")

  @doc """
  Refreshes JS for a site (recompiles and updates).

  Convenience function that recompiles JavaScript for a site and updates
  the cache. This is useful when JavaScript hooks or configurations change.

  ## Parameters

  - `site_name` - The site identifier to refresh JavaScript for

  ## Returns

  - `{:ok, compiled_js}` - On successful recompilation
  - `{:error, reason}` - On compilation failure

  ## Usage

      # Refresh after updating JavaScript hooks
      case JavaScriptCompiler.refresh_js("main") do
        {:ok, js} ->
          Logger.info("JavaScript refreshed successfully")
        {:error, reason} ->
          Logger.error("Failed to refresh: \#{reason}")
      end

  ## When to Use

  - After updating JavaScript hooks in database
  - When site configuration changes
  - During development when app.js changes
  - For periodic cache invalidation
  """
  def refresh_js(site_name) do
    Logger.info("Refreshing JS for site: #{site_name}")
    compile_and_store(site_name)
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################
  # Get or create temporary directory for build artifacts.
  #
  # Creates a temporary directory within the application's priv/static/temp
  # for storing temporary files during the compilation process.
  #
  # ## Returns
  #
  # Returns the absolute path to the temporary directory.
  #
  # ## Directory Structure
  #
  # - Development: "priv/static/temp"
  # - Production: "{app_priv_dir}/static/temp"
  defp get_temp_dir do
    dir =
      case :code.priv_dir(@host_app) do
        {:error, _} -> Path.join(["priv", "static", "temp"])
        priv_dir -> Path.join([priv_dir, "static", "temp"])
      end

    _ = File.mkdir_p!(dir)
    dir
  end

  # Get or create JavaScript assets directory structure.
  #
  # Creates the complete directory structure needed for JavaScript compilation
  # including subdirectories for different asset types.
  #
  # ## Returns
  #
  # Returns the base assets directory path.
  #
  # ## Created Directories
  #
  # - `js_assets/` - Base assets directory
  # - `js_assets/js/` - Site-specific JavaScript files
  # - `js_assets/vendor/` - Vendor JavaScript files
  # - `js_assets/node_modules/` - Node modules for ESBuild
  defp get_js_assets_dir do
    dir =
      case :code.priv_dir(@host_app) do
        {:error, _} -> Path.join(["priv", "static", "temp", "js_assets"])
        priv_dir -> Path.join([priv_dir, "static", "temp", "js_assets"])
      end

    Enum.map(
      [dir, Path.join(dir, "js"), Path.join(dir, "vendor"), Path.join(dir, "node_modules")],
      &File.mkdir_p!/1
    )

    dir
  end

  # Ensure Phoenix colocated hooks are available for compilation.
  #
  # Sets up the phoenix-colocated module structure needed for ESBuild compilation.
  # Either copies existing colocated hooks or creates a stub if none exist.
  #
  # ## Parameters
  #
  # - `js_assets_dir` - The base JavaScript assets directory
  #
  # ## Behavior
  #
  # 1. Checks for existing Phoenix-generated colocated hooks
  # 2. Copies them if found, otherwise creates a stub
  # 3. Creates proper node_modules structure for ESBuild resolution
  #
  # ## File Structure
  #
  # Creates: `node_modules/phoenix-colocated/mishka_cms.js`
  defp ensure_colocated_hooks(js_assets_dir) do
    colocated_dir = Path.join([js_assets_dir, "node_modules", "phoenix-colocated"])
    _ = File.mkdir_p!(colocated_dir)

    colocated_file = Path.join(colocated_dir, "mishka_cms.js")

    # Check if Phoenix generated the colocated hooks
    priv_dir =
      case :code.priv_dir(@host_app) do
        {:error, _} -> "priv"
        priv_dir -> priv_dir
      end

    source_colocated = Path.join([priv_dir, "static", "colocated", "mishka_cms.js"])

    cond do
      # If Phoenix generated colocated hooks exist, copy them
      File.exists?(source_colocated) ->
        File.copy!(source_colocated, colocated_file)
        Logger.debug("Copied phoenix-colocated/mishka_cms from Phoenix generated file")

      # Otherwise create a stub
      !File.exists?(colocated_file) ->
        stub_content = """
        // Auto-generated stub for phoenix-colocated hooks
        export const hooks = {};
        """

        File.write!(colocated_file, stub_content)
        Logger.debug("Created stub for phoenix-colocated/mishka_cms")

      true ->
        :ok
    end
  end

  # The site's active hooks, split into those whose npm packages are in place and those left out
  # because their packages cannot be had. Packages are fetched once into `node_modules/`, where
  # esbuild resolves the hook's bare imports — see `NpmPackages`.
  defp runtime_hooks(site_name, global_only?, js_assets_dir) do
    case load_runtime_hooks(site_name, global_only?) do
      :none ->
        {[], []}

      hooks ->
        Enum.reduce(hooks, {[], []}, fn hook, {ready, left_out} ->
          case NpmPackages.ensure(hook.npm, js_assets_dir) do
            :ok -> {ready ++ [hook], left_out}
            {:error, reason} -> {ready, [{hook, reason} | left_out]}
          end
        end)
    end
  end

  # ONE HOOK THAT DOES NOT BUILD IS LEFT OUT, and the rest of the site's hooks still build: a single
  # unresolved import or syntax error fails esbuild for the whole bundle, and that bundle is what
  # starts every page's live connection. esbuild names the file of each error, so an error in a
  # hook's own file, in one of its `modules` or inside one of its `npm` packages leaves that hook out
  # and the bundle is built again without it. An error no hook owns — `boot.js`, a shared hook —
  # fails the compile, and the hooks the bundle served before stay as they were reported.
  defp bundle({hooks, left_out}, site_name, tmp_dir) do
    _ = write_runtime_hooks!(hooks, site_name)

    case execute_esbuild(tmp_dir, site_name) do
      {:ok, js} ->
        report_left_out(left_out, site_name)
        {:ok, js}

      {:error, reason} ->
        hooks
        |> failing_hooks(reason, site_name)
        |> rebuild_without(reason, {hooks, left_out}, site_name, tmp_dir)
    end
  end

  defp rebuild_without([], reason, _hooks, _site_name, _tmp_dir), do: {:error, reason}

  defp rebuild_without(failing, _reason, {hooks, left_out}, site_name, tmp_dir) do
    failing_ids = Enum.map(failing, fn {hook, _reason} -> hook.id end)

    _ = cleanup_runtime_files(Path.join([get_js_assets_dir(), "js", site_name]))

    bundle(
      {Enum.reject(hooks, &(&1.id in failing_ids)), failing ++ left_out},
      site_name,
      tmp_dir
    )
  end

  # esbuild prints each error as `✘ [ERROR] <message>`, a blank line, then `    <file>:<line>:<col>:`.
  @esbuild_error ~r/^\S+ \[ERROR\] ([^\n]+)\n\n\s+([^\n]+?):(\d+):\d+:$/m

  defp failing_hooks(hooks, output, site_name) do
    errors = Regex.scan(@esbuild_error, output, capture: :all_but_first)

    for hook <- hooks,
        owned =
          Enum.filter(errors, fn [_message, file, _line] -> owns?(hook, file, site_name) end),
        owned != [],
        do: {hook, Enum.map_join(owned, "; ", &describe_error/1)}
  end

  defp describe_error([message, file, line]), do: "#{message} (#{Path.basename(file)}:#{line})"

  # esbuild prints the real path of a file, so a hook's files are matched by their last segments.
  defp owns?(hook, file, site_name) do
    own_files = Enum.map(hook_files(hook, site_name), &["js", site_name, &1])

    Enum.take(Path.split(file), -3) in own_files or
      Enum.any?(hook.npm || [], &in_package?(file, &1))
  end

  defp hook_files(hook, site_name) do
    modules =
      for module <- hook.modules || [],
          MishkaCmsCore.Runtime.Resources.Validations.HookPackages.module?(module),
          do: NpmPackages.stringify(module)["file"]

    [hook_file(hook, site_name) | modules]
  end

  defp in_package?(file, entry) do
    case NpmPackages.stringify(entry) do
      %{"path" => path} when is_binary(path) -> String.contains?("/" <> file, "/" <> path <> "/")
      _not_a_package -> false
    end
  end

  # What a bundle left out is replaced only when the bundle is built, so it always describes the
  # bundle being served.
  defp report_left_out(left_out, site_name) do
    CompileFailureState.clear_matching(left_out_key(:_, site_name))

    Enum.each(left_out, fn {hook, reason} ->
      Logger.warning(
        "[JavaScriptCompiler] #{hook.name} is left out of #{site_name}'s JavaScript: #{reason}"
      )

      CompileFailureState.record(left_out_key(hook.id, site_name), reason)

      MishkaInstaller.Event.Hook.call(
        "runtime:compile:js_hook_skipped",
        %{hook: hook.name, site: site_name, reason: reason},
        meta: %{site: site_name},
        return: false
      )
    end)
  end

  @doc """
  The bundles the JS hook `hook_id` was left out of when they were last built, each with the
  reason, sorted by bundle: `[{"localhost", ~s(Could not resolve "echarts" (globalChart.js:28))}]`.

  A bundle is a site's name, or `"#{@shared_base_id}"` for the global hooks every site without hooks
  of its own shares. A global hook is built into every site's bundle, so it can be left out of
  several.
  """
  @spec left_out(String.t()) :: [{String.t(), String.t()}]
  def left_out(hook_id) do
    hook_id
    |> left_out_key(:_)
    |> CompileFailureState.matching()
    |> Enum.map(fn {{_resource, _hook_id, bundle}, reason} -> {bundle, reason} end)
    |> Enum.sort()
  end

  defp left_out_key(hook_id, bundle), do: {MishkaCmsCore.Runtime.JsHook, hook_id, bundle}

  # Writes each hook to `{site_name}/{hookName}.js` beside its `modules`, and
  # `{site_name}/mishka_runtime_components.js`, which exports them all under their browser names:
  # `Global{Name}` for a global hook, `{SitePrefix}{Name}` for a site's own.
  defp write_runtime_hooks!(hooks, site_name) do
    site_js_dir = Path.join([get_js_assets_dir(), "js", site_name])
    _ = File.mkdir_p!(site_js_dir)

    runtime_hook_agregator = """
    const MishkaRuntimeComponents = {};

    export default MishkaRuntimeComponents;
    """

    runtime_hook_agregator_content =
      Enum.reduce(hooks, runtime_hook_agregator, fn hook, acc ->
        write_modules(hook, site_js_dir)
        formatted_hook_name = format_hook_name(hook, site_name)
        filename = hook_file(hook, site_name)

        File.write!(Path.join(site_js_dir, filename), hook.content)

        import = """
        import #{formatted_hook_name} from "./#{filename}";
        """

        {:ok, _, imported} = Parser.insert_imports(acc, import)

        {:ok, _, extended} =
          imported
          |> Parser.extend_var_object_by_object_names(
            "MishkaRuntimeComponents",
            "#{formatted_hook_name}"
          )

        {:ok, _, formatted} = Formatter.format(extended)
        formatted
      end)

    site_js_dir
    |> Path.join("mishka_runtime_components.js")
    |> File.write!(runtime_hook_agregator_content)
  end

  defp hook_file(hook, site_name) do
    <<first::utf8, rest::binary>> = format_hook_name(hook, site_name)
    String.downcase(<<first::utf8>>) <> rest <> ".js"
  end

  # The files a hook imports from beside itself (`./chart_extensions.js`), written next to it. The
  # names were checked when the hook was saved — see `Validations.HookPackages`.
  defp write_modules(hook, site_js_dir) do
    for module <- hook.modules || [],
        MishkaCmsCore.Runtime.Resources.Validations.HookPackages.module?(module),
        %{"file" => file, "content" => content} = NpmPackages.stringify(module),
        do: File.write!(Path.join(site_js_dir, file), content)
  end

  # Active JS hooks for a compile. The shared base (`global_only?`) takes the
  # global hooks (site_id IS NULL) only; a real site adds its own on top.
  # Returns `:none` when there are no hooks to aggregate.
  defp load_runtime_hooks(_site_name, true) do
    MishkaCmsCore.Runtime.JsHook
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(active == true and is_nil(site_id))
    |> Ash.Query.load([:is_global])
    |> Ash.read!(authorize?: false, page: false)
  end

  defp load_runtime_hooks(site_name, false) do
    case SiteState.get_by_name(site_name) do
      {:error, :not_found} ->
        :none

      {:ok, data} ->
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(active == true and (site_id == ^data.id or is_nil(site_id)))
        |> Ash.Query.load([:is_global])
        |> Ash.read!(authorize?: false, page: false)
    end
  end

  # Execute ESBuild compilation with optimized settings.
  #
  # Runs ESBuild to bundle JavaScript with production optimizations including
  # minification, tree shaking, and modern ES2022 output.
  #
  # ## Parameters
  #
  # - `tmp_dir` - Temporary directory for output files
  # - `site_name` - Site identifier for entry file generation
  #
  # ## Returns
  #
  # `{:ok, js}`, or `{:error, reason}` with esbuild's own messages at the end of `reason`.
  #
  # ## ESBuild Configuration
  #
  # - **Target**: ES2022 for modern browser features
  # - **Format**: IIFE for immediate execution
  # - **Platform**: Browser optimizations
  # - **Minification**: Enabled for smaller bundle size
  # - **External**: Excludes fonts and images
  # - **Alias**: @ points to js directory for cleaner imports
  #
  # Which esbuild profile to run. The host defines it in its own config (the CMS calls it
  # `:mishka_cms_js`); a different host names its own.
  defp esbuild_profile,
    do: Application.get_env(:mishka_cms_core, :esbuild_profile, :"#{@host_app}_js")

  defp execute_esbuild(tmp_dir, site_name) do
    timestamp = :os.system_time(:nanosecond)
    output_file = Path.join(tmp_dir, "output_#{site_name}_#{timestamp}.js")
    js_assets_dir = get_js_assets_dir()
    entry_file = create_entry_file(js_assets_dir, site_name, timestamp)

    # TODO: we need check we are in dev or not and based on convert the JS
    try do
      args = [
        entry_file,
        "--bundle",
        "--target=es2022",
        "--format=iife",
        "--platform=browser",
        "--minify",
        "--outfile=#{output_file}",
        "--log-level=error",
        "--log-limit=0",
        "--color=false",
        "--external:/fonts/*",
        "--external:/images/*",
        "--resolve-extensions=.js",
        "--alias:@=#{Path.join(js_assets_dir, "js")}"
      ]

      case run_esbuild(args) do
        {_output, 0} ->
          {:ok, File.read!(output_file)}

        {output, exit_code} ->
          {:error,
           """
           Esbuild compilation failed with exit code #{exit_code}
           Profile: #{esbuild_profile()}
           Entry file: #{entry_file}
           Output file: #{output_file}
           Args: #{inspect(args)}

           #{output}
           """}
      end
    after
      Enum.each([entry_file, output_file, "#{output_file}.map"], &File.rm/1)
    end
  end

  # The profile run the way `Esbuild.run/2` runs it, with esbuild's messages kept rather than
  # streamed to stdout: they name the file each error is in.
  defp run_esbuild(args) do
    config = Esbuild.config_for!(esbuild_profile())

    System.cmd(Esbuild.bin_path(), (config[:args] || []) ++ args,
      cd: config[:cd] || File.cwd!(),
      env: Map.new(config[:env] || %{}, fn {key, value} -> {key, env_value(value)} end),
      stderr_to_stdout: true
    )
  end

  defp env_value(value) when is_list(value) do
    separator =
      case :os.type() do
        {:win32, _} -> ";"
        {:unix, _} -> ":"
      end

    Enum.join(value, separator)
  end

  defp env_value(value), do: value

  # Create entry file combining app.js with runtime components.
  #
  # Generates a temporary entry file that merges the base app.js with
  # site-specific runtime components for ESBuild compilation.
  #
  # ## Parameters
  #
  # - `js_assets_dir` - Base JavaScript assets directory
  # - `site_name` - Site identifier for component imports
  # - `timestamp` - Unique timestamp for file naming
  #
  # ## Returns
  #
  # Returns the path to the created entry file.
  #
  # ## Process
  #
  # 1. Reads base app.js file
  # 2. Adds import for site-specific runtime components
  # 3. Extends Phoenix hooks object with runtime components
  # 4. Formats the final JavaScript using IgniterJs
  # 5. Writes temporary entry file
  # THE ENTRY IS FIVE LINES, WRITTEN HERE, rather than the admin's own `app.js` rewritten.
  #
  # It used to read `app.js` whole and splice `...MishkaRuntimeComponents` into its `hooks:` object
  # with an AST pass. That worked, and it meant a site's bundle WAS the admin's bundle: the page
  # builder, the dashboard's widget grid and `sortablejs` shipped to every visitor of every site, to
  # sit unmounted. It also made the compile depend on the shape of a file nobody thought of as
  # shared — moving the `new LiveSocket` call broke the splice.
  #
  # `assets/js/site.js` is the same four lines, built by the root esbuild profile, so a syntax error
  # in `boot.js` or `site_hooks.js` is caught at build time rather than at the next site compile.
  defp create_entry_file(js_assets_dir, site_name, timestamp) do
    entry_path = Path.join([js_assets_dir, "js", "entry_#{site_name}_#{timestamp}.js"])

    entry = """
    import { boot } from "./boot";
    import SharedHooks from "./shared_hooks";
    import SiteHooks from "./site_hooks";
    import MishkaRuntimeComponents from "./#{site_name}/mishka_runtime_components.js";

    boot({ ...SharedHooks, ...SiteHooks, ...MishkaRuntimeComponents });
    """

    _ = File.write!(entry_path, entry)
    entry_path
  end

  # Clean up temporary runtime files after compilation.
  #
  # Removes all generated JavaScript files from the site-specific directory
  # to keep the build environment clean.
  #
  # ## Parameters
  #
  # - `site_js_dir` - The site-specific JavaScript directory to clean
  #
  # ## Behavior
  #
  # - Removes all .js files from the directory
  # - Ignores errors if directory doesn't exist
  # - Preserves directory structure for future compilations
  defp cleanup_runtime_files(site_js_dir) do
    case File.ls(site_js_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".js"))
        # `File.rm` (not `rm!`): a concurrent build may have already removed a
        # file; cleanup must never fail the compile.
        |> Enum.each(&File.rm(Path.join(site_js_dir, &1)))

      {:error, _} ->
        :ok
    end
  end

  # Format JavaScript hook name based on naming conventions.
  #
  # Converts hook names to proper JavaScript identifiers using PascalCase
  # with appropriate prefixes for global and site-specific hooks.
  #
  # ## Parameters
  #
  # - `hook` - Hook struct containing name and is_global flag
  # - `site_name` - Site identifier for non-global hooks
  #
  # ## Returns
  #
  # Returns a properly formatted JavaScript identifier.
  #
  # ## Naming Rules
  #
  # - Global hooks: `Global{PascalCaseHookName}`
  # - Site hooks: `{PascalCaseSiteName}{PascalCaseHookName}`
  # - Converts dashes and underscores to PascalCase
  #
  # ## Examples
  #
  # - Global "user-menu" → "GlobalUserMenu"
  # - Site "main" + "shopping-cart" → "MainShoppingCart"
  @doc """
  The name a runtime hook is registered under in the browser.

  Public because the builder's hook picker has to write exactly this string into `phx-hook`, and a
  second copy of the rule would drift from the one that does the registering.
  """
  @spec browser_name(map(), String.t() | nil) :: String.t()
  def browser_name(hook, site_name), do: format_hook_name(hook, site_name)

  defp format_hook_name(hook, site_name) do
    base_name = hook.name |> String.split("-") |> Enum.map(&String.capitalize/1) |> Enum.join("")

    case {hook.is_global, site_name} do
      {true, _any} ->
        "Global#{base_name}"

      # A SITE HOOK WITH NO SITE NAME cannot be given the prefix it is compiled under, and this used
      # to hand `nil` to `String.split/3` — a 500 on the way into the editor rather than a missing
      # name. Callers should not ask (see `MishkaCmsCore.Runtime.PageBuilder.Hooks.available/3`);
      # answering the bare name is better than raising if one does.
      {_site_scoped, nil} ->
        base_name

      {_site_scoped, name} ->
        prefix =
          name |> String.split(["_", "-"]) |> Enum.map(&String.capitalize/1) |> Enum.join("")

        "#{prefix}#{base_name}"
    end
  end
end
