defmodule MishkaCmsCore.Runtime.Resources.ComponentTest do
  @moduledoc """
  Comprehensive tests for MishkaCmsCore.Runtime.Component resource.
  """
  use MishkaCmsCore.DataCase, async: false

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  require Ash.Query
  alias MishkaCmsCore.Runtime.Component

  @moduletag :unit

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its components" do
      site = create_site!()
      create_component!(site_id: site.id)

      count = fn ->
        Component |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false) |> length()
      end

      assert count.() == 1
      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
      assert count.() == 0
    end
  end

  describe "resource configuration" do
    test "uses correct table name" do
      assert AshPostgres.DataLayer.Info.table(Component) == "components"
    end

    test "uses correct repo" do
      assert AshPostgres.DataLayer.Info.repo(Component) == @repo
    end

    test "uses UUID for primary keys" do
      site = create_site!()
      component = create_component!(site_id: site.id)
      assert is_binary(component.id)
      assert String.length(component.id) == 36
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(Component)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(Component) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(Component) == :site_id
      assert Ash.Resource.Info.multitenancy_global?(Component) == true
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      components =
        Component
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      ids = Enum.map(components, & &1.id)
      assert component.id in ids

      Ash.destroy!(component, authorize?: false, tenant: site.id)

      components =
        Component
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      ids = Enum.map(components, & &1.id)
      refute component.id in ids
    end
  end

  describe "create action (tenant)" do
    test "creates site-specific component with valid attributes" do
      site = create_site!()

      component =
        create_component!(
          name: "Header Component",
          template: "<header><%= @title %></header>",
          description: "Main header",
          format: :heex,
          priority: 10,
          site_id: site.id
        )

      assert component.name == "header-component"
      assert component.template == "<header><%= @title %></header>"
      assert component.description == "Main header"
      assert component.format == :heex
      assert component.priority == 10
      assert component.site_id == site.id
    end

    test "auto-slugifies name" do
      site = create_site!()

      component =
        Component
        |> Ash.Changeset.for_create(
          :create,
          %{name: "My Test Component", template: "<div>test</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert component.name == "my-test-component"
    end

    test "requires name and template" do
      site = create_site!()

      assert_raise Ash.Error.Invalid, fn ->
        Component
        |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
        |> Ash.create!()
      end
    end

    test "auto-assigns site_id from tenant context" do
      site = create_site!()

      component =
        Component
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Tenant Component", template: "<div>test</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

      assert component.site_id == site.id
    end

    test "persists type, dependencies, and examples (UI-kit import fields)" do
      examples = [~S|<.component component_name="chelekom-x" site="Global" />|]

      component =
        Component
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "Typed Component",
            template: "<div>x</div>",
            site_id: nil,
            type: "general",
            dependencies: ["chelekom-icon", "collapsible.js"],
            examples: examples
          },
          authorize?: false
        )
        |> Ash.create!()

      assert component.type == "general"
      assert component.dependencies == ["chelekom-icon", "collapsible.js"]
      assert component.examples == examples

      # round-trips through Postgres
      reloaded = Ash.get!(Component, component.id, action: :master_get, authorize?: false)
      assert reloaded.type == "general"
      assert "chelekom-icon" in reloaded.dependencies
      assert "collapsible.js" in reloaded.dependencies
    end

    test "validates name length constraints" do
      site = create_site!()

      # Too short
      assert_raise Ash.Error.Invalid, fn ->
        Component
        |> Ash.Changeset.for_create(
          :create,
          %{name: "ab", template: "<div>test</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()
      end

      # Too long
      long_name = String.duplicate("a", 101)

      assert_raise Ash.Error.Invalid, fn ->
        Component
        |> Ash.Changeset.for_create(
          :create,
          %{name: long_name, template: "<div>test</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()
      end
    end

    test "validates format constraints" do
      site = create_site!()

      assert_raise Ash.Error.Invalid, fn ->
        Component
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Test", template: "<div>test</div>", format: :invalid},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()
      end

      # Valid formats
      for format <- [:heex, :eex, :markdown] do
        component =
          Component
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test #{format}", template: "<div>test</div>", format: format},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert component.format == format
      end
    end

    test "sets default values correctly" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      assert component.format == :heex
      assert component.priority == 0
      assert component.extra == %{}
      assert component.attrs == []
      assert component.slots == []
      assert component.helpers == []
      assert component.permissions == []
      assert component.active == true
      assert component.inserted_at != nil
      assert component.updated_at != nil
    end

    test "form_meta lifts the kit's own form declaration out of extra" do
      site = create_site!()

      declared = %{"role" => "field", "field" => "bind", "name" => "input_name"}

      create_component!(site_id: site.id, extra: %{"form" => declared, "furnishing" => %{}})

      assert [%{form_meta: ^declared}] =
               Component
               |> Ash.Query.set_tenant(site.id)
               |> Ash.Query.load(:form_meta)
               |> Ash.read!(authorize?: false)
    end

    test "and answers nothing for a component whose kit says nothing" do
      site = create_site!()
      create_component!(site_id: site.id)

      assert [%{form_meta: nil}] =
               Component
               |> Ash.Query.set_tenant(site.id)
               |> Ash.Query.load(:form_meta)
               |> Ash.read!(authorize?: false)
    end

    test "enforces unique name per site" do
      site = create_site!()
      create_component!(name: "Unique", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_component!(name: "Unique", site_id: site.id)
      end
    end

    test "allows same name across different sites" do
      site1 = create_site!()
      site2 = create_site!()

      component1 = create_component!(name: "Shared", site_id: site1.id)
      component2 = create_component!(name: "Shared", site_id: site2.id)

      assert component1.name == component2.name
      assert component1.id != component2.id
    end

    test "creates component with attrs and slots" do
      site = create_site!()

      attrs = [
        %{name: "title", type: "string", opts: %{required: true}},
        %{name: "count", type: "integer", opts: %{default: 0}}
      ]

      slots = [
        %{name: "header", opts: %{required: true}},
        %{name: "body", attrs: [%{name: "class", type: "string"}]}
      ]

      component = create_component!(site_id: site.id, attrs: attrs, slots: slots)

      assert length(component.attrs) == 2
      assert length(component.slots) == 2
    end

    test "creates component with examples" do
      site = create_site!()

      examples = [
        "<.button type=\"primary\">Click</.button>",
        "<.button disabled={true}>Disabled</.button>"
      ]

      component = create_component!(site_id: site.id, examples: examples)
      assert component.examples == examples
    end
  end

  describe "master_create action" do
    test "creates site-specific component with explicit site_id" do
      site = create_site!()

      component =
        Component
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "Master Component",
            template: "<div>master</div>",
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!()

      assert component.name == "master-component"
      assert component.site_id == site.id
    end

    test "creates global component with nil site_id" do
      component =
        Component
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "Global Component",
            template: "<div>global</div>",
            site_id: nil
          },
          authorize?: false
        )
        |> Ash.create!()

      assert component.name == "global-component"
      assert component.site_id == nil
    end

    test "slugifies name" do
      component =
        Component
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "My Global Component",
            template: "<div>test</div>",
            site_id: nil
          },
          authorize?: false
        )
        |> Ash.create!()

      assert component.name == "my-global-component"
    end

    test "allows same name for global and site-specific components" do
      site = create_site!()

      global =
        Component
        |> Ash.Changeset.for_create(
          :master_create,
          %{name: "Same Name", template: "<div>global</div>", site_id: nil},
          authorize?: false
        )
        |> Ash.create!()

      site_specific =
        Component
        |> Ash.Changeset.for_create(
          :master_create,
          %{name: "Same Name", template: "<div>site</div>", site_id: site.id},
          authorize?: false
        )
        |> Ash.create!()

      assert global.name == site_specific.name
      assert global.site_id == nil
      assert site_specific.site_id == site.id
    end
  end

  describe "update action (tenant)" do
    test "updates component attributes" do
      site = create_site!()

      component =
        create_component!(
          name: "Original",
          template: "<div>original</div>",
          site_id: site.id
        )

      updated =
        component
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Updated", template: "<div>updated</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      assert updated.name == "updated"
      assert updated.template == "<div>updated</div>"
    end

    test "slugifies name when updated" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      updated =
        component
        |> Ash.Changeset.for_update(
          :update,
          %{name: "New Component Name"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      assert updated.name == "new-component-name"
    end

    test "cannot update archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Archive it
      archived =
        component
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Try to update
      assert_raise Ash.Error.Invalid, fn ->
        archived
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Should Fail"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()
      end
    end

    test "prevents site_id changes" do
      site1 = create_site!()
      site2 = create_site!()
      component = create_component!(site_id: site1.id)

      # site_id is not in accepted fields for update
      assert_raise Ash.Error.Invalid, fn ->
        component
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Updated", site_id: site2.id},
          tenant: site1.id,
          authorize?: false
        )
        |> Ash.update!()
      end
    end
  end

  describe "master_update action" do
    test "updates any component regardless of site" do
      site = create_site!()
      component = create_component!(name: "Original", site_id: site.id)

      updated =
        component
        |> Ash.Changeset.for_update(
          :master_update,
          %{name: "Master Updated", template: "<div>master updated</div>"},
          authorize?: false
        )
        |> Ash.update!()

      assert updated.name == "master-updated"
      assert updated.template == "<div>master updated</div>"
    end

    test "updates global component" do
      component = create_component!(name: "Global Original", site_id: nil)

      updated =
        component
        |> Ash.Changeset.for_update(
          :master_update,
          %{description: "Updated description"},
          authorize?: false
        )
        |> Ash.update!()

      assert updated.description == "Updated description"
    end

    test "returns error for non-existent component" do
      fake_id = Ecto.UUID.generate()

      result = Ash.get(Component, fake_id, action: :master_get, authorize?: false)

      assert match?({:error, _}, result)
    end
  end

  describe "read actions (tenant)" do
    test "read lists only non-archived site components" do
      site = create_site!()

      active = create_component!(name: "Active", site_id: site.id)
      archived = create_component!(name: "Archived", site_id: site.id)

      # Archive one
      archived
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      components = Ash.read!(Component, tenant: site.id, authorize?: false)
      ids = Enum.map(components, & &1.id)

      assert active.id in ids
      refute archived.id in ids
    end

    test "archived action lists only archived components" do
      site = create_site!()

      active = create_component!(name: "Active", site_id: site.id)
      to_archive = create_component!(name: "Archived", site_id: site.id)

      # Archive one
      to_archive
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      result =
        Component
        |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
        |> Ash.read!()

      ids = Enum.map(result.results, & &1.id)

      assert to_archive.id in ids
      refute active.id in ids
    end

    test "get_archived retrieves single archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Archive it
      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      result =
        Ash.get!(Component, component.id,
          action: :get_archived,
          tenant: site.id,
          authorize?: false
        )

      assert result.id == component.id
      assert result.archived_at != nil
    end

    test "by_priority orders by priority desc then name asc" do
      site = create_site!()

      create_component!(name: "BBB", priority: 10, site_id: site.id)
      create_component!(name: "AAA", priority: 10, site_id: site.id)
      create_component!(name: "CCC", priority: 20, site_id: site.id)

      page =
        Component
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :by_priority, authorize?: false)

      components = page.results
      assert length(components) == 3
      assert Enum.at(components, 0).name == "ccc"
      assert Enum.at(components, 1).name == "aaa"
      assert Enum.at(components, 2).name == "bbb"
    end
  end

  describe "master read actions" do
    test "master_read lists all components across sites" do
      site1 = create_site!()
      site2 = create_site!()

      comp1 = create_component!(site_id: site1.id)
      comp2 = create_component!(site_id: site2.id)
      global = create_component!(site_id: nil)

      page =
        Component
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read!()

      ids = Enum.map(page.results, & &1.id)

      assert comp1.id in ids
      assert comp2.id in ids
      assert global.id in ids
    end

    test "master_get retrieves any component by ID" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      result = Ash.get!(Component, component.id, action: :master_get, authorize?: false)
      assert result.id == component.id
    end

    test "master_archived lists all archived components across sites" do
      site1 = create_site!()
      site2 = create_site!()

      comp1 = create_component!(site_id: site1.id)
      comp2 = create_component!(site_id: site2.id)

      # Archive both
      comp1
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site1.id, authorize?: false)
      |> Ash.destroy!()

      comp2
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
      |> Ash.destroy!()

      page =
        Component
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.read!()

      ids = Enum.map(page.results, & &1.id)

      assert comp1.id in ids
      assert comp2.id in ids
    end

    test "master_get_archived retrieves any archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Archive it
      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      result = Ash.get!(Component, component.id, action: :master_get_archived, authorize?: false)
      assert result.id == component.id
    end
  end

  describe "for_tenant_with_globals action" do
    setup do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      global1 = create_component!(name: "Global 1", site_id: nil)
      global2 = create_component!(name: "Global 2", site_id: nil)
      site1_comp = create_component!(name: "Site1 Comp", site_id: site1.id)
      site2_comp = create_component!(name: "Site2 Comp", site_id: site2.id)

      {:ok,
       site1: site1,
       site2: site2,
       global1: global1,
       global2: global2,
       site1_comp: site1_comp,
       site2_comp: site2_comp}
    end

    test "tenant user sees their site's components plus global ones", context do
      results =
        Component
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:for_tenant_with_globals, %{})
        |> Ash.read!(authorize?: false)

      ids = Enum.map(results.results, & &1.id)

      # Should see site1 and global components
      assert context.global1.id in ids
      assert context.global2.id in ids
      assert context.site1_comp.id in ids
      # Should NOT see site2 components
      refute context.site2_comp.id in ids
    end

    test "tenant user ignores site_id argument and uses their tenant", context do
      # Pass site2.id as argument, but with site1 tenant - should still only see site1 + global
      results =
        Component
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: context.site2.id})
        |> Ash.read!(authorize?: false)

      ids = Enum.map(results.results, & &1.id)

      assert context.global1.id in ids
      assert context.site1_comp.id in ids
      refute context.site2_comp.id in ids
    end

    test "master user can filter by specific site_id argument", context do
      # No tenant, use site_id argument. A master is a user whose `site_id` is nil.
      master = create_user_with_permissions!(["*"])

      results =
        Component
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: context.site1.id},
          actor: master
        )
        |> Ash.read!(authorize?: false)

      ids = Enum.map(results.results, & &1.id)

      assert context.global1.id in ids
      assert context.site1_comp.id in ids
      refute context.site2_comp.id in ids
    end

    test "master user without site_id sees all components", context do
      # A master is a user whose `site_id` is nil — not a query with no actor in it.
      master = create_user_with_permissions!(["*"])

      results =
        Component
        |> Ash.Query.for_read(:for_tenant_with_globals, %{}, actor: master)
        |> Ash.read!(authorize?: false)

      ids = Enum.map(results.results, & &1.id)

      assert context.global1.id in ids
      assert context.global2.id in ids
      assert context.site1_comp.id in ids
      assert context.site2_comp.id in ids
    end
  end

  describe "get_for_tenant_with_globals action" do
    setup do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      global = create_component!(name: "Global", site_id: nil)
      site1_comp = create_component!(name: "Site1", site_id: site1.id)
      site2_comp = create_component!(name: "Site2", site_id: site2.id)

      {:ok,
       site1: site1, site2: site2, global: global, site1_comp: site1_comp, site2_comp: site2_comp}
    end

    test "tenant user can get their own component", context do
      result =
        Component
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.filter(id == ^context.site1_comp.id)
        |> Ash.Query.for_read(:get_for_tenant_with_globals, %{})
        |> Ash.read_one!(authorize?: false)

      assert result.id == context.site1_comp.id
    end

    test "tenant user can get global component", context do
      result =
        Component
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.filter(id == ^context.global.id)
        |> Ash.Query.for_read(:get_for_tenant_with_globals, %{})
        |> Ash.read_one!(authorize?: false)

      assert result.id == context.global.id
    end

    test "tenant user cannot get other site's component", context do
      result =
        Component
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.filter(id == ^context.site2_comp.id)
        |> Ash.Query.for_read(:get_for_tenant_with_globals, %{})
        |> Ash.read_one!(authorize?: false)

      assert result == nil
    end

    test "master user can get any component with site_id argument", context do
      master = create_user_with_permissions!(["*"])

      result =
        Component
        |> Ash.Query.filter(id == ^context.site1_comp.id)
        |> Ash.Query.for_read(:get_for_tenant_with_globals, %{site_id: context.site1.id},
          actor: master
        )
        |> Ash.read_one!(authorize?: false)

      assert result.id == context.site1_comp.id
    end
  end

  describe "destroy action (tenant - soft delete)" do
    test "archives component by setting archived_at" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      # Should not appear in regular read
      components = Ash.read!(Component, tenant: site.id, authorize?: false)
      refute component.id in Enum.map(components, & &1.id)

      # Should appear in archived
      result =
        Component
        |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
        |> Ash.read!()

      assert component.id in Enum.map(result.results, & &1.id)
    end

    test "cannot archive already archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Archive it first
      archived =
        component
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Try to archive again
      assert_raise Ash.Error.Invalid, fn ->
        archived
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()
      end
    end
  end

  describe "master_destroy action" do
    test "archives any component regardless of site" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      archived =
        component
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      assert archived.archived_at != nil
    end

    test "archives global component" do
      component = create_component!(site_id: nil)

      archived =
        component
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      assert archived.archived_at != nil
    end

    test "returns error for non-existent component" do
      fake_id = Ecto.UUID.generate()

      result = Ash.get(Component, fake_id, action: :master_get, authorize?: false)

      assert match?({:error, _}, result)
    end
  end

  describe "unarchive action (tenant)" do
    test "restores archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Archive it
      archived =
        component
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Unarchive it
      unarchived =
        archived
        |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
        |> Ash.update!()

      assert unarchived.archived_at == nil

      # Should appear in regular read
      components = Ash.read!(Component, tenant: site.id, authorize?: false)
      assert component.id in Enum.map(components, & &1.id)
    end

    test "prevents unarchiving when active component with same name exists" do
      site = create_site!()

      comp1 = create_component!(name: "Conflict", site_id: site.id)

      # Archive it
      archived =
        comp1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Create another with same name
      _comp2 = create_component!(name: "Conflict", site_id: site.id)

      # Try to unarchive - should fail due to unique constraint
      assert {:error, _} =
               archived
               |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
               |> Ash.update()
    end
  end

  describe "master_unarchive action" do
    test "restores any archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Archive it
      archived =
        component
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Unarchive using master action
      unarchived =
        archived
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update!()

      assert unarchived.archived_at == nil
    end

    test "returns error for non-archived component" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      result =
        component
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update()

      assert match?({:error, _}, result)
    end

    test "restores global archived component" do
      component = create_component!(site_id: nil)

      # Archive it using master
      archived =
        component
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      # Unarchive it
      unarchived =
        archived
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update!()

      assert unarchived.archived_at == nil
    end
  end

  describe "permanent_destroy action (tenant)" do
    test "permanently deletes component" do
      site = create_site!()
      component = create_component!(site_id: site.id)
      component_id = component.id

      component
      |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      # Should not exist anywhere
      result = Ash.get(Component, component_id, action: :master_get, authorize?: false)
      assert match?({:error, _}, result)
    end
  end

  describe "master_permanent_destroy action" do
    test "permanently deletes any component" do
      site = create_site!()
      component = create_component!(site_id: site.id)
      component_id = component.id

      component
      |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Should not exist anywhere
      result = Ash.get(Component, component_id, action: :master_get, authorize?: false)
      assert match?({:error, _}, result)
    end

    test "permanently deletes global component" do
      component = create_component!(site_id: nil)
      component_id = component.id

      component
      |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      result = Ash.get(Component, component_id, action: :master_get, authorize?: false)
      assert match?({:error, _}, result)
    end
  end

  defp changed(%{changes: changes}) when is_map(changes), do: changes
  defp changed(%{changes: changes}) when is_binary(changes), do: Jason.decode!(changes)
  defp changed(_version), do: %{}

  # WHAT A COMPONENT COMPILES INTO, declared on the row rather than guessed from its markup.
  # `false` is the shape every component has had until now: a function component, rendered by
  # applying its name, holding nothing between renders. `true` is a `Phoenix.LiveComponent`.
  describe "the stateful flag" do
    test "defaults to false, so the 141 already installed read as function components" do
      site = create_site!()
      component = create_component!(name: "Ordinary", site_id: site.id)

      assert component.stateful == false
    end

    test "is accepted on create and read back" do
      site = create_site!()

      assert {:ok, component} =
               Component
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Live Search", template: "<div>a</div>", stateful: true},
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert component.stateful == true
    end

    test "and on update, both ways" do
      site = create_site!()
      component = create_component!(name: "Becoming Live", site_id: site.id)

      assert {:ok, live} =
               component
               |> Ash.Changeset.for_update(:update, %{stateful: true}, tenant: site.id)
               |> Ash.update(authorize?: false)

      assert live.stateful == true

      assert {:ok, back} =
               live
               |> Ash.Changeset.for_update(:update, %{stateful: false}, tenant: site.id)
               |> Ash.update(authorize?: false)

      assert back.stateful == false
    end

    test "a master sets it too" do
      site = create_site!()

      assert {:ok, component} =
               Component
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{
                   name: "Master Live",
                   template: "<div>a</div>",
                   stateful: true,
                   site_id: site.id
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)

      assert component.stateful == true
    end

    # THE ADMIN CAN SET IT AND SEE IT. A flag that decides what a component can do, settable only
    # through the API or a kit bundle, is a flag most readers will never know exists — and the two
    # kinds are indistinguishable in a list of 140 without a column that says which.
    test "the admin form offers it and the list shows it" do
      alias MishkaGervaz.Resource.Info

      field =
        Component
        |> Info.Form.fields()
        |> Enum.find(&(&1.name == :stateful))

      assert field, "the admin form does not offer the flag at all"
      assert field.type == :toggle

      # The kind shares a column with the dependencies, the way `active` shares one with
      # `precompile` — so what matters is that the column REQUIRES `stateful`, not what it is
      # called. Naming the column would have made this test fail for a layout change.
      column =
        Component
        |> Info.Table.columns()
        |> Enum.find(&(:stateful in List.wrap(&1.requires)))

      assert column, "the component list does not say which kind a row is"
    end

    # THE COLUMN ITSELF, RENDERED. `Kind & Dependencies` carries two facts and a third party's cell:
    # the chip is this column's markup, the tags are `MishkaGervaz.UIAdapters.Tailwind.cell_tags/1`.
    # Asserting on the output rather than on the declaration is what catches the cell being dropped
    # for hand-rolled chips again, or the chip losing the hook other tests select on.
    test "the merged column draws the kind and the dependencies" do
      alias MishkaGervaz.Resource.Info

      column =
        Component
        |> Info.Table.columns()
        |> Enum.find(&(:stateful in List.wrap(&1.requires)))

      # THE RECORD GERVAZ ACTUALLY HANDS IT: a map of the column's OWN `requires` and nothing else.
      # Building a fuller one here is what let `record.id` ship unrequired — the probe passed, the
      # test passed, and every row in the real table raised `key :id not found`, which crashed the
      # LiveView and reconnected it in a loop.
      record = fn fields ->
        Map.take(fields, List.wrap(column.requires))
      end

      # THE CONTRACT, SAID OUT LOUD. The cell namespaces its expand toggle per row, so it reads the
      # id — and a field a column does not require is a field it is not given. `tags_dom_id/1` falls
      # back to a hash if this is ever dropped, so the row degrades rather than crashing, but the
      # toggles would then collide between rows with equal dependencies.
      assert :id in List.wrap(column.requires),
             "the cell reads the record id, so the column has to ask for it"

      live =
        drawn(
          column,
          record.(%{
            id: Ash.UUID.generate(),
            stateful: true,
            dependencies: ["chelekom-icon", "chelekom-card", "a", "b", "c"],
            name: "not required, must not be read"
          })
        )

      assert live =~ ~s(data-kind="live")
      assert live =~ "chelekom-icon"

      # THE ADAPTER'S CELL AND NOT A FLEX-WRAP OF SPANS: more dependencies than the column shows
      # collapse behind a `+N` the reader can expand, and hand-rolled chips had no such thing. The
      # number itself is the column's to tune — pinning it here is what made a one-line change to
      # `max_items` read as the cell being lost.
      assert live =~ ~r/\+\d+/,
             "the tags lost their expand toggle, so they are not the adapter's cell"

      plain =
        drawn(
          column,
          record.(%{id: Ash.UUID.generate(), stateful: false, dependencies: []})
        )

      assert plain =~ ~s(data-kind="function")
      assert plain =~ "—", "an empty list lost the adapter's placeholder"
    end

    defp drawn(column, record) do
      record
      |> column.render.()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end

    # A RESTORE BRINGS BACK THE SHAPE ALONG WITH THE MARKUP. `restore_version` reduces over the keys
    # PRESENT in the snapshot, and a snapshot taken since this column existed carries one — so
    # rolling a component back to a version it was a function component at makes it a function
    # component again. That is the consistent answer (a version is what the row was, all of it) and
    # it is worth pinning, because the alternative reading is just as plausible and the two differ
    # silently.
    #
    # A snapshot taken BEFORE the column existed has no such key and the reduce never sees it, so
    # those restores leave the flag alone. That case cannot be built here without writing a version
    # row by hand, so it is stated rather than asserted.
    test "restoring a version restores the shape it was, not only the markup" do
      site = create_site!()

      component =
        create_component!(name: "Restorable Live", template: "<div>One</div>", site_id: site.id)

      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>Two</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # CHOSEN BY WHAT IT HOLDS, not by being first. Two versions written inside the same microsecond
      # tie on `version_inserted_at`, and then "the earliest" is whichever the database felt like —
      # which passed alone and failed inside a full run.
      first_version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^component.id)
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(changed(&1)["template"] == "<div>One</div>"))

      assert first_version, "no version holds the original markup"

      made_live =
        component
        |> Ash.Changeset.for_update(:update, %{stateful: true},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      assert made_live.stateful == true

      {:ok, restored} =
        Component
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{id: component.id, version_id: first_version.id},
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.template == "<div>One</div>", "the markup came back"

      assert restored.stateful == false,
             "the snapshot said function component, so the restore should say so too"
    end
  end

  describe "version management - get_with_versions" do
    test "gets component with paginated versions (tenant)" do
      site = create_site!()
      component = create_component!(name: "Versioned", site_id: site.id)

      # Create versions by updating
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V3</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      result =
        Component
        |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
        |> Ash.Query.filter(id == ^component.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == component.id
      assert is_list(result.sorted_versions)
      assert length(result.sorted_versions) > 0
    end

    test "respects versions_limit argument" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create multiple versions
      for i <- 1..5 do
        component
        |> Ash.Changeset.for_update(:update, %{template: "<div>V#{i}</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()
      end

      result =
        Component
        |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 2}, tenant: site.id)
        |> Ash.Query.filter(id == ^component.id)
        |> Ash.read_one!(authorize?: false)

      assert length(result.sorted_versions) <= 2
    end
  end

  describe "version management - master_get_with_versions" do
    test "gets component with versions bypassing tenant (master)" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create a version
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      result =
        Component
        |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10}, authorize?: false)
        |> Ash.Query.filter(id == ^component.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == component.id
      assert is_list(result.sorted_versions)
    end
  end

  describe "version management - list_versions" do
    test "lists all versions for a component (tenant)" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create versions
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      result =
        Component
        |> Ash.Query.for_read(:list_versions, %{component_id: component.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.read!()

      components = result.results
      assert length(components) == 1
      assert List.first(components).id == component.id
      assert is_list(List.first(components).sorted_versions)
    end

    test "returns error for component from different tenant" do
      site1 = create_site!()
      site2 = create_site!()

      component = create_component!(site_id: site1.id)

      result =
        Component
        |> Ash.Query.for_read(:list_versions, %{component_id: component.id},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.read()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "version management - master_list_versions" do
    test "lists all versions bypassing tenant (master)" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      result =
        Component
        |> Ash.Query.for_read(:master_list_versions, %{component_id: component.id},
          authorize?: false
        )
        |> Ash.read!(authorize?: false)

      components = result.results
      assert length(components) == 1
      assert is_list(List.first(components).sorted_versions)
    end
  end

  describe "version management - restore_version_api (tenant)" do
    test "tenant restores their own component version" do
      site = create_site!()

      component =
        create_component!(
          name: "Restorable",
          template: "<div>Original</div>",
          description: "Original desc",
          site_id: site.id
        )

      # Update to create a version
      component
      |> Ash.Changeset.for_update(
        :update,
        %{template: "<div>Updated</div>", description: "Updated desc"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Get the first version
      versions =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      first_version = List.first(versions)
      assert first_version != nil

      # Restore using API action
      {:ok, restored} =
        Component
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{id: component.id, version_id: first_version.id},
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.template == "<div>Original</div>"
      assert restored.description == "Original desc"
    end

    test "tenant cannot restore global component version" do
      site = create_site!()

      component =
        create_component!(
          name: "Global Restorable",
          template: "<div>Original</div>",
          site_id: nil
        )

      # Update
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>Updated</div>"}, authorize?: false)
      |> Ash.update!()

      # Get version
      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      # Tenant cannot restore global component
      assert_raise Ash.Error.Invalid, fn ->
        Component
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{id: component.id, version_id: version.id},
          tenant: site.id
        )
        |> Ash.run_action!(authorize?: false)
      end
    end

    test "tenant cannot restore other tenant's component" do
      site1 = create_site!()
      site2 = create_site!()

      component = create_component!(site_id: site1.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site1.id,
        authorize?: false
      )
      |> Ash.update!()

      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      # Site2 cannot restore site1's component
      result =
        Component
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{id: component.id, version_id: version.id},
          tenant: site2.id
        )
        |> Ash.run_action(authorize?: false)

      assert match?({:error, _}, result)
    end

    test "cannot restore archived component" do
      site = create_site!()

      component = create_component!(site_id: site.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Archive
      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      result =
        Component
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{id: component.id, version_id: version.id},
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert match?({:error, _}, result)
    end
  end

  describe "version management - master_restore_version" do
    test "master restores any component version" do
      site = create_site!()

      component =
        create_component!(
          name: "Master Restorable",
          template: "<div>Original</div>",
          site_id: site.id
        )

      # Update
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>Updated</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Get version
      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      {:ok, restored} =
        Component
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: component.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert restored.template == "<div>Original</div>"
    end

    test "returns error if version doesn't belong to component" do
      site = create_site!()

      comp1 = create_component!(name: "Comp1", site_id: site.id)
      comp2 = create_component!(name: "Comp2", site_id: site.id)

      # Create version for comp2
      comp2
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: comp2.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      # Try to restore comp1 with comp2's version
      result =
        Component
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: comp1.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert match?({:error, _}, result)
    end

    test "cannot restore archived component" do
      site = create_site!()

      component = create_component!(site_id: site.id)

      # Create version
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Archive
      component
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      result =
        Component
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: component.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert match?({:error, _}, result)
    end
  end

  describe "version management - preview_version (tenant)" do
    test "previews version without restoring" do
      site = create_site!()

      component =
        create_component!(
          name: "Preview",
          template: "<div>Original</div>",
          description: "Original desc",
          site_id: site.id
        )

      # Update
      component
      |> Ash.Changeset.for_update(
        :update,
        %{template: "<div>Updated</div>", description: "Updated desc"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Get version
      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      {:ok, preview} =
        Component
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{component_id: component.id, version_id: version.id},
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert preview.template == "<div>Original</div>"
      assert preview.description == "Original desc"

      # Verify original is unchanged
      current = Ash.get!(Component, component.id, tenant: site.id, authorize?: false)
      assert current.template == "<div>Updated</div>"
    end

    test "returns error for version from wrong component" do
      site = create_site!()

      comp1 = create_component!(name: "Comp1", site_id: site.id)
      comp2 = create_component!(name: "Comp2", site_id: site.id)

      # Create version for comp2
      comp2
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: comp2.id)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      result =
        Component
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{component_id: comp1.id, version_id: version.id},
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert match?({:error, _}, result)
    end
  end

  describe "version management - master_preview_version" do
    test "previews any version without restoring (master)" do
      site = create_site!()

      component =
        create_component!(
          name: "Master Preview",
          template: "<div>Original</div>",
          site_id: site.id
        )

      # Update
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>Updated</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      # Get version
      version =
        Component.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id: component.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      {:ok, preview} =
        Component
        |> Ash.ActionInput.for_action(
          :master_preview_version,
          %{
            component_id: component.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert preview.template == "<div>Original</div>"
    end
  end

  describe "version calculations" do
    test "version_count returns correct count" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create versions
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V3</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      loaded =
        Component
        |> Ash.get!(component.id, tenant: site.id, authorize?: false)
        |> Ash.load!(:version_count, authorize?: false)

      assert loaded.version_count >= 2
    end

    test "latest_version returns most recent version" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create versions
      component
      |> Ash.Changeset.for_update(:update, %{template: "<div>V2</div>"},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      loaded =
        Component
        |> Ash.get!(component.id, tenant: site.id, authorize?: false)
        |> Ash.load!(:latest_version, authorize?: false)

      assert loaded.latest_version != nil
      assert is_struct(loaded.latest_version, Component.Version)
    end

    test "recent_versions returns up to 10 versions" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      # Create multiple versions
      for i <- 1..5 do
        component
        |> Ash.Changeset.for_update(:update, %{template: "<div>V#{i}</div>"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()
      end

      loaded =
        Component
        |> Ash.get!(component.id, tenant: site.id, authorize?: false)
        |> Ash.load!(:recent_versions, authorize?: false)

      assert is_list(loaded.recent_versions)
      assert length(loaded.recent_versions) <= 10
      assert length(loaded.recent_versions) >= 5
    end
  end

  describe "calculations" do
    test "component_module generates correct module name" do
      site = create_site!()
      component = create_component!(name: "My Component", site_id: site.id)

      loaded =
        Ash.get!(Component, component.id,
          load: [:component_module],
          tenant: site.id,
          authorize?: false
        )

      assert loaded.component_module != nil
      assert to_string(loaded.component_module) =~ ~r/Component$/
    end

    test "is_global correctly identifies global components" do
      site = create_site!()

      global = create_component!(name: "Global", site_id: nil)
      site_specific = create_component!(name: "Site Specific", site_id: site.id)

      global_loaded = Ash.load!(global, :is_global, authorize?: false)
      site_loaded = Ash.load!(site_specific, :is_global, tenant: site.id, authorize?: false)

      assert global_loaded.is_global == true
      assert site_loaded.is_global == false
    end
  end

  describe "relationships" do
    test "belongs_to site relationship" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      loaded = Ash.load!(component, :site, authorize?: false)
      assert loaded.site.id == site.id
    end

    test "global component has nil site" do
      component = create_component!(site_id: nil)

      loaded = Ash.load!(component, :site, authorize?: false)
      assert loaded.site == nil
    end
  end

  describe "identities" do
    test "unique_name_per_site enforces uniqueness within site" do
      site = create_site!()

      create_component!(name: "Unique", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_component!(name: "Unique", site_id: site.id)
      end
    end

    test "allows same name for archived and active within same site" do
      site = create_site!()

      comp1 = create_component!(name: "Reusable", site_id: site.id)

      # Archive it
      comp1
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      # Create new with same name
      comp2 = create_component!(name: "Reusable", site_id: site.id)
      assert comp2.name == "reusable"
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()
      component = create_component!(site_id: site.id)
      binary_id = Ecto.UUID.dump!(component.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE components SET name = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger prevents archived updates" do
      site = create_site!()
      component = create_component!(site_id: site.id)

      {:ok, _archived} =
        Ash.destroy(component, authorize?: false, return_destroyed?: true, tenant: site.id)

      binary_id = Ecto.UUID.dump!(component.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE components SET name = 'Should Fail' WHERE id = $1",
          [binary_id]
        )
      end
    end
  end
end
