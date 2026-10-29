# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.LiveViewCompiler do
  @moduledoc """
  Runtime compiler for Phoenix LiveView modules with dynamic content compilation.

  This module provides comprehensive functionality to dynamically compile Phoenix LiveView modules
  at runtime from configuration data. It generates complete LiveView modules with proper template
  compilation, event handling, lifecycle management, and metadata for CMS pages.

  ## Features

  - **Dynamic LiveView module generation** from configuration parameters
  - **HEEx template compilation** with Phoenix LiveView integration
  - **Event handler compilation** for interactive functionality (`handle_event/3`)
  - **Info handler compilation** for message processing (`handle_info/2`)
  - **Page metadata and information** functions for runtime introspection
  - **Helper function integration** for custom page logic
  - **SEO and schema metadata** with customizable tags
  - **Multi-site page support** with site-specific configurations
  - **Template rendering utilities** for runtime template processing

  ## LiveView Module Structure

  Generated LiveView modules include:
  - `__page_information__/0` - Returns complete page metadata
  - `__page_information__/1` - Returns specific metadata by key or path
  - `render/1` - Main template rendering function
  - `templates/1` - Template collection function
  - `handle_event/3` - Event handlers (if defined)
  - `handle_info/2` - Message handlers (if defined)
  - Helper functions (if defined in configuration)
  - Proper Phoenix LiveView and MishkaCMS integration

  ## Basic Usage

  The primary entry point is `build_module/1` which takes page configuration
  and returns a complete AST ready for compilation:

      params = %{
        title: "Home Page",
        page_module: MyApp.Pages.Home,
        template: ~S'''
        <div class="home-page">
          <h1><%= @title %></h1>
          <p>Welcome to our site!</p>

          <button phx-click="increment">
            Count: <%= @count %>
          </button>

          <%= for item <- @items do %>
            <div class="item"><%= item.name %></div>
          <% end %>
        </div>
        ''',
        events: [
          %{
            name: "increment",
            code: ~S'''
            count = (socket.assigns[:count] || 0) + 1
            {:noreply, assign(socket, :count, count)}
            '''
          }
        ],
        site: "main_site",
        site_id: 1
      }

      ast = LiveViewCompiler.build_module(params)
      MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

  ## Page Information Access

  Once compiled, pages provide comprehensive metadata access:

      # Get complete page information
      info = MyApp.Pages.Home.__page_information__()

      # Access specific sections
      page_data = MyApp.Pages.Home.__page_information__(:page)
      permissions = MyApp.Pages.Home.__page_information__(:acl)

      # Access nested data with dot notation
      site_id = MyApp.Pages.Home.__page_information__("private.site_id")
      schema = MyApp.Pages.Home.__page_information__("page.seo.schema")

  ## SEO and Schema Metadata

  Pages support comprehensive SEO and structured data:

      seo_tags: [
        %{name: "description", content: "Page description"},
        %{name: "keywords", content: "keyword1, keyword2"},
        %{property: "og:title", content: "Social Media Title"},
        %{property: "og:image", content: "https://example.com/image.png"}
      ]

      schema: [
        %{
          "@context" => "https://schema.org",
          "@type" => "Article",
          "headline" => "Article Title",
          "author" => %{"@type" => "Person", "name" => "John Doe"},
          "datePublished" => "2024-01-15"
        }
      ]

  ## Helper Functions in Pages

  Helper functions provide custom logic within pages:

      helpers: [
        %{
          name: "calculate_discount",
          args: "price, discount_percent",
          code: ~S'''
          discount_amount = price * (discount_percent / 100)
          price - discount_amount
          '''
        },
        %{
          name: "render_status_badge",
          args: "status",
          code: ~S'''
          class = case status do
            "active" -> "badge-success"
            "pending" -> "badge-warning"
            "inactive" -> "badge-danger"
            _ -> "badge-secondary"
          end

          ~H\"""
          <span class={"badge " <> class}>
            <%= String.capitalize(status) %>
          </span>
          \"""
          \'''
        }
      ]

  ## Error Handling and Safety

  The compiler includes comprehensive error handling:

  - **Template compilation errors** are caught and reported with context
  - **Event handler compilation** validates syntax before module creation
  - **Catch-all handlers** prevent crashes from unhandled events/messages
  - **Safe code evaluation** with proper error boundaries
  - **Runtime template rendering** with graceful error handling

  ## Performance Considerations

  - **Template compilation** is performed once during module compilation
  - **Event handlers** are compiled as efficient pattern-matched functions
  - **Helper functions** are compiled as regular module functions
  - **Metadata access** uses compiled functions for optimal performance
  - **Template rendering utilities** use optimized Phoenix engines


  ## Multi-Site Page Management

  Pages support multi-site configurations:

      # Site-specific page configuration
      params = %{
        title: "Site A Home",
        page_module: MyApp.Pages.SiteA.Home,
        template: site_a_template,
        site: "site_a",
        site_id: 1,
        host: "sitea.example.com"
      }
  """

  require Logger

  alias MishkaCmsCore.Runtime.PageBuilder.CodeReads
  alias MishkaCmsCore.Runtime.PageBuilder.CodeSignature
  alias MishkaCmsCore.Runtime.PageBuilder.Markup
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageUpload

  # Compiled modules are built on the host's web entrypoint when it names one, so runtime templates
  # can reach its components and routes. See `MishkaCmsCore.Runtime.CompiledPageBase`.
  @web_module MishkaCmsCore.Runtime.Compilers.Shared.web_module()

  # Rendering a template evaluates bare components such as `<.icon>` as LOCAL calls, so the eval env
  # has to import a CoreComponents module — the host's, since that is what compiled pages resolve
  # against. Standing alone this library's own is the only one that exists. Exactly one is imported:
  # importing both makes `icon/1` ambiguous and every render fails.
  @core_components Application.compile_env(
                     :mishka_cms_core,
                     :core_components,
                     MishkaCmsCore.CoreComponents
                   )

  ####################################################################################
  ############################ (▰˘◡˘▰) Functions (▰˘◡˘▰) #############################
  ####################################################################################

  @doc """
  Builds a complete LiveView module AST from configuration parameters.

  This is the primary entry point for the LiveView compilation process. It orchestrates
  the entire compilation pipeline to transform page configuration into a complete
  Phoenix LiveView module AST ready for compilation.

  ## Parameters

  - `params` - Map containing page configuration with keys:
    - `:title` - Page title/name (required)
    - `:page_module` - Target module name (required)
    - `:template` - HEEx template string (required)
    - `:path` - Page path/URL (optional)
    - `:section` - Page section/category (optional)
    - `:events` - List of event handler definitions (optional)
    - `:infos` - List of info handler definitions (optional)
    - `:helpers` - List of helper function definitions (optional)
    - `:description` - The page's meta description, stored as `page.seo.description` (optional)
    - `:seo_tags` - List of SEO meta tags (optional)
    - `:schema` - List of structured data schema (optional)
    - `:site`, `:site_id`, `:host` - Site identification (optional)
    - `:permissions` - Access control permissions (optional)
    - `:extra` - Additional metadata (optional)
    - `:priority` - Page priority for ordering (optional)
    - `:format` - Template format (:heex, default)

  ## Returns

  Returns the complete AST for the LiveView module that can be compiled using
  `MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module/1`.

  ## Examples

      # Basic interactive page
      params = %{
        title: "Counter Page",
        page_module: MyApp.Pages.Counter,
        template: ~S'''
        <div>
          <h1>Count: <%= @count %></h1>
          <button phx-click="increment">+</button>
          <button phx-click="decrement">-</button>
        </div>
        ''',
        events: [
          %{name: "increment", code: "{:noreply, update(socket, :count, &(&1 + 1))}"},
          %{name: "decrement", code: "{:noreply, update(socket, :count, &(&1 - 1))}"}
        ]
      }

      ast = build_module(params)

      # Complex dashboard page
      params = %{
        title: "Analytics Dashboard",
        page_module: MyApp.Pages.Dashboard,
        template: dashboard_template,
        events: dashboard_events,
        infos: dashboard_message_handlers,
        helpers: dashboard_helpers,
        seo_tags: [%{name: "description", content: "Analytics dashboard"}]
      }

      ast = build_module(params)

  ## Compilation Pipeline

  The function processes page data through these stages:
  1. **Assigns building** - Creates page information and metadata functions
  2. **Page forms** - Lifts the template's own forms into `__page_forms__/0` and generates their
     change and submit handlers
  3. **Event handlers** - Compiles interactive event handling functions
  4. **Info handlers** - Compiles message processing functions
  5. **Render functions** - Compiles template and creates render functions
  6. **Helper functions** - Processes and compiles helper functions
  7. **Module creation** - Assembles final module AST with imports

  Each stage adds specific functionality to the final compiled LiveView module.
  """
  def build_module(params) do
    MishkaInstaller.Event.Hook.call("runtime:compile:before_page", params,
      meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
      return: false
    )

    :telemetry.span(
      [:mishka_cms, :runtime, :compilers, :live_view],
      %{name: params[:title] || params["title"], site: params[:site] || params["site"]},
      fn ->
        # A HIDDEN ELEMENT IS LEFT OUT FIRST, so every stage after this one — the forms the page
        # declares included — sees only what a visitor gets. See `PageBuilder.Visibility`.
        result =
          MishkaCmsCore.Runtime.Helpers.atomize_keys(params)
          |> Map.update(:template, nil, &MishkaCmsCore.Runtime.PageBuilder.Visibility.strip/1)
          |> build_assigns()
          |> build_uploads()
          |> build_page_state()
          |> build_page_forms()
          |> build_page_messages()
          |> build_event_handlers()
          |> build_info_handlers()
          |> build_renders()
          |> build_helpers()
          |> create_module_ast()

        MishkaInstaller.Event.Hook.call("runtime:compile:after_page", params,
          meta: %{title: params[:title] || params["title"], site: params[:site] || params["site"]},
          return: false
        )

        {result, %{}}
      end
    )
  end

  @doc """
  Builds page information and metadata functions.

  Creates AST for the `__page_information__` functions that provide comprehensive
  access to page metadata, private information, ACL permissions, and extra data.
  These functions are essential for runtime introspection and page management.

  ## Parameters

  - `params` - Atomized page configuration map containing all page data

  ## Returns

  Returns a tuple `{params, functions_ast}` where:
  - `params` - Original parameters (passed through for pipeline)
  - `functions_ast` - List containing the page information function ASTs

  ## Generated Functions

  The generated module will contain these information functions:

  ### `__page_information__/0`
  Returns complete page metadata as a structured map with sections:
  - `:page` - Core page data (title, path, language, content, SEO, schema)
  - `:private` - Private metadata (IDs, module info, site data, whether the page reads the
    signed-in user — see `MishkaCmsCore.Runtime.Compilers.UserClosure`)
  - `:acl` - Access control permissions
  - `:extra` - Additional custom metadata

  ### `__page_information__/1` (atom key)
  Returns specific top-level section by atom key.

  ### `__page_information__/1` (list of keys)
  Returns nested data using a list of keys for deep access.

  ### `__page_information__/1` (dot-notation string)
  Returns nested data using dot-notation string paths like "private.site_id".

  ## Page Information Structure

      %{
        page: %{
          title: "Page Title",
          path: "/pages/example",
          section: "blog",
          language: "en",
          language_group_id: "0192f1d5-…",
          timestamp: ~N[2024-01-15 10:30:00],
          content: "page content",
          seo: %{
            description: "Shown by search engines and link previews",
            meta_tags: [%{name: "description", content: "..."}],
            schema: [%{"@type" => "Article", "headline" => "..."}]
          }
        },
        private: %{
          id: 123,
          page_module: MyApp.Pages.Example,
          priority: 0,
          site: "main_site",
          site_id: 1,
          host: "example.com",
          format: :heex,
          reads_user: false
        },
        acl: %{permissions: ["page_view", "page_edit"]},
        extra: %{analytics_id: "page_123", cache_ttl: 3600}
      }

  ## Examples

      # After compilation, access page information:
      info = MyPage.__page_information__()
      page_data = MyPage.__page_information__(:page)
      site_id = MyPage.__page_information__("private.site_id")
      seo_tags = MyPage.__page_information__([:page, :seo, :meta_tags])

  ## Error Handling

  The string-based accessor includes error handling for invalid paths,
  returning `nil` when the path cannot be resolved or atoms don't exist.

  This function is typically called as the first stage in the compilation pipeline.
  """
  def build_assigns(params) do
    assigns_ast =
      quote do
        def __page_information__ do
          %{
            page: %{
              title: unquote(params[:title]),
              path: unquote(params[:path]),
              section: unquote(params[:section]),
              language: unquote(params[:language]),
              language_group_id: unquote(params[:language_group_id]),
              timestamp: unquote(Macro.escape(params[:timestamp])),
              content: unquote(Macro.escape(params[:content])),
              seo: %{
                description: unquote(params[:description]),
                meta_tags: unquote(Macro.escape(params[:seo_tags] || [])),
                schema: unquote(Macro.escape(params[:schema] || []))
              }
            },
            private: %{
              id: unquote(params[:id]),
              layout: unquote(Macro.escape(params[:layout])),
              priority: unquote(params[:priority] || 0),
              page_module: unquote(params[:page_module]),
              site: unquote(params[:site]),
              site_id: unquote(params[:site_id]),
              host: unquote(params[:host]),
              format: unquote(params[:format]) || :heex,
              # WHETHER SERVING THIS PAGE HAS TO LOAD THE SIGNED-IN USER — see
              # `MishkaCmsCore.Runtime.Compilers.UserClosure`, which works it out from the page's
              # own markup and code. The layout it is drawn inside answers separately, in its own
              # module, and `MishkaCmsWeb.RuntimeLive` puts the two together. ANYTHING BUT AN
              # EXPLICIT `false` MEANS LOAD, so a page compiled without the answer carries the safe
              # one rather than the absent one.
              reads_user: unquote(params[:reads_user] != false)
            },
            acl: %{permissions: unquote(Macro.escape(params[:permissions] || []))},
            extra: unquote(Macro.escape(params[:extra]))
          }
        end

        def __page_information__(key) when is_atom(key) do
          get_in(__page_information__(), [key])
        end

        def __page_information__(keys) when is_list(keys) do
          get_in(__page_information__(), keys)
        end

        def __page_information__(key) when is_binary(key) do
          String.split(key, ".")
          |> Enum.map(&String.to_existing_atom/1)
          |> then(&get_in(__page_information__(), &1))
        rescue
          _ -> nil
        end
      end

    {params, [assigns_ast]}
  end

  @doc """
  Compiles the page's upload declarations into `__page_uploads__/0`, for the LiveView that mounts it
  to register.

  `allow_upload/3` is a `Phoenix.LiveView` function, and until this stage a compiled page had
  nowhere to call one: the compiler emits no `mount/3`, so `@uploads` never existed and
  `chelekom-file-field`'s live mode — the one stateful capability the kit already ships — had
  nothing to be handed. A live component cannot supply it either; `allow_upload/3` is not one of
  its functions.

  ## Why the module only says what it wants, and registers nothing

  A compiled page is not the LiveView that renders it: `MishkaCmsWeb.RuntimeLive` mounts, compiles
  the module and then calls its `render/1` and `handle_event/3`. So a `mount/3` or an `on_mount`
  hook emitted here would never run, and `@uploads` would never exist — which is how this was first
  written and what a page on the dev site said, in a 500 reading `key :uploads not found`.

  `MishkaCmsCore.Runtime.PageUpload.allow/2` is called by the mounting LiveView and reads this.

  ## Generated

      def __page_uploads__, do: [%{name: :attachment, accept: "image/*", max_entries: 2}]

  Emitted whether or not anything is declared, so a reader can ask without `function_exported?/3`.
  The name is turned into an atom HERE, at compile time, and never at runtime: the set of atoms is
  then bounded by what authors have saved rather than by what visitors send.
  """
  def build_uploads({params, functions_ast}) do
    declared = declared_uploads(params[:uploads])

    uploads_ast =
      quote do
        def __page_uploads__, do: unquote(Macro.escape(declared))
      end

    {params, functions_ast ++ [uploads_ast]}
  end

  # A DECLARATION WITH NO NAME IS NOT ONE, and neither is one that takes no type a visitor may send:
  # `accept` is required and `MishkaCmsCore.Runtime.PageUpload.allowed_extensions/1` reads it.
  # Everything else is optional and `MishkaCmsCore.Runtime.PageUpload.options/1` supplies both the
  # defaults and the ceilings, so the only work here is reading a row somebody stored — string keys
  # from the form, atom keys from a seed — refusing what cannot be registered at all, and keeping the
  # first of two that share a name, because `allow_upload/3` raises on a duplicate and would take the
  # whole page with it.
  # sobelow_skip ["DOS.StringToAtom"]
  # Compile time only, from the stored page's `uploads`, which only the page or code permission can write.
  defp declared_uploads(uploads) when is_list(uploads) do
    for declaration <- uploads,
        is_map(declaration),
        name = upload_name(declaration),
        is_binary(name),
        trimmed = String.trim(name),
        trimmed != "",
        PageUpload.allowed_extensions(upload_field(declaration, "accept")) != [] do
      %{
        name: String.to_atom(trimmed),
        accept: upload_field(declaration, "accept"),
        max_entries: upload_field(declaration, "max_entries"),
        max_file_size: upload_field(declaration, "max_file_size"),
        auto_upload: upload_field(declaration, "auto_upload")
      }
    end
    |> Enum.uniq_by(& &1.name)
  end

  defp declared_uploads(_uploads), do: []

  defp upload_name(declaration), do: upload_field(declaration, "name")

  defp upload_field(declaration, key),
    do: Map.get(declaration, key) || Map.get(declaration, String.to_existing_atom(key))

  @doc """
  Compiles the page's `state` into the assigns it starts with — see
  `MishkaCmsCore.Runtime.PageState`, which the mounting LiveView calls.

  ## Generated

      def __page_state__, do: %{count: 0, roles: roles()}
      def __page_state_keys__, do: [:count, :roles]

  `__page_state__/0` is evaluated each time a visitor mounts the page, so an expression may call the
  page's helpers and a timestamp is fresh. `__page_state_keys__/0` is a literal, read without running
  any of it. Both are emitted whether or not anything is declared.

  Each value passes through the same signature check as a handler: unsigned code, where signing is
  on, compiles to `nil`. The names become atoms here, at compile time, from rows that passed
  `MishkaCmsCore.Runtime.Resources.Validations.PageStateNames`; anything that is not a name is
  skipped rather than minted.
  """
  def build_page_state({params, functions_ast}) do
    declared = declared_state(params[:state])
    pairs = Enum.map(declared, fn {key, entry} -> {key, trusted_body(entry, :state, nil)} end)
    keys = Enum.map(declared, &elem(&1, 0))

    state_ast =
      quote do
        def __page_state__, do: unquote({:%{}, [], pairs})
        def __page_state_keys__, do: unquote(keys)
      end

    {params, functions_ast ++ [state_ast]}
  end

  # sobelow_skip ["DOS.StringToAtom"]
  # Compile time only, and only a name `PageState.valid_name?/1` accepts from the stored page's `state`.
  defp declared_state(entries) when is_list(entries) do
    for entry <- entries,
        is_map(entry),
        name = state_field(entry, :name),
        MishkaCmsCore.Runtime.PageState.valid_name?(name),
        code = state_field(entry, :code),
        is_binary(code) and String.trim(code) != "" do
      {String.to_atom(name), %{name: name, code: code, signature: state_field(entry, :signature)}}
    end
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp declared_state(_entries), do: []

  defp state_field(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  @doc """
  Compiles the page's own forms into `__page_forms__/0`, and generates the change and submit
  handlers for every form whose event names the author has NOT declared.

  The template is parsed ONCE PER COMPILE — a save, not a keystroke — so a page never re-reads its
  own markup to answer an event. The specs are put back into `params` under `:page_forms` for the
  same reason: `build_renders/1` needs nothing from them but "does this page have a form", and asking
  `PageForms.declared/1` again for that boolean tokenized, parsed and walked the whole page template a
  second time to re-derive a fact this stage already holds.

  An author who declares an event of the same name on the Events tab suppresses generation for it
  and owns the clause outright; they keep the whole seam by calling
  `MishkaCmsCore.Runtime.PageForm.validate/4` or `MishkaCmsCore.Runtime.PageForm.submit/5` from
  their own body. Generation is skipped rather than the clause being shadowed, because two
  `handle_event/3` heads with the same name would make the author's unreachable and their page would
  silently stop responding.

  The author's entries are first renamed with `MishkaCmsCore.Runtime.PageBuilder.PageForms.follow/2`
  and put back into `params[:events]`, so an entry stored under a renamed form's old tagged event
  compiles under the form's current one, and an entry for a deleted form never answers a new form
  that happens to reuse its seed.

  Runs before `build_event_handlers/1`, which appends the author's clauses and then the catch-all,
  so every generated clause is reachable and the catch-all still answers everything else.

  ## Generated Functions

      def __page_forms__, do: [%{assign: :contact_form, as: "contact", ...}]

      def handle_event("contact-k7m2q-validate", params, socket) do
        {:noreply, PageForm.validate(socket, __page_forms__(), "contact-k7m2q-validate", params)}
      end

      def handle_event("contact-k7m2q-submit", params, socket) do
        PageForm.submit(socket, __page_forms__(), "contact-k7m2q-submit", params)
      end
  """
  def build_page_forms({params, functions_ast}) do
    specs =
      params[:template]
      |> MishkaCmsCore.Runtime.PageBuilder.PageForms.declared()
      |> Enum.map(&with_upload_fields(&1, declared_uploads(params[:uploads])))

    events = PageForms.follow(params[:events] || [], current_events(specs))

    declared = MapSet.new(events, & &1.name)

    information =
      quote do
        def __page_forms__, do: unquote(Macro.escape(specs))
      end

    handlers =
      for spec <- specs,
          {event, kind} <- [{spec.change, :validate}, {spec.submit, :submit}],
          is_binary(event),
          event != "",
          !MapSet.member?(declared, event),
          do: {event, kind}

    {params |> Map.put(:page_forms, specs) |> Map.put(:events, events),
     functions_ast ++ [information | generated(handlers)]}
  end

  @doc """
  The body of a form's generated `handle_event/3` clause, as source: `kind` is `:validate` or
  `:submit`, and `event` is the event name the clause matches, which is also how the body finds its
  form in `__page_forms__/0`.
  """
  @spec form_handler_source(:validate | :submit, String.t()) :: String.t()
  def form_handler_source(:validate, event),
    do:
      ~s|{:noreply, MishkaCmsCore.Runtime.PageForm.validate(socket, __page_forms__(), #{inspect(event)}, params)}|

  def form_handler_source(:submit, event),
    do:
      ~s|MishkaCmsCore.Runtime.PageForm.submit(socket, __page_forms__(), #{inspect(event)}, params)|

  @doc """
  The default code for a form's event on the Events tab: print the params, then run
  `form_handler_source/2`, so the form keeps working.
  """
  @spec form_handler_sample(:validate | :submit, String.t()) :: String.t()
  def form_handler_sample(kind, event),
    do: "IO.inspect(params, label: #{inspect(event)})\n" <> form_handler_source(kind, event)

  @doc """
  Whether `code` is `form_handler_source/2` or `form_handler_sample/2` for `event` as written,
  whitespace aside. A quoted name carrying the same token and kind as `event` counts as `event`, so
  an untouched body still reads as untouched after its form is renamed.
  """
  @spec untouched_handler?(:validate | :submit, term(), term()) :: boolean()
  def untouched_handler?(kind, code, event) when is_binary(code) and is_binary(event) do
    defaults =
      Enum.map([form_handler_source(kind, event), form_handler_sample(kind, event)], &flat/1)

    code
    |> unrenamed(event)
    |> flat()
    |> then(&(&1 in defaults))
  end

  def untouched_handler?(_kind, _code, _event), do: false

  defp current_events(specs),
    do: for(spec <- specs, event <- [spec.change, spec.submit], is_binary(event), do: event)

  defp unrenamed(code, event),
    do: Regex.replace(~r/"([a-z][a-z0-9_-]*)"/, code, &quoted(&1, &2, event))

  defp quoted(whole, name, event),
    do: literal(name == event or Naming.same_event?(name, event), whole, event)

  defp literal(true, _whole, event), do: inspect(event)
  defp literal(false, whole, _event), do: whole

  defp flat(code) do
    code
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # TWO FORMS MAY NAME ONE EVENT, and a second clause for a name the first already matches is
  # unreachable code in somebody's published page. The first one wins, which is the same rule the
  # author's own declaration follows.
  # A FILE IS PART OF THE SUBMISSION. `Rules.changeset/2` casts against the fields a form declares
  # and `cast/4` drops everything else — so the descriptors
  # `MishkaCmsCore.Runtime.PageUpload.consume/2` merges in were consumed, written to disk and then
  # dropped on the floor before anything could be told about them. The file was stored and the
  # submission did not mention it.
  #
  # Every declared upload becomes a field on every form on the page, because consumption is
  # page-wide: an upload belongs to whichever form the visitor pressed, and reading which form a
  # `live_file_input` sits under would have to understand `upload={@uploads.x}` and the kit's
  # `uploads={@uploads} target={:x}` both. A form the visitor attached nothing to gets no key at
  # all, so the blunt rule costs a submission nothing.
  #
  # No rules: whether a file is required is a question about the form, and a page cannot make one up
  # on the author's behalf.
  defp with_upload_fields(spec, []), do: spec

  defp with_upload_fields(spec, uploads) do
    taken = MapSet.new(spec.fields, & &1.key)

    added =
      for %{name: name} <- uploads,
          not MapSet.member?(taken, name),
          do: %{key: name, type: {:array, :map}, rules: []}

    %{spec | fields: spec.fields ++ added}
  end

  defp generated(handlers),
    do: handlers |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&form_handler/1)

  # The body is `form_handler_source/2`, parsed.
  defp form_handler({event, kind}) do
    body = kind |> form_handler_source(event) |> Code.string_to_quoted!()

    quote do
      def handle_event(unquote(event), var!(params), var!(socket)) do
        unquote(body)
      end
    end
  end

  @doc """
  Gives a page the `handle_event/3` clauses for whatever server actions it uses.

  ## What the author did

  Picked an action in the builder's On click panel — "Show a message" is core's one — which wrote a
  `JS.push(…)` into the element's `phx-click`. That is the whole of the client half, and it is the
  same push a developer would write by hand.

  ## Why the registry rather than a name

  Because the list is not core's to close. `MishkaCmsCore.Runtime.PageBuilder.Interactions` collects
  every action through `builder:interactions`, and each server one names the event it pushes and the
  `{module, function}` that answers it — so an installed package's action compiles into a page the
  same way core's does, with nothing here knowing that package exists.

  The module named is the action's own RUNTIME module, never the editor code that wrote the click:
  what goes here is compiled into every published page using the action.

  ## Why every page, and not only the ones whose markup carries the push

  Because a page's markup is not where the click has to be. An author who puts the button inside a
  COMPONENT saves it in the component's markup; the page that uses that component says only
  `<.component component_name="promo-card" />`, and the word the gate was looking for is nowhere in
  it. The card rendered, the button rendered, the visitor clicked, and the event arrived at a module
  with no clause for it — swallowed by the catch-all, nothing on screen, nothing in the log. The same
  is true of a button in a layout, and of one on an error page.

  Looking harder was not an option worth the price: the page would have to load and scan every
  component it names, on every compile, to answer a question whose wrong answer is silence.

  So the clause is always there. A `handle_event/3` that nothing pushes costs nothing — it is three
  lines of bytecode in a module that already exists, no process, no query, and never runs. An author
  who declares an event of that name on the Events tab still suppresses it, exactly as they do for a
  form's: theirs is the more specific answer, and generating a second clause would make it
  unreachable.
  """
  def build_page_messages({params, functions_ast}) do
    declared = MapSet.union(author_events(params), form_events(params))
    answering = MishkaCmsCore.Runtime.PageBuilder.Interactions.server_actions()

    clauses =
      for action <- answering,
          not MapSet.member?(declared, action.event),
          do: say_handler(action)

    # PUT BACK INTO `params` FOR THE SAME REASON THE FORM SPECS ARE: `build_renders/1` needs nothing
    # from this but "does this page reach the server", and asking the registry again to re-derive a
    # fact this stage already holds is the collection `build_page_forms/1` was fixed not to repeat.
    {Map.put(params, :server_actions, answering), functions_ast ++ clauses}
  end

  defp author_events(params), do: MapSet.new(params[:events] || [], & &1.name)

  # AND A FORM'S EVENTS ARE SPOKEN FOR TOO. `build_page_forms/1` runs first, so its clause would win
  # anyway — which makes a colliding action's clause unreachable code the compiler warns about, in
  # somebody's published page. Left out rather than emitted dead.
  defp form_events(params) do
    for spec <- params[:page_forms] || [],
        event <- [spec.change, spec.submit],
        is_binary(event),
        into: MapSet.new(),
        do: event
  end

  defp say_handler(%{event: event, handler: {module, function}}) do
    quote do
      def handle_event(unquote(event), params, socket) do
        {:noreply, unquote(module).unquote(function)(socket, params)}
      end
    end
  end

  @doc """
  Builds event handler functions for LiveView interactivity.

  Compiles event handler definitions into `handle_event/3` functions that respond
  to user interactions like clicks, form submissions, and keyboard events.

  It takes the pipeline tuple `{params, functions_ast}` and reads the `:events` list of `params`.

  ## Returns

  Returns updated tuple `{params, functions_ast}` with event handler functions added.

  ## Event Handler Format

  Each event handler should be defined as a map with:
  - `:name` - Event name as string (required)
  - `:code` - Handler code as Elixir code string (required)

  ## Examples

      events: [
        %{
          name: "increment",
          code: ~S'''
          current_count = socket.assigns[:count] || 0
          {:noreply, assign(socket, :count, current_count + 1)}
          '''
        },
        %{
          name: "save_form",
          code: ~S'''
          case MyApp.Forms.save(params) do
            {:ok, result} ->
              {:noreply,
               socket
               |> put_flash(:info, "Saved successfully!")
               |> assign(:data, result)}

            {:error, changeset} ->
              {:noreply, assign(socket, :changeset, changeset)}
          end
          '''
        },
        %{
          name: "delete_item",
          code: ~S'''
          item_id = String.to_integer(params["id"])

          case MyApp.Items.delete(item_id) do
            :ok ->
              items = Enum.reject(socket.assigns.items, &(&1.id == item_id))
              {:noreply, assign(socket, :items, items)}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to delete item")}
          end
          '''
        }
      ]

  ## Generated Functions

  Each event definition creates a `handle_event/3` function:

      def handle_event("increment", _params, socket) do
        current_count = socket.assigns[:count] || 0
        {:noreply, assign(socket, :count, current_count + 1)}
      end

  ## Template Usage

  Event handlers are triggered from templates using Phoenix LiveView bindings:

      <button phx-click="increment">+1</button>

      <form id="save-form" phx-submit="save_form">
        <input type="text" name="title" />
        <button type="submit">Save</button>
      </form>

      <button phx-click="delete_item" phx-value-id={item.id}>
        Delete
      </button>

  ## Available Variables

  Event handler code has access to:
  - `params` - Event parameters from the client
  - `socket` - The LiveView socket with assigns and state
  - All imported functions from Phoenix.LiveView
  - Helper functions defined in the same module

  ## Return Values

  Event handlers must return valid LiveView responses:
  - `{:noreply, socket}` - Update socket and re-render
  - `{:reply, map, socket}` - Send reply to client and update socket
  - `{:noreply, socket, timeout}` - Update with timeout

  ## Catch-All Handler

  A catch-all `handle_event/3` is automatically added that:
  - Handles any unmatched events gracefully
  - Returns `{:noreply, socket}` to prevent crashes
  - Can be enhanced with logging in future versions

  ## Error Handling and Safety

  - **Syntax validation** - Event code is parsed for syntax errors during compilation
  - **Runtime errors** - Errors in event handlers are caught by Phoenix LiveView
  - **Parameter validation** - Access to `params` should include nil checks
  - **Socket state** - Always return valid socket to maintain LiveView state

  ## Performance Considerations

  - Event handlers are compiled as efficient pattern-matched functions
  - No runtime overhead for event dispatch
  - Direct access to socket assigns without serialization
  - Optimized for high-frequency user interactions

  This function is called as the second stage in the compilation pipeline.
  """
  def build_event_handlers({params, functions_ast}) do
    event_handlers_ast =
      Enum.map(params[:events] || [], fn event ->
        quote do
          def handle_event(unquote(event.name), var!(params), var!(socket)) do
            unquote(trusted_body(event, :handler, quote(do: {:noreply, var!(socket)})))
          end
        end
      end)

    # Add catch-all handle_event that just returns the socket
    # TODO: We can send logger here to dev and production report
    catch_all =
      quote do
        def handle_event(_event_name, _params, socket) do
          {:noreply, socket}
        end
      end

    {params, functions_ast ++ event_handlers_ast ++ [catch_all]}
  end

  @doc """
  Builds info handler functions for LiveView message processing.

  Compiles info handler definitions into `handle_info/2` functions that respond
  to messages sent to the LiveView process from other parts of the system.

  It takes the pipeline tuple `{params, functions_ast}` and reads the `:infos` list of `params`.

  ## Returns

  Returns updated tuple `{params, functions_ast}` with info handler functions added.

  ## Info Handler Format

  Each info handler should be defined as a map with:
  - `:name` - Message pattern as string (required)
  - `:code` - Handler code as Elixir code string (required)

  ## Examples

      infos: [
        %{
          name: ":refresh_data",
          code: ~S'''
          data = MyApp.DataSource.get_latest()
          {:noreply, assign(socket, :data, data)}
          '''
        },
        %{
          name: "{:user_updated, user}",
          code: ~S'''
          if socket.assigns.user_id == user.id do
            {:noreply, assign(socket, :user, user)}
          else
            {:noreply, socket}
          end
          '''
        },
        %{
          name: "{:broadcast, :data_changed, payload}",
          code: ~S'''
          case payload do
            %{type: "products"} ->
              products = MyApp.Products.list_products()
              {:noreply, assign(socket, :products, products)}

            %{type: "users"} ->
              users = MyApp.Users.list_users()
              {:noreply, assign(socket, :users, users)}

            _ ->
              {:noreply, socket}
          end
          '''
        },
        %{
          name: "{:timeout, ref, :periodic_update}",
          code: ~S'''
          # Schedule next update
          timer_ref = Process.send_after(self(), {:timeout, make_ref(), :periodic_update}, 30_000)

          # Update data
          stats = MyApp.Stats.get_current()

          {:noreply,
           socket
           |> assign(:stats, stats)
           |> assign(:timer_ref, timer_ref)}
          '''
        }
      ]

  ## Generated Functions

  Each info definition creates a `handle_info/2` function with pattern matching:

      def handle_info(:refresh_data, socket) do
        data = MyApp.DataSource.get_latest()
        {:noreply, assign(socket, :data, data)}
      end

      def handle_info({:user_updated, user}, socket) do
        if socket.assigns.user_id == user.id do
          {:noreply, assign(socket, :user, user)}
        else
          {:noreply, socket}
        end
      end

  ## Message Sending

  Info handlers can be triggered from anywhere in the system:

      # From controllers, contexts, or other processes
      send(live_view_pid, :refresh_data)
      send(live_view_pid, {:user_updated, updated_user})

      # From other LiveViews
      Phoenix.PubSub.broadcast(MyApp.PubSub, "data_updates",
        {:broadcast, :data_changed, %{type: "products"}})

      # Scheduled messages
      Process.send_after(self(), {:timeout, make_ref(), :periodic_update}, 5000)

  ## Common Use Cases

  ### Real-time Updates
  ```elixir
  infos: [
    %{
      name: "{:live_update, data}",
      code: ~S'''
      {:noreply, assign(socket, :live_data, data)}
      '''
    }
  ]
  ```

  ### PubSub Integration
  ```elixir
  # In mount/3 or event handler:
  Phoenix.PubSub.subscribe(MyApp.PubSub, "updates")

  # Info handler:
  infos: [
    %{
      name: "{:update_notification, payload}",
      code: ~S'''
      {:noreply, put_flash(socket, :info, payload.message)}
      '''
    }
  ]
  ```

  ### Periodic Tasks
  ```elixir
  infos: [
    %{
      name: ":tick",
      code: ~S'''
      # Schedule next tick
      Process.send_after(self(), :tick, 1000)

      # Update timestamp
      {:noreply, assign(socket, :current_time, DateTime.utc_now())}
      '''
    }
  ]
  ```

  ## Available Variables

  Info handler code has access to:
  - `socket` - The LiveView socket with assigns and state
  - Pattern-matched message variables (e.g., `user` in `{:user_updated, user}`)
  - All imported functions from Phoenix.LiveView
  - Helper functions defined in the same module

  ## Return Values

  Info handlers must return valid LiveView responses:
  - `{:noreply, socket}` - Update socket and re-render
  - `{:noreply, socket, timeout}` - Update with timeout for hibernation

  ## Catch-All Handler

  A catch-all `handle_info/2` is automatically added that:
  - Handles any unmatched messages gracefully
  - Returns `{:noreply, socket}` to prevent crashes
  - Can be enhanced with logging in future versions

  ## Error Handling and Safety

  - **Pattern matching** - Use specific patterns to avoid unexpected messages
  - **Guard clauses** - Add guards for additional message validation
  - **Defensive coding** - Check socket assigns before accessing nested data
  - **Message validation** - Validate message payload structure in handler code

  ## Performance Considerations

  - Info handlers are compiled as efficient pattern-matched functions
  - Direct message passing without serialization overhead
  - Optimized for high-frequency real-time updates
  - Process mailbox efficiency depends on message pattern specificity

  This function is called as the third stage in the compilation pipeline.
  """
  def build_info_handlers({params, functions_ast}) do
    info_handlers_ast =
      for info <- params[:infos] || [], pattern = info_pattern(info.name), pattern != :skip do
        quote do
          def handle_info(unquote(pattern), var!(socket)) do
            unquote(trusted_body(info, :message, quote(do: {:noreply, var!(socket)})))
          end
        end
      end

    # Add catch-all handle_info that just returns the socket
    # TODO: We can send logger here to dev and production report
    catch_all =
      quote do
        def handle_info(_message, socket) do
          {:noreply, socket}
        end
      end

    {params, functions_ast ++ info_handlers_ast ++ [catch_all]}
  end

  # A MESSAGE IS A TERM, NOT A STRING, and this is the difference between the two handler kinds.
  # LiveView really does send `"save"` to `handle_event/3`, so unquoting that name as a literal is
  # right. `handle_info/2` receives whatever `send/2` was given — `:tick`, `{:user_updated, user}` —
  # and unquoting THAT name as a string compiled to `handle_info(":tick", socket)`, a clause no
  # message can match. Every info handler anyone has written fell through to the catch-all below and
  # did nothing, silently, since the feature shipped.
  #
  # Parsed as a pattern it can also bind, which is the whole reason to match on a tuple: the `user`
  # in `{:user_updated, user}` is available to the body, because both sides come through
  # `Code.string_to_quoted!/1` and share its variable context.
  # SIGNED CODE RUNS; ANYTHING ELSE DOES NOTHING, AND THE PAGE STILL RENDERS.
  #
  # `MishkaCmsCore.Runtime.PageBuilder.CodeSignature` is off unless a key is configured, and then
  # `trusted?/1` answers true for everything and this is exactly the old behaviour. With a key, a
  # snippet whose signature is missing or does not match — a restored dump, a row written by
  # something other than this application — compiles to `inert` instead of to what it says.
  #
  # Inert rather than refusing to compile, on purpose: refusing would turn one tampered helper into a
  # site-wide outage, which is a better outcome for whoever tampered with it than for anybody else.
  defp trusted_body(snippet, kind, inert) do
    case CodeSignature.trusted?(snippet) do
      true ->
        Code.string_to_quoted!(snippet.code)

      false ->
        CodeSignature.warn_untrusted(kind, Map.get(snippet, :name))
        inert
    end
  end

  defp info_pattern(name) when is_binary(name) do
    case String.trim(name) do
      "" -> :skip
      trimmed -> guard_swallowing(Code.string_to_quoted!(trimmed), trimmed)
    end
  end

  defp info_pattern(_name), do: :skip

  # A BARE NAME MATCHES EVERY MESSAGE. `tick` — the colon left off, which is the likeliest typo here —
  # parses to a variable, and a variable pattern in the first clause swallows every message the page
  # ever receives, including the ones its other handlers were written for. It is skipped rather than
  # compiled, so the page keeps working exactly as it did before this function was fixed, and rather
  # than raised, so a page already carrying such a name still compiles.
  defp guard_swallowing({name, _meta, context}, trimmed)
       when is_atom(name) and is_atom(context) do
    Logger.warning(
      "[LiveViewCompiler] handle_info pattern #{inspect(trimmed)} would match every message — " <>
        "skipped. Write an atom (:tick) or a tuple ({:done, id})."
    )

    :skip
  end

  defp guard_swallowing(pattern, _trimmed), do: pattern

  @doc """
  Builds render functions for LiveView template rendering.

  Compiles the HEEx template and creates render functions that handle template
  rendering within the LiveView lifecycle. The functions integrate with Phoenix
  LiveView's rendering system and provide access to compiled templates.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing:
    - `params` - Page configuration with template and metadata
    - `functions_ast` - Existing function ASTs from previous pipeline stages

  ## Returns

  Returns updated tuple `{params, functions_ast}` with render functions added.

  ## Generated Functions

  ### `render/1` - Main template rendering function
  The primary render function that Phoenix LiveView calls to render the page.
  Takes assigns and returns the rendered template.

      def render(assigns) when is_map(assigns) do
        [primary] = templates(assigns)
        primary
      end

  ### `templates/1` - Template collection function
  Returns all compiled templates for the page. Currently returns a single
  primary template but structured to support multiple templates in the future.

      def templates(assigns) when is_map(assigns) do
        [compiled_template]
      end

  ## Template Compilation

  Templates are compiled using Phoenix's HEEx engine with:
  - **XSS protection** through automatic escaping
  - **LiveView integration** for dynamic updates
  - **Component support** for MishkaCMS runtime components
  - **Proper error handling** with detailed compilation feedback

  ## Template Structure

  The compiled template has access to:
  - **All assigns** - LiveView socket assigns
  - **Helper functions** - Custom page helper functions
  - **MishkaCMS components** - Runtime compiled components
  - **Phoenix components** - Standard Phoenix UI components

  ## Example Templates

      # Interactive template with event bindings
      template = ~S'''
      <div class="page">
        <h1><%= @title %></h1>

        <div class="counter">
          <button phx-click="decrement">-</button>
          <span><%= @count %></span>
          <button phx-click="increment">+</button>
        </div>

        <div class="items">
          <%= for item <- @items do %>
            <div class="item" id={"item-\#{item.id}"}>
              <h3><%= item.name %></h3>
              <p><%= item.description %></p>
              <button phx-click="delete" phx-value-id={item.id}>
                Delete
              </button>
            </div>
          <% end %>
        </div>
      </div>
      '''

      # Template with helper functions and components
      template = ~S'''
      <div class="dashboard">
        <header>
          <h1><%= format_title(@page_title, @site_name) %></h1>
          <div class="stats">
            <%= render_stats(@statistics) %>
          </div>
        </header>

        <main>
          <.component name="data_table"
                     data={@table_data}
                     columns={@columns} />
        </main>
      </div>
      '''

  ## Template Engine Configuration

  The compilation uses these settings:
  - **Engine**: Phoenix.LiveView.TagEngine for HEEx support
  - **Tag Handler**: Phoenix.LiveView.HTMLEngine for proper HTML handling
  - **File Context**: Generated file name for debugging
  - **Source Trimming**: Enabled for cleaner output
  - **Line Tracking**: Accurate line numbers for errors

  ## Error Handling

  Template compilation errors include:
  - Syntax errors with line numbers
  - Invalid HEEx expressions
  - Missing closing tags
  - Malformed component calls
  - Undefined variable references

  Errors are propagated up with full context for debugging.

  ## Integration with LiveView Lifecycle

  The render function integrates with Phoenix LiveView's rendering cycle:
  1. **Socket assigns** are passed to render/1
  2. **Template compilation** happens once during module compilation
  3. **Dynamic updates** are handled by LiveView's diff engine
  4. **Component integration** allows nested component rendering

  ## Performance Considerations

  - Template compilation is performed once during module compilation
  - Render function is optimized for repeated calls
  - LiveView's diff engine minimizes DOM updates
  - Helper function calls are direct module function calls

  This function is called as the fourth stage in the compilation pipeline.
  """
  def build_renders({params, functions_ast}) do
    opts = [
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_page_#{params[:template_name]}_#{params[:site]}",
      caller: make_env(),
      trim: true,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    primary =
      params[:template]
      |> confirmable(params[:page_forms], params[:layout_says?])
      |> Phoenix.LiveView.TagEngine.compile(opts)

    {references_ast, prefetch_ast} =
      MishkaCmsCore.Runtime.Compilers.Shared.component_prefetch(params[:template], params[:site])

    render_handlers_ast =
      quote do
        unquote(references_ast)

        # The components the page draws are built before it draws them — see
        # `MishkaCmsCore.Runtime.ComponentPrefetch` — and before its clock starts: a build is not
        # the page's render time.
        def render(var!(assigns)) when is_map(var!(assigns)) do
          unquote(prefetch_ast)
          unquote(measured_render(params[:page_module]))
        end

        def templates(var!(assigns)) when is_map(var!(assigns)) do
          [unquote(primary)]
        end
      end

    {params, functions_ast ++ [render_handlers_ast]}
  end

  # THE PAGE'S CLOCK (`MishkaCmsCore.Runtime.RenderMetrics`), chosen here, when the module is built,
  # so a draft preview's module gets the template alone. A page is `:handed_in`: its layout draws it
  # as `@inner_content` and does not count it.
  defp measured_render(module) do
    template =
      quote do
        [primary] = templates(var!(assigns))
        primary
      end

    case MishkaCmsCore.Runtime.RenderMetrics.measured?(module) do
      true ->
        quote do
          MishkaCmsCore.Runtime.RenderMetrics.measure(
            __MODULE__,
            fn -> unquote(template) end,
            :handed_in
          )
        end

      false ->
        template
    end
  end

  # EVERY PAGE SHOWS ITS OWN MESSAGES, because it cannot rely on a layout to.
  #
  # `MishkaCmsCore.Runtime.PageForm.submit/5` announces with `put_flash/3`, which is the right place
  # for it — a layout that renders a flash region shows it wherever the site decided such things
  # belong. But a layout is content somebody wrote, `data-success` on a form node promises the
  # visitor a message, and the promise was being kept only where a layout happened to have a flash:
  # measured across every layout in a stock install, that was none of them. Sending an enquiry
  # answered with nothing at all, which reads as a page that swallowed it.
  #
  # So the page carries the region itself. It was once carried only by a page with a form, which was
  # the same mistake one level down: a message can also come from a button, and a button set inside a
  # COMPONENT leaves no trace in the page's own markup to gate on — see `build_page_messages/1`. A
  # page that never says anything renders none of this, because the whole block is behind
  # `:if={announcements(@flash) != []}`; what it costs a page with nothing to say is nothing at all.
  #
  # A layout that renders its own flash simply shows the message twice in two places the author
  # chose, which is a styling question rather than a lost message.
  #
  # It reads `MishkaCmsCore.Runtime.PageForm.announcements/1` rather than naming a flash key, because
  # naming one is how the refusal came to be invisible: `refused/4` writes `:error`, the region knew
  # only `:info`, and a submission an author's own handler declined re-rendered with everything still
  # typed in it and no explanation — the very silence this region exists to end.
  #
  # IT FLOATS, AND IT CLOSES. Prepended to the document it was a block at the very top of the page:
  # subscribe to a newsletter in the footer and the answer landed a screenful and a half above the
  # form that asked, which is the same "nothing happened" this region exists to end. And `put_flash/3`
  # keeps a message for the life of the LiveView, so with no way to clear it the green success banner
  # stayed pinned over the contact form the visitor filled in next, for the rest of the session.
  # `lv:clear-flash` is LiveView's own event and needs no handler on the compiled page.
  #
  # AND IT LEAVES ON ITS OWN. `FlashAutoDismiss` is already in every site's bundle — the admin has
  # used it since it was written — and it takes the same route out that the click does, so waiting
  # it out and dismissing early end identically. A notice that only ever leaves when it is clicked
  # is a notice sitting over whatever the visitor was about to click, which on a phone is most of
  # the screen. Five seconds, because the two things it says are one short sentence each.
  #
  # THE TWO STACK. `announcements/1` returns one of each when a page carries several forms and one
  # was accepted while another was refused — and with the fixed placement on each `<p>`, both landed
  # at the same coordinates: the success sat exactly on top of the refusal, so the visitor of a
  # five-form page was told one thing and never shown the other. The placement belongs to the region,
  # once, and the messages are a column inside it.
  @confirmation ~S"""
  <div
    :if={MishkaCmsCore.Runtime.PageForm.announcements(@flash) != []}
    id="page-form-announcements"
    class="fixed inset-x-4 top-4 z-50 mx-auto flex max-w-3xl flex-col gap-2"
  >
    <p
      :for={{kind, message} <- MishkaCmsCore.Runtime.PageForm.announcements(@flash)}
      id={"page-form-#{kind}"}
      role={if(kind == :error, do: "alert", else: "status")}
      phx-click="lv:clear-flash"
      phx-value-key={kind}
      phx-hook="FlashAutoDismiss"
      data-kind={kind}
      data-dismiss-after="5000"
      title="Dismiss"
      class={[
        "cursor-pointer rounded-lg shadow-lg px-4 py-3 text-sm font-medium",
        kind == :info && "bg-emerald-50 text-emerald-800",
        kind == :error && "bg-rose-50 text-rose-800"
      ]}
    >{message}</p>
  </div>
  """

  @doc """
  The template a page really compiles: its own markup, with the confirmation region in front of it
  when the page declares a form.

  Public because THE CLASS SCANNER HAS TO READ THE SAME STRING. Tailwind matches class-shaped text in
  the `.template` files `MishkaCmsCore.Runtime.Handlers.BootHandler.create_template_file/4` writes,
  and that file was built from the STORED template while the region was prepended on the way into
  `Phoenix.LiveView.TagEngine.compile/2` — so `bg-emerald-50`, `max-w-3xl`, `shadow-lg` and the rest
  existed in no scanned file, no rule was generated for them, and the confirmation rendered as bare
  unstyled body text. Same class of bug as an attribute's default: markup that only ever exists after
  the scanner has read the file.

  `specs` is what `build_page_forms/1` already read out of the same template. Passing `nil` re-reads
  it, which is what a caller holding only a stored template has to do.
  """
  @spec confirmable(String.t() | nil, [map()] | nil, boolean() | nil) :: String.t() | nil
  def confirmable(template, specs \\ nil, layout_says? \\ false)

  # THE LAYOUT SAYS IT, SO THE PAGE DOES NOT. Watched on a real page: the click flashed, and the
  # visitor was told the same thing twice — once by this region and once by the flash group the
  # site's layout already renders. A layout that shows messages is the better place for them, since
  # it is where that site styled them.
  def confirmable(template, _specs, true) when is_binary(template), do: template

  def confirmable(template, _specs, _quiet_layout) when is_binary(template),
    do: @confirmation <> template

  # A PAGE WITH NO TEMPLATE HAS NOTHING TO SAY, and this has always answered `nil` for one.
  def confirmable(absent, _specs, _layout_says?), do: absent

  @doc """
  Whether a layout already shows messages — what `confirmable/3` takes as its third argument.

  ## Asked of the parsed template

  Because a wrong yes is a visitor who is told NOTHING, and this used to be
  `String.contains?(template, "@flash")` — which said yes to a layout that merely MENTIONED it: in an
  HTML comment, inside a string, in a `<pre>` showing somebody how to write one. No spelling of that
  check tells those apart, because the difference is not in the characters. So the template is
  tokenised and its expressions are parsed, and an assign is a node rather than a run of text.

  ## The two answers that are not about a template

  `nil` is a page with no layout of its own, which `MishkaCmsWeb.RuntimeLive` renders inside
  `Layouts.app` — and that carries a `<.flash_group>`, so it counts as a layout that shows messages.

  Anything unreadable counts as one that does not, so the page keeps its own region: being told twice
  is a blemish, being told nothing is the bug.
  """
  @spec shows_messages?(map() | nil) :: boolean()
  def shows_messages?(nil), do: true

  def shows_messages?(%{template: template}) when is_binary(template) do
    template
    |> Markup.expressions()
    |> Enum.any?(&MapSet.member?(CodeReads.assigns(&1), "flash"))
  end

  def shows_messages?(_unreadable), do: false

  # A PAGE THAT REACHES THE SERVER NEEDS SOMEWHERE TO ANSWER. A flash nothing renders is a button that
  # does nothing — the same silence this region was added for — and asking each action whether it
  # flashes would be a callback whose only honest answer is "possibly". Any server action is enough:
  # the region renders nothing at all when there is nothing to say, so being wrong costs no markup.
  @doc """
  Builds helper functions for custom page logic.

  Processes helper function definitions from the page configuration and compiles
  them into the LiveView module. Helper functions provide custom logic that can be
  called from within page templates and event handlers.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing:
    - `params` - Page configuration including `:helpers` list
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
          args: "date, format \\\\ :short",
          code: ~S'''
          case format do
            :short -> Calendar.strftime(date, "%m/%d/%Y")
            :long -> Calendar.strftime(date, "%B %d, %Y")
            :iso -> Date.to_iso8601(date)
            custom when is_binary(custom) -> Calendar.strftime(date, custom)
            _ -> Date.to_string(date)
          end
          '''
        },
        %{
          name: "calculate_total",
          args: "items, tax_rate \\\\ 0.08",
          code: ~S'''
          subtotal = Enum.reduce(items, 0, fn item, acc ->
            acc + (item.price * item.quantity)
          end)

          tax = subtotal * tax_rate
          subtotal + tax
          '''
        },
        %{
          name: "render_status_indicator",
          args: "status",
          code: ~S'''
          {class, icon, text} = case String.downcase(status) do
            "active" -> {"text-green-600", "check-circle", "Active"}
            "pending" -> {"text-yellow-600", "clock", "Pending"}
            "inactive" -> {"text-red-600", "x-circle", "Inactive"}
            "processing" -> {"text-blue-600", "refresh", "Processing"}
            _ -> {"text-gray-600", "question-mark-circle", "Unknown"}
          end

          ~H\"""
          <div class={"flex items-center space-x-2 " <> class}>
            <svg class="w-4 h-4" data-icon={icon}>
              <!-- Icon SVG would be here -->
            </svg>
            <span><%= text %></span>
          </div>
          \"""
          '''
        },
        %{
          name: "generate_pagination",
          args: "current_page, total_pages, window \\\\ 2",
          code: ~S'''
          start_page = max(1, current_page - window)
          end_page = min(total_pages, current_page + window)

          pages = Enum.to_list(start_page..end_page)

          %{
            current: current_page,
            total: total_pages,
            pages: pages,
            prev: if(current_page > 1, do: current_page - 1),
            next: if(current_page < total_pages, do: current_page + 1),
            has_prev: current_page > 1,
            has_next: current_page < total_pages
          }
          '''
        }
      ]

  ## Template Usage

  Helper functions can be called directly from templates:

      template = ~S'''
      <div class="order-summary">
        <h2>Order Summary</h2>
        <div class="date">
          Order Date: <%= format_date(@order.inserted_at, :long) %>
        </div>

        <div class="items">
          <%= for item <- @order.items do %>
            <div class="item">
              <span><%= item.name %></span>
              <span>$<%= item.price %> x <%= item.quantity %></span>
            </div>
          <% end %>
        </div>

        <div class="total">
          Total: $<%= calculate_total(@order.items, @tax_rate) %>
        </div>

        <div class="status">
          <%= render_status_indicator(@order.status) %>
        </div>
      </div>
      '''

  ## Event Handler Usage

  Helper functions can also be called from event handlers:

      events: [
        %{
          name: "change_page",
          code: ~S'''
          new_page = String.to_integer(params["page"])
          pagination = generate_pagination(new_page, socket.assigns.total_pages)

          {:noreply,
           socket
           |> assign(:current_page, new_page)
           |> assign(:pagination, pagination)}
          '''
        }
      ]

  ## Advanced Helper Examples

      helpers: [
        # Helper with pattern matching and guards
        %{
          name: "safe_divide",
          args: "a, b",
          code: ~S'''
          cond do
            b == 0 -> {:error, :division_by_zero}
            is_number(a) and is_number(b) -> {:ok, a / b}
            true -> {:error, :invalid_arguments}
          end
          '''
        },

        # Helper with HEEx components
        %{
          name: "render_breadcrumbs",
          args: "breadcrumbs",
          code: ~S'''
          breadcrumbs
          |> Enum.with_index()
          |> Enum.map(fn {crumb, index} ->
            if index == length(breadcrumbs) - 1 do
              ~H"<span class='breadcrumb-current'><%= crumb.title %></span>"
            else
              ~H\"""
              <a href={crumb.url} class='breadcrumb-link'>
                <%= crumb.title %>
              </a>
              \"""
            end
          end)
          |> Enum.intersperse(~H" / ")
          '''
        },

        # Helper with external API calls
        %{
          name: "get_weather",
          args: "location",
          code: ~S'''
          case MyApp.WeatherAPI.get_current(location) do
            {:ok, weather} ->
              %{
                temperature: weather.temp,
                description: weather.description,
                icon: weather.icon_url
              }

            {:error, _} ->
              %{
                temperature: "N/A",
                description: "Weather unavailable",
                icon: "/images/weather-unknown.svg"
              }
          end
          '''
        }
      ]

  ## Function Compilation

  Helper functions are compiled as regular module functions with:
  - **Full Elixir syntax support** - Use any valid Elixir code
  - **Access to imports** - Phoenix.Component, HEEx, etc.
  - **Pattern matching** - Multiple function heads supported
  - **Guard clauses** - When conditions supported
  - **Default arguments** - Using `\\\\` syntax
  - **Private scope** - Helper functions are public within the LiveView module

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

  ## Security Considerations

  - Helper functions have full access to the module's context
  - Validate inputs in helpers that process user data
  - Be cautious with helpers that make external API calls
  - Use proper escaping for helpers that return HTML content

  This function is called as the fifth stage in the compilation pipeline.
  """
  # sobelow_skip ["DOS.StringToAtom"]
  # Helper names of a stored page, which only the page or code permission can write.
  def build_helpers({params, functions_ast}) do
    helpers_handlers_ast =
      Enum.map(params[:helpers] || [], fn helper ->
        quote do
          # sobelow_skip ["DOS.StringToAtom"]
          # The stored helper's name becomes the function's, as in `build_helpers/1` above.
          def unquote(String.to_atom(helper.name))(unquote_splicing(helper_args(helper.args))) do
            unquote(trusted_body(helper, :helper, nil))
          end
        end
      end)

    {params, functions_ast ++ helpers_handlers_ast}
  end

  @doc """
  The quoted argument list of a helper whose `args` is `args`, for
  `def name(unquote_splicing(…))`: `""` or `nil` is no argument, `"assigns"` one,
  `"assigns, suffix"` two, defaults included.

  Read as the argument list of a call, so `args` must parse as one. Pages, layouts and error pages
  all build their helpers' heads with it.

      LiveViewCompiler.helper_args("")
      #=> []

      LiveViewCompiler.helper_args("assigns, size")
      #=> [{:assigns, [line: 1], nil}, {:size, [line: 1], nil}]
  """
  @spec helper_args(String.t() | nil) :: [Macro.t()]
  def helper_args(args) when is_binary(args) do
    case String.trim(args) do
      "" ->
        []

      trimmed ->
        {:helper, _meta, parsed} = Code.string_to_quoted!("helper(#{trimmed})")
        parsed
    end
  end

  def helper_args(_args), do: []

  @doc """
  Creates the final LiveView module AST with all components assembled.

  This is the final stage of the compilation pipeline that assembles all generated
  function ASTs into a complete LiveView module definition with proper imports and structure.

  ## Parameters

  - `{params, functions_ast}` - Tuple containing:
    - `params` - Page configuration with `:page_module` target
    - `functions_ast` - All compiled function ASTs from previous stages

  ## Returns

  Returns the complete module AST ready for compilation.

  ## Generated Module Structure

  The final module includes:

  ```elixir
  defmodule TargetModule do
    use MishkaCmsWeb, :live_view  # whatever :web_module names
    import MishkaCmsCore.Runtime.LiveViewHelpers, only: [component: 1, component: 2]

    # Page information functions
    def __page_information__() do ... end
    def __page_information__(key) when is_atom(key) do ... end
    def __page_information__(keys) when is_list(keys) do ... end
    def __page_information__(key) when is_binary(key) do ... end

    # Event handlers
    def handle_event(event, params, socket) do ... end

    # Info handlers
    def handle_info(message, socket) do ... end

    # Render functions
    def render(assigns) when is_map(assigns) do ... end
    def templates(assigns) when is_map(assigns) do ... end

    # Helper functions (if defined)
    def helper_function_name(args) do ... end
  end
  ```

  ## Module Dependencies

  The generated module automatically includes:

  - **MishkaCmsWeb :live_view** - Full Phoenix LiveView functionality
  - **MishkaCmsCore.Runtime.LiveViewHelpers** - Runtime component access

  These imports enable the LiveView to:
  - Use LiveView features like event handling and socket management
  - Access Phoenix.Component functionality and HEEx templates
  - Call runtime-compiled MishkaCMS components
  - Handle user interactions and real-time updates

  ## Example Generated Module

      defmodule MyApp.Pages.ProductList do
        use MishkaCmsWeb, :live_view  # whatever :web_module names
        import MishkaCmsCore.Runtime.LiveViewHelpers, only: [component: 1, component: 2]

        def __page_information__() do
          %{
            page: %{title: "Product List", path: "/products"},
            private: %{site: "main", format: :heex},
            acl: %{permissions: []},
            extra: nil
          }
        end

        def handle_event("search", %{"query" => query}, socket) do
          results = MyApp.Products.search(query)
          {:noreply, assign(socket, :results, results)}
        end

        def render(assigns) do
          # Compiled template code here
        end

        def format_price(price) do
          # Helper function code here
        end
      end

  ## Integration Points

  The module structure ensures compatibility with:
  - **Phoenix LiveView** - Standard LiveView module pattern
  - **Phoenix Router** - Can be mounted with `live/3` macro
  - **MishkaCMS Runtime** - Component and page system integration
  - **Phoenix Components** - Full component library access
  - **Elixir OTP** - Standard module loading and hot code swapping

  ## Compilation Process

  After this function returns the AST:

      ast = create_module_ast({params, functions_ast})
      {:ok, module} = MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

  The module is then available for use in routes, testing, and the application.

  ## LiveView Lifecycle Integration

  The generated module works seamlessly with Phoenix LiveView's lifecycle:

      # In router
      live "/dashboard", MyApp.Pages.Dashboard

      # LiveView handles mount, events, and rendering automatically
      # Page information is available for metadata and SEO
      # Event handlers respond to user interactions
      # Info handlers process real-time updates

  This is the final stage in the compilation pipeline and produces the
  complete LiveView module ready for runtime compilation and usage.
  """
  def create_module_ast({params, functions_ast}) do
    quote do
      defmodule unquote(params[:page_module]) do
        use unquote(@web_module), :live_view

        import MishkaCmsCore.Runtime.LiveViewHelpers,
          only: unquote(MishkaCmsCore.Runtime.LiveViewHelpers.imports(params[:helpers]))

        import MishkaCmsCore.Runtime.PageForm, only: [form_errors: 1]

        unquote_splicing(functions_ast)
      end
    end
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################
  @doc """
  Renders isolated HEEx template with assigns for runtime operations not page compiling.

  ## Example

      render_template("<div>{@name}</div>", %{name: "John"})
      #=> "<div>John</div>"

      render_template("<.link patch='/users'>{@text}</.link>", %{text: "Users"})
      #=> "<a href=\"/users\" data-phx-link=\"patch\" data-phx-link-state=\"push\">Users</a>"
  """
  @spec render_template(String.t(), map()) :: String.t() | {:error, term()}
  # sobelow_skip ["RCE.CodeModule"]
  # Renders a template an admin stored (a page, layout, error page, component or a draft of one) for a
  # preview; templates are code by design, and only the runtime and code permissions can write them.
  def render_template(template, assigns \\ %{}) when is_binary(template) and is_map(assigns) do
    template = MishkaCmsCore.Runtime.PageBuilder.Visibility.strip(template)

    assigns =
      assigns
      |> Map.new()
      |> Map.put_new(:__changed__, %{})
      |> Map.put_new(:socket, %Phoenix.LiveView.Socket{})

    template_name = "runtime_template_#{:erlang.unique_integer([:positive])}"

    opts = [
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_render_#{template_name}",
      caller: make_env(),
      trim: true,
      tag_handler: Phoenix.LiveView.HTMLEngine
    ]

    try do
      ast = Phoenix.LiveView.TagEngine.compile(template, opts)

      env =
        make_env([
          Phoenix.Component,
          Phoenix.HTML,
          # STATIC, NOT LIVE, and the swap is the whole fix for four surfaces at once. Everything
          # that reaches this function renders a template to a STRING and hands the string somewhere
          # that is not a LiveView — the Preview tab, the palette's card thumbnails, the examples
          # encoder, the public draft-preview URL. A stateful component called through the live
          # dispatch builds a `%Phoenix.LiveView.Component{}`, and asking one for iodata raises
          # "cannot convert component … to HTML", so every one of them showed that sentence instead
          # of a picture.
          #
          # This environment is OUR code rather than a generated module, which is what makes one
          # import the boundary: nothing a kit or an author writes can reach past it, and a compiled
          # page module — which imports the live helpers and IS a LiveView — is untouched.
          MishkaCmsCore.Runtime.StaticHelpers,
          MishkaCmsCore.Runtime.PageForm,
          @core_components
        ])

      {rendered, _} = Code.eval_quoted(ast, [assigns: assigns], env)

      rendered
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    rescue
      error ->
        {:error, Exception.format(:error, error, __STACKTRACE__)}
    end
  end

  @doc """
  Renders `template` with the classic `Phoenix.HTML.Engine` (not HEEx), matching how the runtime
  serves error-page templates (`MishkaCmsCore.Runtime.Compilers.ErrorCompiler` compiles them with
  the same engine). Unlike `render_template/2`, this engine does not tokenize HTML structurally, so
  it allows EEx interpolation inside attribute values (`content="<%= ... %>"`) — which a
  server-rendered root layout relies on and which HEEx rejects.

  Returns the rendered HTML string, or `{:error, message}` on failure.
  """
  @spec render_html_template(String.t(), map()) :: String.t() | {:error, term()}
  # sobelow_skip ["RCE.CodeModule"]
  # Renders a stored error page's or layout's template for a preview, as `render_template/2` does;
  # only the runtime and code permissions can write one.
  def render_html_template(template, assigns \\ %{})
      when is_binary(template) and is_map(assigns) do
    assigns = Map.new(assigns)
    template_name = "runtime_html_#{:erlang.unique_integer([:positive])}"

    opts = [
      engine: Phoenix.HTML.Engine,
      line: 1,
      indentation: 0,
      file: "mishka_cms_runtime_html_render_#{template_name}",
      caller: make_env(),
      source: template,
      trim: true
    ]

    try do
      ast = EEx.compile_string(template, opts)

      env =
        make_env([
          Phoenix.Component,
          Phoenix.HTML,
          # STATIC, NOT LIVE, and the swap is the whole fix for four surfaces at once. Everything
          # that reaches this function renders a template to a STRING and hands the string somewhere
          # that is not a LiveView — the Preview tab, the palette's card thumbnails, the examples
          # encoder, the public draft-preview URL. A stateful component called through the live
          # dispatch builds a `%Phoenix.LiveView.Component{}`, and asking one for iodata raises
          # "cannot convert component … to HTML", so every one of them showed that sentence instead
          # of a picture.
          #
          # This environment is OUR code rather than a generated module, which is what makes one
          # import the boundary: nothing a kit or an author writes can reach past it, and a compiled
          # page module — which imports the live helpers and IS a LiveView — is untouched.
          MishkaCmsCore.Runtime.StaticHelpers,
          MishkaCmsCore.Runtime.PageForm,
          @core_components
        ])

      {rendered, _} = Code.eval_quoted(ast, [assigns: assigns], env)

      rendered
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    rescue
      error ->
        {:error, Exception.format(:error, error, __STACKTRACE__)}
    end
  end

  @doc """
  Renders a HEEx template with assigns, raises on error.
  """
  @spec render_template!(String.t(), map()) :: String.t()
  def render_template!(template, assigns \\ %{}) do
    case render_template(template, assigns) do
      {:error, message} -> raise "Template rendering failed: #{message}"
      result when is_binary(result) -> result
    end
  end

  @doc """
  Creates compilation environment for template and code processing.

  Builds a macro environment with proper imports and context for HEEx template
  compilation and code evaluation. This environment determines what modules and
  functions are available within compiled templates and code.

  ## Parameters

  - `imports` - List of modules to import (default: `[]`)

  ## Returns

  Returns a `Macro.Env` struct configured for compilation with the specified imports.

  ## Environment Configuration

  The environment includes:
  - **Base Environment** - Standard Elixir compilation environment
  - **Dynamic Imports** - Configurable module imports
  - **Error Handling** - Strict error handling for import failures

  ## Import Processing

  Each import is processed with:
  1. **Module availability check** - Verifies module is loaded
  2. **Safe import definition** - Uses `Macro.Env.define_import/3`
  3. **Strict error handling** - Raises on import failures

  ## Common Usage

      # Template compilation environment
      env = make_env([Phoenix.Component, Phoenix.HTML])

      # Code evaluation environment
      env = make_env([Phoenix.LiveView, MyApp.Helpers])

  ## Error Handling

  Import failures will raise exceptions with detailed error information.
  This ensures that compilation fails early if required modules are not available.
  """
  def make_env(imports \\ []) do
    Enum.reduce(imports, aliased_env(), fn module, env ->
      # `Code.ensure_loaded?/1` rather than `:erlang.module_loaded/1`, which only answers whether the
      # module happens to be in memory ALREADY. On a cold VM every one of these is `false` — the BEAM
      # loads on first use — so the import was silently skipped and `<.form>`, `<.link>` and every
      # other `Phoenix.Component` function component was undefined inside a runtime template. Whether
      # a template rendered then depended on whether some unrelated request had loaded the module
      # first, which is a template that works in production and not in a fresh release, or the other
      # way round, for no reason the author can see.
      with true <- Code.ensure_loaded?(module),
           {:ok, env} <- define_import(env, module) do
        env
      else
        {:error, error} -> raise "failed to import #{module}: #{error}"
        _unavailable -> env
      end
    end)
  end

  # `JS` IS AN ALIAS, NOT AN IMPORT, and this environment had every import a page gets and none of its
  # aliases. A compiled page reaches `JS.show(…)` because `use <web module>, :live_view` folds in
  # `alias Phoenix.LiveView.JS`; `render_template/2` folded imports onto this module's own `__ENV__`,
  # where that alias does not exist, so the one thing the builder's own Interactions panel writes —
  # `phx-click={JS.toggle_class("is-open", to: ".pb-…")}` — could not be evaluated here at all:
  #
  #     ** (UndefinedFunctionError) function JS.toggle_class/2 is undefined (module JS is not
  #        available)
  #
  # The page it is written on compiles and runs; only the surfaces that go through this function —
  # the component preview and the Examples tab — could not show it. So an interaction worked
  # everywhere except where the author looks to check it.
  defp aliased_env do
    case Macro.Env.define_alias(__ENV__, [line: __ENV__.line], Phoenix.LiveView.JS, as: JS) do
      {:ok, env} -> env
      {:error, _reason} -> __ENV__
    end
  end

  # Defines an import in the macro environment safely.
  #
  # Wrapper around `Macro.Env.define_import/3` that provides a clean interface
  # for adding module imports to the compilation environment.
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
  defp define_import(env, module),
    do: MishkaCmsCore.Runtime.Compilers.Shared.define_import(env, module)
end
