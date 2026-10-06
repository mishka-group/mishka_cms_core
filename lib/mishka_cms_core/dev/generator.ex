defmodule MishkaCmsCore.Dev.Generator do
  @moduledoc """
  Generator for MishkaCmsCore resources.
  - Test functions (no prefix): simple, deterministic — used by factory and tests.
  - Dev functions (dev_ prefix): realistic, rich data — used by dev seeds.

  ## Every attribute an action accepts is named

  One a generator leaves out is INVENTED by `Ash.Generator` from its type, and a type is looser than
  the resource: a layout's `example` drawn from all of printable Unicode passes `min_length: 3` and
  is refused by the guard, which strips zero-width and control characters before counting, so seeds
  failed now and then. The same omission made `precompile` a coin flip and `uploads` a random list
  before it. `MishkaCmsCore.Dev.GeneratorNamesEveryAttributeTest` reads each `defaults` list against
  its action's `accept`, so an attribute added to a resource fails there first.

  ## The error-page templates are AUTHOR CONTENT, not markup

  `generate_error_pages/0` builds template STRINGS that are written into the database. Nothing here
  is rendered by Phoenix: `MishkaCmsCore.Runtime.Compilers.ErrorCompiler` reads those rows back,
  compiles them per site and serves them from a controller on a PUBLIC page. Two things follow.

  Their Tailwind classes are found by the per-site pass over stored templates rather than by
  `mix admin_css`, which is why `test/mishka_cms_web/live/interpolated_class_test.exs` exempts this
  file by name.

  And they cannot carry an inline event handler. A site that enforces a Content-Security-Policy
  refuses `onclick=` outright — `script-src` has no nonce or hash that applies to an event handler,
  so the attribute IS the violation — and there is no LiveView on an error page to accept a
  `phx-click` instead. A control that needs the browser to move is therefore a link: "Try Again"
  re-requests `@conn.request_path`, which is what a reload is. Walking back through history is the
  one thing no link expresses, so it is not offered.
  """
  use Ash.Generator

  # ---------------------------------------------------------------------------
  # TEST generators (used by factory / tests)
  # ---------------------------------------------------------------------------

  def site(opts \\ []) do
    changeset_generator(
      MishkaCmsCore.Runtime.Site,
      :create,
      authorize?: false,
      defaults: [
        host: sequence(:host, &"test#{&1}.com"),
        name: sequence(:name, &"Test Site #{&1}"),
        active: true,
        priority: 0,
        master: false,
        # `:hybrid`, not one of the three at random. `mode` decides whether a site answers the web,
        # the API, or both, so a random one made every test touching either a coin flip — and while
        # the plugs compared this atom against a string and never matched, nothing noticed. A test
        # that wants another mode asks for it.
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      ],
      overrides: opts
    )
  end

  def component(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.Component,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Component #{&1}"),
        # A TEMPLATE THAT READS AN ASSIGN THIS FACTORY NEVER DECLARES CANNOT RENDER. `attrs` below
        # is `[]`, so `@content` was a `KeyError` in every fixture component that was actually
        # drawn — caught by the canvas's `contain/3` and logged as "raised while rendering", which
        # made a rescued fixture defect look like a component failure and put noise in every run
        # that happened to draw one.
        template: "<div>Test template</div>",
        format: :heex,
        priority: 0,
        extra: %{},
        body: nil,
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        active: true,
        # EVERY BOOLEAN THIS RESOURCE HAS, PINNED. An attribute a generator says nothing about is
        # INVENTED by `Ash.Generator` from its type, and for a boolean that is a coin flip on every
        # fixture — so `precompile` and `required` have been random in every component this factory
        # ever built, and a fixture that happened to come out `precompile: true` compiles at boot.
        # Nothing asserted on either, so it stayed invisible until `stateful` arrived and a test
        # asked what a plain component's shape was.
        #
        # The page, layout and error-page factories beside this one all pin `precompile: false`. This
        # one was simply missed.
        precompile: false,
        required: false,
        stateful: false,
        description: nil,
        type: nil,
        examples: [],
        dependencies: [],
        site_id: nil
      ],
      # A SEED IS NOT AN AUTHOR. These four resources carry `helpers` (and a page carries `events`
      # and `infos` too), and `Validations.CodeChange` refuses those from a write with no actor. A
      # seed and a test fixture have no actor at all, so they announce what they are the same way the
      # kit installer does.
      context: %{page_code: :package},
      overrides: opts,
      tenant: tenant
    )
  end

  def layout(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.Layout,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Layout #{&1}"),
        path: sequence(:path, &"/test-path-#{&1}"),
        description: nil,
        template: "<html><head><title>Test</title></head><body><%= @content %></body></html>",
        format: :heex,
        priority: 0,
        extra: %{},
        content: %{},
        example: nil,
        resource_links: [],
        seo_tags: [],
        helpers: [],
        active: true,
        precompile: false,
        permissions: [],
        site_id: nil
      ],
      # A SEED IS NOT AN AUTHOR. These four resources carry `helpers` (and a page carries `events`
      # and `infos` too), and `Validations.CodeChange` refuses those from a write with no actor. A
      # seed and a test fixture have no actor at all, so they announce what they are the same way the
      # kit installer does.
      context: %{page_code: :package},
      overrides: opts,
      tenant: tenant
    )
  end

  def error_page(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.ErrorPage,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Error Page #{&1}"),
        path: sequence(:path, &"/error-path-#{&1}"),
        root_layout_template:
          "<html><head><title>Error</title></head><body><%= @inner_content %></body></html>",
        format: :heex,
        priority: 0,
        extra: %{},
        error_pages: [
          %{
            status: 404,
            template: "<h1>Page Not Found</h1><p>The page you requested could not be found.</p>",
            layout: %{template: "<div class='error-404'><%= @inner_content %></div>"}
          },
          %{
            status: 500,
            template: "<h1>Internal Server Error</h1><p>Something went wrong on our end.</p>",
            layout: %{template: "<div class='error-500'><%= @inner_content %></div>"}
          }
        ],
        helpers: [],
        active: true,
        precompile: false,
        site_id: nil
      ],
      # A SEED IS NOT AN AUTHOR. These four resources carry `helpers` (and a page carries `events`
      # and `infos` too), and `Validations.CodeChange` refuses those from a write with no actor. A
      # seed and a test fixture have no actor at all, so they announce what they are the same way the
      # kit installer does.
      context: %{page_code: :package},
      overrides: opts,
      tenant: tenant
    )
  end

  def js_hook(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.JsHook,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Hook #{&1}"),
        description: nil,
        content: "console.log('Test hook loaded');",
        format: :js,
        priority: 0,
        active: true,
        permissions: [],
        npm: [],
        modules: [],
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def page(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.Page,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Page #{&1}"),
        title: sequence(:title, &"Test Page #{&1}"),
        path: sequence(:path, &"/test-page-#{&1}"),
        section: "default",
        template: "<div class='page'><h1><%= @title %></h1><%= @content %></div>",
        description: sequence(:description, &"Test page description #{&1}"),
        format: :heex,
        priority: 0,
        extra: %{},
        content: %{title: "Test Title", body: "Test content"},
        seo_tags: [],
        schema: [],
        events: [],
        infos: [],
        resource_links: [],
        helpers: [],
        # EVERY ARRAY THIS RESOURCE HAS, PINNED — `uploads` was the one that was not. An attribute a
        # generator says nothing about is INVENTED by `Ash.Generator` from its type, so a fixture
        # page carried a random upload declaration, and `PageUpload.allow/2` refused it the moment
        # anything mounted that page through `RuntimeLive`:
        #
        #     invalid accept filter provided to allow_upload … Got: "\x{DAE66}"
        #
        # Random, so it failed on some runs and not others, and it named a page nobody had touched.
        # The same omission that made `precompile` a coin flip on the component factory.
        uploads: [],
        active: true,
        precompile: false,
        permissions: [],
        # And the create action's own argument: an unset one is invented too, as a random kind of
        # record written into `extra`. It follows the `extra` a caller gives instead.
        record: MishkaCmsCore.Runtime.Seo.record_of(opts[:extra]),
        layout_id: nil,
        # A new page is the English master of a group of its own — see
        # `MishkaCmsCore.Runtime.PageEditions`.
        language: "en",
        language_group_id: nil,
        site_id: nil
      ],
      # A SEED IS NOT AN AUTHOR. These four resources carry `helpers` (and a page carries `events`
      # and `infos` too), and `Validations.CodeChange` refuses those from a write with no actor. A
      # seed and a test fixture have no actor at all, so they announce what they are the same way the
      # kit installer does.
      context: %{page_code: :package},
      overrides: opts,
      tenant: tenant
    )
  end

  def user(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Accounts.User,
      :register_with_password,
      authorize?: false,
      defaults: [
        email: sequence(:email, &"user#{&1}@example.com"),
        password: "Password123!",
        password_confirmation: "Password123!"
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def permission(opts \\ []) do
    changeset_generator(
      MishkaCmsCore.Accounts.Permission,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"permission:#{&1}"),
        description: sequence(:description, &"Test permission #{&1}")
      ],
      overrides: opts
    )
  end

  def media_category(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.MediaCategory,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Media Category #{&1}"),
        description: sequence(:description, &"Test media category description #{&1}"),
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  # `relative_path` is still taken as an option, but handed on as the private `stored_path`: the
  # create does not accept the path as input, only from the code that stored the file.
  def media(opts \\ [], tenant \\ nil) do
    {stored_path, opts} =
      Keyword.pop_lazy(opts, :relative_path, fn ->
        sequence(:path, &"/uploads/media-#{&1}.jpg")
      end)

    changeset_generator(
      MishkaCmsCore.Runtime.Media,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Media #{&1}"),
        type: StreamData.member_of([:images, :videos, :documents]),
        size: StreamData.integer(1..10_000_000),
        format: StreamData.member_of(["jpg", "png", "gif", "mp4", "pdf", "doc"]),
        featured: false,
        dimensions: %{},
        description: sequence(:description, &"Test media description #{&1}"),
        site_id: nil,
        media_category_id: nil
      ],
      overrides: opts,
      private_arguments: %{stored_path: stored_path},
      tenant: tenant
    )
  end

  # ---------------------------------------------------------------------------
  # DEV generators (realistic data, used by dev seeds)
  # ---------------------------------------------------------------------------

  def dev_site(opts \\ []) do
    changeset_generator(
      MishkaCmsCore.Runtime.Site,
      :create,
      authorize?: false,
      defaults: [
        name:
          sequence(:site_name, fn i ->
            if i == 0, do: "localhost", else: "localhost#{i}"
          end),
        host:
          sequence(:site_host, fn i ->
            if i == 0, do: "localhost", else: "localhost#{i}"
          end),
        priority: StreamData.integer(0..100),
        active: true,
        master: false,
        mode: StreamData.member_of(["api_only", "phoenix_only", "hybrid"]),
        frontend_domain: nil,
        allowed_origins: []
      ],
      overrides: opts
    )
  end

  def dev_error_page(opts \\ [], tenant) do
    changeset_generator(
      MishkaCmsCore.Runtime.ErrorPage,
      :create,
      authorize?: false,
      defaults: [
        name:
          sequence(:error_page_name, fn i ->
            "Error Pages #{i}"
          end),
        path:
          StreamData.repeatedly(fn ->
            MishkaCmsCore.Runtime.ErrorAddress.for_site(tenant) ||
              MishkaCmsCore.Runtime.ErrorAddress.path("unknown")
          end),
        root_layout_template: nil,
        format: :heex,
        priority: StreamData.integer(0..100),
        extra: StreamData.repeatedly(fn -> generate_error_extra() end),
        error_pages: StreamData.repeatedly(fn -> generate_error_pages() end),
        helpers: [],
        active: true,
        precompile: StreamData.boolean()
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_layout_with_tenant(opts \\ [], tenant) do
    changeset_generator(
      MishkaCmsCore.Runtime.Layout,
      :create,
      authorize?: false,
      defaults: [
        name:
          sequence(:layout_name, fn i ->
            types = [
              "Blog",
              "Landing",
              "Dashboard",
              "Portfolio",
              "Shop",
              "News",
              "Gallery",
              "Contact"
            ]

            "#{Enum.random(types)} Layout #{i}"
          end),
        path:
          sequence(:layout_path, fn i ->
            "/layouts/#{Enum.random(["main", "blog", "landing", "admin", "shop", "news"])}-#{i}"
          end),
        description:
          StreamData.repeatedly(fn ->
            type = Enum.random(["modern", "classic", "minimal", "creative", "professional"])
            "A #{type} layout template with responsive design"
          end),
        template: StreamData.repeatedly(fn -> generate_layout_template() end),
        example: nil,
        format: :heex,
        priority: StreamData.integer(0..100),
        extra: StreamData.repeatedly(fn -> generate_layout_extra() end),
        content: StreamData.repeatedly(fn -> generate_layout_content() end),
        resource_links: StreamData.repeatedly(fn -> generate_resource_links() end),
        seo_tags: StreamData.repeatedly(fn -> generate_seo_tags() end),
        helpers: [],
        active: true,
        precompile: StreamData.boolean(),
        permissions: []
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_layout_global(opts \\ []) do
    changeset_generator(
      MishkaCmsCore.Runtime.Layout,
      :create,
      authorize?: false,
      defaults: [
        name:
          sequence(:global_layout_name, fn i ->
            types = [
              "Global Main",
              "Global Blog",
              "Global Landing",
              "Global Admin",
              "Global Shop",
              "Global News"
            ]

            "#{Enum.random(types)} Layout #{i}"
          end),
        path:
          sequence(:global_layout_path, fn i ->
            "/global/layouts/#{Enum.random(["main", "blog", "landing", "admin", "shop", "news"])}-#{i}"
          end),
        description:
          StreamData.repeatedly(fn ->
            type =
              Enum.random(["universal", "flexible", "adaptive", "responsive", "cross-platform"])

            "A #{type} global layout template for multi-site use"
          end),
        template: StreamData.repeatedly(fn -> generate_layout_template() end),
        example: nil,
        format: :heex,
        priority: StreamData.integer(0..100),
        extra: StreamData.repeatedly(fn -> generate_layout_extra() end),
        content: StreamData.repeatedly(fn -> generate_layout_content() end),
        resource_links: StreamData.repeatedly(fn -> generate_resource_links() end),
        seo_tags: StreamData.repeatedly(fn -> generate_seo_tags() end),
        helpers: [],
        active: true,
        precompile: StreamData.boolean(),
        permissions: []
      ],
      overrides: opts,
      tenant: nil
    )
  end

  def dev_page_with_layout(opts \\ [], tenant, layout_id) do
    changeset_generator(
      MishkaCmsCore.Runtime.Page,
      :create,
      authorize?: false,
      defaults: [
        name:
          sequence(:page_name, fn i ->
            types = [
              "Home",
              "About",
              "Services",
              "Contact",
              "Blog",
              "Portfolio",
              "News",
              "Gallery",
              "FAQ",
              "Privacy"
            ]

            "#{Enum.random(types)} Page #{i}"
          end),
        title: sequence(:page_title, &"Page #{&1}"),
        path:
          sequence(:page_path, fn i ->
            paths = [
              "/home",
              "/about",
              "/services",
              "/contact",
              "/blog",
              "/portfolio",
              "/news",
              "/gallery",
              "/faq",
              "/privacy"
            ]

            "#{Enum.random(paths)}-#{i}"
          end),
        section:
          StreamData.repeatedly(fn ->
            Enum.random(["main", "blog", "portfolio", "news", "help", "legal", "marketing"])
          end),
        template: StreamData.repeatedly(fn -> generate_page_template() end),
        description:
          StreamData.repeatedly(fn ->
            "A professionally designed page with modern layout and responsive design"
          end),
        format: :heex,
        priority: StreamData.integer(0..100),
        extra: StreamData.repeatedly(fn -> generate_page_extra() end),
        content: StreamData.repeatedly(fn -> generate_page_content(tenant) end),
        seo_tags: StreamData.repeatedly(fn -> generate_page_seo_tags() end),
        schema: StreamData.repeatedly(fn -> generate_page_schema() end),
        events: [],
        infos: [],
        resource_links: StreamData.repeatedly(fn -> generate_page_resource_links() end),
        helpers: [],
        uploads: [],
        active: true,
        precompile: StreamData.boolean(),
        permissions: [],
        record: nil,
        layout_id: layout_id,
        language: "en",
        language_group_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_page_without_layout(opts \\ [], tenant) do
    changeset_generator(
      MishkaCmsCore.Runtime.Page,
      :create,
      authorize?: false,
      defaults: [
        name:
          sequence(:standalone_page_name, fn i ->
            types = [
              "Landing",
              "Promo",
              "Special",
              "Campaign",
              "Event",
              "Standalone",
              "Independent"
            ]

            "#{Enum.random(types)} Page #{i}"
          end),
        title: sequence(:standalone_page_title, &"Standalone Page #{&1}"),
        path:
          sequence(:standalone_page_path, fn i ->
            paths = [
              "/landing",
              "/promo",
              "/special",
              "/campaign",
              "/event",
              "/standalone",
              "/independent"
            ]

            "#{Enum.random(paths)}-#{i}"
          end),
        section:
          StreamData.repeatedly(fn ->
            Enum.random(["standalone", "promo", "campaign", "special", "landing"])
          end),
        template: StreamData.repeatedly(fn -> generate_standalone_page_template() end),
        description:
          StreamData.repeatedly(fn ->
            "A standalone page with self-contained design and independent layout"
          end),
        format: :heex,
        priority: StreamData.integer(0..100),
        extra: StreamData.repeatedly(fn -> generate_page_extra() end),
        content: StreamData.repeatedly(fn -> generate_page_content(tenant) end),
        seo_tags: StreamData.repeatedly(fn -> generate_page_seo_tags() end),
        schema: StreamData.repeatedly(fn -> generate_page_schema() end),
        events: [],
        infos: [],
        resource_links: StreamData.repeatedly(fn -> generate_page_resource_links() end),
        helpers: [],
        uploads: [],
        active: true,
        precompile: StreamData.boolean(),
        permissions: [],
        record: nil,
        layout_id: nil,
        language: "en",
        language_group_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers — error pages
  # ---------------------------------------------------------------------------

  defp generate_error_extra do
    %{
      "theme" => "modern",
      "show_navigation" => false,
      "custom_css" => "/* Custom error page styles */",
      "analytics_tracking" => true
    }
  end

  defp generate_error_pages do
    [
      error_page_config(
        301,
        "indigo",
        "Moved Permanently",
        "This page has moved to a new location. Please update your bookmarks and head to the new URL.",
        ~s(<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"></path>),
        [
          {:primary, "/", "Continue to New Location"},
          {:secondary, "/", "Go Home"}
        ]
      ),
      error_page_config(
        400,
        "orange",
        "Bad Request",
        "The server couldn't understand your request. Check the URL or form data and try again.",
        ~s(<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01M5.07 19h13.86c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path>),
        [
          {:primary, "/", "Go Home"}
        ]
      ),
      error_page_config(
        401,
        "amber",
        "Unauthorized",
        "You need to sign in to access this page. Please log in with a valid account to continue.",
        ~s(<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m0 0v.01M6 21h12a2 2 0 002-2v-7a2 2 0 00-2-2H6a2 2 0 00-2 2v7a2 2 0 002 2zM16 10V7a4 4 0 10-8 0v3"></path>),
        [
          {:primary, "/login", "Sign In"},
          {:secondary, "/", "Go Home"}
        ]
      ),
      error_page_config(
        404,
        "blue",
        "Page Not Found",
        "We couldn't find the page you're looking for. It may have been moved, renamed, or no longer exists.",
        ~s(<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.172 16.172a4 4 0 015.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>),
        [
          {:primary, "/", "Go Home"}
        ]
      ),
      error_page_config(
        500,
        "red",
        "Internal Server Error",
        "Something went wrong on our end. Our team has been notified — please try again in a moment.",
        ~s(<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M12 2a10 10 0 100 20 10 10 0 000-20z"></path>),
        [
          {:primary, "/", "Go Home"},
          {:reload, nil, "Try Again"}
        ]
      )
    ]
  end

  defp error_page_config(status, color, title, description, icon_path, actions) do
    %{
      "status" => status,
      "template" => error_template(status, color, title, description, icon_path, actions),
      "layout" => nil
    }
  end

  defp error_template(status, color, title, description, icon_path, actions) do
    """
    <div class="min-h-screen flex items-center justify-center px-6 py-12 bg-gradient-to-br from-#{color}-50 via-white to-#{color}-100/60">
      <div class="w-full max-w-lg bg-white rounded-3xl shadow-2xl shadow-#{color}-600/10 ring-1 ring-#{color}-100 p-8 sm:p-12 text-center">
        <div class="inline-flex items-center justify-center w-24 h-24 rounded-full bg-#{color}-50 ring-8 ring-#{color}-100/50 mb-8">
          <svg class="w-12 h-12 text-#{color}-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            #{String.trim(icon_path)}
          </svg>
        </div>
        <p class="text-sm font-semibold tracking-widest uppercase text-#{color}-600 mb-3">Error #{status}</p>
        <h1 class="text-7xl sm:text-8xl font-black text-gray-900 mb-4 tracking-tight leading-none">#{status}</h1>
        <h2 class="text-2xl sm:text-3xl font-bold text-gray-900 mb-4">#{title}</h2>
        <p class="text-base sm:text-lg text-gray-600 mb-10 max-w-md mx-auto leading-relaxed">#{description}</p>
        <div class="flex flex-col sm:flex-row gap-3 justify-center">
          #{Enum.map_join(actions, "\n      ", &render_action(&1, color))}
        </div>
      </div>
    </div>
    """
  end

  defp render_action({:primary, href, label}, color) do
    ~s|<a href="#{href}" class="inline-flex items-center justify-center px-8 py-3 bg-#{color}-600 hover:bg-#{color}-700 text-white font-semibold rounded-xl transition-all duration-200 shadow-lg shadow-#{color}-600/20 hover:shadow-xl hover:-translate-y-0.5">#{label}</a>|
  end

  defp render_action({:secondary, href, label}, _color) do
    ~s|<a href="#{href}" class="inline-flex items-center justify-center px-8 py-3 bg-white hover:bg-gray-50 text-gray-700 font-semibold rounded-xl border-2 border-gray-200 hover:border-gray-300 transition-all duration-200">#{label}</a>|
  end

  defp render_action({:reload, _, label}, _color) do
    ~s|<a href={@conn.request_path} class="inline-flex items-center justify-center px-8 py-3 bg-white hover:bg-gray-50 text-gray-700 font-semibold rounded-xl border-2 border-gray-200 hover:border-gray-300 transition-all duration-200">#{label}</a>|
  end

  # ---------------------------------------------------------------------------
  # Private helpers — layouts
  # ---------------------------------------------------------------------------

  defp generate_layout_template do
    bg_color =
      Enum.random([
        "bg-white",
        "bg-gray-50",
        "bg-slate-50",
        "bg-zinc-50",
        "bg-neutral-50",
        "bg-stone-50"
      ])

    nav_color =
      Enum.random(["bg-white", "bg-gray-100", "bg-slate-100", "bg-blue-50", "bg-indigo-50"])

    footer_color = Enum.random(["bg-gray-900", "bg-slate-800", "bg-zinc-800", "bg-neutral-800"])

    """
    <body class="min-h-screen #{bg_color}">
      <nav class="#{nav_color} shadow-sm border-b">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex justify-between h-16">
            <div class="flex items-center">
              <h1 class="text-xl font-semibold text-gray-900">Site Name</h1>
            </div>
            <div class="flex items-center space-x-4">
              <a href="/" class="text-gray-600 hover:text-gray-900">Home</a>
              <a href="/about" class="text-gray-600 hover:text-gray-900">About</a>
              <a href="/contact" class="text-gray-600 hover:text-gray-900">Contact</a>
            </div>
          </div>
        </div>
      </nav>
      <main class="flex-1">
        <div class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
          <%= @inner_content %>
        </div>
      </main>
      <footer class="#{footer_color} text-white">
        <div class="max-w-7xl mx-auto py-8 px-4 sm:px-6 lg:px-8">
          <div class="grid md:grid-cols-3 gap-8">
            <div>
              <h3 class="text-lg font-semibold mb-4">About</h3>
              <p class="text-gray-300">Your website description here.</p>
            </div>
            <div>
              <h3 class="text-lg font-semibold mb-4">Links</h3>
              <ul class="space-y-2 text-gray-300">
                <li><a href="/privacy" class="hover:text-white">Privacy</a></li>
                <li><a href="/terms" class="hover:text-white">Terms</a></li>
              </ul>
            </div>
            <div>
              <h3 class="text-lg font-semibold mb-4">Contact</h3>
              <p class="text-gray-300">info@example.com</p>
            </div>
          </div>
          <div class="border-t border-gray-700 mt-8 pt-8 text-center text-gray-400">
            <p>&copy; 2024 Your Site. All rights reserved.</p>
          </div>
        </div>
      </footer>
    </body>
    """
  end

  defp generate_layout_extra do
    %{
      "layout_type" => Enum.random(["main", "blog", "landing", "admin", "shop"]),
      "css_framework" => "tailwind",
      "responsive" => true,
      "dark_mode_support" => Enum.random([true, false]),
      "accessibility" => %{
        "aria_labels" => true,
        "keyboard_navigation" => true,
        "screen_reader_friendly" => true
      },
      "performance" => %{
        "lazy_loading" => true,
        "optimized_images" => true,
        "minified_css" => true
      }
    }
  end

  defp generate_layout_content do
    %{
      "header" => %{
        "logo" => "Site Logo",
        "navigation" => ["Home", "About", "Services", "Contact"],
        "cta_button" => "Get Started"
      },
      "footer" => %{
        "links" => ["Privacy", "Terms", "Support"],
        "social" => ["Twitter", "Facebook", "LinkedIn"],
        "copyright" => "© 2024 Your Site. All rights reserved."
      },
      "sidebar" => %{
        "widgets" => ["recent_posts", "categories", "tags"],
        "position" => Enum.random(["left", "right"])
      }
    }
  end

  defp generate_resource_links do
    [
      %{"type" => "stylesheet", "href" => "https://cdn.tailwindcss.com", "rel" => "stylesheet"},
      %{
        "type" => "font",
        "href" =>
          "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap",
        "rel" => "stylesheet"
      },
      %{
        "type" => "script",
        "href" => "https://unpkg.com/alpinejs@3.x.x/dist/cdn.min.js",
        "attrs" => %{"defer" => true}
      }
    ]
  end

  defp generate_seo_tags do
    [
      %{
        "tag" => "meta",
        "attrs" => %{
          "name" => "description",
          "content" => "A modern website built with Elixir and Phoenix"
        },
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{
          "name" => "keywords",
          "content" => "elixir, phoenix, web development, modern"
        },
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{"property" => "og:title", "content" => "Your Site Name"},
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{"property" => "og:description", "content" => "A modern website description"},
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{"name" => "twitter:card", "content" => "summary_large_image"},
        "content" => nil
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Private helpers — pages
  # ---------------------------------------------------------------------------

  defp generate_page_template do
    content_type =
      Enum.random(["hero", "features", "testimonials", "contact", "about", "services"])

    case content_type do
      "hero" ->
        """
        <div class="bg-gradient-to-r from-blue-600 to-purple-600 text-white py-20">
          <div class="container mx-auto px-4 text-center">
            <h1 class="text-5xl font-bold mb-6"><%= @page_data.page.title || "Welcome to Our Site" %></h1>
            <button class="bg-white text-blue-600 px-8 py-3 rounded-lg font-semibold hover:bg-gray-100 transition-colors">Get Started</button>
          </div>
        </div>
        """

      "features" ->
        """
        <div class="py-16 bg-gray-50">
          <div class="container mx-auto px-4">
            <h2 class="text-3xl font-bold text-center mb-12"><%= @page_data.page.title || "Our Features" %></h2>
            <div class="grid md:grid-cols-3 gap-8">
              <div class="bg-white p-6 rounded-lg shadow-md">
                <h3 class="text-xl font-semibold mb-4">Feature One</h3>
                <p class="text-gray-600">Amazing feature description here.</p>
              </div>
              <div class="bg-white p-6 rounded-lg shadow-md">
                <h3 class="text-xl font-semibold mb-4">Feature Two</h3>
                <p class="text-gray-600">Another great feature description.</p>
              </div>
              <div class="bg-white p-6 rounded-lg shadow-md">
                <h3 class="text-xl font-semibold mb-4">Feature Three</h3>
                <p class="text-gray-600">Third amazing feature here.</p>
              </div>
            </div>
          </div>
        </div>
        """

      "contact" ->
        """
        <div class="py-16">
          <div class="container mx-auto px-4 max-w-2xl">
            <h2 class="text-3xl font-bold text-center mb-12"><%= @page_data.page.title || "Contact Us" %></h2>
            <form class="space-y-6">
              <div>
                <label class="block text-sm font-medium mb-2">Name</label>
                <input type="text" class="w-full px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500">
              </div>
              <div>
                <label class="block text-sm font-medium mb-2">Email</label>
                <input type="email" class="w-full px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500">
              </div>
              <div>
                <label class="block text-sm font-medium mb-2">Message</label>
                <textarea rows="4" class="w-full px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"></textarea>
              </div>
              <button type="submit" class="w-full bg-blue-600 text-white py-2 rounded-lg hover:bg-blue-700 transition-colors">Send Message</button>
            </form>
          </div>
        </div>
        """

      _ ->
        """
        <div class="py-16">
          <div class="container mx-auto px-4">
            <h1 class="text-4xl font-bold mb-8"><%= @page_data.page.title || "Page Title" %></h1>
            <div class="prose max-w-none">
              <p>This is a sample page with professional styling and layout.</p>
            </div>
          </div>
        </div>
        """
    end
  end

  defp generate_standalone_page_template do
    """
    <div class="container mx-auto px-4 py-16">
      <div class="bg-white rounded-2xl shadow-2xl p-8 max-w-4xl mx-auto">
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-gray-800 mb-4"><%= @page_data.page.title || "Standalone Page" %></h1>
        </div>
        <div class="grid md:grid-cols-2 gap-8">
          <div>
            <h2 class="text-2xl font-semibold mb-4">Content Area</h2>
            <button class="bg-purple-600 text-white px-6 py-3 rounded-lg hover:bg-purple-700 transition-colors">Take Action</button>
          </div>
          <div class="bg-gray-50 p-6 rounded-lg">
            <h3 class="text-xl font-semibold mb-4">Features</h3>
            <ul class="space-y-2">
              <li class="flex items-center"><span class="w-2 h-2 bg-purple-600 rounded-full mr-3"></span>Self-contained design</li>
              <li class="flex items-center"><span class="w-2 h-2 bg-purple-600 rounded-full mr-3"></span>No external layout needed</li>
              <li class="flex items-center"><span class="w-2 h-2 bg-purple-600 rounded-full mr-3"></span>Complete HTML structure</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp generate_page_extra do
    %{
      "page_type" => Enum.random(["standard", "landing", "blog", "portfolio", "contact"]),
      "theme" => Enum.random(["light", "dark", "colorful", "minimal"]),
      "analytics" => %{"track_views" => true, "track_interactions" => true},
      "cache_settings" => %{
        "ttl" => Enum.random([300, 600, 1800, 3600]),
        "cache_key" => "page_cache"
      }
    }
  end

  # THE PICTURES COME FROM THE SITE'S OWN LIBRARY. This named `/images/hero.jpg` and
  # `/images/feature.jpg`, neither of which is under `priv/static` in this project or any other, so a
  # template reading `@page_data.page.content["images"]` drew two broken pictures. A generator cannot
  # know what files exist; the site's media rows do, and `MishkaCmsCore.Dev.SeedMedia` puts real ones
  # there before any page is written. A site with no media seeded answers none, which is the honest
  # answer and what a fresh install looks like.
  defp generate_page_content(site_id) do
    images = MishkaCmsCore.Dev.SeedMedia.images(site_id)

    pictures =
      [:cover, :card]
      |> Enum.flat_map(&Map.get(images, &1, []))
      |> Enum.take(2)
      |> Enum.map(&%{"src" => &1, "alt" => "Seeded image"})

    %{
      "title" =>
        Enum.random(["Welcome", "About Us", "Our Services", "Contact", "Portfolio", "Blog"]),
      "subtitle" => "Professional web solutions for your business",
      "content" =>
        "This is the main content area with detailed information about our services and offerings.",
      "cta_text" => Enum.random(["Get Started", "Learn More", "Contact Us", "View Portfolio"]),
      "images" => pictures
    }
  end

  defp generate_page_seo_tags do
    [
      %{
        "tag" => "meta",
        "attrs" => %{
          "name" => "description",
          "content" => "Professional page with modern design and great user experience"
        },
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{
          "name" => "keywords",
          "content" => "web design, professional, modern, responsive"
        },
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{"property" => "og:title", "content" => "Professional Web Page"},
        "content" => nil
      }
    ]
  end

  defp generate_page_schema do
    [
      %{
        "@context" => "http://schema.org",
        "@type" => "WebPage",
        "name" => "Professional Web Page",
        "description" => "A professionally designed web page",
        "url" => "https://example.com"
      }
    ]
  end

  defp generate_page_resource_links do
    [
      %{"type" => "stylesheet", "href" => "https://cdn.tailwindcss.com", "rel" => "stylesheet"},
      %{
        "type" => "script",
        "href" => "https://unpkg.com/alpinejs@3.x.x/dist/cdn.min.js",
        "attrs" => %{"defer" => true}
      }
    ]
  end
end
