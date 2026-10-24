# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.StarterContentTest do
  @moduledoc """
  The content a first install answers with, asked of the module itself.

  `MishkaCmsCore.Install.BootstrapTest` in the host application asserts that the installer runs this
  and what a fresh site ends up holding; what is here is the module's own contract — the report it
  answers, the options a caller steers it with, and the rule that it never writes over anything.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory
  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler

  alias MishkaCmsCore.Runtime.{
    Component,
    ErrorPage,
    Layout,
    Media,
    Page,
    PageProvision,
    Stylesheet,
    Translations
  }

  alias MishkaCmsCore.Settings

  require Ash.Query

  # THE SITE IS THE MASTER, because the logo lives in the master's media library and a first install
  # has no other kind. The files go to a folder of this test's own, never to `priv/static`.
  setup do
    dir = Path.join(System.tmp_dir!(), "starter_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    name = "starter#{System.unique_integer([:positive])}"
    %{site: create_site!(name: name, host: "#{name}.test", active: true, master: true)}
  end

  test "writes the whole starter site and says what it wrote", %{site: site} do
    report = StarterContent.seed!(site)

    assert report.stylesheets == ["site-theme"]
    assert report.media == ["mishka-logo"]
    assert Enum.sort(report.components) == ["site-footer", "site-header"]
    assert report.layouts == ["site-main"]
    assert report.pages == ["/:lang"]
    assert [_error_page] = report.error_pages
    assert report.renamed_pages == []
    assert report.skipped_pages == []

    # THE LAYOUT IS IN THE REPORT WHETHER OR NOT THIS CALL WROTE IT, because a caller adding pages of
    # its own — `MishkaCmsCore.Dev.Seeds` does — has to hang them on the same row on every run.
    assert report.layout_id == one(Layout, site).id
  end

  # A FIRST INSTALL ANSWERS ONE PAGE. About, Contact and Privacy were the installer's and are the dev
  # seeds' now (`MishkaCmsCore.Dev.StarterPages`), so a site nobody seeded further holds only `/`.
  test "writes no about, contact or privacy page", %{site: site} do
    StarterContent.seed!(site)

    assert [%{name: "home", path: "/:lang"}] = rows(Page, site)
  end

  # THE FRAME IS THE LAYOUT'S: a page the site adds later has the header and the footer without
  # asking, and the page at `/` is what is between them.
  test "the layout draws the header and the footer, and the home page draws neither", %{
    site: site
  } do
    StarterContent.seed!(site)

    layout = one(Layout, site).template
    assert layout =~ ~s(component_name="site-header")
    assert layout =~ ~s(component_name="site-footer")
    assert layout =~ "{@inner_content}"

    home = page(site, "/:lang").template
    refute home =~ "site-header"
    refute home =~ "site-footer"
    refute home =~ "<header"
    refute home =~ "<footer"
  end

  # THE DESIGN'S OWN WORDS, dashes included: the page is the designer's copy, not ours to reword.
  test "the home page says what the design says", %{site: site} do
    StarterContent.seed!(site)

    template = page(site, "/:lang").template

    for text <- [
          "Mishka is <em",
          "up and running",
          "Nothing is published yet — sign in to the admin console and start shaping your first site.",
          "HOW A PAGE IS SERVED",
          "Every request, composed from parts you own.",
          "Domain resolves to one of your sites — run many from one install.",
          "START HERE",
          "Three steps to replace this page.",
          "Plugins add features like blogs or documentation — install them only when you need them.",
          "Sign in to the admin console",
          "Pick a layout for your site",
          "Every page shares it — change it any time.",
          "Publish a page at “/”"
        ],
        do: assert(template =~ text, text)
  end

  # THE LOGO IS A FILE IN THE MEDIA MANAGER, put there the way an upload is, and the three places that
  # draw it name the row's own address rather than a path somebody typed.
  test "the logo is a file of the master site's media library, and every template draws it", %{
    site: site
  } do
    StarterContent.seed!(site)

    assert [logo] = rows(Media, site)
    assert logo.name == "mishka-logo"
    assert logo.type == :images
    assert logo.format == "png"
    assert logo.size > 0
    assert logo.site_id == site.id
    assert String.starts_with?(logo.relative_path, "/uploads/#{site.id}/media/")

    assert {:ok, %{active: file}} = Media.storage_paths(logo.relative_path, site.id)
    assert File.exists?(file)

    assert File.read!(file) ==
             File.read!(
               Path.join([:code.priv_dir(:mishka_cms_core), "install", "mishka-logo.png"])
             )

    for name <- ["site-header", "site-footer"] do
      attr = Enum.find(component(site, name).attrs, &(&1.name == "logo"))
      assert attr.opts["default"] == logo.relative_path, name
    end

    assert page(site, "/:lang").template =~ ~s(src="#{logo.relative_path}")
  end

  # THE MASTER'S PICTURE, whichever site draws it: a dev site is not the master, and a second logo in
  # its own library would be a file nobody asked for.
  test "a site that is not the master draws the master's logo and stores none of its own", %{
    site: master
  } do
    StarterContent.seed!(master)
    [logo] = rows(Media, master)

    name = "other#{System.unique_integer([:positive])}"
    other = create_site!(name: name, host: "#{name}.test", active: true)

    report = StarterContent.seed!(other)

    assert report.media == []
    assert rows(Media, other) == []
    assert [^logo] = rows(Media, master)

    attr = Enum.find(component(other, "site-header").attrs, &(&1.name == "logo"))
    assert attr.opts["default"] == logo.relative_path
    assert page(other, "/:lang").template =~ ~s(src="#{logo.relative_path}")
  end

  test "raises for a site that is not the master when there is no master", %{site: site} do
    Ecto.Adapters.SQL.query!(
      MishkaCmsCore.Repo,
      "UPDATE sites SET master = false WHERE id = $1",
      [
        Ecto.UUID.dump!(site.id)
      ]
    )

    assert_raise ArgumentError, ~r/no master site/, fn -> StarterContent.seed!(site.id) end
    assert rows(Media, site) == []
  end

  # A site switched offline shows this page; its admin rewords it like the 404 and the 500, and
  # the gate draws its built-in page only when it is gone.
  test "the site's Error Page holds its offline page beside the 404 and the 500", %{site: site} do
    StarterContent.seed!(site)

    entries = one(ErrorPage, site).error_pages

    assert Enum.map(entries, & &1.status) == [404, 500, :offline]
    assert Enum.find(entries, &(&1.status == :offline)).template =~ "Down for maintenance"
  end

  # For the dev seeds: an Error Page seeded before the entry existed gets it, after its own.
  test "ensure_offline_entry adds the offline page to an Error Page without one, once", %{
    site: site
  } do
    assert StarterContent.ensure_offline_entry(site) == :no_error_page

    StarterContent.seed!(site)
    page = one(ErrorPage, site)
    kept = Enum.reject(page.error_pages, &(&1.status == :offline))

    page
    |> Ash.Changeset.for_update(:update, %{error_pages: kept}, tenant: site.id, authorize?: false)
    |> Ash.update!()

    assert StarterContent.ensure_offline_entry(site.id) == :added
    assert Enum.map(one(ErrorPage, site).error_pages, & &1.status) == [404, 500, :offline]

    assert StarterContent.ensure_offline_entry(site) == :held
    assert Enum.map(one(ErrorPage, site).error_pages, & &1.status) == [404, 500, :offline]
  end

  test "the home page hangs on the site's own layout", %{site: site} do
    report = StarterContent.seed!(site)

    for page <- rows(Page, site), do: assert(page.layout_id == report.layout_id)
  end

  test "the layout titles every page the same way, after the page and then the site", %{
    site: site
  } do
    StarterContent.seed!(site)

    assert [%{tag: "title", content: "{{page.title}} · {{site.name}}"}] =
             one(Layout, site).seo_tags
             |> MishkaCmsCore.Runtime.Seo.stored_tags()
             |> Enum.filter(&(&1.tag == "title"))
  end

  # `/fa` answers with the starter's home page on a site publishing in Persian, rather than a 404
  # until somebody writes a Persian edition.
  test "the home page answers every language the site publishes in", %{site: site} do
    StarterContent.seed!(site)

    assert [home] = rows(Page, site)
    assert PageProvision.serves_all_languages?(home)
  end

  # RUN AGAIN, IT WRITES NOTHING. The dev seeds run this on every reseed and the installer may be
  # pressed twice; a row found by its name is left exactly as it is, edits and all.
  test "a second run adds nothing and keeps an edited row", %{site: site} do
    StarterContent.seed!(site)

    header = component(site, "site-header")

    header
    |> Ash.Changeset.for_update(:update, %{description: "Rewritten by the admin"},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.update!()

    report = StarterContent.seed!(site)

    assert report.pages == []
    assert report.media == []
    assert report.components == []
    assert report.layouts == []
    assert report.stylesheets == []
    assert report.error_pages == []

    assert length(rows(Page, site)) == 1
    assert length(rows(Media, site)) == 1
    assert length(rows(Component, site)) == 2

    assert component(site, "site-header").description == "Rewritten by the admin"
  end

  # A HELD ADDRESS IS NOT AN ERROR. A site already answering at `/:lang` keeps whatever it answers
  # with, and the rest of the starter content is still written — left to `Ash.create!` that was a
  # raise in the middle of the run and a half-provisioned site for good.
  test "a page the site already has at the home address is left alone", %{site: site} do
    create_page!(site_id: site.id, name: "Ours", path: "/:lang")

    report = StarterContent.seed!(site)

    assert report.pages == []
    assert [%{path: "/:lang"}] = report.skipped_pages
    assert Enum.sort(report.components) == ["site-footer", "site-header"]
    assert [%{name: "ours"}] = rows(Page, site)
  end

  # THE NAV IS A THING A CALLER CHANGES, because the pages it points at are the caller's own.
  test "extra nav links are written into the layout, in the page's language", %{site: site} do
    StarterContent.seed!(site, nav: [{"Pricing", "/pricing"}])

    template = one(Layout, site).template

    assert template =~ ~s|navigate={site_path("/:lang/pricing", lang(assigns))}|
    assert template =~ ">Pricing<"
  end

  @column ~s(<main id="site-main" class="mx-auto w-full max-w-[1160px] flex-1 px-8 pb-24">{@inner_content}</main>)

  # ONE WIDTH FOR EVERY PAGE, the home design's, and the layout's to draw: a page draws its sections
  # into it, so no page draws a column of its own and none is drawn twice.
  describe "the content column" do
    test "is the layout's: 1160 px, 32 px gutters and the room under the last section", %{
      site: site
    } do
      StarterContent.seed!(site)

      assert one(Layout, site).template =~ @column
    end

    # WHOEVER CALLS, whatever links they bring, the layout's `<main>` is the same, so a page drawn in
    # the design's column is drawn in one in dev and in one in production.
    test "is the same for every caller, the dev seeds' included", %{site: site} do
      StarterContent.seed!(site, nav: [{"Pricing", "/pricing"}])

      template = one(Layout, site).template

      assert template =~ @column
      assert [_one] = Regex.scan(~r/<main\b/, template)
    end

    test "is the only container: the home page draws its sections straight into it", %{
      site: site
    } do
      StarterContent.seed!(site)

      home = page(site, "/:lang").template

      refute home =~ "max-w-[1160px]"
      refute home =~ ~r/<section[^>]*\bpx-8\b/

      # THE DOTTED WELCOME IS A BAND FROM ONE EDGE OF THE WINDOW TO THE OTHER, its content still in
      # the column, through the theme's utility rather than a container of its own.
      assert [hero | _] = Regex.scan(~r/<section class="[^"]*"/, home)
      assert hd(hero) =~ "site-bleed"
    end

    # A `site-bleed` SECTION REACHES PAST THE COLUMN BY HALF A SCROLLBAR where the window has one.
    test "the frame clips what a band runs past the window, so no page scrolls sideways", %{
      site: site
    } do
      StarterContent.seed!(site)

      assert one(Layout, site).template =~
               ~r/\A<div class="flex min-h-screen flex-col overflow-x-clip /
    end
  end

  describe "the section bar" do
    test "is drawn by the layout under the header and above the messages, from the page", %{
      site: site
    } do
      StarterContent.seed!(site)

      template = one(Layout, site).template

      call =
        ~s(<MishkaCmsCore.Runtime.SiteLayout.section_bar bar={assigns[:page_section_bar]} site="#{site.name}" />)

      assert template =~ call

      [before_bar, after_bar] = String.split(template, call)
      assert before_bar =~ ~s(component_name="site-header")
      assert after_bar =~ ~s(id="site-flash")
      assert after_bar =~ @column
    end
  end

  # ONE LINK, BOTH MODES: every link to a page of the site is written as the stored path and the
  # page's language, so it follows the site's `site.language_urls`. The links that leave the site
  # are the same in every mode and in every language.
  describe "the links of the starter" do
    setup %{site: site} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok = Translations.put_site(site.id)
      StarterContent.seed!(site)
      :ok
    end

    @docs "https://mishka.tools/docs"
    @github "https://github.com/mishka-group/mishka_cms"

    defp hrefs(template, assigns) do
      template
      |> LiveViewCompiler.render_template(assigns)
      |> then(&Regex.scan(~r/href="([^"]*)"/, &1, capture: :all_but_first))
      |> List.flatten()
    end

    defp home_links(site, language) do
      hrefs(page(site, "/:lang").template, %{
        page: %{language: language},
        current_site: %{host: "acme.test"}
      })
    end

    defp header_html(site, assigns) do
      LiveViewCompiler.render_template(
        component(site, "site-header").template,
        Map.merge(
          %{
            brand: "Acme",
            logo: "/logo.png",
            lang: "en",
            current_user: nil,
            editions: [],
            class: nil,
            inner_block: []
          },
          assigns
        )
      )
    end

    defp header_links(site, language) do
      site |> header_html(%{lang: language}) |> links()
    end

    defp links(html) do
      ~r/href="([^"]*)"/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()
    end

    defp footer_html(site) do
      LiveViewCompiler.render_template(component(site, "site-footer").template, %{
        logo: "/logo.png",
        class: nil,
        inner_block: []
      })
    end

    defp footer_links(site), do: site |> footer_html() |> links()

    # THE TWO BUTTONS AND NOTHING ELSE ARE LINKS, and the three numbered steps are plain cards: a
    # link on one of them would be a fifth `href` here.
    test "the home page has two links, the sign-in page and the docs", %{site: site} do
      assert home_links(site, "en") == ["/auth", "https://mishka.tools/cms/docs"]
      assert home_links(site, "fa") == ["/fa/auth", "https://mishka.tools/cms/docs"]
    end

    test "the header links home, to the docs, to GitHub and to the sign-in page", %{site: site} do
      assert header_links(site, "en") == ["/", @docs, @github, "/auth"]
      assert header_links(site, "fa") == ["/fa", @docs, @github, "/fa/auth"]
    end

    test "the footer links to Mishka CMS, the docs, GitHub and the sponsor page", %{site: site} do
      assert footer_links(site) == [
               "https://mishka.tools/cms",
               @docs,
               @github,
               "https://mishka.tools/sponsor"
             ]
    end

    test "prefix every language in prefix_all", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert hd(home_links(site, "en")) == "/en/auth"
      assert [home, _docs, _github, sign_in] = header_links(site, "en")
      assert {home, sign_in} == {"/en", "/en/auth"}
    end

    test "no link of the starter goes nowhere", %{site: site} do
      links =
        home_links(site, "en") ++ header_links(site, "en") ++ footer_links(site)

      refute "#" in links
      refute "" in links
    end

    test "every link that leaves the site opens a new tab without handing it the opener", %{
      site: site
    } do
      for template <- [
            page(site, "/:lang").template,
            component(site, "site-header").template,
            component(site, "site-footer").template
          ],
          [tag] <- Regex.scan(~r/<\.link\b[^>]*href="https?:\/\/[^>]*>/s, template) do
        assert tag =~ ~s(target="_blank"), tag
        assert tag =~ ~s(rel="noopener noreferrer"), tag
      end
    end

    test "the error page's Back home is the visitor's language's home, else the first one's", %{
      site: site
    } do
      [not_found | _] = one(ErrorPage, site).error_pages
      home = &hrefs(not_found.template, %{conn: %{assigns: %{site_language: &1}}})

      assert home.("fa") == ["/fa"]
      assert home.(nil) == ["/"]

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert home.(nil) == ["/en"]
    end

    test "the offline page's sign-in is in the visitor's language, else the first one's", %{
      site: site
    } do
      offline = Enum.find(one(ErrorPage, site).error_pages, &(&1.status == :offline))
      sign_in = &hrefs(offline.template, %{conn: %{assigns: %{site_language: &1}}})

      assert sign_in.("fa") == ["/fa/auth?master_user=false"]
      assert sign_in.(nil) == ["/auth?master_user=false"]

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert sign_in.(nil) == ["/en/auth?master_user=false"]
    end

    test "the sign-in pages link to each other in the language they answer in", %{site: site} do
      StarterContent.ensure_auth!(site)
      sign_in = Enum.find(rows(Page, site), &(&1.path == "/:lang/auth/register"))

      assert sign_in.template =~
               ~s|navigate={returning(assigns, site_path("/:lang/auth", @page.language))}|

      assert Enum.any?(sign_in.helpers, &(&1.name == "returning"))
      refute Enum.any?(sign_in.helpers, &(&1.name == "flow_path"))
    end
  end

  # A SITE AN ADMIN ADDS LATER IS DRAWN IN THE SAME FRAME as the first one: its `"provision"` job
  # writes the starter beside the sign-in pages, and a job that runs twice writes nothing twice.
  describe "a site created in the admin" do
    setup do
      name = "admin-made#{System.unique_integer([:positive])}"

      site =
        MishkaCmsCore.Runtime.Site
        |> Ash.Changeset.for_create(:create, %{name: name, host: "#{name}.test"},
          authorize?: false
        )
        |> Ash.create!()

      on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.delete(site.id) end)

      %{made: site}
    end

    defp provision!(site) do
      assert :ok =
               MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker.perform(%Oban.Job{
                 args: %{
                   "transition" => "provision",
                   "site_id" => site.id,
                   "site_name" => site.name,
                   "old_name" => site.name
                 }
               })
    end

    test "gets the theme, the header, the footer, the layout and the home page", %{
      made: made
    } do
      provision!(made)

      assert names(Stylesheet, made) == ["site-theme"]
      assert names(Component, made) == ["site-footer", "site-header"]
      assert names(Layout, made) == ["auth", "site-main"]

      home = page(made, "/:lang")
      assert home.section == "starter"
      assert home.layout_id == MishkaCmsCore.Runtime.SiteLayout.layout_id(made.id)
      assert home.template =~ "up and running"

      # BESIDE THE SIGN-IN PAGES THE JOB HAS ALWAYS WRITTEN.
      assert Enum.count(rows(Page, made), &(&1.section == "auth")) == 8
    end

    test "draws the master's logo and stores none of its own", %{site: master, made: made} do
      provision!(made)

      assert rows(Media, made) == []
      [logo] = rows(Media, master)

      attr = Enum.find(component(made, "site-header").attrs, &(&1.name == "logo"))
      assert attr.opts["default"] == logo.relative_path
    end

    test "writes nothing twice when the job runs again", %{made: made} do
      provision!(made)
      before = Enum.map([Stylesheet, Component, Layout, Page, ErrorPage], &names(&1, made))

      provision!(made)

      assert Enum.map([Stylesheet, Component, Layout, Page, ErrorPage], &names(&1, made)) ==
               before
    end

    test "gets its sign-in pages even with no master site to keep the logo in", %{
      site: master,
      made: made
    } do
      Ecto.Adapters.SQL.query!(
        MishkaCmsCore.Repo,
        "UPDATE sites SET master = false WHERE id = $1",
        [Ecto.UUID.dump!(master.id)]
      )

      assert {:error, :no_master_site} = StarterContent.seed(made.id)

      ExUnit.CaptureLog.capture_log(fn -> provision!(made) end)

      assert Enum.count(rows(Page, made), &(&1.section == "auth")) == 8
      assert names(Layout, made) == ["auth"]
    end

    test "seed/2 answers a site that is not there" do
      assert StarterContent.seed(Ash.UUID.generate()) == {:error, :site_not_found}
    end
  end

  # THE NAME THE USER TYPED, not the one the database kept: `Site :create` slugifies `:name`, so a
  # site installed as "Acme Docs" is stored as `acme-docs` — a tenant key, not a masthead.
  test "the brand a caller names is what the header prints", %{site: site} do
    StarterContent.seed!(site, brand: "Acme Docs")

    header = component(site, "site-header")

    assert Enum.find(header.attrs, &(&1.name == "brand")).opts["default"] == "Acme Docs"
    assert header.template =~ "{@brand}"

    for component <- rows(Component, site), template <- [component.template] do
      refute template =~ site.name
    end
  end

  # THE DEV SEEDS' WAY, and the reason a dev site's `/` is production's: the pages come AFTER the
  # installer's home, so nothing a caller brings can stand in its place.
  test "extra pages a caller hands it are written after the installer's home, not instead", %{
    site: site
  } do
    plain = create_site!(name: "plain#{System.unique_integer([:positive])}", active: true)
    StarterContent.seed!(plain)

    report =
      StarterContent.seed!(site,
        extra_pages: [
          %{
            name: "About",
            title: "About",
            path: "/:lang/about",
            description: "Us.",
            template: ~S|<p id="about">Us</p>|
          }
        ]
      )

    assert report.pages == ["/:lang", "/:lang/about"]

    pages = rows(Page, site)
    assert Enum.find(pages, &(&1.path == "/:lang")).template == page(plain, "/:lang").template
    assert Enum.find(pages, &(&1.path == "/:lang/about")).template == ~S|<p id="about">Us</p>|

    for page <- pages do
      assert page.section == "starter"
      assert PageProvision.provisioned_by(page) == "mishka_cms_core"
      assert PageProvision.serves_all_languages?(page)
    end
  end

  test "the error page takes the root layout a caller hands it", %{site: site} do
    StarterContent.seed!(site, root_layout_template: "<html><body>mine</body></html>")

    assert one(ErrorPage, site).root_layout_template == "<html><body>mine</body></html>"
  end

  @paired ~w(page fg dim subtle faint surface edge sunk chip dot wash)

  # THE ERROR PAGES AND THE DEV SEEDS ARE WRITTEN IN THE FIRST BLOCK, the home page in the second.
  test "theme_css/0 is the stylesheet a new site's theme holds", %{site: site} do
    StarterContent.seed!(site)

    assert one(Stylesheet, site).content == StarterContent.theme_css()
  end

  test "the theme declares the tokens the starter markup is written in", %{site: site} do
    StarterContent.seed!(site)

    sheet = one(Stylesheet, site)

    assert sheet.kind == :theme

    for token <-
          ~w(--color-ground --color-ink --color-line --color-accent --font-sans --font-display),
        do: assert(sheet.content =~ token <> ":", token)

    for token <-
          ~w(--color-brand --color-brand-deep --font-geist --font-geist-mono --font-newsreader),
        do: assert(sheet.content =~ token <> ":", token)
  end

  test "the theme gives every colour of the home page a light and a dark value", %{site: site} do
    StarterContent.seed!(site)

    sheet = one(Stylesheet, site)

    for name <- @paired,
        token <- ["--color-#{name}", "--color-#{name}-dark"],
        do: assert(sheet.content =~ token <> ":", token)
  end

  # WHAT THE BLOG'S AND THE DOCS' KITS WROTE AS HEX VALUES OF THEIR OWN, in the site's tokens: each
  # with its value in the light and its twin in the dark.
  @shared %{
    "tint-1" => {"#e7f1ee", "#1d2b28"},
    "tint-1-ink" => {"#2f6b5e", "#8fd1bf"},
    "tint-2" => {"#eceafb", "#24223a"},
    "tint-2-ink" => {"#5b4fe0", "#a9a2f7"},
    "tint-3" => {"#faefdc", "#2e2618"},
    "tint-3-ink" => {"#9a6412", "#e6b86a"},
    "tint-4" => {"#f6e7eb", "#2e1f24"},
    "tint-4-ink" => {"#a13d5a", "#e89ab0"},
    "tint-5" => {"#e7edf7", "#1d2433"},
    "tint-5-ink" => {"#3b5e99", "#93b2e8"},
    "tint-6" => {"#efede6", "#26251f"},
    "tint-6-ink" => {"#6b6650", "#c9c3a6"},
    "chip-wash" => {"#eceafb", "#25223f"},
    "body" => {"#3a3940", "#c9c7d2"},
    "warn-ink" => {"#a26a10", "#e6b86a"},
    "warn-wash" => {"#fbf0dc", "#2e2618"}
  }

  test "the theme holds the colours the extensions' pages share, each with its dark twin", %{
    site: site
  } do
    StarterContent.seed!(site)

    sheet = one(Stylesheet, site).content

    for {name, {light, dark}} <- @shared do
      assert sheet =~ "--color-#{name}: #{light};", name
      assert sheet =~ "--color-#{name}-dark: #{dark};", "#{name}-dark"
    end

    # THE BRAND, ON A DARK PAGE; AND THE EDGE A HOVERED CARD TAKES, THE SAME IN BOTH.
    assert sheet =~ "--color-brand: #5b4fe0;"
    assert sheet =~ "--color-brand-dark: #a9a2f7;"
    assert sheet =~ "--color-edge-hover: #b9b2f3;"
    refute sheet =~ "--color-edge-hover-dark"
  end

  test "the theme holds the utility a band runs edge to edge with", %{site: site} do
    StarterContent.seed!(site)

    assert one(Stylesheet, site).content =~
             ~r/@utility site-bleed \{\s*margin-inline: calc\(50% - 50vw\);\s*padding-inline: calc\(50vw - 50%\);\s*\}/
  end

  describe "the header's languages, as the layout hands them" do
    setup %{site: site} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      :ok = Translations.put_site(site.id)
      StarterContent.seed!(site)
      :ok
    end

    # WHAT `MishkaCmsCore.Runtime.SiteLayout` HANDS IT FOR A RECORD: each translation at its own
    # address, with the record's own title in that language.
    test "names each language as the entry does, and titles it with the record's own name", %{
      site: site
    } do
      editions = [
        %{language: "en", path: "/blog/category/news", name: "English", title: "News"},
        %{language: "ar", path: "/ar/blog/category/akhbar", name: "العربية", title: "الأخبار"},
        %{language: "fa", path: "/fa/blog/category/akhbar", name: "فارسی", title: "اخبار"}
      ]

      html = header_html(site, %{editions: editions, lang: "en"})

      assert [ar] = Regex.run(~r/<a [^>]*hreflang="ar"[^>]*>.*?<\/a>/s, html)
      assert ar =~ ~s(href="/ar/blog/category/akhbar")
      assert ar =~ ~s(title="الأخبار")
      assert ar =~ "العربية"
    end

    test "is drawn for no fewer than two", %{site: site} do
      html = header_html(site, %{editions: [%{language: "en", path: "/"}], lang: "en"})

      refute html =~ "site-language"
      refute html =~ "hreflang"
    end

    # AN ENTRY THAT NAMES NO LANGUAGE: a layout that hands the header only a code and an address.
    test "names a language the entry leaves unnamed", %{site: site} do
      html =
        header_html(site, %{
          editions: [%{language: "en", path: "/"}, %{language: "fa", path: "/fa"}],
          lang: "en"
        })

      assert html =~ MishkaCmsCore.Runtime.Languages.name("fa")
    end
  end

  # A COLOUR WRITTEN FOR THE LIGHT PAGE ALONE is a header that stays white on the dark one. Every
  # `bg-`, `text-` and `border-` utility of a themed colour has to travel with its `dark:` twin in
  # the same list of classes, which is how the design's `var(--ink)` changes with the theme.
  test "every themed colour in the starter's markup is paired with its dark twin", %{site: site} do
    StarterContent.seed!(site)

    templates = [
      page(site, "/:lang").template,
      component(site, "site-header").template,
      component(site, "site-footer").template,
      one(Layout, site).template
    ]

    for template <- templates, [_whole, classes] <- Regex.scan(~r/"([^"]*)"/, template) do
      list = String.split(classes)

      # UNDER A VARIANT TOO — `hover:`, `max-lg:`, `max-lg:[&>a]:hover:` — the twin is under the
      # same ones, after `dark:`: the phone menu's colours are written for the phone alone.
      themed = ~r/\A((?:.*:)?)((?:bg|text|border)-(?:#{Enum.join(@paired, "|")}))\z/

      for token <- list,
          [_whole, variants, utility] <- Regex.scan(themed, token),
          not String.starts_with?(variants, "dark:") do
        assert "dark:#{variants}#{utility}-dark" in list,
               "#{token} has no dark twin in: #{classes}"
      end

      # THE DOT GRID NAMES ITS COLOUR IN A GRADIENT, not in a utility of its own.
      if classes =~ "var(--color-dot)",
        do:
          assert(classes =~ "var(--color-dot-dark)", "the dots have no dark twin in: #{classes}")
    end
  end

  # THE TOGGLE IS THE HOST'S OWN MECHANISM, not a script of ours: the root layout listens for
  # `phx:set-theme` and sets `data-theme` on the document, and the site's `dark:` variant answers it.
  # Two buttons, because the design shows the moon in the light and the sun in the dark.
  test "the header's toggle sets the theme through the host's event, one button for each", %{
    site: site
  } do
    StarterContent.seed!(site)

    template = component(site, "site-header").template

    assert length(Regex.scan(~r/JS\.dispatch\("phx:set-theme"\)/, template)) == 2
    assert template =~ ~s(data-phx-theme="dark")
    assert template =~ ~s(data-phx-theme="light")
    assert template =~ "dark:hidden"
    assert template =~ "dark:grid"
  end

  # WHAT THE HEADER SHOWS A SIGNED-IN VISITOR is the admin topbar's menu in the public design: the
  # email, the console when they may open it, and Sign out. The sign-out route answers a DELETE, so
  # the entry is the form the sign-out page itself posts.
  describe "the header's visitor" do
    setup %{site: site} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      :ok = Translations.put_site(site.id)
      StarterContent.seed!(site)
      :ok
    end

    defp signed_in(site, user), do: header_html(site, %{current_user: user})

    test "a visitor who is not signed in is offered Sign in, and no menu", %{site: site} do
      html = header_html(site, %{})

      assert html =~ ~r/<a href="\/auth"[^>]*>\s*Sign in\s*<\/a>/
      refute html =~ "site-user-menu"
      refute html =~ "site-sign-out"
    end

    test "a signed-in visitor sees their email, and Sign in is gone", %{site: site} do
      user = create_user!()
      html = signed_in(site, user)

      assert html =~ "site-user-button"
      assert html =~ ~s(id="site-user-email")
      assert html =~ to_string(user.email)
      refute html =~ ~r/>\s*Sign in\s*</
      refute "/auth" in links(html)
    end

    test "Sign out is a DELETE of the sign-out route, with the token a form carries", %{
      site: site
    } do
      html = signed_in(site, create_user!())

      assert [form] = Regex.run(~r/<form[^>]*id="site-sign-out-form"[^>]*>.*?<\/form>/s, html)
      assert form =~ ~s(action="/auth/sign-out")
      assert form =~ ~s(method="post")
      assert form =~ ~r/name="_method"[^>]*value="delete"/
      assert form =~ ~s(name="_csrf_token")
      assert form =~ ~s(id="site-sign-out")
      assert form =~ "Sign out"
    end

    test "the menu is the host's own toggle: closed, opened by its button, closed away from it",
         %{
           site: site
         } do
      html = signed_in(site, create_user!())

      assert html =~ ~r/id="site-user-menu"[^>]*class="[^"]*\bhidden\b/
      assert html =~ ~s(aria-expanded="false")
      assert html =~ "toggle"
      assert html =~ "phx-click-away"
    end

    test "an admin is offered the console and their account settings", %{site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:*"])
      html = signed_in(site, admin)

      assert html =~ ~s(id="site-admin-console")
      assert "/admin/dashboard" in links(html)
      assert html =~ ~s(id="site-account-settings")
      assert "/admin/dashboard/settings?tab=preferences" in links(html)
    end

    test "a visitor who may not open the console is offered neither", %{site: site} do
      html = signed_in(site, create_user!())

      refute html =~ "site-admin-console"
      refute html =~ "site-account-settings"
      refute Enum.any?(links(html), &String.starts_with?(&1, "/admin"))
    end

    # A PAGE IS SERVED WITHOUT A VISITOR UNLESS ITS SOURCE NAMES ONE, which is how a brochure page
    # costs no lookup. The layout names `current_user` where it hands it to the header, so every
    # page on it loads whoever is signed in, and the header can say who.
    test "the layout asks the runtime for the visitor", %{site: site} do
      assert MishkaCmsCore.Runtime.Compilers.UserClosure.reads_user?(one(Layout, site))
    end

    test "the layout hands the header the visitor and the page's languages", %{site: site} do
      template = one(Layout, site).template

      assert template =~
               ~r/component_name="site-header".*?current_user=\{assigns\[:current_user\]\}/s

      assert template =~ ~r/component_name="site-header".*?editions=\{assigns\[:page_languages\]/s
    end
  end

  # THE SWITCHER REPLACED THE FOOTER'S PILLS. It lists the languages the page answers in, as the
  # page's own `@page_languages` says (a page that is in one language has none), each at the address
  # `Languages.url/3` gave it, with its flag and its name, and marks the one the visitor is reading.
  describe "the header's language switcher" do
    setup %{site: site} do
      StarterContent.seed!(site)

      %{
        both: [
          %{language: "en", path: "/"},
          %{language: "fa", path: "/fa"}
        ]
      }
    end

    test "lists each language with its flag and its name, at its address", %{
      site: site,
      both: both
    } do
      html = header_html(site, %{editions: both, lang: "en"})

      assert html =~ "site-language-menu"
      assert html =~ ~s(href="/fa")
      assert html =~ ~s(hreflang="fa")
      assert html =~ ~s(hreflang="en")
      assert html =~ MishkaCmsCore.Runtime.Languages.flag("fa")
      assert html =~ MishkaCmsCore.Runtime.Languages.flag("en")
      assert html =~ MishkaCmsCore.Runtime.Languages.name("fa")
      assert html =~ MishkaCmsCore.Runtime.Languages.name("en")
    end

    test "marks the language the visitor is reading, and only that one", %{site: site, both: both} do
      html = header_html(site, %{editions: both, lang: "fa"})

      assert [current] = Regex.scan(~r/<a [^>]*aria-current="true"[^>]*>/, html)
      assert hd(current) =~ ~s(hreflang="fa")
      assert length(Regex.scan(~r/aria-current/, html)) == 1
    end

    test "shows the current language on its button, and opens the menu from it", %{
      site: site,
      both: both
    } do
      html = header_html(site, %{editions: both, lang: "fa"})

      assert [button] =
               Regex.run(~r/<button[^>]*id="site-language-button"[^>]*>.*?<\/button>/s, html)

      assert button =~ MishkaCmsCore.Runtime.Languages.flag("fa")
      assert button =~ ">fa<"
      assert html =~ ~r/id="site-language-menu"[^>]*class="[^"]*\bhidden\b/
    end

    test "is not drawn for a page that answers in one language", %{site: site} do
      html = header_html(site, %{editions: [], lang: "en"})

      refute html =~ "site-language"
      refute html =~ "hreflang"
    end

    test "is not in the footer, which has no language links any more", %{site: site} do
      html = footer_html(site)

      refute html =~ "hreflang"
      refute html =~ "uppercase"
      assert footer_links(site) |> length() == 4

      refute Enum.any?(component(site, "site-footer").attrs, &(&1.name in ["editions", "lang"]))
    end

    test "the layout hands the footer no languages", %{site: site} do
      assert one(Layout, site).template =~ ~s(<.component component_name="site-footer" site=)
      refute one(Layout, site).template =~ ~r/site-footer.*?page_languages/s
    end
  end

  # THE BAR DID NOT FIT A PHONE. At 375 px the links ran under the logo, and Sign in sat from 372 to
  # 451, off the screen, with no control to reach it by. Below `lg` the same elements, not copies of
  # them, sit in a panel a button opens; from `lg` up the header is the bar it was. `lg`, not `md`,
  # because a site that adds six links of its own and has two languages is wider than 768 px.
  describe "the header's phone menu" do
    setup %{site: site} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      :ok = Translations.put_site(site.id)
      StarterContent.seed!(site)

      %{both: [%{language: "en", path: "/"}, %{language: "fa", path: "/fa"}]}
    end

    defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp attribute(html, selector, name),
      do: html |> query(selector) |> LazyHTML.attribute(name)

    defp class_list(html, selector),
      do: html |> attribute(selector, "class") |> hd() |> String.split()

    # THE COMMANDS A `phx-*` ATTRIBUTE HOLDS, as the client reads them.
    defp commands(html, selector, name),
      do: html |> attribute(selector, name) |> hd() |> Jason.decode!()

    # A LAYOUT'S LINKS, handed in the slot the way the layout hands them.
    defp nav_slot(links) do
      [
        %{
          __slot__: :inner_block,
          inner_block: fn _changed, _argument ->
            assigns = %{links: links}

            ~H"""
            <a :for={{label, path} <- @links} href={path} class="text-dim dark:text-dim-dark">{label}</a>
            """
          end
        }
      ]
    end

    test "is a button that names itself, controls the panel and starts closed", %{
      site: site,
      both: both
    } do
      html = header_html(site, %{editions: both})

      assert attribute(html, "button#site-menu-button", "type") == ["button"]
      assert attribute(html, "#site-menu-button", "aria-label") == ["Menu"]
      assert attribute(html, "#site-menu-button", "aria-controls") == ["site-menu"]
      assert attribute(html, "#site-menu-button", "aria-expanded") == ["false"]

      # NOT DRAWN FROM `lg` UP, where the bar has room: there is nothing for it to open.
      assert "lg:hidden" in class_list(html, "#site-menu-button")
    end

    test "opens and closes the panel with the host's own commands, and says which it did", %{
      site: site
    } do
      html = header_html(site, %{})

      assert commands(html, "#site-menu-button", "phx-click") == [
               ["toggle_class", %{"names" => ["max-lg:hidden"], "to" => "#site-menu"}],
               ["toggle_attr", %{"attr" => ["aria-expanded", "true", "false"]}]
             ]
    end

    # A CLICK ANYWHERE ELSE ON THE PAGE, OR ESCAPE: the same two ways the header's dropdowns close.
    # The listener is the header's, which holds the button, so the button's own click is not "away"
    # from it — on the panel alone, the click that closes the panel would open it again.
    test "closes on a click away from the header and on Escape, and Escape returns the focus", %{
      site: site
    } do
      html = header_html(site, %{})
      close = ["add_class", %{"names" => ["max-lg:hidden"], "to" => "#site-menu"}]

      collapsed = [
        "set_attr",
        %{"to" => "#site-menu-button", "attr" => ["aria-expanded", "false"]}
      ]

      assert commands(html, "header", "phx-click-away") == [close, collapsed]

      # THE FOCUS ONLY WHEN THE MENU IS OPEN: Escape pressed somewhere else on the page must not
      # take the focus to a button that is not showing anything.
      assert commands(html, "header", "phx-window-keydown") == [
               ["focus", %{"to" => "#site-menu-button[aria-expanded=true]"}],
               close,
               collapsed
             ]

      assert attribute(html, "header", "phx-key") == ["Escape"]
    end

    # THE CLICK-AWAY IS THE WRAPPER'S, which holds the button as well as the menu. On the menu alone,
    # the click on the button that is meant to close it is "away" from it: the menu hides, and then the
    # button's own toggle shows it again. Tapping the button of an open menu on a phone did nothing.
    test "a dropdown closes away from its button and its menu both, and says so", %{
      site: site,
      both: both
    } do
      for {html, menu, button} <- [
            {header_html(site, %{editions: both}), "#site-language-menu",
             "#site-language-button"},
            {signed_in(site, create_user!()), "#site-user-menu", "#site-user-button"}
          ] do
        close = [
          ["hide", %{"to" => menu}],
          ["set_attr", %{"to" => button, "attr" => ["aria-expanded", "false"]}]
        ]

        # THE WRAPPER IS THE ONE `div` THAT LISTENS, and the button is its child.
        assert attribute(html, "div[phx-key] > #{button}", "type") == ["button"]
        assert commands(html, "div[phx-key]", "phx-click-away") == close
        assert commands(html, "div[phx-key]", "phx-window-keydown") == close
        assert attribute(html, "div[phx-key]", "phx-key") == ["Escape"]

        assert attribute(html, menu, "phx-click-away") == []
        assert attribute(html, menu, "phx-window-keydown") == []
      end
    end

    test "holds the links, the switcher, the toggle and Sign in, and not the logo", %{
      site: site,
      both: both
    } do
      html = header_html(site, %{editions: both, inner_block: nav_slot([{"About", "/about"}])})

      assert attribute(html, "#site-menu a", "href") ==
               ["/about", @docs, @github, "/", "/fa", "/auth"]

      inside = attribute(html, "#site-menu [id]", "id")

      for id <- ~w(site-language-button site-language-menu site-theme-dark site-theme-light),
          do: assert(id in inside, id)

      assert attribute(html, "#site-menu img", "src") == []
      assert attribute(html, "header > a > img", "src") == ["/logo.png"]
    end

    test "holds the visitor's menu for a signed-in visitor", %{site: site} do
      html = signed_in(site, create_user!())
      inside = attribute(html, "#site-menu [id]", "id")

      for id <-
            ~w(site-user-button site-user-menu site-user-email site-sign-out-form site-sign-out),
          do: assert(id in inside, id)

      refute "/auth" in attribute(html, "#site-menu a", "href")
    end

    # TAB GOES FROM THE BUTTON INTO THE PANEL, and the logo comes first, the way it reads.
    test "is after the logo and before the panel, in the order Tab walks", %{site: site} do
      html = header_html(site, %{})

      assert [logo, button, panel] =
               for(
                 needle <- [~s(<img), ~s(id="site-menu-button"), ~s(id="site-menu")],
                 do: html |> :binary.match(needle) |> elem(0)
               )

      assert logo < button and button < panel
    end

    test "is shut below lg and a row from lg up, so the desktop links are still there", %{
      site: site,
      both: both
    } do
      html = header_html(site, %{editions: both})
      panel = class_list(html, "#site-menu")

      # THE PANEL'S OWN CLASSES ARE THE BAR'S, hidden only where `max-lg` says so...
      assert "max-lg:hidden" in panel
      assert "flex" in panel
      assert "items-center" in panel
      assert "gap-[22px]" in panel
      refute "hidden" in panel

      # ...and what it holds has no class of its own that hides it at `lg` or above: Docs and GitHub
      # were hidden below `sm` and are in the panel there now, the switcher and Sign in never were.
      hides = ["hidden" | for(size <- ~w(sm md lg xl 2xl), do: "#{size}:hidden")]

      for selector <- [
            "#site-menu a[href^=http]",
            "#site-language-button",
            ~s(#site-menu a[href="/auth"])
          ],
          classes <- attribute(html, selector, "class"),
          token <- String.split(classes),
          do: refute(token in hides, "#{selector}: #{token}")

      assert header_links(site, "en") == ["/", @docs, @github, "/auth"]
    end

    # ONE SET OF ELEMENTS, restyled: a second copy of the bar for the phone would put every id on the
    # page twice, and the logo in the page three times where a page carries it in the header, the hero
    # and the footer.
    test "does not double what the bar holds, so an id is on the page once", %{
      site: site,
      both: both
    } do
      html = header_html(site, %{editions: both})
      ids = for [id] <- Regex.scan(~r/ id="([^"]+)"/, html, capture: :all_but_first), do: id

      assert ids != []
      assert ids == Enum.uniq(ids)

      signed = signed_in(site, create_user!())

      signed_ids =
        for [id] <- Regex.scan(~r/ id="([^"]+)"/, signed, capture: :all_but_first), do: id

      assert signed_ids == Enum.uniq(signed_ids)
    end

    # THE LOGO NEVER GIVES WAY: the link around it shrinks (`min-w-0`) and the name inside truncates,
    # but the picture keeps its 40 px, so nothing the link is squeezed against can land on it.
    test "keeps the logo its size and the header the panel hangs from", %{site: site} do
      html = header_html(site, %{})

      assert "relative" in class_list(html, "header")
      assert "shrink-0" in class_list(html, "header > a > img")
      assert "min-w-0" in class_list(html, "header > a")
      assert "truncate" in class_list(html, "header > a > span")
    end
  end

  # A SITE WITH MANY LINKS PUTS THEM IN ONE GROUP. The dev sites carry up to eight links of their own
  # and, beside the language switcher and Sign in, that is a header that does not fit; a group is
  # one button on the bar and a labelled list in the phone's panel. It is written into the layout,
  # beside the plain links, so the `site-header` component is the one it always was.
  describe "a group of links in the header" do
    @dev [{"About", "/about"}, {"Pricing", "/pricing"}, %{label: "Blog", path: "/blog"}]

    setup %{site: site} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok = Translations.put_site(site.id)

      # A PLAIN LINK AS A TUPLE AND AS A MAP, a group's link the same two ways: whatever the
      # caller writes, the links come out alike.
      StarterContent.seed!(site,
        nav: [{"Home", "/home"}, %{label: "Dev", children: @dev}, %{label: "Last", path: "/last"}]
      )

      :ok
    end

    # WHAT THE LAYOUT WRITES BETWEEN THE HEADER'S TAGS, drawn: `lang(assigns)` is a helper of the
    # layout's own, which a template rendered on its own does not have, so it is the language the
    # test gives.
    defp layout_nav_html(site, language) do
      [slot] =
        Regex.run(
          ~r/<\.component\s+component_name="site-header".*?\n\s*>(.*?)<\/\.component>/s,
          one(Layout, site).template,
          capture: :all_but_first
        )

      slot
      |> String.replace("lang(assigns)", "@lang")
      |> LiveViewCompiler.render_template(%{lang: language})
    end

    # AND THAT IN THE HEADER, where the layout puts it: in the slot, before Docs and GitHub.
    defp header_with_nav(site, language) do
      nav = layout_nav_html(site, language)

      slot = [
        %{
          __slot__: :inner_block,
          inner_block: fn _changed, _argument -> Phoenix.HTML.raw(nav) end
        }
      ]

      header_html(site, %{
        lang: language,
        inner_block: slot,
        editions: [%{language: "en", path: "/"}, %{language: "fa", path: "/fa"}]
      })
    end

    # THE `div` THAT LISTENS FOR A DROPDOWN, found by the button it holds: the header has two now.
    defp wrapper_attribute(html, button_id, name) do
      html
      |> query("div[phx-key]")
      |> Enum.find(&(&1 |> LazyHTML.query("#" <> button_id) |> Enum.count() == 1))
      |> LazyHTML.attribute(name)
      |> hd()
    end

    # A COLOUR THAT CHANGES IN THE DARK IS WRITTEN TWICE, so a group is never drawn light on a dark
    # page. Every element the selector finds that has one of these has its twin.
    defp assert_dark_twins(html, selector) do
      light = ~w(text-fg text-dim text-faint text-subtle bg-surface border-edge hover:bg-wash)
      found = for classes <- attribute(html, selector, "class"), do: String.split(classes)

      assert found != [], selector

      for list <- found, token <- light, token in list do
        assert "dark:#{token}-dark" in list, "#{selector}: #{token} has no dark twin"
      end
    end

    test "is a button on the bar from lg up, and is not drawn below it", %{site: site} do
      html = header_with_nav(site, "en")
      wrapper = html |> wrapper_attribute("site-nav-dev-button", "class") |> String.split()

      assert "max-lg:hidden" in wrapper
      assert "relative" in wrapper

      assert attribute(html, "#site-nav-dev-button", "type") == ["button"]
      assert attribute(html, "#site-nav-dev-button", "aria-haspopup") == ["menu"]
      assert attribute(html, "#site-nav-dev-button", "aria-expanded") == ["false"]
      assert html |> query("#site-nav-dev-button > span") |> LazyHTML.text() == "Dev"
      assert html |> query("#site-nav-dev-button > svg") |> Enum.count() == 1
    end

    test "looks like the language switcher's button, and its menu like the language menu", %{
      site: site
    } do
      html = header_with_nav(site, "en")

      # THE BUTTON'S SHAPE IS THE SWITCHER'S: the same height, border, fill and radius.
      group = class_list(html, "#site-nav-dev-button")
      language = class_list(html, "#site-language-button")

      for token <- ~w(h-[38px] cursor-pointer rounded-[11px] border border-edge bg-surface) do
        assert token in group, token
        assert token in language, token
      end

      menu = class_list(html, "#site-nav-dev-menu")

      for token <-
            ~w(absolute z-50 hidden min-w-[190px] overflow-hidden rounded-[14px] border border-edge bg-surface p-1.5) do
        assert token in menu, token
        assert token in class_list(html, "#site-language-menu"), token
      end

      assert attribute(html, "#site-nav-dev-menu", "role") == ["menu"]

      for selector <- [
            "#site-nav-dev-button",
            "#site-nav-dev-button > svg",
            "#site-nav-dev-menu",
            "#site-nav-dev-menu > a"
          ],
          do: assert_dark_twins(html, selector)
    end

    test "opens, closes and keeps aria-expanded as the language switcher does, by its own ids", %{
      site: site
    } do
      html = header_with_nav(site, "en")

      # THE SAME COMMANDS, NOT A NEW MECHANISM: what the switcher holds, with the group's ids.
      as_group = fn commands ->
        commands
        |> Jason.encode!()
        |> String.replace("site-language", "site-nav-dev")
        |> Jason.decode!()
      end

      assert commands(html, "#site-nav-dev-button", "phx-click") ==
               as_group.(commands(html, "#site-language-button", "phx-click"))

      for name <- ["phx-click-away", "phx-window-keydown"] do
        group = html |> wrapper_attribute("site-nav-dev-button", name) |> Jason.decode!()
        language = html |> wrapper_attribute("site-language-button", name) |> Jason.decode!()

        assert group == as_group.(language), name

        assert group == [
                 ["hide", %{"to" => "#site-nav-dev-menu"}],
                 [
                   "set_attr",
                   %{"to" => "#site-nav-dev-button", "attr" => ["aria-expanded", "false"]}
                 ]
               ]
      end

      assert wrapper_attribute(html, "site-nav-dev-button", "phx-key") == "Escape"

      # THE WRAPPER LISTENS, AND THE MENU DOES NOT: a click on the button of an open menu is "away"
      # from the menu alone, which hid it for the button's own toggle to show it again.
      assert attribute(html, "#site-nav-dev-menu", "phx-click-away") == []
      assert attribute(html, "#site-nav-dev-menu", "phx-window-keydown") == []

      assert [["toggle", %{"to" => "#site-nav-dev-menu"}], ["toggle_attr", toggle]] =
               commands(html, "#site-nav-dev-button", "phx-click")

      assert toggle == %{"attr" => ["aria-expanded", "true", "false"]}
    end

    test "holds the group's links in its menu, in order, each a menu item", %{site: site} do
      html = header_with_nav(site, "en")

      assert attribute(html, "#site-nav-dev-menu > a", "href") == ["/about", "/pricing", "/blog"]
      assert attribute(html, "#site-nav-dev-menu > a", "role") == List.duplicate("menuitem", 3)

      assert html |> query("#site-nav-dev-menu > a") |> Enum.map(&LazyHTML.text/1) ==
               ["About", "Pricing", "Blog"]

      # A TUPLE OR A MAP: the three are drawn alike.
      assert html |> attribute("#site-nav-dev-menu > a", "class") |> Enum.uniq() |> length() == 1

      # SHUT UNTIL ITS BUTTON OPENS IT.
      assert "hidden" in class_list(html, "#site-nav-dev-menu")
    end

    test "is a labelled group with its links in the phone's panel, and not drawn from lg up", %{
      site: site
    } do
      html = header_with_nav(site, "en")
      group = "#site-menu [role=group]"

      assert attribute(html, group, "aria-labelledby") == ["site-nav-dev-label"]
      assert "lg:hidden" in class_list(html, group)
      assert html |> query("#site-nav-dev-label") |> LazyHTML.text() |> String.trim() == "Dev"

      assert attribute(html, "#{group} > a", "href") == ["/about", "/pricing", "/blog"]
      assert html |> attribute("#{group} > a", "class") |> Enum.uniq() |> length() == 1

      # NO BUTTON TO OPEN: the panel is already something the visitor opened.
      assert html |> query("#{group} button") |> Enum.count() == 0

      for selector <- ["#{group} > a", "#site-nav-dev-label"],
          do: assert_dark_twins(html, selector)
    end

    test "leaves the plain links as they were, in the panel's own list, in the order given", %{
      site: site
    } do
      html = header_with_nav(site, "en")

      assert attribute(html, "#site-menu > div:first-child > a", "href") ==
               ["/home", "/last", @docs, @github]

      for class <- attribute(html, "#site-menu > div:first-child > a[href^='/']", "class"),
          do: assert(class == "text-dim dark:text-dim-dark")

      # HOME, THE GROUP, LAST: where the caller put it.
      assert [home, group, last] =
               for(
                 needle <- [~s(href="/home"), ~s(id="site-nav-dev-button"), ~s(href="/last")],
                 do: html |> :binary.match(needle) |> elem(0)
               )

      assert home < group and group < last
    end

    test "puts every id on the page once, the group's two sets of elements included", %{
      site: site
    } do
      html = header_with_nav(site, "en")
      ids = for [id] <- Regex.scan(~r/ id="([^"]+)"/, html, capture: :all_but_first), do: id

      assert ~w(site-nav-dev-button site-nav-dev-menu site-nav-dev-label) -- ids == []
      assert ids == Enum.uniq(ids)
    end

    test "follows the site's URL mode and the page's language, as the plain links do", %{
      site: site
    } do
      assert site |> layout_nav_html("en") |> links() |> Enum.uniq() ==
               ["/home", "/about", "/pricing", "/blog", "/last"]

      assert site |> layout_nav_html("fa") |> links() |> Enum.uniq() ==
               ["/fa/home", "/fa/about", "/fa/pricing", "/fa/blog", "/fa/last"]

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert site |> layout_nav_html("en") |> links() |> Enum.uniq() ==
               ["/en/home", "/en/about", "/en/pricing", "/en/blog", "/en/last"]
    end

    test "is stored as links through site_path, not as addresses", %{site: site} do
      template = one(Layout, site).template

      for path <- ~w(about pricing blog) do
        assert template =~ ~s|navigate={site_path("/:lang/#{path}", lang(assigns))}|
      end

      refute template =~ "href="
    end

    test "is not touched by the header component, which is the one every site has", %{site: site} do
      refute component(site, "site-header").template =~ "site-nav-"
    end
  end

  describe "a group that is not worth a button" do
    test "with no link draws nothing, and the rest of the nav is as given", %{site: site} do
      StarterContent.seed!(site, nav: [{"Home", "/home"}, %{label: "Dev", children: []}])
      template = one(Layout, site).template

      refute template =~ "site-nav-"
      assert template =~ ~s|navigate={site_path("/:lang/home", lang(assigns))}|
    end

    test "labelled in a script with no letter or digit in it is named by its place", %{site: site} do
      StarterContent.seed!(site,
        nav: [
          %{label: "ابزار", children: [{"A", "/a"}]},
          %{label: "Docs & guides", children: [{"B", "/b"}]}
        ]
      )

      template = one(Layout, site).template

      assert template =~ ~s(id="site-nav-group-0-button")
      assert template =~ ~s(id="site-nav-docs-guides-menu")
    end
  end

  # THE VERSION IS THE APPLICATION'S, read when the page is drawn. A literal in the template is a
  # version nobody bumps: it said `v1.0.0` on a build that is `0.0.1`.
  describe "the version the home page shows" do
    test "is the host application's, as the header of a page reads it", %{site: site} do
      StarterContent.seed!(site)

      template = page(site, "/:lang").template

      assert template =~ "v{MishkaCmsCore.Helpers.host_version()}"
      refute template =~ ~r/\bv\d+\.\d+/

      html =
        LiveViewCompiler.render_template(template, %{
          page: %{language: "en"},
          current_site: %{host: "acme.test"}
        })

      host_app = Application.fetch_env!(:mishka_cms_core, :host_app)
      version = to_string(Application.spec(host_app, :vsn))

      assert version =~ ~r/\A\d+\.\d+\.\d+/
      assert html =~ "<span>v#{version}</span>"
    end

    test "is written nowhere else in the starter", %{site: site} do
      StarterContent.seed!(site)

      templates =
        Enum.map(rows(Page, site), & &1.template) ++
          Enum.map(rows(Component, site), & &1.template) ++ [one(Layout, site).template]

      for template <- templates, do: refute(template =~ ~r/(?<![#\w])v\d+\.\d+/)
    end
  end

  # THE DESIGN'S TYPEFACES, two of which are not the host's: the layout links them from Google, the
  # one origin besides its own that the public Content-Security-Policy names for fonts, from the
  # head, which is where a layout's `seo_tags` are drawn.
  test "the layout's head links the two typefaces the theme does not ship", %{site: site} do
    StarterContent.seed!(site)

    links =
      for %{tag: "link", attrs: attrs} <-
            MishkaCmsCore.Runtime.Seo.stored_tags(one(Layout, site).seo_tags),
          do: attrs

    assert Enum.map(links, &{&1["rel"], &1["href"]}) == [
             {"preconnect", "https://fonts.googleapis.com"},
             {"preconnect", "https://fonts.gstatic.com"},
             {"stylesheet",
              "https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&display=swap"}
           ]

    assert Enum.at(links, 1)["crossorigin"] == "anonymous"
    refute one(Layout, site).template =~ "<link"
  end

  # NOTHING A PRODUCTION INSTALL MAY NOT HAVE. The user can deselect every UI component, and the
  # host's own `<.input>` styles itself with class names no bundle here ships.
  test "no starter markup needs the kit, an inline style or a script", %{site: site} do
    StarterContent.seed!(site)

    templates =
      Enum.map(rows(Page, site), & &1.template) ++
        Enum.map(rows(Component, site), & &1.template) ++ [one(Layout, site).template]

    for template <- templates do
      refute template =~ "chelekom-"
      refute template =~ "<.input"
      refute template =~ "style="
      refute template =~ "<script"
    end
  end

  test "takes a site id as well as a record", %{site: site} do
    assert StarterContent.seed!(site.id).pages != []
  end

  test "raises for a site that is not there" do
    assert_raise ArgumentError, fn -> StarterContent.seed!(Ash.UUID.generate()) end
  end

  defp rows(resource, site) do
    resource
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  defp one(resource, site), do: resource |> rows(site) |> hd()

  defp names(resource, site), do: resource |> rows(site) |> Enum.map(& &1.name) |> Enum.sort()

  defp page(site, path), do: site |> then(&rows(Page, &1)) |> Enum.find(&(&1.path == path))

  defp component(site, name),
    do: site |> then(&rows(Component, &1)) |> Enum.find(&(&1.name == name))
end
