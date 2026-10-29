# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.LayoutTest do
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  import MishkaCmsCore.Test.VersionHelpers
  alias MishkaCmsCore.Runtime.Layout
  require Ash.Query
  @moduletag :unit

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its layouts" do
      site = create_site!()
      create_layout!(site_id: site.id)

      count = fn ->
        Layout |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false) |> length()
      end

      assert count.() == 1
      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
      assert count.() == 0
    end
  end

  describe "configuration" do
    test "resource has correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(Layout) == "layouts"
      assert AshPostgres.DataLayer.Info.repo(Layout) == @repo
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(Layout)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(Layout) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(Layout) == :site_id
      assert Ash.Resource.Info.multitenancy_global?(Layout) == true
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)

      layouts =
        Layout
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped layout in layouts

      archived_layout = Ash.destroy!(layout, authorize?: false)

      layouts =
        Layout
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived_layout not in layouts
    end
  end

  describe "create action" do
    test "creates a site-specific layout with valid attributes" do
      site = create_site!()

      attrs = [
        name: "Main Layout",
        path: "/blog/*",
        template: "<html><body><%= @content %></body></html>"
      ]

      assert {:ok, layout} =
               Layout
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.Changeset.load([:layout_module, :site, :is_global])
               |> Ash.create(authorize?: false)

      assert layout.name == "main-layout"
      assert layout.path == "/blog/*"
      assert layout.template == "<html><body><%= @content %></body></html>"
      assert layout.is_global == false
      assert layout.site_id == site.id
      assert layout.layout_module != nil
      assert to_string(layout.layout_module) =~ ~r/Layout$/
    end

    test "creates a global layout with master_create" do
      attrs = [
        name: "Global Layout",
        path: "/global",
        template: "<html><head><title>Global</title></head><body><%= @content %></body></html>"
      ]

      assert {:ok, layout} =
               Layout
               |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
               |> Ash.Changeset.load([:layout_module, :site, :is_global])
               |> Ash.create(authorize?: false)

      assert layout.name == "global-layout"
      assert layout.is_global == true
      assert layout.site_id == nil
      assert layout.site == nil
      assert to_string(layout.layout_module) =~ ~r/Layout$/
    end

    test "validates required fields" do
      site = create_site!()

      changeset =
        Layout
        |> Ash.Changeset.for_create(:create, %{}, tenant: site.id)

      # A TEMPLATE IS NO LONGER AMONG THEM — see the test below. Name and path still are.
      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          :name in error.fields and :path in error.fields
      end)
    end

    test "validates name length constraints" do
      site = create_site!()

      changeset =
        Layout
        |> Ash.Changeset.for_create(:create, %{name: "ab", path: "/test", template: "test"},
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      long_name = String.duplicate("a", 201)

      changeset =
        Layout
        |> Ash.Changeset.for_create(:create, %{name: long_name, path: "/test", template: "test"},
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end

    test "validates path format - must start with '/'" do
      site = create_site!()

      changeset =
        Layout
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Layout",
            path: "invalid-path",
            template: "test"
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :path and
          error.message =~ "Path must start with '/'"
      end)

      changeset =
        Layout
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Layout",
            path: "/valid-path",
            template: "test"
          },
          tenant: site.id
        )

      assert changeset.valid?
    end

    test "validates path format - rejects traversal, empty segments, and unsafe characters" do
      site = create_site!()

      reject = fn path, fragment ->
        changeset =
          Layout
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Bad Path", path: path, template: "test"},
            tenant: site.id
          )

        assert_has_error(changeset, fn error ->
          error.field == :path and error.message =~ fragment
        end)
      end

      reject.("/a/../b", "must not contain '..'")
      reject.("/a//b", "must not contain '//'")
      reject.("/a b", "may only contain")
      reject.("/a<script>", "may only contain")

      for path <- ["/", "/about", "/blog/posts", "/blog/:id", "/files/*rest", "/a-b_c.d.html"] do
        changeset =
          Layout
          |> Ash.Changeset.for_create(
            :create,
            %{name: "OK Path", path: path, template: "test"},
            tenant: site.id
          )

        refute Enum.any?(changeset.errors, &(Map.get(&1, :field) == :path)),
               "expected #{path} to pass path validation, got: #{inspect(changeset.errors)}"
      end
    end

    # A BLANK TEMPLATE IS NOW A REQUEST, NOT AN ERROR — the same one a page and a component already
    # answered. It is what lets the visual editor open a layout that nobody has written HEEx for yet;
    # `Changes.BlankTemplateStartsEmpty` fills it with the empty starter container, and the column's
    # NOT NULL and length check are untouched.
    test "an empty template means an empty layout, not a rejected one" do
      site = create_site!()

      assert {:ok, layout} =
               Layout
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Test Layout", path: "/test", template: "   "},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.create()

      assert layout.template == MishkaCmsCore.Runtime.Authoring.PageStarter.blank(:layout)

      assert layout.template =~ "@inner_content",
             "a layout that renders no page is broken, not empty"
    end

    test "validates format constraints" do
      site = create_site!()

      changeset =
        Layout
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test",
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
          Layout
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test #{format}",
              path: "/test-#{format}",
              template: "test",
              format: format
            },
            tenant: site.id
          )

        assert changeset.valid?
      end
    end

    test "validates resource_links structure" do
      site = create_site!()

      valid_resource_links = [
        %{
          type: "stylesheet",
          href: "/assets/css/app.css",
          rel: "stylesheet"
        },
        %{
          type: "script",
          href: "/assets/js/app.js",
          integrity: "sha384-test",
          crossorigin: "anonymous"
        }
      ]

      layout = create_layout!(site_id: site.id, resource_links: valid_resource_links)
      assert length(layout.resource_links) == 2
    end

    test "validates seo_tags structure" do
      site = create_site!()

      valid_seo_tags = [
        %{
          tag: "meta",
          attrs: %{name: "description"},
          content: "Test description"
        },
        %{
          tag: "meta",
          attrs: %{property: "og:title"},
          content: "Test Title"
        }
      ]

      layout = create_layout!(site_id: site.id, seo_tags: valid_seo_tags)
      assert length(layout.seo_tags) == 2
    end

    test "enforces unique name constraint for global layouts" do
      create_layout!(name: "Unique Global Layout", path: "/unique-global", site_id: nil)

      assert_raise Ash.Error.Invalid, fn ->
        create_layout!(name: "Unique Global Layout", path: "/unique-global-2", site_id: nil)
      end
    end

    test "enforces unique path constraint for global layouts" do
      create_layout!(name: "Global Layout 1", path: "/unique-path", site_id: nil)

      assert_raise Ash.Error.Invalid, fn ->
        create_layout!(name: "Global Layout 2", path: "/unique-path", site_id: nil)
      end
    end

    test "enforces unique name per site constraint" do
      site = create_site!()
      create_layout!(name: "Unique Layout", path: "/test1", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_layout!(name: "Unique Layout", path: "/test2", site_id: site.id)
      end
    end

    test "enforces unique path per site constraint" do
      site = create_site!()
      create_layout!(name: "Layout 1", path: "/unique-path", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_layout!(name: "Layout 2", path: "/unique-path", site_id: site.id)
      end
    end

    test "allows same name across different sites" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      layout1 = create_layout!(name: "Main Layout", path: "/main1", site_id: site1.id)
      layout2 = create_layout!(name: "Main Layout", path: "/main2", site_id: site2.id)

      assert layout1.name == layout2.name
      assert layout1.site_id != layout2.site_id
    end

    test "allows same path across different sites" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      layout1 = create_layout!(name: "Layout 1", path: "/blog/*", site_id: site1.id)
      layout2 = create_layout!(name: "Layout 2", path: "/blog/*", site_id: site2.id)

      assert layout1.path == layout2.path
      assert layout1.site_id != layout2.site_id
    end

    test "allows same name across global and site layouts" do
      site = create_site!()

      global_layout = create_layout!(name: "Same Name", path: "/global", site_id: nil)
      site_layout = create_layout!(name: "Same Name", path: "/site", site_id: site.id)

      assert global_layout.name == site_layout.name
      assert global_layout.site_id == nil
      assert site_layout.site_id == site.id
    end

    test "Extra :: allows same name for global and site-specific layouts" do
      site = create_site!()

      # Create a global layout
      global_layout = create_layout!(name: "Test Layout", path: "/global", site_id: nil)

      # Create a site-specific layout with the same name
      site_layout = create_layout!(name: "Test Layout", path: "/site", site_id: site.id)

      # Load the calculations
      global_layout = Ash.get!(Layout, global_layout.id, load: [:is_global], authorize?: false)

      site_layout =
        Ash.get!(Layout, site_layout.id, load: [:is_global], tenant: site.id, authorize?: false)

      # Both should be created successfully
      assert global_layout.name == "test-layout"
      assert global_layout.site_id == nil
      assert global_layout.is_global == true

      assert site_layout.name == "test-layout"
      assert site_layout.site_id == site.id
      assert site_layout.is_global == false

      # They should be different records
      assert global_layout.id != site_layout.id
    end
  end

  describe "update action" do
    test "updates a non-archived layout successfully" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)

      assert {:ok, updated} =
               layout
               |> Ash.Changeset.for_update(:update, %{name: "Updated Name"}, tenant: site.id)
               |> Ash.update(authorize?: false)

      assert updated.name == "updated-name"
    end

    test "prevents updating archived layouts" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)
      {:ok, archived} = Ash.destroy(layout, authorize?: false, return_destroyed?: true)

      changeset =
        archived
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          error.fields == [:archived_at]
      end)
    end

    test "validates path format on update" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)

      changeset =
        layout
        |> Ash.Changeset.for_update(:update, %{path: "invalid-path"}, tenant: site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :path and
          error.message =~ "Path must start with '/'"
      end)
    end

    test "layout module name stays consistent when updating attributes" do
      site = create_site!(name: "Test Site")
      layout = create_layout!(site_id: site.id)

      layout =
        Ash.get!(Layout, layout.id, load: [:layout_module], tenant: site.id, authorize?: false)

      original_module = to_string(layout.layout_module)

      {:ok, updated} =
        layout
        |> Ash.Changeset.for_update(:update, %{name: "New Name"}, tenant: site.id)
        |> Ash.Changeset.load([:layout_module])
        |> Ash.update(authorize?: false)

      assert to_string(updated.layout_module) == original_module
    end
  end

  describe "read actions with multitenancy" do
    setup do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      global1 =
        create_layout!(
          name: "Global Header Layout",
          path: "/global/header",
          site_id: nil,
          priority: 10
        )

      global2 =
        create_layout!(
          name: "Global Footer Layout",
          path: "/global/footer",
          site_id: nil,
          priority: 5
        )

      site1_layout =
        create_layout!(name: "Site 1 Layout", path: "/site1/*", site_id: site1.id, priority: 20)

      site2_layout =
        create_layout!(name: "Site 2 Layout", path: "/site2/*", site_id: site2.id, priority: 15)

      {:ok,
       site1: site1,
       site2: site2,
       global1: global1,
       global2: global2,
       site1_layout: site1_layout,
       site2_layout: site2_layout}
    end

    test "default read with tenant shows only site-specific layouts", context do
      layouts =
        Layout
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.read!(authorize?: false)

      layout_ids = Enum.map(layouts, & &1.id)

      assert context.site1_layout.id in layout_ids
      refute context.site2_layout.id in layout_ids
      # This is the correct behavior - global layouts are NOT included
      refute context.global1.id in layout_ids
      refute context.global2.id in layout_ids
    end

    test "read without tenant shows only global layouts", context do
      layouts =
        Layout
        |> Ash.Query.filter(is_nil(site_id))
        |> Ash.read!(authorize?: false)

      layout_ids = Enum.map(layouts, & &1.id)

      assert context.global1.id in layout_ids
      assert context.global2.id in layout_ids
      refute context.site1_layout.id in layout_ids
      refute context.site2_layout.id in layout_ids
    end

    test "by_path finds layout by exact path", context do
      layouts =
        Layout
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:by_path, %{path: "/site1/*"})
        |> Ash.read!(authorize?: false)

      assert length(layouts) == 1
      assert List.first(layouts).id == context.site1_layout.id
    end
  end

  describe "archive/unarchive actions" do
    test "destroy archives a layout (sets archived_at)" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)

      assert {:ok, archived} = Ash.destroy(layout, authorize?: false, return_destroyed?: true)
      assert archived.archived_at != nil

      layouts = Layout |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      layout_ids = Enum.map(layouts, & &1.id)
      refute archived.id in layout_ids

      archived_layouts = Ash.read!(Layout, action: :archived, authorize?: false)
      archived_ids = Enum.map(archived_layouts.results, & &1.id)
      assert archived.id in archived_ids
    end

    test "unarchive restores a layout" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)
      {:ok, _archived} = Ash.destroy(layout, authorize?: false, return_destroyed?: true)

      query =
        Layout
        |> Ash.Query.filter(id: layout.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(query.results)

      {:ok, unarchived} = Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
      assert unarchived.archived_at == nil

      layouts = Layout |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      layout_ids = Enum.map(layouts, & &1.id)
      assert unarchived.id in layout_ids
    end

    test "permanent_destroy actually deletes the record" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)
      layout_id = layout.id

      _result = Ash.destroy(layout, action: :permanent_destroy, authorize?: false)

      active = Layout |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      archived = Ash.read!(Layout, action: :archived, authorize?: false)

      active_ids = Enum.map(active, & &1.id)
      archived_ids = Enum.map(archived.results, & &1.id)

      refute layout_id in active_ids
      refute layout_id in archived_ids
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)
      binary_id = Ecto.UUID.dump!(layout.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE layouts SET name = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger prevents archived updates" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)
      {:ok, archived} = Ash.destroy(layout, authorize?: false, return_destroyed?: true)
      binary_id = Ecto.UUID.dump!(archived.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE layouts SET name = 'Should Fail' WHERE id = $1",
          [binary_id]
        )
      end
    end
  end

  describe "attribute defaults" do
    test "sets default values correctly" do
      site = create_site!()
      layout = create_layout!(site_id: site.id)

      assert layout.format == :heex
      assert layout.priority == 0
      assert layout.extra == %{}
      assert layout.content == %{}
      assert layout.resource_links == []
      assert layout.seo_tags == []
      assert layout.helpers == []
      assert layout.permissions == []
      assert layout.inserted_at != nil
      assert layout.updated_at != nil
    end
  end

  describe "complex scenarios" do
    test "handles layout with full resource_links and seo_tags" do
      site = create_site!()

      resource_links = [
        %{
          type: "stylesheet",
          href: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css",
          rel: "stylesheet",
          integrity: "sha384-test",
          crossorigin: "anonymous"
        },
        %{
          type: "script",
          href: "/assets/js/app.js",
          attrs: %{defer: true}
        }
      ]

      seo_tags = [
        %{
          tag: "meta",
          attrs: %{name: "description"},
          content: "A complex layout with many features"
        },
        %{
          tag: "meta",
          attrs: %{property: "og:title"},
          content: "Complex Layout"
        },
        %{
          tag: "script",
          attrs: %{type: "application/ld+json"},
          content: ~s({"@context": "https://schema.org"})
        }
      ]

      layout =
        create_layout!(
          site_id: site.id,
          resource_links: resource_links,
          seo_tags: seo_tags,
          description: "A complex layout with many features",
          permissions: ["admin", "editor"],
          content: %{
            "sections" => ["header", "main", "footer"],
            "sidebar" => true
          }
        )

      assert length(layout.resource_links) == 2
      assert length(layout.seo_tags) == 3
      assert layout.permissions == ["admin", "editor"]
      assert layout.content["sections"] == ["header", "main", "footer"]
      assert layout.content["sidebar"] == true
    end

    test "allows same name for archived and active layouts within same site" do
      site = create_site!()

      layout1 = create_layout!(name: "Reusable", path: "/reusable1", site_id: site.id)
      {:ok, _archived} = Ash.destroy(layout1, authorize?: false, return_destroyed?: true)

      layout2 = create_layout!(name: "Reusable", path: "/reusable2", site_id: site.id)
      assert layout2.name == "reusable"
    end

    test "allows same path for archived and active layouts within same site" do
      site = create_site!()

      layout1 = create_layout!(name: "Layout 1", path: "/reusable", site_id: site.id)
      {:ok, _archived} = Ash.destroy(layout1, authorize?: false, return_destroyed?: true)

      layout2 = create_layout!(name: "Layout 2", path: "/reusable", site_id: site.id)
      assert layout2.path == "/reusable"
    end

    test "prevents unarchiving when active layout with same name exists" do
      site = create_site!()

      layout1 = create_layout!(name: "Conflict", path: "/conflict1", site_id: site.id)
      {:ok, _archived} = Ash.destroy(layout1, authorize?: false, return_destroyed?: true)

      _layout2 = create_layout!(name: "Conflict", path: "/conflict2", site_id: site.id)

      query =
        Layout
        |> Ash.Query.filter(id: layout1.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(query.results)

      assert {:error, _error} =
               Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
    end

    test "prevents unarchiving when active layout with same path exists" do
      site = create_site!()

      layout1 = create_layout!(name: "Layout 1", path: "/conflict", site_id: site.id)
      {:ok, _archived} = Ash.destroy(layout1, authorize?: false, return_destroyed?: true)

      _layout2 = create_layout!(name: "Layout 2", path: "/conflict", site_id: site.id)

      query =
        Layout
        |> Ash.Query.filter(id: layout1.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(query.results)

      assert {:error, _error} =
               Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
    end
  end

  describe "for_tenant_with_globals and get_for_tenant_with_globals with site_id argument" do
    test "master user can filter by specific site_id" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")
      # A MASTER IS A USER WHOSE `site_id` IS NIL — not a query with no actor in it.
      master = create_user_with_permissions!(["*"])

      # Create layouts for different sites
      global_layout = create_layout!(name: "Global Layout", path: "/global/*", site_id: nil)
      site1_layout = create_layout!(name: "Site1 Layout", path: "/site1/*", site_id: site1.id)
      site2_layout = create_layout!(name: "Site2 Layout", path: "/site2/*", site_id: site2.id)

      # Test for_tenant_with_globals with site_id for master user (no tenant)
      results =
        Layout
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: site1.id}, actor: master)
        |> Ash.read!(authorize?: false)

      layout_ids = Enum.map(results.results, & &1.id)

      # Should see site1 layouts and global layouts only
      assert global_layout.id in layout_ids
      assert site1_layout.id in layout_ids
      refute site2_layout.id in layout_ids

      # Test get_for_tenant_with_globals with site_id for master user
      result =
        Layout
        |> Ash.Query.for_read(:get_for_tenant_with_globals, %{site_id: site1.id}, actor: master)
        |> Ash.Query.filter(id == ^site1_layout.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == site1_layout.id
    end

    test "tenant user ignores site_id argument and uses their tenant" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      # Create layouts for different sites
      global_layout = create_layout!(name: "Global Layout", path: "/global/*", site_id: nil)
      site1_layout = create_layout!(name: "Site1 Layout", path: "/site1/*", site_id: site1.id)
      site2_layout = create_layout!(name: "Site2 Layout", path: "/site2/*", site_id: site2.id)

      # Test for_tenant_with_globals with site_id for tenant user (site1)
      # Even though we pass site2.id, it should be ignored and use site1
      results =
        Layout
        |> Ash.Query.set_tenant(site1.id)
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: site2.id})
        |> Ash.read!(authorize?: false)

      layout_ids = Enum.map(results.results, & &1.id)

      # Should see site1 layouts and global layouts (ignoring site_id argument)
      assert global_layout.id in layout_ids
      assert site1_layout.id in layout_ids
      refute site2_layout.id in layout_ids
    end

    test "master user without site_id sees all layouts" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")
      # A MASTER IS A USER WHOSE `site_id` IS NIL — not a query with no actor in it.
      master = create_user_with_permissions!(["*"])

      # Create layouts for different sites
      global_layout = create_layout!(name: "Global Layout", path: "/global/*", site_id: nil)
      site1_layout = create_layout!(name: "Site1 Layout", path: "/site1/*", site_id: site1.id)
      site2_layout = create_layout!(name: "Site2 Layout", path: "/site2/*", site_id: site2.id)

      # Test for_tenant_with_globals without site_id for master user
      results =
        Layout
        |> Ash.Query.for_read(:for_tenant_with_globals, %{}, actor: master)
        |> Ash.read!(authorize?: false)

      layout_ids = Enum.map(results.results, & &1.id)

      # Should see all layouts
      assert global_layout.id in layout_ids
      assert site1_layout.id in layout_ids
      assert site2_layout.id in layout_ids
    end
  end

  describe "restore_version action" do
    test "master user can restore any layout version" do
      site = create_site!()

      # Create layouts
      global_layout =
        create_layout!(
          name: "Global Layout",
          path: "/global/*",
          template: "<div>Global V1</div>",
          site_id: nil
        )

      tenant_layout =
        create_layout!(
          name: "Tenant Layout",
          path: "/tenant/*",
          template: "<div>Tenant V1</div>",
          site_id: site.id
        )

      # Update layouts to create versions
      # Global layout needs master_update (changeset pattern)
      {:ok, _} =
        global_layout
        |> Ash.Changeset.for_update(:master_update, %{template: "<div>Global V2</div>"},
          authorize?: false
        )
        |> Ash.update(authorize?: false)

      tenant_layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>Tenant V2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get first version - wait for versions to be created
      # Sort by version_inserted_at to get the oldest version (which contains V1 state)
      global_version = first_version(MishkaCmsCore.Runtime.Layout.Version, global_layout.id)

      tenant_version =
        first_version(MishkaCmsCore.Runtime.Layout.Version, tenant_layout.id, tenant: site.id)

      assert global_version != nil
      assert tenant_version != nil

      # Master user (no tenant) can restore global layout using master_restore_version
      {:ok, restored_global} =
        Layout
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: global_layout.id,
            version_id: global_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      fresh_global = Ash.get!(Layout, restored_global.id, authorize?: false)
      assert fresh_global.template == "<div>Global V1</div>"

      # Master user can restore tenant layout using master_restore_version
      {:ok, restored_tenant} =
        Layout
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: tenant_layout.id,
            version_id: tenant_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      fresh_tenant = Ash.get!(Layout, restored_tenant.id, authorize?: false, tenant: site.id)
      assert fresh_tenant.template == "<div>Tenant V1</div>"
    end

    test "tenant user can restore their own tenant's layout" do
      site = create_site!()

      tenant_layout =
        create_layout!(
          name: "Tenant Layout",
          path: "/tenant/*",
          template: "<div>Original</div>",
          site_id: site.id
        )

      # Update to create version
      tenant_layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>Updated</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Wait for versions to be created (1 create + 1 update = 2 versions)
      wait_for_version_count("layout_versions", tenant_layout.id, 2)

      # Get the original (create) version - sort by inserted_at asc to get the first one
      version =
        first_version(MishkaCmsCore.Runtime.Layout.Version, tenant_layout.id, tenant: site.id)

      # Tenant can restore their own layout
      tenant_user = create_user_with_permissions!(["*"], site_id: site.id)
      tenant_layout_fresh = Ash.get!(Layout, tenant_layout.id, authorize?: false, tenant: site.id)

      {:ok, restored} =
        tenant_layout_fresh
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
          tenant: site.id,
          actor: tenant_user
        )
        |> Ash.update(actor: tenant_user)

      assert restored.template == "<div>Original</div>"
    end

    test "tenant user cannot restore global layout" do
      site = create_site!()

      global_layout =
        create_layout!(
          name: "Global Layout",
          path: "/global/*",
          template: "<div>Global V1</div>",
          site_id: nil
        )

      # Update to create version using master_update (changeset pattern)
      {:ok, _} =
        global_layout
        |> Ash.Changeset.for_update(:master_update, %{template: "<div>Global V2</div>"},
          authorize?: false
        )
        |> Ash.update(authorize?: false)

      # Get version
      version = first_version(MishkaCmsCore.Runtime.Layout.Version, global_layout.id)

      # Tenant cannot restore global layout - restore_version requires tenant and layout must belong to tenant
      global_layout_fresh = Ash.get!(Layout, global_layout.id, authorize?: false)

      changeset =
        global_layout_fresh
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id}, tenant: site.id)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(changeset, authorize?: false)
    end

    test "tenant user cannot access other tenant's layout to restore" do
      site1 = create_site!()
      site2 = create_site!()

      other_layout =
        create_layout!(
          name: "Other Layout",
          path: "/other/*",
          template: "<div>Other V1</div>",
          site_id: site2.id
        )

      # Update to create version
      other_layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>Other V2</div>"}, tenant: site2.id)
      |> Ash.update!(authorize?: false)

      # Tenant from site1 cannot even get site2's layout
      # When using tenant context, they can't see other tenant's layouts
      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(Layout, other_layout.id, authorize?: false, tenant: site1.id)
      end
    end

    test "cannot restore version of archived layout" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test/*",
          template: "<div>V1</div>",
          site_id: site.id
        )

      # Update to create version
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get version
      version = first_version(MishkaCmsCore.Runtime.Layout.Version, layout.id, tenant: site.id)

      # Archive the layout
      Ash.destroy!(layout, authorize?: false, tenant: site.id)

      # Get the archived layout
      archived_layout =
        Ash.get!(Layout, layout.id, action: :get_archived, authorize?: false, tenant: site.id)

      # Try to restore version of archived layout
      assert {:error, %Ash.Error.Invalid{}} =
               archived_layout
               |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
                 tenant: site.id
               )
               |> Ash.update(authorize?: false)
    end

    test "restored layout has correct attributes from version" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test/*",
          template: "<div>Original</div>",
          description: "Original description",
          priority: 10,
          site_id: site.id
        )

      # Update multiple times
      layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Version 2</div>",
          description: "Version 2 description",
          priority: 20
        },
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Version 3</div>",
          description: "Version 3 description",
          priority: 30
        },
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      # Get first version (original)
      version = first_version(MishkaCmsCore.Runtime.Layout.Version, layout.id, tenant: site.id)

      # Restore to first version
      layout_fresh = Ash.get!(Layout, layout.id, authorize?: false, tenant: site.id)

      {:ok, restored} =
        layout_fresh
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update(authorize?: false)

      assert restored.template == "<div>Original</div>"
      assert restored.description == "Original description"
      assert restored.priority == 10
    end
  end

  describe "preview_version action (generic action)" do
    test "master_preview_version can preview any layout version" do
      site = create_site!()

      # Create tenant layout
      tenant_layout =
        create_layout!(
          name: "Tenant Preview Read",
          path: "/tenant-read/*",
          template: "<div>Tenant Read V1</div>",
          description: "Tenant V1",
          priority: 20,
          site_id: site.id
        )

      # Update to create version
      tenant_layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Tenant Read V2</div>",
          description: "Tenant V2",
          priority: 25
        },
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      # Get version ID
      tenant_version =
        first_version(MishkaCmsCore.Runtime.Layout.Version, tenant_layout.id, tenant: site.id)

      # Master user can preview using master_preview_version (generic action)
      {:ok, preview} =
        Layout
        |> Ash.ActionInput.for_action(
          :master_preview_version,
          %{
            layout_id: tenant_layout.id,
            version_id: tenant_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert preview.id == tenant_layout.id
      assert preview.template == "<div>Tenant Read V1</div>"
      assert preview.description == "Tenant V1"
      assert preview.priority == 20
    end

    test "tenant user can preview their own tenant's layout version" do
      site = create_site!()

      tenant_layout =
        create_layout!(
          name: "Tenant Preview Own",
          path: "/tenant-own/*",
          template: "<div>Own V1</div>",
          description: "Own V1",
          priority: 30,
          site_id: site.id
        )

      # Update to create version
      tenant_layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Own V2</div>",
          description: "Own V2",
          priority: 35
        },
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      # Get the original (create) version deterministically
      version =
        first_version(MishkaCmsCore.Runtime.Layout.Version, tenant_layout.id, tenant: site.id)

      # Tenant can preview their own layout version using preview_version generic action
      {:ok, preview} =
        Layout
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            layout_id: tenant_layout.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert preview.id == tenant_layout.id
      assert preview.template == "<div>Own V1</div>"
      assert preview.description == "Own V1"
      assert preview.priority == 30
    end

    test "tenant user CAN preview global layout version (read-only access)" do
      site = create_site!()

      global_layout =
        create_layout!(
          name: "Global No Access",
          path: "/global-no/*",
          template: "<div>Global No V1</div>",
          description: "No Access V1",
          site_id: nil
        )

      # Update to create version using master_update (changeset pattern)
      {:ok, _} =
        global_layout
        |> Ash.Changeset.for_update(
          :master_update,
          %{
            template: "<div>Global No V2</div>",
            description: "No Access V2"
          },
          authorize?: false
        )
        |> Ash.update(authorize?: false)

      # Get version
      # Get the original (create) version deterministically
      version = first_version(MishkaCmsCore.Runtime.Layout.Version, global_layout.id)

      # Tenants CAN preview global layout versions (read-only access to global layouts)
      {:ok, preview} =
        Layout
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            layout_id: global_layout.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      # The preview should show the first version (before update)
      assert preview.id == global_layout.id
      assert preview.template == "<div>Global No V1</div>"
    end

    test "tenant user cannot preview other tenant's layout version" do
      site1 = create_site!()
      site2 = create_site!()

      other_layout =
        create_layout!(
          name: "Other Tenant Layout",
          path: "/other-tenant/*",
          template: "<div>Other V1</div>",
          description: "Other V1",
          site_id: site2.id
        )

      # Update to create version
      other_layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Other V2</div>",
          description: "Other V2"
        },
        tenant: site2.id
      )
      |> Ash.update!(authorize?: false)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.Layout.Version, other_layout.id, tenant: site2.id)

      # Tenant from site1 cannot preview site2's layout version - returns not found error
      result =
        Layout
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            layout_id: other_layout.id,
            version_id: version.id
          },
          tenant: site1.id
        )
        |> Ash.run_action(authorize?: false)

      # Error is wrapped in Ash.Error.Invalid
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} = result
    end

    test "preview_version returns correct version data" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Version Test Layout",
          path: "/version-test/*",
          template: "<div>Original</div>",
          description: "Original description",
          priority: 10,
          extra: %{"key1" => "value1"},
          site_id: site.id
        )

      # Create multiple versions
      layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Version 2</div>",
          description: "Version 2 description",
          priority: 20,
          extra: %{"key2" => "value2"}
        },
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      layout
      |> Ash.Changeset.for_update(
        :update,
        %{
          template: "<div>Version 3</div>",
          description: "Version 3 description",
          priority: 30,
          extra: %{"key3" => "value3"}
        },
        tenant: site.id
      )
      |> Ash.update!(authorize?: false)

      # Get first version (original)
      versions = versions(MishkaCmsCore.Runtime.Layout.Version, layout.id, tenant: site.id)

      first_version = List.first(versions)

      # Preview first version using generic action
      {:ok, preview} =
        Layout
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            layout_id: layout.id,
            version_id: first_version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      # Verify preview data matches first version
      assert preview.template == "<div>Original</div>"
      assert preview.description == "Original description"
      assert preview.priority == 10
      assert preview.extra == %{"key1" => "value1"}

      # Verify current layout still has latest data
      current_layout = Ash.get!(Layout, layout.id, authorize?: false, tenant: site.id)
      assert current_layout.template == "<div>Version 3</div>"
      assert current_layout.description == "Version 3 description"
      assert current_layout.priority == 30
    end
  end

  describe "master read actions" do
    test "master_read returns all layouts system-wide" do
      site1 = create_site!(name: "Site 1", host: "site1.example.com")
      site2 = create_site!(name: "Site 2", host: "site2.example.com")

      global_layout = create_layout!(name: "Global Layout", path: "/global", site_id: nil)
      site1_layout = create_layout!(name: "Site1 Layout", path: "/site1", site_id: site1.id)
      site2_layout = create_layout!(name: "Site2 Layout", path: "/site2", site_id: site2.id)

      # master_read should return all layouts
      %{results: layouts} = Ash.read!(Layout, action: :master_read, authorize?: false)

      layout_ids = Enum.map(layouts, & &1.id)
      assert global_layout.id in layout_ids
      assert site1_layout.id in layout_ids
      assert site2_layout.id in layout_ids
    end

    test "master_get returns any layout by id" do
      site = create_site!()
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)

      # master_get should return the layout without tenant context
      result = Ash.get!(Layout, layout.id, action: :master_get, authorize?: false)
      assert result.id == layout.id
    end

    test "get_any returns any layout by id" do
      site = create_site!()
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)

      # get_any should return the layout
      result = Ash.get!(Layout, layout.id, action: :get_any, authorize?: false)
      assert result.id == layout.id
    end

    test "master_archived returns all archived layouts system-wide" do
      site1 = create_site!(name: "Site 1", host: "site1.example.com")
      site2 = create_site!(name: "Site 2", host: "site2.example.com")

      layout1 = create_layout!(name: "Layout 1", path: "/layout1", site_id: site1.id)
      layout2 = create_layout!(name: "Layout 2", path: "/layout2", site_id: site2.id)

      # Archive both layouts
      Ash.destroy!(layout1, authorize?: false, tenant: site1.id)
      Ash.destroy!(layout2, authorize?: false, tenant: site2.id)

      # master_archived should return all archived layouts
      %{results: archived} = Ash.read!(Layout, action: :master_archived, authorize?: false)

      archived_ids = Enum.map(archived, & &1.id)
      assert layout1.id in archived_ids
      assert layout2.id in archived_ids
    end

    test "master_get_archived returns specific archived layout" do
      site = create_site!()
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)

      # Archive the layout
      Ash.destroy!(layout, authorize?: false, tenant: site.id)

      # master_get_archived should return the archived layout
      result = Ash.get!(Layout, layout.id, action: :master_get_archived, authorize?: false)
      assert result.id == layout.id
      assert result.archived_at != nil
    end

    test "read_any returns all layouts for admin" do
      site = create_site!()
      global_layout = create_layout!(name: "Global Layout", path: "/global", site_id: nil)
      site_layout = create_layout!(name: "Site Layout", path: "/site", site_id: site.id)

      # read_any is not paginated, returns a plain list
      layouts = Ash.read!(Layout, action: :read_any, authorize?: false)

      # Handle both paginated and non-paginated results
      layout_list =
        case layouts do
          %{results: results} -> results
          list when is_list(list) -> list
        end

      layout_ids = Enum.map(layout_list, & &1.id)
      assert global_layout.id in layout_ids
      assert site_layout.id in layout_ids
    end
  end

  describe "master update/unarchive actions" do
    test "master_update can update any layout" do
      site = create_site!()

      # Test updating site-specific layout
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)

      updated =
        layout
        |> Ash.Changeset.for_update(
          :master_update,
          %{
            name: "Updated Name",
            description: "New description"
          },
          authorize?: false
        )
        |> Ash.update!()

      assert updated.name == "updated-name"
      assert updated.description == "New description"

      # Test updating global layout
      global_layout = create_layout!(name: "Global Layout", path: "/global", site_id: nil)

      updated_global =
        global_layout
        |> Ash.Changeset.for_update(:master_update, %{name: "Updated Global"}, authorize?: false)
        |> Ash.update!()

      assert updated_global.name == "updated-global"
    end

    test "master_unarchive can unarchive any layout" do
      site = create_site!()
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)

      # Archive the layout
      Ash.destroy!(layout, authorize?: false, tenant: site.id)

      # Get the archived record using master_get_archived
      archived_layout =
        Ash.get!(Layout, layout.id, action: :master_get_archived, authorize?: false)

      # Use master_unarchive to restore it (changeset pattern)
      {:ok, restored} =
        archived_layout
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update()

      assert restored.archived_at == nil
    end
  end

  describe "master destroy actions (generic actions)" do
    test "master_destroy archives any layout" do
      site = create_site!()
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)

      # Use master_destroy to archive (changeset pattern)
      {:ok, archived} =
        layout
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      assert archived.archived_at != nil

      # Verify it's not in active list
      layouts = Layout |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      layout_ids = Enum.map(layouts, & &1.id)
      refute layout.id in layout_ids
    end

    test "master_permanent_destroy permanently deletes any layout" do
      site = create_site!()
      layout = create_layout!(name: "Test Layout", path: "/test", site_id: site.id)
      layout_id = layout.id

      # Use master_permanent_destroy to delete (changeset pattern)
      layout
      |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Verify it's gone completely
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Layout, layout_id, action: :master_get, authorize?: false)
    end
  end

  describe "version list actions" do
    test "list_versions returns all versions for a layout" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test",
          template: "<div>V1</div>",
          site_id: site.id
        )

      # Create versions by updating
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>V3</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # list_versions requires tenant context, pass layout_id as argument
      %{results: results} =
        Layout
        |> Ash.Query.for_read(:list_versions, %{layout_id: layout.id}, tenant: site.id)
        |> Ash.read!(authorize?: false)

      # list_versions returns layouts with sorted_versions loaded
      assert length(results) == 1
      layout_with_versions = List.first(results)
      assert length(layout_with_versions.sorted_versions) >= 2
    end

    test "master_list_versions returns all versions for any layout" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test",
          template: "<div>V1</div>",
          site_id: site.id
        )

      # Create version by updating
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # master_list_versions bypasses tenant, returns layouts with sorted_versions
      %{results: results} =
        Layout
        |> Ash.Query.for_read(:master_list_versions, %{layout_id: layout.id}, authorize?: false)
        |> Ash.read!(authorize?: false)

      assert length(results) == 1
      layout_with_versions = List.first(results)
      assert length(layout_with_versions.sorted_versions) >= 1
    end

    test "get_with_versions returns layout with paginated versions" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test",
          template: "<div>V1</div>",
          site_id: site.id
        )

      # Create version
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get layout with versions - it's a get? action, so filter by id
      result =
        Layout
        |> Ash.Query.filter(id == ^layout.id)
        |> Ash.Query.for_read(:get_with_versions, %{}, tenant: site.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == layout.id
      assert length(result.sorted_versions) >= 1
    end

    test "master_get_with_versions returns layout with paginated versions" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test",
          template: "<div>V1</div>",
          site_id: site.id
        )

      # Create version
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get layout with versions using master action - filter by id
      result =
        Layout
        |> Ash.Query.filter(id == ^layout.id)
        |> Ash.Query.for_read(:master_get_with_versions, %{}, authorize?: false)
        |> Ash.read_one!(authorize?: false)

      assert result.id == layout.id
      assert length(result.sorted_versions) >= 1
    end
  end

  describe "restore_version_api action" do
    test "restore_version_api restores layout to specific version (tenant action)" do
      site = create_site!()

      layout =
        create_layout!(
          name: "Test Layout",
          path: "/test",
          template: "<div>Original</div>",
          site_id: site.id
        )

      # Create version
      layout
      |> Ash.Changeset.for_update(:update, %{template: "<div>Updated</div>"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get version
      version = first_version(MishkaCmsCore.Runtime.Layout.Version, layout.id, tenant: site.id)

      # Restore using restore_version_api (generic action for tenant)
      {:ok, restored} =
        Layout
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{
            id: layout.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.template == "<div>Original</div>"
    end
  end
end
