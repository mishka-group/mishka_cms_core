defmodule MishkaCmsCore.Runtime.PageProvisionTest do
  @moduledoc """
  The question every caller that writes pages by code has to ask — an extension provisioning a site,
  the dev seeds — and the two ways it is answered: by reading what the site already holds, and by
  reading the refusal when the database will not have the row.

  The case the whole module exists for is the NAME. A page is unique by its path and by its name
  within a site, so a site with a page called "Blog" at an address of its own refuses a sample page
  at a path nothing has taken — and refuses it in the middle of a run, where a raise means the
  definitions after it are never written and every later run stops at the same row.

  Nothing here names the identities it expects to be honoured. They are read off
  `MishkaCmsCore.Runtime.Page`, which is what makes the answer survive one being added.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageProvision

  require Ash.Query

  setup do
    {:ok, site: create_site!(name: "provision#{System.unique_integer([:positive])}")}
  end

  defp definitions(site_id) do
    [
      {"Manual home", "/:lang/manual"},
      {"Manual entry", "/:lang/manual/:slug"},
      {"Manual index", "/:lang/manual/all"}
    ]
    |> Enum.map(fn {name, path} ->
      %{
        name: name,
        title: name,
        path: path,
        section: "manual",
        description: name,
        format: :heex,
        template: "<div>#{name}</div>",
        active: true,
        site_id: site_id
      }
    end)
  end

  defp paths(site_id), do: Enum.map(definitions(site_id), & &1.path)

  defp write!(attrs) do
    Page
    |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
    |> Ash.create!()
  end

  defp run(site_id, definitions \\ nil) do
    site_id
    |> PageProvision.missing(definitions || definitions(site_id))
    |> PageProvision.create(&write!/1)
  end

  defp created(report), do: Enum.map(report.created, & &1.path)

  defp rows(site_id) do
    for action <- [:read_any, :master_archived],
        row <-
          Page
          |> Ash.Query.for_read(action, %{}, authorize?: false)
          |> Ash.Query.filter(site_id == ^site_id)
          |> Ash.read!(authorize?: false, page: [limit: 100])
          |> Map.fetch!(:results),
        do: row
  end

  # `count` archived pages under one name, written straight to the table: this is a fixture for the
  # read's paging, and the create action would compile a template for every one of them. The ids are
  # dictated rather than generated because a paginated read is sorted by primary key and this site's
  # own rows carry time-ordered uuids — these have to be the page that comes back first, or the test
  # says nothing on any run.
  defp crowd!(site_id, name, count) do
    for index <- 1..count do
      Ash.Seed.seed!(
        Page,
        %{
          id: "00000000-0000-4000-8000-#{String.pad_leading("#{index}", 12, "0")}",
          name: name,
          title: name,
          path: "/crowd-#{index}",
          section: "manual",
          description: "One of many",
          format: :heex,
          template: "<div>crowd</div>",
          active: true,
          site_id: site_id,
          archived_at: DateTime.utc_now()
        },
        tenant: site_id
      )
    end
  end

  describe "a site with none of them" do
    test "is given every page, in the order they were handed over", %{site: site} do
      report = run(site.id)

      assert created(report) == paths(site.id)
      assert report.skipped == []
      assert Enum.sort(Enum.map(rows(site.id), & &1.path)) == Enum.sort(paths(site.id))
    end

    test "is not given one because another site has it", %{site: site} do
      other = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      run(other.id)

      assert created(run(site.id)) == paths(site.id)
    end
  end

  describe "a path that is not free" do
    test "is left to whoever holds it, and the rest are still written", %{site: site} do
      [taken | rest] = paths(site.id)
      mine = create_page!(site_id: site.id, path: taken, template: ~S(<div>mine</div>))

      report = run(site.id)

      assert created(report) == rest
      assert [%{path: ^taken, fields: fields}] = report.skipped
      assert fields[:path] == taken
      assert Enum.find(rows(site.id), &(&1.path == taken)).id == mine.id
    end

    test "says what holds it, without naming the site back to whoever chose it", %{site: site} do
      [taken | _rest] = paths(site.id)
      create_page!(site_id: site.id, path: taken, template: ~S(<div>mine</div>))

      assert [held] = run(site.id).skipped

      note = PageProvision.note(held)

      assert note =~ taken
      assert note =~ ~s(its path "#{taken}" is taken)
      refute note =~ site.id
    end
  end

  # THE IDENTITY NO READING OF PATHS CAN SEE, and the one a real site fails on: every site the dev
  # seeds touched holds a page named "Blog" at `/blog`. An address is what a page IS, so a held one
  # is a real skip; a NAME is how an admin finds it in a list, and answering a held one with a skip
  # left the page that mattered most at an address nothing had taken, and no later run would ever
  # write it.
  describe "a name that is not free" do
    test "is answered with the next free name, at the address it asked for", %{site: site} do
      [wanted_path | _rest] = paths(site.id)

      mine =
        create_page!(
          site_id: site.id,
          name: "Manual home",
          path: "/somewhere-of-its-own",
          template: ~S(<div>mine</div>)
        )

      report = run(site.id)

      assert created(report) == paths(site.id)
      assert report.skipped == []

      written = Enum.find(rows(site.id), &(&1.path == wanted_path))

      assert written, "the page whose name was taken was not written at all"
      assert written.name == "manual-home-2"

      assert Enum.find(rows(site.id), &(&1.path == "/somewhere-of-its-own")).id == mine.id,
             "the page holding the name was written over"
    end

    test "says so, naming the address, what is held and what it was called instead", %{site: site} do
      [wanted_path | _rest] = paths(site.id)

      create_page!(
        site_id: site.id,
        name: "Manual home",
        path: "/somewhere-of-its-own",
        template: ~S(<div>mine</div>)
      )

      assert [renamed] = run(site.id).renamed
      assert renamed.path == wanted_path
      assert renamed.name == "manual-home-2"
      assert renamed.fields[:name] == "manual-home"

      note = PageProvision.note(renamed)

      assert note =~ wanted_path
      assert note =~ ~s(its name "manual-home" is taken)
      assert note =~ ~s(so it was created as "manual-home-2")
      refute note =~ site.id
    end

    # THE NAME AS THE ROW CARRIES IT, which is not the name anybody typed: the create slugifies it,
    # so "MANUAL HOME" is this definition's name too and a comparison of the literals misses it.
    test "counts the site's own spelling of it", %{site: site} do
      create_page!(
        site_id: site.id,
        name: "MANUAL HOME",
        path: "/shouting",
        template: ~S(<div>mine</div>)
      )

      assert [%{name: "manual-home-2"}] = run(site.id).renamed
    end

    # AND ONE THE ADMIN ARCHIVED, WHICH THE INDEX ITSELF WOULD LET THROUGH: every unique index on
    # this table is partial on `(archived_at IS NULL)`, so only the read above can see that row. A
    # site that took the write would hold a second page under a name it has already used, and the
    # archived one could never be unarchived again.
    test "counts one the admin archived, which the database would have allowed", %{site: site} do
      mine =
        create_page!(
          site_id: site.id,
          name: "Manual home",
          path: "/archived-one",
          template: ~S(<div>mine</div>)
        )

      :ok = Ash.destroy!(mine, action: :master_destroy, authorize?: false, tenant: site.id)

      assert [%{name: "manual-home-2"}] = run(site.id).renamed
    end

    # EVERY NAME IN THE WAY, not the first one: a site that has been lived in holds more than one
    # spelling of the same idea, and a run that offered `Manual home 2` without asking whether THAT
    # was free would be refused by the database for the same reason it was renamed at all.
    test "keeps looking until it finds one nothing holds", %{site: site} do
      for {name, path} <- [{"Manual home", "/one"}, {"Manual home 2", "/two"}] do
        create_page!(site_id: site.id, name: name, path: path, template: ~S(<div>mine</div>))
      end

      assert [%{name: "manual-home-3"}] = run(site.id).renamed
      assert Enum.find(rows(site.id), &(&1.path == hd(paths(site.id)))).name == "manual-home-3"
    end

    # AND GIVES UP RATHER THAN GUESSING FOR EVER. A site holding every name this looks at has
    # something going on that a provisioner has no business answering by writing a twentieth page,
    # and the honest answer is the skip it would have given before.
    test "is left alone when nothing it offers is free either", %{site: site} do
      [wanted_path | rest] = paths(site.id)

      for step <- 1..20 do
        create_page!(
          site_id: site.id,
          name: (step == 1 && "Manual home") || "Manual home #{step}",
          path: "/taken-#{step}",
          template: ~S(<div>mine</div>)
        )
      end

      report = run(site.id)

      assert created(report) == rest
      assert report.renamed == []
      assert [%{path: ^wanted_path, fields: fields}] = report.skipped
      assert fields[:name] == "manual-home"
    end

    # A NAME THIS RUN IS ABOUT TO TAKE IS TAKEN, and no read can see it: the row is not there yet.
    # Two definitions wanting one name is what a bundle looks like the day somebody copies a page
    # definition and forgets to rename it, and offering both the same free name is a create the
    # database refuses in the middle of the run.
    test "does not offer one definition the name another is about to be written under", %{
      site: site
    } do
      twins =
        site.id
        |> definitions()
        |> Enum.take(2)
        |> Enum.map(&%{&1 | name: "Manual home"})

      create_page!(
        site_id: site.id,
        name: "Manual home",
        path: "/somewhere-of-its-own",
        template: ~S(<div>mine</div>)
      )

      report = run(site.id, twins)

      assert created(report) == Enum.map(twins, & &1.path)
      assert Enum.map(report.renamed, & &1.name) == ["manual-home-2", "manual-home-3"]
    end

    # AND NEITHER IS A NAME A DEFINITION THAT NEEDS NO RENAMING IS ABOUT TO TAKE. The page it belongs
    # to is not written yet, so no read can see it — and offering it to the definition ahead of it in
    # the run is the same create refused, one row later.
    test "does not offer one the name a definition that is free is about to be written under", %{
      site: site
    } do
      [first, second | _rest] = definitions(site.id)

      wanted = [%{first | name: "Manual home"}, %{second | name: "Manual home 2"}]

      create_page!(
        site_id: site.id,
        name: "Manual home",
        path: "/somewhere-of-its-own",
        template: ~S(<div>mine</div>)
      )

      report = run(site.id, wanted)

      assert created(report) == Enum.map(wanted, & &1.path)
      assert report.skipped == []
      assert Enum.map(report.renamed, & &1.name) == ["manual-home-3"]

      assert Enum.sort(for row <- rows(site.id), do: row.name) ==
               ["manual-home", "manual-home-2", "manual-home-3"]
    end

    # AND IS NOT A WRITE THAT IS ATTEMPTED AND TURNED DOWN. Every write compiles the page's template
    # before its row is reached, so the plan decides what is written and the database is never asked
    # a question it has already been answered.
    test "is written once, under the name the plan chose", %{site: site} do
      create_page!(
        site_id: site.id,
        name: "Manual home",
        path: "/somewhere-of-its-own",
        template: ~S(<div>mine</div>)
      )

      report =
        site.id
        |> PageProvision.missing(definitions(site.id))
        |> PageProvision.create(fn attrs ->
          send(self(), {:written, attrs.path, attrs.name})

          write!(attrs)
        end)

      assert created(report) == paths(site.id)

      assert_received {:written, "/:lang/manual", "Manual home 2"}

      for path <- tl(paths(site.id)), do: assert_received({:written, ^path, _name})
    end
  end

  # ONE NAME'S DISCARDED COPIES MUST NOT CROWD ANOTHER OFF THE READ. Every unique index here is
  # partial on `(archived_at IS NULL)`, so one name can hold any number of archived rows while the
  # read is asked about every name at once — and a read that stopped at its first page would see
  # those and not the archived row holding a LATER definition's name, which would then be written
  # back over a page the admin threw away. `MishkaCmsCore.Dev.Seeds` is where this was found, in its
  # hooks.
  describe "a name behind more archived rows than one page of the read holds" do
    test "is still seen, and the page it holds is still given a name of its own", %{site: site} do
      last = List.last(definitions(site.id))

      archived =
        create_page!(
          site_id: site.id,
          name: last.name,
          path: "/put-away",
          template: ~S(<div>mine</div>)
        )

      :ok = Ash.destroy!(archived, action: :master_destroy, authorize?: false, tenant: site.id)

      crowd!(site.id, "manual-home", 120)

      report = run(site.id)

      assert created(report) == paths(site.id)

      assert Enum.map(report.renamed, &{&1.path, &1.name}) == [
               {hd(paths(site.id)), "manual-home-2"},
               {List.last(paths(site.id)), "manual-index-2"}
             ]
    end
  end

  # WHICH OF THE TWO SKIPS IT IS, which every report made of them has to be able to ask. A page the
  # site answers at is a page it has; one whose NAME a different page holds was never written and no
  # run will write it while that name is held, and a report reading the two as one thing tells
  # whoever is looking at it that the site has a page that is not there.
  describe "a page left alone" do
    test "is answered for when the site holds its address", %{site: site} do
      [taken | _rest] = paths(site.id)
      create_page!(site_id: site.id, path: taken, template: ~S(<div>mine</div>))

      assert [held] = run(site.id).skipped
      assert PageProvision.answered?(held)
    end

    # AND THE SKIP THIS USED TO BE. A name held elsewhere is no longer a skip at all — the page is
    # written under another name — so the only skip left that the site does not answer for is one
    # the database refused after the plan was made, which `answered?/1` still has to tell apart.
    test "is not answered for when the database refused it on a name", %{site: site} do
      plan = PageProvision.missing(site.id, definitions(site.id))

      create_page!(
        site_id: site.id,
        name: "Manual home",
        path: "/arrived-in-between",
        template: ~S(<div>mine</div>)
      )

      assert [held] = PageProvision.create(plan, &write!/1).skipped
      refute PageProvision.answered?(held)
    end

    # AND CARRIES EVERY IDENTITY THAT HOLDS IT, not the first one the resource happens to declare.
    # A run repeated holds each page by its name AND by its path, and an answer read off the first
    # match alone would turn on the order the identities are written in — `unique_name_per_site` is
    # declared first, so it would say the site does not answer at a page it wrote itself.
    test "names every identity holding it when the run is repeated", %{site: site} do
      run(site.id)

      assert [held | _rest] = run(site.id).skipped

      assert held.fields[:name] == "manual-home"
      assert held.fields[:path] == hd(paths(site.id))
      assert PageProvision.answered?(held)
    end
  end

  describe "a second run" do
    test "writes nothing and reports every page as already there", %{site: site} do
      first = run(site.id)
      second = run(site.id)

      assert created(first) == paths(site.id)
      assert created(second) == []
      assert Enum.map(second.skipped, & &1.path) == paths(site.id)
      assert length(rows(site.id)) == length(paths(site.id))
    end

    test "finishes what a run that was interrupted did not", %{site: site} do
      [first_path | rest] = paths(site.id)

      {[one | _others], held} = PageProvision.missing(site.id, definitions(site.id))
      write!(one.attrs)

      assert one.attrs.path == first_path
      assert held == []

      report = run(site.id)

      assert created(report) == rest
      assert Enum.map(report.skipped, & &1.path) == [first_path]
      assert length(rows(site.id)) == length(paths(site.id))
    end
  end

  # WHAT THE DATABASE SAYS, which is the half of the answer the plan cannot read: an identity keyed
  # on a value the create itself mints, and a row somebody else wrote after the plan was made.
  describe "a row the plan could not know about" do
    test "is a page left alone rather than a run that stops", %{site: site} do
      plan = PageProvision.missing(site.id, definitions(site.id))
      [first_path | rest] = paths(site.id)

      create_page!(
        site_id: site.id,
        name: "Manual home",
        path: "/arrived-in-between",
        template: ~S(<div>mine</div>)
      )

      report = PageProvision.create(plan, &write!/1)

      assert created(report) == rest
      assert [%{path: ^first_path, fields: [name: "manual-home"]}] = report.skipped
    end

    # AN IDENTITY THE PLAN CANNOT ASK ABOUT AT ALL. `unique_preview_token` is keyed on a value the
    # create mints, so nothing can be looked for — and a page refused by it is still a page the site
    # cannot be given, not a run that should stop.
    test "is left alone on an identity nothing could have been looked up by", %{site: site} do
      holder = create_page!(site_id: site.id, path: "/holds-a-token", template: ~S(<div>x</div>))

      report =
        site.id
        |> PageProvision.missing(definitions(site.id))
        |> PageProvision.create(fn attrs ->
          Page
          |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
          |> Ash.Changeset.force_change_attribute(:preview_token, holder.preview_token)
          |> Ash.create!()
        end)

      assert created(report) == []
      assert Enum.map(report.skipped, & &1.fields) == [[], [], []]

      assert PageProvision.note(hd(report.skipped)) ==
               "#{hd(paths(site.id))} — something the site already has holds it"
    end
  end

  describe "the mark a provisioned page carries" do
    @tag :stamp
    test "says which extension gave the site the page, and at what version", %{site: site} do
      site.id
      |> PageProvision.missing(definitions(site.id), stamp: {:mishka_blog, "3.0.1"})
      |> PageProvision.create(&write!/1)

      for page <- pages_of(site.id) do
        assert PageProvision.provisioned_by(page) == "mishka_blog"
        assert PageProvision.provisioned_version(page) == "3.0.1"
        assert PageProvision.ours?(page, :mishka_blog)
        refute PageProvision.ours?(page, :mishka_document)
      end
    end

    # WITHOUT IT A PAGE IS THE ADMIN'S. `nil` is not "not ours" — it is "nothing here says" — and an
    # installer that treated the two alike would claim a page somebody wrote by hand.
    test "is absent when the caller passed none, and that is not the same as another's", %{
      site: site
    } do
      run(site.id)

      page = hd(pages_of(site.id))

      assert PageProvision.provisioned_by(page) == nil
      assert PageProvision.provisioned_version(page) == nil
      refute PageProvision.ours?(page, :mishka_blog)
    end

    test "leaves whatever the definition already put in extra", %{site: site} do
      [first | _rest] = definitions(site.id)
      kept = Map.put(first, :extra, %{"theirs" => "kept"})

      site.id
      |> PageProvision.missing([kept], stamp: {:mishka_blog, "3.0.1"})
      |> PageProvision.create(&write!/1)

      page = hd(pages_of(site.id))

      assert page.extra["theirs"] == "kept"
      assert PageProvision.ours?(page, :mishka_blog)
    end

    # EVERY DEFINITION OR NONE — the option is read once, inside `missing/3`, so a caller cannot mark
    # the first page and leave the rest looking like somebody else's work.
    test "marks every page of a run, not the first", %{site: site} do
      site.id
      |> PageProvision.missing(definitions(site.id), stamp: :mishka_blog)
      |> PageProvision.create(&write!/1)

      marks = site.id |> pages_of() |> Enum.map(&PageProvision.provisioned_by/1)

      assert length(marks) == length(definitions(site.id))
      assert Enum.uniq(marks) == ["mishka_blog"]
    end

    test "a bare source marks the page with no version", %{site: site} do
      site.id
      |> PageProvision.missing(definitions(site.id), stamp: :mishka_blog)
      |> PageProvision.create(&write!/1)

      page = hd(pages_of(site.id))

      assert PageProvision.ours?(page, :mishka_blog)
      assert PageProvision.provisioned_version(page) == nil
    end
  end

  # What the routing row stores: `nil` answers every language the URL captures, a code only its own.
  describe "routing_language/1" do
    test "is none for a page that serves every language" do
      page = %{language: "en", extra: %{"serves_all_languages" => true}}

      assert PageProvision.routing_language(page) == nil
    end

    test "is the page's own for one written in a language" do
      assert PageProvision.routing_language(%{language: "fa", extra: %{}}) == "fa"
      assert PageProvision.routing_language(%{language: "fa", extra: nil}) == "fa"
    end

    test "is none for a record with no language, as a layout is" do
      assert PageProvision.routing_language(%{extra: %{}}) == nil
    end

    # A COMPILED PAGE'S `extra` has its keys atomized wherever the atom exists, and it is that
    # `extra` `MishkaCmsWeb.RuntimeLive` hands `PageEditions` to decide the languages it offers.
    test "is none for a compiled page whose mark is keyed by an atom" do
      page = %{language: "en", extra: %{serves_all_languages: true}}

      assert PageProvision.routing_language(page) == nil
    end
  end

  defp pages_of(site_id) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(authorize?: false, page: [limit: 100])
    |> Map.fetch!(:results)
  end
end
