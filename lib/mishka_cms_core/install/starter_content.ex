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

  ## The sign-in pages

  `ensure_auth!/1` gives a site the `auth` layout and one page per sign-in flow, whatever else the
  site holds. Every site gets them: the installer, the dev seeds and a site created in the admin
  (the `"provision"` job of `MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker`) all call it. Each
  page answers every language of the site and is marked in `extra`:

    * `"auth_role"` — which flow the page is: `sign_in`, `register`, `forgot_password`,
      `magic_link`, `password_reset`, `confirm_new_user`, `magic_link_sign_in` or `sign_out`
    * `"visitors_only"` — `true` on every page but `sign_out`, so a signed-in visitor is sent away
    * `"signed_in_only"` — `true` on `sign_out` alone, so a visitor who is not signed in is sent to
      the sign-in page

  | Path                                  | Role                 |
  | ------------------------------------- | -------------------- |
  | `/:lang/auth`                         | `sign_in`            |
  | `/:lang/auth/register`                | `register`           |
  | `/:lang/auth/forgot-password`         | `forgot_password`    |
  | `/:lang/auth/magic-link`              | `magic_link`         |
  | `/:lang/auth/password-reset/:token`   | `password_reset`     |
  | `/:lang/auth/confirm-new-user/:token` | `confirm_new_user`   |
  | `/:lang/auth/magic-link/:token`       | `magic_link_sign_in` |
  | `/:lang/auth/sign-out`                | `sign_out`           |

  The pages read these assigns besides the ones every runtime page has: `current_tenant` (the site
  a form signs into, `nil` for a master), `client_request` (`%{remote_ip: String.t() | nil}`, what
  the rate limits count), `query_params["token"]` on the token pages and
  `query_params["return_to"]`, carried on when `MishkaCmsCoreWeb.ReturnTo.verify/2` accepts it.

  Every word goes through `t/1`, so a page answers in any language the site publishes in. A language
  with built-in words (Persian today) gets a row for each of them; any other reads the English until
  its rows are filled in on the Translations screen.

  ## Events

    * `runtime:site:before_auth_pages` — `%{site_id: site_id, site_name: site_name}`, before the
      sign-in content is written.
    * `runtime:site:after_auth_pages` — the report `ensure_auth!/1` returns, with `site_id`.
  """

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    ErrorStatus,
    Languages,
    Layout,
    Page,
    PageProvision,
    Site,
    Stylesheet,
    Translation
  }

  alias MishkaInstaller.Event.Hook

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

  @type auth_report :: %{
          layout_id: String.t(),
          layouts: [String.t()],
          pages: [String.t()],
          renamed_pages: [PageProvision.renamed()],
          skipped_pages: [PageProvision.held()],
          translations: non_neg_integer()
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

  @doc """
  Gives `site` the sign-in content it is missing — the built-in words for each language the site
  publishes in that has them (Persian today), the `auth` layout and the eight sign-in pages — and
  returns what was written. `layout_id` is
  the `auth` layout whether this call wrote it or found it.

  Takes the site record or its id. A row found is left exactly as it is: a page held at its path is
  reported in `skipped_pages`, one whose name only is taken is written under the next free name and
  reported in `renamed_pages`, and a translation row that exists keeps its value.

  Raises when the site is not there, or when a write is refused for any reason but a row being
  taken. See `ensure_auth/1` for the answer a job reads.
  """
  @spec ensure_auth!(map() | String.t()) :: auth_report()
  def ensure_auth!(site_id) when is_binary(site_id), do: site_id |> site!() |> ensure_auth!()

  def ensure_auth!(%{id: site_id, name: site_name} = site)
      when is_binary(site_id) and is_binary(site_name) do
    Hook.call("runtime:site:before_auth_pages", %{site_id: site_id, site_name: site_name},
      return: false
    )

    # THE WORDS BEFORE THE PAGES: saving a page registers an empty row for every word it asks for,
    # and a row that exists is never written over.
    translations = ensure_auth_translations(site)
    {layout, layouts} = ensure_auth_layout(site)

    %{created: created, renamed: renamed, skipped: skipped} =
      site_id
      |> PageProvision.missing(auth_page_attrs(site_id, layout.id), stamp: :mishka_cms_core)
      |> PageProvision.create(&write_auth_page!/1)

    report = %{
      layout_id: layout.id,
      layouts: layouts,
      pages: Enum.map(created, & &1.path),
      renamed_pages: renamed,
      skipped_pages: skipped,
      translations: translations
    }

    Hook.call("runtime:site:after_auth_pages", Map.put(report, :site_id, site_id), return: false)

    report
  end

  @doc """
  `ensure_auth!/1`, answering `{:error, :site_not_found}` for a site that is not there instead of
  raising. Any other refusal still raises.
  """
  @spec ensure_auth(map() | String.t()) :: {:ok, auth_report()} | {:error, :site_not_found}
  def ensure_auth(site_id) when is_binary(site_id) do
    case find_site(site_id) do
      nil -> {:error, :site_not_found}
      site -> {:ok, ensure_auth!(site)}
    end
  end

  def ensure_auth(%{id: _site_id} = site), do: {:ok, ensure_auth!(site)}

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
  # The sign-in pages
  # ---------------------------------------------------------------------------

  @auth_layout_name "auth"
  @auth_layout_path "/layouts/auth"
  @auth_section "auth"

  # OUT OF EVERY INDEX: a sign-in page is a door, not content.
  @unindexed [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, nofollow"}]

  @input_class "h-[46px] w-full rounded-[12px] border border-[#ecebe6] bg-[#faf9f6] text-[13.5px] font-medium text-[#1b1a18] outline-none placeholder:text-[#a8a5a0] focus:border-[#c3c1f0] focus:bg-white focus:shadow-[0_0_0_3px_rgba(91,87,214,0.1)]"
  @cta_class "flex h-12 w-full items-center justify-center rounded-[13px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-[13.5px] font-bold text-white shadow-[0_6px_18px_rgba(79,75,204,0.3)] hover:opacity-95 disabled:cursor-not-allowed disabled:opacity-50"
  @back_class "mb-5 inline-flex h-8 items-center gap-[7px] rounded-[9px] border border-[#ecebe6] bg-white pl-2 pr-[11px] text-[11.5px] font-semibold text-[#5c5a54] hover:bg-[#f7f6f3]"
  @eye_button_class "absolute right-2 top-1/2 flex size-[30px] -translate-y-1/2 items-center justify-center rounded-lg text-[#a8a5a0] hover:bg-[#f2f1ec] hover:text-[#5c5a54]"
  @icon_left_class "pointer-events-none absolute left-[13px] top-1/2 flex -translate-y-1/2 text-[#a8a5a0]"
  @title_class "m-0 font-['Newsreader'] text-[32px] font-medium leading-[1.05] tracking-[-0.015em] text-[#17161a] max-[620px]:text-[27px]! max-[380px]:text-[24px]!"
  @lede_class "mt-[9px] text-[13.5px] font-medium text-[#6d6a63]"
  @label_class "text-[12px] font-semibold text-[#3a382f]"
  @error_class "mt-[7px] text-[10.5px] font-semibold text-[#c0473d]"
  @link_class "text-[11.5px] font-semibold text-[#4f4bcc] hover:text-[#3a37a8]"
  @alert_class "mb-4 flex items-start gap-2.5 rounded-[12px] border border-[#f5dcd8] bg-[#fdf3f1] px-[13px] py-[11px]"
  @dashed_class "mt-[10px] flex h-11 w-full items-center justify-center gap-2 rounded-[12px] border border-dashed border-[#d9d7d0] bg-white text-[12.5px] font-bold text-[#4f4bcc] hover:border-[#5b57d6] hover:bg-[#faf9ff]"
  @spinner_class "size-[15px] animate-spin rounded-full border-2 border-white/35 border-t-white"

  # EVERY LANGUAGE THE SITE PUBLISHES IN that `auth_words/0` holds words for; English is the key
  # itself, and a language with no words reads the English until its rows are filled in. A row the
  # site holds keeps its value.
  defp ensure_auth_translations(%{id: site_id}) do
    site_id
    |> Languages.site()
    |> Enum.flat_map(fn language ->
      words = Map.get(auth_words(), language, %{})
      held = held_translations(site_id, language, Map.keys(words))

      for {key, value} <- words,
          not MapSet.member?(held, key),
          do: %{key: key, language: language, value: value, site_id: site_id}
    end)
    |> write_translations!()
  end

  defp held_translations(site_id, language, keys) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and language == ^language and key in ^keys)
    |> Ash.Query.select([:key])
    |> Ash.read!(authorize?: false, page: false)
    |> MapSet.new(& &1.key)
  end

  defp write_translations!([]), do: 0

  # AN UPSERT THAT CHANGES NOTHING, so a row another run wrote in between keeps its value.
  defp write_translations!(rows) do
    Ash.bulk_create!(rows, Translation, :master_create,
      authorize?: false,
      upsert?: true,
      upsert_identity: :unique_translation,
      upsert_fields: [],
      return_errors?: true,
      stop_on_error?: true,
      notify?: true
    )

    length(rows)
  end

  # THE ROW AT THE NAME OR AT THE PATH, because either one refuses a second.
  defp ensure_auth_layout(%{id: site_id}) do
    case held_auth_layout(site_id) do
      nil -> create_auth_layout(site_id)
      layout -> {layout, []}
    end
  end

  defp create_auth_layout(site_id) do
    Layout
    |> Ash.Changeset.for_create(:create, auth_layout_attrs(),
      tenant: site_id,
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.create()
    |> case do
      {:ok, layout} -> {layout, [@auth_layout_name]}
      {:error, error} -> {taken_auth_layout!(site_id, error), []}
    end
  end

  # ANOTHER RUN WROTE IT BETWEEN THE READ AND THE CREATE: a unique index refused this one, so the
  # row it holds is the one the pages hang on. Any other refusal is raised.
  defp taken_auth_layout!(site_id, error) do
    with true <- unique_refusal?(error),
         %Layout{} = layout <- held_auth_layout(site_id) do
      layout
    else
      _not_taken -> raise error
    end
  end

  defp held_auth_layout(site_id) do
    name = @auth_layout_name
    path = @auth_layout_path

    Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and (name == ^name or path == ^path))
    |> rows()
    |> Enum.sort_by(&(&1.name != name))
    |> List.first()
  end

  defp unique_refusal?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, fn error ->
      Keyword.get(Map.get(error, :private_vars) || [], :constraint_type) == :unique
    end)
  end

  defp unique_refusal?(_error), do: false

  defp auth_layout_attrs do
    %{
      name: @auth_layout_name,
      path: @auth_layout_path,
      description:
        "The frame of every sign-in page: the form pane, the brand panel and the messages.",
      template: auth_layout_template(),
      format: :heex,
      helpers:
        Enum.map(
          ~w(moon_svg sun_svg shield_svg lock_svg globe_svg feature_svg quotes),
          &auth_helper/1
        ),
      seo_tags: @unindexed ++ @titled,
      precompile: true,
      priority: 0,
      active: true
    }
  end

  defp auth_page_attrs(site_id, layout_id) do
    Enum.map(auth_pages(), fn page ->
      %{
        name: page.name,
        title: page.title,
        path: page.path,
        section: @auth_section,
        description: page.description,
        format: :heex,
        template: page.template,
        events: Enum.map(page.events, &auth_event/1),
        helpers: Enum.map(page.helpers, &auth_helper/1),
        seo_tags: @unindexed,
        precompile: true,
        permissions: [],
        active: true,
        layout_id: layout_id,
        site_id: site_id,
        extra: auth_extra(page.role)
      }
      |> PageProvision.serving_all_languages()
    end)
  end

  # SIGNING OUT IS FOR SOMEBODY SIGNED IN; every other flow is for a visitor.
  defp auth_extra("sign_out" = role), do: %{"auth_role" => role, "signed_in_only" => true}
  defp auth_extra(role), do: %{"auth_role" => role, "visitors_only" => true}

  # CODE A PACKAGE SHIPS: a write with no actor and no `page_code: :package` has its Elixir refused.
  defp write_auth_page!(attrs) do
    Page
    |> Ash.Changeset.for_create(:master_create, attrs,
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.create!()
  end

  @navigation ~w(flow_path return_params)
  # What a refused sign-in form says: a captcha not passed, a rate limit, or a way in the site has
  # closed.
  @rate_limit ~w(refused_or captcha_message rate_limited rate_limit_message gate_message)

  defp auth_pages do
    [
      %{
        name: "Auth sign in",
        title: "Sign in",
        path: "/:lang/auth",
        role: "sign_in",
        description: "Sign in with an email and a password.",
        template: sign_in_template(),
        events: ~w(sign_in second_factor_mode),
        helpers:
          @navigation ++
            ~w(password_strategy build_form sign_in_form code_step_form sign_in_action token_path) ++
            @rate_limit ++
            ~w(second_factor_message) ++
            ~w(filled_svg mail_svg lock_svg eye_svg eye_off_svg arrow_right_svg bolt_svg alert_svg) ++
            ~w(chevron_left_svg shield_svg)
      },
      %{
        name: "Auth register",
        title: "Create account",
        path: "/:lang/auth/register",
        role: "register",
        description: "Create an account with an email and a password.",
        template: register_template(),
        events: ~w(register validate_register toggle_register_password),
        helpers:
          @navigation ++
            ~w(password_strategy build_form register_form register_action token_path) ++
            @rate_limit ++
            ~w(password_rules password_score strength_label strength_text strength_bar) ++
            ~w(confirm_state chevron_left_svg alert_svg mail_svg lock_svg eye_svg eye_off_svg) ++
            ~w(tick_svg cross_svg)
      },
      %{
        name: "Auth forgot password",
        title: "Reset your password",
        path: "/:lang/auth/forgot-password",
        role: "forgot_password",
        description: "Ask for a link that sets a new password.",
        template: forgot_password_template(),
        events: ["request_reset"],
        helpers:
          @navigation ++
            ~w(password_strategy build_form reset_form sent) ++
            @rate_limit ++ ~w(chevron_left_svg lock_alert_svg alert_svg tick_svg mail_svg)
      },
      %{
        name: "Auth magic link",
        title: "Sign in without a password",
        path: "/:lang/auth/magic-link",
        role: "magic_link",
        description: "Ask for a single-use link that signs in.",
        template: magic_link_template(),
        events: ~w(request_magic_link resend_magic_link),
        helpers:
          @navigation ++
            ~w(magic_link_strategy build_form magic_form sent) ++
            @rate_limit ++ ~w(chevron_left_svg bolt_svg alert_svg tick_svg mail_svg)
      },
      %{
        name: "Auth password reset",
        title: "Reset your password",
        path: "/:lang/auth/password-reset/:token",
        role: "password_reset",
        description: "Set a new password from the link in the reset email.",
        template: password_reset_template(),
        events: [],
        helpers: @navigation ++ ~w(chevron_left_svg lock_alert_svg)
      },
      %{
        name: "Auth confirm new user",
        title: "Confirm your account",
        path: "/:lang/auth/confirm-new-user/:token",
        role: "confirm_new_user",
        description: "Confirm a new account from the link in the confirmation email.",
        template: confirm_new_user_template(),
        events: [],
        helpers: @navigation ++ ~w(chevron_left_svg shield_svg)
      },
      %{
        name: "Auth magic link sign in",
        title: "Magic sign in",
        path: "/:lang/auth/magic-link/:token",
        role: "magic_link_sign_in",
        description: "Finish signing in from the link in the magic link email.",
        template: magic_link_sign_in_template(),
        events: [],
        helpers: @navigation ++ ~w(chevron_left_svg bolt_svg)
      },
      %{
        name: "Auth sign out",
        title: "Sign out",
        path: "/:lang/auth/sign-out",
        role: "sign_out",
        description: "Confirm signing out.",
        template: sign_out_template(),
        events: [],
        helpers: ~w(sign_out_svg arrow_right_svg chevron_left_svg)
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # The sign-in layout and templates
  # ---------------------------------------------------------------------------

  # THE QUOTE PICKER IS JS: all three quotes are drawn and two are hidden, because a click the page
  # has no handler for is answered by nothing.
  defp auth_layout_template do
    ~s"""
    <div class="grid min-h-dvh grid-cols-[minmax(0,1fr)_480px] bg-[#f6f5f2] font-[Manrope,ui-sans-serif,system-ui,sans-serif] text-[#1b1a18] antialiased max-[1080px]:grid-cols-[minmax(0,1fr)]! [@media(max-height:780px)]:h-dvh [@media(max-height:780px)]:overflow-hidden [[data-theme=dark]_&]:[filter:invert(0.92)_hue-rotate(180deg)] [[data-theme=dark]_&]:[transition:filter_.3s_ease]">
      <div class="relative flex min-w-0 flex-col overflow-y-auto overflow-x-hidden px-10 pb-10 pt-[34px] [scrollbar-color:#cfcdc6_transparent] [scrollbar-width:thin] max-[1080px]:px-7! max-[1080px]:pb-[30px]! max-[1080px]:pt-[26px]! max-[620px]:px-4! max-[620px]:pb-[22px]! max-[620px]:pt-[18px]! [&::-webkit-scrollbar-thumb]:rounded [&::-webkit-scrollbar-thumb]:bg-[#cfcdc6] [&::-webkit-scrollbar]:size-2">
        <span class="pointer-events-none absolute bottom-0 -right-[90px] z-0 block size-[360px] opacity-[0.035] max-[620px]:-right-[70px]! max-[620px]:size-[260px]!">
          <img src="/images/mishka-logo.svg" alt="" class="block size-full" />
        </span>

        <div class="relative z-[1] mb-auto flex items-center gap-3">
          <img src="/images/mishka-logo.svg" alt="MishkaCMS" class="block size-[30px] shrink-0" />
          <span class="font-['Space_Grotesk'] text-[15px] font-extrabold tracking-[-0.02em] text-[#17161a]">
            MishkaCMS
          </span>
          <span class="flex-1"></span>
          <button
            type="button"
            id="auth-theme-dark"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="dark"
            title={t("Switch to dark")}
            class="flex size-[34px] items-center justify-center rounded-[10px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3] [[data-theme=dark]_&]:hidden"
          >
            <.moon_svg />
          </button>
          <button
            type="button"
            id="auth-theme-light"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="light"
            title={t("Switch to light")}
            class="hidden size-[34px] items-center justify-center rounded-[10px] border border-[#ecebe6] bg-white text-[#c8931f] hover:bg-[#f7f6f3] [[data-theme=dark]_&]:flex"
          >
            <.sun_svg />
          </button>
        </div>

        <div class="relative z-[1] flex justify-center py-9 max-[620px]:py-[22px]! [@media(max-height:680px)]:py-3 [@media(max-height:780px)]:py-5">
          <div class="w-full max-w-[420px] transition-[opacity,transform] duration-[350ms] ease-[cubic-bezier(0.2,0.7,0.3,1)] starting:translate-y-2 starting:opacity-0">
            {@inner_content}
          </div>
        </div>

        <div class="relative z-[1] mt-auto flex flex-wrap items-center gap-[14px] text-[11.5px] font-semibold text-[#6d6a63] max-[620px]:justify-center!">
          <span>© {Date.utc_today().year} MishkaCMS</span>
          <span class="flex-1 max-[620px]:hidden!"></span>
          <.link href="/mish-cms/extensions/documentation" class="hover:text-[#4f4bcc]">
            {t("Docs")}
          </.link>
          <.link href="/mish-hire-us" class="hover:text-[#4f4bcc]">{t("Support")}</.link>
        </div>
      </div>

      <aside class="relative flex min-w-0 flex-col overflow-hidden bg-[linear-gradient(155deg,#211f28,#17161a_55%,#1c1a24)] px-[38px] py-10 max-[1080px]:hidden! [[data-theme=dark]_&]:border [[data-theme=dark]_&]:border-[#232228] [[data-theme=dark]_&]:bg-[#141317] [[data-theme=dark]_&]:bg-none [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]">
        <span class="pointer-events-none absolute -right-[70px] top-1/2 block size-[420px] -translate-y-1/2 opacity-[0.05]">
          <img
            src="/images/mishka-logo.svg"
            alt=""
            class="block size-full invert [[data-theme=dark]_&]:invert-0"
          />
        </span>

        <div class="relative flex items-center gap-[14px]">
          <img
            src="/images/mishka-logo.svg"
            alt=""
            class="block size-[38px] shrink-0 invert [[data-theme=dark]_&]:invert-0"
          />
          <span class="h-[26px] w-px shrink-0 bg-white/15"></span>
          <div class="min-w-0">
            <div class="font-['Space_Grotesk'] text-[13px] font-extrabold tracking-[-0.01em] text-white">
              MishkaCMS
            </div>
            <div class="mt-[3px] flex items-center gap-1.5">
              <span class="relative flex shrink-0 size-1.5">
                <span class="absolute inline-flex size-full animate-ping rounded-full opacity-60 bg-[#4ec08d]">
                </span>
                <span class="relative inline-flex size-full rounded-full bg-[#4ec08d]"></span>
              </span>
              <span class="text-[9.5px] font-semibold uppercase tracking-[0.09em] text-[#8ee0b8]">
                {t("All systems operational")}
              </span>
            </div>
          </div>
        </div>

        <div class="relative my-auto">
          <div class="font-['Newsreader'] text-[27px] font-medium leading-[1.25] tracking-[-0.01em] text-white">
            {t("Everything your site needs, in one place.")}
          </div>
          <p class="mt-[14px] max-w-[340px] text-[13px] font-medium leading-[1.65] text-[#9795a0] [text-wrap:pretty]">
            {t(
              "Write pages, publish articles, sell files, gather form replies and manage your team — without touching code."
            )}
          </p>

          <div class="mt-[26px] flex flex-col gap-[9px]">
            <div
              :for={
                feature <- [
                  %{
                    title: t("Pages & layouts"),
                    desc: t("Build any page by dragging blocks"),
                    color: "text-[#a6a2f5]",
                    path: "M4 4h16v5H4zM4 12h7v8H4zM13 12h7v8h-7z"
                  },
                  %{
                    title: t("Blog & documents"),
                    desc: t("Write, translate and schedule"),
                    color: "text-[#8ee0b8]",
                    path: "M9 3h7l4 4v14H9z M15 3v5h5"
                  },
                  %{
                    title: t("Media & files"),
                    desc: t("Upload, organise, even sell them"),
                    color: "text-[#e6c477]",
                    path: "M3 4h18v16H3zm0 12 5-4 4 3 4-4 5 4"
                  },
                  %{
                    title: t("Team & permissions"),
                    desc: t("Invite people, control access"),
                    color: "text-[#f2a79f]",
                    path: "M16 20v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M22 20v-2a4 4 0 0 0-3-3.8"
                  }
                ]
              }
              class="flex items-center gap-3 rounded-[13px] border border-white/[0.07] bg-white/[0.045] px-[14px] py-3"
            >
              <span class={[
                "flex size-[30px] shrink-0 items-center justify-center rounded-[9px] bg-white/[0.07]",
                feature.color
              ]}>
                <.feature_svg path={feature.path} />
              </span>
              <span class="min-w-0">
                <span class="block text-[12px] font-bold text-[#e6e5ea]">{feature.title}</span>
                <span class="mt-0.5 block text-[10.5px] font-medium text-[#8b8995]">
                  {feature.desc}
                </span>
              </span>
            </div>
          </div>

          <div
            :for={{quote, index} <- Enum.with_index(quotes())}
            id={"auth-quote-\#{index}"}
            data-auth-quote
            class={[
              "mt-[22px] rounded-[14px] border border-white/[0.06] bg-white/[0.03] px-[17px] py-4",
              index > 0 && "hidden"
            ]}
          >
            <p class="m-0 font-['Newsreader'] text-[13.5px] italic leading-[1.6] text-[#e6e5ea]">
              “{quote.text}”
            </p>
            <div class="mt-[13px] flex items-center gap-2.5">
              <span class={[
                "flex size-[26px] shrink-0 items-center justify-center rounded-full font-['Space_Grotesk'] text-[10px] font-bold text-white",
                quote.avatar
              ]}>
                {quote.initial}
              </span>
              <span class="min-w-0">
                <span class="block text-[11px] font-semibold text-[#c9c7d1]">{quote.name}</span>
                <span class="block text-[10px] font-medium text-[#7e7c86]">{quote.role}</span>
              </span>
              <span class="flex-1"></span>
              <span class="flex shrink-0 gap-1">
                <button
                  :for={{entry, dot} <- Enum.with_index(quotes())}
                  type="button"
                  title={entry.name}
                  aria-label={t("Read what %{name} said", name: entry.name)}
                  phx-click={
                    JS.add_class("hidden", to: "[data-auth-quote]")
                    |> JS.remove_class("hidden", to: "#auth-quote-\#{dot}")
                  }
                  class={[
                    "size-1.5 rounded-full",
                    if(dot == index, do: "bg-[#8ee0b8]", else: "bg-white/20")
                  ]}
                ></button>
              </span>
            </div>
          </div>
        </div>

        <div class="relative flex flex-wrap items-center gap-4 text-[10.5px] font-semibold text-[#8b8995]">
          <span class="inline-flex items-center gap-[7px]">
            <span class="text-[#8ee0b8]"><.shield_svg size={13} stroke="2" /></span>{t("GDPR ready")}
          </span>
          <span class="inline-flex items-center gap-[7px]">
            <span class="text-[#8ee0b8]"><.lock_svg size={13} stroke="2" /></span>{t(
              "Encrypted at rest"
            )}
          </span>
          <span class="inline-flex items-center gap-[7px]">
            <span class="text-[#8ee0b8]"><.globe_svg /></span>{t("Multi-site ready")}
          </span>
        </div>
      </aside>

      <div
        id="mishka-flash"
        class="pointer-events-none fixed right-4 top-4 z-[9999] flex flex-col items-end gap-2"
      >
        <div
          :if={msg = Phoenix.Flash.get(@flash, :info)}
          id="flash-info"
          phx-hook="FlashAutoDismiss"
          data-kind="info"
          data-dismiss-after="4000"
          phx-click={JS.push("lv:clear-flash", value: %{key: :info}) |> JS.hide(to: "#flash-info")}
          role="alert"
          class="pointer-events-auto max-w-[32rem] cursor-pointer rounded-lg px-4 py-3 font-[system-ui,sans-serif] text-white [background:#16a34a] [box-shadow:0_4px_12px_rgba(0,0,0,0.15)]"
        >
          {msg}
        </div>
        <div
          :if={msg = Phoenix.Flash.get(@flash, :error)}
          id="flash-error"
          phx-hook="FlashAutoDismiss"
          data-kind="error"
          data-dismiss-after="7000"
          phx-click={JS.push("lv:clear-flash", value: %{key: :error}) |> JS.hide(to: "#flash-error")}
          role="alert"
          class="pointer-events-auto max-w-[32rem] cursor-pointer rounded-lg px-4 py-3 font-[system-ui,sans-serif] text-white [background:#dc2626] [box-shadow:0_4px_12px_rgba(0,0,0,0.15)]"
        >
          {msg}
        </div>
      </div>
    </div>
    """
  end

  defp sign_in_template do
    ~s"""
    <div>
      <%= if assigns[:second_factor] do %>
        <div>
          <.link
            navigate={flow_path(assigns, "")}
            id="auth-second-factor-back"
            class="#{@back_class}"
          >
            <.chevron_left_svg />{t("Back to login")}
          </.link>
          <%= if assigns[:recovery?] do %>
            <h1 class="#{@title_class}">{t("Enter a recovery code")}</h1>
            <p class="#{@lede_class}">
              {t("Enter one of the recovery codes you saved when you set up two-step sign-in. Each works once.")}
            </p>
          <% else %>
            <h1 class="#{@title_class}">{t("Enter your authenticator code")}</h1>
            <p class="#{@lede_class}">
              {t("Open your authenticator app and enter the 6-digit code it shows for this account.")}
            </p>
          <% end %>
        </div>

        <div
          :if={assigns[:message]}
          id={Map.get(@message, :id, "auth-alert")}
          class="#{@alert_class} mt-[22px]"
        >
          <span class="mt-px shrink-0 text-[#c0473d]"><.alert_svg /></span>
          <div class="min-w-0">
            <div class="text-[12px] font-bold text-[#a5352c]">{@message.title}</div>
            <div class="mt-0.5 text-[11px] font-medium text-[#b06a63]">{@message.text}</div>
          </div>
        </div>

        <.form
          for={%{}}
          as={:user}
          id="auth-second-factor-form"
          class="mt-[22px] flex flex-col gap-[15px]"
          phx-submit="sign_in"
        >
          <div :if={assigns[:recovery?]}>
            <label for="auth-signin-recovery" class="#{@label_class} mb-[7px] block">
              {t("Recovery code")}
            </label>
            <div class="relative">
              <span class="#{@icon_left_class}"><.shield_svg /></span>
              <input
                type="text"
                id="auth-signin-recovery"
                name="user[recovery_code]"
                dir="ltr"
                autocomplete="off"
                autocapitalize="characters"
                spellcheck="false"
                maxlength="20"
                placeholder="XXXX-XXXX-XXXX"
                required
                autofocus
                class="#{@input_class} pl-10 pr-[14px] tracking-[0.12em]"
              />
            </div>
          </div>

          <div :if={!assigns[:recovery?]}>
            <label for="auth-signin-code" class="#{@label_class} mb-[7px] block">
              {t("Authenticator code")}
            </label>
            <div class="relative">
              <span class="#{@icon_left_class}"><.shield_svg /></span>
              <input
                type="text"
                id="auth-signin-code"
                name="user[totp_code]"
                dir="ltr"
                inputmode="numeric"
                autocomplete="one-time-code"
                pattern="[0-9]{6}"
                maxlength="6"
                placeholder="123456"
                required
                autofocus
                class="#{@input_class} pl-10 pr-[14px] tracking-[0.3em]"
              />
            </div>
          </div>

          <button type="submit" class="#{@cta_class} mt-[7px]">
            <span class="hidden items-center gap-[9px] phx-submit-loading:inline-flex">
              <span class="#{@spinner_class}">
              </span>{t("Checking…")}
            </span>
            <span class="inline-flex items-center gap-[9px] phx-submit-loading:hidden">
              {t("Verify and sign in")}<.arrow_right_svg />
            </span>
          </button>
        </.form>

        <button
          type="button"
          id="auth-second-factor-mode"
          phx-click="second_factor_mode"
          class="#{@dashed_class}"
        >
          {if assigns[:recovery?],
            do: t("Use your authenticator app"),
            else: t("Use a recovery code instead")}
        </button>
      <% else %>
        <div class="mb-4 inline-flex items-center gap-[7px] rounded-[20px] border border-[#e4e2f7] bg-[#f2f1fc] px-[11px] py-1 text-[10px] font-bold uppercase tracking-[0.13em] text-[#4f4bcc]">
          <span class="relative flex shrink-0 size-[5px]">
            <span class="absolute inline-flex size-full animate-ping rounded-full opacity-60 bg-[#1f9d6b]">
            </span>
            <span class="relative inline-flex size-full rounded-full bg-[#1f9d6b]"></span>
          </span>{t("Welcome")}
        </div>
        <h1 class="#{@title_class}">{t("Welcome back")}</h1>
        <p class="#{@lede_class}">{t("Sign in to manage your content, media and team.")}</p>

        <div class="mt-[26px] grid grid-cols-3 gap-[9px] max-[620px]:gap-[7px]!">
          <button
            :for={
              provider <- [
                %{
                  label: "Google",
                  color: "text-[#4285f4]",
                  path:
                    "M21.4 12.2c0-.7-.1-1.4-.2-2H12v3.9h5.3a4.5 4.5 0 0 1-2 3v2.4h3.1c1.9-1.7 3-4.3 3-7.3z M12 22c2.7 0 5-.9 6.7-2.4l-3.2-2.4c-.9.6-2 1-3.5 1a5.9 5.9 0 0 1-5.5-4H3.2v2.5A10 10 0 0 0 12 22z M6.5 14.2a6 6 0 0 1 0-3.8V7.9H3.2a10 10 0 0 0 0 8.6l3.3-2.3z M12 6c1.5 0 2.8.5 3.8 1.5l2.8-2.8A10 10 0 0 0 3.2 7.9l3.3 2.5A5.9 5.9 0 0 1 12 6z"
                },
                %{
                  label: "GitHub",
                  color: "text-[#1b1a18]",
                  path:
                    "M12 2a10 10 0 0 0-3.2 19.5c.5.1.7-.2.7-.5v-1.8c-2.8.6-3.4-1.3-3.4-1.3-.4-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.3 1.1 2.9.8.1-.7.4-1.1.7-1.4-2.2-.3-4.6-1.1-4.6-5 0-1.1.4-2 1-2.7-.1-.3-.4-1.3.1-2.7 0 0 .8-.3 2.7 1a9.4 9.4 0 0 1 5 0c1.9-1.3 2.7-1 2.7-1 .5 1.4.2 2.4.1 2.7.6.7 1 1.6 1 2.7 0 3.9-2.4 4.7-4.6 5 .4.3.7 1 .7 2v3c0 .3.2.6.7.5A10 10 0 0 0 12 2z"
                },
                %{
                  label: "Apple",
                  color: "text-[#1b1a18]",
                  path:
                    "M16.4 12.7c0-2.4 2-3.6 2.1-3.6-1.1-1.7-2.9-1.9-3.5-1.9-1.5-.1-2.9.9-3.7.9-.8 0-2-.9-3.3-.8-1.7 0-3.2 1-4.1 2.5-1.7 3-.4 7.5 1.3 10 .8 1.2 1.8 2.5 3.1 2.5 1.2 0 1.7-.8 3.2-.8s1.9.8 3.2.8c1.3 0 2.2-1.2 3-2.4a11 11 0 0 0 1.4-2.8c-.1 0-2.7-1-2.7-4.4z M14.6 5.6c.7-.8 1.1-2 1-3.1-1 0-2.2.7-2.9 1.5-.6.7-1.1 1.9-1 3 1.1.1 2.2-.6 2.9-1.4z"
                }
              ]
            }
            type="button"
            aria-label={t("Continue with %{provider}", provider: provider.label)}
            class="flex h-11 items-center justify-center gap-2 rounded-[12px] border border-[#ecebe6] bg-white text-[12px] font-semibold text-[#3a382f] shadow-[0_1px_2px_rgba(30,28,24,0.04)] hover:border-[#dcdbf5] hover:bg-[#faf9f6] max-[620px]:p-0!"
          >
            <span class={["flex items-center justify-center", provider.color]}>
              <.filled_svg path={provider.path} />
            </span>
            <span class="max-[620px]:hidden!">{provider.label}</span>
          </button>
        </div>

        <div class="my-[22px] flex items-center gap-3">
          <span class="h-px flex-1 bg-[#e6e4de]"></span>
          <span class="text-[11.5px] font-semibold uppercase tracking-[0.06em] text-[#6d6a63]">
            {t("or with email")}
          </span>
          <span class="h-px flex-1 bg-[#e6e4de]"></span>
        </div>

        <div :if={assigns[:message]} id={Map.get(@message, :id, "auth-alert")} class="#{@alert_class}">
          <span class="mt-px shrink-0 text-[#c0473d]"><.alert_svg /></span>
          <div class="min-w-0">
            <div class="text-[12px] font-bold text-[#a5352c]">{@message.title}</div>
            <div class="mt-0.5 text-[11px] font-medium text-[#b06a63]">{@message.text}</div>
          </div>
        </div>

        <.form
          :let={f}
          for={sign_in_form(assigns)}
          id="auth-sign-in-form"
          class="flex flex-col gap-[15px]"
          phx-submit="sign_in"
          phx-trigger-action={assigns[:trigger_action]}
          action={sign_in_action(assigns)}
          method="POST"
        >
          <div>
            <label for="auth-signin-email" class="#{@label_class} mb-[7px] block">{t("Email")}</label>
            <div class="relative">
              <span class="#{@icon_left_class}"><.mail_svg /></span>
              <input
                type="email"
                id="auth-signin-email"
                name={f[:email].name}
                value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
                placeholder="you@example.com"
                autocomplete="email"
                required
                class="#{@input_class} pl-10 pr-[14px]"
              />
            </div>
            <p :for={err <- f[:email].errors} class="#{@error_class}">
              {MishkaCmsCore.CoreComponents.translate_error(err)}
            </p>
          </div>

          <div>
            <div class="mb-[7px] flex items-center gap-2">
              <label for="auth-signin-pw" class="#{@label_class}">{t("Password")}</label>
              <span class="flex-1"></span>
              <.link
                navigate={flow_path(assigns, "/magic-link")}
                id="auth-go-magic"
                class="#{@link_class}"
              >
                {t("Magic link")}
              </.link>
              <span class="h-[11px] w-px bg-[#e6e4de]"></span>
              <.link
                navigate={flow_path(assigns, "/forgot-password")}
                id="auth-go-forgot"
                class="#{@link_class}"
              >
                {t("Forgot?")}
              </.link>
            </div>
            <div class="relative">
              <span class="#{@icon_left_class}"><.lock_svg /></span>
              <input
                type="password"
                id="auth-signin-pw"
                name={f[:password].name}
                value={Phoenix.HTML.Form.normalize_value("password", f[:password].value)}
                placeholder={t("Enter your password")}
                autocomplete="current-password"
                required
                class="#{@input_class} pl-10 pr-11"
              />
              <button
                type="button"
                aria-label={t("Show password")}
                class="#{@eye_button_class}"
                phx-click={
                  JS.toggle_attribute({"type", "text", "password"}, to: "#auth-signin-pw")
                  |> JS.toggle_class("hidden", to: "#auth-signin-pw-show")
                  |> JS.toggle_class("hidden", to: "#auth-signin-pw-hide")
                }
              >
                <span id="auth-signin-pw-show"><.eye_svg /></span>
                <span id="auth-signin-pw-hide" class="hidden"><.eye_off_svg /></span>
              </button>
            </div>
          </div>

          <.captcha form={f} for="sign_in" tenant={assigns[:current_tenant]} class="mt-[3px] justify-center" />

          <button type="submit" class="#{@cta_class} mt-[7px]">
            <span class="hidden items-center gap-[9px] phx-submit-loading:inline-flex">
              <span class="#{@spinner_class}">
              </span>{t("Signing in…")}
            </span>
            <span class="inline-flex items-center gap-[9px] phx-submit-loading:hidden">
              {t("Sign in")}<.arrow_right_svg />
            </span>
          </button>
        </.form>

        <.link
          navigate={flow_path(assigns, "/magic-link")}
          id="auth-go-magic-cta"
          class="#{@dashed_class}"
        >
          <.bolt_svg size={15} />{t("Email me a magic link instead")}
        </.link>

        <div class="mt-[22px] border-t border-[#ecebe6] pt-[18px] text-center text-[12.5px] font-medium text-[#6d6a63]">
          {t("New to MishkaCMS?")}
          <.link
            navigate={flow_path(assigns, "/register")}
            id="auth-go-signup"
            class="font-bold text-[#4f4bcc] hover:text-[#3a37a8]"
          >
            {t("Create an account")}
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  defp register_template do
    ~s"""
    <div>
      <div>
        <.link navigate={flow_path(assigns, "")} id="auth-back-to-login" class="#{@back_class}">
          <.chevron_left_svg />{t("Back to login")}
        </.link>
        <h1 class="#{@title_class}">{t("Create your account")}</h1>
        <p class="#{@lede_class}">{t("Enter your details to get started.")}</p>
      </div>

      <div
        :if={assigns[:message]}
        id={Map.get(@message, :id, "auth-alert")}
        class="#{@alert_class} mt-6"
      >
        <span class="mt-px shrink-0 text-[#c0473d]"><.alert_svg /></span>
        <div class="min-w-0">
          <div class="text-[12px] font-bold text-[#a5352c]">{@message.title}</div>
          <div class="mt-0.5 text-[11px] font-medium text-[#b06a63]">{@message.text}</div>
        </div>
      </div>

      <.form
        :let={f}
        for={register_form(assigns)}
        id="auth-register-form"
        class="mt-6 flex flex-col gap-[15px]"
        phx-change="validate_register"
        phx-submit="register"
        phx-trigger-action={assigns[:trigger_action]}
        action={register_action(assigns)}
        method="POST"
      >
        <div>
          <label for="auth-reg-email" class="#{@label_class} mb-[7px] block">{t("Email")}</label>
          <div class="relative">
            <span class="#{@icon_left_class}"><.mail_svg /></span>
            <input
              type="email"
              id="auth-reg-email"
              name={f[:email].name}
              value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
              placeholder="you@example.com"
              autocomplete="email"
              required
              class="#{@input_class} pl-10 pr-[14px]"
            />
          </div>
          <p :for={err <- f[:email].errors} class="#{@error_class}">
            {MishkaCmsCore.CoreComponents.translate_error(err)}
          </p>
        </div>

        <div>
          <label for="auth-reg-pw" class="#{@label_class} mb-[7px] block">{t("Password")}</label>
          <div class="relative">
            <span class="#{@icon_left_class}"><.lock_svg /></span>
            <input
              type={if assigns[:reg_pw_visible], do: "text", else: "password"}
              id="auth-reg-pw"
              name={f[:password].name}
              value={Phoenix.HTML.Form.normalize_value("password", f[:password].value)}
              placeholder={t("Minimum 8 characters")}
              autocomplete="new-password"
              required
              class="#{@input_class} pl-10 pr-11"
            />
            <button
              type="button"
              aria-label={t("Show password")}
              class="#{@eye_button_class}"
              phx-click="toggle_register_password"
            >
              <.eye_off_svg :if={assigns[:reg_pw_visible]} /><.eye_svg :if={!assigns[:reg_pw_visible]} />
            </button>
          </div>

          <div class="mt-[9px] flex items-center gap-[5px]">
            <span
              :for={index <- 0..3}
              class={[
                "h-1 flex-1 rounded-[3px]",
                if(index < password_score(f),
                  do: strength_bar(password_score(f)),
                  else: "bg-[#eceae4]"
                )
              ]}
            ></span>
            <span class={[
              "ml-1.5 shrink-0 text-[10.5px] font-bold",
              strength_text(password_score(f))
            ]}>
              {strength_label(password_score(f))}
            </span>
          </div>

          <div class="mt-[9px] flex flex-wrap gap-x-[14px] gap-y-1.5">
            <span
              :for={rule <- password_rules(f)}
              class={[
                "inline-flex items-center gap-[5px] text-[10.5px] font-bold",
                if(rule.met?, do: "text-[#177a53]", else: "text-[#6d6a63]")
              ]}
            >
              <.tick_svg :if={rule.met?} size={11} stroke="3" /><.cross_svg
                :if={!rule.met?}
                size={11}
                stroke="3"
              />{rule.label}
            </span>
          </div>

          <p :for={err <- f[:password].errors} class="#{@error_class}">
            {MishkaCmsCore.CoreComponents.translate_error(err)}
          </p>
        </div>

        <div>
          <label for="auth-reg-pw2" class="#{@label_class} mb-[7px] block">
            {t("Confirm password")}
          </label>
          <div class="relative">
            <span class="#{@icon_left_class}"><.lock_svg /></span>
            <input
              type={if assigns[:reg_pw_visible], do: "text", else: "password"}
              id="auth-reg-pw2"
              name={f[:password_confirmation].name}
              value={Phoenix.HTML.Form.normalize_value("password", f[:password_confirmation].value)}
              placeholder={t("Re-enter your password")}
              autocomplete="new-password"
              required
              class={["#{@input_class} pl-10 pr-11", confirm_state(f).frame]}
            />
            <span
              :if={confirm_state(f).shown?}
              class={[
                "absolute right-[13px] top-1/2 flex -translate-y-1/2",
                confirm_state(f).icon_color
              ]}
            >
              <.tick_svg :if={confirm_state(f).matched?} /><.cross_svg :if={
                !confirm_state(f).matched?
              } />
            </span>
          </div>
          <p
            :if={confirm_state(f).shown? and !confirm_state(f).matched?}
            class="#{@error_class}"
          >
            {t("Passwords don't match yet.")}
          </p>
          <p :for={err <- f[:password_confirmation].errors} class="#{@error_class}">
            {MishkaCmsCore.CoreComponents.translate_error(err)}
          </p>
        </div>

        <.captcha form={f} for="register" tenant={assigns[:current_tenant]} class="mt-[3px] justify-center" />

        <button type="submit" class="#{@cta_class} mt-[7px]">
          <span class="hidden items-center gap-[9px] phx-submit-loading:inline-flex">
            <span class="#{@spinner_class}">
            </span>{t("Creating…")}
          </span>
          <span class="phx-submit-loading:hidden">{t("Create account")}</span>
        </button>
      </.form>
    </div>
    """
  end

  defp forgot_password_template do
    ~s"""
    <div>
      <div>
        <.link navigate={flow_path(assigns, "")} id="auth-back-to-login" class="#{@back_class}">
          <.chevron_left_svg />{t("Back to login")}
        </.link>
        <span class="mb-4 flex size-[46px] items-center justify-center rounded-[14px] bg-[#fbf1df] text-[#a5691a]">
          <.lock_alert_svg />
        </span>
        <h1 class="#{@title_class}">{t("Reset your password")}</h1>
        <p class="#{@lede_class}">
          {t("Enter the email on your account and we'll send reset instructions.")}
        </p>
      </div>

      <div
        :if={assigns[:message]}
        id={Map.get(@message, :id, "auth-alert")}
        class="#{@alert_class} mt-6"
      >
        <span class="mt-px shrink-0 text-[#c0473d]"><.alert_svg /></span>
        <div class="min-w-0">
          <div class="text-[12px] font-bold text-[#a5352c]">{@message.title}</div>
          <div class="mt-0.5 text-[11px] font-medium text-[#b06a63]">{@message.text}</div>
        </div>
      </div>

      <div :if={assigns[:sent]} class="mt-[22px] rounded-[14px] border border-[#e2ece5] bg-[#f3f8f4] p-[18px]">
        <div class="flex items-center gap-2.5">
          <span class="flex size-[30px] shrink-0 items-center justify-center rounded-full bg-[#1f9d6b] text-white">
            <.tick_svg stroke="2.8" />
          </span>
          <div class="min-w-0">
            <div class="text-[13px] font-bold text-[#177a53]">{t("Check your inbox")}</div>
            <div class="mt-0.5 text-[11.5px] font-medium text-[#6f8f7f]">{@sent.text}</div>
          </div>
        </div>
      </div>

      <.form
        :let={f}
        :if={!assigns[:sent]}
        for={reset_form(assigns)}
        id="auth-reset-form"
        class="mt-6"
        phx-submit="request_reset"
      >
        <div>
          <label for="auth-reset-email" class="#{@label_class} mb-[7px] block">{t("Email")}</label>
          <div class="relative">
            <span class="#{@icon_left_class}"><.mail_svg /></span>
            <input
              type="email"
              id="auth-reset-email"
              name={f[:email].name}
              value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
              placeholder="you@example.com"
              autocomplete="email"
              required
              class="#{@input_class} pl-10 pr-[14px]"
            />
          </div>
          <p :for={err <- f[:email].errors} class="#{@error_class}">
            {MishkaCmsCore.CoreComponents.translate_error(err)}
          </p>
        </div>
        <.captcha form={f} for="reset_request" tenant={assigns[:current_tenant]} class="mt-[18px] justify-center" />

        <button type="submit" class="#{@cta_class} mt-[18px]">
          <span class="hidden items-center gap-[9px] phx-submit-loading:inline-flex">
            <span class="#{@spinner_class}">
            </span>{t("Sending…")}
          </span>
          <span class="phx-submit-loading:hidden">{t("Send reset instructions")}</span>
        </button>
      </.form>
    </div>
    """
  end

  defp magic_link_template do
    ~s"""
    <div>
      <div>
        <.link navigate={flow_path(assigns, "")} id="auth-back-to-login" class="#{@back_class}">
          <.chevron_left_svg />{t("Back to login")}
        </.link>
        <span class="mb-4 flex size-[46px] items-center justify-center rounded-[14px] bg-[#f2f1fc] text-[#4f4bcc]">
          <.bolt_svg />
        </span>
        <h1 class="#{@title_class}">{t("Sign in without a password")}</h1>
        <p class="#{@lede_class}">
          {t("We'll email a single-use link that signs you in on this device.")}
        </p>
      </div>

      <div
        :if={assigns[:message]}
        id={Map.get(@message, :id, "auth-alert")}
        class="#{@alert_class} mt-6"
      >
        <span class="mt-px shrink-0 text-[#c0473d]"><.alert_svg /></span>
        <div class="min-w-0">
          <div class="text-[12px] font-bold text-[#a5352c]">{@message.title}</div>
          <div class="mt-0.5 text-[11px] font-medium text-[#b06a63]">{@message.text}</div>
        </div>
      </div>

      <div :if={assigns[:sent]} class="mt-[22px] rounded-[14px] border border-[#e2ece5] bg-[#f3f8f4] p-[18px]">
        <div class="flex items-center gap-2.5">
          <span class="flex size-[30px] shrink-0 items-center justify-center rounded-full bg-[#1f9d6b] text-white">
            <.tick_svg stroke="2.8" />
          </span>
          <div class="min-w-0">
            <div class="text-[13px] font-bold text-[#177a53]">{t("Check your inbox")}</div>
            <div class="mt-0.5 text-[11.5px] font-medium text-[#6f8f7f]">{@sent.text}</div>
          </div>
        </div>
        <div class="mt-[14px] flex items-center gap-2.5 border-t border-[#dceadf] pt-[13px]">
          <span class="text-[11px] font-semibold text-[#6f8f7f]">{t("Didn't arrive?")}</span>
          <span class="flex-1"></span>
          <button
            type="button"
            id="auth-resend-link"
            phx-click="resend_magic_link"
            phx-value-email={@sent.email}
            class="h-[30px] rounded-lg border border-[#cfe3d6] bg-white px-3 text-[11px] font-bold text-[#177a53] hover:bg-[#f7fcf9]"
          >
            {t("Resend link")}
          </button>
        </div>
      </div>

      <.form
        :let={f}
        :if={!assigns[:sent]}
        for={magic_form(assigns)}
        id="auth-magic-form"
        class="mt-6"
        phx-submit="request_magic_link"
      >
        <div>
          <label for="auth-magic-email" class="#{@label_class} mb-[7px] block">{t("Email")}</label>
          <div class="relative">
            <span class="#{@icon_left_class}"><.mail_svg /></span>
            <input
              type="email"
              id="auth-magic-email"
              name={f[:email].name}
              value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
              placeholder="you@example.com"
              autocomplete="email"
              required
              class="#{@input_class} pl-10 pr-[14px]"
            />
          </div>
          <p :for={err <- f[:email].errors} class="#{@error_class}">
            {MishkaCmsCore.CoreComponents.translate_error(err)}
          </p>
        </div>
        <.captcha form={f} for="magic_link" tenant={assigns[:current_tenant]} class="mt-[18px] justify-center" />

        <button type="submit" class="#{@cta_class} mt-[18px]">
          <span class="hidden items-center gap-[9px] phx-submit-loading:inline-flex">
            <span class="#{@spinner_class}">
            </span>{t("Sending…")}
          </span>
          <span class="phx-submit-loading:hidden">{t("Send magic link")}</span>
        </button>
      </.form>
    </div>
    """
  end

  defp password_reset_template do
    ~s"""
    <div>
      <.link navigate={flow_path(assigns, "")} id="auth-back-to-login" class="#{@back_class}">
        <.chevron_left_svg />{t("Back to login")}
      </.link>
      <span class="mb-4 flex size-[46px] items-center justify-center rounded-[14px] bg-[#fbf1df] text-[#a5691a]">
        <.lock_alert_svg />
      </span>
      <h1 class="#{@title_class}">{t("Reset your password")}</h1>
      <p class="#{@lede_class}">{t("Choose a new password for your account.")}</p>
    </div>
    <div class="mt-6">
      <.live_component
        module={AshAuthentication.Phoenix.Components.Reset}
        id="reset"
        otp_app={nil}
        token={@query_params["token"]}
        auth_routes_prefix="/api/auth"
        overrides={[MishkaCmsCoreWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]}
        current_tenant={assigns[:current_tenant]}
        context={%{}}
        gettext_fn={nil}
      />
    </div>
    """
  end

  defp confirm_new_user_template do
    ~s"""
    <div>
      <.link navigate={flow_path(assigns, "")} id="auth-back-to-login" class="#{@back_class}">
        <.chevron_left_svg />{t("Back to login")}
      </.link>
      <span class="mb-4 flex size-[46px] items-center justify-center rounded-[14px] bg-[#e6f6ee] text-[#177a53]">
        <.shield_svg />
      </span>
      <h1 class="#{@title_class}">{t("Confirm your account")}</h1>
      <p class="#{@lede_class}">{t("One more step to activate your account.")}</p>
    </div>
    <div class="mt-6">
      <.live_component
        module={AshAuthentication.Phoenix.Components.Confirm}
        id="confirm"
        otp_app={nil}
        token={@query_params["token"]}
        auth_routes_prefix="/api/auth"
        overrides={[MishkaCmsCoreWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]}
        current_tenant={assigns[:current_tenant]}
        context={%{}}
        gettext_fn={nil}
        resource={MishkaCmsCore.Accounts.User}
        strategy={:confirm_new_user}
      />
    </div>
    """
  end

  defp magic_link_sign_in_template do
    ~s"""
    <div>
      <.link navigate={flow_path(assigns, "")} id="auth-back-to-login" class="#{@back_class}">
        <.chevron_left_svg />{t("Back to login")}
      </.link>
      <span class="mb-4 flex size-[46px] items-center justify-center rounded-[14px] bg-[#f2f1fc] text-[#4f4bcc]">
        <.bolt_svg />
      </span>
      <h1 class="#{@title_class}">{t("Magic sign in")}</h1>
      <p class="#{@lede_class}">{t("Confirm below to finish signing in.")}</p>
    </div>
    <div class="mt-6">
      <.live_component
        module={AshAuthentication.Phoenix.Components.MagicLink.SignIn}
        id="magic-sign-in"
        otp_app={nil}
        token={@query_params["token"]}
        strategy={:magic_link}
        auth_routes_prefix="/api/auth"
        overrides={[MishkaCmsCoreWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]}
        resource={MishkaCmsCore.Accounts.User}
        current_tenant={assigns[:current_tenant]}
        context={%{}}
        gettext_fn={nil}
      />
    </div>
    """
  end

  # A DELETE, NOT A GET: a link that ends a session can be triggered by any page that embeds it, so
  # this page is the confirmation in front of the CSRF-protected route.
  defp sign_out_template do
    ~s"""
    <div>
      <span class="mb-4 flex size-[46px] items-center justify-center rounded-[14px] bg-[#fbeceb] text-[#c0473d]">
        <.sign_out_svg />
      </span>
      <h1 class="#{@title_class}">{t("Sign out")}</h1>
      <p class="#{@lede_class}">{t("You'll need your email and password to get back in.")}</p>
    </div>

    <.form for={%{}} id="auth-sign-out-form" action="/auth/sign-out" method="delete" class="mt-6">
      <button type="submit" class="#{@cta_class}">
        <span class="hidden items-center gap-[9px] phx-submit-loading:inline-flex">
          <span class="#{@spinner_class}">
          </span>{t("Signing out…")}
        </span>
        <span class="inline-flex items-center gap-[9px] phx-submit-loading:hidden">
          {t("Sign out")}<.arrow_right_svg />
        </span>
      </button>
    </.form>

    <.link
      navigate={MishkaCmsCore.Sidebar.landing_path(assigns[:current_user])}
      id="auth-stay-signed-in"
      class="#{@dashed_class}"
    >
      <.chevron_left_svg />{t("Stay signed in")}
    </.link>
    """
  end

  # ---------------------------------------------------------------------------
  # The sign-in events and helpers
  # ---------------------------------------------------------------------------

  defp auth_event("sign_in") do
    %{
      name: "sign_in",
      code: ~S"""
      # THE SECOND STEP SENDS ONLY THE CODE. The email and password it follows stay in this process,
      # never in the page, and nothing the page sends replaces them; see
      # `MishkaCmsCore.Accounts.SecondFactor`.
      second_factor = socket.assigns[:second_factor]
      user = Map.merge(params["user"] || %{}, second_factor || %{})

      # AND ASKS NO CAPTCHA, which the password step passed: a form built for this one submit says so,
      # and is never kept. See `MishkaCmsCore.Accounts.CaptchaCheck`.
      form =
        if second_factor,
          do: code_step_form(socket.assigns),
          else: sign_in_form(socket.assigns)

      if password_strategy().sign_in_tokens_enabled? do
        case AshPhoenix.Form.submit(form, params: user, read_one?: true) do
          {:ok, signed_in} ->
            {:noreply, redirect(socket, to: token_path(socket.assigns, signed_in))}

          {:error, form} ->
            case form
                 |> AshPhoenix.Form.raw_errors(for_path: :all)
                 |> MishkaCmsCore.Accounts.SecondFactor.refusal() do
              :required ->
                {:noreply,
                 socket
                 |> assign(:sign_in_form, nil)
                 |> assign(:message, nil)
                 |> assign(:second_factor, Map.take(user, ["email", "password"]))}

              :invalid ->
                {:noreply, assign(socket, :message, second_factor_message(:invalid))}

              _not_the_code ->
                {:noreply,
                 socket
                 |> assign(:sign_in_form, if(second_factor, do: nil, else: form))
                 |> assign(:second_factor, nil)
                 |> refused_or(
                   form,
                   &assign(&1, :message, %{
                     title: t("Invalid email or password"),
                     text: t("Check your details and try again.")
                   })
                 )}
            end
        end
      else
        form = AshPhoenix.Form.validate(form, user)

        {:noreply,
         socket |> assign(:sign_in_form, form) |> assign(:trigger_action, form.source.valid?)}
      end
      """
    }
  end

  defp auth_event("register") do
    %{
      name: "register",
      code: ~S"""
      form = register_form(socket.assigns)
      user = params["user"] || %{}

      if password_strategy().sign_in_tokens_enabled? do
        case AshPhoenix.Form.submit(form, params: user, read_one?: true) do
          {:ok, registered} ->
            {:noreply, redirect(socket, to: token_path(socket.assigns, registered))}

          {:error, form} ->
            {:noreply,
             socket
             |> assign(:register_form, form)
             |> refused_or(
               form,
               &assign(&1, :message, %{
                 title: t("Could not create your account"),
                 text: t("Check the fields and try again.")
               })
             )}
        end
      else
        form = AshPhoenix.Form.validate(form, user)

        {:noreply,
         socket |> assign(:register_form, form) |> assign(:trigger_action, form.source.valid?)}
      end
      """
    }
  end

  # `errors: false` keeps the strength meter, the rules and the confirm indicator live while the
  # visitor types; the errors come with the submit.
  defp auth_event("validate_register") do
    %{
      name: "validate_register",
      code: ~S"""
      form =
        AshPhoenix.Form.validate(register_form(socket.assigns), params["user"] || %{},
          errors: false
        )

      {:noreply, assign(socket, :register_form, form)}
      """
    }
  end

  # The code step asks the authenticator's code, or one of the recovery codes in its place.
  defp auth_event("second_factor_mode") do
    %{
      name: "second_factor_mode",
      code: ~S"""
      {:noreply, socket |> assign(:recovery?, !socket.assigns[:recovery?]) |> assign(:message, nil)}
      """
    }
  end

  defp auth_event("toggle_register_password") do
    %{
      name: "toggle_register_password",
      code: ~S"""
      {:noreply, assign(socket, :reg_pw_visible, !socket.assigns[:reg_pw_visible])}
      """
    }
  end

  # THE SAME ANSWER WHETHER OR NOT THE ACCOUNT EXISTS, unless its rate refused the request.
  defp auth_event("request_reset") do
    %{
      name: "request_reset",
      code: ~S"""
      user = params["user"] || %{}

      site = socket.assigns[:current_site]

      answer =
        &sent(
          &1,
          :reset_form,
          user,
          if(MishkaCmsCore.Accounts.AuthGate.closed?(:reset, site && site.id),
            do:
              t(
                "Password reset is closed on this site. If your account may still use it, a reset link is on its way."
              ),
            else: t("If an account exists for that email, a reset link is on its way.")
          )
        )

      case AshPhoenix.Form.submit(reset_form(socket.assigns), params: user) do
        {:error, form} ->
          {:noreply, socket |> assign(:reset_form, form) |> refused_or(form, answer)}

        _requested ->
          {:noreply, answer.(socket)}
      end
      """
    }
  end

  defp auth_event("request_magic_link") do
    %{
      name: "request_magic_link",
      code: ~S"""
      user = params["user"] || %{}

      site = socket.assigns[:current_site]

      closed? =
        MishkaCmsCore.Accounts.AuthGate.closed?(:magic_link, site && site.id) or
          MishkaCmsCore.Accounts.AuthGate.closed?(:sign_in, site && site.id)

      answer =
        &sent(
          &1,
          :magic_form,
          user,
          if(closed?,
            do:
              t(
                "Sign-in links are closed on this site. If your account may still use them, a link is on its way."
              ),
            else: t("If an account exists for that email, a magic sign-in link is on its way.")
          )
        )

      case AshPhoenix.Form.submit(magic_form(socket.assigns), params: user) do
        {:error, form} ->
          {:noreply, socket |> assign(:magic_form, form) |> refused_or(form, answer)}

        _requested ->
          {:noreply, answer.(socket)}
      end
      """
    }
  end

  # A RESEND IS A NEW REQUEST, and a site that asks a captcha asks it again: the form comes back with
  # the address in it.
  defp auth_event("resend_magic_link") do
    %{
      name: "resend_magic_link",
      code: ~S"""
      if MishkaCmsCore.Captcha.on?(socket.assigns[:current_tenant]) do
        form =
          AshPhoenix.Form.validate(magic_form(socket.assigns), %{"email" => params["email"]},
            errors: false
          )

        {:noreply, socket |> assign(:sent, nil) |> assign(:magic_form, form)}
      else
        handle_event("request_magic_link", %{"user" => %{"email" => params["email"]}}, socket)
      end
      """
    }
  end

  # `{default size, default stroke width, the shapes}` of each icon the sign-in content draws.
  @auth_icons %{
    "alert_svg" => {15, "2", ~s(<circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/>)},
    "arrow_right_svg" => {16, "2.2", ~s(<path d="M4 12h14M12 5l7 7-7 7"/>)},
    "bolt_svg" => {22, "1.9", ~s(<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>)},
    "chevron_left_svg" => {14, "2.1", ~s(<path d="M15 6l-6 6 6 6"/>)},
    "cross_svg" => {16, "2.4", ~s(<path d="M18 6 6 18M6 6l12 12"/>)},
    "eye_off_svg" =>
      {16, "1.8",
       ~s(<path d="M3 3l18 18"/><path d="M10.6 6.2A9.6 9.6 0 0 1 12 6c6.5 0 10 6 10 6a17 17 0 0 1-2.4 3.2M6.6 8A17 17 0 0 0 2 12s3.5 6 10 6c1.2 0 2.3-.2 3.3-.6"/>)},
    "eye_svg" =>
      {16, "1.8",
       ~s(<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/>)},
    "globe_svg" =>
      {13, "2",
       ~s(<path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/><circle cx="12" cy="12" r="9"/>)},
    "lock_alert_svg" =>
      {22, "1.9",
       ~s(<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/><path d="M12 15v2"/>)},
    "lock_svg" =>
      {16, "1.8",
       ~s(<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>)},
    "mail_svg" =>
      {16, "1.8", ~s(<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>)},
    "moon_svg" => {16, "1.9", ~s(<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>)},
    "shield_svg" =>
      {22, "1.9",
       ~s(<path d="M12 3 19 6v6c0 4-3 7-7 8-4-1-7-4-7-8V6z"/><path d="m9 12 2 2 4-4"/>)},
    "sign_out_svg" =>
      {22, "1.9",
       ~s(<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>)},
    "sun_svg" =>
      {16, "1.9",
       ~s(<circle cx="12" cy="12" r="4"/><path d="M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M4.9 19.1l1.8-1.8M17.3 6.7l1.8-1.8"/>)},
    "tick_svg" => {16, "2.4", ~s(<path d="M20 7 10 17l-5-5"/>)}
  }

  defp auth_helper(name) when is_map_key(@auth_icons, name) do
    {size, stroke, shapes} = Map.fetch!(@auth_icons, name)

    helper(name, "assigns", """
    assigns = assign(assigns, size: assigns[:size] || #{size}, stroke: assigns[:stroke] || "#{stroke}")

    ~H\"\"\"
    <svg width={@size} height={@size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width={@stroke} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{shapes}</svg>
    \"\"\"
    """)
  end

  defp auth_helper("filled_svg") do
    helper("filled_svg", "assigns", ~S'''
    ~H"""
    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" stroke="none" aria-hidden="true"><path d={@path}/></svg>
    """
    ''')
  end

  defp auth_helper("feature_svg") do
    helper("feature_svg", "assigns", ~S'''
    ~H"""
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={@path}/></svg>
    """
    ''')
  end

  defp auth_helper("quotes") do
    helper("quotes", "", ~S'''
    [
      %{
        text:
          t(
            "I run a bakery, not a tech company. I add the weekly menu myself in about five minutes."
          ),
        name: "Lucia Ferreira",
        role: t("Owner · Pão & Sal"),
        initial: "L",
        avatar: "bg-[#c07a2a]"
      },
      %{
        text:
          t("Our whole editorial team works in here. Nobody has ever asked a developer for help."),
        name: "Frank Garcia",
        role: t("Editor · Nord Review"),
        initial: "F",
        avatar: "bg-[#4f4bcc]"
      },
      %{
        text:
          t(
            "Five languages, one dashboard. Switching to Persian just works, right to left and all."
          ),
        name: "Dave Brown",
        role: t("Marketing · Atlas Travel"),
        initial: "D",
        avatar: "bg-[#1f9d6b]"
      }
    ]
    ''')
  end

  # THE SAME LANGUAGE, and the verified `return_to` carried on.
  defp auth_helper("flow_path") do
    helper("flow_path", "assigns, suffix", ~S'''
    language =
      (assigns[:page] || %{})[:language] ||
        MishkaCmsCore.Runtime.Languages.primary(Map.get(assigns[:current_site] || %{}, :id))

    case return_params(assigns) do
      query when map_size(query) == 0 -> "/#{language}/auth#{suffix}"
      query -> "/#{language}/auth#{suffix}?#{URI.encode_query(query)}"
    end
    ''')
  end

  # ONLY A TOKEN THIS APPLICATION SIGNED; a stranger's string never reaches a form action.
  defp auth_helper("return_params") do
    helper("return_params", "assigns", ~S'''
    endpoint = Application.fetch_env!(:mishka_cms_core, :endpoint)

    with %{"return_to" => token} when is_binary(token) <- assigns[:query_params] || %{},
         true <- is_binary(MishkaCmsCoreWeb.ReturnTo.verify(endpoint, token)) do
      %{"return_to" => token}
    else
      _unverified -> %{}
    end
    ''')
  end

  defp auth_helper("password_strategy") do
    helper("password_strategy", "", ~S'''
    MishkaCmsCore.Accounts.User
    |> AshAuthentication.Info.authentication_strategies()
    |> Enum.find(&match?(%AshAuthentication.Strategy.Password{}, &1))
    ''')
  end

  defp auth_helper("magic_link_strategy") do
    helper("magic_link_strategy", "", ~S'''
    MishkaCmsCore.Accounts.User
    |> AshAuthentication.Info.authentication_strategies()
    |> Enum.find(&match?(%AshAuthentication.Strategy.MagicLink{}, &1))
    ''')
  end

  # THE FORM THE STRATEGY'S OWN ROUTE WOULD BUILD, for the tenant signing in and the address asking.
  defp auth_helper("build_form") do
    helper("build_form", "assigns, strategy, action, token_type", ~S'''
    context = %{
      strategy: strategy,
      private: %{ash_authentication?: true},
      ash_authentication_request: assigns[:client_request]
    }

    MishkaCmsCore.Accounts.User
    |> AshPhoenix.Form.for_action(action,
      domain: MishkaCmsCore.Accounts,
      as: "user",
      tenant: assigns[:current_tenant],
      context: if(token_type, do: Map.put(context, :token_type, token_type), else: context)
    )
    |> to_form()
    ''')
  end

  # THE CODE STEP OF A SIGN-IN ASKS NO CAPTCHA: it is reached only once the password step passed
  # one. Its form says so in its context, where nothing the browser sends can put it, and is built
  # for one submit and never kept — a kept one would carry the pass to every later try. See
  # `MishkaCmsCore.Accounts.CaptchaCheck`.
  defp auth_helper("code_step_form") do
    helper("code_step_form", "assigns", ~S'''
    MishkaCmsCore.Accounts.User
    |> AshPhoenix.Form.for_action(password_strategy().sign_in_action_name,
      domain: MishkaCmsCore.Accounts,
      as: "user",
      tenant: assigns[:current_tenant],
      context: %{
        strategy: password_strategy(),
        private: %{ash_authentication?: true},
        ash_authentication_request: assigns[:client_request],
        token_type: :sign_in,
        captcha_passed?: true
      }
    )
    |> to_form()
    ''')
  end

  defp auth_helper("sign_in_form") do
    helper("sign_in_form", "assigns", ~S'''
    assigns[:sign_in_form] ||
      build_form(assigns, password_strategy(), password_strategy().sign_in_action_name, :sign_in)
    ''')
  end

  defp auth_helper("register_form") do
    helper("register_form", "assigns", ~S'''
    assigns[:register_form] ||
      build_form(assigns, password_strategy(), password_strategy().register_action_name, :sign_in)
    ''')
  end

  defp auth_helper("reset_form") do
    helper("reset_form", "assigns", ~S'''
    assigns[:reset_form] ||
      build_form(
        assigns,
        password_strategy(),
        password_strategy().resettable.request_password_reset_action_name,
        nil
      )
    ''')
  end

  defp auth_helper("magic_form") do
    helper("magic_form", "assigns", ~S'''
    assigns[:magic_form] ||
      build_form(assigns, magic_link_strategy(), magic_link_strategy().request_action_name, nil)
    ''')
  end

  defp auth_helper("sign_in_action") do
    helper("sign_in_action", "assigns", ~S'''
    AshAuthentication.Phoenix.Components.Helpers.auth_path(
      nil,
      "user",
      "/api/auth",
      password_strategy(),
      :sign_in,
      return_params(assigns)
    )
    ''')
  end

  defp auth_helper("register_action") do
    helper("register_action", "assigns", ~S'''
    AshAuthentication.Phoenix.Components.Helpers.auth_path(
      nil,
      "user",
      "/api/auth",
      password_strategy(),
      :register,
      return_params(assigns)
    )
    ''')
  end

  # THE SESSION COOKIE IS SET BY THIS GET: the form checked the password, the route signs in.
  defp auth_helper("token_path") do
    helper("token_path", "assigns, user", ~S'''
    AshAuthentication.Phoenix.Components.Helpers.auth_path(
      nil,
      "user",
      "/api/auth",
      password_strategy(),
      :sign_in_with_token,
      Map.put(return_params(assigns), "token", user.__metadata__.token)
    )
    ''')
  end

  # WHAT THE CAPTCHA SAID when it refused the form (`MishkaCmsCore.Accounts.CaptchaCheck`), HOW LONG
  # TO WAIT when the rate refused it, WHAT IS CLOSED when the site closed this way in
  # (`MishkaCmsCore.Accounts.AuthGate`), else whatever `otherwise` makes of it.
  #
  # Whatever the refusal, the form's captcha is asked again: its token may have been spent.
  defp auth_helper("refused_or") do
    helper("refused_or", "socket, form, otherwise", ~S'''
    errors = AshPhoenix.Form.raw_errors(form, for_path: :all)
    socket = push_event(socket, "mishka:captcha:reset", %{})

    with nil <- MishkaCmsCore.Accounts.CaptchaCheck.refusal(errors),
         nil <- MishkaCmsCore.Accounts.AuthRateLimit.limited(errors),
         nil <- MishkaCmsCore.Accounts.AuthGate.refusal(errors) do
      otherwise.(socket)
    else
      %{reason: reason} -> assign(socket, :message, captcha_message(reason))
      %{retry_after: _} = limited -> rate_limited(socket, limited)
      %{action: action} -> assign(socket, :message, gate_message(action))
    end
    ''')
  end

  # EVERY TITLE A LITERAL, so each is a key the translation screen sees as used.
  defp auth_helper("captcha_message") do
    helper("captcha_message", "reason", ~S'''
    case reason do
      :missing ->
        %{
          id: "auth-captcha-refused",
          title: t("Complete the security check"),
          text: t("Then send the form again.")
        }

      _failed ->
        %{
          id: "auth-captcha-refused",
          title: t("The security check did not pass"),
          text: t("Try the check again, then send the form.")
        }
    end
    ''')
  end

  # EVERY TITLE A LITERAL, so each is a key the translation screen sees as used.
  defp auth_helper("gate_message") do
    helper("gate_message", "action", ~S'''
    %{
      id: "auth-closed",
      title:
        case action do
          :sign_in -> t("Sign-in is closed")
          :register -> t("Registration is closed")
          :reset -> t("Password reset is closed")
          _magic_link -> t("Sign-in links are closed")
        end,
      text: t("This site has switched it off for now.")
    }
    ''')
  end

  # A PLUGIN ON `auth:live:rate_limited` HEARS THE REFUSAL FIRST and may send the visitor elsewhere.
  defp auth_helper("rate_limited") do
    helper("rate_limited", "socket, limited", ~S'''
    site = socket.assigns[:current_site]

    socket =
      MishkaInstaller.Event.Hook.call("auth:live:rate_limited", socket,
        meta: Map.put(limited, :site_id, site && site.id)
      )

    if socket.redirected,
      do: socket,
      else: assign(socket, :message, rate_limit_message(limited))
    ''')
  end

  # EVERY TITLE A LITERAL, so each is a key the translation screen sees as used.
  defp auth_helper("rate_limit_message") do
    helper("rate_limit_message", "limited", ~S'''
    seconds = limited.retry_after
    minutes = div(seconds + 59, 60)

    %{
      id: "auth-rate-limited",
      title:
        case limited.action do
          :sign_in -> t("Too many sign-in attempts")
          :reset_request -> t("Too many password reset requests")
          :magic_link -> t("Too many sign-in link requests")
          :register -> t("Too many new accounts")
          :totp -> t("Too many authenticator codes")
          _other -> t(MishkaCmsCore.Accounts.AuthRateLimit.describe(limited).title)
        end,
      text:
        cond do
          seconds == 1 -> t("Try again in 1 second.")
          seconds < 60 -> t("Try again in %{count} seconds.", count: seconds)
          minutes == 1 -> t("Try again in 1 minute.")
          true -> t("Try again in %{count} minutes.", count: minutes)
        end
    }
    ''')
  end

  # EVERY TITLE A LITERAL, so each is a key the translation screen sees as used.
  defp auth_helper("second_factor_message") do
    helper("second_factor_message", "reason", ~S'''
    case reason do
      :invalid ->
        %{
          id: "auth-second-factor-invalid",
          title: t("That code did not match"),
          text: t("Enter the current code from your authenticator app.")
        }

      _password ->
        %{
          id: "auth-second-factor-password",
          title: t("Sign in with your password"),
          text: t("This account signs in with its password and a code from its authenticator app.")
        }
    end
    ''')
  end

  defp auth_helper("sent") do
    helper("sent", "socket, form, params, text", ~S'''
    socket
    |> assign(:sent, %{email: params["email"], text: text})
    |> assign(form, nil)
    ''')
  end

  defp auth_helper("password_rules") do
    helper("password_rules", "form", ~S'''
    password = to_string(form[:password].value || "")

    [
      %{label: t("8+ characters"), met?: String.length(password) >= 8},
      %{label: t("Uppercase"), met?: String.match?(password, ~r/[A-Z]/)},
      %{label: t("Number"), met?: String.match?(password, ~r/[0-9]/)},
      %{label: t("Symbol"), met?: String.match?(password, ~r/[^A-Za-z0-9]/)}
    ]
    ''')
  end

  defp auth_helper("password_score") do
    helper("password_score", "form", ~S'''
    form |> password_rules() |> Enum.count(& &1.met?)
    ''')
  end

  defp auth_helper("strength_label") do
    helper("strength_label", "score", ~S'''
    case score do
      0 -> t("Too short")
      1 -> t("Weak")
      2 -> t("Fair")
      3 -> t("Good")
      4 -> t("Strong")
    end
    ''')
  end

  defp auth_helper("strength_text") do
    helper("strength_text", "score", ~S'''
    Enum.at(
      ["text-[#6d6a63]", "text-[#c0473d]", "text-[#c0752a]", "text-[#3a6cb5]", "text-[#177a53]"],
      score
    )
    ''')
  end

  defp auth_helper("strength_bar") do
    helper("strength_bar", "score", ~S'''
    Enum.at(
      ["bg-[#eceae4]", "bg-[#c0473d]", "bg-[#c0752a]", "bg-[#3a6cb5]", "bg-[#177a53]"],
      score
    )
    ''')
  end

  defp auth_helper("confirm_state") do
    helper("confirm_state", "form", ~S'''
    password = to_string(form[:password].value || "")
    confirmation = to_string(form[:password_confirmation].value || "")

    cond do
      confirmation == "" ->
        %{shown?: false, matched?: false, frame: nil, icon_color: nil}

      password == confirmation ->
        %{
          shown?: true,
          matched?: true,
          frame: "border-[#cfe6d8]! bg-[#f7fcf9]!",
          icon_color: "text-[#1f9d6b]"
        }

      true ->
        %{
          shown?: true,
          matched?: false,
          frame: "border-[#f0dcd8]! bg-[#fdf7f6]!",
          icon_color: "text-[#c0473d]"
        }
    end
    ''')
  end

  defp helper(name, args, code), do: %{name: name, args: args, code: code}

  # THE BUILT-IN WORDS, by language code: every word the sign-in content asks `t/1` for, the English
  # being the key. A language added here is written for every site that publishes in it.
  defp auth_words, do: %{"fa" => persian_words()}

  defp persian_words do
    %{
      "Sign-in is closed" => "ورود بسته است",
      "Registration is closed" => "ثبت‌نام بسته است",
      "Password reset is closed" => "بازیابی رمز عبور بسته است",
      "Sign-in links are closed" => "لینک‌های ورود بسته‌اند",
      "This site has switched it off for now." => "این سایت فعلاً آن را خاموش کرده است.",
      "Password reset is closed on this site. If your account may still use it, a reset link is on its way." =>
        "بازیابی رمز عبور در این سایت بسته است. اگر حساب شما هنوز اجازه‌ی آن را دارد، لینک بازیابی در راه است.",
      "Sign-in links are closed on this site. If your account may still use them, a link is on its way." =>
        "لینک‌های ورود در این سایت بسته‌اند. اگر حساب شما هنوز اجازه‌ی آن را دارد، لینک در راه است.",
      "Switch to dark" => "تغییر به حالت تیره",
      "Switch to light" => "تغییر به حالت روشن",
      "Docs" => "مستندات",
      "Support" => "پشتیبانی",
      "All systems operational" => "همه‌ی سامانه‌ها فعال‌اند",
      "Everything your site needs, in one place." => "هر آنچه سایت شما نیاز دارد، در یک جا.",
      "Write pages, publish articles, sell files, gather form replies and manage your team — without touching code." =>
        "صفحه بنویسید، مقاله منتشر کنید، فایل بفروشید، پاسخ فرم‌ها را گرد آورید و تیمتان را مدیریت کنید — بی آنکه به کد دست بزنید.",
      "Pages & layouts" => "صفحه‌ها و قالب‌ها",
      "Build any page by dragging blocks" => "هر صفحه‌ای را با کشیدن بلوک‌ها بسازید",
      "Blog & documents" => "وبلاگ و مستندات",
      "Write, translate and schedule" => "بنویسید، ترجمه کنید و زمان‌بندی کنید",
      "Media & files" => "رسانه و فایل‌ها",
      "Upload, organise, even sell them" => "بارگذاری کنید، مرتب کنید، حتی بفروشید",
      "Team & permissions" => "تیم و دسترسی‌ها",
      "Invite people, control access" => "افراد را دعوت کنید، دسترسی‌ها را در دست بگیرید",
      "I run a bakery, not a tech company. I add the weekly menu myself in about five minutes." =>
        "من یک نانوایی دارم، نه یک شرکت فناوری. منوی هفتگی را خودم در حدود پنج دقیقه اضافه می‌کنم.",
      "Our whole editorial team works in here. Nobody has ever asked a developer for help." =>
        "همه‌ی تیم تحریریه‌ی ما همین‌جا کار می‌کنند. تا امروز کسی از برنامه‌نویس کمک نخواسته است.",
      "Five languages, one dashboard. Switching to Persian just works, right to left and all." =>
        "پنج زبان، یک داشبورد. رفتن به فارسی بی‌دردسر کار می‌کند، راست‌به‌چپ و همه‌چیز.",
      "Owner · Pão & Sal" => "مالک · Pão & Sal",
      "Editor · Nord Review" => "ویراستار · Nord Review",
      "Marketing · Atlas Travel" => "بازاریابی · Atlas Travel",
      "Read what %{name} said" => "بخوانید %{name} چه گفت",
      "GDPR ready" => "آماده برای GDPR",
      "Encrypted at rest" => "رمزنگاری‌شده در ذخیره‌سازی",
      "Multi-site ready" => "آماده برای چند سایت",
      "Welcome" => "خوش آمدید",
      "Welcome back" => "خوش برگشتید",
      "Sign in to manage your content, media and team." =>
        "وارد شوید تا محتوا، رسانه و تیمتان را مدیریت کنید.",
      "Continue with %{provider}" => "ادامه با %{provider}",
      "or with email" => "یا با ایمیل",
      "Email" => "ایمیل",
      "Password" => "رمز عبور",
      "Magic link" => "لینک جادویی",
      "Forgot?" => "فراموش کرده‌اید؟",
      "Enter your password" => "رمز عبورتان را وارد کنید",
      "Show password" => "نمایش رمز عبور",
      "Signing in…" => "در حال ورود…",
      "Sign in" => "ورود",
      "Email me a magic link instead" => "به‌جایش یک لینک جادویی برایم بفرست",
      "New to MishkaCMS?" => "با MishkaCMS تازه آشنا شده‌اید؟",
      "Create an account" => "یک حساب بسازید",
      "Invalid email or password" => "ایمیل یا رمز عبور نادرست است",
      "Check your details and try again." => "اطلاعاتتان را بررسی کنید و دوباره تلاش کنید.",
      "Too many sign-in attempts" => "تلاش برای ورود بیش از اندازه بوده است",
      "Complete the security check" => "بررسی امنیتی را کامل کنید",
      "Then send the form again." => "سپس فرم را دوباره بفرستید.",
      "The security check did not pass" => "بررسی امنیتی پذیرفته نشد",
      "Try the check again, then send the form." =>
        "بررسی را دوباره انجام دهید و سپس فرم را بفرستید.",
      "Too many password reset requests" => "درخواست بازنشانی رمز عبور بیش از اندازه بوده است",
      "Too many sign-in link requests" => "درخواست لینک ورود بیش از اندازه بوده است",
      "Too many new accounts" => "ساخت حساب جدید بیش از اندازه بوده است",
      "Too many authenticator codes" => "کدهای احراز هویت بیش از اندازه وارد شده است",
      "Enter your authenticator code" => "کد احراز هویت را وارد کنید",
      "Open your authenticator app and enter the 6-digit code it shows for this account." =>
        "برنامه‌ی احراز هویت خود را باز کنید و کد ۶ رقمی‌ای را که برای این حساب نشان می‌دهد وارد کنید.",
      "Authenticator code" => "کد احراز هویت",
      "Enter a recovery code" => "یک کد بازیابی وارد کنید",
      "Enter one of the recovery codes you saved when you set up two-step sign-in. Each works once." =>
        "یکی از کدهای بازیابی‌ای را که هنگام راه‌اندازی ورود دومرحله‌ای ذخیره کردید وارد کنید. هر کد فقط یک بار کار می‌کند.",
      "Recovery code" => "کد بازیابی",
      "Use a recovery code instead" => "به‌جای آن از کد بازیابی استفاده کنید",
      "Use your authenticator app" => "از برنامه‌ی احراز هویت استفاده کنید",
      "Checking…" => "در حال بررسی…",
      "Verify and sign in" => "تأیید و ورود",
      "That code did not match" => "این کد درست نبود",
      "Enter the current code from your authenticator app." =>
        "کد فعلی برنامه‌ی احراز هویت خود را وارد کنید.",
      "Sign in with your password" => "با رمز عبور خود وارد شوید",
      "This account signs in with its password and a code from its authenticator app." =>
        "ورود به این حساب با رمز عبور و کد برنامه‌ی احراز هویت انجام می‌شود.",
      "Try again in 1 second." => "یک ثانیه‌ی دیگر دوباره تلاش کنید.",
      "Try again in %{count} seconds." => "%{count} ثانیه‌ی دیگر دوباره تلاش کنید.",
      "Try again in 1 minute." => "یک دقیقه‌ی دیگر دوباره تلاش کنید.",
      "Try again in %{count} minutes." => "%{count} دقیقه‌ی دیگر دوباره تلاش کنید.",
      "Back to login" => "بازگشت به ورود",
      "Create your account" => "حساب خود را بسازید",
      "Enter your details to get started." => "برای شروع، اطلاعاتتان را وارد کنید.",
      "Minimum 8 characters" => "دست‌کم ۸ نویسه",
      "Too short" => "خیلی کوتاه",
      "Weak" => "ضعیف",
      "Fair" => "متوسط",
      "Good" => "خوب",
      "Strong" => "قوی",
      "8+ characters" => "۸ نویسه یا بیشتر",
      "Uppercase" => "حرف بزرگ",
      "Number" => "عدد",
      "Symbol" => "نماد",
      "Confirm password" => "تکرار رمز عبور",
      "Re-enter your password" => "رمز عبورتان را دوباره وارد کنید",
      "Passwords don't match yet." => "رمزهای عبور هنوز یکی نیستند.",
      "Creating…" => "در حال ساخت…",
      "Create account" => "ساخت حساب",
      "Could not create your account" => "حساب شما ساخته نشد",
      "Check the fields and try again." => "فیلدها را بررسی کنید و دوباره تلاش کنید.",
      "Reset your password" => "بازنشانی رمز عبور",
      "Enter the email on your account and we'll send reset instructions." =>
        "ایمیل حسابتان را وارد کنید تا راهنمای بازنشانی را برایتان بفرستیم.",
      "Check your inbox" => "صندوق ایمیلتان را ببینید",
      "Sending…" => "در حال ارسال…",
      "Send reset instructions" => "ارسال راهنمای بازنشانی",
      "If an account exists for that email, a reset link is on its way." =>
        "اگر حسابی با این ایمیل وجود داشته باشد، لینک بازنشانی در راه است.",
      "Sign in without a password" => "ورود بدون رمز عبور",
      "We'll email a single-use link that signs you in on this device." =>
        "لینکی یک‌بارمصرف برایتان ایمیل می‌کنیم که شما را در همین دستگاه وارد می‌کند.",
      "Didn't arrive?" => "نرسید؟",
      "Resend link" => "ارسال دوباره‌ی لینک",
      "Send magic link" => "ارسال لینک جادویی",
      "If an account exists for that email, a magic sign-in link is on its way." =>
        "اگر حسابی با این ایمیل وجود داشته باشد، لینک ورود جادویی در راه است.",
      "Choose a new password for your account." => "برای حسابتان رمز عبور تازه‌ای برگزینید.",
      "Confirm your account" => "تأیید حساب",
      "One more step to activate your account." => "یک گام دیگر تا فعال شدن حسابتان.",
      "Magic sign in" => "ورود جادویی",
      "Confirm below to finish signing in." => "برای پایان ورود، در پایین تأیید کنید.",
      "Sign out" => "خروج",
      "You'll need your email and password to get back in." =>
        "برای ورود دوباره به ایمیل و رمز عبورتان نیاز خواهید داشت.",
      "Signing out…" => "در حال خروج…",
      "Stay signed in" => "وارد بمانید"
    }
  end

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
