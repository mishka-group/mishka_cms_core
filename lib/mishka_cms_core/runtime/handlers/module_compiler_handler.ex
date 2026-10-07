defmodule MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler do
  @moduledoc """
  Dynamic module compiler handler for MishkaCms runtime components with concurrent compilation management.

  The `ModuleCompilerHandler` provides a sophisticated system for compiling Phoenix LiveView modules,
  components, layouts, and error pages on-demand. It manages concurrent compilation processes,
  prevents duplicate work, and ensures efficient resource utilization through partitioned dynamic
  supervision and registry-based process coordination.

  ## Features

  * **Concurrent Compilation Management**: Prevents duplicate compilation work using process registry
  * **Dynamic Supervision**: Distributes compilation work across partitioned supervisors for scalability
  * **Module Type Detection**: Automatically detects and compiles different module types (Page, Component, Layout, Error)
  * **Timeout Management**: Provides configurable timeouts to prevent hanging compilation processes
  * **Database Integration**: Seamlessly integrates with Ash-based data layer for content retrieval
  * **Compiler Abstraction**: Uses specialized compilers for different content types
  * **Process Lifecycle Management**: Handles temporary workers with automatic cleanup

  ## Architecture Overview

  The handler operates within a distributed architecture:

  ```
  ModuleCompilerHandler (Temporary GenServer)
  ├── Registry-based Process Coordination
  ├── Partitioned Dynamic Supervision
  ├── Type-specific Compilers
  │   ├── LiveViewCompiler (Pages)
  │   ├── ComponentCompiler (Components)
  │   ├── LayoutCompiler (Layouts)
  │   └── ErrorCompiler (Error Pages)
  └── ModuleCompiler (AST → Runtime Module)
  ```

  ## Compilation Process Flow

  1. **Request Handling**: Receives compilation request with module name and metadata
  2. **Registry Check**: Verifies if compilation is already in progress
  3. **Process Spawning**: Creates temporary GenServer worker if needed
  4. **Database Query**: Retrieves content data based on module type and path
  5. **AST Generation**: Uses type-specific compiler to generate Abstract Syntax Tree
  6. **Module Compilation**: Compiles AST into runtime Elixir module
  7. **Cleanup**: Automatically terminates worker after completion

  ## Basic Usage

      # Compile or return existing module
      case ModuleCompilerHandler.compile_or_return_module(
        MyApp.Generated.Page123,
        "/blog/article",
        "my_site",
        site_id
      ) do
        {:ok, module} ->
          # Module is compiled and ready to use
          {:ok, _pid} = DynamicSupervisor.start_child(
            MyApp.PageSupervisor,
            {Phoenix.LiveView, module}
          )

        {:error, reason} ->
          Logger.error("Compilation failed: \#{inspect(reason)}")
      end

  ## Production Considerations

  * **Memory Management**: Compiled modules remain in memory until explicitly purged
  * **Concurrency**: Uses all available CPU cores through partitioned supervision
  * **Timeout Configuration**: Default 1-minute timeout prevents hanging processes
  * **Process Cleanup**: Temporary workers automatically terminate after compilation
  * **Registry Overhead**: Minimal overhead for process coordination and deduplication
  * **Database Load**: Each compilation triggers database queries for content retrieval

  ## Module Type Support

  The handler supports compilation for:
  * **Pages**: Phoenix LiveView pages with full interactivity
  * **Components**: Reusable UI components with attributes and slots
  * **Layouts**: Page layouts with resource links and SEO metadata
  * **Error Pages**: Custom error handling pages with fallback layouts
  """
  use GenServer
  require Logger

  alias MishkaCmsCore.Runtime.Compilers.{
    LiveViewCompiler,
    UndefinedModuleError,
    ModuleCompiler,
    ErrorCompiler,
    ComponentCompiler,
    LayoutCompiler,
    UserClosure,
    Helpers
  }

  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState}
  alias MishkaCmsCore.Runtime.Handlers.CompileGate

  @timeout :timer.minutes(1)
  @registry MishkaCms.ModuleCompilerHandlerRegistry
  ####################################################################################
  ########################### (▰˘◡˘▰) Client API (▰˘◡˘▰) #############################
  ####################################################################################
  @doc """
  Generates child specification for temporary compilation workers.

  This function creates a child specification used by DynamicSupervisor to spawn
  temporary GenServer workers for module compilation. Each worker is configured
  with a unique identifier based on module name and site to prevent conflicts.

  ## Parameters

  * `{module_name, path, site, site_id, type}` - Tuple containing:
    * `module_name` - Atom representing the target module name, or `{module_name, record}` when
      the record is already in hand (boot)
    * `path` - String path or identifier for content lookup
    * `site` - String site name for multi-tenant support
    * `site_id` - Site identifier for database queries
    * `type` - `:new` or `:update`, as `compile_or_return_module/5` takes it

  ## Return Value

  Returns a child specification map with:
  * `id` - Unique identifier combining module name and site
  * `start` - Start function tuple for GenServer initialization
  * `restart` - `:temporary` for automatic cleanup after completion
  * `type` - `:worker` process type
  """
  def child_spec({module_name_and_item, path, site, site_id, type}) do
    %{
      id: {__MODULE__, get_module_name(module_name_and_item), site},
      start: {__MODULE__, :start_link, [{module_name_and_item, path, site, site_id, type}]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Starts the worker that compiles one module, registered under the module's name.

  It is registered from the moment it starts — while it still waits for a `CompileGate` slot — so
  every caller that asks for the module meanwhile finds it and waits for its answer instead of
  compiling the module again. It compiles at once, without being asked, and stops when it is done;
  the reason it stops with carries its answer (see `compile_or_return_module/5`).

  ## Return Values

  * `{:ok, pid}` - Successfully started GenServer worker
  * `{:error, {:already_started, pid}}` - Worker already exists for this module
  * `{:error, reason}` - Failed to start worker
  """
  def start_link({module_name_and_item, _path, _site, _site_id, _type} = args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {@registry, get_module_name(module_name_and_item)}}
    )
  end

  @doc """
  Compiles a module or returns existing compiled module with intelligent coordination.

  This is the primary entry point for module compilation. It implements sophisticated
  coordination logic to prevent duplicate compilation work while ensuring modules
  are available when needed. The function handles both new compilation and updates
  with different strategies based on module state and compilation type.

  ## Parameters

  * `module_name` - Atom representing the target module name
  * `path` - String path or identifier used for content database lookup
  * `site` - String site name for multi-tenant content isolation
  * `site_id` - Integer site identifier for database queries
  * `type` - Compilation type (defaults to `:new`):
    * `:new` - Skip compilation if module already loaded
    * `:update` - Force recompilation even if module exists

  ## Return Values

  * `{:ok, module_name}` - Module compiled successfully or already available
  * `{:error, :not_found}` - Content not found in database
  * `{:error, :compilation_error}` - Compilation failed due to syntax/logic errors
  * `{:error, :compilation_timeout}` - Compilation exceeded timeout limit
  * `{:error, reason}` - Other compilation failures

  ## Coordination Strategy

  A module is compiled once however many callers ask for it at the same time:

  1. **Module Existence Check**: For `:new` type, returns immediately if module loaded
  2. **Registry Lookup**: A worker already registered for the module — compiling, or still waiting
     for a `CompileGate` slot — is waited for, and its answer is this caller's too
  3. **One Worker**: Otherwise one is started; it registers before it waits for a slot, so callers
     after this one wait for it rather than queue at the gate for the same module
  4. **One Message**: The worker's exit carries its answer, so every caller waiting on it is
     answered the moment it ends, whether or not the caller that started it is still there

  Waiting takes no gate slot: the slots are only ever held by compiles, so the pages of other sites
  keep compiling while many callers wait for one page.

  An `:update` takes the answer of a compile that began after it was asked for. One already running
  may have read the record before it changed, so it is waited out and the next one started, and the
  callers that waited together share that one compile rather than each compiling in turn.
  """
  def compile_or_return_module(module_name, path, site, site_id, type \\ :new)
      when type in [:new, :update] do
    :telemetry.span(
      [:mishka_cms, :runtime, :handlers, :module_compiler],
      %{module_name: module_name, path: path, site: site, site_id: site_id, type: type},
      fn ->
        result =
          cond do
            Helpers.loaded?(module_name) and type == :new ->
              {:ok, module_name}

            # Known-broken module: skip the worker + compile entirely (pure ETS lookup).
            type == :new and CompileFailureState.failed?(module_name) ->
              {:error, CompileFailureState.reason(module_name)}

            true ->
              case compile(module_name, path, site, site_id, type) do
                {:started, result} -> tap(result, &maybe_emit_compiled(&1, site_id))
                {:waited, result} -> result
              end
          end

        {result, %{}}
      end
    )
  end

  @doc """
  Resolves a module's compile outcome from already-recorded shared state — the loaded-code table
  plus `CompileFailureState` — without contacting the compiling worker process.

  Used when the worker a caller waited for ended without handing over its answer — it was gone
  before the caller could watch it, or it was killed. A worker records its outcome before it ends,
  so a caller reads it here instead. Loaded module → `{:ok, module}`; otherwise the recorded failure
  reason, or `:compilation_error` when the worker died before recording one.

  ## Examples

      # a module the winner already compiled/loaded
      compiled_result(MyApp.Runtime.SomePage)
      #=> {:ok, MyApp.Runtime.SomePage}

      # never loaded and no recorded failure
      compiled_result(MyApp.Runtime.NeverCompiled)
      #=> {:error, :compilation_error}
  """
  @spec compiled_result(module()) :: {:ok, module()} | {:error, term()}
  def compiled_result(module) do
    if Helpers.loaded?(module) do
      {:ok, module}
    else
      {:error, CompileFailureState.reason(module) || :compilation_error}
    end
  end

  @doc """
  Classifies an exception raised while building/compiling a runtime module as either a cacheable
  compile failure or a transient (retryable) infrastructure error.

  Genuine template errors (`SyntaxError`, HEEx token errors, `CompileError`, …) become
  `{:compilation_error, message}` and are cached in `CompileFailureState` so the hot path skips
  the broken module. Database/pool blips (`DBConnection.ConnectionError`, `Postgrex.Error`)
  become `:compile_transient`, which is NEVER cached — the next request retries instead of being
  permanently served a 500. Everything else is treated as a compile error so an unknown template
  failure still gets cached (fail-safe).

  ## Examples

      classify_compile_error(%DBConnection.ConnectionError{message: "pool timeout"})
      #=> :compile_transient

      classify_compile_error(%RuntimeError{message: "unclosed tag"})
      #=> {:compilation_error, "unclosed tag"}
  """
  @spec classify_compile_error(Exception.t()) ::
          :compile_transient | {:compilation_error, String.t()}
  def classify_compile_error(%DBConnection.ConnectionError{}), do: :compile_transient
  def classify_compile_error(%Postgrex.Error{}), do: :compile_transient

  def classify_compile_error(error) when is_exception(error),
    do: {:compilation_error, Exception.message(error)}

  # A lazy (request-time) compile has no Oban job, so emit telemetry the runtime status
  # panel + activity feed can pick up (see Activity.Sources.RuntimeCompile). Worker (Oban)
  # compiles are already captured by Oban telemetry, so RuntimeCompilerWorker marks its
  # process via `:runtime_compile_via_oban` and we skip the emit to avoid a duplicate.
  defp maybe_emit_compiled({:ok, module}, site_id) do
    if !Process.get(:runtime_compile_via_oban) do
      :telemetry.execute(
        [:mishka_cms, :runtime, :compiler, :compiled],
        %{count: 1},
        %{module: module, site_id: site_id}
      )
    end

    :ok
  end

  defp maybe_emit_compiled(_result, _site_id), do: :ok

  # ONE COMPILE PER MODULE, HOWEVER MANY ASK FOR IT. See "Coordination Strategy" in
  # `compile_or_return_module/5`. `{:started, result}` for the caller whose worker compiled it,
  # `{:waited, result}` for every other.
  defp compile(module_and_item, path, site, site_id, type) do
    case Registry.lookup(@registry, get_module_name(module_and_item)) do
      [{pid, _}] -> joined(await(pid), module_and_item, path, site, site_id, type)
      [] -> start(module_and_item, path, site, site_id, type)
    end
  end

  defp joined(outcome, module_and_item, _path, _site, _site_id, :new),
    do: {:waited, answer(outcome, get_module_name(module_and_item), :new)}

  # The worker that was running when the update was asked for may have read the record before it
  # changed, so the update needs the next one.
  defp joined(_outcome, module_and_item, path, site, site_id, :update),
    do: start(module_and_item, path, site, site_id, :update)

  defp start(module_and_item, path, site, site_id, type) do
    module = get_module_name(module_and_item)

    get_dynamic_supervisor_key()
    |> DynamicSupervisor.start_child(child_spec({module_and_item, path, site, site_id, type}))
    |> case do
      {:ok, pid} ->
        result = pid |> await() |> answer(module, type)
        check_offline_page(result)
        {:started, result}

      # Started since this caller looked, so it began after this was asked for: its answer is ours.
      {:error, {:already_started, pid}} ->
        {:waited, pid |> await() |> answer(module, type)}

      {:error, reason} ->
        {:started, {:error, reason}}
    end
  end

  # No timeout here: the worker waits for its slot as long as the gate makes it, and once it has one
  # it ends within `@timeout` (see `in_time/1`), so it always ends and every waiter is answered.
  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:shutdown, {:compiled, result}}} -> {:compiled, result}
      {:DOWN, ^ref, :process, ^pid, _no_answer} -> :lost
    end
  end

  # A WORKER THAT ENDED WITHOUT AN ANSWER: the module as the worker left it for a new page; for an
  # update, a transient error, since the compile it needed may not have happened.
  defp answer({:compiled, result}, _module, _type), do: result
  defp answer(:lost, module, :new), do: compiled_result(module)
  defp answer(:lost, _module, :update), do: {:error, :compile_transient}

  # AN OFFLINE PAGE THAT CANNOT BE DRAWN IS KNOWN BEFORE A VISITOR ASKS FOR IT. An Error Page's root
  # layout and helpers are shared by all its entries, and only the `:offline` one hands them `@status`
  # as an atom, so a page whose 404 draws can still raise on it. `MishkaCms.Plugs.MaintenanceGate`
  # draws that page inside a plug, where a raise is a bare 500 on every request. So it is drawn once
  # here, as a visitor gets it, and a failure is kept in `CompileFailureState` under
  # `{module, :offline}`: `MishkaCmsWeb.ErrorHTML.offline_page/1` reads it and hands the visitor the
  # built-in page instead. The module stays loaded, so its 404 and 500 still work.
  #
  # By the caller that started the compile, once its worker has ended and given back its slot: the
  # page may name a component that is not built yet, and building it takes a slot of its own.
  defp check_offline_page({:ok, module}) do
    cond do
      not function_exported?(module, :__error_information__, 1) -> :ok
      not ErrorCompiler.offline_entry?(module) -> CompileFailureState.clear({module, :offline})
      true -> module |> draw_offline_page() |> offline_page_drawn(module)
    end
  end

  defp check_offline_page(_not_compiled), do: :ok

  # The compile-time boundary a drawn page may raise at, as `handle_call(:compile, ...)` is for
  # building it.
  defp draw_offline_page(module) do
    _page = ErrorCompiler.render_page(module, visitor_conn(module), :offline)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, "#{kind}: #{inspect(value)}"}
  end

  defp offline_page_drawn(:ok, module), do: CompileFailureState.clear({module, :offline})

  defp offline_page_drawn({:error, reason}, module) do
    CompileFailureState.record({module, :offline}, reason)
    site = module.__error_information__([:private, :site])

    MishkaInstaller.Event.Hook.call(
      "runtime:compile:offline_page_failed",
      %{module: module, site: site, reason: reason},
      meta: %{module: module, site: site},
      return: false
    )

    :ok
  end

  # A signed-out visitor's request to the site the page belongs to, answered with a 503.
  defp visitor_conn(module) do
    %{site: name, site_id: site_id, host: host} = module.__error_information__(:private)

    site =
      case SiteState.get_by_name(name) do
        {:ok, cached} -> cached
        _not_cached -> %{id: site_id, name: name, host: host}
      end

    %Plug.Conn{status: 503, assigns: %{current_site: site, current_user: nil}}
  end

  # A LIVE COMPONENT WITH THE WRONG ROOT IS A COMPILE FAILURE, NOT A VISITOR'S CRASH.
  #
  # `Phoenix.LiveView.Diff.component_to_rendered/3` raises "Stateful components must have a single
  # static HTML tag at the root" inside whichever LiveView renders it — and there is nothing in
  # front of that on a published page. The compile itself succeeds, so nothing is recorded and the
  # NEXT request dies the same way rather than short-circuiting to a placeholder.
  #
  # `%Rendered{}.root` is false for a conditional root, two sibling tags, leading text or a bare
  # expression — none of which looks wrong, and none of which the canvas can show, because the
  # canvas calls `render/1` as a plain function and never consults `root`. So the module is rendered
  # once here, where the answer can still be turned into something the author reads.
  #
  # Only a stateful component is asked: `ComponentCompiler.check_root/1` answers `:ok` for every
  # other shape, so nothing about the 141 changes.
  defp rooted(module) do
    case ComponentCompiler.check_root(module) do
      :ok -> {:ok, module}
      {:error, why} -> {:error, {:compilation_error, why}}
    end
  end

  # Cache only genuine compile failures so the hot path can skip them; a clean compile
  # clears the entry, and `:not_found`/timeout stay uncached (transient / retryable).
  defp record_compile_result({:ok, _module}, module) do
    CompileFailureState.clear(module)

    MishkaInstaller.Event.Hook.call("runtime:after_module_compile", %{module: module},
      return: false
    )

    :ok
  end

  defp record_compile_result({:error, :compilation_error}, module),
    do: CompileFailureState.record(module, :compilation_error)

  defp record_compile_result({:error, {:compilation_error, _} = reason}, module),
    do: CompileFailureState.record(module, reason)

  defp record_compile_result(_other, _module), do: :ok

  ####################################################################################
  ########################### (▰˘◡˘▰) Server API (▰˘◡˘▰) #############################
  ####################################################################################
  def init({module_name_and_item, path, site, site_id, type}) do
    Logger.info("Starting compiler for module: #{get_module_name(module_name_and_item)}")

    {:ok,
     %{
       module_name_and_item: module_name_and_item,
       path: path,
       site: site,
       site_id: site_id,
       type: type
     }, {:continue, :compile}}
  end

  # THE WORKER ANSWERS EVERY CALLER AT ONCE, BY ENDING. The reason it stops with carries the result,
  # and every caller waiting for the module is watching for that exit. The outcome is recorded first,
  # so a request that comes after finds the module loaded or its failure known.
  #
  # A new page is looked for once more here: a caller can find no worker an instant after the last
  # one loaded the module, and here, where only one worker per module can be, that is caught.
  def handle_continue(:compile, state) do
    module_name = get_module_name(state.module_name_and_item)

    result =
      if state.type == :new and Helpers.loaded?(module_name) do
        {:ok, module_name}
      else
        result = CompileGate.run(fn -> in_time(state) end)
        record_compile_result(result, module_name)
        result
      end

    Logger.info("Work completed for module: #{module_name}, terminating...")
    {:stop, {:shutdown, {:compiled, result}}, state}
  end

  # A COMPILE THAT HANGS GIVES ITS SLOT BACK AFTER `@timeout`. It runs in a task so the worker, which
  # holds the slot, can stop it: a compile running in the worker's own process could not be stopped.
  defp in_time(state) do
    task = Task.async(fn -> build(state) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _too_late ->
        Logger.warning(
          "Timeout reached for module: #{get_module_name(state.module_name_and_item)} after #{@timeout}ms, terminating..."
        )

        {:error, :compilation_timeout}
    end
  end

  defp build(state) do
    UndefinedModuleError.enable(state.site_id)

    module_name_and_item =
      case state.module_name_and_item do
        {module_name, item} -> {Atom.to_string(module_name), item}
        module_name -> Atom.to_string(module_name)
      end

    # Compiling user-authored HEEx can RAISE (SyntaxError/TokenMissingError) during
    # AST-build — there's no non-raising template-compile API — so this is the one
    # compile-time boundary that catches it and answers `{:error, _}` instead of
    # crashing the worker (which would take down boot / every lazy request).
    try do
      with {:ok, ast} <- get_data_from_database_to_ast({module_name_and_item, state}),
           {:ok, module, _diagnostics} <- ModuleCompiler.compile_module(ast) do
        rooted(module)
      else
        {:error, _ash_error} -> {:error, :not_found}
        {:error, _module, {_error, _diagnostics}} -> {:error, :compilation_error}
      end
    rescue
      error -> {:error, classify_compile_error(error)}
    catch
      :exit, {:timeout, _} -> {:error, :compile_transient}
      kind, value -> {:error, {:compilation_error, "#{kind}: #{inspect(value)}"}}
    end
  end

  def terminate(reason, state) do
    module_name = get_module_name(state.module_name_and_item)
    Logger.debug("Terminating compiler for module: #{module_name}, reason: #{inspect(reason)}")
    :ok
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################
  def get_data_from_database_to_ast(
        {{<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>>, page},
         _state}
      )
      when type == "Page" do
    {:ok, LiveViewCompiler.build_module(page_params(page, page.page_module))}
  end

  def get_data_from_database_to_ast(
        {<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>> =
           module_name, state}
      )
      when type == "Page" do
    :telemetry.span(
      [:mishka_cms, :runtime, :handlers, :database_to_ast, :page],
      %{type: type, path: state.path, site: state.site, site_id: state.site_id},
      fn ->
        result =
          MishkaCmsCore.Runtime.get_page_by_path(state.path,
            tenant: state.site_id,
            load: [:page_module, :loaded_layout, :site],
            authorize?: false,
            not_found_error?: true
          )
          |> case do
            {:ok, page} ->
              get_data_from_database_to_ast({{module_name, page}, state})

            {:error, ash_error} ->
              :telemetry.execute(
                [:mishka_cms, :runtime, :handlers, :database_to_ast, :page, :error],
                %{count: 1},
                %{path: state.path, site: state.site, site_id: state.site_id, error: ash_error}
              )

              {:error, ash_error}
          end

        {result, %{}}
      end
    )
  end

  def get_data_from_database_to_ast(
        {{<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>>, err},
         _state}
      )
      when type == "ErrorPage" do
    params = %{
      id: err.id,
      error_module: err.error_module,
      site: err.site && err.site.name,
      site_id: err.site && err.site.id,
      host: err.site && err.site.host,
      title: err.name,
      path: err.path,
      priority: err.priority,
      format: err.format,
      timestamp: err.updated_at,
      error_pages: err.error_pages,
      helpers: err.helpers,
      root_layout_template: err.root_layout_template,
      extra: err.extra
    }

    {:ok, ErrorCompiler.build_module(params)}
  end

  def get_data_from_database_to_ast(
        {<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>> =
           module_name, state}
      )
      when type == "ErrorPage" do
    :telemetry.span(
      [:mishka_cms, :runtime, :handlers, :database_to_ast, :error],
      %{type: type, path: state.path, site: state.site, site_id: state.site_id},
      fn ->
        result =
          MishkaCmsCore.Runtime.get_error_by_path(state.path,
            tenant: state.site_id,
            load: [:error_module, :site],
            authorize?: false,
            not_found_error?: true
          )
          |> case do
            {:ok, err} ->
              get_data_from_database_to_ast({{module_name, err}, state})

            {:error, ash_error} ->
              :telemetry.execute(
                [:mishka_cms, :runtime, :handlers, :database_to_ast, :error, :error],
                %{count: 1},
                %{path: state.path, site: state.site, site_id: state.site_id, error: ash_error}
              )

              {:error, ash_error}
          end

        {result, %{}}
      end
    )
  end

  def get_data_from_database_to_ast(
        {{<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>>,
          component}, _state}
      )
      when type == "Component" do
    extra = component.extra || %{}

    params = %{
      id: component.id,
      title: component.name,
      component_module: component.component_module,
      site: component.site && component.site.name,
      site_id: component.site && component.site.id,
      host: component.site && component.site.host,
      template: component.template,
      priority: component.priority,
      format: component.format,
      timestamp: component.updated_at,
      attrs: component.attrs,
      slots: component.slots,
      helpers: component.helpers,
      permissions: component.permissions,
      body: component.body,
      # WHICH SHAPE TO EMIT. `== true` rather than the value, because a row read before the column
      # existed answers `nil` and a lazily-compiled stale module must take the old path.
      stateful: component.stateful == true,
      extra: extra,
      prelude: extra["prelude"] || extra[:prelude],
      module_attributes: extra["module_attributes"] || extra[:module_attributes] || [],
      clauses: extra["clauses"] || extra[:clauses] || []
    }

    {:ok, ComponentCompiler.build_module(params)}
  end

  def get_data_from_database_to_ast(
        {<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>> =
           module_name, state}
      )
      when type == "Component" do
    :telemetry.span(
      [:mishka_cms, :runtime, :handlers, :database_to_ast, :component],
      %{type: type, path: state.path, site: state.site, site_id: state.site_id},
      fn ->
        # state.path is the name of component and state.site_id can be nil for global component.
        #
        # `active` is filtered HERE rather than in the action, because the action is the general way
        # to look a component up by name and the admin has every reason to read an inactive one.
        # This is the compile path, and here a component an operator switched off must not be built
        # — a lazy component is built by the first render that names it, so without this filter a
        # deactivated one would come back to life at the next request for it.
        result =
          MishkaCmsCore.Runtime.get_component_by_name(state.path,
            tenant: state.site_id,
            query: [filter: [active: true]],
            load: [:component_module, :site],
            authorize?: false,
            not_found_error?: true
          )
          |> case do
            {:ok, component} ->
              get_data_from_database_to_ast({{module_name, component}, state})

            {:error, ash_error} ->
              :telemetry.execute(
                [:mishka_cms, :runtime, :handlers, :database_to_ast, :component, :error],
                %{count: 1},
                %{path: state.path, site: state.site, site_id: state.site_id, error: ash_error}
              )

              {:error, ash_error}
          end

        {result, %{}}
      end
    )
  end

  def get_data_from_database_to_ast(
        {{<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>>, layout},
         _state}
      )
      when type == "Layout" do
    {:ok, LayoutCompiler.build_module(layout_params(layout, layout.layout_module))}
  end

  def get_data_from_database_to_ast(
        {<<"Elixir.MishkaCmsCore.Runtime.", _hash::binary-size(32), ".", type::binary>> =
           module_name, state}
      )
      when type == "Layout" do
    :telemetry.span(
      [:mishka_cms, :runtime, :handlers, :database_to_ast, :layout],
      %{type: type, path: state.path, site: state.site, site_id: state.site_id},
      fn ->
        result =
          MishkaCmsCore.Runtime.get_layout_by_path(state.path,
            tenant: state.site_id,
            load: [:layout_module, :site],
            authorize?: false,
            not_found_error?: true
          )
          |> case do
            {:ok, layout} ->
              get_data_from_database_to_ast({{module_name, layout}, state})

            {:error, ash_error} ->
              :telemetry.execute(
                [:mishka_cms, :runtime, :handlers, :database_to_ast, :layout, :error],
                %{count: 1},
                %{path: state.path, site: state.site, site_id: state.site_id, error: ash_error}
              )

              {:error, ash_error}
          end

        {result, %{}}
      end
    )
  end

  def get_data_from_database_to_ast({module, state}) do
    :telemetry.execute(
      [:mishka_cms, :runtime, :handlers, :database_to_ast, :unknown_type, :error],
      %{count: 1},
      %{module: module, path: state.path, site: state.site, site_id: state.site_id}
    )

    {:error, :not_found}
  end

  @doc """
  What `LiveViewCompiler.build_module/1` compiles `page` from, as `page_module`.

  `page` is a `MishkaCmsCore.Runtime.Page` loaded with `:site` and `:loaded_layout`, or a
  `MishkaCmsCore.Runtime.PageDraft` loaded with `:site` and `layout: [:site]`.
  """
  def page_params(page, page_module) do
    layout = page_layout(page)
    layout_site_name = layout && ((layout.site && layout.site.name) || "Global")

    %{
      id: page.id,
      page_module: page_module,
      # WHAT THE PAGE IS CALLED, NOT THE KEY IT IS FILED UNDER. This reaches `<title>` through
      # `MishkaCmsWeb.RuntimeLive.assign_page_title/1`, and `name` is the slugified identifier — a
      # Persian page's tab read `qymtgdhry` where its title says `قیمت‌گذاری`.
      title: page.title,
      path: page.path,
      section: page.section,
      # WHICH LANGUAGE, AND WHICH OTHER EDITIONS. `MishkaCmsWeb.RuntimeLive` reads both back for
      # `<html lang dir>` and the page's alternates — see `MishkaCmsCore.Runtime.PageEditions`.
      language: page.language,
      language_group_id: page.language_group_id,
      timestamp: page.updated_at,
      content: page.content,
      # The page's meta description — see `MishkaCmsCore.Runtime.Seo`.
      description: page.description,
      seo_tags: page.seo_tags,
      schema: page.schema,
      layout: layout && {layout_site_name, layout.path},
      # WHETHER ANYTHING ABOVE THE PAGE ALREADY SHOWS MESSAGES, answered here because this is the
      # only place the layout RECORD is in hand — the compiler is given its site and path and
      # nothing else, and looking the row up again would be a query per page compile to re-derive
      # what is already loaded. See `LiveViewCompiler.confirmable/3`.
      layout_says?: LiveViewCompiler.shows_messages?(layout),
      # WHETHER SERVING THIS PAGE HAS TO LOAD THE SIGNED-IN USER, so that a public page which never
      # mentions a visitor costs a signed-in one nothing. `MishkaCmsWeb.RuntimeLive` reads the answer
      # back off the compiled module.
      #
      # THE LAYOUT IS NOT ASKED HERE, although it is in hand a line above — a layout edit rebuilds
      # the layout module and no page under it, so a page carrying an answer about its layout would
      # go on saying nobody is signed in for the life of the node. The layout answers for itself,
      # into its own module, and `RuntimeLive` puts the two together. See
      # `MishkaCmsCore.Runtime.Compilers.UserClosure`.
      reads_user: UserClosure.reads_user?(page),
      priority: page.priority,
      site: page.site && page.site.name,
      site_id: page.site && page.site.id,
      host: page.site && page.site.host,
      format: page.format,
      template_name: "#{page.id}-#{page.name}",
      template: page.template,
      events: page.events,
      infos: page.infos,
      state: Map.get(page, :state),
      helpers: page.helpers,
      uploads: Map.get(page, :uploads),
      # WHO MAY OPEN THE PAGE, which `MishkaCmsWeb.RuntimeLive` reads back from the compiled module
      # on every mount and live navigation. A page compiled without it is public whatever its row
      # says.
      permissions: page.permissions,
      extra: page.extra
    }
  end

  defp page_layout(%{loaded_layout: %{} = layout}), do: layout
  defp page_layout(%{layout: %MishkaCmsCore.Runtime.Layout{} = layout}), do: layout
  defp page_layout(_page), do: nil

  @doc """
  What `LayoutCompiler.build_module/1` compiles `layout` from, as `layout_module`.

  `layout` is a `MishkaCmsCore.Runtime.Layout` or a `MishkaCmsCore.Runtime.LayoutDraft`, loaded
  with `:site`.
  """
  def layout_params(layout, layout_module) do
    %{
      id: layout.id,
      title: layout.name,
      path: layout.path,
      timestamp: layout.updated_at,
      content: layout.content,
      resource_links: layout.resource_links,
      seo_tags: layout.seo_tags,
      layout_module: layout_module,
      priority: layout.priority,
      site: layout.site && layout.site.name,
      site_id: layout.site && layout.site.id,
      host: layout.site && layout.site.host,
      format: layout.format,
      permissions: layout.permissions,
      extra: layout.extra,
      helpers: layout.helpers,
      template: layout.template,
      template_name: "#{layout.id}-#{layout.name}",
      # WHETHER A PAGE DRAWN INSIDE THIS LAYOUT HAS TO LOAD THE SIGNED-IN USER. The layout is
      # rendered with the LiveView's own assigns, so its markup reads `@current_user` exactly as a
      # page's does — and this is the module that is rebuilt when the layout is edited, which is why
      # the answer lives here rather than in the pages. See
      # `MishkaCmsCore.Runtime.Compilers.UserClosure`.
      reads_user: UserClosure.reads_user?(layout)
    }
  end

  @doc """
  Returns the number of partitions used for dynamic supervision.

  This function provides the partition count used by the PartitionSupervisor
  to distribute compilation workers. The count is based on the number of
  available CPU schedulers, ensuring optimal resource utilization.

  ## Return Value

  * `integer()` - Number of partitions (equal to CPU scheduler count)

  ## Examples

      # Get partition count
      count = ModuleCompilerHandler.partition_count()
      # Returns: 8 (on an 8-core system)

      # Use for load balancing decisions
      partition_load = total_workers / ModuleCompilerHandler.partition_count()

      if partition_load > 10 do
        Logger.warning("High compilation load detected")
      end

  ## Performance Implications

  The partition count directly affects:
  * **Concurrency**: Higher count enables more parallel compilations
  * **Resource Distribution**: Workers spread across CPU cores
  * **Memory Usage**: Each partition maintains separate worker pools
  * **Scheduling Efficiency**: Aligned with Erlang VM scheduler count

  ## Monitoring Integration

      # Track partition utilization
      defmodule PartitionMonitor do
        def check_load_balance do
          partition_count = ModuleCompilerHandler.partition_count()
          health_stats = ModuleCompilerHandler.partition_health_stats()

          max_workers = Enum.max_by(health_stats, & &1.workers).workers
          min_workers = Enum.min_by(health_stats, & &1.workers).workers

          imbalance_ratio = max_workers / max(min_workers, 1)

          if imbalance_ratio > 2.0 do
            Logger.warning("Partition load imbalance detected: \#{imbalance_ratio}")
          end
        end
      end
  """
  def partition_count() do
    System.schedulers_online()
  end

  @doc """
  Selects a dynamic supervisor partition for load distribution.

  This function implements round-robin load balancing across partitioned
  dynamic supervisors to distribute compilation workers evenly. It uses
  an atomic counter to ensure thread-safe partition selection.

  ## Return Value

  * `{:via, PartitionSupervisor, {supervisor_name, partition_number}}` -
    Supervisor reference for worker spawning

  ## Load Balancing Strategy

  Uses atomic counter-based round-robin:
  1. Increments global atomic counter
  2. Maps counter value to partition number
  3. Returns supervisor reference for selected partition

  ## Examples

      # Get supervisor for worker spawning
      supervisor = ModuleCompilerHandler.get_dynamic_supervisor_key()

      # Start child worker
      {:ok, pid} = DynamicSupervisor.start_child(
        supervisor,
        child_spec({module, path, site, site_id})
      )

      # Automatic load balancing across calls
      supervisors = for _ <- 1..10 do
        ModuleCompilerHandler.get_dynamic_supervisor_key()
      end
      # Returns different partitions in round-robin fashion

  ## Concurrency Safety

      # Thread-safe counter operations
      # Multiple processes can call simultaneously without coordination
      tasks = for i <- 1..100 do
        Task.async(fn ->
          ModuleCompilerHandler.get_dynamic_supervisor_key()
        end)
      end

      # Each task gets a properly balanced supervisor reference
      supervisor_refs = Task.await_many(tasks)

  ## Performance Characteristics

  * **Atomic Operations**: O(1) counter increment with minimal contention
  * **Memory Usage**: Single atomic counter shared across all processes
  * **Distribution**: Even spread across available partitions
  * **Scalability**: Efficient with high concurrent access

  ## Partition Health Impact

      # Load distribution affects partition health
      defmodule LoadTracker do
        def track_supervisor_usage do
          # Sample supervisor selection over time
          selections = for _ <- 1..1000 do
            ModuleCompilerHandler.get_dynamic_supervisor_key()
          end

          # Count selections per partition
          partition_counts = Enum.frequencies(selections)

          # Verify even distribution
          target_count = 1000 / ModuleCompilerHandler.partition_count()

          Enum.each(partition_counts, fn {partition, count} ->
            deviation = abs(count - target_count) / target_count

            if deviation > 0.1 do
              Logger.warning("Partition \#{partition} load deviation: \#{deviation}")
            end
          end)
        end
      end

  ## Integration with Worker Lifecycle

      defp start_and_compile(module_name, path, site, site_id) do
        # Get balanced supervisor for this worker
        supervisor = get_dynamic_supervisor_key()

        # Supervisor selection affects resource distribution
        case DynamicSupervisor.start_child(
          supervisor,
          child_spec({module_name, path, site, site_id})
        ) do
          {:ok, pid} -> handle_worker_success(pid)
          {:error, reason} -> handle_worker_failure(reason)
        end
      end
  """
  def get_dynamic_supervisor_key() do
    counter_ref = :persistent_term.get(:module_compiler_partition_counter)
    counter = :atomics.add_get(counter_ref, 1, 1)

    {:via, PartitionSupervisor,
     {MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandlerPartition, counter}}
  end

  @doc """
  Retrieves health statistics for all dynamic supervisor partitions.

  This function provides comprehensive health metrics for each partition
  in the dynamic supervisor pool, enabling monitoring, debugging, and
  load balancing decisions. It queries each partition's child count
  and status information.

  ## Return Value

  Returns a list of maps, one per partition, with the following keys:
  * `active` - Total number of active processes
  * `specs` - Number of child specifications
  * `supervisors` - Number of supervisor children
  * `workers` - Number of worker processes

  ## Examples

      # Get current health stats
      stats = ModuleCompilerHandler.partition_health_stats()
      # Returns: [
      #   %{active: 3, specs: 3, supervisors: 0, workers: 3},
      #   %{active: 1, specs: 1, supervisors: 0, workers: 1},
      #   %{active: 0, specs: 0, supervisors: 0, workers: 0},
      #   %{active: 2, specs: 2, supervisors: 0, workers: 2}
      # ]

      # Calculate total workers across all partitions
      total_workers = stats
        |> Enum.map(& &1.workers)
        |> Enum.sum()

      IO.puts("Total compilation workers: \#{total_workers}")
  """
  def partition_health_stats() do
    for partition <- 0..(System.schedulers_online() - 1) do
      pid =
        GenServer.whereis(
          {:via, PartitionSupervisor,
           {MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandlerPartition, partition}}
        )

      DynamicSupervisor.count_children(pid)
    end
  end

  @doc """
  **This is helper function to boot compile or return module, do not use it directly!!**
  """
  def boot_compile_or_return_module({module_name, _item} = module_and_item, path, site, site_id) do
    if Helpers.loaded?(module_name) do
      {:ok, module_name}
    else
      {_started_or_waited, result} = compile(module_and_item, path, site, site_id, :new)
      result
    end
  end

  defp get_module_name(module_name_and_item) do
    case module_name_and_item do
      {module_name, _item} -> module_name
      module_name -> module_name
    end
  end
end
