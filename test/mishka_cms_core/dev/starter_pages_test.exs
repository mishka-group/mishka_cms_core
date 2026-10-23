# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.StarterPagesTest do
  @moduledoc """
  The about, contact and privacy pages a first install no longer writes and the dev seeds still do,
  written the way `MishkaCmsCore.Dev.Seeds` writes them: through `StarterContent.seed!/2`'s `:pages`.

  What the installer itself writes is `MishkaCmsCore.Install.StarterContentTest`'s; the whole dev
  seed is `MishkaCmsCore.Dev.SeedsInstallTest`'s, in the host application.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Dev.StarterPages
  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.{Layout, Page, PageProvision, Translations}
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Settings

  require Ash.Query

  @home ~S|<p id="home">Home</p>|

  setup do
    dir = Path.join(System.tmp_dir!(), "starter_pages_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    name = "devpages#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true, master: true)

    %{site: site, pages: StarterPages.pages(name, @home)}
  end

  test "writes the four pages, in the order a first install used to", %{site: site, pages: pages} do
    report = StarterContent.seed!(site, pages: pages)

    assert report.pages == ["/:lang", "/:lang/about", "/:lang/contact", "/:lang/privacy"]
    assert report.renamed_pages == []
    assert report.skipped_pages == []
  end

  # THE SAME ROWS THE INSTALLER'S OWN PAGE IS: a section of their own, the package's stamp, and an
  # answer in every language the site publishes in.
  test "writes them as starter pages that answer every language", %{site: site, pages: pages} do
    StarterContent.seed!(site, pages: pages)

    stored = rows(Page, site)
    assert length(stored) == 4

    for page <- stored do
      assert page.section == "starter", page.path
      assert PageProvision.provisioned_by(page) == "mishka_cms_core", page.path
      assert PageProvision.serves_all_languages?(page), page.path
    end
  end

  test "the home is the one a site hands in, and the about is the plain one unless it hands one in",
       %{site: site, pages: pages} do
    StarterContent.seed!(site, pages: pages)

    assert page(site, "/:lang").template == @home
    assert page(site, "/:lang/about").template =~ "About #{site.name}"

    other = create_site!(name: "other#{System.unique_integer([:positive])}", active: true)
    about = ~S|<article id="its-own-about">Ours</article>|
    StarterContent.seed!(other, pages: StarterPages.pages(other.name, @home, about))

    assert page(other, "/:lang/about").template == about
  end

  # Pages saved before tokens keep `contact_submit`; a page written today is tagged (spec 0.8).
  test "the contact form carries a token in both event names", %{site: site, pages: pages} do
    StarterContent.seed!(site, pages: pages)

    forms =
      for page <- rows(Page, site),
          tree = Tree.parse!(page.template),
          node <- Tree.walk(tree),
          PageForms.form?(node),
          do: {page.path, node}

    assert [{"/:lang/contact", form}] = forms
    assert Naming.form_token(form), "the form carries a token"

    for attr <- ~w(phx-change phx-submit) do
      assert Naming.event_key(Node.attr_text(form, attr)), "#{attr} is a tagged event name"
    end
  end

  test "nothing of the three needs the kit, an inline style or a script", %{
    site: site,
    pages: pages
  } do
    StarterContent.seed!(site, pages: pages)

    for page <- rows(Page, site) do
      refute page.template =~ "chelekom-"
      refute page.template =~ "<.input"
      refute page.template =~ "style="
      refute page.template =~ "<script"
    end
  end

  test "the header links to the about and contact pages, as the first install's did", %{
    site: site,
    pages: pages
  } do
    StarterContent.seed!(site, pages: pages, nav: StarterPages.nav())

    template = layout(site).template

    assert template =~ ~s|navigate={site_path("/:lang/about", lang(assigns))}|
    assert template =~ ~s|navigate={site_path("/:lang/contact", lang(assigns))}|
    assert template =~ ">About<"
    assert template =~ ">Contact<"
  end

  # ONE LINK, BOTH MODES: every link between them is written as the stored path and the page's
  # language, so it follows the site's `site.language_urls`.
  describe "the links between them" do
    setup %{site: site, pages: pages} do
      forget_settings(~w(site.languages site.language_urls), [site.id])
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok = Translations.put_site(site.id)
      StarterContent.seed!(site, pages: pages)
      :ok
    end

    defp page_links(site, path, language) do
      page = page(site, path)

      page.template
      |> LiveViewCompiler.render_template(%{
        page: %{language: language},
        query_params: %{"lang" => language}
      })
      |> then(&Regex.scan(~r/href="([^"]*)"/, &1, capture: :all_but_first))
      |> List.flatten()
    end

    test "leave the primary language unprefixed by default", %{site: site} do
      assert page_links(site, "/:lang/about", "en") == ["/"]
      assert page_links(site, "/:lang/about", "fa") == ["/fa"]
      assert page_links(site, "/:lang/contact", "en") == ["/privacy"]
      assert page_links(site, "/:lang/contact", "fa") == ["/fa/privacy"]
      assert page_links(site, "/:lang/privacy", "en") == ["/"]
    end

    test "prefix every language in prefix_all", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert page_links(site, "/:lang/about", "en") == ["/en"]
      assert page_links(site, "/:lang/contact", "en") == ["/en/privacy"]
    end
  end

  defp rows(resource, site) do
    resource
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  defp page(site, path), do: site |> then(&rows(Page, &1)) |> Enum.find(&(&1.path == path))
  defp layout(site), do: site |> then(&rows(Layout, &1)) |> hd()
end
