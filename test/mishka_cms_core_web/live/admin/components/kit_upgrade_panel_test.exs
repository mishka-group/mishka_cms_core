defmodule MishkaCmsCore.Test.Web.KitUpgradePanelTest do
  @moduledoc """
  The standings themselves, driven through a host LiveView (`MishkaCmsCore.Test.KitUpgradeHostLive`) over a
  bundle the test wrote, so what the admin is TOLD is asserted where they read it.

  The extensions' own suites cover the wiring on each dashboard. What can only be covered here is
  what the shared report does when the answer is not the happy one: a write Ash refuses, a site
  holding none of the kit's components, and the site select and the report disagreeing.

  There is a second half, and it is the half that must never write anything live: a sample page
  the site is behind on is offered as a DRAFT of that page. It is driven here over pages the test
  wrote for the same reason the components are.

  `async: false` — installs write runtime rows and rebuild the site's modules.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Test.KitUpgradeHostLive

  require Ash.Query

  @moduletag :integration

  setup do
    dir = Path.join(System.tmp_dir!(), "panel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, site: site!("panel"), other: site!("other")}
  end

  defp site!(prefix) do
    name = "#{prefix}#{System.unique_integer([:positive])}"

    create_site!(name: name, host: "#{name}.test", active: true)
  end

  defp write!(dir, file, version, template) do
    path = Path.join(dir, file)

    File.write!(
      path,
      Jason.encode!(%{
        "$schema" => "mishka.ui_kit.bundle.v3",
        "name" => "panelkit",
        "version" => version,
        "components" => [
          %{"name" => "pnl-card", "type" => "widgets", "template" => template}
        ]
      })
    )

    path
  end

  defp host(conn, bundle, sites, pages \\ []) do
    offered = Enum.map(sites, fn %{name: name, id: id} -> {name, id} end)

    live_isolated(conn, KitUpgradeHostLive,
      session: %{"bundle" => bundle, "sites" => offered, "pages" => pages}
    )
  end

  defp rows(site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  # A WRITE ASH REFUSES IS NOT AN `{:error, _}`. The installer's `create!`/`update!` run inside
  # `Ash.transaction/3`, which re-raises — so before this rescued, a bundle whose template will
  # not compile answered the admin by killing the LiveView. The row this bundle would have replaced
  # has to still be there afterwards, or the flash is all that was fixed.
  test "says so and stays up when the bundle cannot be written", %{
    conn: conn,
    dir: dir,
    site: site
  } do
    good = write!(dir, "good.json", "1.0.0", "<span>good</span>\n")
    bad = write!(dir, "bad.json", "2.0.0", "<span>{@broken</span>\n")

    {:ok, _installed} = UiKitHandler.install_kit!(good, site_id: site.id)

    {:ok, view, _html} = host(conn, bad, [site])

    view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

    assert has_element?(view, "#kit-safe")

    view |> element("#kit-safe") |> render_click()

    assert has_element?(view, "#kit-flash-error", "could not be updated")
    assert has_element?(view, "#kit"), "the modal went down with the write"
    assert hd(rows(site)).template == "<span>good</span>"
  end

  test "says so when the file it is pointed at is not a bundle", %{
    conn: conn,
    dir: dir,
    site: site
  } do
    notes = Path.join(dir, "notes.txt")
    File.write!(notes, "a note somebody left in the kits directory")

    {:ok, view, _html} = host(conn, notes, [site])

    view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

    assert has_element?(view, "#kit-flash-error", "could not be read against the bundle")
    refute has_element?(view, "#kit-report")
  end

  # THE READ RAISES TOO, and for a plainer reason than the write does: `plan/2` reads through
  # `Ash.read!`, and a dashboard hands it whatever its own site check answered — which for a tenant
  # admin is the id on their user record, taken on trust. An id the database will not cast is the
  # cheapest way to be handed one, and it must be a sentence rather than a dead LiveView.
  test "says so when the site it is asked about cannot be read", %{conn: conn, dir: dir} do
    bundle = write!(dir, "kit.json", "1.0.0", "<span>one</span>\n")

    {:ok, view, _html} = host(conn, bundle, [%{name: "Gone", id: "not-a-site-id"}])

    view |> form("#kit-form", %{"site_id" => "not-a-site-id"}) |> render_submit()

    assert has_element?(view, "#kit-flash-error", "could not be read against the bundle")
    assert has_element?(view, "#kit"), "the modal went down with the read"
    refute has_element?(view, "#kit-report")
  end

  # THE FIRST THING AN ADMIN READS, and the read-only path has to say what pressing Update would.
  # On a site holding none of this kit's components there is nothing to be up to date, and the
  # reassuring sentence reads as a failure to look.
  test "does not call a site with none of the kit's components up to date", %{
    conn: conn,
    dir: dir,
    site: site
  } do
    bundle = write!(dir, "kit.json", "1.0.0", "<span>one</span>\n")

    {:ok, _installed} = UiKitHandler.install_kit!(bundle, site_id: site.id)

    Ash.destroy!(hd(rows(site)),
      action: :master_permanent_destroy,
      authorize?: false,
      tenant: site.id
    )

    {:ok, view, _html} = host(conn, bundle, [site])

    view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

    assert has_element?(view, "#kit-headline", "none of this kit's components in use")
    assert has_element?(view, "#kit-absent-0", "pnl-card")
    refute has_element?(view, "#kit-headline", "up to date")
  end

  # THE BUTTONS WRITE TO THE SITE THE REPORT IS ABOUT, and they sit outside the form, so the select
  # moving without the report moving would point them at a site the admin had stopped looking at.
  test "follows the site select without waiting to be submitted", %{
    conn: conn,
    dir: dir,
    site: site,
    other: other
  } do
    old = write!(dir, "old.json", "1.0.0", "<span>one</span>\n")
    new = write!(dir, "new.json", "2.0.0", "<span>two</span>\n")

    {:ok, _installed} = UiKitHandler.install_kit!(old, site_id: site.id)

    {:ok, view, _html} = host(conn, new, [site, other])

    view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

    assert has_element?(view, "#kit-safe", "Update 1 component")

    view |> form("#kit-form", %{"site_id" => other.id}) |> render_change()

    refute has_element?(view, "#kit-safe"),
           "the report still offers the first site's components while the select reads the second"

    assert has_element?(view, "#kit-absent-0", "pnl-card")
  end

  # THE HALF THAT MUST NEVER WRITE ANYTHING LIVE. A component is code the kit owns; a page is what
  # a site's readers are looking at, and it may be work somebody did — so the only thing this offers
  # is a draft, and the live row has to be byte for byte where it was afterwards.
  describe "the sample pages" do
    @older ~S(<div id="older">what the site was set up with</div>)
    @shipped ~S(<div id="shipped">what this version ships</div>)

    setup %{dir: dir, site: site} do
      page =
        create_page!(
          site_id: site.id,
          name: "Their manual",
          path: "/:lang/panel-manual",
          section: "panelkit",
          template: @older
        )

      %{
        bundle: write!(dir, "kit.json", "1.0.0", "<span>one</span>\n"),
        page: page,
        pages: [{"/:lang/panel-manual", @shipped}]
      }
    end

    defp drafts(page) do
      PageDraft
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(source_page_id == ^page.id)
      |> Ash.read!(authorize?: false, page: [limit: 50])
      |> Map.fetch!(:results)
    end

    defp serving(page) do
      Page
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(id == ^page.id)
      |> Ash.read_one!(authorize?: false)
    end

    test "are reported before anything is written", context do
      %{conn: conn, site: site, bundle: bundle, page: page, pages: pages} = context

      {:ok, view, _html} = host(conn, bundle, [site], pages)

      refute has_element?(view, "#kit-pages")

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#kit-pages-headline", "create a draft?")
      assert has_element?(view, "#kit-pages-behind-0", "/:lang/panel-manual")
      assert has_element?(view, "#kit-pages-offer", "Create 1 draft")

      assert drafts(page) == [], "reading what is behind wrote to the site"
    end

    test "are offered as drafts when the admin presses it, and the live page is untouched",
         context do
      %{conn: conn, site: site, bundle: bundle, page: page, pages: pages} = context

      {:ok, view, _html} = host(conn, bundle, [site], pages)

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()
      html = view |> element("#kit-pages-offer") |> render_click()

      assert html =~ "Created 1 draft"
      assert html =~ "nothing live has changed"

      assert [draft] = drafts(page)
      assert draft.template == @shipped
      assert draft.label == "Test sample page"
      assert serving(page).template == @older
    end

    test "are not offered twice, and the second press writes no second draft", context do
      %{conn: conn, site: site, bundle: bundle, page: page, pages: pages} = context

      {:ok, view, _html} = host(conn, bundle, [site], pages)

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()
      view |> element("#kit-pages-offer") |> render_click()

      refute has_element?(view, "#kit-pages-offer"), "there is still something to offer"
      assert has_element?(view, "#kit-pages-waiting-0", "waiting as a draft")

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#kit-pages-headline", "waiting in the builder")
      assert [_one] = drafts(page)
    end

    # A SITE THAT ANSWERS 403 FOR ITS PAGES STILL KEEPS THEM. The mode is a setting an admin
    # changes, so the pages are drafted as on any other site — and the standings say out loud that
    # nobody can read them meanwhile, which is the one thing an admin cannot work out from here.
    test "say so on a site whose mode serves no pages, and are offered anyway", context do
      %{conn: conn, site: site, bundle: bundle, page: page, pages: pages} = context

      Ash.update!(site, %{mode: :api_only}, action: :update, authorize?: false)

      {:ok, view, _html} = host(conn, bundle, [site], pages)

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#kit-pages-mode", "API-only")

      view |> element("#kit-pages-offer") |> render_click()

      assert [_draft] = drafts(page)
    end

    test "are refused to an admin who may not write this site", context do
      %{conn: conn, site: site, bundle: bundle, page: page, pages: pages} = context

      {:ok, view, _html} =
        live_isolated(conn, KitUpgradeHostLive,
          session: %{
            "bundle" => bundle,
            "sites" => [{site.name, site.id}],
            "pages" => pages,
            "may_upgrade?" => false
          }
        )

      assert render_click(view, "page_drafts", %{}) =~ "not allowed"
      assert drafts(page) == []
    end

    test "are refused before anything has been checked", context do
      %{conn: conn, site: site, bundle: bundle, page: page, pages: pages} = context

      {:ok, view, _html} = host(conn, bundle, [site], pages)

      assert render_click(view, "page_drafts", %{}) =~ "Check for updates first."
      assert drafts(page) == []
    end

    # A DRAFT WHOSE COMPONENTS ARE NOT THERE IS AN ERROR MESSAGE WITH A PUBLISH BUTTON ON IT. The
    # page resolves a component by name against this site's own rows, and one that resolves to
    # nothing draws a red "failed to render" line in its place — which is exactly the state the
    # check is for: the blog's featured strip became a component of its own in the same commit that
    # rewrote the index page to place it, and an update never installs a component a site has not
    # got.
    test "are not offered while a component the shipped page draws is not on this site",
         context do
      %{conn: conn, site: site, bundle: bundle, page: page} = context

      pages = [
        {"/:lang/panel-manual",
         ~S(<div><.component component_name="pnl-featured" site="x" id="f" /></div>)}
      ]

      {:ok, view, _html} = host(conn, bundle, [site], pages)

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

      refute has_element?(view, "#kit-pages-offer"),
             "a draft was offered for a page nothing draws"

      assert has_element?(view, "#kit-pages-blocked-0", "pnl-featured")
      assert has_element?(view, "#kit-pages-headline", "waiting on components")

      assert render_click(view, "page_drafts", %{}) =~
               "drawing components this site does not have"

      assert drafts(page) == []
    end

    # AND IT SAYS WHICH HALF OF IT FAILED. Both halves reach Ash through calls that raise, and
    # the pages read used to land in the rescue around the components read: the admin was told the
    # COMPONENTS could not be read and sent to the logs to look for something that is not there.
    test "say so in their own words when the read of them fails", context do
      %{conn: conn, site: site, bundle: bundle} = context

      {:ok, view, _html} = host(conn, bundle, [site], "raise")

      view |> form("#kit-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#kit-flash-error", "The sample pages could not be read")
      refute has_element?(view, "#kit-pages")

      assert has_element?(view, "#kit-report"),
             "the components half went with the half that failed"
    end
  end
end
