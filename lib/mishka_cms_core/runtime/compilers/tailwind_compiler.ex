defmodule MishkaCmsCore.Runtime.Compilers.TailwindCompiler do
  @moduledoc """
  Production-ready Tailwind CSS v4 compiler for runtime CSS generation with multi-site support.

  The `TailwindCompiler` provides comprehensive CSS compilation capabilities for the MishkaCms
  ecosystem, integrating with `AssetsState` for efficient site-specific CSS management and
  caching. It supports dynamic template scanning, custom variants, Phoenix LiveView integration,
  and production-optimized asset compression.

  ## Features

  * **Multi-Site CSS Compilation**: Generate and manage CSS for multiple sites independently
  * **Runtime Template Scanning**: Dynamically scans templates and JavaScript assets for Tailwind classes
  * **Phoenix LiveView Integration**: Built-in support for LiveView loading states and lifecycle
  * **Asset Compression**: Automatic Brotli and Gzip compression for optimized delivery
  * **AssetsState Integration**: Seamless integration with MishkaCms asset management system
  * **Production Optimization**: Minified output with configurable source paths
  * **Dark Mode Support**: Custom dark mode variant using data attributes
  * **Custom Variants**: Pre-configured Phoenix-specific loading state variants

  ## Static base (compile time) vs runtime DB content

  Tailwind classes reach this CMS from two timelines:

    * **Compile time** — the host app's `lib/**`, the extensions
      (`__extensions/**`, later `deps/mishka_*`), and `assets/css/app.css`.
      These don't change after a release is built, so Tailwind's own
      scanner reads them ONCE via `mix mishka.compile_static_css`, which
      writes `priv/static/temp/static_base.css`. That file ships in the
      release and is prepended verbatim to every site's CSS. No regex — the
      scanner reads every `class={[...]}` list, `&&` conditional, macro and
      sigil shape natively.

    * **Runtime** — DB-stored `Component` / `Page` / `Layout` / `Stylesheet`
      rows. These change when an admin saves, so they're scanned by Tailwind
      at boot and on each per-resource Oban job, then concatenated on top of
      the static base.

  In **development** the `static_base.css` file is absent, so the compiler
  scans the live source tree directly (see `host_app_web_sources/0`).
  Tailwind has the real files, so nothing is missed. The precompiled file
  exists only for **releases**, where the source tree isn't on disk.

  ## Theme tokens (`@theme`) — the one trade-off to know

  A custom utility such as `bg-brand-500` only generates CSS if its token
  (`--color-brand-500`) is defined in an `@theme {}` block present in the
  SAME Tailwind compile. Tokens can live in two places:

    * `assets/css/app.css` (or a kit theme file) — present at **compile** time.
    * A `Stylesheet` DB row of `kind: :theme` — present only at **runtime**.

  This produces one rule you must respect:

  | Where the class is used | Where its token lives | Result |
  |-------------------------|-----------------------|--------|
  | DB content (component/page) | DB `:theme` row       | ✅ both meet at runtime |
  | DB content                  | `app.css`             | ✅ token present at runtime too |
  | **Static code** (`lib/`, ext) | `app.css`           | ✅ token present at compile time |
  | **Static code**             | **DB `:theme` only**  | ❌ dropped — see below |

  The failure case: a custom color used in **static code** whose token lives
  **only in the DB**. At compile time the token doesn't exist, so the static
  base never gets the rule; at runtime the class isn't in DB content, so it's
  never generated. It silently produces no CSS.

  ### Rule: custom color in a static file ⇒ define its token in a static file

  To use `bg-brand-500` in a LiveView/component under `lib/` or an extension,
  declare the token in `assets/css/app.css`:

      /* assets/css/app.css */
      @theme {
        --color-brand-500: oklch(0.62 0.21 12);
      }

  Now the token is present at compile time, `static_base.css` resolves
  `bg-brand-500`, and it ships in the release. A per-site DB theme can still
  override the *visual value* at runtime through the `:custom`/`:theme`
  stylesheet layers — it just can't introduce a brand-new token that static
  code depends on.

  ## Basic Usage

      # Compile CSS for a specific site
      case TailwindCompiler.compile("my_site") do
        {:ok, css} ->
          IO.puts("CSS compiled successfully")
          IO.puts("Size: \#{byte_size(css)} bytes")

        {:error, reason} ->
          IO.puts("Compilation failed: \#{reason}")
      end

  ## Integrated Workflow with AssetsState

      # Compile and automatically store in AssetsState with compression
      case TailwindCompiler.compile_and_store("production_site") do
        {:ok, css} ->
          # CSS is now available in multiple formats:
          # - Raw CSS
          # - Brotli compressed
          # - Gzip compressed
          IO.puts("CSS compiled and cached successfully")

        {:error, reason} ->
          Logger.error("Failed to compile CSS: \#{reason}")
      end

      # Retrieve compiled CSS from cache
      css = TailwindCompiler.get_compiled_css("production_site")

      # Get compressed version for optimal delivery
      brotli_css = TailwindCompiler.get_compiled_css("production_site", "brotli_css")
      gzip_css = TailwindCompiler.get_compiled_css("production_site", "gzip_css")

  ## Asset Management Operations

      # Check compilation status
      status = TailwindCompiler.get_css_status("my_site")
      # Returns: %{
      #   site: "my_site",
      #   compiled: true,
      #   updated_at: ~U[2024-01-01 12:00:00Z],
      #   css_size: 125_000
      # }

      # Refresh CSS (recompile and update cache)
      {:ok, fresh_css} = TailwindCompiler.refresh_css("my_site")

      # Check if CSS exists
      if TailwindCompiler.css_exists?("my_site") do
        IO.puts("CSS is available")
      end

      # Clean up CSS for a site
      :ok = TailwindCompiler.delete_compiled_css("my_site")

  ## CSS Source Configuration

  The compiler automatically configures Tailwind CSS v4 with comprehensive source scanning:

      # static_base.css (compile-time) prepended verbatim — host app + extensions
      @source "runtime/my_site/js_hook/**/*.template"     # Reachable by no walk, so globbed
      @source "runtime/my_site/stylesheet/**/*.template"
      @source "runtime/__global__/js_hook/**/*.template"
      @source "runtime/__global__/stylesheet/**/*.template"
      @source "runtime/my_site/page/home.template"        # One line per REACHABLE template:
      @source "runtime/my_site/layout/main.template"      # the site's pages and error pages, the
      @source "runtime/__global__/component/alert.template" # layouts they use, the components
      @source "runtime/__global__/component/icon.template"  # they name — see `closure_roots/2`
      @source "js_assets/js/**/*.js"                   # Runtime JS hooks (NOT vendor/ — see below)
      @source "js_assets/js/**/*.ts"                   # TypeScript files

  ## Custom Variants and Phoenix Integration

      /* Phoenix LiveView loading states */
      @custom-variant phx-click-loading (.phx-click-loading&, .phx-click-loading &);
      @custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
      @custom-variant phx-change-loading (.phx-change-loading&, .phx-change-loading &);

      /* Data attribute-based dark mode */
      @custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *));

  ## Usage in Phoenix Controllers/LiveViews

      defmodule MyAppWeb.PageController do
        use MyAppWeb, :controller

        def show(conn, %{"site" => site_name}) do
          # Ensure CSS is compiled for the site
          case TailwindCompiler.compile_and_store(site_name) do
            {:ok, _css} ->
              render(conn, :show, site: site_name)

            {:error, reason} ->
              conn
              |> put_flash(:error, "Failed to load site styles")
              |> redirect(to: "/")
          end
        end
      end

      defmodule MyAppWeb.AdminLive do
        use MyAppWeb, :live_view

        def handle_event("refresh_css", %{"site" => site}, socket) do
          case TailwindCompiler.refresh_css(site) do
            {:ok, _css} ->
              {:noreply, put_flash(socket, :info, "CSS refreshed successfully")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to refresh CSS: \#{reason}")}
          end
        end
      end

  ## Performance Optimization

      # Batch operations for multiple sites
      sites = ["site1", "site2", "site3"]

      compiled_sites =
        Task.async_stream(sites, &TailwindCompiler.compile_and_store/1,
          max_concurrency: 3,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

  ## Error Handling and Debugging

      case TailwindCompiler.compile("problematic_site") do
        {:ok, css} ->
          Logger.info("Successfully compiled \#{byte_size(css)} bytes of CSS")

        {:error, reason} ->
          Logger.error("Tailwind compilation failed: \#{reason}")

          # Check system requirements
          if !System.find_executable("node") do
            Logger.error("Node.js not found - required for Tailwind compilation")
          end

          # Verify template paths exist
          temp_dir = System.tmp_dir()
          Logger.info("Using temporary directory: \#{temp_dir}")
      end

  ## Production Deployment Considerations

  * **Asset Precompilation**: Consider pre-compiling CSS during deployment for faster startup
  * **Memory Management**: CSS assets are cached in memory; monitor memory usage with many sites
  * **Concurrent Compilation**: Use Task.async_stream for bulk compilation operations
  * **File System Access**: Ensure proper permissions for temporary directory operations
  * **Node.js Dependency**: Requires Node.js runtime for Tailwind CLI execution


  ## Asset Compression Details

  All compiled CSS is automatically compressed using multiple algorithms:
  * **Brotli**: Best compression ratio, supported by modern browsers
  * **Gzip**: Universal compatibility, good compression ratio
  * **Raw CSS**: Uncompressed for development and fallback scenarios

  The compiler calculates MD5 hashes for cache invalidation and stores metadata
  including compilation timestamps and asset sizes.
  """

  # The CSS this compiler starts from — app.css, the heroicons bundle — lives in the priv of the
  # application this library is installed into, not in this library.
  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  require Logger
  require Ash.Query
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.Compilers.CssClosure
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Stylesheet

  # Track if Tailwind binary is verified (avoid repeated install checks)
  @tailwind_verified_key :tailwind_binary_verified

  # THE TEMPLATE KINDS NO WALK CAN REACH. A JS hook is JavaScript and a stylesheet row is CSS;
  # neither is the target of a `component_name=` edge, so neither can be discovered from markup and
  # both keep a directory glob. Pages, error pages, layouts and components are all reachable and are
  # scanned per site from `CssClosure`.
  @unwalkable_kinds ["js_hook", "stylesheet"]

  @doc """
  Ensures Tailwind binary is installed. Call once at boot time.

  This avoids repeated install checks during `install_and_run/2` calls.
  After calling this, use `run/2` instead of `install_and_run/2`.
  """
  def ensure_installed do
    case :persistent_term.get(@tailwind_verified_key, false) do
      true -> :ok
      false -> alone(&verify_and_install/0)
    end
  end

  # ONE PROCESS AT A TIME, OR THE CHECK BREAKS THE THING IT IS CHECKING.
  #
  # `@tailwind_verified_key` memoises only a SUCCESSFUL verify, so every caller that arrives before
  # the first one finishes misses it and runs the check itself. At boot that is at least two — the
  # dev assets watcher compiles a site's CSS and its JS — and they raced over one file:
  #
  #     [TailwindCompiler] Verifying Tailwind v4.3.2 binary...
  #     [TailwindCompiler] Verifying Tailwind v4.3.2 binary...
  #     could not read a version from the Tailwind binary at … — installing Tailwind v4.3.2...
  #     could not read a version from the Tailwind binary at … — installing Tailwind v4.3.2...
  #
  # Both verifies failed because the OTHER was part-way through writing an 80 MB download over the
  # same path, so each concluded the binary was unusable and started a download of its own — which
  # broke the next verify in turn. Observed on a developer machine where the binary on disk was
  # perfectly good: `--help` printed `tailwindcss v4.3.2` and the regex matched it by hand. Site
  # assets never finished compiling, so pages served an empty stylesheet under a hash-less URL, and
  # every later Tailwind pass queued behind a download that started again each time.
  #
  # A global lock rather than a process, because there is no state to hold and nothing to supervise:
  # whoever gets there first installs, everyone else waits and then finds the answer memoised.
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
      :aborted -> {:error, "could not take the Tailwind install lock"}
      result -> result
    end
  end

  defp verify_and_install do
    # Asked again INSIDE the lock: the pass this caller queued behind was very likely the install,
    # and repeating an 80 MB download to confirm it would be the whole bug again in miniature.
    case :persistent_term.get(@tailwind_verified_key, false) do
      true ->
        :ok

      false ->
        version = Application.fetch_env!(:tailwind, :version)
        Logger.info("[TailwindCompiler] Verifying Tailwind v#{version} binary...")
        ensure_binary(Tailwind.bin_path(), version)
        :persistent_term.put(@tailwind_verified_key, true)
        :ok
    end
  end

  defp ensure_binary(path, version) do
    case verify_binary(path, version) do
      :ok ->
        Logger.info("[TailwindCompiler] Tailwind v#{version} verified at #{path}")

      {:error, reason} ->
        Logger.warning("[TailwindCompiler] #{reason} — installing Tailwind v#{version}...")
        Tailwind.install()
        log_post_install(Tailwind.bin_path(), version)
    end
  end

  defp log_post_install(path, version) do
    case verify_binary(path, version) do
      :ok ->
        Logger.info("[TailwindCompiler] Tailwind v#{version} installed at #{path}")

      {:error, reason} ->
        Logger.error("[TailwindCompiler] Tailwind v#{version} unusable after install: #{reason}")
    end
  end

  # Confirms the binary is present, is an executable regular file, and — by
  # running it — reports the version pinned in `config :tailwind, :version`.
  # Guards three failure modes: a missing file (the tailwind 0.5+ wrapper renamed
  # the binary to `tailwind-<target>-<version>`, so a stale name reads as absent),
  # a non-executable or partial download, and a version drift after the pin moves.
  defp verify_binary(path, version) do
    with {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) != 0,
         {:ran, output, status} <- ran(path) do
      reported(
        Regex.run(~r/tailwindcss v(\d+\.\d+\.\d+)/, output),
        version,
        path,
        output,
        status,
        size
      )
    else
      {:error, :enoent} -> {:error, "Tailwind binary missing at #{path}"}
      {:error, posix} -> {:error, "cannot stat Tailwind binary at #{path} (#{inspect(posix)})"}
      {:ok, %File.Stat{}} -> {:error, "Tailwind path #{path} is not a regular file"}
      false -> {:error, "Tailwind binary at #{path} is not executable"}
      {:raised, why} -> {:error, "could not run the Tailwind binary at #{path}: #{why}"}
    end
  end

  # `System.cmd/3` RAISES rather than answering when it cannot run the file at all — a bad
  # interpreter, a wrong architecture, a working directory the process can no longer reach. That
  # raise used to escape this function entirely, so the caller saw a crash instead of a reason.
  defp ran(path) do
    {output, status} =
      System.cmd(path, ["--help"], stderr_to_stdout: true, env: [{"NO_COLOR", "1"}])

    {:ran, uncoloured(output), status}
  rescue
    error -> {:raised, Exception.message(error)}
  end

  # THE BINARY PAINTS ITS OWN OUTPUT, and that is why this check failed on a Tailwind that worked.
  # Under the development server it printed
  #
  #     "\e[3m\e[1m\e[34m≈\e[39m\e[22m\e[23m tailwindcss \e[34mv4.3.2\e[39m"
  #
  # — a colour escape sits BETWEEN `tailwindcss ` and `v4.3.2`, so a pattern wanting them adjacent
  # never matched. The same binary run by hand into a pipe emitted no colour and matched perfectly,
  # which is exactly why this looked like it could not be reproduced.
  #
  # `NO_COLOR` asks; stripping does not have to trust the answer, since the variable is a convention
  # and a later version may paint regardless.
  defp uncoloured(output), do: String.replace(output, ~r/\e\[[0-9;]*[a-zA-Z]/, "")

  defp reported([_whole, version], version, _path, _output, _status, _size), do: :ok

  defp reported([_whole, other], version, path, _output, _status, _size),
    do: {:error, "binary at #{path} reports v#{other}, config pins v#{version}"}

  # WHAT IT ACTUALLY SAID, because "could not read a version" is not a diagnosis. A binary that is
  # fine by hand and unreadable here is the interesting case, and the old message threw away every
  # fact that could tell the two apart: what it printed, whether it exited cleanly, how big it is.
  defp reported(nil, _version, path, output, status, size) do
    {:error,
     "could not read a version from the Tailwind binary at #{path} " <>
       "(#{size} bytes, exit #{status}, said: #{inspect(String.slice(output, 0, 160))})"}
  end

  @doc """
  Compiles ONLY the CSS every site shares: the host shell, `app.css`, `js_assets`, and the global
  templates no reachability walk can reach (JS hooks and stylesheet rows).

  This should be called ONCE during boot. The result is cached in AssetsState
  with id "__shared_base__" and reused by all site compilations.

  Global LAYOUTS, ERROR PAGES and COMPONENTS are deliberately absent — a site's stylesheet carries
  what that site renders, so those are reached per site in `compile/1`.

  ## Performance Benefit
  - static_base.css prepended once instead of re-scanned N times
  - the shared global templates scanned once instead of N times
  - js_assets/js/** scanned once instead of N times

  ## Why `js_assets/js/**` and not `js_assets/**`

  `js_assets/vendor/` holds `tailwind-browser.js` — the page builder's in-browser Tailwind engine,
  281 KB whose whole job is to know every utility name there is. Scanning it as a SOURCE meant
  Tailwind read the editor's own name tables as if a template had asked for them, and generated real
  rules into the base every site's stylesheet is built on: a measured 42 KB, of which the great
  majority matched no template anywhere. The site's actual JS hooks live under `js_assets/js/`, so
  the narrower glob keeps them and drops the engine.

  ## Return Values
  - `{:ok, css}` - Successfully compiled shared CSS
  - `{:error, reason}` - Compilation failed
  """
  def compile_shared_base do
    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :tailwind, :shared_base],
      %{},
      fn ->
        result =
          try do
            ensure_installed()
            {:ok, execute_tailwind_shared_base()}
          rescue
            e -> {:error, Exception.message(e)}
          end

        {result, %{}}
      end
    )
  end

  @doc """
  Compiles shared base CSS and stores it in AssetsState for reuse.
  """
  def compile_and_store_shared_base do
    case compile_shared_base() do
      {:ok, css} ->
        {brotli, gzip} = Helpers.compress_asset(css)
        updated_at = DateTime.utc_now()
        hash = Base.encode16(:crypto.hash(:md5, css), case: :lower)

        [
          %{id: "__shared_base__", type: "css", value: css, hash: hash, updated_at: updated_at},
          %{
            id: "__shared_base__",
            type: "brotli_css",
            value: brotli,
            hash: hash,
            updated_at: updated_at
          },
          %{
            id: "__shared_base__",
            type: "gzip_css",
            value: gzip,
            hash: hash,
            updated_at: updated_at
          }
        ]
        |> AssetsState.save_batch()

        Logger.info("[TailwindCompiler] Shared base CSS compiled and cached")
        {:ok, css}

      {:error, reason} = error ->
        Logger.error("[TailwindCompiler] Failed to compile shared base CSS: #{reason}")
        error
    end
  end

  @doc """
  Gets the cached shared base CSS, or compiles it if not available.
  """
  def get_or_compile_shared_base do
    case AssetsState.get_value("__shared_base__", "css") do
      nil ->
        case compile_and_store_shared_base() do
          {:ok, css} -> css
          {:error, _} -> ""
        end

      css ->
        css
    end
  end

  @doc """
  Compiles Tailwind CSS from dynamic templates and assets for a specific site.

  This optimized version:
  1. Uses cached shared base CSS (global templates, js_assets) - avoids rescanning N times
  2. Only compiles site-specific templates
  3. Combines shared base + site-specific CSS

  ## Parameters

  * `site_name` - String identifier for the site (used for template scanning and caching)

  ## Return Values

  * `{:ok, css}` - Successfully compiled CSS as a minified string
  * `{:error, reason}` - Compilation failed

  ## Performance Optimization

  With 20 sites, instead of scanning global templates 20 times:
  - Shared base compiled ONCE (~225ms)
  - Each site only scans its own templates (~50-100ms)
  - Total: ~225ms + 20×75ms = ~1.7s instead of 20×225ms = ~4.5s

  There used to be a second way to answer this — `compile_full/1`, a `use_shared_base: false` mode
  that assembled the whole stylesheet in one Tailwind run. Nothing called it outside its own tests,
  and it restated every decision made here, so the two drifted apart with each change to what gets
  scanned. A stale shared base is dropped with `delete_shared_base_css/0` instead, which is what
  every writer already does.
  """
  def compile(site_name) do
    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :tailwind],
      %{site: site_name},
      fn ->
        result =
          try do
            ensure_installed()
            shared_css = get_or_compile_shared_base()
            site_css = execute_tailwind_site_only(site_name)
            {:ok, shared_css <> "\n/* Site: #{site_name} */\n" <> site_css}
          rescue
            e -> {:error, Exception.message(e)}
          end

        {result, %{}}
      end
    )
  end

  @doc """
  Whether a candidate stylesheet fragment compiles for a site, in Tailwind's own words when it does
  not: `:ok` | `{:error, message}`.

  For CSS that is ABOUT TO BE STORED as a row. Tailwind v4 answers `@apply` of a utility it does not
  know with a non-zero exit, and a stored fragment that does that fails every later compile in its
  scope — so a writer proves it before writing it rather than after.

  Nothing is scanned: the fragment is compiled against the site's theme rows, `tailwind_preamble/0`
  and the utility definitions alone, with no `@source` line, which is what makes this affordable on
  a save. The preamble is the half that is easy to forget and the half that matters — a check
  missing the plugin and the variants is STRICTER than the compiles it stands in for, and refuses
  utilities this CMS ships. It also means this answers for the fragment and nothing else: a row
  that is already broken cannot fail somebody's valid class.
  """
  @spec verify_css(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def verify_css(css, site_id) do
    ensure_installed()
    {global_pre, _global_post} = read_global_stylesheets()

    case ran_tailwind(build_css_content_verify(global_pre, site_pre(site_id), css), "verify") do
      {0, _css, _output} -> :ok
      {_status, _css, output} -> {:error, tailwind_message(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A site inherits the globals, and for the globals themselves the two reads are the same row set.
  defp site_pre(nil), do: ""
  defp site_pre(site_id), do: site_id |> read_stylesheets_for() |> elem(0)

  defp build_css_content_verify(global_pre, site_pre, css) do
    """
    #{global_pre}
    #{site_pre}

    @import "tailwindcss/theme.css" layer(theme);
    @import "tailwindcss/utilities.css" layer(utilities) source(none);

    #{tailwind_preamble()}

    #{css}
    """
  end

  # WHAT TAILWIND SAID, not that it said something. Its refusal names the typo —
  # "Cannot apply unknown utility class `rounde-xl`" — which is the whole value of checking, and it
  # arrives as a boxed, coloured block:
  #
  #     Error:
  #     ┌
  #     │ Error: Cannot apply unknown utility class `rounde-xl`
  #     └
  defp tailwind_message(output) do
    output
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("│") |> String.trim()))
    |> Enum.filter(&String.starts_with?(&1, "Error: "))
    |> List.last()
    |> case do
      nil -> "Tailwind refused that CSS: #{String.trim(output)}"
      line -> String.replace_prefix(line, "Error: ", "")
    end
  end

  @doc """
  Compile a ONE-OFF CSS bundle for a draft/preview: the shared base + the site's classes + the
  draft's OWN template (so brand-new classes in an unpublished draft are styled). Writes the draft
  template into an isolated temp namespace, scans it alongside the site, and removes it after — it
  NEVER touches the live site bundle. Returns `{:ok, css}` | `{:error, reason}`.
  """
  def compile_preview(site_name, preview_ns, template_name, template_content) do
    ensure_installed()
    write_preview_template(preview_ns, template_name, template_content)

    try do
      shared = get_or_compile_shared_base()

      delta =
        run_tailwind(build_css_content_preview(site_name, preview_ns), "preview_#{preview_ns}")

      {:ok, shared <> "\n/* Preview: #{preview_ns} */\n" <> delta}
    rescue
      e -> {:error, Exception.message(e)}
    after
      cleanup_preview_template(preview_ns)
    end
  end

  defp write_preview_template(preview_ns, name, content) do
    dir = Path.join([get_temp_dir(), "runtime", preview_ns, "page"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{preview_slug(name)}.template"), content)
  end

  defp cleanup_preview_template(preview_ns),
    do: File.rm_rf(Path.join([get_temp_dir(), "runtime", preview_ns]))

  defp preview_slug(name) do
    case name
         |> to_string()
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "-")
         |> String.trim("-") do
      "" -> "draft"
      slug -> slug
    end
  end

  defp build_css_content_preview(site_name, preview_ns) do
    closure = closure_for(site_name, [preview_ns])

    {global_pre, _global_post} = read_global_stylesheets()
    {site_pre, post_tailwind} = read_site_stylesheets(site_name)

    """
    #{global_pre}
    #{site_pre}

    @import "tailwindcss/theme.css" layer(theme);
    @import "tailwindcss/utilities.css" layer(utilities) source(none);

    /* SITE: #{site_name} + DRAFT PREVIEW: #{preview_ns} */
    #{site_unwalkable_sources([site_name])}

    /* Walked over the draft TOO. The draft is usually the only thing referencing the component
       being previewed — that is what makes it a draft — so a walk over the saved site alone would
       leave the previewed component unstyled. */
    #{reachable_sources(closure, site_name, [preview_ns])}

    #{tailwind_preamble()}
    #{icon_css(closure, site_name)}

    #{post_tailwind}
    """
  end

  @doc """
  Compiles Tailwind CSS and stores all compressed variants in AssetsState for optimized delivery.

  This function combines compilation with intelligent caching by automatically generating
  and storing multiple compressed formats (raw, Brotli, Gzip) along with metadata for
  efficient asset serving. It provides the complete workflow for production CSS management.

  ## Parameters

  * `site_name` - String identifier for the site

  ## Return Values

  * `{:ok, css}` - Successfully compiled and stored CSS (returns the raw CSS string)
  * `{:error, reason}` - Compilation or storage failed with error message

  ## Storage Process

  1. **CSS Compilation**: Generates minified CSS using `compile/1`
  2. **Multi-format Compression**: Creates Brotli and Gzip compressed variants
  3. **Metadata Generation**: Calculates MD5 hash and timestamp for cache invalidation
  4. **Batch Storage**: Atomically stores all formats in AssetsState
  5. **Logging**: Records successful operations for monitoring

  ## Stored Asset Formats

  * `"css"` - Raw minified CSS for development and fallback
  * `"brotli_css"` - Brotli compressed CSS (best compression, ~20-30% smaller)
  * `"gzip_css"` - Gzip compressed CSS (universal compatibility, ~15-25% smaller)

  ## Examples

      # Basic compilation and storage
      case TailwindCompiler.compile_and_store("ecommerce_site") do
        {:ok, css} ->
          IO.puts("CSS compiled and cached")
          IO.puts("Available formats: css, brotli_css, gzip_css")

        {:error, reason} ->
          Logger.error("Failed to compile ecommerce CSS: \#{reason}")
      end

      # Use in a Phoenix plug for automatic CSS generation
      defmodule EnsureCssPlug do
        def init(opts), do: opts

        def call(conn, _opts) do
          site = get_site_from_conn(conn)

          if !TailwindCompiler.css_exists?(site) do
            case TailwindCompiler.compile_and_store(site) do
              {:ok, _css} -> conn
              {:error, reason} ->
                conn
                |> put_status(500)
                |> Phoenix.Controller.text("CSS compilation failed: \#{reason}")
                |> halt()
            end
          else
            conn
          end
        end
      end

      # Bulk compilation for multiple sites
      sites = ["blog", "shop", "portfolio"]

      results =
        Task.async_stream(
          sites,
          &TailwindCompiler.compile_and_store/1,
          max_concurrency: 2,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

  ## Asset Metadata

  Each stored asset includes comprehensive metadata:
  * `hash` - MD5 hash for cache busting and integrity verification
  * `updated_at` - UTC timestamp for cache management
  * `value` - The actual CSS content (raw or compressed)
  * `type` - Format identifier ("css", "brotli_css", "gzip_css")

  ## Integration with HTTP Serving

      defmodule CssController do
        def serve_css(conn, %{"site" => site}) do
          content_encoding = get_best_encoding(conn)
          css_type = encoding_to_type(content_encoding)

          case AssetsState.get(site, css_type) do
            {:ok, asset} ->
              conn
              |> put_resp_content_type("text/css")
              |> put_resp_header("content-encoding", content_encoding)
              |> put_resp_header("etag", asset.hash)
              |> put_resp_header("cache-control", "public, max-age=31536000")
              |> send_resp(200, asset.value)

            {:error, :not_found} ->
              # Trigger compilation on demand
              case TailwindCompiler.compile_and_store(site) do
                {:ok, _css} -> serve_css(conn, %{"site" => site})
                {:error, _} -> send_resp(conn, 500, "CSS unavailable")
              end
          end
        end
      end

  ## Performance Benefits

  * **Reduced Bandwidth**: Compression reduces transfer sizes by 15-30%
  * **Faster Loading**: Pre-compressed assets eliminate server-side compression overhead
  * **Cache Efficiency**: Hash-based versioning enables aggressive browser caching
  * **CDN Optimization**: Multiple formats support optimal CDN distribution
  """
  def compile_and_store(site_name) do
    MishkaInstaller.Event.Hook.call("runtime:compile:before_css", %{site: site_name},
      meta: %{site: site_name},
      return: false
    )

    case compile(site_name) do
      {:ok, css} ->
        css =
          MishkaInstaller.Event.Hook.call("runtime:compile:css", css, meta: %{site: site_name})

        {brotli, gzip} = Helpers.compress_asset(css)
        updated_at = DateTime.utc_now()
        hash = Base.encode16(:crypto.hash(:md5, css), case: :lower)
        previous_hash = AssetsState.get!(site_name, "css")[:hash]

        [
          %{id: site_name, type: "css", value: css, hash: hash, updated_at: updated_at},
          %{id: site_name, type: "brotli_css", value: brotli, hash: hash, updated_at: updated_at},
          %{id: site_name, type: "gzip_css", value: gzip, hash: hash, updated_at: updated_at}
        ]
        |> AssetsState.save_batch()

        if hash != previous_hash do
          MishkaCmsCore.PubSub
          |> Phoenix.PubSub.broadcast("site:#{site_name}:assets", {:css_updated, hash})
        end

        Logger.debug("Tailwind CSS compiled and stored in AssetsState for site: #{site_name}")
        {:ok, css}

      {:error, reason} = error ->
        Logger.error("Failed to compile Tailwind CSS for site #{site_name}: #{reason}")
        error
    end
  end

  @doc """
  Retrieves compiled CSS from AssetsState cache for a specific site and format.

  This function provides fast access to pre-compiled CSS assets without triggering
  recompilation. It supports multiple compression formats for optimal delivery
  based on client capabilities and performance requirements.

  ## Parameters

  * `site_name` - String identifier for the site
  * `type` - Asset format type (defaults to `"css"`)
    * `"css"` - Raw minified CSS
    * `"brotli_css"` - Brotli compressed CSS
    * `"gzip_css"` - Gzip compressed CSS

  ## Return Value

  * `binary()` - The CSS content as a binary string
  * Returns a CSS comment with error message if the asset doesn't exist

  ## Examples

      # Get standard CSS
      css = TailwindCompiler.get_compiled_css("my_site")

      # Get compressed format for optimal delivery
      brotli_css = TailwindCompiler.get_compiled_css("my_site", "brotli_css")
      gzip_css = TailwindCompiler.get_compiled_css("my_site", "gzip_css")

      # Use in Phoenix controller with content negotiation
      defmodule AssetController do
        def css(conn, %{"site" => site}) do
          format = case get_req_header(conn, "accept-encoding") do
            [encoding] when is_binary(encoding) ->
              cond do
                String.contains?(encoding, "br") -> "brotli_css"
                String.contains?(encoding, "gzip") -> "gzip_css"
                true -> "css"
              end
            _ -> "css"
          end

          css_content = TailwindCompiler.get_compiled_css(site, format)

          conn
          |> put_resp_content_type("text/css")
          |> maybe_put_encoding_header(format)
          |> send_resp(200, css_content)
        end

        defp maybe_put_encoding_header(conn, "brotli_css"),
          do: put_resp_header(conn, "content-encoding", "br")
        defp maybe_put_encoding_header(conn, "gzip_css"),
          do: put_resp_header(conn, "content-encoding", "gzip")
        defp maybe_put_encoding_header(conn, _), do: conn
      end

  ## Error Handling

      # CSS not found scenario
      css = TailwindCompiler.get_compiled_css("non_existent_site")
      # Returns: "/* CSS not found for site: non_existent_site */"

      # Handle missing CSS gracefully
      css = case TailwindCompiler.get_compiled_css("my_site") do
        "/* CSS not found" <> _ ->
          # Trigger compilation if CSS is missing
          case TailwindCompiler.compile_and_store("my_site") do
            {:ok, compiled_css} -> compiled_css
            {:error, _} -> "/* Compilation failed */"
          end
        valid_css -> valid_css
      end

  ## Performance Notes

  * This function performs a direct cache lookup with minimal overhead
  * No disk I/O or compilation occurs - purely memory-based retrieval
  * Consider using compressed formats for production traffic
  * Falls back gracefully with informative error messages for missing assets
  """
  def get_compiled_css(site_name, type \\ "css") do
    case AssetsState.get_value(site_name, type) do
      nil -> "/* CSS not found for site: #{site_name} */"
      css -> css
    end
  end

  @doc """
  Checks if compiled CSS exists for a specific site in the cache.

  This function provides a quick boolean check for CSS availability without
  retrieving the actual content, making it ideal for conditional compilation
  logic and cache validation.

  ## Parameters

  * `site_name` - String identifier for the site

  ## Return Value

  * `true` - CSS exists and is available in the cache
  * `false` - CSS has not been compiled or has been removed

  ## Examples

      # Check before attempting to serve CSS
      if TailwindCompiler.css_exists?("blog_site") do
        css = TailwindCompiler.get_compiled_css("blog_site")
        send_css_response(conn, css)
      else
        # Trigger compilation
        {:ok, _css} = TailwindCompiler.compile_and_store("blog_site")
        redirect_to_css(conn)
      end

      # Batch check multiple sites
      sites = ["site1", "site2", "site3"]
      compiled_sites = Enum.filter(sites, &TailwindCompiler.css_exists?/1)
      missing_sites = sites -- compiled_sites

      # Use in a deployment health check
      defmodule HealthCheck do
        def css_status do
          required_sites = Application.get_env(:app, :required_sites)

          Enum.map(required_sites, fn site ->
            %{
              site: site,
              css_ready: TailwindCompiler.css_exists?(site)
            }
          end)
        end
      end
  """
  def css_exists?(site_name), do: AssetsState.exists?(site_name, "css")

  @doc """
  Deletes all compiled CSS variants for a specific site from the cache.

  This function removes all cached CSS formats (raw, Brotli, Gzip) for a site,
  effectively clearing the cache and forcing recompilation on the next request.
  Useful for cache invalidation when templates or styles are updated.

  ## Parameters

  * `site_name` - String identifier for the site

  ## Return Value

  * `:ok` - CSS successfully deleted or didn't exist

  ## Examples

      # Delete CSS after template updates
      :ok = TailwindCompiler.delete_compiled_css("updated_site")

      # Next request will trigger recompilation
      {:ok, fresh_css} = TailwindCompiler.compile_and_store("updated_site")

      # Use in a cache management task
      defmodule CacheManager do
        def invalidate_site_css(site_name) do
          Logger.info("Invalidating CSS cache for site: \#{site_name}")
          :ok = TailwindCompiler.delete_compiled_css(site_name)

          # Optionally precompile immediately
          Task.start(fn ->
            TailwindCompiler.compile_and_store(site_name)
          end)
        end
      end

      # Bulk cache clearing
      sites_to_clear = ["site1", "site2", "site3"]
      Enum.each(sites_to_clear, &TailwindCompiler.delete_compiled_css/1)

  ## Use Cases

  * **Template Updates**: Clear cache when site templates are modified
  * **Development**: Reset styles during development iterations
  * **Deployment**: Clear cache as part of deployment pipeline
  * **Memory Management**: Periodically clear unused site CSS
  * **Error Recovery**: Clear potentially corrupted cached CSS
  """
  def delete_compiled_css(site_name), do: AssetsState.delete(site_name, "css")

  @doc """
  Invalidate the cached shared-base CSS so the next compile rebuilds it
  from scratch.

  Why this exists: `compile/1` reuses the cached `__shared_base__` row in
  `AssetsState` rather than rebuilding it per site. The shared base prepends
  the precompiled `static_base.css`
  (release) or live-scans the host app's `lib/**` + `__extensions/**` (dev,
  via `host_app_web_sources/0`), so any class added to a LiveView will only
  show up after this cache is cleared.

  The dev `AssetsWatcher` calls this on every host-app file event so a
  `<div class="grid-cols-3">` you just typed makes it into the next CSS
  build. Production deployments don't need it — the shared base is
  rebuilt at boot.
  """
  def delete_shared_base_css do
    AssetsState.delete("__shared_base__", "css")
    AssetsState.delete("__shared_base__", "brotli_css")
    AssetsState.delete("__shared_base__", "gzip_css")
    :ok
  end

  @doc """
  Refreshes CSS for a site by recompiling and updating the cache.

  This function forces a complete recompilation of CSS for a site, regardless
  of whether cached CSS already exists. It combines cache invalidation with
  fresh compilation, ensuring the most up-to-date styles are available.

  ## Parameters

  * `site_name` - String identifier for the site

  ## Return Values

  * `{:ok, css}` - Successfully recompiled and cached fresh CSS
  * `{:error, reason}` - Compilation failed with error message

  ## Examples

      # Refresh CSS after template changes
      case TailwindCompiler.refresh_css("blog_site") do
        {:ok, css} ->
          Logger.info("Blog CSS refreshed: \#{byte_size(css)} bytes")

        {:error, reason} ->
          Logger.error("Failed to refresh blog CSS: \#{reason}")
      end

      # Use in a Phoenix LiveView for admin functionality
      defmodule AdminLive do
        def handle_event("refresh_css", %{"site" => site}, socket) do
          case TailwindCompiler.refresh_css(site) do
            {:ok, _css} ->
              {:noreply, put_flash(socket, :info, "CSS refreshed for \#{site}")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Refresh failed: \#{reason}")}
          end
        end
      end

      # Scheduled CSS refresh for active sites
      defmodule CssRefreshWorker do
        use Oban.Worker, queue: :css_refresh

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"site" => site}}) do
          case TailwindCompiler.refresh_css(site) do
            {:ok, _css} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      end

      # Bulk refresh for multiple sites
      sites = ["blog", "shop", "docs"]

      results =
        Task.async_stream(sites, &TailwindCompiler.refresh_css/1)
        |> Enum.map(fn {:ok, result} -> result end)

  ## When to Use

  * **Template Updates**: After modifying site templates or components
  * **Style Changes**: When custom CSS or Tailwind configuration changes
  * **Deployment**: As part of the deployment process to ensure fresh styles
  * **Development**: During active development for immediate style updates
  * **Maintenance**: Periodic refresh to clear any potential cache inconsistencies
  """
  def refresh_css(site_name) do
    Logger.info("Refreshing CSS for site: #{site_name}")
    compile_and_store(site_name)
  end

  @doc """
  Gets comprehensive CSS compilation status and metadata for a specific site.

  This function returns detailed information about the CSS compilation state,
  including availability, timestamps, and size metrics. It's useful for
  monitoring, debugging, and administrative interfaces.

  ## Parameters

  * `site_name` - String identifier for the site

  ## Return Value

  Returns a map with the following keys:
  * `site` - The site name (string)
  * `compiled` - Boolean indicating if CSS exists
  * `updated_at` - UTC DateTime of last compilation (or `nil` if not compiled)
  * `css_size` - Size of CSS in bytes (or `0` if not compiled)

  ## Examples

      # Check single site status
      status = TailwindCompiler.get_css_status("my_site")
      # => %{
      #   site: "my_site",
      #   compiled: true,
      #   updated_at: ~U[2024-01-15 10:30:45Z],
      #   css_size: 125_430
      # }

      # Use in admin dashboard
      defmodule AdminDashboard do
        def site_status_list do
          Application.get_env(:app, :managed_sites)
          |> Enum.map(&TailwindCompiler.get_css_status/1)
          |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
        end
      end

      # Monitor compilation staleness
      status = TailwindCompiler.get_css_status("production_site")

      if status.compiled do
        age_hours = DateTime.diff(DateTime.utc_now(), status.updated_at, :hour)

        if age_hours > 24 do
          Logger.warning("CSS for \#{status.site} is \#{age_hours} hours old")
          TailwindCompiler.refresh_css(status.site)
        end
      else
        Logger.error("No CSS compiled for critical site: \#{status.site}")
        TailwindCompiler.compile_and_store(status.site)
      end

      # Health check endpoint
      defmodule HealthController do
        def css_health(conn, _params) do
          critical_sites = ["main", "blog", "shop"]

          statuses = Enum.map(critical_sites, &TailwindCompiler.get_css_status/1)
          all_compiled = Enum.all?(statuses, & &1.compiled)

          total_size = Enum.sum(Enum.map(statuses, & &1.css_size))

          health_data = %{
            status: if(all_compiled, do: "healthy", else: "degraded"),
            sites: statuses,
            total_css_size: total_size,
            checked_at: DateTime.utc_now()
          }

          json(conn, health_data)
        end
      end

  ## Monitoring Use Cases

  * **Admin Dashboards**: Display CSS compilation status across all sites
  * **Health Checks**: Verify critical site CSS is available
  * **Performance Monitoring**: Track CSS size and compilation frequency
  * **Alerting**: Trigger alerts for missing or stale CSS
  * **Analytics**: Gather metrics on CSS usage patterns
  """
  def get_css_status(site_name) do
    case AssetsState.get(site_name, "css") do
      {:ok, asset} ->
        %{
          site: site_name,
          compiled: true,
          updated_at: asset.updated_at,
          css_size: byte_size(asset.value)
        }

      {:error, :not_found} ->
        %{site: site_name, compiled: false, updated_at: nil, css_size: 0}
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################
  @doc """
  Where the compiled runtime templates and CSS live.

  Public because `MishkaCmsCore.Runtime.Compilers.CssClosure` walks the same tree.
  """
  @spec temp_dir() :: String.t()
  def temp_dir, do: get_temp_dir()

  defp get_temp_dir do
    # In production/release: uses the app's priv directory
    # In development: falls back to relative path
    case :code.priv_dir(@host_app) do
      {:error, _} -> Path.join(["priv", "static", "temp"])
      priv_dir -> Path.join([priv_dir, "static", "temp"])
    end
  end

  # Tailwind v4 only generates utility classes for selectors it actually
  # finds in the configured @source globs. The runtime CMS scans DB
  # templates and JS — but the host project also has hand-written
  # `.ex`/`.heex` files (LiveViews, controllers, layouts, components)
  # whose Tailwind classes would otherwise be invisible to the JIT.
  #
  # Resolve the project source tree from `File.cwd!/0` (where the
  # server was launched) and emit absolute @source globs for it. In a
  # release where `cwd` doesn't point at source, we silently emit
  # nothing — the precompiled CSS already accounts for those classes.
  @doc false
  # The globally-installed templates NO WALK CAN REACH: JS hooks and stylesheet rows.
  #
  # Global LAYOUTS, ERROR PAGES and COMPONENTS used to be here too, which is what made "global" mean
  # "in every site's stylesheet". It never should have: scope decides where a thing may be USED, and
  # a site's stylesheet is built from what that site renders. They are reached per site now, from
  # that site's own roots.
  defp global_unwalkable_sources do
    global = Path.join([get_temp_dir(), "runtime", "__global__"])

    Enum.map_join(@unwalkable_kinds, "\n", &~s|@source "#{Path.join(global, &1)}/**/*.template";|)
  end

  # The same kinds inside a site's own scope.
  defp site_unwalkable_sources(scopes) do
    runtime = Path.join(get_temp_dir(), "runtime")

    for scope <- scopes, kind <- @unwalkable_kinds do
      ~s|@source "#{Path.join([runtime, scope, kind])}/**/*.template";|
    end
    |> Enum.join("\n")
  end

  # ONE `@source` PER REACHABLE TEMPLATE, in whichever scope it lives — the site's pages and error
  # pages, the layouts those pages use, and the components they name transitively. A template that
  # names a component through an expression makes the walk unsound, and then everything is scanned
  # instead. Correct-and-large beats small-and-broken: an under-approximation means a component
  # renders with no CSS at all, in production.
  defp reachable_sources(closure, site_name, extra_scopes) do
    runtime = Path.join(get_temp_dir(), "runtime")

    case closure do
      :unbounded ->
        scopes = [site_name | extra_scopes] ++ ["__global__"]

        Enum.map_join(scopes, "\n", &~s|@source "#{Path.join(runtime, &1)}/**/*.template";|)

      %{templates: templates} ->
        Enum.map_join(templates, "\n", &~s|@source "#{&1}";|)
    end
  end

  @doc """
  The templates a visitor can reach on `site_name` — the roots of its CSS closure.

  A site's pages and error pages are roots because a visitor can ask for either by URL. Its LAYOUTS
  are not: a layout is chosen by a database relation rather than named in markup, so a site with
  thirty layout templates and five pages was scanning twenty-five it can never render, and every
  global layout sat in every site's stylesheet. The layouts this site's pages actually name are read
  from `pages.layout_id` and added here — which is also what makes editing a global layout a rebuild
  of the sites that use it rather than a fact about all of them.

  Read here rather than inside `MishkaCmsCore.Runtime.Compilers.CssClosure`, which walks a directory
  and deliberately knows nothing about the database. If the read fails the layouts fall back to the
  whole directory, on the same principle as `:unbounded` — correct-and-large, never small-and-broken.
  """
  @spec closure_roots(String.t(), keyword()) :: [String.t()]
  def closure_roots(site_name, opts \\ []) do
    runtime = Keyword.get_lazy(opts, :runtime_dir, fn -> Path.join(get_temp_dir(), "runtime") end)
    scopes = [site_name | Keyword.get(opts, :extra_scopes, [])]

    CssClosure.entry_templates(runtime, scopes) ++ layout_roots(site_name, runtime)
  end

  defp layout_roots(site_name, runtime) do
    case used_layouts(site_name) do
      {:ok, layouts} ->
        for {name, scope} <- layouts,
            path = Path.join([runtime, scope, "layout", "#{Slug.slugify(name)}.template"]),
            File.exists?(path),
            do: path

      :error ->
        Path.wildcard(Path.join([runtime, site_name, "layout", "**", "*.template"])) ++
          Path.wildcard(Path.join([runtime, "__global__", "layout", "**", "*.template"]))
    end
  end

  # `{layout name, scope directory}` for every layout an ACTIVE page of this site uses. A global
  # layout lives under `__global__`, a tenant one under the site's own name — the same rule
  # `BootHandler.create_template_file/4` writes by.
  defp used_layouts(site_name) do
    with {:ok, site} <- MishkaCmsCore.Runtime.States.SiteState.get_by_name(site_name),
         {:ok, ids} <- layout_ids_of_pages(site.id),
         {:ok, layouts} <- layouts_by_id(ids) do
      {:ok, Enum.map(layouts, &{&1.name, (&1.site && &1.site.name) || "__global__"})}
    else
      _unavailable -> :error
    end
  end

  defp layout_ids_of_pages(id) do
    MishkaCmsCore.Runtime.Page
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^id and active == true and not is_nil(layout_id))
    |> Ash.Query.select([:layout_id])
    |> Ash.read(authorize?: false, page: false)
    |> case do
      {:ok, pages} -> {:ok, pages |> Enum.map(& &1.layout_id) |> Enum.uniq()}
      {:error, _reason} -> :error
    end
  end

  defp layouts_by_id([]), do: {:ok, []}

  # PAGINATED BY THE ANSWER'S OWN SIZE. `Layout.read_any` does not declare `required?: false`, so
  # `page: false` is refused there — and one page cannot use more layouts than there are ids.
  defp layouts_by_id(ids) do
    MishkaCmsCore.Runtime.Layout
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:site)
    |> Ash.read(authorize?: false, page: [limit: length(ids)])
    |> case do
      {:ok, %{results: layouts}} -> {:ok, layouts}
      {:ok, layouts} when is_list(layouts) -> {:ok, layouts}
      {:error, _reason} -> :error
    end
  end

  # ONE WALK PER COMPILE, shared by the `@source` list and the icon sweep below — they are the same
  # question asked twice, and answering it reads every reachable template off disk.
  defp closure_for(site_name, extra_scopes \\ []) do
    runtime = Path.join(get_temp_dir(), "runtime")

    CssClosure.for_site(site_name,
      runtime_dir: runtime,
      extra_scopes: extra_scopes,
      roots: closure_roots(site_name, runtime_dir: runtime, extra_scopes: extra_scopes),
      content_components: content_components(site_name)
    )
  end

  @doc """
  The component names the stored content of the site `site_name` uses — what a template drawing
  that content reaches (`MishkaCmsCore.Runtime.Compilers.CssClosure`).

  Asked of whoever stores content through `runtime:compile:content_components`, with
  `%{site: name, site_id: id, components: []}`: a plugin adds the names its content uses to
  `components`. Read while a stylesheet is built, never in a request. `[]` for a site `SiteState`
  does not know.

      def call(%{site_id: site_id, components: names} = data),
        do: {:reply, %{data | components: names ++ names_my_posts_use(site_id)}}
  """
  @spec content_components(String.t()) :: [String.t()]
  def content_components(site_name) do
    with {:ok, %{id: site_id}} <- MishkaCmsCore.Runtime.States.SiteState.get_by_name(site_name),
         %{components: names} when is_list(names) <-
           MishkaInstaller.Event.Hook.call(
             "runtime:compile:content_components",
             %{site: site_name, site_id: site_id, components: []},
             meta: %{site: site_name}
           ) do
      names |> Enum.filter(&is_binary/1) |> Enum.uniq()
    else
      _nothing_named -> []
    end
  end

  @doc """
  Enqueues the stylesheet build of the site `site_id` names — its `"css"` job, on the per-site path
  that coalesces a burst of writes into one build. For a write that changed what the stylesheet is
  built from without a component, page or layout being written: content that names a component it
  did not name before.

  A switched-off or unknown site has nothing to build, and is `:ok`. So is every call under the
  `:env_test?` flag, as for every other runtime job.
  """
  @spec schedule(String.t()) :: :ok | {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(site_id) when is_binary(site_id) do
    case Application.get_env(:mishka_cms_core, :env_test?, false) do
      true -> :ok
      false -> enqueue(site_id)
    end
  end

  defp enqueue(site_id) do
    case MishkaCmsCore.Runtime.States.SiteState.get(site_id) do
      {:ok, %{active: true} = site} ->
        site.name
        |> MishkaCmsCore.Runtime.Handlers.BootHandler.asset_job(site.id, "css")
        |> Oban.insert()

      _nothing_to_build ->
        :ok
    end
  end

  # THE RUNTIME SHELL — the host code that renders AROUND a database page: the whole `components/`
  # tree and `RuntimeLive`. Nothing else.
  #
  # This used to be `lib/**` plus `__extensions/**`, guarded by "only in development" — which put the
  # whole admin dashboard and the host's marketing site into every site's stylesheet whenever the
  # precompiled base was absent, and did nothing at all when it was present. The guard also made the
  # dev watcher a lie: a class typed into a host LiveView produced no CSS until someone re-ran a mix
  # task by hand.
  #
  # THE DIRECTORY, not a list of files. Narrowing it to `layouts.ex` + `layouts/` + `runtime_live.ex`
  # looked exact and was wrong: `layouts.ex` renders `<.flash_group>`, which renders `<.flash>`, which
  # lives in `core_components.ex` — so every flash and both LiveView reconnect banners lost their
  # styling on every site page, rendering as unstyled text in normal flow across the top of the
  # document. A shell is defined by what it can transitively render, and hand-listing files means
  # re-deriving that closure by eye every time someone adds a component. `components/` is the whole
  # shell and holds nothing else; the marketing LiveViews live in `live/` and are served `public.css`.
  def host_app_web_sources do
    project_root = File.cwd!()

    [
      Path.join([project_root, "lib", "mishka_cms_web", "components"]),
      Path.join([project_root, "lib", "mishka_cms_web", "live", "runtime_live.ex"])
    ]
    |> Enum.filter(&(File.exists?(&1) or File.dir?(&1)))
    |> Enum.map_join("\n", fn path ->
      case File.dir?(path) do
        true -> ~s|@source "#{path}/**/*.{ex,heex,eex}";|
        false -> ~s|@source "#{path}";|
      end
    end)
  end

  @doc false
  # Absolute path of the compile-time static base artifact. Lives in the
  # shipped `priv/static/temp` dir so it travels with releases.
  def static_base_path, do: Path.join(get_temp_dir(), "static_base.css")

  @doc false
  # The precompiled runtime shell, prepended verbatim to shared-base output in releases. Not used in
  # development even when the file is present: there the sources are on disk and scanned live, so an
  # edit to a layout produces CSS immediately instead of waiting for someone to re-run a mix task.
  def static_base_prefix do
    case File.read(static_base_path()) do
      {:ok, css} -> "/* === precompiled static base (compile time) === */\n" <> css <> "\n"
      {:error, _} -> ""
    end
  end

  @doc """
  Compiles the **static base** CSS at compile/release time and writes it to
  `static_base_path/0`.

  Scans the RUNTIME SHELL — the layouts module, its templates and `RuntimeLive` — plus the JS assets
  and `app.css` (for `@theme` tokens), with Tailwind's own scanner. The result ships in the release
  and is prepended to every site's CSS at runtime, because a release has no `.ex` files to scan.

  Run from `mix mishka.compile_static_css` (wired into the release build).
  See the moduledoc "Static base" and "Theme tokens" sections.
  """
  def compile_static_base do
    ensure_installed()
    css = run_tailwind(build_css_content_static_base(), "static_base")
    path = static_base_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, css)
    {:ok, path}
  end

  @doc false
  # Public for testing. Builds the input CSS handed to the Tailwind binary
  # at compile time — pure string assembly, no binary invocation.
  def build_css_content_static_base do
    temp_dir = get_temp_dir()
    app_root = Application.app_dir(@host_app)

    app_css_path = Path.expand("priv/static/assets/css/app.css", app_root)

    app_css_content =
      case File.read(app_css_path) do
        {:ok, content} -> content
        {:error, _reason} -> ""
      end

    """
    @import "tailwindcss" source(none);

    /* STATIC BASE — the RUNTIME SHELL, scanned at compile time because a release ships no sources.
       The same three paths `host_app_web_sources/0` scans live in development, and nothing more:
       this artifact is prepended to every SITE's stylesheet, so anything else in it is weight a
       visitor to a database page downloads and cannot render. The admin ships `admin.css` and the
       host's marketing pages ship `public.css`; both are built by `mix admin_css`. */
    #{host_app_web_sources()}
    @source "#{temp_dir}/js_assets/js/**/*.js";
    @source "#{temp_dir}/js_assets/js/**/*.ts";

    #{tailwind_preamble()}

    [data-phx-session], [data-phx-teleported-src] { display: contents }

    /* app.css carries @theme tokens that static classes resolve against */
    #{app_css_content}
    """
  end

  # Read all globally-scoped (site_id IS NULL) Stylesheet rows and split
  # them into the two CSS-pipeline halves Tailwind v4 cares about:
  #
  #   pre_tailwind  → :app_base + :theme  (must precede class generation,
  #                   because @theme blocks define the color tokens
  #                   utilities like `bg-primary-light` resolve against)
  #
  #   post_tailwind → :base + :custom     (apply on top of generated
  #                   utilities; user overrides win the cascade)
  # Its duplicated just is for documenting and making understanding easy
  defp read_global_stylesheets, do: read_stylesheets_for(nil)

  defp read_site_stylesheets(site_name) do
    case site_id_for_name(site_name) do
      nil -> {"", ""}
      site_id -> read_stylesheets_for(site_id)
    end
  end

  defp read_stylesheets_for(site_id) do
    sheets =
      Stylesheet
      |> Ash.Query.for_read(:for_compiler, %{site_id: site_id}, authorize?: false)
      |> Ash.read!(authorize?: false)

    {pre, post} = Enum.split_with(sheets, fn s -> s.kind in [:app_base, :theme] end)

    {format_stylesheets(pre), format_stylesheets(post)}
  end

  defp format_stylesheets([]), do: ""

  defp format_stylesheets(sheets) do
    sheets
    |> Enum.sort_by(&Stylesheet.load_order/1)
    |> Enum.map_join("\n\n", fn s ->
      "/* Stylesheet##{s.id} kind=:#{s.kind} name=#{inspect(s.name)} */\n#{s.content}"
    end)
  end

  # Resolve site name → site_id via SiteState (cached at boot). Falls back
  # to nil if the name isn't known — caller treats that as "no site rows".
  defp site_id_for_name(site_name) when is_binary(site_name) do
    case MishkaCmsCore.Runtime.States.SiteState.get_by_name(site_name) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp site_id_for_name(_), do: nil

  # Which tailwind profile to run. The host defines it in its own config (the CMS calls it
  # `:mishka_cms_css`); a different host names its own. Mirrors `esbuild_profile/0` in
  # `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler`.
  defp tailwind_profile,
    do: Application.get_env(:mishka_cms_core, :tailwind_profile, :"#{@host_app}_css")

  # The heroicons Tailwind plugin is a HOST asset (`heroicons` is the host's dependency, and the
  # plugin file resolves the icon directory relative to itself). `@plugin` pointing at a file that is
  # not there aborts the whole run, so a host that does not use heroicons would get no CSS at all
  # rather than CSS without icon classes. Degrades the same way the `app.css` read does.
  # THE SITE'S OWN ICON SETS. `heroicons_plugin/0` covers one library because it is the one this CMS
  # ships, so a kit registering its own glyphs got them in the editor's picker and nowhere a visitor
  # could see — blank boxes on the published page, permanently.
  #
  # The names come from the components this site actually reaches, which is the same closure the
  # stylesheet is already built from: an icon belonging to a component no page renders has no more
  # claim on the bundle than the component itself.
  defp icon_css(closure, site_name) do
    closure
    |> icon_scan_paths(site_name)
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, source} -> MishkaCmsCore.Runtime.PageBuilder.Icons.classes_in(source)
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
    |> MishkaCmsCore.Runtime.PageBuilder.Icons.css()
  end

  # SCOPED TO THIS SITE even when the walk gave up: `runtime/*/component/*` matched every OTHER
  # site's component directory too, so one site's icons rode into another's stylesheet.
  defp icon_scan_paths(:unbounded, site_name) do
    runtime = Path.join(get_temp_dir(), "runtime")

    Path.wildcard(Path.join([runtime, site_name, "**", "*.template"])) ++
      Path.wildcard(Path.join([runtime, "__global__", "**", "*.template"]))
  end

  defp icon_scan_paths(%{templates: templates}, _site_name), do: templates

  # THE SAME VOCABULARY IN EVERY COMPILE, because a template that leaves part of it out does not
  # compile the CSS the others do. `hero-bell` is a class this CMS ships — a `@plugin` defines it —
  # and `phx-submit-loading:` is a variant its own templates use, so the check that was missing both
  # refused, in Tailwind's voice, utilities every real compile resolves. It was the fourth hand-copy
  # of this block; there is one now.
  defp tailwind_preamble do
    """
    #{heroicons_plugin()}

    @custom-variant phx-click-loading (.phx-click-loading&, .phx-click-loading &);
    @custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
    @custom-variant phx-change-loading (.phx-change-loading&, .phx-change-loading &);

    /* Use the data attribute for dark mode */
    @custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *));
    """
  end

  defp heroicons_plugin do
    path =
      Path.expand(
        "priv/static/temp/js_assets/vendor/heroicons.js",
        Application.app_dir(@host_app)
      )

    if File.exists?(path) do
      ~s|@plugin "#{path}";|
    else
      Logger.debug("[TailwindCompiler] no heroicons plugin at #{path}; skipping icon classes")
      ""
    end
  end

  defp run_tailwind(input_content, identifier) do
    case ran_tailwind(input_content, identifier) do
      {0, css, _output} ->
        css

      {status, _css, output} ->
        raise "Tailwind compilation failed (#{identifier}, exit code #{status}): " <>
                tailwind_message(output)
    end
  end

  # ONE RUNNER, and it KEEPS WHAT THE BINARY SAID. `Tailwind.run/2` streams the output to this
  # process's stdio and hands back an exit code, which is enough to know a compile failed and not
  # enough to say why — and "why" is the name of the utility that broke it, which is the whole
  # value of `verify_css/2` and of the raise above. Running the binary directly keeps it: the same
  # `stderr_to_stdout` + `uncoloured/1` pair `ran/1` uses, and for the same reason — the binary
  # paints its own output whatever `NO_COLOR` asks.
  defp ran_tailwind(input_content, identifier) do
    timestamp = :os.system_time(:nanosecond)
    input_css_path = Path.join(System.tmp_dir!(), "tw_in_#{identifier}_#{timestamp}.css")
    output_css_path = Path.join(System.tmp_dir!(), "tw_out_#{identifier}_#{timestamp}.css")
    config = Tailwind.config_for!(tailwind_profile())

    File.write!(input_css_path, input_content)

    try do
      args =
        (config[:args] || []) ++
          ["--input=#{input_css_path}", "--output=#{output_css_path}", "--minify"]

      case System.cmd(Tailwind.bin_path(), args,
             cd: config[:cd] || File.cwd!(),
             stderr_to_stdout: true,
             env: [{"NO_COLOR", "1"}, {"BROWSERSLIST_IGNORE_OLD_DATA", "1"}]
           ) do
        {output, 0} -> {0, File.read!(output_css_path), uncoloured(output)}
        {output, status} -> {status, "", uncoloured(output)}
      end
    after
      File.rm(input_css_path)
      File.rm(output_css_path)
    end
  end

  # The static base used to be the whole host app plus every extension — the admin dashboard, the
  # Gervaz table library, the marketing site — 514 KB prepended to every site's stylesheet that a
  # visitor to a database page could never render. It is the RUNTIME SHELL now (see
  # `build_css_content_static_base/0`), and it is prepended only where the shell cannot be scanned
  # live: a release ships no `.ex` sources, so there the precompiled artifact is the only copy.
  defp execute_tailwind_shared_base do
    prefix = if host_app_web_sources() == "", do: static_base_prefix(), else: ""

    prefix <> run_tailwind(build_css_content_shared_base(), "shared_base")
  end

  defp execute_tailwind_site_only(site_name) do
    run_tailwind(build_css_content_site_only(site_name), site_name)
  end

  defp build_css_content_shared_base do
    temp_dir = get_temp_dir()
    app_root = Application.app_dir(@host_app)

    app_css_path = Path.expand("priv/static/assets/css/app.css", app_root)

    app_css_content =
      case File.read(app_css_path) do
        {:ok, content} ->
          Logger.debug(
            "[TailwindCompiler] Shared base: reading app.css, size: #{byte_size(content)} bytes"
          )

          content

        {:error, _reason} ->
          ""
      end

    {pre_tailwind, post_tailwind} = read_global_stylesheets()

    """
    /* === pre-Tailwind: kit themes (@theme blocks must precede class generation) === */
    #{pre_tailwind}

    @import "tailwindcss" source(none);

    /* SHARED BASE - Scanned ONCE for all sites: the globally-installed JS hooks and stylesheet
       rows, which are the only global templates no walk can reach. The globally-installed LAYOUTS,
       ERROR PAGES and COMPONENTS are NOT here: being global says where a thing may be used, never
       that every site pays for it, so each site scans the ones it reaches in
       `build_css_content_site_only/1`. */
    #{global_unwalkable_sources()}

    /* Scan JS/TS assets - same for all sites */
    @source "#{temp_dir}/js_assets/js/**/*.js";
    @source "#{temp_dir}/js_assets/js/**/*.ts";

    /* Scan host app web layer (LiveViews, controllers, components) so
       Tailwind picks up classes used in the parent project's `.ex/.heex`
       templates — not just the runtime DB-stored components. */
    #{host_app_web_sources()}

    /* Add plugins and custom variants */
    #{tailwind_preamble()}

    /* Make LiveView wrapper divs transparent for layout */
    [data-phx-session], [data-phx-teleported-src] { display: contents }

    /* App CSS content directly embedded */
    #{app_css_content}

    /* === post-Tailwind: global :base layers + :custom overrides === */
    #{post_tailwind}
    """
  end

  # Global :theme/:app_base tokens (e.g. the Chelekom `chelekom-theme`
  # row, site_id == nil) MUST be present in this compile too. Site-scoped
  # components scanned below use those tokens (`bg-primary-light` resolves
  # `--color-primary-light`); without the tokens in THIS Tailwind run the
  # utilities aren't generated, so site components render uncolored.
  # Global theme first so a site :theme row can still override it.
  defp build_css_content_site_only(site_name) do
    closure = closure_for(site_name)

    {global_pre, _global_post} = read_global_stylesheets()
    {site_pre, post_tailwind} = read_site_stylesheets(site_name)

    """
    #{global_pre}
    #{site_pre}

    @import "tailwindcss/theme.css" layer(theme);
    @import "tailwindcss/utilities.css" layer(utilities) source(none);

    /* SITE-SPECIFIC: #{site_name} */
    #{site_unwalkable_sources([site_name])}

    /* EVERY TEMPLATE THIS SITE CAN REACH, and nothing else: its pages and error pages, the layouts
       those pages use, and the components they name transitively — in whichever scope each lives.
       The directory globs this replaced charged every visitor for every layout the site had ever
       had and every component of every installed kit, to render the handful it renders. */
    #{reachable_sources(closure, site_name, [])}

    /* Plugin needed for icon classes in site templates */
    #{tailwind_preamble()}
    #{icon_css(closure, site_name)}

    /* === post-Tailwind: site :base + :custom rows === */
    #{post_tailwind}
    """
  end
end
