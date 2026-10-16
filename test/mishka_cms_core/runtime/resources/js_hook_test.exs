# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.JsHookTest do
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  import MishkaCmsCore.Test.VersionHelpers
  alias MishkaCmsCore.Runtime.JsHook
  require Ash.Query
  @moduletag :unit

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its js hooks" do
      site = create_site!()
      create_js_hook!(site_id: site.id)

      count = fn ->
        JsHook |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false) |> length()
      end

      assert count.() == 1
      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
      assert count.() == 0
    end
  end

  describe "configuration" do
    test "resource has correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(JsHook) == "js_hooks"
      assert AshPostgres.DataLayer.Info.repo(JsHook) == @repo
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(JsHook)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(JsHook) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(JsHook) == :site_id
      assert Ash.Resource.Info.multitenancy_global?(JsHook) == true
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)

      hooks =
        JsHook
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped hook in hooks

      archived_hook = Ash.destroy!(hook, authorize?: false)

      hooks =
        JsHook
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived_hook not in hooks
    end
  end

  describe "create action" do
    test "creates a site-specific js hook with valid attributes" do
      site = create_site!()

      attrs = %{
        name: "Navigation Hook",
        content: "console.log('Navigation loaded');"
      }

      assert {:ok, hook} =
               JsHook
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.Changeset.load([:is_global, :site, :file_extension])
               |> Ash.create(authorize?: false)

      assert hook.name == "navigation-hook"
      assert hook.content == "console.log('Navigation loaded');"
      assert hook.is_global == false
      assert hook.site_id == site.id
      assert hook.file_extension == ".js"
    end

    test "creates a global js hook via master_create" do
      attrs = %{
        name: "Global Analytics",
        content: "window.analytics = { track: function() {} };"
        # site_id: nil - omitted for global hook
      }

      assert {:ok, hook} =
               JsHook
               |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
               |> Ash.Changeset.load([:is_global, :site, :file_extension])
               |> Ash.create(authorize?: false)

      assert hook.name == "global-analytics"
      assert hook.is_global == true
      assert hook.site_id == nil
      assert hook.site == nil
      assert hook.file_extension == ".js"
    end

    test "creates typescript hook with correct extension" do
      site = create_site!()

      attrs = %{
        name: "TypeScript Hook",
        content: "const message: string = 'Hello TypeScript';",
        format: :ts
      }

      assert {:ok, hook} =
               JsHook
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.Changeset.load([:file_extension])
               |> Ash.create(authorize?: false)

      assert hook.format == :ts
      assert hook.file_extension == ".ts"
    end

    test "validates required fields" do
      site = create_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, %{})
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          :name in error.fields and :content in error.fields
      end)
    end

    test "validates name length constraints" do
      site = create_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, %{name: "ab", content: "test"})
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      long_name = String.duplicate("a", 101)

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, %{name: long_name, content: "test"})
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end

    test "validates content constraints" do
      attrs = [
        name: "Empty Content Hook",
        content: ""
      ]

      changeset =
        JsHook
        |> Ash.Changeset.for_create(:create, attrs)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          :content in error.fields
      end)
    end

    test "validates format constraints" do
      site = create_site!()

      changeset =
        JsHook
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test",
            content: "test",
            format: :invalid
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      for format <- [:js, :ts] do
        changeset =
          JsHook
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test #{format}",
              content: "console.log('test');",
              format: format
            },
            tenant: site.id
          )

        assert changeset.valid?
      end
    end

    test "enforces unique name constraint for global hooks" do
      create_js_hook!(name: "Unique Global", site_id: nil)

      assert_raise Ash.Error.Invalid, fn ->
        create_js_hook!(name: "Unique Global", site_id: nil)
      end
    end

    test "enforces unique name per site constraint" do
      site = create_site!()
      create_js_hook!(name: "Unique Hook", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_js_hook!(name: "Unique Hook", site_id: site.id)
      end
    end

    test "allows same name across different sites" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      hook1 = create_js_hook!(name: "Analytics", site_id: site1.id)
      hook2 = create_js_hook!(name: "Analytics", site_id: site2.id)

      assert hook1.name == hook2.name
      assert hook1.site_id != hook2.site_id
    end

    test "allows same name across global and site hooks" do
      site = create_site!()

      global_hook = create_js_hook!(name: "Same Name", site_id: nil)
      site_hook = create_js_hook!(name: "Same Name", site_id: site.id)

      assert global_hook.name == site_hook.name
      assert global_hook.site_id == nil
      assert site_hook.site_id == site.id
    end

    test "Extra :: allows same name for global and site-specific hooks" do
      site = create_site!()

      # Create a global hook
      global_hook = create_js_hook!(name: "Test Hook", site_id: nil)

      # Create a site-specific hook with the same name
      site_hook = create_js_hook!(name: "Test Hook", site_id: site.id)

      # Load the calculations
      global_hook = Ash.get!(JsHook, global_hook.id, load: [:is_global], authorize?: false)

      site_hook =
        Ash.get!(JsHook, site_hook.id, load: [:is_global], tenant: site.id, authorize?: false)

      # Both should be created successfully
      assert global_hook.name == "test-hook"
      assert global_hook.site_id == nil
      assert global_hook.is_global == true

      assert site_hook.name == "test-hook"
      assert site_hook.site_id == site.id
      assert site_hook.is_global == false

      # They should be different records
      assert global_hook.id != site_hook.id
    end
  end

  describe "update action" do
    test "updates a non-archived hook successfully" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)

      assert {:ok, updated} =
               hook
               |> Ash.Changeset.for_update(:update, %{name: "Updated Name"})
               |> Ash.Changeset.set_tenant(site.id)
               |> Ash.update(authorize?: false)

      assert updated.name == "updated-name"
    end

    test "prevents updating archived hooks" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)
      {:ok, archived} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)

      changeset =
        archived
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"})
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          error.fields == [:archived_at]
      end)
    end

    test "can update content and format" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id, format: :js)

      {:ok, updated} =
        hook
        |> Ash.Changeset.for_update(:update, %{
          content: "const newCode: string = 'updated';",
          format: :ts
        })
        |> Ash.Changeset.set_tenant(site.id)
        |> Ash.Changeset.load([:file_extension])
        |> Ash.update(authorize?: false)

      assert updated.content == "const newCode: string = 'updated';"
      assert updated.format == :ts
      assert updated.file_extension == ".ts"
    end
  end

  describe "read actions with multitenancy" do
    setup do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      global1 = create_js_hook!(name: "Global Header", site_id: nil, priority: 10)
      global2 = create_js_hook!(name: "Global Footer", site_id: nil, priority: 5)

      site1_hook = create_js_hook!(name: "Site 1 Hook", site_id: site1.id, priority: 20)
      site2_hook = create_js_hook!(name: "Site 2 Hook", site_id: site2.id, priority: 15)

      {:ok,
       site1: site1,
       site2: site2,
       global1: global1,
       global2: global2,
       site1_hook: site1_hook,
       site2_hook: site2_hook}
    end

    test "default read with tenant shows only site-specific hooks", context do
      hooks =
        JsHook
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.read!(authorize?: false)

      hook_ids = Enum.map(hooks, & &1.id)

      assert context.site1_hook.id in hook_ids
      refute context.site2_hook.id in hook_ids
      # This is the correct behavior - global hooks are NOT included
      refute context.global1.id in hook_ids
      refute context.global2.id in hook_ids
    end

    test "read without tenant shows only global hooks", context do
      hooks =
        JsHook
        |> Ash.Query.filter(is_nil(site_id))
        |> Ash.read!(authorize?: false)

      hook_ids = Enum.map(hooks, & &1.id)

      assert context.global1.id in hook_ids
      assert context.global2.id in hook_ids
      refute context.site1_hook.id in hook_ids
      refute context.site2_hook.id in hook_ids
    end

    test "hooks can be sorted by priority desc, then name asc", context do
      _same_priority =
        create_js_hook!(
          name: "AAA Hook",
          site_id: context.site1.id,
          priority: 20
        )

      hooks =
        JsHook
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.sort(priority: :desc, name: :asc)
        |> Ash.read!(authorize?: false)

      assert length(hooks) == 2

      assert Enum.at(hooks, 0).priority == 20
      assert Enum.at(hooks, 0).name == "aaa-hook"
      assert Enum.at(hooks, 1).priority == 20
      assert Enum.at(hooks, 1).name == "site-1-hook"
    end
  end

  describe "active/inactive filtering" do
    test "can filter active hooks using query filter" do
      site = create_site!()
      active_hook = create_js_hook!(site_id: site.id, active: true)
      inactive_hook = create_js_hook!(site_id: site.id, active: false)

      active_hooks =
        JsHook
        |> Ash.Query.set_tenant(site.id)
        |> Ash.Query.filter(active == true)
        |> Ash.read!(authorize?: false)

      active_ids = Enum.map(active_hooks, & &1.id)
      assert active_hook.id in active_ids
      refute inactive_hook.id in active_ids
    end

    test "can filter inactive hooks using query filter" do
      site = create_site!()
      active_hook = create_js_hook!(site_id: site.id, active: true)
      inactive_hook = create_js_hook!(site_id: site.id, active: false)

      inactive_hooks =
        JsHook
        |> Ash.Query.set_tenant(site.id)
        |> Ash.Query.filter(active == false)
        |> Ash.read!(authorize?: false)

      inactive_ids = Enum.map(inactive_hooks, & &1.id)

      refute active_hook.id in inactive_ids
      assert inactive_hook.id in inactive_ids
    end

    test "update action can toggle active to true" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id, active: false)

      {:ok, activated} =
        hook
        |> Ash.Changeset.for_update(:update, %{active: true})
        |> Ash.Changeset.set_tenant(site.id)
        |> Ash.update(authorize?: false)

      assert activated.active == true
    end

    test "update action can toggle active to false" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id, active: true)

      {:ok, deactivated} =
        hook
        |> Ash.Changeset.for_update(:update, %{active: false})
        |> Ash.Changeset.set_tenant(site.id)
        |> Ash.update(authorize?: false)

      assert deactivated.active == false
    end
  end

  describe "format filtering" do
    test "filters hooks by javascript format using query" do
      site = create_site!()
      js_hook = create_js_hook!(site_id: site.id, format: :js)
      ts_hook = create_js_hook!(site_id: site.id, format: :ts)

      js_hooks =
        JsHook
        |> Ash.Query.set_tenant(site.id)
        |> Ash.Query.filter(format == :js)
        |> Ash.read!(authorize?: false)

      js_ids = Enum.map(js_hooks, & &1.id)

      assert js_hook.id in js_ids
      refute ts_hook.id in js_ids
    end

    test "filters hooks by typescript format using query" do
      site = create_site!()
      js_hook = create_js_hook!(site_id: site.id, format: :js)
      ts_hook = create_js_hook!(site_id: site.id, format: :ts)

      ts_hooks =
        JsHook
        |> Ash.Query.set_tenant(site.id)
        |> Ash.Query.filter(format == :ts)
        |> Ash.read!(authorize?: false)

      ts_ids = Enum.map(ts_hooks, & &1.id)

      refute js_hook.id in ts_ids
      assert ts_hook.id in ts_ids
    end
  end

  describe "archive/unarchive actions" do
    test "destroy archives a hook (sets archived_at)" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)

      assert {:ok, archived} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)
      assert archived.archived_at != nil

      hooks = JsHook |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      hook_ids = Enum.map(hooks, & &1.id)
      refute archived.id in hook_ids

      archived_hooks = Ash.read!(JsHook, action: :archived, authorize?: false)
      archived_ids = Enum.map(archived_hooks.results, & &1.id)
      assert archived.id in archived_ids
    end

    test "unarchive restores a hook" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)
      {:ok, _archived} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)

      query =
        JsHook
        |> Ash.Query.filter(id: hook.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(query.results)

      {:ok, unarchived} = Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
      assert unarchived.archived_at == nil

      hooks = JsHook |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      hook_ids = Enum.map(hooks, & &1.id)
      assert unarchived.id in hook_ids
    end

    test "permanent_destroy actually deletes the record" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)
      hook_id = hook.id

      _result = Ash.destroy(hook, action: :permanent_destroy, authorize?: false)

      active = JsHook |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      archived = Ash.read!(JsHook, action: :archived, authorize?: false)

      active_ids = Enum.map(active, & &1.id)
      archived_ids = Enum.map(archived.results, & &1.id)

      refute hook_id in active_ids
      refute hook_id in archived_ids
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)
      binary_id = Ecto.UUID.dump!(hook.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE js_hooks SET name = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger prevents archived updates" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)
      {:ok, archived} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)
      binary_id = Ecto.UUID.dump!(archived.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE js_hooks SET name = 'Should Fail' WHERE id = $1",
          [binary_id]
        )
      end
    end
  end

  describe "attribute defaults" do
    test "sets default values correctly" do
      site = create_site!()
      hook = create_js_hook!(site_id: site.id)

      assert hook.format == :js
      assert hook.priority == 0
      assert hook.active == true
      assert hook.permissions == []
      assert hook.inserted_at != nil
      assert hook.updated_at != nil
    end
  end

  describe "complex scenarios" do
    test "handles hook with all attributes" do
      site = create_site!()

      hook =
        create_js_hook!(
          site_id: site.id,
          name: "Complex Hook",
          description: "A complex hook with many features",
          content: "const complex = { init: () => console.log('loaded') };",
          format: :ts,
          priority: 50,
          active: false,
          permissions: ["admin", "developer"]
        )

      assert hook.description == "A complex hook with many features"
      assert hook.format == :ts
      assert hook.priority == 50
      assert hook.active == false
      assert hook.permissions == ["admin", "developer"]
    end

    test "allows same name for archived and active hooks within same site" do
      site = create_site!()

      hook1 = create_js_hook!(name: "Reusable", site_id: site.id)
      {:ok, _archived} = Ash.destroy(hook1, authorize?: false, return_destroyed?: true)

      hook2 = create_js_hook!(name: "Reusable", site_id: site.id)
      assert hook2.name == "reusable"
    end

    test "prevents unarchiving when active hook with same name exists" do
      site = create_site!()

      hook1 = create_js_hook!(name: "Conflict", site_id: site.id)
      {:ok, _archived} = Ash.destroy(hook1, authorize?: false, return_destroyed?: true)

      _hook2 = create_js_hook!(name: "Conflict", site_id: site.id)

      query =
        JsHook
        |> Ash.Query.filter(id: hook1.id)
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

      # Create JS hooks for different sites
      global_hook = create_js_hook!(name: "Global Hook", content: "// global", site_id: nil)
      site1_hook = create_js_hook!(name: "Site1 Hook", content: "// site1", site_id: site1.id)
      site2_hook = create_js_hook!(name: "Site2 Hook", content: "// site2", site_id: site2.id)

      # Test for_tenant_with_globals with site_id for master user (no tenant)
      results =
        JsHook
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: site1.id}, actor: master)
        |> Ash.read!(authorize?: false)

      hook_ids = Enum.map(results.results, & &1.id)

      # Should see site1 hooks and global hooks only
      assert global_hook.id in hook_ids
      assert site1_hook.id in hook_ids
      refute site2_hook.id in hook_ids

      # Test get_for_tenant_with_globals with site_id for master user
      result =
        JsHook
        |> Ash.Query.for_read(:get_for_tenant_with_globals, %{site_id: site1.id}, actor: master)
        |> Ash.Query.filter(id == ^site1_hook.id)
        |> Ash.read_one!(authorize?: false)

      assert result.id == site1_hook.id
    end

    test "tenant user ignores site_id argument and uses their tenant" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")

      # Create JS hooks for different sites
      global_hook = create_js_hook!(name: "Global Hook", content: "// global", site_id: nil)
      site1_hook = create_js_hook!(name: "Site1 Hook", content: "// site1", site_id: site1.id)
      site2_hook = create_js_hook!(name: "Site2 Hook", content: "// site2", site_id: site2.id)

      # Test for_tenant_with_globals with site_id for tenant user (site1)
      # Even though we pass site2.id, it should be ignored and use site1
      results =
        JsHook
        |> Ash.Query.set_tenant(site1.id)
        |> Ash.Query.for_read(:for_tenant_with_globals, %{site_id: site2.id})
        |> Ash.read!(authorize?: false)

      hook_ids = Enum.map(results.results, & &1.id)

      # Should see site1 hooks and global hooks (ignoring site_id argument)
      assert global_hook.id in hook_ids
      assert site1_hook.id in hook_ids
      refute site2_hook.id in hook_ids
    end

    test "master user without site_id sees all JS hooks" do
      site1 = create_site!(name: "Site 1")
      site2 = create_site!(name: "Site 2")
      # A MASTER IS A USER WHOSE `site_id` IS NIL — not a query with no actor in it.
      master = create_user_with_permissions!(["*"])

      # Create JS hooks for different sites
      global_hook = create_js_hook!(name: "Global Hook", content: "// global", site_id: nil)
      site1_hook = create_js_hook!(name: "Site1 Hook", content: "// site1", site_id: site1.id)
      site2_hook = create_js_hook!(name: "Site2 Hook", content: "// site2", site_id: site2.id)

      # Test for_tenant_with_globals without site_id for master user
      results =
        JsHook
        |> Ash.Query.for_read(:for_tenant_with_globals, %{}, actor: master)
        |> Ash.read!(authorize?: false)

      hook_ids = Enum.map(results.results, & &1.id)

      # Should see all JS hooks
      assert global_hook.id in hook_ids
      assert site1_hook.id in hook_ids
      assert site2_hook.id in hook_ids
    end
  end

  describe "restore_version action" do
    test "master_restore_version can restore any JS hook version" do
      site = create_site!()

      # Create JS hooks
      global_js_hook =
        create_js_hook!(
          name: "Global JS Hook",
          content: "console.log('Global V1');",
          priority: 10,
          site_id: nil
        )

      tenant_js_hook =
        create_js_hook!(
          name: "Tenant JS Hook",
          content: "console.log('Tenant V1');",
          priority: 20,
          site_id: site.id
        )

      # Update JS hooks to create versions using master_update for global
      global_js_hook
      |> Ash.Changeset.for_update(:master_update, %{content: "console.log('Global V2');"},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      tenant_js_hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('Tenant V2');"})
      |> Ash.Changeset.set_tenant(site.id)
      |> Ash.update!(authorize?: false)

      # Get first version
      global_version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, global_js_hook.id)

      assert global_version != nil

      tenant_version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, tenant_js_hook.id, tenant: site.id)

      assert tenant_version != nil

      # Master user can restore global JS hook via master_restore_version
      {:ok, restored_global} =
        JsHook
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: global_js_hook.id,
            version_id: global_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert restored_global.content == "console.log('Global V1');"

      # Master user can restore tenant JS hook via master_restore_version
      {:ok, restored_tenant} =
        JsHook
        |> Ash.ActionInput.for_action(
          :master_restore_version,
          %{
            id: tenant_js_hook.id,
            version_id: tenant_version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert restored_tenant.content == "console.log('Tenant V1');"
    end

    test "tenant user can restore their own tenant's JS hook" do
      site = create_site!()

      tenant_js_hook =
        create_js_hook!(
          name: "Tenant JS Hook",
          content: "console.log('Original');",
          priority: 10,
          site_id: site.id
        )

      # Update to create version
      tenant_js_hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('Updated');"})
      |> Ash.update!(authorize?: false, tenant: site.id)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, tenant_js_hook.id, tenant: site.id)

      assert version != nil

      # Tenant can restore their own JS hook
      tenant_user = create_user_with_permissions!(["*"], site_id: site.id)

      tenant_js_hook_fresh =
        Ash.get!(JsHook, tenant_js_hook.id, authorize?: false, tenant: site.id)

      {:ok, restored} =
        tenant_js_hook_fresh
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
          actor: tenant_user
        )
        |> Ash.update(actor: tenant_user, tenant: site.id)

      assert restored.content == "console.log('Original');"
    end

    test "tenant user cannot restore global JS hook" do
      site = create_site!()

      global_js_hook =
        create_js_hook!(
          name: "Global JS Hook",
          content: "console.log('Global V1');",
          priority: 10,
          site_id: nil
        )

      # Update to create version using master_update for global hook
      global_js_hook
      |> Ash.Changeset.for_update(:master_update, %{content: "console.log('Global V2');"},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, global_js_hook.id)

      assert version != nil

      # Tenant cannot restore global JS hook
      global_js_hook_fresh = Ash.get!(JsHook, global_js_hook.id, authorize?: false)

      changeset =
        global_js_hook_fresh
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(changeset, authorize?: false, tenant: site.id)
    end

    test "tenant user cannot access other tenant's JS hook to restore" do
      site1 = create_site!()
      site2 = create_site!()

      other_js_hook =
        create_js_hook!(
          name: "Other JS Hook",
          content: "console.log('Other V1');",
          priority: 10,
          site_id: site2.id
        )

      # Update to create version
      other_js_hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('Other V2');"})
      |> Ash.update!(authorize?: false, tenant: site2.id)

      # Tenant from site1 cannot even get site2's JS hook
      # When using tenant context, they can't see other tenant's JS hooks
      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(JsHook, other_js_hook.id, authorize?: false, tenant: site1.id)
      end
    end

    test "cannot restore version of archived JS hook" do
      site = create_site!()

      js_hook =
        create_js_hook!(
          name: "Test JS Hook",
          content: "console.log('V1');",
          priority: 10,
          site_id: site.id
        )

      # Update to create version
      js_hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('V2');"})
      |> Ash.update!(authorize?: false, tenant: site.id)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, js_hook.id, tenant: site.id)

      assert version != nil

      # Archive the JS hook
      Ash.destroy!(js_hook, authorize?: false, tenant: site.id)

      # Get the archived JS hook
      archived_js_hook =
        Ash.get!(JsHook, js_hook.id, action: :get_archived, authorize?: false, tenant: site.id)

      # Try to restore version of archived JS hook
      assert {:error, %Ash.Error.Invalid{}} =
               archived_js_hook
               |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id})
               |> Ash.update(authorize?: false, tenant: site.id)
    end

    test "restored JS hook has correct attributes from version" do
      site = create_site!()

      js_hook =
        create_js_hook!(
          name: "Test JS Hook",
          content: "console.log('Original');",
          description: "Original description",
          priority: 10,
          active: true,
          site_id: site.id
        )

      # Update multiple times
      js_hook
      |> Ash.Changeset.for_update(:update, %{
        content: "console.log('Version 2');",
        description: "Version 2 description",
        priority: 20
      })
      |> Ash.update!(authorize?: false, tenant: site.id)

      js_hook
      |> Ash.Changeset.for_update(:update, %{
        content: "console.log('Version 3');",
        description: "Version 3 description",
        priority: 30
      })
      |> Ash.update!(authorize?: false, tenant: site.id)

      # Get first version (original)
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, js_hook.id, tenant: site.id)

      # Restore to first version
      js_hook_fresh = Ash.get!(JsHook, js_hook.id, authorize?: false, tenant: site.id)

      {:ok, restored} =
        js_hook_fresh
        |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
          authorize?: false
        )
        |> Ash.update(authorize?: false, tenant: site.id)

      assert restored.content == "console.log('Original');"
      assert restored.description == "Original description"
      assert restored.priority == 10
    end
  end

  describe "preview_version generic action" do
    # Note: preview_version is a generic action, not a read action
    # Use Ash.ActionInput.for_action instead of Ash.Query.for_read

    test "tenant user can preview their own tenant's JS hook version" do
      site = create_site!()

      tenant_js_hook =
        create_js_hook!(
          name: "Tenant Preview Own",
          content: "console.log('Own V1');",
          description: "Own V1",
          priority: 30,
          active: true,
          site_id: site.id
        )

      # Update to create version
      tenant_js_hook
      |> Ash.Changeset.for_update(:update, %{
        content: "console.log('Own V2');",
        description: "Own V2",
        priority: 35
      })
      |> Ash.Changeset.set_tenant(site.id)
      |> Ash.update!(authorize?: false)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, tenant_js_hook.id, tenant: site.id)

      assert version != nil

      # Tenant can preview their own JS hook version via generic action
      {:ok, preview} =
        JsHook
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            js_hook_id: tenant_js_hook.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert preview.id == tenant_js_hook.id
      # preview_version action returns restored values directly on the struct
      assert preview.content == "console.log('Own V1');"
      assert preview.description == "Own V1"
      assert preview.priority == 30
    end

    test "master_preview_version can preview any version" do
      site = create_site!()

      tenant_js_hook =
        create_js_hook!(
          name: "Tenant Preview Master",
          content: "console.log('Tenant V1');",
          description: "Tenant V1",
          priority: 20,
          active: true,
          site_id: site.id
        )

      # Update to create version
      tenant_js_hook
      |> Ash.Changeset.for_update(:update, %{
        content: "console.log('Tenant V2');",
        description: "Tenant V2",
        priority: 25
      })
      |> Ash.Changeset.set_tenant(site.id)
      |> Ash.update!(authorize?: false)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, tenant_js_hook.id, tenant: site.id)

      assert version != nil

      # Master can preview any version via master_preview_version action
      {:ok, preview} =
        JsHook
        |> Ash.ActionInput.for_action(
          :master_preview_version,
          %{
            js_hook_id: tenant_js_hook.id,
            version_id: version.id
          },
          authorize?: false
        )
        |> Ash.run_action(authorize?: false)

      assert preview.id == tenant_js_hook.id
      # master_preview_version action returns restored values directly on the struct
      assert preview.content == "console.log('Tenant V1');"
      assert preview.description == "Tenant V1"
      assert preview.priority == 20
    end

    test "preview_version loads correct version data from multiple versions" do
      site = create_site!()

      js_hook =
        create_js_hook!(
          name: "Version Test JS Hook",
          content: "console.log('Original');",
          description: "Original description",
          priority: 10,
          active: true,
          site_id: site.id
        )

      # Create multiple versions
      js_hook
      |> Ash.Changeset.for_update(:update, %{
        content: "console.log('Version 2');",
        description: "Version 2 description",
        priority: 20
      })
      |> Ash.Changeset.set_tenant(site.id)
      |> Ash.update!(authorize?: false)

      js_hook
      |> Ash.Changeset.for_update(:update, %{
        content: "console.log('Version 3');",
        description: "Version 3 description",
        priority: 30
      })
      |> Ash.Changeset.set_tenant(site.id)
      |> Ash.update!(authorize?: false)

      # Get first version (original)
      versions =
        versions(MishkaCmsCore.Runtime.JsHook.Version, js_hook.id, tenant: site.id)

      first_version = List.first(versions)

      # Preview first version
      {:ok, preview} =
        JsHook
        |> Ash.ActionInput.for_action(
          :preview_version,
          %{
            js_hook_id: js_hook.id,
            version_id: first_version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      # Verify preview data matches first version (restored values directly on the struct)
      assert preview.content == "console.log('Original');"
      assert preview.description == "Original description"
      assert preview.priority == 10

      # Verify current JS hook still has latest data
      current_js_hook = Ash.get!(JsHook, js_hook.id, authorize?: false, tenant: site.id)
      assert current_js_hook.content == "console.log('Version 3');"
      assert current_js_hook.description == "Version 3 description"
      assert current_js_hook.priority == 30
    end
  end

  describe "master_read action" do
    test "master_read returns all JS hooks system-wide" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      hook1 = create_js_hook!(name: "Hook 1", site_id: site1.id)
      hook2 = create_js_hook!(name: "Hook 2", site_id: site2.id)
      global_hook = create_js_hook!(name: "Global Hook", site_id: nil)

      # Master read (nil tenant) returns all hooks with pagination
      {:ok, %Ash.Page.Offset{results: result}} =
        JsHook
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read(authorize?: false)

      hook_ids = Enum.map(result, & &1.id)
      assert hook1.id in hook_ids
      assert hook2.id in hook_ids
      assert global_hook.id in hook_ids
    end

    test "master_read fails with tenant context" do
      site = create_site!()

      # master_read requires nil tenant context (require_master: true)
      assert {:error, %Ash.Error.Invalid{}} =
               JsHook
               |> Ash.Query.for_read(:master_read, %{}, tenant: site.id)
               |> Ash.read(authorize?: false)
    end
  end

  describe "master_unarchive action" do
    test "master_unarchive restores archived hook" do
      site = create_site!()
      hook = create_js_hook!(name: "Archived Hook", site_id: site.id)

      # Archive the hook first
      {:ok, archived_hook} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)
      assert not is_nil(archived_hook.archived_at)

      # Get the archived hook for master_unarchive
      archived_for_update =
        JsHook
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^archived_hook.id)
        |> Ash.read_one!(authorize?: false)

      # Master unarchive
      restored =
        archived_for_update
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update!()

      assert is_nil(restored.archived_at)
      assert restored.id == hook.id
    end

    test "master_unarchive restores global archived hook" do
      global_hook = create_js_hook!(name: "Global Archived", site_id: nil)

      # Archive using master_destroy
      {:ok, archived} =
        global_hook
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      assert not is_nil(archived.archived_at)

      # Get the archived hook for master_unarchive
      archived_for_update =
        JsHook
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.read_one!(authorize?: false)

      # Master unarchive
      {:ok, restored} =
        archived_for_update
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update()

      assert is_nil(restored.archived_at)
    end

    test "master_unarchive fails on non-archived hook" do
      site = create_site!()
      hook = create_js_hook!(name: "Active Hook", site_id: site.id)

      changeset =
        hook
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = Ash.update(changeset)
    end

    test "master_unarchive fails with tenant context" do
      site = create_site!()
      hook = create_js_hook!(name: "Test Hook", site_id: site.id)
      {:ok, archived} = Ash.destroy(hook, authorize?: false, return_destroyed?: true)

      # Get the archived hook
      archived_for_update =
        JsHook
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^archived.id)
        |> Ash.read_one!(authorize?: false)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               archived_for_update
               |> Ash.Changeset.for_update(:master_unarchive, %{}, tenant: site.id)
               |> Ash.update()
    end
  end

  describe "master_destroy action" do
    test "master_destroy archives a hook" do
      site = create_site!()
      hook = create_js_hook!(name: "To Archive", site_id: site.id)

      {:ok, archived} =
        hook
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      assert not is_nil(archived.archived_at)
      assert archived.id == hook.id
    end

    test "master_destroy can archive global hooks" do
      global_hook = create_js_hook!(name: "Global To Archive", site_id: nil)

      {:ok, archived} =
        global_hook
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      assert not is_nil(archived.archived_at)
    end

    test "master_destroy fails with tenant context" do
      site = create_site!()
      hook = create_js_hook!(name: "Test Hook", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               hook
               |> Ash.Changeset.for_destroy(:master_destroy, %{}, tenant: site.id)
               |> Ash.destroy()
    end
  end

  describe "master_permanent_destroy action" do
    test "master_permanent_destroy permanently deletes a hook" do
      site = create_site!()
      hook = create_js_hook!(name: "To Delete", site_id: site.id)
      hook_id = hook.id

      hook
      |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Verify it's really gone (NotFound is wrapped in Invalid)
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.get(JsHook, hook_id, action: :get_any, authorize?: false)
    end

    test "master_permanent_destroy can delete global hooks" do
      global_hook = create_js_hook!(name: "Global To Delete", site_id: nil)
      hook_id = global_hook.id

      global_hook
      |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Verify it's really gone (NotFound is wrapped in Invalid)
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.get(JsHook, hook_id, action: :get_any, authorize?: false)
    end

    test "master_permanent_destroy fails with tenant context" do
      site = create_site!()
      hook = create_js_hook!(name: "Test Hook", site_id: site.id)

      # Note: authorize? must not be false for TenantContext validation to trigger
      assert {:error, %Ash.Error.Invalid{}} =
               hook
               |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, tenant: site.id)
               |> Ash.destroy()
    end
  end

  describe "restore_version_api action" do
    test "restore_version_api restores tenant's own hook version" do
      site = create_site!()

      hook =
        create_js_hook!(
          name: "API Restore Test",
          content: "console.log('V1');",
          site_id: site.id
        )

      # Update to create version
      hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('V2');"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, hook.id, tenant: site.id)

      assert version != nil

      # Restore via API action
      {:ok, restored} =
        JsHook
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{
            id: hook.id,
            version_id: version.id
          },
          tenant: site.id
        )
        |> Ash.run_action(authorize?: false)

      assert restored.content == "console.log('V1');"
    end

    test "restore_version_api fails for global hooks (tenant cannot modify)" do
      site = create_site!()

      global_hook =
        create_js_hook!(
          name: "Global API Test",
          content: "console.log('Global V1');",
          site_id: nil
        )

      # Update global hook using master_update
      global_hook
      |> Ash.Changeset.for_update(:master_update, %{content: "console.log('Global V2');"},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      # Get version
      version =
        first_version(MishkaCmsCore.Runtime.JsHook.Version, global_hook.id)

      assert version != nil

      # Tenant cannot restore global hook via API
      assert {:error, %Ash.Error.Invalid{}} =
               JsHook
               |> Ash.ActionInput.for_action(
                 :restore_version_api,
                 %{
                   id: global_hook.id,
                   version_id: version.id
                 },
                 tenant: site.id
               )
               |> Ash.run_action(authorize?: false)
    end

    test "restore_version_api fails without tenant context" do
      site = create_site!()
      hook = create_js_hook!(name: "Test", content: "test", site_id: site.id)

      # No tenant context
      assert {:error, %Ash.Error.Invalid{}} =
               JsHook
               |> Ash.ActionInput.for_action(:restore_version_api, %{
                 id: hook.id,
                 version_id: Ash.UUID.generate()
               })
               |> Ash.run_action(authorize?: false)
    end
  end

  describe "archived read actions" do
    setup do
      site = create_site!()
      active_hook = create_js_hook!(name: "Active", site_id: site.id)

      archived_hook = create_js_hook!(name: "Archived", site_id: site.id)

      {:ok, archived_hook} =
        Ash.destroy(archived_hook, authorize?: false, return_destroyed?: true)

      global_archived = create_js_hook!(name: "Global Archived", site_id: nil)

      {:ok, global_archived} =
        global_archived
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy(return_destroyed?: true)

      %{
        site: site,
        active_hook: active_hook,
        archived_hook: archived_hook,
        global_archived: global_archived
      }
    end

    test "get_archived retrieves single archived hook for tenant", %{
      site: site,
      archived_hook: archived_hook
    } do
      {:ok, found} =
        JsHook
        |> Ash.Query.for_read(:get_archived, %{}, tenant: site.id)
        |> Ash.Query.filter(id == ^archived_hook.id)
        |> Ash.read_one(authorize?: false)

      assert found.id == archived_hook.id
    end

    test "get_archived does not return active hooks", %{site: site, active_hook: active_hook} do
      {:ok, result} =
        JsHook
        |> Ash.Query.for_read(:get_archived, %{}, tenant: site.id)
        |> Ash.Query.filter(id == ^active_hook.id)
        |> Ash.read_one(authorize?: false)

      assert is_nil(result)
    end

    test "master_get_archived retrieves any archived hook", %{global_archived: global_archived} do
      {:ok, found} =
        JsHook
        |> Ash.Query.for_read(:master_get_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id == ^global_archived.id)
        |> Ash.read_one(authorize?: false)

      assert found.id == global_archived.id
    end

    test "archived lists archived hooks for tenant", %{site: site, archived_hook: archived_hook} do
      {:ok, %Ash.Page.Offset{results: result}} =
        JsHook
        |> Ash.Query.for_read(:archived, %{}, tenant: site.id)
        |> Ash.read(authorize?: false)

      hook_ids = Enum.map(result, & &1.id)
      assert archived_hook.id in hook_ids
    end

    test "master_archived lists all archived hooks system-wide", %{
      archived_hook: archived_hook,
      global_archived: global_archived
    } do
      {:ok, %Ash.Page.Offset{results: result}} =
        JsHook
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.read(authorize?: false)

      hook_ids = Enum.map(result, & &1.id)
      assert archived_hook.id in hook_ids
      assert global_archived.id in hook_ids
    end

    test "master_archived fails with tenant context", %{site: site} do
      assert {:error, %Ash.Error.Invalid{}} =
               JsHook
               |> Ash.Query.for_read(:master_archived, %{}, tenant: site.id)
               |> Ash.read(authorize?: false)
    end
  end

  describe "version read actions" do
    setup do
      site = create_site!()

      hook =
        create_js_hook!(
          name: "Version Test Hook",
          content: "console.log('V1');",
          site_id: site.id
        )

      # Create versions
      hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('V2');"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      hook
      |> Ash.Changeset.for_update(:update, %{content: "console.log('V3');"}, tenant: site.id)
      |> Ash.update!(authorize?: false)

      # Get all versions
      versions =
        versions(MishkaCmsCore.Runtime.JsHook.Version, hook.id, tenant: site.id)

      assert length(versions) >= 2

      %{site: site, hook: hook, versions: versions}
    end

    test "get_with_versions retrieves hook with sorted versions", %{site: site, hook: hook} do
      {:ok, found} =
        JsHook
        |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10, versions_offset: 0},
          tenant: site.id
        )
        |> Ash.Query.filter(id == ^hook.id)
        |> Ash.read_one(authorize?: false)

      assert found.id == hook.id
      assert is_list(found.sorted_versions)
      assert length(found.sorted_versions) >= 2
    end

    test "master_get_with_versions retrieves any hook with versions", %{hook: hook} do
      {:ok, found} =
        JsHook
        |> Ash.Query.for_read(
          :master_get_with_versions,
          %{versions_limit: 10, versions_offset: 0},
          authorize?: false
        )
        |> Ash.Query.filter(id == ^hook.id)
        |> Ash.read_one(authorize?: false)

      assert found.id == hook.id
      assert is_list(found.sorted_versions)
    end

    test "master_get_with_versions fails with tenant context", %{site: site, hook: hook} do
      # master_get_with_versions requires nil tenant (require_master: true)
      assert {:error, %Ash.Error.Invalid{}} =
               JsHook
               |> Ash.Query.for_read(
                 :master_get_with_versions,
                 %{
                   versions_limit: 10,
                   versions_offset: 0
                 },
                 tenant: site.id
               )
               |> Ash.Query.filter(id == ^hook.id)
               |> Ash.read_one(authorize?: false)
    end

    test "list_versions returns hook with sorted versions", %{site: site, hook: hook} do
      {:ok, %Ash.Page.Offset{results: result}} =
        JsHook
        |> Ash.Query.for_read(:list_versions, %{js_hook_id: hook.id}, tenant: site.id)
        |> Ash.read(authorize?: false)

      assert length(result) == 1
      found = List.first(result)
      assert found.id == hook.id
      assert is_list(found.sorted_versions)
    end

    test "list_versions returns empty for global hooks due to multitenancy filtering", %{
      site: site
    } do
      # list_versions doesn't have multitenancy :bypass, so tenant query won't find global hooks
      global_hook = create_js_hook!(name: "Global Versions", content: "global", site_id: nil)

      # Create version using master_update
      global_hook
      |> Ash.Changeset.for_update(:master_update, %{content: "global v2"}, authorize?: false)
      |> Ash.update!(authorize?: false)

      # Verify version was created
      global_versions =
        versions(MishkaCmsCore.Runtime.JsHook.Version, global_hook.id)

      assert length(global_versions) >= 1

      # Tenant list_versions returns empty for global hooks (multitenancy filtering)
      # To access global hook versions, use master_list_versions
      {:ok, %Ash.Page.Offset{results: result}} =
        JsHook
        |> Ash.Query.for_read(:list_versions, %{js_hook_id: global_hook.id}, tenant: site.id)
        |> Ash.read(authorize?: false)

      # Global hooks are not returned due to multitenancy filtering on list_versions
      assert length(result) == 0

      # Master can access global hook versions
      {:ok, %Ash.Page.Offset{results: master_result}} =
        JsHook
        |> Ash.Query.for_read(:master_list_versions, %{js_hook_id: global_hook.id},
          authorize?: false
        )
        |> Ash.read(authorize?: false)

      assert length(master_result) == 1
      found = List.first(master_result)
      assert found.id == global_hook.id
    end

    test "master_list_versions returns any hook with sorted versions", %{hook: hook} do
      {:ok, %Ash.Page.Offset{results: result}} =
        JsHook
        |> Ash.Query.for_read(:master_list_versions, %{js_hook_id: hook.id}, authorize?: false)
        |> Ash.read(authorize?: false)

      assert length(result) == 1
      found = List.first(result)
      assert found.id == hook.id
      assert is_list(found.sorted_versions)
    end

    test "master_list_versions fails with tenant context", %{site: site, hook: hook} do
      # master_list_versions requires nil tenant (require_master: true)
      assert {:error, %Ash.Error.Invalid{}} =
               JsHook
               |> Ash.Query.for_read(:master_list_versions, %{js_hook_id: hook.id},
                 tenant: site.id
               )
               |> Ash.read(authorize?: false)
    end
  end
end
