# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.StarterContent do
  @moduledoc """
  The site a first install answers with: a theme, the logo, a header, a footer, a layout, a home
  page and an error page, written through the ordinary create actions.

  ## Why it is plain HTML

  The installer lets the user deselect every UI component (`MishkaCmsCore.Install.Bootstrap`), so a
  starter page that drew `chelekom-card` would render the red "Component failed to render!" box on
  exactly the install that chose least. Everything below is HTML plus `<.link>`, which a compiled
  page has whatever is installed — and NOT the host's `<.input>`, whose class names come from a CSS
  framework no bundle here ships.

  What the pages DO have is the site's own `:theme` stylesheet, so `bg-page`, `text-fg`,
  `border-edge` and the rest are real utilities in the site's bundle. That is the one dependency,
  and it is seeded here beside them. Each colour of the home page has a `-dark` twin, and the
  markup pairs them with `dark:`, which the site's stylesheet answers to `data-theme="dark"` on the
  document; the header's toggle sets that attribute through the host's `phx:set-theme` event, the
  same one the sign-in layout uses.

  ## Every site has it

  The installer writes it whatever its first screen said (`MishkaCmsCore.Install.Bootstrap`), and
  a site created later in the admin gets the same from its `"provision"` job
  (`MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker`), so every site of an install has a home
  page, the theme, the header, the footer and the `site-main` layout.

  ## What belongs to the layout and what to the page

  ONE LAYOUT FOR EVERY PAGE. The header and the footer are components, drawn by the `site-main`
  layout, so every page the site has, the blog's and the docs' among them, has the home page's
  header and footer without asking. The page at `/:lang` is everything between them. What the
  layout draws, the content column a page is drawn in and what a page hands the layout (its
  languages and the bar under the header) are `MishkaCmsCore.Runtime.SiteLayout`'s.

  The layout also links, from the document's `<head>`, the two typefaces the theme does not ship,
  Geist and Geist Mono, from Google Fonts, which the public Content-Security-Policy already
  allows; Newsreader comes with the host's own `/fonts/fonts.css`.

  ## What the header changes with

  Three things, each handed to the `site-header` by the layout and each read from what the runtime
  already assigns, so no page and no helper of ours looks anything up:

    * `@current_user` — a signed-in visitor sees their email and a menu in place of Sign in: the
      console and their account settings when `MishkaCmsCore.Sidebar.landing_path/1` says they may
      open it, and Sign out, which is the DELETE the sign-out page's own form sends. Naming the
      visitor in the layout is also what makes the runtime load one for pages that use it
      (`MishkaCmsCore.Runtime.Compilers.UserClosure`).
    * `@page_languages` — the languages the page is written in, each at its own address, as
      `MishkaCmsCore.Runtime.SiteLayout` resolves them: the page's own editions, or the record's
      translations an extension answers with. With two or more the header has a language
      switcher: a flag (`Languages.flag/1`) and the entry's `name` for each, the current one
      marked. A page in one language has none.
    * The version the home page's pill shows is `MishkaCmsCore.Helpers.host_version/0`, the
      application's own, read when the page is drawn.

  ## The header on a phone

  The bar is the design's from `lg` (1024 px) up. Below it the links, the language switcher, the
  dark toggle and the Sign in button or the visitor's menu are the same elements, in a panel under
  the header that a menu button opens: the logo and the button are all the bar holds, so nothing
  can run over the logo or off the screen. `lg` and not `md`, because a site that adds links of its
  own (the dev sites had up to six, before their links went into one dropdown) and two languages is
  wider than 768 px.

  The button works as the header's two dropdowns do, with the host's own `Phoenix.LiveView.JS`: it
  toggles the panel's `max-lg:hidden` class and its own `aria-expanded`, a click away from the
  header or Escape closes the panel and Escape gives the focus back to the button. The switcher and
  the visitor's menu open in the panel, in the list, rather than over it.

  Each dropdown listens for the click away from the `div` that holds its button, not from its menu:
  the click that is meant to close an open menu is on its button, which is "away" from the menu
  alone, so the menu hid and the button's own toggle showed it again.

  ## Grouped links

  A site with many links of its own (the dev sites have up to eight) can put them in a group, one
  entry of the `:nav` option (`t:nav_entry/0`) that holds the links instead of being one. The
  group is written into the layout, beside the plain links, and the `site-header` component is
  not told about it, so a site that passes no group has the header, and the layout, it had.

    * From `lg` up it is a dropdown: a button with the group's label and a chevron, drawn as the
      language switcher's is and opened, closed (by its button, a click away or Escape) and
      marked (`aria-expanded`) with the same `Phoenix.LiveView.JS` commands. Its menu opens
      under the button.
    * Below `lg` it is a labelled group in the menu panel, its links in the list and no button
      to open: the panel is already something a visitor opened.

  They are two sets of elements, one hidden at each width, so each has the semantics its width
  needs (a menu button; a group with a label) and neither is restyled into the other. The links
  are on the page twice, and only one set is ever shown.

  ## The theme

  Three blocks of design tokens and one utility:

    * the admin palette the error pages and the dev seeds' pages are written in (`ground`, `ink`,
      `accent`, …);
    * the home page's colours, each that changes in the dark with a `-dark` twin (`page`, `fg`,
      `dim`, `surface`, `edge`, …), and its three typefaces;
    * the colours the extensions' pages share, so a blog and a documentation kit are written in
      the site's tokens and not in hex values of their own:
      * six tints, each a surface and its ink: `tint-1` to `tint-6`, with `tint-N-ink`, and
        `tint-N-dark`, `tint-N-ink-dark` for the dark (teal, violet, amber, rose, blue, stone);
      * `chip-wash` (`-dark`), the wash behind a chosen chip or link;
      * `brand-dark`, the brand on a dark page;
      * `body` (`-dark`), the text of a long read;
      * `edge-hover`, the edge a hovered or focused card takes, the same in both;
      * `warn-ink` (`-dark`), the ink of a warning or a featured mark;
      * `warn-wash` (`-dark`), the wash behind a warning or a featured mark;
    * `site-bleed`, which lets a section run from one edge of the window to the other while its
      content stays in the layout's column (`MishkaCmsCore.Runtime.SiteLayout`).

  ## The logo

  The mark in the header, the footer and the home page is a picture in the MASTER site's media
  library, named `mishka-logo`, and every address of it is that row's `relative_path`. It is
  stored the way an upload is (`MishkaCmsCore.Runtime.Media.validate_and_process_file/1`, then
  `save_file_to_storage/3`), so it can be replaced, archived or deleted from the media manager like
  any other file. A site that is not the master draws the master's picture, which is what a
  dev site does. It ships as a PNG under `priv/install`: the library refuses SVG, because a vector
  served from the site's own origin can carry a script.

  ## Why the dev seeds run it too

  `MishkaCmsCore.Dev.Seeds` gives every dev site this same base before it adds what that site exists
  to demonstrate, so the code a stranger's first install runs is the code this project's developers
  look at every day. A production path nobody opens is a production path nobody has seen.

  That includes the home page: a dev site's `/` is the one written here, template and stamps, and
  the dev seeds add their pages beside it (`:extra_pages`), never in its place.

  ## Running it again

  It writes ONLY WHAT IS MISSING, the rule the whole seeding surface follows: a row found by its
  name — the key the database keeps — is left exactly as it is, edits and all, and a page is asked
  about through `MishkaCmsCore.Runtime.PageProvision`, which knows that a held NAME and a held
  ADDRESS are two different answers.

  ## Bringing an older site up to date

  The one exception is `upgrade/1`, which `seed!/2` runs on the rows it finds, and which
  `MishkaCmsCore.Runtime.ExtensionProvision` runs before an extension writes its pages. It adds
  what a release needs and touches nothing an admin wrote:

    * the theme gains each token and the `site-bleed` utility it does not declare yet, in a block
      of their own after the row's content; a value already there is kept, edited or not;
    * the `site-header` component takes the phone menu, when its template is still, whole, one an
      earlier release wrote;
    * the `site-main` layout takes the content column and the section bar, when its frame, its
      messages and its `<main>` are still what an earlier release wrote;
    * the home page drops the containers of its own, when its three sections are still what an
      earlier release wrote and the layout draws the column.

  A header, a layout or a home page that was edited where the upgrade would write keeps everything
  it has.

  ## The addresses

  `/:lang` — the path mode `MishkaCmsCore.Runtime.Languages` validates, so `/fa` answers and `/xyz`
  does not. It collides with no route this application answers itself, and it answers every
  language the site publishes in (`PageProvision.serving_all_languages/1`).

  Every link to another page of the site is written with `site_path/2`
  (`MishkaCmsCore.Runtime.LiveViewHelpers.site_path/2`), in the language of the page it is on, so
  it follows the site's URL mode: `/auth` and `/fa/auth`, or `/en/auth` and `/fa/auth`. A page that
  knows no language links in the site's first.

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
    Media,
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

  # THE ADMIN PALETTE AND THE HOME PAGE'S, as this site's own design tokens. Written as `@theme`
  # rather than as a hundred arbitrary hex values in the markup, because a site's CSS bundle only
  # contains the classes its own templates can be scanned for — and a token is one name the whole
  # site shares.
  #
  # The first block is what the error pages and the dev seeds' pages are written in; the second is
  # the home page's, where every colour that changes in the dark has a `-dark` twin and the markup
  # pairs them with `dark:`. A colour that is the same in both (`edge-hover`) has none. The third is
  # what the extensions' pages share, which the blog's and the docs' kits wrote as hex values of
  # their own before it was here; `brand-dark` is the brand of the second block, on a dark page.
  #
  # `site-bleed` is the one utility: a section that runs edge to edge inside the layout's column.
  # The negative margin reaches the window's edges and the padding brings the content back to the
  # column's, both measured against the column the section sits in. The layout clips what the
  # scrollbar would add, so no page scrolls sideways.
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

  /* The home page: its light and dark colours, and the three typefaces it is set in. */
  @theme {
    --color-page: #faf9f6;
    --color-page-dark: #131217;
    --color-fg: #1a1a1f;
    --color-fg-dark: #eceaf2;
    --color-dim: #6b6a72;
    --color-dim-dark: #a09eab;
    --color-subtle: #8a8892;
    --color-subtle-dark: #8c8a96;
    --color-faint: #a3a0a9;
    --color-faint-dark: #6e6c78;
    --color-surface: #ffffff;
    --color-surface-dark: #1b1a20;
    --color-edge: #ece9e2;
    --color-edge-dark: #2a2930;
    --color-sunk: #fbfaf8;
    --color-sunk-dark: #17161b;
    --color-chip: #dcd8f7;
    --color-chip-dark: #3a3560;
    --color-dot: #e4e1d9;
    --color-dot-dark: #26252c;
    --color-wash: #f7f6fd;
    --color-wash-dark: #211f2b;
    --color-brand: #5b4fe0;
    --color-brand-deep: #4338ca;
    --font-geist: "Geist", system-ui, sans-serif;
    --font-geist-mono: "Geist Mono", monospace;
    --font-newsreader: "Newsreader", Georgia, serif;
  }

  /* What the extensions' pages share: six tints, each a surface and its ink, the wash behind a
     chosen chip, the brand on a dark page, the text of a long read, the edge a hovered card takes
     and the ink of a warning. */
  @theme {
    --color-tint-1: #e7f1ee;
    --color-tint-1-ink: #2f6b5e;
    --color-tint-1-dark: #1d2b28;
    --color-tint-1-ink-dark: #8fd1bf;
    --color-tint-2: #eceafb;
    --color-tint-2-ink: #5b4fe0;
    --color-tint-2-dark: #24223a;
    --color-tint-2-ink-dark: #a9a2f7;
    --color-tint-3: #faefdc;
    --color-tint-3-ink: #9a6412;
    --color-tint-3-dark: #2e2618;
    --color-tint-3-ink-dark: #e6b86a;
    --color-tint-4: #f6e7eb;
    --color-tint-4-ink: #a13d5a;
    --color-tint-4-dark: #2e1f24;
    --color-tint-4-ink-dark: #e89ab0;
    --color-tint-5: #e7edf7;
    --color-tint-5-ink: #3b5e99;
    --color-tint-5-dark: #1d2433;
    --color-tint-5-ink-dark: #93b2e8;
    --color-tint-6: #efede6;
    --color-tint-6-ink: #6b6650;
    --color-tint-6-dark: #26251f;
    --color-tint-6-ink-dark: #c9c3a6;
    --color-chip-wash: #eceafb;
    --color-chip-wash-dark: #25223f;
    --color-brand-dark: #a9a2f7;
    --color-body: #3a3940;
    --color-body-dark: #c9c7d2;
    --color-edge-hover: #b9b2f3;
    --color-warn-ink: #a26a10;
    --color-warn-ink-dark: #e6b86a;
    --color-warn-wash: #fbf0dc;
    --color-warn-wash-dark: #2e2618;
  }

  /* A section that runs from one edge of the window to the other, its content in the column. */
  @utility site-bleed {
    margin-inline: calc(50% - 50vw);
    padding-inline: calc(50vw - 50%);
  }
  """

  # THE LOGO'S NAME IN THE MEDIA LIBRARY, which is what `Media.upload_name/1` makes of the file's
  # name and what the row's own `slugify` leaves alone — so the name asked for before the file is
  # stored is the name the row carries after.
  @logo_file "mishka-logo.png"
  @logo_name "mishka-logo"

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
          media: [String.t()],
          components: [String.t()],
          layouts: [String.t()],
          pages: [String.t()],
          error_pages: [String.t()],
          renamed_pages: [PageProvision.renamed()],
          skipped_pages: [PageProvision.held()],
          upgraded: [String.t()]
        }

  @typedoc """
  A link the header carries, as the `:nav` option takes it: `{label, path}` (or the same as
  `%{label:, path:}`), the path being what follows the language, or a group of them,
  `%{label:, children:}`, which the header draws as a dropdown (see "Grouped links" above). A
  group's children are links; a group does not hold another group.
  """
  @type nav_link :: {String.t(), String.t()} | %{label: String.t(), path: String.t()}
  @type nav_entry :: nav_link() | %{label: String.t(), children: [nav_link()]}

  @typedoc """
  What `upgrade/1` changed, by name: `"site-theme"`, `"site-header"`, `"site-main"`, and the home
  page's path.
  """
  @type upgraded :: [String.t()]

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

    * `:nav` — extra links for the header, as `[t:nav_entry/0]`: `{label, path}` where the path is
      what follows the language (`{"Pricing", "/pricing"}`), or a group of them,
      `%{label: "Dev", children: [{"Pricing", "/pricing"}, …]}` — see "Grouped links" above. The dev
      seeds use it to reach the pages they add.
    * `:brand` — the name to print in the header. Defaults to the site's name, which the create
      action has slugified.
    * `:extra_pages` — page definitions (`%{name:, title:, path:, description:, template:}`) written
      after the home page, stamped and held the way the home is. The dev seeds hand it the about,
      contact and privacy pages a first install no longer has, and so every dev site's `/` is the
      home a first install writes, not a copy of it.
    * `:pages` — page definitions written IN PLACE of the installer's home page, for a caller that
      ships a home of its own. The dev seeds do not: a home they wrote would be a home no
      production install draws.
    * `:root_layout_template` — the error page's root layout, for a caller that ships its own.

  Every page is drawn in the same column, the layout's (`MishkaCmsCore.Runtime.SiteLayout`), so
  there is no option for its width: the dev sites are drawn as a stranger's install is.

  The rows it finds are brought up to date by `upgrade/1`, whose answer is `upgraded`.

  The logo goes in the master site's media library, `site` or not — see "The logo" above — and
  `media` in the report names it when this call stored it. Raises when the site is not there, when
  `site` is not the master and there is none, or when a write is refused for any reason but a page
  being taken — the installer shows the failure on its own progress list. `seed/2` answers the
  first two instead.
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

    # THE THEME BEFORE THE MARKUP THAT READS IT, the logo and the components before the layout that
    # draws them: a layout compiled against a `site-header` that is not there renders the red
    # "Component failed to render!" box where the header should be and reports success.
    stylesheets = ensure_theme(site)
    {logo, media} = ensure_logo(site)
    components = ensure_components(site, brand, logo)
    {layout, layouts} = ensure_layout(site, brand, opts)

    pages =
      Keyword.get_lazy(opts, :pages, fn -> [home(logo)] end) ++
        Keyword.get(opts, :extra_pages, [])

    %{created: created, renamed: renamed, skipped: skipped} =
      site_id
      |> PageProvision.missing(page_attrs(site, layout.id, pages), stamp: :mishka_cms_core)
      |> PageProvision.create(&write_page!/1)

    %{
      layout_id: layout.id,
      stylesheets: stylesheets,
      media: media,
      components: components,
      layouts: layouts,
      pages: Enum.map(created, & &1.path),
      error_pages: ensure_error_page(site, Keyword.get(opts, :root_layout_template)),
      renamed_pages: renamed,
      skipped_pages: skipped,
      # AFTER THE WRITES, so a row this call wrote is current already and only one it found is
      # looked at.
      upgraded: upgrade(site)
    }
  end

  @doc """
  `seed!/2`, answering `{:error, :site_not_found}` for a site that is not there and
  `{:error, :no_master_site}` for a site that is not the master on an install that has none,
  where the logo would be kept, instead of raising. Any other refusal still raises.

  For the `"provision"` job of a site created in the admin
  (`MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker`).
  """
  @spec seed(map() | String.t(), keyword()) ::
          {:ok, report()} | {:error, :site_not_found | :no_master_site}
  def seed(site, opts \\ [])

  def seed(site_id, opts) when is_binary(site_id) do
    case find_site(site_id) do
      nil -> {:error, :site_not_found}
      site -> seed(site, opts)
    end
  end

  def seed(%{id: _site_id} = site, opts) do
    if Map.get(site, :master) == true or master_site() != nil,
      do: {:ok, seed!(site, opts)},
      else: {:error, :no_master_site}
  end

  defp page_attrs(%{id: site_id}, layout_id, pages) do
    Enum.map(pages, fn definition ->
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
  # The logo
  # ---------------------------------------------------------------------------

  # A FILE OF THE MASTER SITE'S MEDIA LIBRARY, and the address every template below draws. Found by
  # its name: the row there is the one the header, the footer and the home page already name, so a
  # second run stores nothing. A row that is archived is not one a page can show — its file is in
  # `uploads_archived/`, which nothing serves — so it is written again, which the name allows
  # because it is unique among the live rows only.
  defp ensure_logo(site) do
    master_id = master_site_id(site)

    case held_row(Media, master_id, @logo_name) do
      %{relative_path: path} -> {path, []}
      nil -> {store_logo!(master_id), [@logo_name]}
    end
  end

  defp master_site_id(%{master: true, id: site_id}), do: site_id
  defp master_site_id(_site), do: master_site!().id

  defp master_site! do
    case master_site() do
      nil -> raise ArgumentError, "no master site to keep the logo in"
      site -> site
    end
  end

  defp master_site do
    Site
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(master == true)
    |> Ash.read_one!(authorize?: false)
  end

  # THE RESOURCE'S OWN UPLOAD PATH, as the media manager takes a file: `validate_and_process_file/1`
  # checks it, `save_file_to_storage/3` puts it in `uploads/<site>/media/`, and the row is made with
  # the path the server stored it at — `stored_path` is private, so no caller can name one.
  #
  # STORED FROM A COPY, because storing removes the file it is handed and this one ships with the
  # package. A refused row takes its file with it, as an upload's does.
  defp store_logo!(site_id) do
    staged = Path.join(System.tmp_dir!(), "mishka-install-#{Ash.UUID.generate()}-#{@logo_file}")
    File.cp!(logo_path(), staged)

    with {:ok, upload} <-
           Media.validate_and_process_file(%{
             file: Ash.Type.File.from_path(staged),
             original_filename: @logo_file
           }),
         {:ok, path} <- Media.save_file_to_storage(upload, site_id, nil) do
      Media
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: @logo_name,
          type: upload.type,
          size: upload.size,
          format: upload.format,
          description: "The Mishka CMS logo."
        },
        tenant: site_id,
        authorize?: false,
        private_arguments: %{stored_path: path}
      )
      |> Ash.create()
      |> case do
        {:ok, _media} ->
          path

        {:error, error} ->
          Media.delete_file_from_storage(path, site_id)
          raise error
      end
    else
      {:error, error} ->
        File.rm(staged)
        raise error
    end
  end

  defp logo_path do
    case :code.priv_dir(:mishka_cms_core) do
      {:error, _unnamed} -> Path.join(["priv", "install", @logo_file])
      priv -> Path.join([to_string(priv), "install", @logo_file])
    end
  end

  # ---------------------------------------------------------------------------
  # The two components every page is framed by
  # ---------------------------------------------------------------------------

  # `brand` DEFAULTS TO THE SITE'S OWN NAME, written into the row as the attribute's default. That is
  # what makes the scoping visible without reading a database — the same `site-header` renders one
  # name on one site and another on the next. `logo` is the same kind of default: the address of
  # the picture in the master site's media library.
  #
  # `lang` is passed IN rather than read here: a component is handed only the assigns its call site
  # writes, and the language of a response lives on the page. The layout reads it once and hands it
  # to both.
  defp ensure_components(%{id: site_id}, brand, logo) do
    specs = components(brand, logo)
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

  # BOTH ARE THE DESIGN'S, LINE FOR LINE, in Tailwind's utilities: a colour that changes in the dark
  # is written twice, `text-fg dark:text-fg-dark`, with both values in the theme. The logo is black
  # line art, so the dark page inverts it, as the design's own filter does.
  #
  # EVERY LINK OUT OPENS A NEW TAB WITH `noopener noreferrer`, as the sign-in layout's do; every link
  # in goes through `site_path/2`.
  defp components(brand, logo) do
    [
      %{
        name: "site-header",
        description: "The bar across the top of every page on #{brand}.",
        template: ~S"""
        <header
          phx-click-away={
            JS.add_class("max-lg:hidden", to: "#site-menu")
            |> JS.set_attribute({"aria-expanded", "false"}, to: "#site-menu-button")
          }
          phx-window-keydown={
            JS.focus(to: "#site-menu-button[aria-expanded=true]")
            |> JS.add_class("max-lg:hidden", to: "#site-menu")
            |> JS.set_attribute({"aria-expanded", "false"}, to: "#site-menu-button")
          }
          phx-key="Escape"
          class={[
            "relative mx-auto flex w-full max-w-[1160px] items-center justify-between gap-4 px-8 py-6 lg:gap-6",
            @class
          ]}
        >
          <.link
            navigate={site_path("/:lang", @lang)}
            class="flex min-w-0 items-center gap-3 text-fg dark:text-fg-dark"
          >
            <img
              src={@logo}
              alt=""
              class="size-10 shrink-0 max-w-none object-contain dark:invert-[0.92]"
            />
            <span class="truncate text-[18px] font-semibold tracking-[-0.01em]">{@brand}</span>
          </.link>
          <%!-- Below `lg` the bar does not fit: what is on its right sits in the panel after this button. --%>
          <button
            type="button"
            id="site-menu-button"
            aria-label="Menu"
            aria-controls="site-menu"
            aria-expanded="false"
            phx-click={
              JS.toggle_class("max-lg:hidden", to: "#site-menu")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
            class="group grid size-[38px] shrink-0 cursor-pointer place-items-center rounded-[11px] border border-edge bg-surface p-0 text-fg lg:hidden dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              class="group-aria-expanded:hidden"
            >
              <path d="M4 7h16M4 12h16M4 17h16"></path>
            </svg>
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              class="hidden group-aria-expanded:block"
            >
              <path d="M6 6l12 12M18 6L6 18"></path>
            </svg>
          </button>
          <div
            id="site-menu"
            class="flex shrink-0 items-center gap-[22px] text-[14px] max-lg:absolute max-lg:end-8 max-lg:top-[calc(100%-0.75rem)] max-lg:z-50 max-lg:hidden max-lg:w-[min(22rem,calc(100%-4rem))] max-lg:flex-col max-lg:items-stretch max-lg:gap-1 max-lg:rounded-[14px] max-lg:border max-lg:border-edge max-lg:bg-surface max-lg:p-2 max-lg:shadow-[0_18px_44px_rgba(30,28,24,0.16)] dark:max-lg:border-edge-dark dark:max-lg:bg-surface-dark dark:max-lg:shadow-[0_18px_44px_rgba(0,0,0,0.5)]"
          >
            <div class="contents max-lg:flex max-lg:flex-col max-lg:gap-0.5 max-lg:[&>a]:rounded-[9px] max-lg:[&>a]:px-[11px] max-lg:[&>a]:py-[9px] max-lg:[&>a]:hover:bg-wash dark:max-lg:[&>a]:hover:bg-wash-dark">
              {render_slot(@inner_block)}
              <.link
                href="https://mishka.tools/docs"
                target="_blank"
                rel="noopener noreferrer"
                class="text-dim dark:text-dim-dark"
              >
                Docs
              </.link>
              <.link
                href="https://github.com/mishka-group/mishka_cms"
                target="_blank"
                rel="noopener noreferrer"
                class="text-dim dark:text-dim-dark"
              >
                GitHub
              </.link>
            </div>
            <div class="contents max-lg:mt-1 max-lg:flex max-lg:flex-wrap max-lg:items-start max-lg:gap-2 max-lg:border-t max-lg:border-edge max-lg:pt-3 dark:max-lg:border-edge-dark">
              <%!-- Two languages or more: a page in one has nothing to switch to. --%>
              <div
                :if={match?([_, _ | _], @editions)}
                phx-click-away={
                  JS.hide(to: "#site-language-menu")
                  |> JS.set_attribute({"aria-expanded", "false"}, to: "#site-language-button")
                }
                phx-window-keydown={
                  JS.hide(to: "#site-language-menu")
                  |> JS.set_attribute({"aria-expanded", "false"}, to: "#site-language-button")
                }
                phx-key="Escape"
                class="relative max-lg:basis-full"
              >
                <button
                  type="button"
                  id="site-language-button"
                  aria-label="Language"
                  aria-haspopup="menu"
                  aria-expanded="false"
                  phx-click={
                    JS.toggle(to: "#site-language-menu")
                    |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                  }
                  class="flex h-[38px] cursor-pointer items-center gap-1.5 rounded-[11px] border border-edge bg-surface px-2.5 text-[13px] font-medium text-fg max-lg:w-full dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
                >
                  <span aria-hidden="true" class="text-[16px] leading-none">
                    {MishkaCmsCore.Runtime.Languages.flag(@lang)}
                  </span>
                  <span class="uppercase">{@lang}</span>
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    class="text-faint max-lg:ms-auto dark:text-faint-dark"
                  >
                    <path d="M6 9l6 6 6-6"></path>
                  </svg>
                </button>
                <div
                  id="site-language-menu"
                  role="menu"
                  class="absolute end-0 top-[46px] z-50 hidden min-w-[190px] overflow-hidden rounded-[14px] border border-edge bg-surface p-1.5 shadow-[0_18px_44px_rgba(30,28,24,0.16)] max-lg:static max-lg:mt-1.5 max-lg:min-w-0 max-lg:shadow-none dark:border-edge-dark dark:bg-surface-dark dark:shadow-[0_18px_44px_rgba(0,0,0,0.5)] dark:max-lg:shadow-none"
                >
                  <%!-- An `href`, not a `<.link navigate>`: `<html lang dir>` is drawn once per HTTP
                        response, so a live navigation into another language would keep the first
                        one's. --%>
                  <a
                    :for={edition <- @editions}
                    role="menuitem"
                    href={edition.path}
                    hreflang={edition.language}
                    title={Map.get(edition, :title)}
                    aria-current={edition.language == @lang && "true"}
                    class={[
                      "flex items-center gap-[11px] rounded-[9px] px-[11px] py-[9px] text-[13px] hover:bg-wash dark:hover:bg-wash-dark",
                      (edition.language == @lang && "font-semibold text-brand") ||
                        "font-medium text-fg dark:text-fg-dark"
                    ]}
                  >
                    <span aria-hidden="true" class="text-[16px] leading-none">
                      {MishkaCmsCore.Runtime.Languages.flag(edition.language)}
                    </span>
                    <span class="flex-1">
                      {Map.get(edition, :name) || MishkaCmsCore.Runtime.Languages.name(edition.language)}
                    </span>
                    <svg
                      :if={edition.language == @lang}
                      width="15"
                      height="15"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M20 6L9 17l-5-5"></path>
                    </svg>
                  </a>
                </div>
              </div>
              <button
                type="button"
                id="site-theme-dark"
                aria-label="Toggle dark mode"
                phx-click={JS.dispatch("phx:set-theme")}
                data-phx-theme="dark"
                class="grid size-[38px] cursor-pointer place-items-center rounded-[11px] border border-edge bg-surface p-0 text-fg dark:hidden dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
              >
                <svg
                  width="17"
                  height="17"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"></path>
                </svg>
              </button>
              <button
                type="button"
                id="site-theme-light"
                aria-label="Toggle dark mode"
                phx-click={JS.dispatch("phx:set-theme")}
                data-phx-theme="light"
                class="hidden size-[38px] cursor-pointer place-items-center rounded-[11px] border border-edge bg-surface p-0 text-fg dark:grid dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
              >
                <svg
                  width="17"
                  height="17"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="#E0B84A"
                  stroke-width="1.8"
                  stroke-linecap="round"
                >
                  <circle cx="12" cy="12" r="4"></circle>
                  <path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4">
                  </path>
                </svg>
              </button>
              <.link
                :if={!@current_user}
                navigate={site_path("/:lang/auth", @lang)}
                class="flex h-[38px] items-center rounded-[11px] border border-edge bg-surface px-4 font-medium text-fg max-lg:flex-1 max-lg:justify-center dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
              >
                Sign in
              </.link>
              <div
                :if={@current_user}
                phx-click-away={
                  JS.hide(to: "#site-user-menu")
                  |> JS.set_attribute({"aria-expanded", "false"}, to: "#site-user-button")
                }
                phx-window-keydown={
                  JS.hide(to: "#site-user-menu")
                  |> JS.set_attribute({"aria-expanded", "false"}, to: "#site-user-button")
                }
                phx-key="Escape"
                class="relative max-lg:min-w-0 max-lg:flex-1"
              >
                <button
                  type="button"
                  id="site-user-button"
                  aria-haspopup="menu"
                  aria-expanded="false"
                  phx-click={
                    JS.toggle(to: "#site-user-menu")
                    |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                  }
                  class="flex h-[38px] cursor-pointer items-center gap-2 rounded-[11px] border border-edge bg-surface ps-1.5 pe-3 font-medium text-fg max-lg:w-full dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
                >
                  <span class="grid size-[26px] place-items-center rounded-full bg-[linear-gradient(180deg,#6A60EC,#5246D6)] text-[12px] font-semibold text-white">
                    {String.upcase(String.first(to_string(@current_user.email)) || "?")}
                  </span>
                  <span
                    id="site-user-email"
                    class="max-w-[180px] truncate max-lg:min-w-0 max-lg:max-w-none max-lg:flex-1 max-lg:text-start"
                  >
                    {to_string(@current_user.email)}
                  </span>
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    class="text-faint dark:text-faint-dark"
                  >
                    <path d="M6 9l6 6 6-6"></path>
                  </svg>
                </button>
                <div
                  id="site-user-menu"
                  role="menu"
                  class="absolute end-0 top-[46px] z-50 hidden w-[250px] overflow-hidden rounded-[14px] border border-edge bg-surface shadow-[0_18px_44px_rgba(30,28,24,0.16)] max-lg:static max-lg:mt-1.5 max-lg:w-full max-lg:shadow-none dark:border-edge-dark dark:bg-surface-dark dark:shadow-[0_18px_44px_rgba(0,0,0,0.5)] dark:max-lg:shadow-none"
                >
                  <div class="border-b border-edge px-4 py-3 dark:border-edge-dark">
                    <div class="text-[11.5px] text-subtle dark:text-subtle-dark">Signed in as</div>
                    <div class="mt-0.5 truncate text-[13px] font-semibold text-fg dark:text-fg-dark">
                      {to_string(@current_user.email)}
                    </div>
                  </div>
                  <div class="p-1.5">
                    <.link
                      :if={MishkaCmsCore.Sidebar.landing_path(@current_user) != "/"}
                      id="site-admin-console"
                      role="menuitem"
                      href={MishkaCmsCore.Sidebar.landing_path(@current_user)}
                      class="flex items-center gap-[11px] rounded-[9px] px-[11px] py-[9px] text-[13px] font-medium text-fg hover:bg-wash dark:text-fg-dark dark:hover:bg-wash-dark"
                    >
                      <svg
                        width="16"
                        height="16"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="1.8"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        class="text-dim dark:text-dim-dark"
                      >
                        <rect x="3" y="3" width="7" height="7"></rect>
                        <rect x="14" y="3" width="7" height="7"></rect>
                        <rect x="14" y="14" width="7" height="7"></rect>
                        <rect x="3" y="14" width="7" height="7"></rect>
                      </svg>
                      Admin console
                    </.link>
                    <.link
                      :if={MishkaCmsCore.Sidebar.landing_path(@current_user) != "/"}
                      id="site-account-settings"
                      role="menuitem"
                      href="/admin/dashboard/settings?tab=preferences"
                      class="flex items-center gap-[11px] rounded-[9px] px-[11px] py-[9px] text-[13px] font-medium text-fg hover:bg-wash dark:text-fg-dark dark:hover:bg-wash-dark"
                    >
                      <svg
                        width="16"
                        height="16"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="1.8"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        class="text-dim dark:text-dim-dark"
                      >
                        <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
                        <circle cx="12" cy="7" r="4"></circle>
                      </svg>
                      Account settings
                    </.link>
                    <div
                      :if={MishkaCmsCore.Sidebar.landing_path(@current_user) != "/"}
                      class="mx-1 my-1.5 h-px bg-edge dark:bg-edge-dark"
                    >
                    </div>
                    <%!-- The sign-out route answers a DELETE, which is what the sign-out page's own form sends; `<.form>` adds the method override and the CSRF token. --%>
                    <.form for={%{}} id="site-sign-out-form" action="/auth/sign-out" method="delete">
                      <button
                        type="submit"
                        id="site-sign-out"
                        role="menuitem"
                        class="flex w-full cursor-pointer items-center gap-[11px] rounded-[9px] px-[11px] py-[9px] text-start text-[13px] font-semibold text-bad hover:bg-bad/10"
                      >
                        <svg
                          width="16"
                          height="16"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="1.8"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path>
                          <path d="M16 17l5-5-5-5"></path>
                          <path d="M21 12H9"></path>
                        </svg>
                        Sign out
                      </button>
                    </.form>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </header>
        """,
        attrs: [
          brand_attr(brand, "The name shown on the left."),
          logo_attr(logo),
          lang_attr(),
          user_attr(),
          editions_attr(),
          class_attr("Extra classes for the header itself")
        ],
        slots: [slot("Extra links, placed before this site's own")]
      },
      %{
        name: "site-footer",
        description: "The strip along the bottom of every page on #{brand}.",
        template: ~S"""
        <footer class={["border-t border-edge dark:border-edge-dark", @class]}>
          <div class="mx-auto flex max-w-[1160px] flex-wrap items-center justify-between gap-4 px-8 py-[22px] text-[13px] text-subtle dark:text-subtle-dark">
            <span class="flex items-center gap-2.5">
              <img
                src={@logo}
                alt=""
                class="size-5 max-w-none object-contain opacity-70 dark:invert-[0.92]"
              />
              <span>
                © {Date.utc_today().year} · Powered by
                <.link
                  href="https://mishka.tools/cms"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-brand hover:text-brand-deep"
                >Mishka CMS</.link>
                · open source
              </span>
            </span>
            <div class="flex gap-5">
              <.link
                href="https://mishka.tools/docs"
                target="_blank"
                rel="noopener noreferrer"
                class="text-subtle dark:text-subtle-dark"
              >
                Docs
              </.link>
              <.link
                href="https://github.com/mishka-group/mishka_cms"
                target="_blank"
                rel="noopener noreferrer"
                class="text-subtle dark:text-subtle-dark"
              >
                GitHub
              </.link>
              <.link
                href="https://mishka.tools/sponsor"
                target="_blank"
                rel="noopener noreferrer"
                class="text-subtle dark:text-subtle-dark"
              >
                Sponsor
              </.link>
              {render_slot(@inner_block)}
            </div>
          </div>
        </footer>
        """,
        attrs: [
          logo_attr(logo),
          class_attr("Extra classes for the footer itself")
        ],
        slots: [slot("Anything to put beside the links")]
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

  defp logo_attr(logo) do
    %{
      "name" => "logo",
      "type" => "string",
      "opts" => %{
        "default" => logo,
        "doc" =>
          "The address of the logo. Defaults to the one in the master site's media library."
      }
    }
  end

  defp lang_attr do
    %{
      "name" => "lang",
      "type" => "string",
      "opts" => %{
        "default" => nil,
        "doc" => "The language the links stay in. The site's first language when not given."
      }
    }
  end

  defp user_attr do
    %{
      "name" => "current_user",
      "type" => "any",
      "opts" => %{
        "default" => nil,
        "doc" => "`@current_user`, the signed-in visitor. Their menu takes the place of Sign in."
      }
    }
  end

  defp editions_attr do
    %{
      "name" => "editions",
      "type" => "any",
      "opts" => %{
        "default" => [],
        "doc" =>
          "`@page_languages`: the page in each language it is written in, each with its `path` and `name` (`MishkaCmsCore.Runtime.SiteLayout`), the current one among them. The switcher shows when there are two."
      }
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

  # THE CONTENT COLUMN EVERY PAGE IS DRAWN IN, the home design's: 1160 px, 32 px at the sides and
  # 96 px under the last section — the same on every site, dev ones included. A page draws its
  # sections straight into it; see `MishkaCmsCore.Runtime.SiteLayout`.
  @column ~s(<main id="site-main" class="mx-auto w-full max-w-[1160px] flex-1 px-8 pb-24">{@inner_content}</main>)

  # WHAT AN EARLIER RELEASE WROTE where the column is now: the whole width, for a home page that drew
  # its own, and the centred column with room above and below that the dev seeds asked for.
  @earlier_mains [
    ~s(<main class="flex w-full flex-1 flex-col">{@inner_content}</main>),
    ~s(<main class="mx-auto w-full max-w-[1160px] flex-1 px-8 py-10">{@inner_content}</main>)
  ]

  # THE FRAME CLIPS WHAT A `site-bleed` SECTION'S `100vw` ADDS where the window has a scrollbar, so no
  # page scrolls sideways. `clip`, not `hidden`: it makes no scroll container, so a sticky element
  # inside a page still sticks.
  @frame_open ~s(<div class="flex min-h-screen flex-col overflow-x-clip bg-page font-geist)
  @earlier_frame_open ~s(<div class="flex min-h-screen flex-col bg-page font-geist)
  @flash_open ~s(<div :if={@flash != %{}} id="site-flash")
  @section_bar "MishkaCmsCore.Runtime.SiteLayout.section_bar"

  # EVERY PAGE TITLED ONE WAY, `Pricing · Acme`: the page's own title — on a page that shows a record
  # per address, the record's — then the site's. Stored on the layouts, so a page's own title tag
  # still wins; a site with no title keeps the bare title, since an unfilled variable leaves the tag
  # out. See `MishkaCmsCore.Runtime.Seo`.
  @titled [%{tag: "title", attrs: %{}, content: "{{page.title}} · {{site.name}}"}]

  # THE TWO TYPEFACES THE THEME CANNOT SHIP, linked from the head. Tailwind drops an `@import url()`
  # that follows any rule, and a UI kit's global theme is one; and a stylesheet `<link>` in the
  # layout's body is not where a document expects one. A layout's `seo_tags` are where a layout
  # reaches `<head>`, and `MishkaCmsWeb.RuntimeLive.page_head/1` draws every `link` among them.
  # Newsreader is the host's own (`/fonts/fonts.css`), and the public Content-Security-Policy names
  # Google's two font origins.
  @fonts [
    %{tag: "link", attrs: %{"rel" => "preconnect", "href" => "https://fonts.googleapis.com"}},
    %{
      tag: "link",
      attrs: %{
        "rel" => "preconnect",
        "href" => "https://fonts.gstatic.com",
        "crossorigin" => "anonymous"
      }
    },
    %{
      tag: "link",
      attrs: %{
        "rel" => "stylesheet",
        "href" =>
          "https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&display=swap"
      }
    }
  ]

  # THE LAYOUT SHOWS THE MESSAGES, so a page does not have to. A compiled page prepends a flash
  # region of its own only when its layout has none — see
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.shows_messages?/1` — and a site that styles
  # its own is the better place for them.
  #
  # NO `<body>`: this is rendered INSIDE the application's root layout, and a second one nests a
  # document in a document.
  defp ensure_layout(%{id: site_id, name: site_name}, brand, opts) do
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
              template: layout_template(site_name, Keyword.get(opts, :nav, [])),
              seo_tags: @titled ++ @fonts,
              format: :heex,
              helpers: [
                %{
                  name: "lang",
                  args: "assigns",
                  code: ~S"""
                  (assigns[:page] || %{})[:language] ||
                    MishkaCmsCore.Runtime.Languages.primary(MishkaCmsCore.Runtime.Translations.site())
                  """
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

  # THE LAYOUT IS THE DESIGN'S FRAME, the header and the footer around whatever the page draws: a
  # column at least as tall as the window, so the footer sits at the bottom of a short page; under
  # the header, the bar a page hands the layout, when it has one; and the page itself in the content
  # column. `@page_languages` and `@page_section_bar` are `MishkaCmsCore.Runtime.SiteLayout`'s.
  defp layout_template(site_name, nav) do
    ~s"""
    #{@frame_open} leading-[normal] text-fg [transition:background_.2s,color_.2s] dark:bg-page-dark dark:text-fg-dark">
      <.component
        component_name="site-header"
        site="#{site_name}"
        lang={lang(assigns)}
        current_user={assigns[:current_user]}
        editions={assigns[:page_languages] || []}
      >#{nav_links(nav)}
      </.component>
      #{section_bar_call(site_name)}
      #{@flash_open} class="mx-auto mt-5 w-full max-w-[1160px] px-8">
        <p
          :for={{kind, message} <- @flash}
          id={"site-flash-\#{kind}"}
          role={if(kind == "error", do: "alert", else: "status")}
          phx-click="lv:clear-flash"
          phx-value-key={kind}
          title="Dismiss"
          class={[
            "cursor-pointer rounded-[10px] border bg-surface px-4 py-3 text-[13px] font-medium dark:bg-surface-dark",
            kind == "error" && "border-bad text-bad",
            kind != "error" && "border-ok text-ok"
          ]}
        >
          {message}
        </p>
      </div>
      #{@column}
      <.component component_name="site-footer" site="#{site_name}" />
    </div>
    """
  end

  defp section_bar_call(site_name),
    do: ~s(<#{@section_bar} bar={assigns[:page_section_bar]} site="#{site_name}" />)

  # A PLAIN LINK IS WRITTEN EXACTLY AS IT ALWAYS WAS: the text below is what a site that passes no
  # group has in its layout, and the tests pin it. A group (`nav_group/3`) is written beside it.
  defp nav_links(nav) do
    nav
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {%{label: label, children: children}, index} ->
        nav_group(label, Enum.map(children, &nav_target/1), index)

      {entry, _index} ->
        entry |> nav_target() |> nav_link()
    end)
  end

  defp nav_target({label, path}), do: {label, path}
  defp nav_target(%{label: label, path: path}), do: {label, path}

  defp nav_link({label, path}) do
    ~s"""

        <.link navigate={site_path("/:lang#{path}", lang(assigns))} class="text-dim dark:text-dim-dark">#{label}</.link>\
    """
  end

  # A GROUP OF LINKS, TWICE: the header's language dropdown from `lg` up, and a labelled list in
  # the phone's panel. See "Grouped links" above for why two sets of elements and not one restyled.
  #
  # THE DROPDOWN IS THE LANGUAGE SWITCHER'S, element for element: the wrapper listens for the click
  # away and for Escape (not the menu, so the click on the button that is meant to close an open
  # menu is not "away" from it), the button toggles the menu and `aria-expanded` with the same
  # `JS` commands, and every colour that changes in the dark has its `-dark` twin. The layout does
  # not alias `JS`, hence `Phoenix.LiveView.JS`. Its menu opens from the button's start edge, the
  # bar's end being where the language switcher is.
  #
  # THE IDS ARE THE LABEL'S, `site-nav-dev-button` for "Dev", or the group's position when the label
  # has no letter or digit in it; two groups with one label are one id twice, which is the
  # caller's to avoid. A group with no link is not drawn: a button that opens nothing.
  defp nav_group(_label, [], _index), do: ""

  defp nav_group(label, links, index) do
    base = "site-nav-" <> group_slug(label, index)
    button = base <> "-button"
    menu = base <> "-menu"
    caption = base <> "-label"

    menu_items =
      Enum.map_join(links, "\n", fn {text, path} ->
        ~s|        <.link role="menuitem" navigate={site_path("/:lang#{path}", lang(assigns))} class="flex items-center rounded-[9px] px-[11px] py-[9px] text-[13px] font-medium text-fg hover:bg-wash dark:text-fg-dark dark:hover:bg-wash-dark">#{text}</.link>|
      end)

    panel_items =
      Enum.map_join(links, "\n", fn {text, path} ->
        ~s|      <.link navigate={site_path("/:lang#{path}", lang(assigns))} class="rounded-[9px] px-[11px] py-[9px] text-dim hover:bg-wash dark:text-dim-dark dark:hover:bg-wash-dark">#{text}</.link>|
      end)

    ~s"""

        <div
          phx-click-away={
            Phoenix.LiveView.JS.hide(to: "##{menu}")
            |> Phoenix.LiveView.JS.set_attribute({"aria-expanded", "false"}, to: "##{button}")
          }
          phx-window-keydown={
            Phoenix.LiveView.JS.hide(to: "##{menu}")
            |> Phoenix.LiveView.JS.set_attribute({"aria-expanded", "false"}, to: "##{button}")
          }
          phx-key="Escape"
          class="relative max-lg:hidden"
        >
          <button
            type="button"
            id="#{button}"
            aria-haspopup="menu"
            aria-expanded="false"
            phx-click={
              Phoenix.LiveView.JS.toggle(to: "##{menu}")
              |> Phoenix.LiveView.JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
            class="flex h-[38px] cursor-pointer items-center gap-1.5 rounded-[11px] border border-edge bg-surface px-2.5 text-[13px] font-medium text-fg dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
          >
            <span>#{label}</span>
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              class="text-faint dark:text-faint-dark"
            >
              <path d="M6 9l6 6 6-6"></path>
            </svg>
          </button>
          <div
            id="#{menu}"
            role="menu"
            class="absolute start-0 top-[46px] z-50 hidden min-w-[190px] overflow-hidden rounded-[14px] border border-edge bg-surface p-1.5 shadow-[0_18px_44px_rgba(30,28,24,0.16)] dark:border-edge-dark dark:bg-surface-dark dark:shadow-[0_18px_44px_rgba(0,0,0,0.5)]"
          >
    #{menu_items}
          </div>
        </div>
        <div role="group" aria-labelledby="#{caption}" class="flex flex-col gap-0.5 lg:hidden">
          <span
            id="#{caption}"
            class="px-[11px] pt-2 pb-1 text-[11.5px] font-semibold tracking-wide text-subtle uppercase dark:text-subtle-dark"
          >
            #{label}
          </span>
    #{panel_items}
        </div>\
    """
  end

  defp group_slug(label, index) do
    case label |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") do
      "-" -> "group-#{index}"
      "" -> "group-#{index}"
      slug -> String.trim(slug, "-")
    end
  end

  # ---------------------------------------------------------------------------
  # The pages
  # ---------------------------------------------------------------------------

  # THE OPENING TAG OF EACH OF THE HOME PAGE'S THREE SECTIONS, now and as an earlier release wrote
  # them, when the page drew its own column: `upgrade/1` swaps the one for the other on a home page
  # nobody has edited there.
  @hero_open ~S|<section class="site-bleed relative bg-[radial-gradient(var(--color-dot)_1px,transparent_1px)] bg-size-[24px_24px] bg-position-[center_top] pt-[72px] pb-24 dark:bg-[radial-gradient(var(--color-dot-dark)_1px,transparent_1px)]">|
  @flow_open ~S|<section class="flex flex-col gap-8 pb-24">|
  @steps_open ~S|<section class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,340px),1fr))] gap-5">|

  @earlier_home [
    {~S|<section class="relative bg-[radial-gradient(var(--color-dot)_1px,transparent_1px)] bg-size-[24px_24px] bg-position-[center_top] px-8 pt-[72px] pb-24 dark:bg-[radial-gradient(var(--color-dot-dark)_1px,transparent_1px)]">|,
     @hero_open},
    {~S|<section class="mx-auto flex w-full max-w-[1160px] flex-col gap-8 px-8 pb-24">|,
     @flow_open},
    {~S|<section class="mx-auto grid w-full max-w-[1160px] grid-cols-[repeat(auto-fit,minmax(min(100%,340px),1fr))] gap-5 px-8 pb-24">|,
     @steps_open}
  ]

  @chip_tag ~S|tag_class: "bg-chip-wash text-brand dark:bg-chip-wash-dark dark:text-brand-dark",|
  @warn_tag ~S|tag_class: "bg-warn-wash text-warn-ink dark:bg-warn-wash-dark dark:text-warn-ink-dark",|

  # AND THE TAGS OF HOW A PAGE IS SERVED, which an earlier release wrote in hex values the theme now
  # holds as tokens: swapped wherever they are, with the sections, so an untouched page becomes
  # exactly the one a new site gets.
  @earlier_home_tags [
    {~S|tag_class: "bg-[#ECEAFB] text-brand dark:bg-[#25223F] dark:text-[#A9A2F7]",|, @chip_tag},
    {~S|tag_class: "bg-[#FBF0DC] text-[#A26A10] dark:bg-[#2E2618] dark:text-[#E6B86A]",|,
     @warn_tag}
  ]

  defp home(logo) do
    %{
      name: "Home",
      title: "Home",
      path: "/:lang",
      description: "The first page a visitor sees.",
      template: home_template(logo)
    }
  end

  # THE DESIGN'S THREE SECTIONS, and nothing the layout already draws: the dotted welcome, how a page
  # is served, and the three steps. The steps are plain cards — nothing in them is a link, so
  # nothing in them can be a dead one. Every colour that changes in the dark is written twice, as in
  # the components, and the hero's two gradients, whose stops are not colours of the theme, are
  # written out in both.
  #
  # THE HOST IS THE ONE THING THE PAGE ASKS THE SITE, read off `assigns[:current_site]` with
  # `Map.get/2` because the page builder's canvas hands it a map without one.
  #
  # IN THE LAYOUT'S COLUMN, with no container of its own: the dotted welcome is a `site-bleed` band,
  # from one edge of the window to the other, and the two sections after it fill the column. The
  # layout puts the room under the last one.
  defp home_template(logo) do
    ~s"""
    #{@hero_open}
      <div class="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_60%_70%_at_50%_40%,rgba(250,249,246,0.96)_30%,rgba(250,249,246,0)_100%)] dark:bg-[radial-gradient(ellipse_60%_70%_at_50%_40%,rgba(19,18,23,0.96)_30%,rgba(19,18,23,0)_100%)]">
      </div>
      <div class="relative mx-auto flex max-w-[820px] flex-col items-center gap-7 text-center">
        <div class="grid size-[132px] place-items-center rounded-[36px] border border-edge bg-surface shadow-[0_30px_60px_-30px_rgba(60,50,120,0.25)] dark:border-edge-dark dark:bg-surface-dark">
          <img src="#{logo}" alt="Mishka" class="size-[88px] object-contain dark:invert-[0.92]" />
        </div>
        <div class="inline-flex items-center gap-2.5 rounded-full border border-edge bg-surface py-[7px] pr-3.5 pl-3 font-geist-mono text-[12px] text-dim dark:border-edge-dark dark:bg-surface-dark dark:text-dim-dark">
          <span class="size-[7px] rounded-full bg-[#22A06B] shadow-[0_0_0_4px_#E3F4EB] dark:shadow-[0_0_0_4px_#173528]">
          </span>
          <span class="max-w-[180px] overflow-hidden text-ellipsis whitespace-nowrap">
            {Map.get(assigns[:current_site] || %{}, :host) || "localhost"}
          </span>
          <span class="text-faint dark:text-faint-dark">/</span>
          <span>v{MishkaCmsCore.Helpers.host_version()}</span>
          <span class="text-faint dark:text-faint-dark">/</span>
          <span>runtime ready</span>
        </div>
        <h1 class="font-newsreader text-[clamp(48px,7vw,84px)] leading-none font-normal tracking-[-0.03em] text-balance">
          Mishka is <em class="text-brand italic">up and running</em>.
        </h1>
        <p class="max-w-[560px] text-[18px] leading-[1.6] text-pretty text-dim dark:text-dim-dark">
          You're looking at the default page of a fresh install. Nothing is published yet — sign in to the admin console and start shaping your first site.
        </p>
        <div class="mt-1 flex flex-wrap justify-center gap-3">
          <.link
            navigate={site_path("/:lang/auth", @page.language)}
            class="flex h-[52px] items-center gap-2.5 rounded-[14px] bg-[linear-gradient(180deg,#6A60EC,#5246D6)] px-6 text-[15px] font-medium text-white shadow-[0_10px_24px_-10px_rgba(91,79,224,0.6)]"
          >
            Open admin console
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M5 12h14M13 6l6 6-6 6"></path>
            </svg>
          </.link>
          <.link
            href="https://mishka.tools/cms/docs"
            target="_blank"
            rel="noopener noreferrer"
            class="flex h-[52px] items-center rounded-[14px] border border-edge bg-surface px-[22px] text-[15px] font-medium text-fg dark:border-edge-dark dark:bg-surface-dark dark:text-fg-dark"
          >
            Read the docs
          </.link>
        </div>
      </div>
    </section>

    #{@flow_open}
      <div class="flex flex-col items-center gap-2.5 text-center">
        <span class="text-[12px] font-semibold tracking-[0.16em] text-subtle dark:text-subtle-dark">
          HOW A PAGE IS SERVED
        </span>
        <h2 class="font-newsreader text-[clamp(30px,4vw,42px)] font-normal tracking-[-0.02em] text-balance">
          Every request, composed from parts you own.
        </h2>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,150px),1fr))] gap-3 rounded-3xl border border-edge bg-surface p-7 dark:border-edge-dark dark:bg-surface-dark">
        <div
          :for={
            flow <- [
              %{
                n: "01",
                tag: "request",
                tag_class: "bg-[#F1EFEA] text-dim dark:bg-[#24232A] dark:text-dim-dark",
                title: "Site",
                desc: "Domain resolves to one of your sites — run many from one install.",
                code: "https://" <> (Map.get(assigns[:current_site] || %{}, :host) || "localhost")
              },
              %{
                n: "02",
                tag: "shell",
                #{@chip_tag}
                title: "Layout",
                desc: "A shared frame wraps the page: header, footer, slots.",
                code: "layout: default"
              },
              %{
                n: "03",
                tag: "content",
                tag_class: "bg-[#E3F4EB] text-[#1E8A5A] dark:bg-[#173528] dark:text-[#6FD3A2]",
                title: "Page",
                desc: "Your content, versioned and translatable.",
                code: "path: /"
              },
              %{
                n: "04",
                tag: "blocks",
                #{@warn_tag}
                title: "Components",
                desc: "Reusable pieces with their own dependencies.",
                code: "<doc-section />"
              },
              %{
                n: "05",
                tag: "compiled",
                #{@chip_tag}
                title: "Runtime",
                desc: "Compiled live on the server and delivered fast.",
                code: "200 OK · 12ms"
              }
            ]
          }
          class="relative flex min-h-[170px] flex-col gap-3.5 rounded-2xl border border-dashed border-edge bg-sunk p-5 dark:border-edge-dark dark:bg-sunk-dark"
        >
          <div class="flex items-center justify-between">
            <span class="font-geist-mono text-[11px] text-faint dark:text-faint-dark">{flow.n}</span>
            <span class={["rounded-md px-2 py-[3px] font-geist-mono text-[11px]", flow.tag_class]}>
              {flow.tag}
            </span>
          </div>
          <span class="text-[17px] font-medium">{flow.title}</span>
          <span class="text-[13.5px] leading-[1.55] text-dim dark:text-dim-dark">{flow.desc}</span>
          <span class="mt-auto font-geist-mono text-[12px] break-words text-brand">{flow.code}</span>
        </div>
      </div>
    </section>

    #{@steps_open}
      <div class="flex flex-col gap-3.5 py-2 pe-2">
        <span class="text-[12px] font-semibold tracking-[0.16em] text-subtle dark:text-subtle-dark">
          START HERE
        </span>
        <h2 class="font-newsreader text-[36px] leading-[1.1] font-normal tracking-[-0.02em]">
          Three steps to replace this page.
        </h2>
        <p class="text-[15px] leading-[1.6] text-pretty text-dim dark:text-dim-dark">
          Need more later? Plugins add features like blogs or documentation — install them only when you need them.
        </p>
      </div>
      <div class="flex flex-col overflow-hidden rounded-[20px] border border-edge bg-surface dark:border-edge-dark dark:bg-surface-dark">
        <div
          :for={
            {number, title, detail} <- [
              {"1", "Sign in to the admin console", "Use the master account from installation."},
              {"2", "Pick a layout for your site", "Every page shares it — change it any time."},
              {"3", "Publish a page at “/”", "It replaces this welcome screen automatically."}
            ]
          }
          class="flex items-center gap-[18px] border-t border-edge px-[22px] py-5 text-fg dark:border-edge-dark dark:text-fg-dark"
        >
          <span class="grid size-[34px] flex-none place-items-center rounded-full border border-chip font-geist-mono text-[12px] text-brand dark:border-chip-dark">
            {number}
          </span>
          <span class="flex min-w-0 flex-1 flex-col gap-[3px]">
            <span class="text-[15px] font-medium">{title}</span>
            <span class="text-[13.5px] text-dim dark:text-dim-dark">{detail}</span>
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp write_page!(attrs) do
    Page
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # Bringing an older site up to date
  # ---------------------------------------------------------------------------

  @doc """
  Brings `site`'s starter rows up to this release where that writes over nothing an admin wrote,
  and returns the names of the ones it changed — `"site-theme"`, `"site-header"`, `"site-main"`,
  `"/:lang"` — `[]` when there was nothing to do. See "Bringing an older site up to date" above.

  Takes the site record or its id. A row the site does not have is not written: that is
  `seed!/2`'s. Run it again and it changes nothing.
  """
  @spec upgrade(map() | String.t()) :: upgraded()
  def upgrade(site_id) when is_binary(site_id), do: site_id |> site!() |> upgrade()

  def upgrade(%{id: _site_id, name: _site_name} = site) do
    theme = upgrade_theme(site)
    header = upgrade_header(site)
    layout = upgrade_layout(site)

    # THE HOME PAGE ONLY BESIDE A LAYOUT THAT DRAWS THE COLUMN: without it the page's sections would
    # lose the only column they have.
    home = if framed?(site), do: upgrade_home(site), else: []

    theme ++ header ++ layout ++ home
  end

  # EACH DECLARATION AND THE UTILITY THE ROW DOES NOT HAVE, after everything it has, so a value an
  # admin changed is the one that stands and nothing they wrote moves.
  defp upgrade_theme(%{id: site_id}) do
    case held_row(Stylesheet, site_id, @theme_name) do
      %{content: content} = row when is_binary(content) ->
        case missing_theme(content) do
          "" ->
            []

          missing ->
            update!(row, %{content: String.trim_trailing(content) <> "\n\n" <> missing}, site_id)
            [@theme_name]
        end

      _none ->
        []
    end
  end

  @doc false
  # What `content` lacks of this release's theme, as CSS to append: one `@theme` block of every
  # missing declaration, and the `site-bleed` utility. `""` when it has them all.
  @spec missing_theme(String.t()) :: String.t()
  def missing_theme(content) do
    tokens =
      for [line, name] <- Regex.scan(~r/^\s*(--[a-z0-9-]+)\s*:[^;]*;/m, @theme_css),
          not Regex.match?(~r/(?<![\w-])#{Regex.escape(name)}\s*:/, content),
          do: "  " <> String.trim(line)

    [
      if(tokens != [],
        do: """
        /* Added when this site was brought up to date: the tokens its theme did not have yet. */
        @theme {
        #{Enum.join(tokens, "\n")}
        }
        """
      ),
      if(not Regex.match?(~r/@utility\s+site-bleed\b/, content),
        do:
          Regex.run(~r/\/\* A section that runs.*?\n@utility site-bleed \{.*?\n\}\n/s, @theme_css)
      )
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # THE HEADER AS AN EARLIER RELEASE WROTE IT, WHOLE. Those had a bar that does not fit a phone: the
  # links ran under the logo and Sign in was off the screen. The template is long and every line of
  # it is the design's, so the earlier ones are held as the SHA-256 of the text a row keeps (the
  # template, trimmed), not as a second copy of the markup; the fixtures the tests upgrade from are
  # in `test/fixtures/starter_content`, and `git show <commit>:<this file>` has the source.
  #
  #   * `6ea2fbc`, the one on master: a row of links, the language dropdown, the toggle, Sign in;
  #   * `3dc740b`, this branch's first: the same, with Docs and GitHub hidden below `sm`, the
  #     dropdown only for two languages or more, and each entry titled and named as it was given.
  #
  # A header that differs by a single character is one somebody edited, and is left as it is.
  @header_name "site-header"
  @earlier_headers %{
    "4c46e3ef80533429faca62bc536f8f9a50f919a1f78a34c45f8471d540cbc60c" => "6ea2fbc",
    "439c346b034c354c07e8dcf76a42066893e664db50c35ff2db5bfc49273ae219" => "3dc740b"
  }

  # THE TEMPLATE IS THE ONE A NEW SITE GETS: it reads neither the brand nor the logo, which are the
  # attributes' defaults, so what the row holds does not depend on the arguments.
  defp upgrade_header(%{id: site_id}) do
    with %{template: template} = header when is_binary(template) <-
           held_row(Component, site_id, @header_name),
         true <- Map.has_key?(@earlier_headers, template_digest(template)) do
      update!(header, %{template: header_template()}, site_id)
      [@header_name]
    else
      _current_edited_or_none -> []
    end
  end

  defp header_template do
    ""
    |> components("")
    |> Enum.find(&(&1.name == @header_name))
    |> Map.fetch!(:template)
  end

  defp template_digest(template),
    do: :sha256 |> :crypto.hash(String.trim(template)) |> Base.encode16(case: :lower)

  # THE FRAME, THE MESSAGES AND `<main>` AS AN EARLIER RELEASE WROTE THEM, each once: then the column
  # and the bar go in, and every other line — the header's call, its links, the footer's — is
  # left as it is.
  defp upgrade_layout(%{id: site_id, name: site_name}) do
    with %{template: template} = layout when is_binary(template) <-
           held_row(Layout, site_id, @layout_name),
         false <- String.contains?(template, @section_bar),
         [main] <- Enum.filter(@earlier_mains, &once?(template, &1)),
         true <- once?(template, @earlier_frame_open) and once?(template, @flash_open) do
      upgraded =
        template
        |> String.replace(@earlier_frame_open, @frame_open)
        |> String.replace(@flash_open, section_bar_call(site_name) <> "\n  " <> @flash_open)
        |> String.replace(main, @column)

      update!(layout, %{template: upgraded}, site_id)
      [@layout_name]
    else
      _current_edited_or_none -> []
    end
  end

  defp framed?(%{id: site_id}) do
    case held_row(Layout, site_id, @layout_name) do
      %{template: template} when is_binary(template) -> String.contains?(template, @column)
      _none -> false
    end
  end

  # THE STARTER'S OWN HOME PAGE, its three sections as an earlier release opened them, each once.
  defp upgrade_home(%{id: site_id}) do
    with %{template: template} = home when is_binary(template) <- starter_home(site_id),
         true <- Enum.all?(@earlier_home, fn {earlier, _now} -> once?(template, earlier) end) do
      upgraded =
        Enum.reduce(@earlier_home ++ @earlier_home_tags, template, fn {earlier, now}, acc ->
          String.replace(acc, earlier, now)
        end)

      update!(home, %{template: upgraded}, site_id)
      [home.path]
    else
      _current_edited_or_none -> []
    end
  end

  defp starter_home(site_id) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and path == "/:lang" and section == ^@section)
    |> rows()
    |> Enum.find(&PageProvision.ours?(&1, :mishka_cms_core))
  end

  defp once?(template, fragment), do: length(String.split(template, fragment)) == 2

  # AS A PACKAGE WRITES, under the site's tenant: what changes is what this module wrote, and a
  # template it writes is not one an author typed (`Validations.CodeChange`).
  defp update!(row, attrs, site_id) do
    row
    |> Ash.Changeset.for_update(:update, attrs,
      tenant: site_id,
      authorize?: false,
      context: %{page_code: :package}
    )
    |> Ash.update!()
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
        <a href={site_path("/:lang", @conn.assigns[:site_language])} class="mt-7 inline-block rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white">
          Back home
        </a>
      </div>
      """
    }
  end

  # THE PAGE AN OFFLINE SITE SHOWS, the site's own to reword like its 404 and 500. Without it the
  # gate draws its built-in page, which knows nothing of the site's look. It offers the site's own
  # sign-in, in the language the visitor reads the site in, because the admin who can bring the
  # site back is the one reading it.
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
        <a href={site_path("/:lang/auth", @conn.assigns[:site_language]) <> "?master_user=false"} class="mt-7 inline-block rounded-[9px] bg-[#17161a] px-4 py-2 text-[12px] font-bold text-white">
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

  @doc """
  What the sign-in page of `role` (`"sign_in"`, `"register"`, …, its `extra["auth_role"]`) is
  written with today: `%{template:, events:, helpers:}`, as `ensure_auth!/1` writes them. Nothing
  here updates a page a site already has; this is for a script that brings one up to date, written
  with `context: %{page_code: :package}` as these are. `nil` for a role there is no page for.
  """
  @spec auth_page_code(String.t()) ::
          %{template: String.t(), events: list(), helpers: list()} | nil
  def auth_page_code(role) do
    case Enum.find(auth_pages(), &(&1.role == role)) do
      nil ->
        nil

      page ->
        %{
          template: page.template,
          events: Enum.map(page.events, &auth_event/1),
          helpers: Enum.map(page.helpers, &auth_helper/1)
        }
    end
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

  @navigation ~w(returning return_params)
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
          <.link
            href="https://mishka.tools/cms/extensions/documentation"
            target="_blank"
            rel="noopener noreferrer"
            class="hover:text-[#4f4bcc]"
          >
            {t("Docs")}
          </.link>
          <.link
            href="https://mishka.tools/hire-us"
            target="_blank"
            rel="noopener noreferrer"
            class="hover:text-[#4f4bcc]"
          >
            {t("Support")}
          </.link>
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
      <%= if assigns[:second_factor] || (assigns[:query_params] || %{})["second_step"] do %>
        <div>
          <.link
            navigate={returning(assigns, site_path("/:lang/auth", @page.language))}
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

        <.sign_in_providers
          site={assigns[:current_site]}
          continue_with={t("Continue with %{provider}")}
          class="mt-[26px]"
        >
          <:divider>
            <div class="my-[22px] flex items-center gap-3">
              <span class="h-px flex-1 bg-[#e6e4de]"></span>
              <span class="text-[11.5px] font-semibold uppercase tracking-[0.06em] text-[#6d6a63]">
                {t("or with email")}
              </span>
              <span class="h-px flex-1 bg-[#e6e4de]"></span>
            </div>
          </:divider>
          <:empty><div class="h-[22px]"></div></:empty>
        </.sign_in_providers>

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
                navigate={returning(assigns, site_path("/:lang/auth/magic-link", @page.language))}
                id="auth-go-magic"
                class="#{@link_class}"
              >
                {t("Magic link")}
              </.link>
              <span class="h-[11px] w-px bg-[#e6e4de]"></span>
              <.link
                navigate={returning(assigns, site_path("/:lang/auth/forgot-password", @page.language))}
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
          navigate={returning(assigns, site_path("/:lang/auth/magic-link", @page.language))}
          id="auth-go-magic-cta"
          class="#{@dashed_class}"
        >
          <.bolt_svg size={15} />{t("Email me a magic link instead")}
        </.link>

        <div class="mt-[22px] border-t border-[#ecebe6] pt-[18px] text-center text-[12.5px] font-medium text-[#6d6a63]">
          {t("New to MishkaCMS?")}
          <.link
            navigate={returning(assigns, site_path("/:lang/auth/register", @page.language))}
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
        <.link navigate={returning(assigns, site_path("/:lang/auth", @page.language))} id="auth-back-to-login" class="#{@back_class}">
          <.chevron_left_svg />{t("Back to login")}
        </.link>
        <h1 class="#{@title_class}">{t("Create your account")}</h1>
        <p class="#{@lede_class}">{t("Enter your details to get started.")}</p>
      </div>

      <.sign_in_providers
        site={assigns[:current_site]}
        id="auth-register-providers"
        continue_with={t("Continue with %{provider}")}
        class="mt-6"
      >
        <:divider>
          <div class="mt-[22px] flex items-center gap-3">
            <span class="h-px flex-1 bg-[#e6e4de]"></span>
            <span class="text-[11.5px] font-semibold uppercase tracking-[0.06em] text-[#6d6a63]">
              {t("or with email")}
            </span>
            <span class="h-px flex-1 bg-[#e6e4de]"></span>
          </div>
        </:divider>
      </.sign_in_providers>

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
        <.link navigate={returning(assigns, site_path("/:lang/auth", @page.language))} id="auth-back-to-login" class="#{@back_class}">
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
        <.link navigate={returning(assigns, site_path("/:lang/auth", @page.language))} id="auth-back-to-login" class="#{@back_class}">
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
      <.link navigate={returning(assigns, site_path("/:lang/auth", @page.language))} id="auth-back-to-login" class="#{@back_class}">
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
      <.link navigate={returning(assigns, site_path("/:lang/auth", @page.language))} id="auth-back-to-login" class="#{@back_class}">
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
      <.link navigate={returning(assigns, site_path("/:lang/auth", @page.language))} id="auth-back-to-login" class="#{@back_class}">
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
      # A PROVIDER'S SIGN-IN WAITING FOR ITS CODE holds only the token the page was handed, never an
      # email or a password; see `MishkaCmsCore.Accounts.SecondFactor.Pending`.
      second_step = (socket.assigns[:query_params] || %{})["second_step"]

      if is_binary(second_step) and second_step != "" do
        code = Map.take(params["user"] || %{}, ["totp_code", "recovery_code"])

        MishkaCmsCore.Accounts.User
        |> Ash.Query.for_read(:sign_in_with_second_factor, Map.put(code, "token", second_step),
          tenant: socket.assigns[:current_tenant],
          context: %{private: %{ash_authentication?: true}}
        )
        |> Ash.read_one()
        |> case do
          {:ok, %{} = signed_in} ->
            {:noreply, redirect(socket, to: token_path(socket.assigns, signed_in))}

          {:error, error} when not is_nil(error) ->
            if MishkaCmsCore.Accounts.SecondFactor.refusal(error) in [:invalid, :required],
              do: {:noreply, assign(socket, :message, second_factor_message(:invalid))},
              else: {:noreply, assign(socket, :message, second_factor_message(:expired))}

          _nobody ->
            {:noreply, assign(socket, :message, second_factor_message(:expired))}
        end
      else
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

  # A SIGN-IN PAGE'S ADDRESS, with the verified `return_to` carried on to it.
  defp auth_helper("returning") do
    helper("returning", "assigns, path", ~S'''
    case return_params(assigns) do
      query when map_size(query) == 0 -> path
      query -> "#{path}?#{URI.encode_query(query)}"
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
          :password -> t("Password sign-in is off")
          _magic_link -> t("Sign-in links are closed")
        end,
      text:
        if(action == :password,
          do: t("This site does not take passwords for now. Sign in another way."),
          else: t("This site has switched it off for now.")
        )
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

      :expired ->
        %{
          id: "auth-second-factor-expired",
          title: t("This sign-in has expired"),
          text: t("Go back to sign in and start again.")
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
      "This sign-in has expired" => "این ورود منقضی شده است",
      "Password sign-in is off" => "ورود با رمز عبور خاموش است",
      "This site does not take passwords for now. Sign in another way." =>
        "این سایت فعلاً رمز عبور نمی‌پذیرد. از راه دیگری وارد شوید.",
      "Go back to sign in and start again." => "به صفحه ورود برگردید و دوباره شروع کنید.",
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
