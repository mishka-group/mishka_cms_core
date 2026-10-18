# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.ErrorCompiler do
  @moduledoc """
  Runtime compiler for Error Page modules with dynamic content compilation.

  This module provides functionality to dynamically compile error page modules at runtime
  from configuration data. It generates complete error handling modules with custom layouts,
  templates, and helper functions for different HTTP error status codes.

  ## Features

  - Dynamic error page module generation from configuration
  - Custom error page templates for different HTTP status codes
  - Flexible layout system with root layout and per-status layouts
  - Helper function integration for custom error page logic
  - Automatic CSS and JavaScript injection for styled error pages
  - Fallback error handling for unhandled status codes
  - Site-specific error page configurations

  ## Error Page Structure

  Generated error page modules include:
  - `__error_information__/0` - Returns error page metadata
  - `__error_information__/1` - Returns specific metadata by key
  - `render/2` - Main rendering function for each status code
  - `layout/2` - Layout function for each status code
  - `root_layout/1` - Root HTML layout wrapper
  - Helper functions (if defined)

  ## Usage

      params = %{
        title: "My Site Errors",
        error_module: MyApp.Errors.SiteErrors,
        site: "main",
        site_id: 1,
        error_pages: [
          %{
            status: 404,
            template: ~S(<h1>Page Not Found</h1><p>The page you're looking for doesn't exist.</p>),
            layout: %{template: ~S(<div class="error-layout"><%= @inner_content %></div>)}
          },
          %{
            status: 500,
            template: ~S(<h1>Server Error</h1><p>Something went wrong on our end.</p>)
          }
        ],
        root_layout_template: ~S(
          <!DOCTYPE html>
          <html>
            <head><title>Error <%= @status %></title></head>
            <body><%= @inner_content %></body>
          </html>
        ),
        helpers: [
          %{
            name: "format_error_message",
            args: "status, message",
            code: ~S("Error " <> Integer.to_string(status) <> ": " <> message)
          }
        ]
      }

      ast = ErrorCompiler.build_module(params)
      MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

  ## Layout Hierarchy

  The error page rendering follows this hierarchy:
  1. **Root Layout** - Outer HTML document structure
  2. **Status Layout** - Per-status layout wrapper (optional)
  3. **Error Template** - The actual error content

  ## Error Page Configuration

  Each error page in the `:error_pages` list should contain:
  - `:status` - HTTP status code, or `:offline` for the page an offline site shows (required) —
    see `MishkaCmsCore.Runtime.ErrorStatus`
  - `:template` - Error content template (required)
  - `:layout` - Optional layout wrapper with `:template` key
  """

  # Compiled modules are built on the host's web entrypoint when it names one, so runtime templates
  # can reach its components and routes. See `MishkaCmsCore.Runtime.CompiledPageBase`.
  @web_module MishkaCmsCore.Runtime.Compilers.Shared.web_module()

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.ErrorStatus

  require Logger

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Main function to build error page modules from error page data.

  Takes error page configuration parameters and returns a complete AST for an error handling module.
  The function orchestrates the entire compilation process through a pipeline of transformations.

  ## Parameters

  - `params` - Map containing error page configuration with keys:
    - `:title` - Error page title/name (required)
    - `:error_module` - Target module name (required)
    - `:site` - Site identifier (required)
    - `:site_id` - Site ID for database reference
    - `:error_pages` - List of error page definitions (required)
    - `:root_layout_template` - Root HTML layout template (optional)
    - `:helpers` - List of helper function definitions (optional)
    - `:host` - Host information for multi-tenant setups
    - `:extra` - Additional metadata

  ## Error Page Structure

  Each error page in `:error_pages` should contain:
  - `:status` - HTTP status code (integer)
  - `:template` - Error content template string
  - `:layout` - Optional layout map with `:template` key

  ## Returns

  Returns the complete AST for the error module that can be compiled using
  `MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module/1`.

  ## Example

      params = %{
        title: "Site Error Pages",
        error_module: MyApp.SiteErrors,
        site: "production",
        error_pages: [
          %{status: 404, template: "<h1>Not Found</h1>"},
          %{status: 500, template: "<h1>Server Error</h1>"}
        ]
      }

      ast = build_module(params)
  """
  def build_module(params) do
    MishkaInstaller.Event.Hook.call("runtime:compile:before_error_page", params,
      meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
      return: false
    )

    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :error],
      %{name: params[:title] || params["title"], site: params[:site] || params["site"]},
      fn ->
        atomized_params = MishkaCmsCore.Runtime.Helpers.atomize_keys(params)

        result =
          atomized_params
          |> build_error_information()
          |> build_layout_functions()
          |> build_render_functions()
          |> build_helpers()
          |> create_module_ast()

        MishkaInstaller.Event.Hook.call("runtime:compile:after_error_page", params,
          meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
          return: false
        )

        {result, %{}}
      end
    )
  end

  @doc """
  Build error page information including metadata.

  Creates AST for the `__error_information__` functions that provide access to error page
  metadata, private information, and extra data. These functions are used by the runtime
  system to introspect error page properties.

  ## Parameters

  - `params` - Atomized error page parameters map

  ## Returns

  Returns a tuple `{params, functions_ast}` where `functions_ast` contains the AST for:
  - `__error_information__/0` - Returns complete metadata map
  - `__error_information__/1` - Returns metadata by atom key or key path
  - `__error_information__/1` - Returns metadata by string dot-notation path

  ## Metadata Structure

  The metadata includes:
  - `:error` - Public error page info (title, path, error_pages, timestamp)
  - `:private` - Private runtime info (id, error_module, priority, site details)
  - `:extra` - Additional custom metadata
  """
  def build_error_information(params) do
    error_info_ast =
      quote do
        def __error_information__ do
          %{
            error: %{
              title: unquote(params[:title]),
              path: unquote(params[:path]),
              error_pages: unquote(Macro.escape(params[:error_pages] || [])),
              timestamp: unquote(Macro.escape(params[:timestamp]))
            },
            private: %{
              id: unquote(params[:id]),
              error_module: unquote(params[:error_module]),
              priority: unquote(params[:priority] || 0),
              site: unquote(params[:site]),
              site_id: unquote(params[:site_id]),
              host: unquote(params[:host]),
              format: unquote(params[:format]) || :heex
            },
            extra: unquote(Macro.escape(params[:extra]))
          }
        end

        def __error_information__(key) when is_atom(key) do
          get_in(__error_information__(), [key])
        end

        def __error_information__(keys) when is_list(keys) do
          get_in(__error_information__(), keys)
        end

        def __error_information__(key) when is_binary(key) do
          String.split(key, ".")
          |> Enum.map(&String.to_existing_atom/1)
          |> then(&get_in(__error_information__(), &1))
        rescue
          _ -> nil
        end
      end

    {params, [error_info_ast]}
  end

  @doc """
  Build layout functions for error pages.

  Generates layout functions for each error page status code. Layout functions provide
  an intermediate rendering layer between the error template and the root layout.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with layout functions added for each status code.

  ## Generated Functions

  For each error page, generates a `layout/2` function that:
  - Takes a status code and assigns map as parameters
  - Returns the rendered layout template (if provided)
  - Falls back to returning inner_content directly if no layout template

  ## Layout Behavior

  - **With layout template**: Renders the template with inner_content available
  - **Without layout template**: Returns the inner_content as-is for direct rendering
  """
  def build_layout_functions({params, functions_ast}) do
    layout_functions_ast =
      Enum.map(params[:error_pages] || [], fn error_page ->
        build_layout_function(error_page, params[:site])
      end)

    {params, functions_ast ++ layout_functions_ast}
  end

  @doc """
  Build render functions for error pages.

  Generates the main rendering functions for each error page status code and a catch-all
  fallback function. These functions are the primary entry points for error page rendering.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with render functions added for each status code plus a catch-all function.

  ## Generated Functions

  For each error page, generates a `render/2` function that:
  1. Takes a connection and status code as parameters
  2. Creates assigns with conn, status, and inner_content
  3. Calls the appropriate layout function for the status
  4. Wraps the result in the root layout

  ## Catch-All Function

  Adds a fallback `render/2` function that:
  - Handles any unhandled status codes
  - Logs a warning about the missing error page
  - Returns a plain text status phrase using `Plug.Conn.Status.reason_phrase/1`

  ## Rendering Flow

  1. `render/2` called with conn and status
  2. Error template compiled and rendered
  3. Layout template applied (if configured)
  4. Root layout wraps the final result
  """
  def build_render_functions({params, functions_ast}) do
    render_functions_ast =
      Enum.map(params[:error_pages] || [], fn error_page ->
        build_render_function(error_page, params[:site])
      end)

    # Add catch-all render function
    catch_all_render_ast =
      quote do
        def render(var!(conn), var!(status)) do
          _ = var!(conn)
          require Logger

          Logger.warning(
            "missing error page for #{unquote(params[:site])} status #{var!(status)}"
          )

          Plug.Conn.Status.reason_phrase(var!(status))
        end
      end

    {params, functions_ast ++ render_functions_ast ++ [catch_all_render_ast]}
  end

  @doc """
  Build helper functions for the error pages.

  Processes helper function definitions and creates corresponding function AST, plus
  generates the root layout function for the complete HTML document structure.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and accumulated AST functions

  ## Returns

  Returns updated tuple with helper functions and root layout function added to the AST.

  ## Helper Functions

  Each helper function definition should contain:
  - `:name` - Function name as string
  - `:args` - Function arguments as Elixir code string
  - `:code` - Function body as Elixir code string

  ## Root Layout Function

  Generates a `root_layout/1` function that provides the outer HTML document structure:

  ### Custom Root Layout
  If `:root_layout_template` is provided, compiles it as the root layout.

  ### Default Root Layout
  If no custom template provided, generates a default HTML document with:
  - Proper DOCTYPE and HTML structure
  - Error status in page title
  - CSRF token meta tag
  - Viewport meta tag for responsive design
  - Automatic CSS injection from TailwindCompiler (if site configured)
  - Automatic JavaScript injection from JavaScriptCompiler (if site configured)
  - Body containing the inner content

  ## Template Compilation

  All templates are compiled using Phoenix.HTML.Engine for proper HTML generation
  and security (XSS protection, HTML escaping, etc.).
  """
  def build_helpers({params, functions_ast}) do
    helpers_ast =
      Enum.map(params[:helpers] || [], fn helper ->
        args = LiveViewCompiler.helper_args(helper.args)

        quote do
          def unquote(String.to_atom(helper.name))(unquote_splicing(args)) do
            unquote(Code.string_to_quoted!(helper.code))
          end
        end
      end)

    # Add root layout function if template provided
    root_layout_ast =
      if params[:root_layout_template] do
        compiled_root = compile_template(params[:root_layout_template], params[:site])

        quote do
          def root_layout(var!(assigns)) when is_map(var!(assigns)) do
            unquote(compiled_root)
          end
        end
      else
        quote do
          def root_layout(var!(assigns)) when is_map(var!(assigns)) do
            ~H"""
            <!DOCTYPE html>
            <html lang="en">
              <head>
                <title>
                  {MishkaCmsCore.Runtime.Compilers.ErrorCompiler.fallback_title(@status)}
                </title>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
                <%!-- LINKED, not inlined. A 404 is the response a site serves most often and cares
                     about least — every dead link, every stale bookmark, every crawler — and
                     inlining put the site's entire stylesheet in each one, uncached. The same bytes
                     are already at a content-addressed URL the visitor almost certainly has in
                     cache, because they got here from a page on this site. Inlining is kept only as
                     the fallback for a site that has never compiled, where a link would 404 inside
                     an error page. --%>
                <% css_href =
                  @conn.assigns[:current_site] &&
                    MishkaCmsCore.Runtime.Compilers.Shared.site_css_href(@conn.assigns.current_site.name) %>
                <% js_href =
                  @conn.assigns[:current_site] &&
                    MishkaCmsCore.Runtime.Compilers.Shared.site_js_href(@conn.assigns.current_site.name) %>
                <link :if={css_href} rel="stylesheet" href={css_href} />
                <style
                  :if={@conn.assigns[:current_site] && !css_href}
                  nonce={@conn.assigns[:csp_nonce]}
                >
                  <%= raw(MishkaCmsCore.Runtime.Compilers.TailwindCompiler.get_compiled_css(@conn.assigns.current_site.name)) %>
                </style>
                <script :if={js_href} defer src={js_href}>
                </script>
                <script :if={@conn.assigns[:current_site] && !js_href}>
                  <%= raw(MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.get_compiled_js(@conn.assigns.current_site.name)) %>
                </script>
              </head>
              <body>
                {@inner_content}
              </body>
            </html>
            """
          end
        end
      end

    {params, functions_ast ++ helpers_ast ++ [root_layout_ast]}
  end

  @doc """
  Create the final module AST.

  Assembles all error page components into a complete error handling module AST.
  The generated module includes all necessary imports and uses for proper Phoenix integration.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing params and all accumulated function ASTs

  ## Returns

  Returns the complete module AST ready for compilation via `ModuleCompiler.compile_module/1`.

  ## Generated Module Structure

  The final module includes:
  - `defmodule` declaration with the target error module name
  - Required imports (`Logger`)
  - LiveView integration via the configured `:web_module`
  - Runtime component helper imports
  - All accumulated function definitions (info, layout, render, helpers, root layout)

  The module is fully self-contained and ready for runtime compilation and loading
  into the Phoenix error handling system.
  """
  def create_module_ast({params, functions_ast}) do
    quote do
      defmodule unquote(params[:error_module]) do
        require Logger
        use unquote(@web_module), :live_view

        import MishkaCmsCore.Runtime.LiveViewHelpers,
          only:
            unquote(
              Keyword.take(MishkaCmsCore.Runtime.LiveViewHelpers.imports(params[:helpers]), [
                :component,
                :csp_nonce,
                :site_path
              ])
            )

        unquote_splicing(functions_ast)
      end
    end
  end

  @doc """
  The `<title>` of an error page whose site set no root layout, in the language of the request.
  """
  @spec fallback_title(ErrorStatus.t()) :: String.t()
  def fallback_title(:offline), do: gettext("Down for maintenance")
  def fallback_title(status), do: gettext("Error %{status}", status: status)

  @doc """
  Whether the compiled Error Page `module` holds an `:offline` entry, however its status was stored.
  """
  @spec offline_entry?(module()) :: boolean()
  def offline_entry?(module) do
    [:error, :error_pages]
    |> module.__error_information__()
    |> List.wrap()
    |> ErrorStatus.offline_entry?()
  end

  @doc """
  The compiled Error Page `module`'s page for `status`, drawn for `conn`, as HTML.

  The template is handed `@status`, and `@conn` with `:page_module` and `:page_data` assigned.
  """
  @spec render_page(module(), Plug.Conn.t(), ErrorStatus.t()) :: iodata()
  def render_page(module, conn, status) do
    conn
    |> Plug.Conn.assign(:page_module, module)
    |> Plug.Conn.assign(:page_data, module.__error_information__())
    |> module.render(status)
    |> Phoenix.HTML.Safe.to_iodata()
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  # Build layout function for a specific error page status.
  #
  # Creates a layout/2 function that handles the intermediate rendering layer
  # between the error template and the root layout.
  #
  # ## Parameters
  #
  # - `error_page` - Error page configuration map with :status and optional :layout
  # - `site` - Site identifier for template compilation context
  #
  # ## Returns
  #
  # Returns AST for a `layout/2` function that pattern matches on the status code.
  #
  # ## Layout Behavior
  #
  # - If layout template provided: Compiles and renders the template
  # - If no layout template: Returns inner_content directly from assigns
  # WRITTEN ONE WAY, READ THE OTHER. `layout` is a bare `:map` inside the `error_pages` constraint,
  # so Ash leaves its inner keys exactly as they were stored — and a form stores strings. Matching
  # `%{template: template}` therefore never matched anything the editor wrote: an author could fill
  # the layout in, save it, and the wrapper was silently ignored. Read by either spelling, and only
  # when there is something to compile.
  defp layout_template(error_page) do
    case Map.get(error_page, :layout) do
      %{} = layout -> Map.get(layout, "template") || Map.get(layout, :template)
      _no_layout -> nil
    end
  end

  defp build_layout_function(error_page, site) do
    status = entry_status(error_page)

    case layout_template(error_page) do
      template when is_binary(template) and template != "" ->
        compiled_template = compile_heex_template(template, site)

        quote do
          def layout(unquote(status), var!(assigns)) when is_map(var!(assigns)) do
            unquote(compiled_template)
          end
        end

      _ ->
        # No layout function for this status - will use inner_content directly
        quote do
          def layout(unquote(status), var!(assigns)) when is_map(var!(assigns)) do
            Map.get(var!(assigns), :inner_content, "")
          end
        end
    end
  end

  # Build render function for a specific error page status.
  #
  # Creates the main render/2 function for a specific HTTP status code.
  # This function orchestrates the complete error page rendering flow.
  #
  # ## Parameters
  #
  # - `error_page` - Error page configuration map with :status and :template
  # - `site` - Site identifier for template compilation context
  #
  # ## Returns
  #
  # Returns AST for a `render/2` function that:
  # 1. Pattern matches on the specific status code
  # 2. Compiles the error template
  # 3. Creates assigns with conn, status, and inner_content
  # 4. Applies layout function
  # 5. Wraps result in root_layout
  #
  # ## Rendering Process
  #
  # render/2 -> layout/2 -> root_layout/1 -> final HTML
  defp build_render_function(error_page, site) do
    %{template: template} = error_page
    status = entry_status(error_page)
    compiled_template = compile_heex_template(template, site)

    quote do
      def render(var!(conn), unquote(status)) do
        # `assigns` is bound BEFORE the inner template renders so a HEEx `<.component site={@site} />`
        # (and any `@status`/`@conn`) resolves; `__changed__`/`socket` let the TagEngine output render
        # outside a live socket (error pages are served by a controller, not a LiveView).
        var!(assigns) = %{
          conn: var!(conn),
          status: unquote(status),
          site: unquote(site),
          __changed__: %{},
          socket: %Phoenix.LiveView.Socket{}
        }

        inner = unquote(compiled_template)
        wrapped = layout(unquote(status), Map.put(var!(assigns), :inner_content, inner))
        root_layout(Map.put(var!(assigns), :inner_content, wrapped))
      end
    end
  end

  # The status an entry's clauses match on: a code, or `:offline` however it was spelled.
  defp entry_status(%{status: status}), do: ErrorStatus.parse(status) || status

  # Compile template string into executable AST.
  #
  # Uses Phoenix.HTML.Engine to compile template strings into proper AST
  # with security features and HTML escaping.
  #
  # ## Parameters
  #
  # - `template` - Template string to compile
  # - `site` - Site identifier for unique file naming in compilation
  #
  # ## Returns
  #
  # Returns compiled template AST ready for execution.
  #
  # ## Compilation Options
  #
  # - Uses Phoenix.HTML.Engine for proper HTML generation
  # - Includes proper file naming for debugging
  # - Sets up import context via make_env/0
  # - Enables template trimming for clean output
  defp compile_template(template, site) do
    opts = [
      engine: Phoenix.HTML.Engine,
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_error_template_#{site}",
      caller: make_env(),
      source: template,
      trim: true
    ]

    EEx.compile_string(template, opts)
  end

  # Compile a per-status error template (or per-status layout) with the HEEx `TagEngine` — the same
  # engine pages use — so `<.component name="..." site={@site} />` and `phx-*` hooks resolve and run.
  # The root layout stays on the classic `compile_template/2` above because it relies on EEx
  # interpolation inside attributes (`content="<%= ... %>"`), which HEEx rejects.
  defp compile_heex_template(template, site) do
    opts = [
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_error_template_#{site}",
      caller: make_env(),
      trim: true,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    template
    |> MishkaCmsCore.Runtime.PageBuilder.Visibility.strip()
    |> Phoenix.LiveView.TagEngine.compile(opts)
  end

  @doc """
  Create environment for template compilation.

  Builds a compilation environment with necessary imports for template processing.
  Ensures that Phoenix HTML, Component, and LiveView helpers are available during
  template compilation.

  ## Returns

  Returns a `Macro.Env` struct with all required imports defined for proper template compilation.

  ## Imported Modules

  - `Phoenix.HTML` - HTML generation helpers and security functions
  - `Phoenix.Component` - Component helpers and sigil_H support

  Failed imports are logged but don't stop the compilation process, ensuring robustness
  even when some modules aren't available.

  ## Error Handling

  If any module fails to import, the error is logged as a warning and compilation continues
  with the remaining successfully imported modules.
  """
  def make_env do
    imports = [
      Phoenix.HTML,
      Phoenix.Component,
      Phoenix.LiveView.Helpers
    ]

    Enum.reduce(imports, __ENV__, fn module, env ->
      with true <- :erlang.module_loaded(module),
           {:ok, env} <- define_import(env, module) do
        env
      else
        {:error, error} ->
          require Logger
          Logger.warning("failed to import #{module}: #{error}")
          env

        _ ->
          env
      end
    end)
  end

  # Define import in the compilation environment.
  #
  # Safely imports a module into the given environment for template compilation.
  # Used by make_env/0 to set up the necessary imports.
  #
  # ## Parameters
  #
  # - `env` - The Macro.Env to import into
  # - `module` - The module to import
  #
  # ## Returns
  #
  # Returns `{:ok, updated_env}` on success or `{:error, reason}` on failure.
  defp define_import(env, module),
    do: MishkaCmsCore.Runtime.Compilers.Shared.define_import(env, module)
end
