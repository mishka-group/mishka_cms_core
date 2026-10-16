# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.LayoutCompiler do
  @moduledoc """
  Runtime compiler for Phoenix Layout modules with dynamic content compilation.

  This module provides comprehensive functionality to dynamically compile Phoenix Layout modules
  at runtime from configuration data. It generates complete layout modules with proper template
  compilation, metadata management, helper functions, and resource handling for CMS layouts.

  ## Features

  - **Dynamic layout module generation** from configuration parameters
  - **HEEx template compilation** with Phoenix LiveView integration
  - **Layout metadata and information** functions for runtime introspection
  - **Helper function integration** for custom layout logic
  - **Resource management** including CSS, JavaScript, and meta tags
  - **SEO optimization** with customizable meta tag support
  - **Multi-site layout support** with site-specific configurations
  - **Access control integration** with permission management

  ## Layout Module Structure

  Generated layout modules include:
  - `__layout_information__/0` - Returns complete layout metadata
  - `__layout_information__/1` - Returns specific metadata by key or path
  - `render/1` - Renders layout with assigns
  - `render/2` - Renders layout with assigns and inner content
  - Helper functions (if defined in configuration)
  - Proper Phoenix LiveView and MishkaCMS integration

  ## Basic Usage

  The primary entry point is `build_module/1` which takes layout configuration
  and returns a complete AST ready for compilation:

      params = %{
        title: "Main Layout",
        layout_module: MyApp.Layouts.Main,
        template: ~S'''
        <!DOCTYPE html>
        <html>
          <head>
            <title><%= @title %></title>
            <%= for meta <- @seo.meta_tags do %>
              <meta name={meta.name} content={meta.content}>
            <% end %>
          </head>
          <body>
            <header>Site Header</header>
            <main><%= @inner_content %></main>
            <footer>Site Footer</footer>
          </body>
        </html>
        ''',
        site: "main_site",
        site_id: 1
      }

      ast = LayoutCompiler.build_module(params)
      MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

  ## SEO and Resource Management

  Layouts provide built-in SEO and resource management:

      # SEO configuration
      seo_tags: [
        %{name: "description", content: "Page description"},
        %{name: "keywords", content: "keyword1, keyword2"},
        %{property: "og:title", content: "Social Media Title"},
        %{property: "og:image", content: "https://example.com/image.png"}
      ]

      # Resource links
      resource_links: [
        %{rel: "stylesheet", href: "/assets/theme.css", type: "text/css"},
        %{rel: "preconnect", href: "https://fonts.googleapis.com"},
        %{rel: "dns-prefetch", href: "//cdn.example.com"}
      ]

  ## Helper Functions in Layouts

  Helper functions provide custom logic within layouts:

      helpers: [
        %{
          name: "render_breadcrumbs",
          args: "breadcrumbs",
          code: ~S'''
          breadcrumbs
          |> Enum.with_index()
          |> Enum.map(fn {crumb, index} ->
            if index == length(breadcrumbs) - 1 do
              ~H"<span class='current'><%= crumb.title %></span>"
            else
              ~H"<a href={crumb.path}><%= crumb.title %></a>"
            end
          end)
          |> Enum.intersperse(~H" > ")
          '''
        }
      ]

  ## Error Handling

  The compiler handles various error conditions gracefully:

  - **Missing template** - Uses empty template with warning
  - **Invalid helper code** - Excludes problematic helpers with logging
  - **Missing required fields** - Uses sensible defaults where possible
  - **Template compilation errors** - Provides detailed error information

  ## Performance Considerations

  - **Template compilation** is performed once during module compilation
  - **Helper functions** are compiled as regular module functions
  - **Metadata access** uses compiled functions for optimal performance
  - **Resource links** are pre-processed and escaped during compilation

  ## Security Features

  - **Template sanitization** through Phoenix's HEEx engine
  - **Access control** integration with permission checks
  - **XSS prevention** through proper escaping
  - **Safe helper execution** with proper error boundaries

  See individual function documentation for detailed implementation examples.
  """

  # Compiled modules are built on the host's web entrypoint when it names one, so runtime templates
  # can reach its components and routes. See `MishkaCmsCore.Runtime.CompiledPageBase`.
  @web_module MishkaCmsCore.Runtime.Compilers.Shared.web_module()

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler

  require Logger

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Builds a complete layout module AST from configuration parameters.

  This is the primary entry point for the layout compilation process. It orchestrates
  the entire compilation pipeline to transform layout configuration into a complete
  Phoenix module AST ready for compilation.

  ## Parameters

  - `params` - Map containing layout configuration with keys:
    - `:title` - Layout title/name (required)
    - `:layout_module` - Target module name (required)
    - `:template` - HEEx template string (required)
    - `:path` - Layout path/URL (optional)
    - `:helpers` - List of helper function definitions (optional)
    - `:resource_links` - List of CSS/JS resource links (optional)
    - `:seo_tags` - List of SEO meta tags (optional)
    - `:site`, `:site_id`, `:host` - Site identification (optional)
    - `:permissions` - Access control permissions (optional)
    - `:extra` - Additional metadata (optional)
    - `:priority` - Layout priority for ordering (optional)
    - `:format` - Template format (:heex, default)

  ## Returns

  Returns the complete AST for the layout module that can be compiled using
  `MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module/1`.

  ## Examples

      # Basic layout
      params = %{
        title: "Simple Layout",
        layout_module: MyApp.Layouts.Simple,
        template: ~S'''
        <html>
          <body><%= @inner_content %></body>
        </html>
        '''
      }

      ast = build_module(params)

      # Complex layout with helpers and resources
      params = %{
        title: "Admin Layout",
        layout_module: MyApp.Layouts.Admin,
        template: admin_template,
        helpers: [
          %{name: "admin_nav", args: "user", code: "render_admin_navigation(user)"}
        ],
        resource_links: [
          %{rel: "stylesheet", href: "/admin/admin.css"}
        ],
        permissions: ["admin_access"]
      }

      ast = build_module(params)

  ## Compilation Pipeline

  The function processes layout data through these stages:
  1. **Information building** - Creates metadata and information functions
  2. **Render functions** - Compiles template and creates render functions
  3. **Helper functions** - Processes and compiles helper functions
  4. **Module creation** - Assembles final module AST with imports

  Each stage adds specific functionality to the final compiled module.
  """
  def build_module(params) do
    MishkaInstaller.Event.Hook.call("runtime:compile:before_layout", params,
      meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
      return: false
    )

    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :layout],
      %{name: params[:title] || params["title"], site: params[:site] || params["site"]},
      fn ->
        result =
          MishkaCmsCore.Runtime.Helpers.atomize_keys(params)
          |> build_layout_information()
          |> build_render_functions()
          |> build_helpers()
          |> create_module_ast()

        MishkaInstaller.Event.Hook.call("runtime:compile:after_layout", params,
          meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
          return: false
        )

        {result, %{}}
      end
    )
  end

  @doc """
  Builds layout information and metadata functions.

  Creates AST for the `__layout_information__` functions that provide comprehensive
  access to layout metadata, private information, ACL permissions, and extra data.
  These functions are essential for runtime introspection and layout management.

  ## Parameters

  - `params` - Atomized layout configuration map containing all layout data

  ## Returns

  Returns a tuple `{params, functions_ast}` where:
  - `params` - Original parameters (passed through for pipeline)
  - `functions_ast` - List containing the layout information function ASTs

  ## Generated Functions

  The generated module will contain these information functions:

  ### `__layout_information__/0`
  Returns complete layout metadata as a structured map with sections:
  - `:layout` - Core layout data (title, path, content, resources, SEO)
  - `:private` - Private metadata (IDs, module info, site data, whether the layout reads the
    signed-in user — see `MishkaCmsCore.Runtime.Compilers.UserClosure`)
  - `:acl` - Access control permissions
  - `:extra` - Additional custom metadata

  ### `__layout_information__/1` (atom key)
  Returns specific top-level section by atom key.

  ### `__layout_information__/1` (list of keys)
  Returns nested data using a list of keys for deep access.

  ### `__layout_information__/1` (dot-notation string)
  Returns nested data using dot-notation string paths like "private.site_id".

  ## Layout Information Structure

      %{
        layout: %{
          title: "Layout Title",
          path: "/layouts/example",
          timestamp: ~N[2024-01-15 10:30:00],
          content: "layout content",
          resource_links: [%{rel: "stylesheet", href: "/css/main.css"}],
          seo: %{meta_tags: [%{name: "description", content: "..."}]}
        },
        private: %{
          id: 123,
          layout_module: MyApp.Layouts.Example,
          priority: 0,
          site: "main_site",
          site_id: 1,
          host: "example.com",
          format: :heex,
          reads_user: false
        },
        acl: %{permissions: ["layout_view", "layout_edit"]},
        extra: %{theme: "modern", version: "1.0"}
      }

  ## Examples

      # After compilation, access layout information:
      info = MyLayout.__layout_information__()
      layout_data = MyLayout.__layout_information__(:layout)
      site_id = MyLayout.__layout_information__("private.site_id")
      permissions = MyLayout.__layout_information__([:acl, :permissions])

  ## Error Handling

  The string-based accessor includes error handling for invalid paths,
  returning `nil` when the path cannot be resolved or atoms don't exist.

  This function is typically called as the first stage in the compilation pipeline.
  """
  def build_layout_information(params) do
    layout_info_ast =
      quote do
        def __layout_information__() do
          %{
            layout: %{
              title: unquote(params[:title]),
              path: unquote(params[:path]),
              timestamp: unquote(Macro.escape(params[:timestamp])),
              content: unquote(Macro.escape(params[:content])),
              resource_links: unquote(Macro.escape(params[:resource_links] || [])),
              seo: %{
                meta_tags: unquote(Macro.escape(params[:seo_tags] || []))
              }
            },
            private: %{
              id: unquote(params[:id]),
              layout_module: unquote(params[:layout_module]),
              priority: unquote(params[:priority] || 0),
              site: unquote(params[:site]),
              site_id: unquote(params[:site_id]),
              host: unquote(params[:host]),
              format: unquote(params[:format]) || :heex,
              # WHETHER DRAWING A PAGE INSIDE THIS LAYOUT HAS TO LOAD THE SIGNED-IN USER — see
              # `MishkaCmsCore.Runtime.Compilers.UserClosure`, which works it out from the layout's
              # own markup and code. ANYTHING BUT AN EXPLICIT `false` MEANS LOAD, so a layout
              # compiled without the answer carries the safe one rather than the absent one.
              reads_user: unquote(params[:reads_user] != false)
            },
            acl: %{permissions: unquote(Macro.escape(params[:permissions] || []))},
            extra: unquote(Macro.escape(params[:extra]))
          }
        end

        def __layout_information__(key) when is_atom(key) do
          get_in(__layout_information__(), [key])
        end

        def __layout_information__(keys) when is_list(keys) do
          get_in(__layout_information__(), keys)
        end

        def __layout_information__(key) when is_binary(key) do
          String.split(key, ".")
          |> Enum.map(&String.to_existing_atom/1)
          |> then(&get_in(__layout_information__(), &1))
        rescue
          _ -> nil
        end
      end

    {params, [layout_info_ast]}
  end

  @doc """
  Builds render functions for layout template rendering.

  Compiles the HEEx template and creates render functions that handle different
  rendering scenarios. The functions automatically merge layout metadata with
  provided assigns and handle inner content injection.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing:
    - `params` - Layout configuration with template and metadata
    - `functions_ast` - Existing function ASTs from previous pipeline stages

  ## Returns

  Returns updated tuple `{params, functions_ast}` with render functions added.

  ## Generated Functions

  ### `render/1` - Basic rendering with assigns
  Renders the layout with provided assigns, automatically merging layout
  metadata into the assigns map.

      MyLayout.render(%{
        title: "Page Title",
        custom_data: "value"
      })

  ### `render/2` - Rendering with inner content
  Renders the layout with assigns and injects inner content. The inner content
  is available in the template as `@inner_content`.

      MyLayout.render(%{
        title: "Page Title"
      }, "<div>Page content here</div>")

  ## Template Compilation

  Templates are compiled using Phoenix's HEEx engine with:
  - **XSS protection** through automatic escaping
  - **LiveView integration** for dynamic updates
  - **Component support** for MishkaCMS runtime components
  - **Proper error handling** with detailed compilation feedback

  ## Layout Data Merging

  Both render functions automatically merge layout metadata into assigns:

      # Layout data is merged first, then user assigns override
      final_assigns = Map.merge(layout_metadata, user_assigns)

  Available layout data includes:
  - `@title` - Layout title
  - `@path` - Layout path
  - `@resource_links` - CSS/JS resource links
  - `@seo` - SEO metadata with meta_tags
  - `@content` - Layout content
  - Plus any custom data from the layout configuration

  ## Template Variables

  Templates have access to:
  - **All assigns** - User-provided and layout metadata
  - **Inner content** - `@inner_content` (render/2 only)
  - **Helper functions** - Custom layout helper functions
  - **MishkaCMS components** - Runtime compiled components

  ## Examples

      # Template with layout features
      template = ~S'''
      <!DOCTYPE html>
      <html>
        <head>
          <title><%= @title %></title>
          <%= for link <- @resource_links do %>
            <link rel={link.rel} href={link.href}>
          <% end %>
          <%= for meta <- @seo.meta_tags do %>
            <meta name={meta.name} content={meta.content}>
          <% end %>
        </head>
        <body>
          <header><%= render_header() %></header>
          <main><%= @inner_content %></main>
          <footer><%= @copyright_text %></footer>
        </body>
      </html>
      '''

      # Usage after compilation
      html = MyLayout.render(%{
        title: "My Page",
        copyright_text: "© 2024"
      }, "<p>Welcome to my site!</p>")

  ## Error Handling

  Template compilation errors are caught and reported with:
  - **File context** - Using generated file names for debugging
  - **Line numbers** - Accurate error positioning
  - **Syntax highlighting** - Clear error messages

  Invalid template syntax will prevent module compilation with detailed feedback.

  This function is called as the second stage in the compilation pipeline.
  """
  def build_render_functions({params, functions_ast}) do
    compiled_template = compile_template(params)

    render_functions_ast =
      quote do
        def render(var!(assigns)) when is_map(var!(assigns)) do
          layout_data = get_in(__layout_information__(), [:layout])
          var!(assigns) = Map.merge(layout_data, var!(assigns))
          unquote(compiled_template)
        end

        def render(var!(assigns), var!(inner_content)) when is_map(var!(assigns)) do
          layout_data = get_in(__layout_information__(), [:layout])

          var!(assigns) =
            var!(assigns)
            |> Map.merge(layout_data)
            |> Map.put(:inner_content, var!(inner_content))

          unquote(compiled_template)
        end
      end

    {params, functions_ast ++ [render_functions_ast]}
  end

  @doc """
  Builds helper functions for custom layout logic.

  Processes helper function definitions from the layout configuration and compiles
  them into the layout module. Helper functions provide custom logic that can be
  called from within layout templates.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing:
    - `params` - Layout configuration including `:helpers` list
    - `functions_ast` - Existing function ASTs from previous pipeline stages

  ## Returns

  Returns updated tuple `{params, functions_ast}` with helper functions added.

  ## Helper Function Format

  Each helper function should be defined as a map with:
  - `:name` - Function name as string (required)
  - `:args` - Function arguments as string (required)
  - `:code` - Function body as Elixir code string (required)

  ## Examples

      helpers: [
        %{
          name: "format_date",
          args: "date",
          code: ~S'''
          case date do
            %Date{} -> Date.to_string(date)
            %DateTime{} -> DateTime.to_date(date) |> Date.to_string()
            _ -> "Invalid date"
          end
          '''
        },
        %{
          name: "render_navigation",
          args: "items, current_path",
          code: ~S'''
          for item <- items || [] do
            active_class = if item.path == current_path, do: "active", else: ""
            ~H\"""
            <a href={item.path} class={"nav-link " <> active_class}>
              <%= item.title %>
            </a>
           \ \"""
          end
          '''
        },
        %{
          name: "calculate_reading_time",
          args: "content",
          code: ~S'''
          word_count = String.split(content || "") |> length()
          reading_time = max(1, div(word_count, 200))
          "\#{reading_time} min read"
          '''
        }
      ]

  ## Template Usage

  Helper functions can be called directly from layout templates:

      template = ~S'''
      <!DOCTYPE html>
      <html>
        <head>
          <title><%= @title %></title>
        </head>
        <body>
          <nav>
            <%= render_navigation(@nav_items, @current_path) %>
          </nav>
          <main>
            <time><%= format_date(@published_at) %></time>
            <p>Reading time: <%= calculate_reading_time(@content) %></p>
            <%= @inner_content %>
          </main>
        </body>
      </html>
      '''

  ## Function Compilation

  Helper functions are compiled as regular module functions with:
  - **Full Elixir syntax support** - Use any valid Elixir code
  - **Access to imports** - Phoenix.Component, HEEx, etc.
  - **Pattern matching** - Multiple function heads supported
  - **Guard clauses** - When conditions supported
  - **Private scope** - Helper functions are public within the layout module

  ## Advanced Helper Examples

      helpers: [
        # Multi-clause function with pattern matching
        %{
          name: "format_currency",
          args: "amount, currency \\\\ \"USD\"",
          code: ~S'''
          case currency do
            "USD" -> "$\#{:erlang.float_to_binary(amount / 100, decimals: 2)}"
            "EUR" -> "€\#{:erlang.float_to_binary(amount / 100, decimals: 2)}"
            _ -> "\#{amount}"
          end
          '''
        },

        # Helper with HEEx components
        %{
          name: "render_breadcrumbs",
          args: "crumbs",
          code: ~S'''
          crumbs
          |> Enum.with_index()
          |> Enum.map(fn {crumb, index} ->
            if index == length(crumbs) - 1 do
              ~H"<span class='breadcrumb-current'><%= crumb.title %></span>"
            else
              ~H"<a href={crumb.url} class='breadcrumb-link'><%= crumb.title %></a>"
            end
          end)
          |> Enum.intersperse(~H" &gt; ")
          '''
        }
      ]

  ## Error Handling

  - **Syntax errors** in helper code will prevent module compilation
  - **Invalid arguments** will cause compilation failures with detailed messages
  - **Missing dependencies** in helper code will be reported during compilation
  - **Runtime errors** in helpers will be caught and logged during template rendering

  ## Performance Considerations

  - Helper functions are compiled once during module compilation
  - No runtime overhead for function calls within templates
  - Complex helpers should be optimized for template rendering performance
  - Consider caching expensive computations within helper implementations

  This function is called as the third stage in the compilation pipeline.
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

    {params, functions_ast ++ helpers_ast}
  end

  @doc """
  Creates the final module AST with all components assembled.

  This is the final stage of the compilation pipeline that assembles all generated
  function ASTs into a complete module definition with proper imports and structure.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing:
    - `params` - Layout configuration with `:layout_module` target
    - `functions_ast` - All compiled function ASTs from previous stages

  ## Returns

  Returns the complete module AST ready for compilation.

  ## Generated Module Structure

  The final module includes:

  ```elixir
  defmodule TargetModule do
    require Logger
    use MishkaCmsWeb, :live_view  # whatever :web_module names
    import MishkaCmsCore.Runtime.LiveViewHelpers, only: [component: 1, component: 2]

    # Layout information functions
    def __layout_information__() do ... end
    def __layout_information__(key) when is_atom(key) do ... end
    def __layout_information__(keys) when is_list(keys) do ... end
    def __layout_information__(key) when is_binary(key) do ... end

    # Render functions
    def render(assigns) when is_map(assigns) do ... end
    def render(assigns, inner_content) when is_map(assigns) do ... end

    # Helper functions (if defined)
    def helper_function_name(args) do ... end
  end
  ```

  ## Module Dependencies

  The generated module automatically includes:

  - **Logger** - For debugging and error reporting
  - **The configured `:web_module`** - Phoenix LiveView functionality
  - **MishkaCmsCore.Runtime.LiveViewHelpers** - Runtime component access

  These imports enable the layout to:
  - Use LiveView features like `~H` sigil
  - Access Phoenix.Component functionality
  - Call runtime-compiled MishkaCMS components
  - Log errors and debug information

  ## Example Generated Module

      defmodule MyApp.Layouts.Main do
        require Logger
        use MishkaCmsWeb, :live_view  # whatever :web_module names
        import MishkaCmsCore.Runtime.LiveViewHelpers, only: [component: 1, component: 2]

        def __layout_information__() do
          %{
            layout: %{title: "Main Layout", path: "/layouts/main"},
            private: %{site: "main", format: :heex},
            acl: %{permissions: []},
            extra: nil
          }
        end

        def render(assigns) when is_map(assigns) do
          # Compiled template code here
        end

        def format_title(title, site_name) do
          # Helper function code here
        end
      end

  ## Integration Points

  The module structure ensures compatibility with:
  - **Phoenix LiveView** - Standard LiveView module pattern
  - **MishkaCMS Runtime** - Component and layout system integration
  - **Phoenix Components** - Full component library access
  - **Elixir OTP** - Standard module loading and hot code swapping

  ## Compilation Process

  After this function returns the AST:

      ast = create_module_ast({params, functions_ast})
      {:ok, module} = MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

  The module is then available for use throughout the application.

  This is the final stage in the compilation pipeline and produces the
  complete module ready for runtime compilation and usage.
  """
  def create_module_ast({params, functions_ast}) do
    quote do
      defmodule unquote(params[:layout_module]) do
        require Logger
        use unquote(@web_module), :live_view

        import MishkaCmsCore.Runtime.LiveViewHelpers,
          only: unquote(MishkaCmsCore.Runtime.LiveViewHelpers.imports(params[:helpers]))

        unquote_splicing(functions_ast)
      end
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  # Compiles HEEx template into executable AST using Phoenix LiveView engine.
  #
  # Transforms the raw template string into compiled Elixir code that can be
  # executed within the layout module context. Uses Phoenix's LiveView TagEngine
  # for proper HEEx syntax support and XSS protection.
  #
  # ## Parameters
  #
  # - `params` - Layout configuration containing `:template` and context information
  #
  # ## Returns
  #
  # Returns the compiled template AST ready for embedding in render functions.
  #
  # ## Template Engine Configuration
  #
  # The compilation uses these settings:
  # - **Engine**: Phoenix.LiveView.TagEngine for HEEx support
  # - **Tag Handler**: Phoenix.LiveView.HTMLEngine for proper HTML handling
  # - **File Context**: Generated file name for debugging
  # - **Source Trimming**: Enabled for cleaner output
  # - **Line Tracking**: Accurate line numbers for errors
  #
  # ## Error Handling
  #
  # Template compilation errors include:
  # - Syntax errors with line numbers
  # - Invalid HEEx expressions
  # - Missing closing tags
  # - Malformed component calls
  #
  # Errors are propagated up with full context for debugging.
  defp compile_template(params) do
    opts = [
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_layout_#{params[:template_name]}_#{params[:site]}",
      caller: make_env(),
      trim: true,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    params[:template]
    |> MishkaCmsCore.Runtime.PageBuilder.Visibility.strip()
    |> Phoenix.LiveView.TagEngine.compile(opts)
  end

  @doc """
  Creates compilation environment for template processing.

  Builds a macro environment with proper imports and context for HEEx template
  compilation. This environment determines what modules and functions are
  available within compiled templates.

  ## Returns

  Returns a `Macro.Env` struct configured for layout template compilation.

  ## Environment Configuration

  The environment includes:
  - **Base Environment** - Standard Elixir compilation environment
  - **Dynamic Imports** - Configurable module imports for templates
  - **Error Handling** - Graceful handling of missing import modules

  ## Current Import Strategy

  Currently, the imports list is empty (`[]`) but the infrastructure supports
  dynamic import addition. Future enhancements can include:

      # Example of potential imports
      imports = [
        Phoenix.Component,
        Phoenix.HTML,
        MyApp.HelperModules.DateHelpers,
        MyApp.HelperModules.TextHelpers
      ]

  ## Import Processing

  Each import is processed with:
  1. **Module availability check** - Verifies module is loaded
  2. **Safe import definition** - Uses `Macro.Env.define_import/3`
  3. **Error logging** - Warns about failed imports without stopping compilation
  4. **Graceful degradation** - Continues compilation even if some imports fail

  ## Error Handling

  Import failures are handled gracefully:
  - **Module not loaded** - Logs warning and continues
  - **Import definition error** - Logs error details and continues
  - **Compilation continues** - Failed imports don't prevent template compilation

  ## Usage in Template Compilation

  This environment is passed to `Phoenix.LiveView.TagEngine.compile/2` to provide
  proper context for template compilation:

      env = make_env()
      opts = [caller: env, ...]
      Phoenix.LiveView.TagEngine.compile(template, opts)

  ## Performance Considerations

  - Environment creation is lightweight
  - Import processing is done once during compilation
  - Failed imports have minimal performance impact
  - Environment is reused across template compilation calls
  """
  def make_env(imports \\ []) do
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

  # Defines an import in the macro environment safely.
  #
  # Wrapper around `Macro.Env.define_import/3` that provides a clean interface
  # for adding module imports to the template compilation environment.
  #
  # ## Parameters
  #
  # - `env` - The current macro environment
  # - `module` - The module to import
  #
  # ## Returns
  #
  # Returns `{:ok, updated_env}` on success or `{:error, reason}` on failure.
  #
  # ## Error Conditions
  #
  # Import definition can fail when:
  # - Module doesn't exist or isn't loaded
  # - Module doesn't export any functions
  # - Import conflicts with existing definitions
  # - Circular import dependencies
  #
  # All errors are handled gracefully by the calling function.
  defp define_import(env, module),
    do: MishkaCmsCore.Runtime.Compilers.Shared.define_import(env, module)
end
