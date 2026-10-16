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
    Page,
    PageProvision,
    Stylesheet,
    Translations
  }

  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  require Ash.Query

  setup do
    name = "starter#{System.unique_integer([:positive])}"
    %{site: create_site!(name: name, host: "#{name}.test", active: true)}
  end

  test "writes the whole starter site and says what it wrote", %{site: site} do
    report = StarterContent.seed!(site)

    assert report.stylesheets == ["site-theme"]
    assert Enum.sort(report.components) == ["site-footer", "site-header"]
    assert report.layouts == ["site-main"]
    assert report.pages == ["/:lang", "/:lang/about", "/:lang/contact", "/:lang/privacy"]
    assert [_error_page] = report.error_pages
    assert report.renamed_pages == []
    assert report.skipped_pages == []

    # THE LAYOUT IS IN THE REPORT WHETHER OR NOT THIS CALL WROTE IT, because a caller adding pages of
    # its own — `MishkaCmsCore.Dev.Seeds` does — has to hang them on the same row on every run.
    assert report.layout_id == one(Layout, site).id
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

  test "every starter page hangs on the site's own layout", %{site: site} do
    report = StarterContent.seed!(site)

    for page <- rows(Page, site), do: assert(page.layout_id == report.layout_id)
  end

  # `/fa/about` answers with the starter's About page on a site publishing in Persian, rather than a
  # 404 until somebody writes a Persian edition.
  test "the layout titles every page the same way, after the page and then the site", %{
    site: site
  } do
    StarterContent.seed!(site)

    assert [%{tag: "title", content: "{{page.title}} · {{site.name}}"}] =
             MishkaCmsCore.Runtime.Seo.stored_tags(one(Layout, site).seo_tags)
  end

  test "every starter page answers every language the site publishes in", %{site: site} do
    StarterContent.seed!(site)

    pages = rows(Page, site)

    assert length(pages) == 4
    for page <- pages, do: assert(PageProvision.serves_all_languages?(page), page.path)
  end

  # RUN AGAIN, IT WRITES NOTHING. The dev seeds run this on every reseed and the installer may be
  # pressed twice; a row found by its name is left exactly as it is, edits and all.
  test "a second run adds nothing and keeps an edited row", %{site: site} do
    StarterContent.seed!(site)

    header = Enum.find(rows(Component, site), &(&1.name == "site-header"))

    header
    |> Ash.Changeset.for_update(:update, %{description: "Rewritten by the admin"},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.update!()

    report = StarterContent.seed!(site)

    assert report.pages == []
    assert report.components == []
    assert report.layouts == []
    assert report.stylesheets == []
    assert report.error_pages == []

    assert length(rows(Page, site)) == 4
    assert length(rows(Component, site)) == 2

    assert Enum.find(rows(Component, site), &(&1.name == "site-header")).description ==
             "Rewritten by the admin"
  end

  # A HELD ADDRESS IS NOT AN ERROR. A site already answering at `/:lang/about` keeps whatever it
  # answers with, and the rest of the starter content is still written — left to `Ash.create!` that
  # was a raise in the middle of the run and a half-provisioned site for good.
  test "a page the site already has at one of these addresses is left alone", %{site: site} do
    create_page!(site_id: site.id, name: "Ours", path: "/:lang/about")

    report = StarterContent.seed!(site)

    assert "/:lang/about" not in report.pages
    assert "/:lang" in report.pages
    assert [%{path: "/:lang/about"}] = report.skipped_pages
    assert Enum.find(rows(Page, site), &(&1.path == "/:lang/about")).name == "ours"
  end

  # THE NAV IS THE ONE THING A CALLER CHANGES, because the pages it points at are the caller's own.
  test "extra nav links are written into the layout, in the page's language", %{site: site} do
    StarterContent.seed!(site, nav: [{"Pricing", "/pricing"}])

    template = one(Layout, site).template

    assert template =~ ~s|navigate={site_path("/:lang/pricing", lang(assigns))}|
    assert template =~ ">Pricing<"
  end

  # ONE LINK, BOTH MODES: every link is written as the stored path and the page's language, so it
  # follows the site's `site.language_urls`.
  describe "the links between the starter pages" do
    setup %{site: site} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok = Translations.put_site(site.id)
      StarterContent.seed!(site)
      :ok
    end

    defp hrefs(template, assigns) do
      template
      |> LiveViewCompiler.render_template(assigns)
      |> then(&Regex.scan(~r/href="([^"]*)"/, &1, capture: :all_but_first))
      |> List.flatten()
    end

    defp page_links(site, path, language) do
      page = Enum.find(rows(Page, site), &(&1.path == path))
      hrefs(page.template, %{page: %{language: language}, query_params: %{"lang" => language}})
    end

    test "leave the primary language unprefixed by default", %{site: site} do
      assert page_links(site, "/:lang/about", "en") == ["/"]
      assert page_links(site, "/:lang/about", "fa") == ["/fa"]
      assert "/about" in page_links(site, "/:lang", "en")
      assert "/fa/contact" in page_links(site, "/:lang", "fa")
    end

    test "prefix every language in prefix_all", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert page_links(site, "/:lang/about", "en") == ["/en"]
      assert "/en/about" in page_links(site, "/:lang", "en")
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
  test "the brand a caller names is what the site prints", %{site: site} do
    StarterContent.seed!(site, brand: "Acme Docs")

    for component <- rows(Component, site) do
      assert Enum.find(component.attrs, &(&1.name == "brand")).opts["default"] == "Acme Docs"
    end

    home = Enum.find(rows(Page, site), &(&1.path == "/:lang"))

    assert home.template =~ "Acme Docs"
    refute home.template =~ site.name
  end

  # THE DEV SEEDS GIVE EVERY SITE ONE. The plain page below is what a stranger's first install opens
  # on; a site with a home of its own must not be given the installer's as well.
  test "a template a caller hands it is written in place of the starter page of that name",
       %{site: site} do
    StarterContent.seed!(site,
      templates: %{"Home" => ~S|<p id="ours">Ours</p>|, "About" => ~S|<p id="about">Us</p>|}
    )

    pages = rows(Page, site)

    assert Enum.find(pages, &(&1.path == "/:lang")).template == ~S|<p id="ours">Ours</p>|
    assert Enum.find(pages, &(&1.path == "/:lang/about")).template == ~S|<p id="about">Us</p>|
    assert Enum.find(pages, &(&1.path == "/:lang/contact")).template =~ "contact-form"
    assert length(pages) == 4
  end

  test "the error page takes the root layout a caller hands it", %{site: site} do
    StarterContent.seed!(site, root_layout_template: "<html><body>mine</body></html>")

    assert one(ErrorPage, site).root_layout_template == "<html><body>mine</body></html>"
  end

  test "the theme declares the tokens the starter markup is written in", %{site: site} do
    StarterContent.seed!(site)

    sheet = one(Stylesheet, site)

    assert sheet.kind == :theme

    for token <- [
          "--color-ground",
          "--color-ink",
          "--color-line",
          "--color-accent",
          "--font-sans"
        ],
        do: assert(sheet.content =~ token)
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

  # Pages saved before tokens keep `contact_submit`; a page written today is tagged (spec 0.8).
  test "every starter form carries a token in both event names", %{site: site} do
    StarterContent.seed!(site)

    forms =
      for page <- rows(Page, site),
          tree = Tree.parse!(page.template),
          node <- Tree.walk(tree),
          PageForms.form?(node),
          do: {page.path, node}

    assert forms != [], "the starter has a Contact form"

    for {path, form} <- forms do
      assert Naming.form_token(form), "the form on #{path} carries a token"

      for attr <- ~w(phx-change phx-submit) do
        assert Naming.event_key(Node.attr_text(form, attr)),
               "#{attr} on #{path} is a tagged event name"
      end
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
end
