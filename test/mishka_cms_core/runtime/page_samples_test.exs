defmodule MishkaCmsCore.Runtime.PageSamplesTest do
  @moduledoc """
  What an extension's sample pages are against the rows a site is already serving, and the one write
  that closes the gap without touching a live page.

  Setting a site up writes only the pages it has no row for, so a site provisioned once keeps the
  pages it was provisioned with — which is how the blog's featured strip became a component of its
  own, the index page that places it was rewritten, and no site already serving that page ever saw
  it. Here is where that is answered, and the whole of the answer is that the live page is left
  exactly where it is and a DRAFT of it is offered instead.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.PageSamples

  require Ash.Query

  @section "manual"
  @shipped ~S(<div id="shipped">the page this version ships</div>)
  @older ~S(<div id="older">the page it was seeded with</div>)

  setup do
    {:ok, site: create_site!(name: "samples#{System.unique_integer([:positive])}")}
  end

  # WHAT AN EXTENSION HANDS OVER, which is the attribute map its "Set up" button writes with: both
  # halves read the pages from one place, so a plan cannot be comparing against pages nobody writes.
  defp definitions(site_id, paths \\ ["/:lang/manual", "/:lang/manual/all"]) do
    Enum.map(paths, fn path ->
      %{
        name: "Manual #{path}",
        path: path,
        section: @section,
        description: "A sample page",
        format: :heex,
        template: @shipped,
        active: true,
        site_id: site_id
      }
    end)
  end

  defp serving!(site, path, template, overrides \\ []) do
    create_page!(
      [
        site_id: site.id,
        name: "Their #{path}",
        path: path,
        section: @section,
        template: template
      ] ++ overrides
    )
  end

  defp drafts(site, page) do
    PageDraft
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and source_page_id == ^page.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  defp reread(site, page) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and id == ^page.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp names(entries), do: Enum.map(entries, & &1.name)

  describe "a site serving what this version ships" do
    test "has nothing offered to it, and pressing the button writes nothing", %{site: site} do
      for path <- ["/:lang/manual", "/:lang/manual/all"], do: serving!(site, path, @shipped)

      plan = PageSamples.plan(site.id, definitions(site.id))

      assert names(plan.current) == ["/:lang/manual", "/:lang/manual/all"]
      assert plan.outdated == []
      assert plan.offered == []
      assert plan.absent == []

      report = PageSamples.offer!(site.id, definitions(site.id))

      assert report.drafted == []
      assert report.current == ["/:lang/manual", "/:lang/manual/all"]

      assert PageSamples.message(report) =~ "is the one this version ships"
    end
  end

  describe "a site serving an older page" do
    setup %{site: site} do
      {:ok, page: serving!(site, "/:lang/manual", @older)}
    end

    test "is told which, before anything is written", %{site: site, page: page} do
      plan = PageSamples.plan(site.id, definitions(site.id))

      assert names(plan.outdated) == ["/:lang/manual"]
      assert names(plan.absent) == ["/:lang/manual/all"]
      assert drafts(site, page) == []
      assert reread(site, page).template == @older
    end

    # THE WHOLE OF WHAT THIS IS ALLOWED TO DO. The live page is what the site's readers are looking
    # at and it may be work somebody did; an update that wrote this module's markup over it would be
    # publishing, live, with no step in between.
    test "is offered it as a draft, and the live page is left exactly as it was", %{
      site: site,
      page: page
    } do
      report = PageSamples.offer!(site.id, definitions(site.id), label: "Manual sample")

      assert report.drafted == ["/:lang/manual"]

      assert [draft] = drafts(site, page)
      assert draft.template == @shipped
      assert draft.label == "Manual sample"
      assert draft.source_page_id == page.id
      assert is_nil(draft.applied_at)

      assert reread(site, page).template == @older
    end

    # A DRAFT THAT IS PUBLISHED HAS TO BE THE PAGE, not a page missing whatever the draft never
    # carried: `Changes.PublishPageDraft` writes every one of the draft's fields back over the live
    # row, so a field this left out is a field publishing puts back to its default. It has already
    # dropped a page's layout, its SEO tags and its language group once.
    test "forks the whole of the page it belongs to, not just its markup", %{site: site} do
      layout = create_layout!(site_id: site.id)

      page =
        serving!(site, "/:lang/manual/all", @older,
          layout_id: layout.id,
          description: "the description they wrote",
          priority: 7,
          permissions: ["manual:read"]
        )

      PageSamples.offer!(site.id, definitions(site.id))

      assert [draft] = drafts(site, page)

      assert draft.name == page.name, "publishing would rename the admin's page"
      assert draft.path == page.path
      assert draft.section == page.section
      assert draft.layout_id == layout.id
      assert draft.language == page.language
      assert draft.language_group_id == page.language_group_id
      assert draft.description == "the description they wrote"
      assert draft.priority == 7
      assert draft.permissions == ["manual:read"]
      assert draft.template == @shipped
    end

    test "is offered nothing on a second press, and keeps the one draft it has", %{
      site: site,
      page: page
    } do
      PageSamples.offer!(site.id, definitions(site.id))

      plan = PageSamples.plan(site.id, definitions(site.id))

      assert names(plan.offered) == ["/:lang/manual"]
      assert plan.outdated == []

      report = PageSamples.offer!(site.id, definitions(site.id))

      assert report.drafted == []
      assert report.waiting == ["/:lang/manual"]
      assert PageSamples.message(report) =~ "already waiting as a draft"

      assert [_one] = drafts(site, page)
    end

    # A DRAFT THAT WAS PUBLISHED IS NOT ONE THAT IS WAITING. The page then holds what this version
    # ships, so there is nothing to offer for the other reason as well — and were the page edited
    # again afterwards, the spent draft must not stand in for a fresh offer.
    test "is offered again after the draft it had was published and the page moved on", %{
      site: site,
      page: page
    } do
      PageSamples.offer!(site.id, definitions(site.id))

      assert [draft] = drafts(site, page)

      Ash.update!(draft, %{}, action: :master_publish, authorize?: false, tenant: site.id)

      assert reread(site, page).template == @shipped
      assert names(PageSamples.plan(site.id, definitions(site.id)).current) == ["/:lang/manual"]

      site
      |> reread(page)
      |> Ash.update!(%{template: @older},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      assert PageSamples.offer!(site.id, definitions(site.id)).drafted == ["/:lang/manual"]
      assert length(drafts(site, page)) == 2
    end
  end

  # A ROW IS OURS BY ITS ADDRESS AND ITS SECTION. The address alone would claim a page an admin
  # wrote where one of ours used to be and offer to replace their work with ours; the section is
  # what an extension stamps every page it writes with, and one this cannot recognise is one it has
  # no business drafting over.
  describe "a page at the address that is not ours" do
    # AND IT IS NOT THE SAME ANSWER AS AN EMPTY ADDRESS. Both were reported absent, under a line
    # telling the admin the Set up button creates what is not there — which for this one it does
    # not: the site answers at that path, so provisioning skips it exactly as this does, and the
    # admin was sent to a button that would do nothing and say nothing.
    test "reads as an address of the site's own, not as an absent one", %{site: site} do
      theirs = serving!(site, "/:lang/manual", @older, section: "theirs")

      plan = PageSamples.plan(site.id, definitions(site.id))

      assert names(plan.taken) == ["/:lang/manual"]
      assert names(plan.absent) == ["/:lang/manual/all"]
      assert plan.outdated == []

      assert PageSamples.note(hd(plan.taken)) =~ "a page of this site's own"

      assert PageSamples.offer!(site.id, definitions(site.id)).drafted == []
      assert drafts(site, theirs) == []
    end

    # AND NEITHER IS ANOTHER SITE'S, however identical its address. Every read here is scoped to the
    # site being looked at, and a draft written onto a neighbour's page is the worst thing in this
    # module that could happen.
    test "is not another site's page at the same address", %{site: site} do
      other = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      theirs = serving!(other, "/:lang/manual", @older)

      assert PageSamples.offer!(site.id, definitions(site.id)).drafted == []
      assert drafts(other, theirs) == []
      assert reread(other, theirs).template == @older
    end
  end

  # A SITE THAT SERVES NO PAGES STILL KEEPS THEM UP TO DATE. `SiteLookupPlug` answers 403 for every
  # runtime page of an `:api_only` site — the mode doing its job — and a mode is a setting an admin
  # changes, so leaving the pages behind would hand a site switched to `:hybrid` later a set of
  # months-old pages and nothing on screen to say why.
  describe "a site whose mode serves no pages" do
    test "is told so, and is offered the same drafts as any other", %{site: site} do
      Ash.update!(site, %{mode: :api_only}, action: :update, authorize?: false)

      page = serving!(site, "/:lang/manual", @older)

      plan = PageSamples.plan(site.id, definitions(site.id))

      refute plan.serves_pages?
      assert names(plan.outdated) == ["/:lang/manual"]

      assert PageSamples.offer!(site.id, definitions(site.id)).drafted == ["/:lang/manual"]
      assert [_draft] = drafts(site, page)
    end

    test "is not what a site that does serve them is told", %{site: site} do
      assert PageSamples.plan(site.id, definitions(site.id)).serves_pages?
    end
  end

  # A PAGE THE ADMIN ARCHIVED IS AN ANSWER, NOT AN ABSENCE. `read_any` cannot see an archived row —
  # AshArchival's base filter is what `MishkaCmsCore.Runtime.PageProvision` reads a second action to
  # get past — so this was reported as an address with nothing at it, under a line saying the Set up
  # button creates what is not there. It does not: the archived row still holds the path.
  describe "a page of ours the admin archived" do
    test "reads as archived rather than as an absent address", %{site: site} do
      page = serving!(site, "/:lang/manual", @older)

      :ok = Ash.destroy!(page, action: :master_destroy, authorize?: false, tenant: site.id)

      plan = PageSamples.plan(site.id, definitions(site.id))

      assert names(plan.archived) == ["/:lang/manual"]
      assert names(plan.absent) == ["/:lang/manual/all"]
      assert plan.outdated == []

      assert PageSamples.note(hd(plan.archived)) =~ "archived"
      assert PageSamples.offer!(site.id, definitions(site.id)).drafted == []
    end
  end

  # THE ONE THING A DRAFT OF A SAMPLE PAGE CAN DO TO A SITE'S READERS. A page names its components
  # by name and the name is resolved against the site's own rows at render time: one that resolves
  # to nothing draws a red "Component failed to render!" line in its place. This version's blog
  # index draws `blog-featured-posts`, which is newer than every site this offer exists for, and no
  # update installs a component a site does not have — so the offer, accepted and published, is an
  # error message where the featured strip should be.
  describe "a page this version ships that draws a component the site has not got" do
    # `<.component …/>` IS THE ONLY TAG THAT RESOLVES AGAINST A ROW. It is what
    # `MishkaCmsCore.Runtime.LiveViewHelpers` imports into every compiled module; every other
    # `<.foo>` is a function component compiled in with no row anywhere, whatever it carries.
    @drawing ~S"""
    <div id="shipped">
      <.component component_name="manual-featured" site="theirs" id="featured" />
      <.link navigate="/elsewhere" component_name="not-a-runtime-component">a function one</.link>
    </div>
    """

    defp drawing(site_id) do
      site_id
      |> definitions(["/:lang/manual"])
      |> Enum.map(&Map.put(&1, :template, @drawing))
    end

    test "is held back rather than offered, and says which component", %{site: site} do
      page = serving!(site, "/:lang/manual", @older)

      plan = PageSamples.plan(site.id, drawing(site.id))

      assert names(plan.blocked) == ["/:lang/manual"]
      assert plan.outdated == []

      note = PageSamples.note(hd(plan.blocked))

      assert note =~ "manual-featured"

      refute note =~ "not-a-runtime-component",
             "a function component was counted as one that resolves against a row"

      report = PageSamples.offer!(site.id, drawing(site.id))

      assert report.drafted == []
      assert report.blocked == ["/:lang/manual"]
      assert PageSamples.message(report) =~ "drawing components this site does not have"
      assert drafts(site, page) == []
    end

    test "is offered the moment the site has that component", %{site: site} do
      page = serving!(site, "/:lang/manual", @older)

      create_component!(site_id: site.id, name: "manual-featured")

      assert names(PageSamples.plan(site.id, drawing(site.id)).outdated) == ["/:lang/manual"]
      assert PageSamples.offer!(site.id, drawing(site.id)).drafted == ["/:lang/manual"]

      assert [draft] = drafts(site, page)
      assert String.trim(draft.template) == String.trim(@drawing)
    end

    # ARCHIVED AND SWITCHED OFF ARE THE SAME ANSWER AS NEVER INSTALLED, because the compile path is:
    # `ModuleCompilerHandler` reads the row with `active: true` and cannot see an archived one at
    # all, so all three draw the same red line and all three hold the page back.
    test "is held back while that component is switched off", %{site: site} do
      serving!(site, "/:lang/manual", @older)

      component = create_component!(site_id: site.id, name: "manual-featured")

      Ash.update!(component, %{active: false},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      assert names(PageSamples.plan(site.id, drawing(site.id)).blocked) == ["/:lang/manual"]
    end

    test "is held back while that component is archived", %{site: site} do
      serving!(site, "/:lang/manual", @older)

      component = create_component!(site_id: site.id, name: "manual-featured")

      :ok = Ash.destroy!(component, action: :master_destroy, authorize?: false, tenant: site.id)

      assert names(PageSamples.plan(site.id, drawing(site.id)).blocked) == ["/:lang/manual"]
    end

    # AND NOT ANOTHER SITE'S COMPONENT. A name resolves against the site the page belongs to, so a
    # neighbour holding one of that name says nothing about whether this page can draw it.
    test "is held back while only another site has that component", %{site: site} do
      serving!(site, "/:lang/manual", @older)

      other = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      create_component!(site_id: other.id, name: "manual-featured")

      assert names(PageSamples.plan(site.id, drawing(site.id)).blocked) == ["/:lang/manual"]
    end

    # AND IS SAID IN THE SAME BREATH AS THE ONES THAT WERE WRITTEN. "Created 1 draft" is the whole
    # of what an admin sees in the flash, and the page held back is the page the offer exists for.
    test "is named beside the drafts the same press did create", %{site: site} do
      [drawing, plain] = definitions(site.id)
      definitions = [Map.put(drawing, :template, @drawing), plain]

      for path <- ["/:lang/manual", "/:lang/manual/all"], do: serving!(site, path, @older)

      report = PageSamples.offer!(site.id, definitions)

      assert report.drafted == ["/:lang/manual/all"]
      assert report.blocked == ["/:lang/manual"]

      message = PageSamples.message(report)

      assert message =~ "Created 1 draft"
      assert message =~ "Held back: 1 page drawing components this site does not have."
    end

    # THE PAGE ALREADY SERVING IT IS LEFT ALONE. It is drawing whatever it draws today and nothing
    # here is going to change it, so reporting it as held back would be alarming an admin about a
    # page this card has no answer for.
    test "is not held back when the site is already serving it", %{site: site} do
      serving!(site, "/:lang/manual", @drawing)

      plan = PageSamples.plan(site.id, drawing(site.id))

      assert names(plan.current) == ["/:lang/manual"]
      assert plan.blocked == []
    end
  end

  describe "a site with none of these pages" do
    test "is left to the Set up button, and told so rather than told it is up to date", %{
      site: site
    } do
      plan = PageSamples.plan(site.id, definitions(site.id))

      assert names(plan.absent) == ["/:lang/manual", "/:lang/manual/all"]
      assert plan.current == []

      report = PageSamples.offer!(site.id, definitions(site.id))

      assert report.drafted == []
      assert PageSamples.message(report) =~ "none of these sample pages"
    end
  end

  describe "the line beside one page" do
    test "is written for every standing there is, and none of them is blank" do
      for standing <- [:current, :outdated, :offered, :blocked, :taken, :archived, :absent] do
        note =
          PageSamples.note(%{name: "/x", standing: standing, page_id: nil, needs: ["a-card"]})

        assert note != "", "#{standing} has nothing to say for itself"
      end
    end

    # NOTHING HERE CAN TELL A PAGE THAT IS BEHIND FROM ONE SOMEBODY REWROTE — a page carries no
    # fingerprint of what it was created from — so the one thing the line must not do is pick.
    test "does not call a page an admin may have written themselves out of date" do
      note = PageSamples.note(%{name: "/x", standing: :outdated, page_id: nil, needs: []})

      assert note =~ "edited"
      assert note =~ "not the page this version ships"
    end
  end

  # THE SENTENCE IS THE FLASH AS WELL AS THE CARD, and in the flash there is no list of groups
  # beside it. "Every sample page on this site is the one this version ships" on a site holding one
  # of the two is the card claiming to have looked at pages it never found.
  describe "what one press says it did" do
    test "does not call a site up to date on the pages it has not got", %{site: site} do
      serving!(site, "/:lang/manual", @shipped)

      message = PageSamples.message(PageSamples.offer!(site.id, definitions(site.id)))

      refute message =~ "Every sample page"
      assert message =~ "1 page already the page this version ships"
      assert message =~ "1 page not on this site"
    end

    test "says every one of them only when every one of them is here", %{site: site} do
      for path <- ["/:lang/manual", "/:lang/manual/all"], do: serving!(site, path, @shipped)

      assert PageSamples.message(PageSamples.offer!(site.id, definitions(site.id))) ==
               "Every sample page on this site is the one this version ships."
    end
  end
end
