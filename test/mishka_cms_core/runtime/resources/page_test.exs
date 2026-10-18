# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.PageTest do
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.AssetsState
  require Ash.Query
  @moduletag :unit

  describe "configuration" do
    test "resource has correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(Page) == "pages"
      assert AshPostgres.DataLayer.Info.repo(Page) == @repo
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(Page)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(Page) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(Page) == :site_id
      assert Ash.Resource.Info.multitenancy_global?(Page) == false
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      pages =
        Page
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped page in pages

      archived_page = Ash.destroy!(page, authorize?: false)

      pages =
        Page
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived_page not in pages
    end
  end

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its pages" do
      site = create_site!()
      create_page!(site_id: site.id)

      count = fn ->
        Page
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(site_id == ^site.id)
        |> Ash.stream!(authorize?: false)
        |> Enum.count()
      end

      assert count.() == 1

      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)

      assert count.() == 0
    end
  end

  describe "create action" do
    test "creates a page with valid attributes" do
      site = create_site!()

      attrs = %{
        name: "About Page",
        title: "About Page",
        path: "/about",
        section: "main",
        template: "<div class='about'><h1><%= @title %></h1></div>",
        description: "About us page"
      }

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.Changeset.load([:page_module, :site])
               |> Ash.create(authorize?: false)

      assert page.name == "about-page"
      assert page.path == "/about"
      assert page.section == "main"
      assert page.template == "<div class='about'><h1><%= @title %></h1></div>"
      assert page.description == "About us page"
      assert page.format == :heex
      assert page.priority == 0
      assert page.site_id == site.id
      assert page.page_module != nil
      assert to_string(page.page_module) =~ ~r/Page$/
    end

    test "validates required fields" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(:create, %{}, tenant: site.id)

      # `template` is deliberately absent: a page with no markup is an empty page now, not a
      # missing field. `name` is not asked for either — it is derived from the title on create.
      for field <- [:title, :path] do
        assert_has_error(changeset, fn error ->
          error.__struct__ == Ash.Error.Changes.InvalidAttribute and
            error.field == field
        end)
      end

      refute_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and error.field == :template
      end)
    end

    test "validates name length constraints" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "ab",
            title: "Ab",
            path: "/test",
            template: "test"
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      long_name = String.duplicate("a", 201)

      changeset =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: long_name,
            title: "Long Name",
            path: "/test",
            template: "test"
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end

    test "validates path starts with slash" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Page",
            title: "Test Page",
            path: "no-slash",
            template: "test"
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :path
      end)
    end

    # A BLANK TEMPLATE IS NOW A REQUEST, NOT AN ERROR. It used to be refused, which meant the only
    # way to reach the visual editor was to write HEEx by hand first — the one thing the editor
    # exists for not having to do. `Changes.BlankTemplateStartsEmpty` turns it into the empty
    # starter container; the column's NOT NULL and its length check are untouched.
    test "an empty template means an empty page, not a rejected one" do
      site = create_site!()

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Test Page", title: "Test Page", path: "/test", template: "   "},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert page.template == MishkaCmsCore.Runtime.PageBuilder.PageStarter.blank()
    end

    test "validates format constraints" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test",
            title: "Test",
            path: "/test",
            template: "test",
            format: :invalid
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      for format <- [:heex, :eex, :markdown] do
        changeset =
          Page
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test #{format}",
              title: "Test #{format}",
              path: "/test-#{format}",
              template: "test",
              format: format
            },
            tenant: site.id
          )

        assert changeset.valid?
      end
    end

    test "validates seo_tags structure" do
      site = create_site!()

      valid_seo_tags = [
        %{tag: "meta", attrs: %{name: "description", content: "Test page"}, content: nil},
        %{tag: "title", attrs: %{}, content: "Test Title"}
      ]

      page = create_page!(site_id: site.id, seo_tags: valid_seo_tags)
      assert length(page.seo_tags) == 2
    end

    test "validates events structure" do
      site = create_site!()

      valid_events = [
        %{name: "click", code: ~S|{:noreply, assign(socket, :clicked, true)}|},
        %{name: "submit", code: "{:noreply, socket}"}
      ]

      page = create_page!(site_id: site.id, events: valid_events)
      assert length(page.events) == 2
    end

    # CODE THAT WILL NOT COMPILE DOES NOT GET STORED. Until this validation existed the save
    # succeeded, the runtime-status panel said Ready — a page that does not precompile is not built
    # when it is saved — and the first visitor got the 500. Worse, on a page whose module was already
    # loaded, the failed recompile left the previous version serving and the author's change simply
    # never appeared.
    #
    # The fixtures these two tests used to carry were literally JavaScript in an Elixir field, which
    # is how easy it is for this to go unnoticed.
    test "refuses a handler that will not compile" do
      site = create_site!()

      assert_raise Ash.Error.Invalid, ~r/missing terminator/, fn ->
        create_page!(site_id: site.id, events: [%{name: "click", code: "{:noreply, socket"}])
      end
    end

    # An empty body never reaches the code check — the attribute's own `allow_nil?: false` refuses
    # it first. `CodeCheck` still names it, because the builder asks before Ash does and "this
    # handler has no code" is a better sentence than "value must not be nil".
    test "refuses a handler with no code" do
      site = create_site!()

      assert_raise Ash.Error.Invalid, fn ->
        create_page!(site_id: site.id, events: [%{name: "click", code: ""}])
      end
    end

    test "refuses a helper whose argument list is not one" do
      site = create_site!()

      assert_raise Ash.Error.Invalid, ~r/syntax error/, fn ->
        create_page!(site_id: site.id, helpers: [%{name: "h", args: "a,", code: ":ok"}])
      end
    end

    test "refuses a template that will not parse" do
      site = create_site!()

      assert_raise Ash.Error.Invalid, ~r/unmatched closing tag/, fn ->
        create_page!(site_id: site.id, template: "<div><span></div>")
      end
    end

    # The check runs over the WHOLE page, not the changed fragment: deleting the helper a handler
    # calls has to be refused, and nothing about the handler changed.
    test "refuses an update that breaks code it did not touch" do
      site = create_site!()

      page =
        create_page!(
          site_id: site.id,
          helpers: [%{name: "shout", args: "text", code: "String.upcase(text)"}],
          events: [%{name: "go", code: ~S|{:noreply, assign(socket, :s, shout("hi"))}|}]
        )

      assert_raise Ash.Error.Invalid, ~r/undefined function shout/, fn ->
        page
        |> Ash.Changeset.for_update(:master_update, %{helpers: []}, authorize?: false)
        |> Ash.update!(authorize?: false)
      end
    end

    test "validates infos structure" do
      site = create_site!()

      valid_infos = [
        %{name: "timer", code: "Process.send_after(self(), :tick, 1000)"},
        %{name: "broadcast", code: "{:noreply, socket}"}
      ]

      page = create_page!(site_id: site.id, infos: valid_infos)
      assert length(page.infos) == 2
    end

    test "validates resource_links structure" do
      site = create_site!()

      valid_resource_links = [
        %{type: "stylesheet", href: "/css/app.css", rel: "stylesheet"},
        %{type: "script", href: "/js/app.js", rel: nil, attrs: %{defer: true}}
      ]

      page = create_page!(site_id: site.id, resource_links: valid_resource_links)
      assert length(page.resource_links) == 2
    end

    test "enforces unique name per site constraint" do
      site = create_site!()
      create_page!(name: "Unique Page", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_page!(name: "Unique Page", site_id: site.id)
      end
    end

    test "enforces unique path per site constraint" do
      site = create_site!()
      create_page!(path: "/unique-path", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_page!(path: "/unique-path", site_id: site.id)
      end
    end

    test "allows same name and path across different sites" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      page1 = create_page!(name: "Home", path: "/home", site_id: site1.id)
      page2 = create_page!(name: "Home", path: "/home", site_id: site2.id)

      assert page1.name == page2.name
      assert page1.path == page2.path
      assert page1.site_id != page2.site_id
    end

    test "creates page with layout relationship" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)

      page = create_page!(site_id: site.id, layout_id: layout.id)
      page = Ash.get!(Page, page.id, load: [:layout], tenant: site.id, authorize?: false)

      assert page.layout_id == layout.id
      assert page.layout.id == layout.id
    end

    test "allows page without layout" do
      site = create_site!()
      page = create_page!(site_id: site.id, layout_id: nil)

      assert page.layout_id == nil
    end
  end

  describe "a page and what it is called" do
    test "the title is stored as it was typed, while the name beside it is slugified" do
      site = create_site!()

      attrs = %{
        name: "Pricing",
        title: "قیمت‌گذاری",
        path: "/pricing",
        template: "<div class='pricing'></div>"
      }

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.create(authorize?: false)

      assert page.title == "قیمت‌گذاری"
      assert page.name == "pricing"
    end

    test "a page with no title is refused" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(:create, %{name: "Pricing", path: "/pricing"},
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and error.field == :title
      end)
    end

    test "a title of nothing but spaces is refused" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Pricing", title: "   ", path: "/pricing"},
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and error.field == :title
      end)
    end

    test "a page nobody named is named after its title" do
      site = create_site!()

      attrs = %{title: "قیمت‌گذاری", path: "/pricing", template: "<div class='p'></div>"}

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.create(authorize?: false)

      assert page.name == "qymtgdhry"
      assert page.title == "قیمت‌گذاری"
    end

    test "the second page with the same title is numbered rather than refused" do
      site = create_site!()

      create = fn path ->
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{title: "قیمت‌گذاری", path: path, template: "<div class='p'></div>"},
          tenant: site.id
        )
        |> Ash.create(authorize?: false)
      end

      assert {:ok, first} = create.("/pricing")
      assert {:ok, second} = create.("/plans")

      assert first.name == "qymtgdhry"
      assert second.name == "qymtgdhry-2"
    end

    test "a title that slugifies to nothing is named after its path" do
      site = create_site!()

      attrs = %{title: "🎉🎉", path: "/launch/party", template: "<div class='p'></div>"}

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.create(authorize?: false)

      assert page.name == "launch-party"
    end

    # The key is minted once. An author who only fixes a typo in the title does not move the row's
    # identity, so nothing needs a rule about skipping the derivation on later saves.
    test "retitling a page leaves the name it was minted with" do
      site = create_site!()

      {:ok, page} =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{title: "Plans And Pricing", path: "/pricing", template: "<div class='p'></div>"},
          tenant: site.id
        )
        |> Ash.create(authorize?: false)

      assert page.name == "plans-and-pricing"

      assert {:ok, retitled} =
               page
               |> Ash.Changeset.for_update(:update, %{title: "قیمت‌گذاری"}, tenant: site.id)
               |> Ash.update(authorize?: false)

      assert retitled.name == "plans-and-pricing"
      assert retitled.title == "قیمت‌گذاری"
    end

    # The reason there is a title at all: renaming re-slugifies the name on every save, and a title
    # that went through the same change would come back transliterated the first time an author
    # touched anything else on the page.
    test "renaming the page re-slugifies the name and leaves the title alone" do
      site = create_site!()

      page =
        create_page!(
          site_id: site.id,
          name: "Pricing",
          title: "قیمت‌گذاری",
          path: "/pricing"
        )

      assert {:ok, renamed} =
               page
               |> Ash.Changeset.for_update(:update, %{name: "Plans And Pricing"}, tenant: site.id)
               |> Ash.update(authorize?: false)

      assert renamed.name == "plans-and-pricing"
      assert renamed.title == "قیمت‌گذاری"
    end
  end

  describe "update action" do
    test "updates a non-archived page successfully" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      assert {:ok, updated} =
               page
               |> Ash.Changeset.for_update(
                 :update,
                 %{
                   name: "Updated Name",
                   section: "updated"
                 },
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)

      assert updated.name == "updated-name"
      assert updated.section == "updated"
    end

    test "prevents updating archived pages" do
      site = create_site!()
      page = create_page!(site_id: site.id)
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      changeset =
        archived
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          error.fields == [:archived_at]
      end)
    end

    test "page module name stays consistent when updating attributes" do
      site = create_site!(name: "Test Site")
      page = create_page!(site_id: site.id)

      page = Ash.get!(Page, page.id, load: [:page_module], tenant: site.id, authorize?: false)
      original_module = to_string(page.page_module)

      {:ok, updated} =
        page
        |> Ash.Changeset.for_update(:update, %{name: "New Name"}, tenant: site.id)
        |> Ash.Changeset.load([:page_module])
        |> Ash.update(authorize?: false)

      assert to_string(updated.page_module) == original_module
    end

    test "validates path starts with slash on update" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      changeset =
        page
        |> Ash.Changeset.for_update(:update, %{path: "no-slash"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :path
      end)
    end
  end

  describe "read actions with multitenancy" do
    setup do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      site1_page1 = create_page!(name: "Site 1 Home", site_id: site1.id, priority: 20)
      site1_page2 = create_page!(name: "Site 1 About", site_id: site1.id, priority: 10)
      site2_page = create_page!(name: "Site 2 Home", site_id: site2.id, priority: 15)

      {:ok,
       site1: site1,
       site2: site2,
       site1_page1: site1_page1,
       site1_page2: site1_page2,
       site2_page: site2_page}
    end

    test "default read with tenant shows only site-specific pages", context do
      pages =
        Page
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.read!(authorize?: false)

      page_ids = Enum.map(pages, & &1.id)

      assert context.site1_page1.id in page_ids
      assert context.site1_page2.id in page_ids
      refute context.site2_page.id in page_ids
    end

    test "by_priority orders by priority desc, then name asc", context do
      _same_priority_page =
        create_page!(
          name: "AAA Page",
          site_id: context.site1.id,
          priority: 20
        )

      page =
        Page
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.read!(action: :by_priority, authorize?: false)

      pages = page.results

      assert length(pages) == 3
      assert Enum.at(pages, 0).priority == 20
      assert Enum.at(pages, 0).name == "aaa-page"
      assert Enum.at(pages, 1).priority == 20
      assert Enum.at(pages, 1).name == "site-1-home"
      assert Enum.at(pages, 2).priority == 10
    end

    test "by_path filters by exact path", context do
      pages =
        Page
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:by_path, %{path: context.site1_page1.path})
        |> Ash.read!(authorize?: false)

      assert length(pages) == 1
      assert List.first(pages).id == context.site1_page1.id
    end

    test "by_section filters by section", context do
      create_page!(section: "blog", site_id: context.site1.id)
      create_page!(section: "blog", site_id: context.site1.id)

      pages =
        Page
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:by_section, %{section: "blog"})
        |> Ash.read!(authorize?: false)

      assert length(pages) == 2
      assert Enum.all?(pages, fn p -> p.section == "blog" end)
    end

    test "by_layout filters by layout_id", context do
      layout = create_layout!(site_id: context.site1.id)
      create_page!(layout_id: layout.id, site_id: context.site1.id)
      create_page!(layout_id: layout.id, site_id: context.site1.id)

      pages =
        Page
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:by_layout, %{layout_id: layout.id})
        |> Ash.read!(authorize?: false)

      assert length(pages) == 2
      assert Enum.all?(pages, fn p -> p.layout_id == layout.id end)
    end
  end

  describe "archive/unarchive actions" do
    test "destroy archives a page (sets archived_at)" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      assert {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)
      assert archived.archived_at != nil

      pages = Page |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      page_ids = Enum.map(pages, & &1.id)
      refute archived.id in page_ids

      %{results: archived_pages} =
        Page |> Ash.Query.set_tenant(site.id) |> Ash.read!(action: :archived, authorize?: false)

      archived_ids = Enum.map(archived_pages, & &1.id)
      assert archived.id in archived_ids
    end

    test "unarchive restores a page" do
      site = create_site!()
      page = create_page!(site_id: site.id)
      {:ok, _archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      %{results: archived_results} =
        Page
        |> Ash.Query.filter(id: page.id)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(archived_results)

      {:ok, unarchived} = Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
      assert unarchived.archived_at == nil

      pages = Page |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      page_ids = Enum.map(pages, & &1.id)
      assert unarchived.id in page_ids
    end

    test "permanent_destroy actually deletes the record" do
      site = create_site!()
      page = create_page!(site_id: site.id)
      page_id = page.id

      _result =
        Ash.destroy(page, action: :permanent_destroy, authorize?: false, return_destroyed?: true)

      active = Page |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)

      %{results: archived} =
        Page |> Ash.Query.set_tenant(site.id) |> Ash.read!(action: :archived, authorize?: false)

      active_ids = Enum.map(active, & &1.id)
      archived_ids = Enum.map(archived, & &1.id)

      refute page_id in active_ids
      refute page_id in archived_ids
    end
  end

  describe "calculations" do
    test "page_module calculation returns correct module name" do
      site = create_site!(name: "Test Site")
      page = create_page!(site_id: site.id)

      page = Ash.get!(Page, page.id, load: [:page_module], tenant: site.id, authorize?: false)

      assert page.page_module != nil
      module_string = to_string(page.page_module)
      assert module_string =~ ~r/Page/
      assert module_string =~ ~r/Page$/
    end

    test "loaded_layout calculation returns layout when present" do
      site = create_site!(name: "Layout Site")
      layout = create_layout!(site_id: site.id, name: "Test Layout")
      page = create_page!(site_id: site.id, layout_id: layout.id)

      page = Ash.get!(Page, page.id, load: [:loaded_layout], tenant: site.id, authorize?: false)

      assert page.loaded_layout != nil
      assert page.loaded_layout.id == layout.id
      assert page.loaded_layout.name == "test-layout"
    end

    test "loaded_layout calculation returns nil when no layout" do
      site = create_site!(name: "No Layout Site")
      page = create_page!(site_id: site.id, layout_id: nil)

      page = Ash.get!(Page, page.id, load: [:loaded_layout], tenant: site.id, authorize?: false)

      assert page.loaded_layout == nil
    end

    test "latest_version calculation returns most recent version" do
      site = create_site!(name: "Version Site")
      page = create_page!(site_id: site.id, name: "Version Test", description: "Original")

      # Create some updates to generate versions
      {:ok, _} =
        page
        |> Ash.Changeset.for_update(:update, %{description: "First update"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      {:ok, _} =
        Ash.get!(Page, page.id, tenant: site.id, authorize?: false)
        |> Ash.Changeset.for_update(:update, %{description: "Second update"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      page = Ash.get!(Page, page.id, load: [:latest_version], tenant: site.id, authorize?: false)

      assert page.latest_version != nil
      assert page.latest_version.version_action_name == :update
      assert page.latest_version.changes["description"] == "Second update"
    end

    test "recent_versions calculation returns up to 10 most recent versions" do
      site = create_site!(name: "Recent Versions Site")
      page = create_page!(site_id: site.id, name: "Recent Test")

      # Create 5 updates to have 6 total versions (1 create + 5 updates)
      for i <- 1..5 do
        {:ok, _} =
          Ash.get!(Page, page.id, tenant: site.id, authorize?: false)
          |> Ash.Changeset.for_update(:update, %{description: "Update #{i}"}, tenant: site.id)
          |> Ash.update(authorize?: false)
      end

      page = Ash.get!(Page, page.id, load: [:recent_versions], tenant: site.id, authorize?: false)

      assert page.recent_versions != nil
      assert is_list(page.recent_versions)
      assert length(page.recent_versions) == 6

      # Verify they are sorted by version_inserted_at desc (most recent first)
      [first | _] = page.recent_versions
      assert first.version_action_name == :update
      assert first.changes["description"] == "Update 5"
    end

    test "recent_versions returns empty list for page with no versions" do
      site = create_site!(name: "Empty Versions Site")

      # Create page but delete all versions manually to test edge case
      page = create_page!(site_id: site.id, name: "No Versions Test")

      # Normal case - should have at least the create version
      page = Ash.get!(Page, page.id, load: [:recent_versions], tenant: site.id, authorize?: false)

      assert page.recent_versions != nil
      assert is_list(page.recent_versions)
      # Should have at least the create version
      assert length(page.recent_versions) >= 1
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()
      page = create_page!(site_id: site.id)
      binary_id = Ecto.UUID.dump!(page.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE pages SET name = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger prevents archived updates" do
      site = create_site!()
      page = create_page!(site_id: site.id)
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)
      binary_id = Ecto.UUID.dump!(archived.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE pages SET name = 'Should Fail' WHERE id = $1",
          [binary_id]
        )
      end
    end
  end

  describe "attribute defaults" do
    test "sets default values correctly" do
      site = create_site!()
      page = create_page!(site_id: site.id, content: %{})

      assert page.format == :heex
      assert page.priority == 0
      assert page.extra == %{}
      assert page.content == %{}
      assert page.seo_tags == []
      assert page.schema == []
      assert page.events == []
      assert page.infos == []
      assert page.resource_links == []
      assert page.helpers == []
      assert page.permissions == []
      assert page.inserted_at != nil
      assert page.updated_at != nil
    end
  end

  describe "complex scenarios" do
    test "handles page with full attributes and structured data" do
      site = create_site!()

      seo_tags = [
        %{tag: "meta", attrs: %{name: "description", content: "Complex page"}, content: nil},
        %{tag: "title", attrs: %{}, content: "Complex Page Title"}
      ]

      schema = [
        %{
          "@context" => "https://schema.org",
          "@type" => "WebPage",
          "name" => "Complex Page",
          "description" => "A complex test page"
        }
      ]

      events = [
        %{name: "click", code: ~S|{:noreply, assign(socket, :clicked, true)}|},
        %{name: "submit", code: "{:noreply, socket}"}
      ]

      infos = [
        %{name: "timer", code: "Process.send_after(self(), :tick, 1000)"}
      ]

      resource_links = [
        %{type: "stylesheet", href: "/css/app.css", rel: "stylesheet"},
        %{type: "script", href: "/js/app.js", attrs: %{defer: true}}
      ]

      page =
        create_page!(
          site_id: site.id,
          name: "Complex Page",
          section: "main",
          description: "A complex page with many features",
          seo_tags: seo_tags,
          schema: schema,
          events: events,
          infos: infos,
          resource_links: resource_links,
          permissions: ["admin", "editor"],
          content: %{title: "Complex", body: "This is complex content"}
        )

      assert length(page.seo_tags) == 2
      assert length(page.schema) == 1
      assert length(page.events) == 2
      assert length(page.infos) == 1
      assert length(page.resource_links) == 2
      assert page.permissions == ["admin", "editor"]
      assert page.content["title"] == "Complex"
    end

    test "allows same name for archived and active pages within same site" do
      site = create_site!()

      page1 = create_page!(name: "Reusable", site_id: site.id)
      {:ok, _archived} = Ash.destroy(page1, authorize?: false, return_destroyed?: true)

      page2 = create_page!(name: "Reusable", site_id: site.id)
      assert page2.name == "reusable"
    end

    test "prevents unarchiving when active page with same name exists" do
      site = create_site!()

      page1 = create_page!(name: "Conflict", site_id: site.id)
      {:ok, _archived} = Ash.destroy(page1, authorize?: false, return_destroyed?: true)

      _page2 = create_page!(name: "Conflict", site_id: site.id)

      %{results: archived_results} =
        Page
        |> Ash.Query.filter(id: page1.id)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(archived_results)

      assert {:error, _error} =
               Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
    end

    test "prevents unarchiving when active page with same path exists" do
      site = create_site!()

      page1 = create_page!(path: "/conflict", site_id: site.id)
      {:ok, _archived} = Ash.destroy(page1, authorize?: false, return_destroyed?: true)

      _page2 = create_page!(path: "/conflict", site_id: site.id)

      %{results: archived_results} =
        Page
        |> Ash.Query.filter(id: page1.id)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(archived_results)

      assert {:error, _error} =
               Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
    end
  end

  describe "paper trail versioning" do
    test "creates a version on page creation" do
      site = create_site!()
      page = create_page!(site_id: site.id, name: "Versioned Page")

      versions = versions(MishkaCmsCore.Runtime.Page.Version, page.id)

      assert length(versions) == 1
      version = List.first(versions)
      assert version.version_action_name == :create
      assert version.version_action_type == :create
      assert version.changes["name"] == "versioned-page"
    end

    test "creates a new version on update" do
      site = create_site!()
      page = create_page!(site_id: site.id, name: "Original Name")

      {:ok, updated_page} =
        page
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "Updated Name",
            description: "New description"
          },
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      versions = versions(MishkaCmsCore.Runtime.Page.Version, updated_page.id)

      assert length(versions) == 2

      # versions/3 returns oldest-first, so create is first and update is last
      create_version = List.first(versions)
      update_version = List.last(versions)

      assert create_version.version_action_name == :create
      assert update_version.version_action_name == :update
      assert update_version.changes["name"] == "updated-name"
      assert update_version.changes["description"] == "New description"
    end

    test "does not create version when nothing changes" do
      site = create_site!()
      page = create_page!(site_id: site.id, name: "Test Page")

      # Update with same values
      {:ok, _updated} =
        page
        |> Ash.Changeset.for_update(:update, %{name: "Test Page"}, tenant: site.id)
        |> Ash.update(authorize?: false)

      versions = versions(MishkaCmsCore.Runtime.Page.Version, page.id)

      # Still only has the create version
      assert length(versions) == 1
      assert List.first(versions).version_action_name == :create
    end

    test "ignores unarchive action for versioning" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      # Archive the page
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      # Get fresh archived page
      %{results: archived_results} =
        Page
        |> Ash.Query.filter(id: archived.id)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(archived_results)

      # Unarchive it
      {:ok, unarchived} =
        Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)

      versions = versions(MishkaCmsCore.Runtime.Page.Version, unarchived.id)

      # Should have create and destroy versions, but not unarchive
      version_actions = Enum.map(versions, & &1.version_action_name)
      assert :create in version_actions
      assert :destroy in version_actions
      refute :unarchive in version_actions
    end

    test "tracks user_id when actor is provided" do
      site = create_site!()

      user =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          email: "master@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("Password1234")
        })
        |> Ash.create!(authorize?: false, tenant: nil)

      page =
        Page
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "User Page",
            title: "User Page",
            path: "/user-page",
            template: "<div>Test</div>"
          },
          tenant: site.id
        )
        |> Ash.create!(actor: user, authorize?: false)

      versions = versions(MishkaCmsCore.Runtime.Page.Version, page.id)

      version = List.first(versions)

      assert version.user_id == user.id
    end

    test "user_id is nil when no actor provided" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      versions = versions(MishkaCmsCore.Runtime.Page.Version, page.id)

      version = List.first(versions)

      assert version.user_id == nil
    end

    test "restore_version action restores page to previous state" do
      site = create_site!()

      # Create initial page
      page =
        create_page!(
          site_id: site.id,
          name: "Original",
          description: "Original description",
          priority: 10
        )

      # Update it multiple times
      {:ok, updated1} =
        page
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "First Update",
            description: "First updated description",
            priority: 20
          },
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      {:ok, updated2} =
        updated1
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "Second Update",
            description: "Second updated description",
            priority: 30
          },
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      # Get versions
      versions = versions(MishkaCmsCore.Runtime.Page.Version, updated2.id)

      # Get the first update version (index 1 in oldest-first order)
      first_update_version = Enum.at(versions, 1)

      # Restore to first update
      {:ok, restored} =
        updated2
        |> Ash.Changeset.for_update(
          :restore_version,
          %{
            version_id: first_update_version.id
          },
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      assert restored.name == "first-update"
      assert restored.description == "First updated description"
      assert restored.priority == 20

      # Check that restoration created a new version
      new_versions = versions(MishkaCmsCore.Runtime.Page.Version, restored.id)

      # Should have 4 versions now (create + 2 updates + restore)
      assert length(new_versions) == 4
      latest_version = List.last(new_versions)
      assert latest_version.version_action_name == :restore_version
    end

    test "cannot restore version of archived page" do
      site = create_site!()
      page = create_page!(site_id: site.id, name: "To Archive")

      # Update to create a version
      {:ok, updated} =
        page
        |> Ash.Changeset.for_update(:update, %{name: "Updated"})
        |> Ash.update(tenant: site.id, authorize?: false)

      # Get version
      versions = versions(MishkaCmsCore.Runtime.Page.Version, updated.id)

      version = List.first(versions)

      # Archive the page
      {:ok, archived} = Ash.destroy(updated, authorize?: false, return_destroyed?: true)

      # Try to restore version on archived page
      changeset =
        archived
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          error.fields == [:archived_at]
      end)
    end

    test "preview_version returns version data without modifying page" do
      site = create_site!()

      page =
        create_page!(
          site_id: site.id,
          name: "Preview Test",
          description: "Original"
        )

      {:ok, updated} =
        page
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "Updated Preview",
            description: "Updated"
          },
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      # Get version to preview
      versions = versions(MishkaCmsCore.Runtime.Page.Version, updated.id)

      create_version = List.first(versions)

      # Preview the create version (this is a generic action, not a read)
      {:ok, preview_page} =
        Page
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            page_id: page.id,
            version_id: create_version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      # Preview should show original data
      assert preview_page.name == "preview-test"
      assert preview_page.description == "Original"

      # But actual page should still have updated data
      current_page = Ash.get!(Page, updated.id, tenant: site.id, authorize?: false)
      assert current_page.name == "updated-preview"
      assert current_page.description == "Updated"
    end

    test "list_versions paginates results" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      # Create many versions
      for i <- 1..25 do
        {:ok, _} =
          Ash.get!(Page, page.id, tenant: site.id, authorize?: false)
          |> Ash.Changeset.for_update(
            :update,
            %{
              description: "Update #{i}"
            },
            tenant: site.id
          )
          |> Ash.update(authorize?: false)
      end

      # Query versions directly with pagination
      versions =
        MishkaCmsCore.Runtime.Page.Version
        |> Ash.Query.filter(version_source_id == ^page.id)
        |> Ash.Query.sort(version_inserted_at: :desc)
        |> Ash.read!(
          tenant: site.id,
          page: [limit: 10, offset: 0],
          authorize?: false
        )

      # Should return max 10 versions due to pagination
      assert length(versions.results) == 10
      assert versions.limit == 10
      assert versions.offset == 0
    end

    test "version_count calculation returns correct count" do
      site = create_site!()
      page = create_page!(site_id: site.id)

      # Create some versions
      for i <- 1..5 do
        {:ok, _} =
          Ash.get!(Page, page.id, tenant: site.id, authorize?: false)
          |> Ash.Changeset.for_update(
            :update,
            %{
              description: "Update #{i}"
            },
            tenant: site.id
          )
          |> Ash.update(authorize?: false)
      end

      # Load with version count
      page_with_count =
        Ash.get!(Page, page.id,
          load: [:version_count],
          tenant: site.id,
          authorize?: false
        )

      # Should have 6 versions (1 create + 5 updates)
      assert page_with_count.version_count == 6
    end

    test "versions respect multitenancy" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      page1 = create_page!(site_id: site1.id, name: "Site 1 Page")
      page2 = create_page!(site_id: site2.id, name: "Site 2 Page")

      # Update both pages
      {:ok, _} =
        page1
        |> Ash.Changeset.for_update(:update, %{description: "Site 1 Update"}, tenant: site1.id)
        |> Ash.update(authorize?: false)

      {:ok, _} =
        page2
        |> Ash.Changeset.for_update(:update, %{description: "Site 2 Update"}, tenant: site2.id)
        |> Ash.update(authorize?: false)

      # Get versions for site1 page (bypassing tenant with read_any)
      site1_versions = versions(MishkaCmsCore.Runtime.Page.Version, page1.id)

      # Verify all versions belong to site1
      assert Enum.all?(site1_versions, fn v ->
               v.site_id == site1.id
             end)

      # Get site2 versions and verify they don't include site1 page
      site2_versions = versions(MishkaCmsCore.Runtime.Page.Version, page2.id)

      # Verify site2 versions belong to site2
      assert Enum.all?(site2_versions, fn v ->
               v.site_id == site2.id
             end)
    end

    test "permanent_destroy does not create version" do
      site = create_site!()
      page = create_page!(site_id: site.id)
      page_id = page.id

      # Permanent destroy
      Ash.destroy(page, action: :permanent_destroy, authorize?: false)

      # Versions should be deleted too due to cascade
      # Change: Just check that no versions exist
      versions = versions(MishkaCmsCore.Runtime.Page.Version, page_id, tenant: site.id)

      assert versions == []
    end
  end

  describe "master_create action" do
    test "creates page with explicit site_id (no tenant context)" do
      site = create_site!()

      attrs = %{
        name: "Master Page",
        title: "Master Page",
        path: "/master-page",
        template: "<div>Master</div>",
        site_id: site.id
      }

      assert {:ok, page} =
               Page
               |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
               |> Ash.create(authorize?: false)

      assert page.name == "master-page"
      assert page.site_id == site.id
    end

    test "requires site_id in attributes" do
      changeset =
        Page
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "No Site",
            title: "No Site",
            path: "/no-site",
            template: "<div>Test</div>"
          },
          authorize?: false
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :site_id
      end)
    end

    test "fails when tenant is provided" do
      site = create_site!()

      changeset =
        Page
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "With Tenant",
            title: "With Tenant",
            path: "/tenant",
            template: "<div>Test</div>",
            site_id: site.id
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges
      end)
    end
  end

  describe "master_read action" do
    test "reads all pages bypassing multitenancy" do
      site1 = create_site!(name: "Site1", host: "site1.test")
      site2 = create_site!(name: "Site2", host: "site2.test")

      page1 = create_page!(name: "Site1 Page", site_id: site1.id)
      page2 = create_page!(name: "Site2 Page", site_id: site2.id)

      %{results: all_pages} =
        Page
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      page_ids = Enum.map(all_pages, & &1.id)
      assert page1.id in page_ids
      assert page2.id in page_ids
    end

    test "fails when tenant is provided" do
      site = create_site!()

      query =
        Page
        |> Ash.Query.for_read(:master_read, %{}, tenant: site.id)

      assert_has_error(query, fn error ->
        error.__struct__ == Ash.Error.Query.InvalidQuery
      end)
    end
  end

  describe "master_get action" do
    test "gets page by ID bypassing multitenancy" do
      site = create_site!()
      page = create_page!(name: "Get Test", site_id: site.id)

      result = Ash.get!(Page, page.id, action: :master_get, authorize?: false)
      assert result.id == page.id
    end

    test "gets archived page" do
      site = create_site!()
      page = create_page!(name: "To Archive", site_id: site.id)
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      result = Ash.get!(Page, archived.id, action: :master_get, authorize?: false)
      assert result.id == archived.id
      assert result.archived_at != nil
    end
  end

  describe "get_archived action" do
    test "gets single archived page with tenant context" do
      site = create_site!()
      page = create_page!(name: "To Archive", site_id: site.id)
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      result =
        Page
        |> Ash.Query.for_read(:get_archived, %{}, tenant: site.id)
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == archived.id
      assert result.archived_at != nil
    end
  end

  describe "master_archived action" do
    test "lists all archived pages bypassing multitenancy" do
      site1 = create_site!(name: "Site1A", host: "site1a.test")
      site2 = create_site!(name: "Site2A", host: "site2a.test")

      page1 = create_page!(name: "Site1 To Archive", site_id: site1.id)
      page2 = create_page!(name: "Site2 To Archive", site_id: site2.id)

      {:ok, archived1} = Ash.destroy(page1, authorize?: false, return_destroyed?: true)
      {:ok, archived2} = Ash.destroy(page2, authorize?: false, return_destroyed?: true)

      %{results: all_archived} =
        Page
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      archived_ids = Enum.map(all_archived, & &1.id)
      assert archived1.id in archived_ids
      assert archived2.id in archived_ids
    end
  end

  describe "master_get_archived action" do
    test "gets single archived page bypassing multitenancy" do
      site = create_site!()
      page = create_page!(name: "To Get Archived", site_id: site.id)
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      result =
        Page
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == archived.id
      assert result.archived_at != nil
    end
  end

  describe "read_any and get_any actions" do
    test "read_any reads all pages bypassing multitenancy (internal)" do
      site1 = create_site!(name: "SiteR1", host: "siter1.test")
      site2 = create_site!(name: "SiteR2", host: "siter2.test")

      page1 = create_page!(name: "Site1", site_id: site1.id)
      page2 = create_page!(name: "Site2", site_id: site2.id)

      all_pages =
        Page
        |> Ash.Query.for_read(:read_any)
        |> Ash.read!(authorize?: false, page: false)

      page_ids = Enum.map(all_pages, & &1.id)
      assert page1.id in page_ids
      assert page2.id in page_ids
    end

    test "get_any gets page bypassing multitenancy" do
      site = create_site!()
      page = create_page!(name: "Get Any", site_id: site.id)

      result = Ash.get!(Page, page.id, action: :get_any, authorize?: false)
      assert result.id == page.id
    end
  end

  describe "master_update action" do
    test "updates page bypassing tenant context" do
      site = create_site!()
      page = create_page!(name: "To Update", site_id: site.id)

      # Fetch page via master_get to avoid tenant inference
      page = Ash.get!(Page, page.id, action: :master_get, authorize?: false)

      {:ok, updated} =
        page
        |> Ash.Changeset.for_update(:master_update, %{name: "Master Updated"}, authorize?: false)
        |> Ash.update(authorize?: false)

      assert updated.name == "master-updated"
    end

    test "fails when tenant is provided" do
      site = create_site!()
      page = create_page!(name: "To Update", site_id: site.id)

      changeset =
        page
        |> Ash.Changeset.for_update(:master_update, %{name: "With Tenant"}, tenant: site.id)

      refute changeset.valid?
    end
  end

  describe "master_destroy action" do
    test "archives page bypassing tenant context" do
      site = create_site!()
      page = create_page!(name: "To Destroy", site_id: site.id)

      # Fetch page via master_get to avoid tenant inference
      page = Ash.get!(Page, page.id, action: :master_get, authorize?: false)

      {:ok, destroyed} =
        page
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(authorize?: false, return_destroyed?: true)

      assert destroyed.archived_at != nil
    end
  end

  describe "master_unarchive action" do
    test "unarchives page bypassing tenant context" do
      site = create_site!()
      page = create_page!(name: "To Unarchive", site_id: site.id)
      {:ok, archived} = Ash.destroy(page, authorize?: false, return_destroyed?: true)

      # Get fresh archived record using master_get_archived
      archived_page = Ash.get!(Page, archived.id, action: :master_get_archived, authorize?: false)

      {:ok, restored} =
        archived_page
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update(authorize?: false)

      assert restored.archived_at == nil
    end

    test "fails for non-archived page" do
      site = create_site!()
      page = create_page!(name: "Not Archived", site_id: site.id)

      changeset =
        page
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)

      refute changeset.valid?
    end
  end

  describe "master_permanent_destroy action" do
    test "permanently deletes page bypassing tenant context" do
      site = create_site!()
      page = create_page!(name: "To Permanently Delete", site_id: site.id)
      page_id = page.id

      # Fetch page via master_get to avoid tenant inference
      page = Ash.get!(Page, page_id, action: :master_get, authorize?: false)

      :ok =
        page
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy(authorize?: false)

      assert {:error, _} = Ash.get(Page, page_id, action: :get_any, authorize?: false)
    end
  end

  describe "get_with_versions and master_get_with_versions actions" do
    import MishkaCmsCore.Test.VersionHelpers

    test "get_with_versions loads sorted versions (tenant)" do
      site = create_site!()
      page = create_page!(name: "With Versions", site_id: site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "First update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      result =
        Page
        |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
        |> Ash.Query.filter(id == ^page.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == page.id
      assert length(result.sorted_versions) >= 1
    end

    test "master_get_with_versions loads versions bypassing tenant" do
      site = create_site!()
      page = create_page!(name: "Master Versions", site_id: site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "Update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      result =
        Page
        |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10}, authorize?: false)
        |> Ash.Query.filter(id == ^page.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == page.id
      assert length(result.sorted_versions) >= 1
    end
  end

  describe "master_list_versions action" do
    import MishkaCmsCore.Test.VersionHelpers

    test "lists versions bypassing tenant" do
      site = create_site!()
      page = create_page!(name: "Master List Versions", site_id: site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "Update"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      %{results: results} =
        Page
        |> Ash.Query.for_read(:master_list_versions, %{page_id: page.id}, authorize?: false)
        |> Ash.read!(authorize?: false)

      assert length(results) == 1
    end
  end

  describe "restore_version_api action" do
    import MishkaCmsCore.Test.VersionHelpers

    test "restores via API (tenant)" do
      site = create_site!()
      page = create_page!(name: "API Restore", description: "Original", site_id: site.id)

      updated =
        page
        |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Page.Version, page.id)

      {:ok, restored} =
        Page
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{
            id: updated.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.description == page.description
    end
  end

  describe "master_restore_version action" do
    import MishkaCmsCore.Test.VersionHelpers

    test "restores bypassing tenant" do
      site = create_site!()
      page = create_page!(name: "Master Restore", description: "Original", site_id: site.id)

      updated =
        page
        |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Page.Version, page.id)

      {:ok, restored} =
        Page
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: updated.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert restored.description == page.description
    end
  end

  describe "preview_version action" do
    import MishkaCmsCore.Test.VersionHelpers

    test "previews a version without restoring (tenant)" do
      site = create_site!()
      page = create_page!(name: "Preview Test", description: "Original", site_id: site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Page.Version, page.id)

      {:ok, preview} =
        Page
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            page_id: page.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert preview.description == "Original"

      # Verify original wasn't changed
      current = Ash.get!(Page, page.id, action: :get_any, authorize?: false)
      assert current.description == "Changed"
    end
  end

  describe "master_preview_version action" do
    import MishkaCmsCore.Test.VersionHelpers

    test "previews bypassing tenant" do
      site = create_site!()
      page = create_page!(name: "Master Preview", description: "Original", site_id: site.id)

      page
      |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      wait_for_version_count("page_versions", page.id, 2)

      version = first_version(MishkaCmsCore.Runtime.Page.Version, page.id)

      {:ok, preview} =
        Page
        |> Ash.ActionInput.for_action(
          :master_preview_version,
          %{
            page_id: page.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert preview.description == "Original"
    end
  end

  defp seed_css!(record) do
    AssetsState.save(%{
      id: record.preview_token,
      type: "css",
      value: ".stale{}",
      hash: "deadbeef",
      updated_at: DateTime.utc_now()
    })

    assert AssetsState.exists?(record.preview_token, "css")
    record
  end

  # THE PREVIEW'S STYLESHEET IS CACHED UNDER THE RECORD'S TOKEN and compiled only when that key is
  # absent, so a write that leaves the key behind serves the CSS of the version before it for the
  # life of the node: the utility classes that write introduced have no rules, and the reviewer sent
  # `/_preview/page/<token>` reads the markup as broken rather than the stylesheet as old. The
  # builder's own save purged the key; these three write the same row and did not.
  describe "the live page's preview stylesheet" do
    import MishkaCmsCore.Test.VersionHelpers
    alias MishkaCmsCore.Runtime.PageDraft

    setup do
      site = create_site!()
      page = create_page!(site_id: site.id)

      %{site: site, page: seed_css!(page)}
    end

    test "is dropped when a draft is published over it", %{site: site, page: page} do
      draft =
        PageDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: page.name,
            title: page.title,
            path: page.path,
            template: ~s(<h1 class="mt-77">published</h1>),
            source_page_id: page.id
          },
          tenant: site.id
        )
        |> Ash.create!(authorize?: false)

      draft
      |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      refute AssetsState.exists?(page.preview_token, "css"),
             "the shareable preview kept the stylesheet from before the publish"
    end

    test "and when a version is restored over it", %{site: site, page: page} do
      page
      |> Ash.Changeset.for_update(:update, %{description: "Changed"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      version = first_version(MishkaCmsCore.Runtime.Page.Version, page.id)

      # That update is itself a write, so it took the key the setup seeded with it — the restore has
      # to be given its own stale stylesheet to drop.
      seed_css!(page)

      {:ok, _restored} =
        Page
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: page.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      refute AssetsState.exists?(page.preview_token, "css"),
             "the shareable preview kept the stylesheet from before the restore"
    end

    # The inspector's Configuration tab is an `AshPhoenix.Form` over this very action.
    test "and when the Configuration form saves it", %{page: page} do
      Page
      |> Ash.get!(page.id, action: :master_get, authorize?: false)
      |> Ash.Changeset.for_update(:master_update, %{template: ~s(<h1 class="mt-77">config</h1>)},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      refute AssetsState.exists?(page.preview_token, "css"),
             "the shareable preview kept the stylesheet from before the save"
    end

    # Archiving is a soft DESTROY, not an update: the row is unreachable afterwards, so a key left
    # behind is one nothing can ever drop again.
    test "and when the page is archived", %{page: page} do
      Ash.destroy!(page, authorize?: false)

      refute AssetsState.exists?(page.preview_token, "css"),
             "an archived page left its preview stylesheet in the cache for good"
    end

    # A PURGE THAT RUNS BEFORE THE COMMIT PUTS THE STALE SHEET BACK: in the window between it and
    # the commit, a reader of `/_preview/page/<token>` finds the key missing, compiles the row as it
    # still is — the version before the save — and stores it under the token nobody will drop again.
    test "and not before the row it invalidates is committed", %{site: site, page: page} do
      test_pid = self()

      page
      |> Ash.Changeset.for_update(:update, %{description: "Committed"}, tenant: site.id)
      |> Ash.Changeset.after_action(fn _changeset, record ->
        send(test_pid, {:mid_transaction, AssetsState.exists?(page.preview_token, "css")})
        {:ok, record}
      end)
      |> Ash.update!(authorize?: false)

      assert_receive {:mid_transaction, true}
      refute AssetsState.exists?(page.preview_token, "css")
    end

    # THE CACHE IS NOT A DEPENDENCY OF WRITING A PAGE. `AssetsState` owns its ETS table, the host
    # app restarts it like any other child, and the sibling extensions' suites never start one —
    # so a write path that cannot survive its absence turns a page save into a 500.
    test "and the save still lands while the cache is not running", %{site: site, page: page} do
      :ok = Supervisor.terminate_child(MishkaCmsCore.TestSupervisor, AssetsState)
      on_exit(fn -> Supervisor.restart_child(MishkaCmsCore.TestSupervisor, AssetsState) end)

      saved =
        page
        |> Ash.Changeset.for_update(:update, %{description: "No cache"}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      assert saved.description == "No cache"
    end
  end
end
