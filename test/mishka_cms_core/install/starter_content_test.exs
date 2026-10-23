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

  # THE PAGE IS DRAWN IN WHAT THE CALLER SAYS: the home draws its own sections edge to edge, and the
  # dev seeds' pages are written for a centred column.
  test "the layout's main takes the classes a caller hands it, and leaves the page the width else",
       %{site: site} do
    StarterContent.seed!(site, main_class: "mx-auto max-w-[900px]")

    assert one(Layout, site).template =~ ~s(<main class="mx-auto max-w-[900px]">)
  end

  test "the layout's main leaves a page the whole width by default", %{site: site} do
    StarterContent.seed!(site)

    assert one(Layout, site).template =~ ~s(<main class="flex w-full flex-1 flex-col">)
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

  # THE DEV SEEDS GIVE EVERY SITE ONE. The welcome page below is what a stranger's first install
  # opens on; a site with a home of its own must not be given the installer's as well.
  test "pages a caller hands it are written in place of the installer's home", %{site: site} do
    StarterContent.seed!(site,
      pages: [
        %{
          name: "Home",
          title: "Home",
          path: "/:lang",
          description: "Ours.",
          template: ~S|<p id="ours">Ours</p>|
        },
        %{
          name: "About",
          title: "About",
          path: "/:lang/about",
          description: "Us.",
          template: ~S|<p id="about">Us</p>|
        }
      ]
    )

    pages = rows(Page, site)

    assert Enum.map(pages, & &1.path) |> Enum.sort() == ["/:lang", "/:lang/about"]
    assert Enum.find(pages, &(&1.path == "/:lang")).template == ~S|<p id="ours">Ours</p>|
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

      for name <- @paired,
          prefix <- ~w(bg text border),
          utility = "#{prefix}-#{name}",
          utility in list do
        assert "dark:#{utility}-dark" in list, "#{utility} has no dark twin in: #{classes}"
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

  defp page(site, path), do: site |> then(&rows(Page, &1)) |> Enum.find(&(&1.path == path))

  defp component(site, name),
    do: site |> then(&rows(Component, &1)) |> Enum.find(&(&1.name == name))
end
