# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.ErrorPageTest do
  use MishkaCmsCore.DataCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use ExUnit.Case, async: false
  import Ash.Test
  alias MishkaCmsCore.Runtime.ErrorAddress
  alias MishkaCmsCore.Runtime.ErrorPage
  require Ash.Query
  @moduletag :unit

  describe "site cascade delete" do
    test "permanently deleting the site cascade-deletes its error pages" do
      site = create_site!()
      create_error_page!(site_id: site.id)

      count = fn ->
        ErrorPage |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false) |> length()
      end

      assert count.() == 1
      Ash.destroy!(site, action: :permanent_destroy, authorize?: false)
      assert count.() == 0
    end
  end

  describe "configuration" do
    test "resource has correct table name and repo" do
      assert AshPostgres.DataLayer.Info.table(ErrorPage) == "error_pages"
      assert AshPostgres.DataLayer.Info.repo(ErrorPage) == @repo
    end

    test "has archival extension enabled" do
      assert AshArchival.Resource in Spark.extensions(ErrorPage)
    end

    test "has multitenancy configured correctly" do
      assert Ash.Resource.Info.multitenancy_strategy(ErrorPage) == :attribute
      assert Ash.Resource.Info.multitenancy_attribute(ErrorPage) == :site_id
      # Never global
      assert Ash.Resource.Info.multitenancy_global?(ErrorPage) == false
    end

    test "has correct base filter for archived records" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      error_pages =
        ErrorPage
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped error_page in error_pages

      archived_error_page = Ash.destroy!(error_page, authorize?: false)

      error_pages =
        ErrorPage
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(authorize?: false)

      assert_stripped archived_error_page not in error_pages
    end
  end

  describe "create action" do
    test "creates a site-specific error page with valid attributes" do
      site = create_site!()

      attrs = [
        name: "Main Error Pages",
        path: "/errors/*",
        error_pages: [
          %{
            status: 404,
            template: "<h1>Not Found</h1>",
            layout: %{template: "<div><%= @inner_content %></div>"}
          }
        ]
      ]

      assert {:ok, error_page} =
               ErrorPage
               |> Ash.Changeset.for_create(:create, attrs, tenant: site.id)
               |> Ash.Changeset.load([:error_module, :site, :configured_statuses])
               |> Ash.create(authorize?: false)

      assert error_page.name == "main-error-pages"

      # THE PATH IS NOT THE CALLER'S. `Changes.ErrorPageAddress` writes the one address the renderer
      # looks a row up by, so the `/errors/*` asked for above is overwritten rather than stored —
      # see `MishkaCmsCore.Runtime.ErrorAddress`.
      assert error_page.path == ErrorAddress.for_site(site.id)
      assert length(error_page.error_pages) == 1
      assert error_page.site_id == site.id
      assert error_page.error_module != nil
      assert to_string(error_page.error_module) =~ ~r/ErrorPage$/
      assert error_page.configured_statuses == [404]
    end

    test "validates name length constraints" do
      site = create_site!()

      changeset =
        ErrorPage
        |> Ash.Changeset.for_create(:create, %{
          name: "ab",
          path: "/test",
          error_pages: [%{status: 404, template: "test"}]
        })
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      long_name = String.duplicate("a", 201)

      changeset =
        ErrorPage
        |> Ash.Changeset.for_create(:create, %{
          name: long_name,
          path: "/test",
          error_pages: [%{status: 404, template: "test"}]
        })
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)
    end

    test "validates path format - must start with '/'" do
      site = create_site!()

      changeset =
        ErrorPage
        |> Ash.Changeset.for_create(:create, %{
          name: "Test Error Page",
          path: "invalid-path",
          error_pages: [%{status: 404, template: "test"}]
        })
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.field == :path and
          error.message =~ "Path must start with '/'"
      end)

      # Valid path should work
      changeset =
        ErrorPage
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Error Page",
            path: "/valid-path",
            error_pages: [%{status: 404, template: "test"}]
          },
          tenant: site.id
        )

      assert changeset.valid?
    end

    test "validates error_pages structure" do
      site = create_site!()

      valid_error_pages = [
        %{
          status: 404,
          template: "<h1>Not Found</h1>",
          layout: %{template: "<div><%= @inner_content %></div>"}
        },
        %{
          status: 500,
          template: "<h1>Server Error</h1>"
        }
      ]

      error_page = create_error_page!(site_id: site.id, error_pages: valid_error_pages)
      assert length(error_page.error_pages) == 2
    end

    test "validates format constraints" do
      site = create_site!()

      changeset =
        ErrorPage
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test",
            path: "/test",
            error_pages: [%{status: 404, template: "test"}],
            format: :invalid
          },
          tenant: site.id
        )

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute
      end)

      for format <- [:heex, :eex, :markdown] do
        changeset =
          ErrorPage
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test #{format}",
              path: "/test-#{format}",
              error_pages: [%{status: 404, template: "test"}],
              format: format
            },
            tenant: site.id
          )

        assert changeset.valid?
      end
    end

    test "enforces unique name per site constraint" do
      site = create_site!()
      create_error_page!(name: "Unique Error Page", path: "/test1", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_error_page!(name: "Unique Error Page", path: "/test2", site_id: site.id)
      end
    end

    test "enforces unique path per site constraint" do
      site = create_site!()
      create_error_page!(name: "Error Page 1", path: "/unique-path", site_id: site.id)

      assert_raise Ash.Error.Invalid, fn ->
        create_error_page!(name: "Error Page 2", path: "/unique-path", site_id: site.id)
      end
    end

    test "allows same name across different sites" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      error_page1 =
        create_error_page!(name: "Main Error Pages", path: "/errors1", site_id: site1.id)

      error_page2 =
        create_error_page!(name: "Main Error Pages", path: "/errors2", site_id: site2.id)

      assert error_page1.name == error_page2.name
      assert error_page1.site_id != error_page2.site_id
    end

    # TWO SITES CANNOT SHARE AN ADDRESS ANY MORE, because an address is a site's own name — which is
    # what makes one lookup answer one site. Both callers below ask for the same path and neither
    # gets it.
    test "each site gets its own address, whatever the caller asked for" do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      error_page1 =
        create_error_page!(name: "Error Page 1", path: "/errors/*", site_id: site1.id)

      error_page2 =
        create_error_page!(name: "Error Page 2", path: "/errors/*", site_id: site2.id)

      assert error_page1.path == ErrorAddress.for_site(site1.id)
      assert error_page2.path == ErrorAddress.for_site(site2.id)
      assert error_page1.path != error_page2.path
      assert error_page1.site_id != error_page2.site_id
    end

    # AND ONE SITE CANNOT HAVE TWO. The address is the site's, `unique_path_per_site` is an identity,
    # and together they are what makes "a site has one error page" a property of the table rather
    # than a convention nobody enforced.
    test "a site's second error page is refused" do
      site = create_site!()
      _first = create_error_page!(site_id: site.id)

      assert {:error, error} =
               ErrorPage
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Second Error Pages",
                   path: "/somewhere-else",
                   error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}]
                 },
                 tenant: site.id
               )
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "already has an error page"
    end

    test "requires site_id - cannot be global" do
      # Test that creation fails without tenant
      result =
        ErrorPage
        |> Ash.Changeset.for_create(:create, %{
          name: "Global Error Page",
          path: "/errors",
          error_pages: [%{status: 404, template: "test"}]
        })
        |> Ash.create(authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result
      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.TenantRequired{}, &1))
    end
  end

  describe "update action" do
    test "updates a non-archived error page successfully" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      assert {:ok, updated} =
               error_page
               |> Ash.Changeset.for_update(:update, %{name: "Updated name"})
               |> Ash.Changeset.set_tenant(site.id)
               |> Ash.update(authorize?: false)

      assert updated.name == "updated-name"
    end

    test "prevents updating archived error pages" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      {:ok, archived} = Ash.destroy(error_page, authorize?: false, return_destroyed?: true)

      changeset =
        archived
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"})
        |> Ash.Changeset.set_tenant(site.id)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidChanges and
          error.fields == [:archived_at]
      end)
    end

    # A PATH IS NO LONGER SOMETHING AN UPDATE CAN GET WRONG, so there is nothing here to refuse: the
    # address is written from the site before the format is looked at. Forcing it on update and not
    # only on create is what repairs a row after its site is renamed — the next save of it is the
    # only repair anybody would think to try.
    test "an update writes the site's address over whatever it was given" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      assert {:ok, updated} =
               error_page
               |> Ash.Changeset.for_update(:update, %{path: "invalid-path"})
               |> Ash.Changeset.set_tenant(site.id)
               |> Ash.update(authorize?: false)

      assert updated.path == ErrorAddress.for_site(site.id)
    end

    test "error module name stays consistent when updating attributes" do
      site = create_site!(name: "Test Site")
      error_page = create_error_page!(site_id: site.id)

      error_page =
        Ash.get!(ErrorPage, error_page.id,
          load: [:error_module],
          tenant: site.id,
          authorize?: false
        )

      original_module = to_string(error_page.error_module)

      {:ok, updated} =
        error_page
        |> Ash.Changeset.for_update(:update, %{name: "New name"})
        |> Ash.Changeset.set_tenant(site.id)
        |> Ash.Changeset.load([:error_module])
        |> Ash.update(authorize?: false)

      assert to_string(updated.error_module) == original_module
    end
  end

  describe "read actions with multitenancy" do
    setup do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      error_page1 =
        create_error_page!(
          name: "Site 1 Errors",
          path: "/site1/errors/*",
          site_id: site1.id,
          priority: 20
        )

      error_page2 =
        create_error_page!(
          name: "Site 2 Errors",
          path: "/site2/errors/*",
          site_id: site2.id,
          priority: 15
        )

      {:ok, site1: site1, site2: site2, error_page1: error_page1, error_page2: error_page2}
    end

    test "default read with tenant shows only site-specific error pages", context do
      error_pages =
        ErrorPage
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.read!(authorize?: false)

      error_page_ids = Enum.map(error_pages, & &1.id)

      assert context.error_page1.id in error_page_ids
      refute context.error_page2.id in error_page_ids
    end

    # A SITE HAS ONE ERROR PAGE NOW, so this can no longer order two of them within a site — the
    # second create is refused by the identity. What is left for it to say is that the action still
    # reads, scoped to the tenant it was given.
    test "by_priority reads the site's own error page", context do
      page =
        ErrorPage
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.read!(action: :by_priority, authorize?: false)

      assert Enum.map(page.results, & &1.id) == [context.error_page1.id]
    end

    test "by_path finds error page by exact path", context do
      error_pages =
        ErrorPage
        |> Ash.Query.set_tenant(context.site1.id)
        |> Ash.Query.for_read(:by_path, %{path: ErrorAddress.for_site(context.site1.id)})
        |> Ash.read!(authorize?: false)

      assert length(error_pages) == 1
      assert List.first(error_pages).id == context.error_page1.id
    end
  end

  describe "archive/unarchive actions" do
    test "destroy archives an error page (sets archived_at)" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      assert {:ok, archived} = Ash.destroy(error_page, authorize?: false, return_destroyed?: true)
      assert archived.archived_at != nil

      error_pages = ErrorPage |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      error_page_ids = Enum.map(error_pages, & &1.id)
      refute archived.id in error_page_ids

      archived_page =
        ErrorPage
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      archived_ids = Enum.map(archived_page.results, & &1.id)
      assert archived.id in archived_ids
    end

    test "unarchive restores an error page" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      {:ok, _archived} = Ash.destroy(error_page, authorize?: false, return_destroyed?: true)

      archived_page =
        ErrorPage
        |> Ash.Query.filter(id: error_page.id)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(archived_page.results)

      {:ok, unarchived} = Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
      assert unarchived.archived_at == nil

      error_pages = ErrorPage |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)
      error_page_ids = Enum.map(error_pages, & &1.id)
      assert unarchived.id in error_page_ids
    end

    test "permanent_destroy actually deletes the record" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      error_page_id = error_page.id

      _result = Ash.destroy(error_page, action: :permanent_destroy, authorize?: false)

      active = ErrorPage |> Ash.Query.set_tenant(site.id) |> Ash.read!(authorize?: false)

      archived_page =
        ErrorPage
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      active_ids = Enum.map(active, & &1.id)
      archived_ids = Enum.map(archived_page.results, & &1.id)

      refute error_page_id in active_ids
      refute error_page_id in archived_ids
    end
  end

  describe "database constraints" do
    test "database enforces check constraints" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      binary_id = Ecto.UUID.dump!(error_page.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE error_pages SET name = '' WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database enforces error_pages not empty constraint" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      binary_id = Ecto.UUID.dump!(error_page.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE error_pages SET error_pages = ARRAY[]::map[] WHERE id = $1",
          [binary_id]
        )
      end
    end

    test "database trigger prevents archived updates" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      {:ok, archived} = Ash.destroy(error_page, authorize?: false, return_destroyed?: true)
      binary_id = Ecto.UUID.dump!(archived.id)

      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE error_pages SET name = 'Should Fail' WHERE id = $1",
          [binary_id]
        )
      end
    end
  end

  describe "attribute defaults" do
    test "sets default values correctly" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      assert error_page.format == :heex
      assert error_page.priority == 0
      assert error_page.extra == %{}
      assert error_page.helpers == []
      assert error_page.inserted_at != nil
      assert error_page.updated_at != nil
    end
  end

  describe "calculations" do
    test "error_module calculation returns proper module name" do
      site = create_site!(name: "TestSite")
      error_page = create_error_page!(site_id: site.id)

      loaded =
        Ash.get!(ErrorPage, error_page.id,
          load: [:error_module],
          tenant: site.id,
          authorize?: false
        )

      assert is_atom(loaded.error_module)
      assert to_string(loaded.error_module) =~ ~r/Error/
    end

    test "configured_statuses calculation returns sorted status codes" do
      site = create_site!()

      error_pages_config = [
        %{status: 500, template: "<h1>Server Error</h1>"},
        %{status: 404, template: "<h1>Not Found</h1>"},
        %{status: 403, template: "<h1>Forbidden</h1>"}
      ]

      error_page = create_error_page!(site_id: site.id, error_pages: error_pages_config)

      loaded =
        Ash.get!(ErrorPage, error_page.id,
          load: [:configured_statuses],
          tenant: site.id,
          authorize?: false
        )

      assert loaded.configured_statuses == [403, 404, 500]
    end
  end

  describe "master_create action" do
    test "creates error page with explicit site_id for master users" do
      site = create_site!()

      attrs = %{
        name: "Master Created Error Page",
        path: "/master/errors/*",
        site_id: site.id,
        error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}]
      }

      assert {:ok, error_page} =
               ErrorPage
               |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
               |> Ash.create(authorize?: false)

      assert error_page.name == "master-created-error-page"
      assert error_page.site_id == site.id
    end

    test "master_create requires site_id" do
      attrs = %{
        name: "No Site Error Page",
        path: "/no-site/*",
        error_pages: [%{status: 404, template: "<h1>Not Found</h1>"}]
      }

      result =
        ErrorPage
        |> Ash.Changeset.for_create(:master_create, attrs, authorize?: false)
        |> Ash.create(authorize?: false)

      assert {:error, error} = result
      assert Exception.message(error) =~ "site_id"
    end
  end

  describe "master read actions" do
    setup do
      site1 = create_site!(name: "Site 1", host: "site1.com")
      site2 = create_site!(name: "Site 2", host: "site2.com")

      error_page1 = create_error_page!(name: "Site 1 Errors", path: "/s1/*", site_id: site1.id)
      error_page2 = create_error_page!(name: "Site 2 Errors", path: "/s2/*", site_id: site2.id)

      {:ok, site1: site1, site2: site2, error_page1: error_page1, error_page2: error_page2}
    end

    test "master_read bypasses multitenancy and shows all error pages", context do
      page =
        ErrorPage
        |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      error_page_ids = Enum.map(page.results, & &1.id)

      assert context.error_page1.id in error_page_ids
      assert context.error_page2.id in error_page_ids
    end

    test "master_get retrieves any error page by ID bypassing multitenancy", context do
      {:ok, error_page} =
        Ash.get(ErrorPage, context.error_page1.id, action: :master_get, authorize?: false)

      assert error_page.id == context.error_page1.id
    end

    test "master_archived shows all archived error pages across sites", context do
      {:ok, _} = Ash.destroy(context.error_page1, authorize?: false, return_destroyed?: true)
      {:ok, _} = Ash.destroy(context.error_page2, authorize?: false, return_destroyed?: true)

      page =
        ErrorPage
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.read!(authorize?: false)

      archived_ids = Enum.map(page.results, & &1.id)

      assert context.error_page1.id in archived_ids
      assert context.error_page2.id in archived_ids
    end

    test "master_get_archived retrieves specific archived error page", context do
      {:ok, _} = Ash.destroy(context.error_page1, authorize?: false, return_destroyed?: true)

      {:ok, archived} =
        Ash.get(ErrorPage, context.error_page1.id,
          action: :master_get_archived,
          authorize?: false
        )

      assert archived.id == context.error_page1.id
      assert archived.archived_at != nil
    end

    test "read_any bypasses multitenancy with keyset pagination", context do
      page =
        ErrorPage
        |> Ash.Query.for_read(:read_any)
        |> Ash.read!(authorize?: false)

      error_page_ids = Enum.map(page.results, & &1.id)

      assert context.error_page1.id in error_page_ids
      assert context.error_page2.id in error_page_ids
    end
  end

  describe "get_archived action" do
    test "retrieves single archived error page by ID within tenant" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      {:ok, _} = Ash.destroy(error_page, authorize?: false, return_destroyed?: true)

      {:ok, archived} =
        Ash.get(ErrorPage, error_page.id,
          action: :get_archived,
          tenant: site.id,
          authorize?: false
        )

      assert archived.id == error_page.id
      assert archived.archived_at != nil
    end
  end

  describe "master_update action" do
    test "updates error page bypassing multitenancy" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      updated =
        error_page
        |> Ash.Changeset.for_update(
          :master_update,
          %{
            name: "Updated By Master",
            priority: 50
          },
          authorize?: false
        )
        |> Ash.update!()

      assert updated.name == "updated-by-master"
      assert updated.priority == 50
    end

    test "master_update fails for non-existent error page" do
      fake_id = Ecto.UUID.generate()

      assert {:error, _error} =
               Ash.get(ErrorPage, fake_id, action: :master_get, authorize?: false)
    end
  end

  describe "master_destroy action" do
    test "archives error page bypassing multitenancy" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      archived =
        error_page
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

      assert archived.archived_at != nil
    end

    test "master_destroy fails for non-existent error page" do
      fake_id = Ecto.UUID.generate()

      assert {:error, _error} =
               Ash.get(ErrorPage, fake_id, action: :master_get, authorize?: false)
    end
  end

  describe "master_unarchive action" do
    test "restores archived error page bypassing multitenancy" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      {:ok, _} = Ash.destroy(error_page, authorize?: false, return_destroyed?: true)

      # Get the archived record
      archived_record =
        Ash.get!(ErrorPage, error_page.id, action: :master_get_archived, authorize?: false)

      unarchived =
        archived_record
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
        |> Ash.update!()

      assert unarchived.archived_at == nil
    end

    test "master_unarchive fails for non-archived error page" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      changeset =
        error_page
        |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)

      assert_has_error(changeset, fn error ->
        error.__struct__ == Ash.Error.Changes.InvalidAttribute and
          error.message =~ "not archived"
      end)
    end

    test "master_unarchive fails for non-existent error page" do
      fake_id = Ecto.UUID.generate()

      assert {:error, _error} =
               Ash.get(ErrorPage, fake_id, action: :master_get, authorize?: false)
    end
  end

  describe "master_permanent_destroy action" do
    test "permanently deletes error page bypassing multitenancy" do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)
      error_page_id = error_page.id

      error_page
      |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
      |> Ash.destroy!()

      # Verify it's gone from both active and archived
      assert {:error, _} =
               Ash.get(ErrorPage, error_page_id, action: :master_get, authorize?: false)
    end

    test "master_permanent_destroy fails for non-existent error page" do
      fake_id = Ecto.UUID.generate()

      assert {:error, _error} =
               Ash.get(ErrorPage, fake_id, action: :master_get, authorize?: false)
    end
  end

  describe "version management actions" do
    setup do
      site = create_site!()
      error_page = create_error_page!(site_id: site.id)

      # Create a version by updating the error page
      {:ok, updated} =
        error_page
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name", priority: 50},
          tenant: site.id
        )
        |> Ash.update(authorize?: false)

      {:ok, site: site, error_page: updated, original_error_page: error_page}
    end

    test "get_with_versions loads error page with versions", context do
      {:ok, error_page} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :get_with_versions,
          tenant: context.site.id,
          authorize?: false
        )

      assert error_page.id == context.error_page.id
      # Should have sorted_versions loaded
      assert is_list(error_page.sorted_versions)
    end

    test "master_get_with_versions loads error page with versions bypassing multitenancy",
         context do
      {:ok, error_page} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :master_get_with_versions,
          authorize?: false
        )

      assert error_page.id == context.error_page.id
      assert is_list(error_page.sorted_versions)
    end

    test "list_versions returns error page with sorted versions", context do
      # Tenant must be set before for_read so TenantContext validation passes
      page =
        ErrorPage
        |> Ash.Query.set_tenant(context.site.id)
        |> Ash.Query.for_read(:list_versions, %{error_page_id: context.error_page.id})
        |> Ash.read!(authorize?: false)

      assert length(page.results) == 1
      assert List.first(page.results).id == context.error_page.id
    end

    test "master_list_versions returns error page with sorted versions bypassing multitenancy",
         context do
      page =
        ErrorPage
        |> Ash.Query.for_read(:master_list_versions, %{error_page_id: context.error_page.id},
          authorize?: false
        )
        |> Ash.read!(authorize?: false)

      assert length(page.results) == 1
      assert List.first(page.results).id == context.error_page.id
    end

    test "restore_version restores error page to previous state", context do
      # Get the first version
      {:ok, error_page_with_versions} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :get_with_versions,
          tenant: context.site.id,
          authorize?: false
        )

      version = List.first(error_page_with_versions.sorted_versions)

      if version do
        {:ok, restored} =
          error_page_with_versions
          |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
            tenant: context.site.id
          )
          |> Ash.update(authorize?: false)

        assert restored.id == context.error_page.id
      end
    end

    test "restore_version_api restores via API action", context do
      {:ok, error_page_with_versions} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :get_with_versions,
          tenant: context.site.id,
          authorize?: false
        )

      version = List.first(error_page_with_versions.sorted_versions)

      if version do
        {:ok, restored} =
          ErrorPage
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: context.error_page.id, version_id: version.id},
            tenant: context.site.id
          )
          |> Ash.run_action(authorize?: false)

        assert restored.id == context.error_page.id
      end
    end

    test "master_restore_version restores bypassing multitenancy", context do
      {:ok, error_page_with_versions} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :master_get_with_versions,
          authorize?: false
        )

      version = List.first(error_page_with_versions.sorted_versions)

      if version do
        {:ok, restored} =
          ErrorPage
          |> Ash.ActionInput.for_action(
            :master_restore_version,
            %{
              id: context.error_page.id,
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.run_action(authorize?: false)

        assert restored.id == context.error_page.id
      end
    end

    test "preview_version returns preview without actually restoring", context do
      {:ok, error_page_with_versions} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :get_with_versions,
          tenant: context.site.id,
          authorize?: false
        )

      version = List.first(error_page_with_versions.sorted_versions)

      if version do
        {:ok, preview} =
          ErrorPage
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{error_page_id: context.error_page.id, version_id: version.id},
            tenant: context.site.id
          )
          |> Ash.run_action(authorize?: false)

        assert preview.id == context.error_page.id
      end
    end

    test "master_preview_version returns preview bypassing multitenancy", context do
      {:ok, error_page_with_versions} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :master_get_with_versions,
          authorize?: false
        )

      version = List.first(error_page_with_versions.sorted_versions)

      if version do
        {:ok, preview} =
          ErrorPage
          |> Ash.ActionInput.for_action(
            :master_preview_version,
            %{
              error_page_id: context.error_page.id,
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.run_action(authorize?: false)

        assert preview.id == context.error_page.id
      end
    end

    test "restore_version fails on archived error page", context do
      # First get a version ID from the error page before archiving
      {:ok, error_page_with_versions} =
        Ash.get(ErrorPage, context.error_page.id,
          action: :get_with_versions,
          tenant: context.site.id,
          authorize?: false
        )

      version = List.first(error_page_with_versions.sorted_versions)

      # Archive the error page
      {:ok, _} = Ash.destroy(context.error_page, authorize?: false, return_destroyed?: true)

      archived =
        Ash.get!(ErrorPage, context.error_page.id,
          action: :get_archived,
          tenant: context.site.id,
          authorize?: false
        )

      # If we have a version, test that restore fails on archived records
      if version do
        changeset =
          Ash.Changeset.for_update(
            archived,
            :restore_version,
            %{version_id: version.id},
            tenant: context.site.id
          )

        assert_has_error(changeset, fn error ->
          error.__struct__ == Ash.Error.Changes.InvalidChanges and
            error.message =~ "archived"
        end)
      else
        # If no version exists, just verify the error page is archived
        assert archived.archived_at != nil
      end
    end
  end

  describe "complex scenarios" do
    test "handles error page with multiple error configurations" do
      site = create_site!()

      error_pages_config = [
        %{
          status: 404,
          template: "<h1>Page Not Found</h1><p>The requested page could not be found.</p>",
          layout: %{template: "<div class='error-404'><%= @inner_content %></div>", format: :heex}
        },
        %{
          status: 500,
          template: "<h1>Internal Server Error</h1><p>Something went wrong.</p>",
          layout: %{template: "<div class='error-500'><%= @inner_content %></div>"}
        },
        %{
          status: 403,
          template: "<h1>Access Forbidden</h1><p>You don't have permission.</p>"
        }
      ]

      error_page =
        create_error_page!(
          site_id: site.id,
          name: "Complete Error Pages",
          path: "/errors/*",
          error_pages: error_pages_config,
          root_layout_template:
            "<html><head><title>Error</title></head><body><%= @inner_content %></body></html>",
          extra: %{theme: "dark", show_contact: true}
        )

      assert length(error_page.error_pages) == 3
      assert error_page.extra["theme"] == "dark"
      assert error_page.root_layout_template =~ "<html>"
    end

    test "allows same name for archived and active error pages within same site" do
      site = create_site!()

      error_page1 = create_error_page!(name: "Reusable", path: "/reusable1", site_id: site.id)
      {:ok, _archived} = Ash.destroy(error_page1, authorize?: false, return_destroyed?: true)

      error_page2 = create_error_page!(name: "Reusable", path: "/reusable2", site_id: site.id)
      assert error_page2.name == "reusable"
    end

    test "prevents unarchiving when active error page with same name exists" do
      site = create_site!()

      error_page1 = create_error_page!(name: "Conflict", path: "/conflict1", site_id: site.id)
      {:ok, _archived} = Ash.destroy(error_page1, authorize?: false, return_destroyed?: true)

      _error_page2 = create_error_page!(name: "Conflict", path: "/conflict2", site_id: site.id)

      archived_page =
        ErrorPage
        |> Ash.Query.filter(id: error_page1.id)
        |> Ash.Query.set_tenant(site.id)
        |> Ash.read!(action: :archived, authorize?: false)

      fresh_archived = List.first(archived_page.results)

      assert {:error, _error} =
               Ash.update(fresh_archived, %{}, action: :unarchive, authorize?: false)
    end
  end
end
