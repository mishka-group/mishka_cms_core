# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageSamples do
  @moduledoc """
  What a site's sample pages are against the ones this checkout ships, and the one write that offers
  the newer ones without taking an admin's page away from them.

  ## The gap this closes

  An extension's "Set up …" button writes only the pages a site has no row for, deliberately — see
  `MishkaCmsCore.Runtime.PageProvision` — so a site provisioned once keeps the pages it was
  provisioned with for ever. `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` closed the same gap for
  COMPONENTS, and closing it left the other half wide open: the blog's featured strip became a
  component of its own, the index page that draws it was rewritten to place it, and no site already
  serving that page ever saw the new one.

  ## Why a draft, and not an update

  A live page is the admin's. They may have rewritten it, hung their own blocks on it, or simply be
  serving it to readers right now — and nothing here can tell a page that is BEHIND from one
  somebody EDITED, because a page carries no fingerprint of what it was created from. An update that
  guessed would publish this module's markup over somebody's work, live, with no step in between.

  So the offer is a `MishkaCmsCore.Runtime.PageDraft` of the page itself: it appears in the
  builder's draft picker next to the admin's own drafts, they open it, look at it, and publish it if
  they want it. Nothing live changes until they do, and publishing keeps a version of what was there
  through the page's own paper trail.

  ## The answers

  `plan/2` sorts every page an extension ships into:

    * `:current` — the row holds exactly the template this checkout ships;
    * `:outdated` — it does not, and no draft of this version's page is waiting on it. This is what
      the button writes;
    * `:offered` — a draft carrying this version's template is already pending on that page, so
      there is nothing to write. This is what makes a second press do nothing;
    * `:blocked` — it is behind, and the page this version ships draws a component this site cannot
      draw. See below;
    * `:taken` — a page that is not ours answers at that address;
    * `:archived` — a page of ours is at that address and the admin archived it;
    * `:absent` — nothing is at that address at all, which is the "Set up …" button's job and never
      this one's.

  The last three are one answer in the site's eyes and three different dead ends in the admin's: the
  "Set up …" button writes the absent one and skips the other two, so a card that called all three
  absent would send an admin to a button that does nothing for two of them.

  A row is ours when its ADDRESS and its SECTION are both the definition's. The address alone would
  claim a page an admin wrote at the same path as their own work and offer to replace it; the
  section is what an extension stamps every page it writes with, and a page whose section an admin
  has changed is one this cannot recognise — so it is left alone, which is the safe way round.

  ## Why a page can be held back

  A page is markup that names components by name, and the name resolves against the site's own rows
  at render time: `MishkaCmsCore.Runtime.LiveViewHelpers` draws a red "Component failed to render!"
  line in place of one it cannot build. This version's blog index draws `blog-featured-posts`, which
  is newer than the sites the offer exists for, and no update installs a component a site does not
  have — the "Set up …" button does. So offering that page to a site without it would be offering an
  admin a draft whose whole purpose is to put an error message in front of their readers.

  `:blocked` is the answer instead, naming the components that are not there. Nothing is written for
  such a page at any setting.

  ## Pressing it twice

  `offer!/3` reads the plan again inside the call rather than taking it from the caller, and writes
  one draft per `:outdated` page. On the second press those pages are `:offered` and nothing is
  written. An admin who then EDITS the draft moves it off this version's template, so the offer is
  made again — that is the honest answer to "is a draft of the shipped page waiting here", and the
  second draft costs them nothing but a row in the picker.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.Site

  @package %{page_code: :package}

  require Ash.Query

  # The page size of the reads below, not how much of them is read: `every_page/1` reads all of it.
  @row_limit 100

  @label gettext_noop("Sample page")

  @typedoc """
  Where one shipped page stands on this site. `:offered` is not a kind of `:outdated` — it is the
  work already done, and a button that offered it again would leave the picker full of copies.
  """
  @type standing ::
          :current | :outdated | :offered | :blocked | :taken | :archived | :absent

  @typedoc """
  One shipped page and its standing. `name` is the page's ADDRESS: that is what an admin recognises
  a sample page by, and what every report of one is written from. `needs` names the components this
  version's page draws that the site cannot draw, and is empty wherever there are none.
  """
  @type entry :: %{
          name: String.t(),
          standing: standing(),
          page_id: String.t() | nil,
          needs: [String.t()]
        }

  @type plan :: %{
          site_id: String.t(),
          serves_pages?: boolean(),
          current: [entry()],
          outdated: [entry()],
          offered: [entry()],
          blocked: [entry()],
          taken: [entry()],
          archived: [entry()],
          absent: [entry()]
        }

  @type report :: %{
          drafted: [String.t()],
          waiting: [String.t()],
          current: [String.t()],
          blocked: [String.t()],
          taken: [String.t()],
          archived: [String.t()],
          absent: [String.t()]
        }

  # WHAT A SENTENCE SAYS ABOUT A GROUP THAT WAS NOT WRITTEN, in the order an admin cares about them.
  # One list rather than a clause per combination: six groups are sixty-four sentences, and the ones
  # nobody wrote are the ones that quietly claim everything is up to date.
  @standings [:waiting, :current, :blocked, :taken, :archived, :absent]

  @doc """
  Where every page in `definitions` stands on `site_id`. Reads, and writes nothing at all: this is
  what a dashboard shows an admin BEFORE anything happens.

  `definitions` are the attribute maps a page create takes — the same ones the extension hands
  `MishkaCmsCore.Runtime.PageProvision` — so the two can never be describing different pages.
  """
  @spec plan(String.t(), [map()], map() | nil) :: plan()
  def plan(site_id, definitions, actor \\ nil)
      when is_binary(site_id) and is_list(definitions) do
    surveyed = survey(site_id, definitions, actor)

    %{
      site_id: site_id,
      serves_pages?: serves_pages?(site_id, actor),
      current: entries(surveyed, :current),
      outdated: entries(surveyed, :outdated),
      offered: entries(surveyed, :offered),
      blocked: entries(surveyed, :blocked),
      taken: entries(surveyed, :taken),
      archived: entries(surveyed, :archived),
      absent: entries(surveyed, :absent)
    }
  end

  @doc """
  Offers every outdated page as a draft of itself and says what it did.

  `:label` is what the drafts are called in the builder's picker; it defaults to `#{inspect(@label)}`.

  Writes nothing but `MishkaCmsCore.Runtime.PageDraft` rows. No live page is touched here at any
  setting — publishing one is the admin's own gesture, in the builder, one page at a time.

  Pass `actor: user` and every draft is written as them, so its history says who forked the page.
  """

  @spec offer!(String.t(), [map()], keyword()) :: report()
  def offer!(site_id, definitions, opts \\ [])
      when is_binary(site_id) and is_list(definitions) do
    label = Keyword.get(opts, :label, Gettext.gettext(MishkaCmsCore.Gettext, @label))
    # WHO ASKED FOR THESE DRAFTS. Every row written below is written as them, so the draft's own
    # history says who forked the page — absent only for a caller with no session behind it.
    actor = Keyword.get(opts, :actor)
    surveyed = survey(site_id, definitions, actor)

    drafted =
      for {definition, page, :outdated, _needs} <- surveyed do
        draft!(page, definition, label, site_id, actor)

        definition.path
      end

    %{
      drafted: drafted,
      waiting: paths(surveyed, :offered),
      current: paths(surveyed, :current),
      blocked: paths(surveyed, :blocked),
      taken: paths(surveyed, :taken),
      archived: paths(surveyed, :archived),
      absent: paths(surveyed, :absent)
    }
  end

  @doc """
  The line a dashboard shows beside one page, saying what its standing is.

  An `:outdated` page is not called old. Nothing here can tell a row that is behind from one an
  admin rewrote, and a card that called somebody's own work outdated would be lying to them in the
  one sentence that has to be trusted.
  """
  @spec note(entry()) :: String.t()
  def note(%{standing: :current}), do: gettext("the page this version ships")

  def note(%{standing: :outdated}),
    do: gettext("not the page this version ships — older here, or edited")

  def note(%{standing: :offered}), do: gettext("this version's page is waiting as a draft")

  def note(%{standing: :blocked, needs: needs}),
    do:
      gettext("this version's page draws %{components} — not in use on this site",
        components: Enum.join(needs, ", ")
      )

  def note(%{standing: :taken}), do: gettext("a page of this site's own answers at this address")
  def note(%{standing: :archived}), do: gettext("the page of ours at this address is archived")
  def note(%{standing: :absent}), do: gettext("this site has no page at this address")

  @doc """
  What one offer did, worded from what was actually written.

  The sentence about nothing living having changed is not decoration: an admin who pressed a button
  on a dashboard and was told "3 pages" has every reason to think their site just changed, and the
  whole point of this path is that it did not.
  """
  @spec message(report()) :: String.t()
  # NOTHING OF OURS TO SPEAK FOR. Every page this version ships is missing from the site, and "all
  # up to date" on a site holding none of them reads as the card failing to look.
  def message(%{drafted: [], waiting: [], current: [], blocked: []}),
    do: gettext("This site has none of these sample pages.")

  # AND EVERY ONE OF THEM IS HERE, which is a different sentence from every one that is here being
  # current. This one goes into the flash, where there is no list of groups beside it to say that
  # four of the six pages it speaks for are not on the site at all.
  def message(%{drafted: [], waiting: [], blocked: [], taken: [], archived: [], absent: []}),
    do: gettext("Every sample page on this site is the one this version ships.")

  def message(%{drafted: []} = report),
    do:
      gettext("Nothing new to offer. %{standings}.",
        standings: Enum.join(standings(report), gettext(", "))
      )

  def message(report) do
    drafts = draft_count(length(report.drafted))

    # A PAGE THAT WAS NOT OFFERED HAS TO BE SAID IN THE SAME BREATH as the ones that were. An admin
    # told "Created 5 drafts" on a site where the sixth was held back has no reason to look for it,
    # and the one held back is the one the whole offer exists for.
    case report.blocked do
      [] ->
        gettext(
          "Created %{drafts} from the pages this version ships. Open each page in the builder to look at its draft and publish it when you want it — nothing live has changed.",
          drafts: drafts
        )

      blocked ->
        gettext(
          "Created %{drafts} from the pages this version ships. Open each page in the builder to look at its draft and publish it when you want it — nothing live has changed. Held back: %{held} drawing components this site does not have.",
          drafts: drafts,
          held: page_count(length(blocked))
        )
    end
  end

  defp standings(report) do
    for key <- @standings,
        pages = Map.fetch!(report, key),
        pages != [],
        do: standing(key, length(pages))
  end

  defp standing(:waiting, count),
    do:
      ngettext(
        "1 page already waiting as a draft",
        "%{count} pages already waiting as a draft",
        count
      )

  defp standing(:current, count),
    do:
      ngettext(
        "1 page already the page this version ships",
        "%{count} pages already the page this version ships",
        count
      )

  defp standing(:blocked, count),
    do:
      ngettext(
        "1 page drawing components this site does not have",
        "%{count} pages drawing components this site does not have",
        count
      )

  defp standing(:taken, count),
    do:
      ngettext(
        "1 page at an address a page of this site's own answers",
        "%{count} pages at an address a page of this site's own answers",
        count
      )

  defp standing(:archived, count),
    do: ngettext("1 page archived here", "%{count} pages archived here", count)

  defp standing(:absent, count),
    do: ngettext("1 page not on this site", "%{count} pages not on this site", count)

  # ---------------------------------------------------------------------------
  # Where each page stands
  # ---------------------------------------------------------------------------

  # THE ROWS AS WELL AS THE VERDICT, because `offer!/3` forks the row it found: reading the plan and
  # then reading the pages again would be two answers to one question, with a write in between.
  defp survey(site_id, definitions, actor) do
    paths = Enum.map(definitions, & &1.path)
    drawn = Enum.map(definitions, &{&1, drawn(&1.template)})
    pages = live_pages(site_id, paths, actor)
    archived = archived_pages(site_id, paths, actor)
    drafts = pending_drafts(site_id, Enum.map(pages, & &1.id), actor)

    in_use =
      components_in_use(
        site_id,
        for({_definition, names} <- drawn, name <- names, do: name),
        actor
      )

    Enum.map(drawn, fn {definition, names} ->
      needs = names -- in_use

      case Enum.find(pages, &ours?(&1, definition)) do
        nil -> {definition, nil, elsewhere(pages ++ archived, definition), needs}
        page -> {definition, page, judge(page, definition, drafts, needs), needs}
      end
    end)
  end

  defp ours?(page, definition),
    do: page.path == definition.path and page.section == definition.section

  # WHOSE ADDRESS IT IS WHEN IT IS NOT OURS, which is three answers and used to be one. The site
  # holds a row at that path in two of them, so the "Set up …" button will skip it exactly as this
  # does — and a card that sent the admin there to have it created would be sending them nowhere.
  defp elsewhere(rows, definition) do
    case Enum.find(rows, &(&1.path == definition.path)) do
      nil -> :absent
      row -> if ours?(row, definition), do: :archived, else: :taken
    end
  end

  # A PAGE THIS SITE CANNOT DRAW IS NOT A PAGE TO OFFER, before anything else about it: a draft
  # whose components are not there publishes a red line where the block should be. The row holding
  # the shipped template already is left alone — it is drawing whatever it draws today and saying so
  # would be alarming an admin about a page nothing here is going to change.
  defp judge(page, definition, drafts, needs) do
    shipped = String.trim(definition.template)

    cond do
      String.trim(page.template) == shipped -> :current
      needs != [] -> :blocked
      Enum.any?(drafts, &offers?(&1, page.id, shipped)) -> :offered
      true -> :outdated
    end
  end

  defp offers?(draft, page_id, shipped),
    do: draft.source_page_id == page_id and String.trim(draft.template) == shipped

  defp entries(surveyed, wanted) do
    for {definition, page, standing, needs} <- surveyed,
        standing == wanted,
        do: %{name: definition.path, standing: standing, page_id: page && page.id, needs: needs}
  end

  defp paths(surveyed, wanted) do
    for {definition, _page, standing, _needs} <- surveyed,
        standing == wanted,
        do: definition.path
  end

  # ---------------------------------------------------------------------------
  # The write
  # ---------------------------------------------------------------------------

  # THE THREE ANSWERS EVERY RUNTIME WRITE GIVES, and this one is a draft of somebody's page: with
  # nobody behind it the history says nobody forked it, which is exactly what it said before. The
  # markup is the extension's, so the write says it is a package's.
  defp draft!(page, definition, label, _site_id, nil) do
    PageDraft
    |> Ash.Changeset.for_create(:master_create, draft_attrs(page, definition, label),
      authorize?: false,
      context: @package
    )
    |> Ash.create!()
  end

  defp draft!(page, definition, label, _site_id, %{site_id: nil} = actor) do
    PageDraft
    |> Ash.Changeset.for_create(:master_create, draft_attrs(page, definition, label),
      actor: actor,
      context: @package
    )
    |> Ash.create!()
  end

  defp draft!(page, definition, label, site_id, actor) do
    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      page |> draft_attrs(definition, label) |> Map.delete(:site_id),
      actor: actor,
      tenant: site_id,
      context: @package
    )
    |> Ash.create!()
  end

  # A DRAFT CARRIES THE WHOLE OF THE PAGE IT FORKS, every field its create accepts, because
  # publishing writes the draft's fields back over the live row — see
  # `MishkaCmsCore.Runtime.Resources.Changes.PublishPageDraft`. A field the draft never took is put
  # back to its default when it is published, which is how a publish drops a page's layout, its SEO
  # tags, its language and its language group. `MishkaCmsCore.Runtime.PageBuilder.Drafts` forks a
  # page the same way and for the same reason.
  #
  # THE TEMPLATE IS THE ONLY THING TAKEN FROM THE SHIPPED PAGE. Everything else on the row is the
  # admin's — the description they rewrote, the priority they set, the permissions they put on it —
  # and an offer that carried those over would be offering something nobody asked for under the name
  # of a template update.
  #
  # The nils are dropped rather than sent: a draft naming no language group would make the published
  # page the master of a group of its own.
  defp draft_attrs(page, definition, label) do
    PageDraft
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> then(&[:site_id | &1])
    |> Map.new(&{&1, Map.get(page, &1)})
    |> Map.merge(%{
      label: label,
      template: definition.template,
      source_page_id: page.id,
      priority: page.priority || 0
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  # EVERY ATTRIBUTE, not a projection: the row is forked whole into a draft, and a field this read
  # left behind is a field the publish puts back to its default.
  defp live_pages(site_id, paths, actor) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, reading(actor))
    |> Ash.Query.filter(site_id == ^site_id and path in ^paths)
    |> rows(actor)
  end

  # ARCHIVED ROWS ARE READ SEPARATELY because nothing else can see them: AshArchival's base filter
  # keeps them out of `:read_any`, which is why `MishkaCmsCore.Runtime.PageProvision` reads the two
  # actions as well. Only the address and the section are wanted here — an archived page is never
  # forked, only reported.
  defp archived_pages(site_id, paths, actor) do
    {action, opts} = archived_read(actor)

    Page
    |> Ash.Query.for_read(action, %{}, opts)
    |> Ash.Query.filter(site_id == ^site_id and path in ^paths)
    |> Ash.Query.select([:id, :path, :section])
    |> rows(actor)
  end

  # A COMPONENT THIS SITE CAN ACTUALLY DRAW, which is narrower than a row of that name existing.
  # `MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler` builds a component's module from a row
  # read with `active: true` and cannot see an archived one at all, so a component that is archived
  # or switched off renders the same red line as one that was never installed — and a page drawing
  # it is held back for the same reason.
  defp components_in_use(_site_id, [], _actor), do: []

  defp components_in_use(site_id, names, actor) do
    wanted = Enum.uniq(names)

    Component
    |> Ash.Query.for_read(:read_any, %{}, reading(actor))
    |> Ash.Query.filter(name in ^wanted and site_id == ^site_id and active == true)
    |> Ash.Query.select([:name])
    |> rows(actor)
    |> Enum.map(& &1.name)
  end

  # WHAT THE PAGE WILL ASK THE SITE FOR, read off the template that is about to be forked rather
  # than listed beside it: a list kept by hand drifts from the markup, and it is the markup that
  # draws the red line.
  #
  # ONLY A LITERAL NAME ON A `<.component>` TAG. Every other `<.foo>` in these templates is a
  # function component compiled into the runtime with no row behind it, and a name written as an
  # expression resolves to something no read can know — the same line
  # `MishkaCmsCore.Runtime.Resources.Validations.StatefulIds` draws. Markup this cannot parse is
  # `MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles`'s refusal to make, not this
  # module's to guess at.
  defp drawn(template) when is_binary(template) do
    case Tree.parse(template) do
      {:ok, tree} ->
        for node <- Tree.walk(tree),
            node.kind == :component,
            node.tag == ".component",
            {:string, name} <- [Node.attr(node, "component_name")],
            trimmed = String.trim(name),
            trimmed != "",
            uniq: true,
            do: trimmed

      _unparseable ->
        []
    end
  end

  defp drawn(_template), do: []

  defp pending_drafts(_site_id, [], _actor), do: []

  defp pending_drafts(site_id, page_ids, actor) do
    PageDraft
    |> Ash.Query.for_read(:read_any, %{}, reading(actor))
    |> Ash.Query.filter(
      site_id == ^site_id and source_page_id in ^page_ids and is_nil(applied_at)
    )
    |> Ash.Query.select([:id, :source_page_id, :template])
    |> rows(actor)
  end

  # A SITE WHOSE MODE SERVES NO PAGES STILL GETS THEM. `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug`
  # answers 403 for every runtime page of an `:api_only` site, which is the mode doing its job and
  # not a reason to leave the rows out: a mode is a setting an admin changes, and a site switched to
  # `:hybrid` later would be missing every page with nothing on screen to say why. So the pages are
  # written and updated as on any other site, and the card says out loud that nobody can read them
  # until the mode changes.
  defp serves_pages?(site_id, actor) do
    Site
    |> Ash.Query.for_read(:get_any, %{}, reading(actor))
    |> Ash.Query.filter(id == ^site_id)
    |> Ash.Query.select([:mode])
    |> Ash.read_one!(reading(actor))
    |> case do
      %{mode: :api_only} -> false
      _serves_pages -> true
    end
  end

  defp rows(query, actor) do
    query
    |> Ash.read!(reading(actor) ++ [page: [limit: @row_limit]])
    |> every_page()
  end

  # SEE `MishkaCmsCore.Runtime.PageProvision`'s `reading/1`: the read action does not change with
  # the actor, because every read above names the site in its own filter.
  defp reading(nil), do: [authorize?: false]
  defp reading(actor), do: [actor: actor]

  # THE ARCHIVED ROWS, AND THE ONE READ AN ACTOR'S ROLE DOES CHANGE. `:master_archived` refuses a
  # tenant actor outright — see `MishkaCmsCore.Runtime.Resources.Validations.TenantContext` — so the
  # site's own admin reads its own `:archived` under its tenant, which answers with the same rows
  # for the only site they can be provisioning.
  defp archived_read(nil), do: {:master_archived, [authorize?: false]}
  defp archived_read(%{site_id: nil} = actor), do: {:master_archived, [actor: actor]}

  defp archived_read(%{site_id: site_id} = actor),
    do: {:archived, [actor: actor, tenant: site_id]}

  # A PAGE THAT CARRIED SOMETHING is what earns the next one: a keyset page with no results answers
  # itself, so a page claiming `more?` over nothing would be asked for its successor for ever.
  defp every_page(%{results: [_first | _rest] = found, more?: true} = page),
    do: found ++ every_page(Ash.page!(page, :next))

  defp every_page(%{results: found}), do: found

  defp draft_count(count), do: ngettext("1 draft", "%{count} drafts", count)

  defp page_count(count), do: ngettext("1 page", "%{count} pages", count)
end
