defmodule MishkaCmsCore.Install.StarterContent do
  @moduledoc """
  The site a first install answers with: a theme, a header, a footer, a layout, four pages and an
  error page, written through the ordinary create actions.

  ## Why it is plain HTML

  The installer lets the user deselect every UI component (`MishkaCmsCore.Install.Bootstrap`), so a
  starter page that drew `chelekom-card` would render the red "Component failed to render!" box on
  exactly the install that chose least. Everything below is HTML plus `<.link>` and `<.form>`, which
  a compiled page has whatever is installed — and NOT the host's `<.input>`, whose class names come
  from a CSS framework no bundle here ships.

  What the pages DO have is the site's own `:theme` stylesheet, so `bg-ground`, `text-ink`,
  `border-line` and the rest are real utilities in the site's bundle. That is the one dependency,
  and it is seeded here beside them.

  ## Why the dev seeds run it too

  `MishkaCmsCore.Dev.Seeds` gives every dev site this same base before it adds what that site exists
  to demonstrate, so the code a stranger's first install runs is the code this project's developers
  look at every day. A production path nobody opens is a production path nobody has seen.

  ## Running it again

  It writes ONLY WHAT IS MISSING, the rule the whole seeding surface follows: a row found by its
  name — the key the database keeps — is left exactly as it is, edits and all, and a page is asked
  about through `MishkaCmsCore.Runtime.PageProvision`, which knows that a held NAME and a held
  ADDRESS are two different answers. Nothing here updates.

  ## The addresses

  `/:lang`, `/:lang/about`, `/:lang/contact`, `/:lang/privacy` — the path mode
  `MishkaCmsCore.Runtime.Languages` validates, so `/en/about` answers and `/xyz/about` does not.
  None of them collides with a route this application answers itself. Each page answers every
  language the site publishes in (`PageProvision.serving_all_languages/1`).
  """

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    ErrorStatus,
    Layout,
    Page,
    PageProvision,
    Site,
    Stylesheet
  }

  require Ash.Query

  @section "starter"

  @row_limit 50

  # THE ADMIN PALETTE, as this site's own design tokens. Written as `@theme` rather than as a
  # hundred arbitrary hex values in the markup, because a site's CSS bundle only contains the
  # classes its own templates can be scanned for — and a token is one name the whole site shares.
  @theme_css ~S"""
  /* The MishkaCMS admin palette, as this site's own design tokens. */
  @theme {
    --color-ground: #f6f5f2;
    --color-ink: #1b1a18;
    --color-ink-soft: #57544d;
    --color-muted: #8a877f;
    --color-line: #ecebe6;
    --color-accent: #5b57d6;
    --color-ok: #1f9d6b;
    --color-warn: #cf8a24;
    --color-bad: #d5544b;
    --font-sans: "Manrope", ui-sans-serif, system-ui, sans-serif;
    --font-display: "Space Grotesk", ui-sans-serif, system-ui, sans-serif;
    --radius-card: 18px;
  }
  """

  # THE ERROR PAGE LINKS THE STYLESHEET RATHER THAN INLINING IT. A 404 is the response a site serves
  # most often and thinks about least — every dead link, every stale bookmark, every crawler — and
  # inlining put the whole bundle inside each one, uncached, when the same bytes already sit at a
  # content-addressed URL a visitor who arrived from a real page has.
  #
  # Inline only as the FALLBACK, for the window between boot and the site's first compile, when
  # there is no hash to link to and an unstyled error page is the worse failure. That fallback needs
  # the NONCE: `style-src-elem` names `'self'` and a nonce and nothing else, so a bare `<style>` is
  # refused and delivers exactly the unstyled page it exists to prevent — silently, because a
  # refused stylesheet raises nothing. Read through `[]`, so a conn that somehow missed the plug
  # renders unstyled rather than raising on the error page itself.
  #
  # Note `<%= %>` INSIDE the quotes: a root layout is compiled with classic EEx, so HEEx's
  # `href={...}` would be emitted to the page literally.
  @error_root_layout ~S"""
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="csrf-token" content="<%= Phoenix.Controller.get_csrf_token() %>" />
      <title><%= if @status == :offline, do: "Down for maintenance", else: "Error #{@status}" %></title>
      <link rel="stylesheet" href="/fonts/fonts.css" />
      <%= if @conn.assigns[:current_site] do %>
        <% css_href = MishkaCmsCore.Runtime.Compilers.Shared.site_css_href(@conn.assigns.current_site.name) %>
        <%= if css_href do %>
          <link rel="stylesheet" href="<%= css_href %>" />
        <% else %>
          <style nonce="<%= @conn.assigns[:csp_nonce] %>">
            <%= raw(MishkaCmsCore.Runtime.Compilers.TailwindCompiler.get_compiled_css(@conn.assigns.current_site.name)) %>
          </style>
        <% end %>
      <% end %>
    </head>
    <body class="antialiased">
      <%= @inner_content %>
    </body>
  </html>
  """

  @type report :: %{
          layout_id: String.t(),
          stylesheets: [String.t()],
          components: [String.t()],
          layouts: [String.t()],
          pages: [String.t()],
          error_pages: [String.t()],
          renamed_pages: [PageProvision.renamed()],
          skipped_pages: [PageProvision.held()]
        }

  @doc """
  Gives `site` the starter content it is missing, and returns what was written — plus `layout_id`,
  which is the `site-main` row whether this call wrote it or found it, so a caller adding pages of
  its own can hang them on the same layout.

  Takes the site record or its id. Options:

    * `:nav` — extra links for the header, as `[{label, path}]` where the path is what follows the
      language (`{"Pricing", "/pricing"}`). The dev seeds use it to reach the pages they add.
    * `:brand` — the name to print in the header and the footer. Defaults to the site's name, which
      the create action has slugified.
    * `:templates` — templates by starter page name (`%{"Home" => …, "About" => …}`), written in
      place of the installer's. The dev seeds give every site its own home, and `localhost` its own
      about.
    * `:root_layout_template` — the error page's root layout, for a caller that ships its own.

  Raises when the site is not there, or when a write is refused for any reason but a page being
  taken — the installer shows the failure on its own progress list.
  """
  @spec seed!(map() | String.t(), keyword()) :: report()
  def seed!(site, opts \\ [])

  def seed!(site_id, opts) when is_binary(site_id), do: site_id |> site!() |> seed!(opts)

  def seed!(%{id: site_id, name: site_name} = site, opts)
      when is_binary(site_id) and is_binary(site_name) do
    # THE NAME THE USER TYPED, not the one the database kept: `Site :create` slugifies `:name`, so a
    # site installed as "Acme Docs" is stored as `acme-docs` — the tenant key every component call
    # below is scoped by, and the last thing a visitor should read in the header.
    brand = Keyword.get(opts, :brand) || site_name

    # THE THEME BEFORE THE MARKUP THAT READS IT, and the components before the layout that draws
    # them: a layout compiled against a `site-header` that is not there renders the red
    # "Component failed to render!" box where the header should be and reports success.
    stylesheets = ensure_theme(site)
    components = ensure_components(site, brand)
    {layout, layouts} = ensure_layout(site, brand, Keyword.get(opts, :nav, []))

    %{created: created, renamed: renamed, skipped: skipped} =
      site_id
      |> PageProvision.missing(page_attrs(site, layout.id, brand, opts), stamp: :mishka_cms_core)
      |> PageProvision.create(&write_page!/1)

    %{
      layout_id: layout.id,
      stylesheets: stylesheets,
      components: components,
      layouts: layouts,
      pages: Enum.map(created, & &1.path),
      error_pages: ensure_error_page(site, Keyword.get(opts, :root_layout_template)),
      renamed_pages: renamed,
      skipped_pages: skipped
    }
  end

  defp page_attrs(%{id: site_id}, layout_id, brand, opts) do
    brand
    |> pages(Keyword.get(opts, :templates, %{}))
    |> Enum.map(fn definition ->
      %{
        name: definition.name,
        title: definition.title,
        path: definition.path,
        section: @section,
        description: definition.description,
        format: :heex,
        template: definition.template,
        active: true,
        layout_id: layout_id,
        site_id: site_id
      }
      |> PageProvision.serving_all_languages()
    end)
  end

  @doc """
  Gives `site`'s Error Page the offline entry a new site's gets, after the entries it holds, when it
  holds none. Answers `:added`, `:held` when it holds one, or `:no_error_page` when the site has no
  Error Page that is not archived.

  For the dev seeds, so a site seeded before the entry existed picks it up on the next run. The
  installer does not call it, so an entry an admin deleted is not handed back.
  """
  @spec ensure_offline_entry(map() | String.t()) :: :added | :held | :no_error_page
  def ensure_offline_entry(site_id) when is_binary(site_id),
    do: site_id |> site!() |> ensure_offline_entry()

  def ensure_offline_entry(%{id: site_id}) do
    ErrorPage
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> rows()
    |> List.first()
    |> add_offline_entry(site_id)
  end

  defp add_offline_entry(nil, _site_id), do: :no_error_page

  defp add_offline_entry(page, site_id) do
    if ErrorStatus.offline_entry?(page.error_pages) do
      :held
    else
      page
      |> Ash.Changeset.for_update(:update, %{error_pages: page.error_pages ++ [offline_status()]},
        tenant: site_id,
        authorize?: false
      )
      |> Ash.update!()

      :added
    end
  end

  @doc "The error page's default root layout, which links the site's compiled stylesheet."
  @spec error_root_layout() :: String.t()
  def error_root_layout, do: @error_root_layout

  # ---------------------------------------------------------------------------
  # The theme
  # ---------------------------------------------------------------------------

  @theme_name "site-theme"

  defp ensure_theme(%{id: site_id}) do
    if held?(Stylesheet, site_id, @theme_name) do
      []
    else
      Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: @theme_name,
          description: "This site's design tokens — colours, fonts and the card radius.",
          content: @theme_css,
          kind: :theme,
          format: :css,
          priority: 10,
          active: true,
          site_id: site_id
        },
        authorize?: false
      )
      |> Ash.create!()

      [@theme_name]
    end
  end

  # ---------------------------------------------------------------------------
  # The two components every page is framed by
  # ---------------------------------------------------------------------------

  # `brand` DEFAULTS TO THE SITE'S OWN NAME, written into the row as the attribute's default. That is
  # what makes the scoping visible without reading a database — the same `site-header` renders one
  # name on one site and another on the next.
  #
  # `lang` is passed IN rather than read here: a component is handed only the assigns its call site
  # writes, and the language of a response lives on the page. The layout reads it once and hands it
  # to both.
  defp ensure_components(%{id: site_id}, brand) do
    specs = components(brand)
    held = held_names(Component, site_id, Enum.map(specs, & &1.name))

    specs
    |> Enum.reject(&MapSet.member?(held, &1.name))
    |> Enum.map(fn spec ->
      Component
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: spec.name,
          description: spec.description,
          template: spec.template,
          format: :heex,
          type: "navigations",
          dependencies: [],
          attrs: spec.attrs,
          slots: spec.slots,
          priority: 0,
          active: true
        },
        tenant: site_id,
        authorize?: false
      )
      |> Ash.create!()

      spec.name
    end)
  end

  defp components(brand) do
    [
      %{
        name: "site-header",
        description: "The bar across the top of every page on #{brand}.",
        template: ~S"""
        <header class={["border-b border-line bg-white", @class]}>
          <div class="mx-auto flex w-full max-w-[1100px] flex-wrap items-center justify-between gap-4 px-6 py-4">
            <.link
              navigate={"/#{@lang}"}
              class="font-display text-[17px] font-bold tracking-[-0.03em] text-ink"
            >
              {@brand}
            </.link>
            <nav class="flex flex-wrap items-center gap-5 text-[13px] font-medium text-ink-soft">
              <.link navigate={"/#{@lang}/about"} class="hover:text-accent">About</.link>
              <.link navigate={"/#{@lang}/contact"} class="hover:text-accent">Contact</.link>
              {render_slot(@inner_block)}
            </nav>
          </div>
        </header>
        """,
        attrs: [
          brand_attr(brand, "The name shown on the left."),
          lang_attr(),
          class_attr("Extra classes for the header itself")
        ],
        slots: [slot("Extra links, placed after this site's own")]
      },
      %{
        name: "site-footer",
        description: "The strip along the bottom of every page on #{brand}.",
        template: ~S"""
        <footer class={["border-t border-line bg-white", @class]}>
          <div class="mx-auto flex w-full max-w-[1100px] flex-wrap items-center justify-between gap-4 px-6 py-8 text-[12.5px] text-muted">
            <p>© {@brand} — built with MishkaCMS</p>
            <div class="flex flex-wrap items-center gap-3">
              <.link navigate={"/#{@lang}/privacy"} class="hover:text-accent">Privacy</.link>
              <%!-- An `href`, not a `<.link navigate>`: `<html lang dir>` is drawn once per HTTP
                    response, so a live navigation into another language would keep the first
                    one's. --%>
              <a
                :for={edition <- @editions}
                href={edition.path}
                hreflang={edition.language}
                class="rounded-[6px] border border-line px-2 py-1 uppercase hover:text-accent"
              >
                {edition.language}
              </a>
              {render_slot(@inner_block)}
            </div>
          </div>
        </footer>
        """,
        attrs: [
          brand_attr(brand, "The name in the credit line."),
          lang_attr(),
          %{
            "name" => "editions",
            "type" => "any",
            "opts" => %{
              "default" => [],
              "doc" => "`@page_languages` — the same page in the site's other languages."
            }
          },
          class_attr("Extra classes for the footer itself")
        ],
        slots: [slot("Anything to put beside the language links")]
      }
    ]
  end

  defp brand_attr(brand, doc) do
    %{
      "name" => "brand",
      "type" => "string",
      "opts" => %{
        "default" => brand,
        "doc" => "#{doc} Defaults to the site this component belongs to."
      }
    }
  end

  defp lang_attr do
    %{
      "name" => "lang",
      "type" => "string",
      "opts" => %{"default" => "en", "doc" => "The language the links stay in."}
    }
  end

  defp class_attr(doc),
    do: %{"name" => "class", "type" => "any", "opts" => %{"default" => nil, "doc" => doc}}

  defp slot(doc),
    do: %{"name" => "inner_block", "attrs" => [], "opts" => %{"required" => false, "doc" => doc}}

  # ---------------------------------------------------------------------------
  # The layout
  # ---------------------------------------------------------------------------

  @layout_name "site-main"

  # EVERY PAGE TITLED ONE WAY, `About · Acme`: the page's own title — on a page that shows a record
  # per address, the record's — then the site's. Stored on the layouts, so a page's own title tag
  # still wins; a site with no title keeps the bare title, since an unfilled variable leaves the tag
  # out. See `MishkaCmsCore.Runtime.Seo`.
  @titled [%{tag: "title", attrs: %{}, content: "{{page.title}} · {{site.name}}"}]

  # THE LAYOUT SHOWS THE MESSAGES, so a page does not have to. A compiled page prepends a flash
  # region of its own only when its layout has none — see
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.shows_messages?/1` — and a site that styles
  # its own is the better place for them.
  #
  # NO `<body>`: this is rendered INSIDE the application's root layout, and a second one nests a
  # document in a document.
  defp ensure_layout(%{id: site_id, name: site_name}, brand, nav) do
    case held_row(Layout, site_id, @layout_name) do
      nil ->
        layout =
          Layout
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: @layout_name,
              path: "/layouts/site-main",
              description: "Header, messages, page, footer — every page on #{brand} sits in it.",
              template: layout_template(site_name, nav),
              seo_tags: @titled,
              format: :heex,
              helpers: [
                %{
                  name: "lang",
                  args: "assigns",
                  code: ~S/(assigns[:page] || %{})[:language] || "en"/
                }
              ],
              priority: 0,
              active: true
            },
            tenant: site_id,
            authorize?: false,
            context: %{page_code: :package}
          )
          |> Ash.create!()

        {layout, [@layout_name]}

      layout ->
        {layout, []}
    end
  end

  defp layout_template(site_name, nav) do
    ~s"""
    <div class="flex min-h-dvh flex-col bg-ground font-sans text-ink antialiased">
      <.component component_name="site-header" site="#{site_name}" lang={lang(assigns)}>#{nav_links(nav)}
      </.component>
      <div :if={@flash != %{}} id="site-flash" class="mx-auto mt-5 w-full max-w-[1100px] px-6">
        <p
          :for={{kind, message} <- @flash}
          id={"site-flash-\#{kind}"}
          role={if(kind == "error", do: "alert", else: "status")}
          phx-click="lv:clear-flash"
          phx-value-key={kind}
          title="Dismiss"
          class={[
            "cursor-pointer rounded-[10px] border px-4 py-3 text-[13px] font-medium",
            kind == "error" && "border-bad bg-white text-bad",
            kind != "error" && "border-ok bg-white text-ok"
          ]}
        >
          {message}
        </p>
      </div>
      <main class="mx-auto w-full max-w-[1100px] flex-1 px-6 py-10">{@inner_content}</main>
      <.component
        component_name="site-footer"
        site="#{site_name}"
        lang={lang(assigns)}
        editions={assigns[:page_languages] || []}
      />
    </div>
    """
  end

  defp nav_links(nav) do
    Enum.map_join(nav, "", fn {label, path} ->
      ~s"""

          <.link navigate={"/\#{lang(assigns)}#{path}"} class="hover:text-accent">#{label}</.link>\
      """
    end)
  end

  # ---------------------------------------------------------------------------
  # The pages
  # ---------------------------------------------------------------------------

  defp pages(brand, templates) do
    [
      %{
        name: "Home",
        title: "Home",
        path: "/:lang",
        description: "The first page a visitor sees.",
        template: home_template(brand)
      }
      | rest(brand)
    ]
    |> Enum.map(&%{&1 | template: Map.get(templates, &1.name, &1.template)})
  end

  defp home_template(brand) do
    ~s"""
    <section class="rounded-card border border-line bg-white px-8 py-14 text-center">
      <p class="text-[12px] font-bold uppercase tracking-[0.18em] text-accent">#{brand}</p>
      <h1 class="mt-3 font-display text-[38px] font-bold leading-[1.15] tracking-[-0.03em] text-ink">
        Your site starts here
      </h1>
      <p class="mx-auto mt-4 max-w-[560px] text-[15px] leading-relaxed text-ink-soft">
        These four pages were written by the installer. Open the dashboard, edit them in the
        builder, and publish when they say what you want them to say.
      </p>
      <div class="mt-7 flex flex-wrap items-center justify-center gap-3">
        <.link
          navigate={"/\#{@query_params["lang"]}/about"}
          class="rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
        >
          About this site
        </.link>
        <.link
          navigate={"/\#{@query_params["lang"]}/contact"}
          class="rounded-[9px] border border-line px-4 py-2 text-[12px] font-bold text-ink"
        >
          Get in touch
        </.link>
      </div>
    </section>

    <section class="mt-6 grid gap-5 md:grid-cols-3">
      <article
        :for={
          {title, body} <- [
            {"Pages, not templates",
             "Every address this site answers is a row you can edit, with its own history."},
            {"Components you own",
             "The header and footer above are this site's own components — change them once."},
            {"Compiled at runtime",
             "A published page compiles to a Phoenix module, so it is as fast as hand-written."}
          ]
        }
        class="rounded-card border border-line bg-white p-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
      >
        <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">{title}</h2>
        <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{body}</p>
      </article>
    </section>

    <section class="mt-6 flex flex-wrap items-center justify-between gap-4 rounded-card border border-line bg-white p-6">
      <div>
        <h2 class="font-display text-[20px] font-bold tracking-[-0.02em] text-ink">
          Ready to make it yours?
        </h2>
        <p class="mt-1 text-[13.5px] text-ink-soft">
          Sign in and open the page builder from the dashboard.
        </p>
      </div>
      <.link
        navigate={"/\#{@query_params["lang"]}/contact"}
        class="rounded-[9px] bg-accent px-4 py-2 text-[12px] font-bold text-white"
      >
        Contact us
      </.link>
    </section>
    """
  end

  defp rest(brand) do
    [
      %{
        name: "About",
        title: "About",
        path: "/:lang/about",
        description: "What this site is.",
        template: ~s"""
        <article class="rounded-card border border-line bg-white p-8">
          <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
            About #{brand}
          </h1>
          <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
            This page is here so you have something to edit. Replace it with who you are, what you
            make and why somebody should read on.
          </p>
          <dl class="mt-8 grid gap-5 sm:grid-cols-3">
            <div :for={
              {term, detail} <- [
                {"Runs on", "Elixir, Phoenix and the Ash Framework"},
                {"Edited in", "The page builder, on this same site"},
                {"Published", "When you say so, and not before"}
              ]
            }>
              <dt class="text-[11.5px] font-bold uppercase tracking-[0.14em] text-muted">{term}</dt>
              <dd class="mt-1 text-[13.5px] text-ink">{detail}</dd>
            </div>
          </dl>
          <p class="mt-8">
            <.link navigate={"/\#{@query_params["lang"]}"} class="text-[13px] font-bold text-accent">
              ← Back home
            </.link>
          </p>
        </article>
        """
      },
      %{
        name: "Contact",
        title: "Contact",
        path: "/:lang/contact",
        description: "A form that really submits, with errors and a confirmation.",
        # THE FIELDS ARE HAND-WRITTEN `<input>`s, not `<.input>`: the host's field component styles
        # itself with class names from a CSS framework this project ships no bundle for, so its
        # boxes would render as bare unstyled text. The form machinery reads a plain control's
        # `name` (and the `f[:key]` in its value) exactly as it reads a kit field's `field=`.
        template: ~S"""
        <div class="grid gap-6 md:grid-cols-[1.2fr_1fr]">
          <.form
            :let={f}
            id="contact-form"
            as={:contact}
            for={assigns[:contact_form]}
            phx-change="contact-k7m2q-validate"
            phx-submit="contact-k7m2q-submit"
            data-success="Thank you — we have your message."
            class="rounded-card border border-line bg-white p-7"
          >
            <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">
              Get in touch
            </h1>
            <p class="mt-2 text-[13.5px] text-ink-soft">
              Tell us what you need. Everything marked required has to be filled in.
            </p>

            <label for="contact-name" class="mt-6 block text-[12.5px] font-bold text-ink">Name</label>
            <input
              type="text"
              id="contact-name"
              name="contact[name]"
              value={f[:name].value}
              required
              minlength="2"
              maxlength="80"
              class="mt-1.5 w-full rounded-[9px] border border-line bg-white px-3 py-2 text-[13.5px] text-ink outline-none focus:border-accent"
            />
            <p :for={{message, _opts} <- form_errors(f[:name])} class="mt-1 text-[12px] text-bad">
              {message}
            </p>

            <label for="contact-email" class="mt-5 block text-[12.5px] font-bold text-ink">
              Email
            </label>
            <input
              type="email"
              id="contact-email"
              name="contact[email]"
              value={f[:email].value}
              required
              data-format="email"
              class="mt-1.5 w-full rounded-[9px] border border-line bg-white px-3 py-2 text-[13.5px] text-ink outline-none focus:border-accent"
            />
            <p :for={{message, _opts} <- form_errors(f[:email])} class="mt-1 text-[12px] text-bad">
              {message}
            </p>

            <label for="contact-message" class="mt-5 block text-[12.5px] font-bold text-ink">
              Message
            </label>
            <textarea
              id="contact-message"
              name="contact[message]"
              required
              minlength="10"
              maxlength="2000"
              rows="5"
              class="mt-1.5 w-full rounded-[9px] border border-line bg-white px-3 py-2 text-[13.5px] text-ink outline-none focus:border-accent"
            >{f[:message].value}</textarea>
            <p :for={{message, _opts} <- form_errors(f[:message])} class="mt-1 text-[12px] text-bad">
              {message}
            </p>

            <button
              type="submit"
              id="contact-submit"
              class="mt-6 rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white"
            >
              Send message
            </button>
          </.form>

          <aside class="rounded-card border border-line bg-white p-7">
            <h2 class="font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
              Other ways
            </h2>
            <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">
              Edit this panel in the builder and put your real address, your hours and anything else
              a visitor needs here.
            </p>
            <p class="mt-6 text-[13px]">
              <.link navigate={"/#{@query_params["lang"]}/privacy"} class="font-bold text-accent">
                How we handle what you send →
              </.link>
            </p>
          </aside>
        </div>
        """
      },
      %{
        name: "Privacy",
        title: "Privacy",
        path: "/:lang/privacy",
        description: "What the site does with what a visitor sends it.",
        template: ~S"""
        <article class="rounded-card border border-line bg-white p-8">
          <h1 class="font-display text-[26px] font-bold tracking-[-0.03em] text-ink">Privacy</h1>
          <p class="mt-4 text-[15px] leading-relaxed text-ink-soft">
            This is a placeholder, not legal advice. Say what you collect, why you collect it, how
            long you keep it and who you share it with — then delete this sentence.
          </p>
          <section :for={
            {heading, body} <- [
              {"What we collect",
               "Whatever the contact form asks for, and nothing the site has not asked you for."},
              {"Why we keep it", "To answer you. Say here how long that is."},
              {"Who else sees it", "Name every service the message passes through."}
            ]
          }>
            <h2 class="mt-7 font-display text-[17px] font-bold tracking-[-0.02em] text-ink">
              {heading}
            </h2>
            <p class="mt-2 text-[13.5px] leading-relaxed text-ink-soft">{body}</p>
          </section>
          <p class="mt-8">
            <.link navigate={"/#{@query_params["lang"]}"} class="text-[13px] font-bold text-accent">
              ← Back home
            </.link>
          </p>
        </article>
        """
      }
    ]
  end

  defp write_page!(attrs) do
    Page
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # The error page
  # ---------------------------------------------------------------------------

  # ONE ERROR PAGE PER SITE — `unique_path_per_site` is what says so, because its path is the site's
  # own address rather than one somebody chose. So the question a second run asks is not "is this row
  # there" but "does this site have one at all", and a site that does keeps it. An archived one
  # counts, or an admin who threw theirs away would be handed it again.
  defp ensure_error_page(%{id: site_id, name: site_name}, root_layout) do
    if held_count(ErrorPage, site_id) == 0 do
      name = "#{site_name} errors"

      ErrorPage
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: name,
          root_layout_template: root_layout || @error_root_layout,
          format: :heex,
          error_pages: [
            error_status(404, "Not here"),
            error_status(500, "Something broke"),
            offline_status()
          ],
          priority: 0,
          active: true
        },
        tenant: site_id,
        authorize?: false
      )
      |> Ash.create!()

      [name]
    else
      []
    end
  end

  defp error_status(status, title) do
    %{
      status: status,
      layout: %{
        template:
          ~s|<div class="flex min-h-dvh items-center justify-center bg-ground font-sans p-6"><%= @inner_content %></div>|
      },
      template: ~s"""
      <div class="w-full max-w-[520px] rounded-[18px] border border-[#ecebe6] bg-white p-10 text-center">
        <p class="font-display text-[46px] font-bold tracking-[-0.03em] text-[#1b1a18]">#{status}</p>
        <h1 class="mt-2 font-display text-[20px] font-bold tracking-[-0.02em] text-[#1b1a18]">#{title}</h1>
        <p class="mt-3 text-[13.5px] text-[#57544d]">
          #{error_body(status)}
        </p>
        <a href="/en" class="mt-7 inline-block rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white">
          Back home
        </a>
      </div>
      """
    }
  end

  # THE PAGE AN OFFLINE SITE SHOWS, the site's own to reword like its 404 and 500. Without it the
  # gate draws its built-in page, which knows nothing of the site's look. It offers the site's own
  # sign-in, because the admin who can bring the site back is the one reading it.
  defp offline_status do
    %{
      status: :offline,
      layout: %{
        template:
          ~s|<div class="flex min-h-dvh items-center justify-center bg-ground font-sans p-6"><%= @inner_content %></div>|
      },
      template: ~s"""
      <div class="w-full max-w-[520px] rounded-[18px] border border-[#ecebe6] bg-white p-10 text-center">
        <h1 class="font-display text-[26px] font-bold tracking-[-0.02em] text-[#1b1a18]">Down for maintenance</h1>
        <p class="mt-3 text-[13.5px] text-[#57544d]">
          We are making some changes to this site. Please check back soon.
        </p>
        <a href="/auth?master_user=false" class="mt-7 inline-block rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white">
          Administrator sign in
        </a>
      </div>
      """
    }
  end

  defp error_body(404), do: "That address is not one this site answers."
  defp error_body(_status), do: "The site could not finish that request. Please try again."

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  # AN ARCHIVED ROW COUNTS AS PRESENT, here as everywhere in the seeding surface: archiving it is
  # what the admin said about it, and handing it back on the next run would be an argument.
  defp held_names(resource, site_id, names) do
    for action <- [:read_any, :master_archived],
        row <-
          resource
          |> Ash.Query.for_read(action, %{}, authorize?: false)
          |> Ash.Query.filter(name in ^names and site_id == ^site_id)
          |> Ash.Query.select([:name])
          |> rows(),
        into: MapSet.new(),
        do: row.name
  end

  defp held?(resource, site_id, name),
    do: MapSet.member?(held_names(resource, site_id, [name]), name)

  defp held_row(resource, site_id, name) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name and site_id == ^site_id)
    |> rows()
    |> List.first()
  end

  defp held_count(resource, site_id) do
    Enum.sum(
      for action <- [:read_any, :master_archived] do
        resource
        |> Ash.Query.for_read(action, %{}, authorize?: false)
        |> Ash.Query.filter(site_id == ^site_id)
        |> Ash.Query.select([:id])
        |> rows()
        |> length()
      end
    )
  end

  defp rows(query) do
    query |> Ash.read!(authorize?: false, page: [limit: @row_limit]) |> Map.fetch!(:results)
  end

  defp site!(site_id) do
    case find_site(site_id) do
      nil -> raise ArgumentError, "no site #{site_id}"
      site -> site
    end
  end

  defp find_site(site_id) do
    Site
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^site_id)
    |> Ash.read_one!(authorize?: false)
  end
end
