# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.GervazTableAuthorizationTest do
  @moduledoc """
  The admin tables' row actions, called the way the table calls them, with authorization on.

  `Ash.destroy(record, action: ...)` resolves the domain's `authorize?` default only after the
  changeset has been built, and an archiving destroy is built in that gap — so every validation on
  the action used to be handed `authorize?: false`, and `TenantContext` stands aside on that. The
  table's Delete was the one caller that took it: the bulk archive, the permanent delete, the restore
  and the JSON:API all resolve the default in time. `MishkaGervaz.Table.Web.Events.RecordHandler`
  now says `authorize?: true` itself.

  What this cost, exactly: the sites table names ONE destroy action for both kinds of user, so a
  tenant admin holding `admin:dashboard:*` archived THEIR OWN SITE. The policy lets them in and
  `TenantContext` — which refuses a tenant on that master-only action — was the whole guard, and it
  was the one thing the gap turned off. Their own row is the only site row the table ever draws for
  them: `read :tenant_get` filters to `actor(:site_id)`, so the foreign row below is reached the way
  an auditor reaches it, not the way the table does. It is here because a row action naming a single
  `master_*` action hands that action to whoever pressed it, and the pages table has three.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.{Page, Site}
  alias MishkaGervaz.Table.Web.Events.RecordHandler.Default, as: RecordHandler
  alias MishkaGervaz.Table.Web.State

  @moduletag :integration

  setup do
    site = create_site!()
    other_site = create_site!()
    master_user = create_user_with_permissions!(["*"])
    tenant_user = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

    %{
      site: site,
      other_site: other_site,
      master_user: master_user,
      tenant_user: tenant_user
    }
  end

  defp state(resource, user), do: State.init("table", resource, user)

  defp page_state(user), do: state(Page, user)

  # The row the table hands its own actions: read back through the handler, so it carries the tenant
  # the reader was given and no other.
  defp row(state, record, archive_status),
    do: RecordHandler.get_record(state, record.id, archive_status)

  defp archived_page(page),
    do: Ash.get(Page, page.id, action: :master_get_archived, authorize?: false)

  defp live_page(page), do: Ash.get(Page, page.id, action: :get_any, authorize?: false)

  defp archive!(page) do
    {:ok, archived} =
      Ash.destroy(page, action: :master_destroy, authorize?: false, return_destroyed?: true)

    archived
  end

  defp site_row(site), do: Ash.get!(Site, site.id, action: :get_any, authorize?: false)

  describe "the sites table's Delete" do
    # THE ROW THE TABLE ACTUALLY DRAWS FOR A TENANT. Read back through the handler, so it is the
    # one `:tenant_get` answers with and no other — and archiving it is what a tenant admin could do.
    test "refuses a tenant admin their own site", %{site: site, tenant_user: tenant_user} do
      state = state(Site, tenant_user)

      refute state.master_user?
      own = RecordHandler.get_record(state, site.id, :active)
      assert own.id == site.id

      assert {:error, _} = RecordHandler.delete_record(state, own)
      assert %{archived_at: nil} = site_row(site)
    end

    test "draws a tenant admin no other site's row at all", %{
      other_site: other_site,
      tenant_user: tenant_user
    } do
      state = state(Site, tenant_user)

      refute RecordHandler.get_record(state, other_site.id, :active)
    end

    test "refuses a tenant admin", %{other_site: other_site, tenant_user: tenant_user} do
      state = state(Site, tenant_user)

      refute state.master_user?
      assert {:error, _} = RecordHandler.delete_record(state, site_row(other_site))
      assert %{archived_at: nil} = site_row(other_site)
    end

    test "archives for a master", %{other_site: other_site, master_user: master_user} do
      state = state(Site, master_user)

      assert state.master_user?
      assert {:ok, _} = RecordHandler.delete_record(state, site_row(other_site))
      assert %DateTime{} = site_row(other_site).archived_at
    end
  end

  describe "a row action naming a master destroy" do
    test "refuses a tenant admin holding another site's page", %{
      other_site: other_site,
      tenant_user: tenant_user
    } do
      foreign = create_page!(site_id: other_site.id, name: "about", path: "/about")

      assert {:error, _} =
               RecordHandler.destroy_record(page_state(tenant_user), foreign, :master_destroy)

      assert {:ok, %{archived_at: nil}} = live_page(foreign)
    end

    test "refuses a tenant admin permanently deleting another site's archived page", %{
      other_site: other_site,
      tenant_user: tenant_user
    } do
      foreign =
        create_page!(site_id: other_site.id, name: "about", path: "/about") |> archive!()

      assert {:error, _} =
               RecordHandler.destroy_record(
                 page_state(tenant_user),
                 foreign,
                 :master_permanent_destroy
               )

      assert {:ok, _} = archived_page(foreign)
    end

    test "refuses a tenant admin restoring another site's archived page", %{
      other_site: other_site,
      tenant_user: tenant_user
    } do
      foreign =
        create_page!(site_id: other_site.id, name: "about", path: "/about") |> archive!()

      assert {:error, _} =
               RecordHandler.update_record(page_state(tenant_user), foreign, :master_unarchive)

      assert {:ok, %{archived_at: archived_at}} = archived_page(foreign)
      assert %DateTime{} = archived_at
    end
  end

  describe "the pages table" do
    test "still deletes, restores and deletes permanently for a master", %{
      site: site,
      master_user: master_user
    } do
      state = page_state(master_user)
      page = create_page!(site_id: site.id, name: "about", path: "/about")

      assert {:ok, _} = RecordHandler.delete_record(state, row(state, page, :active))
      assert {:ok, archived} = archived_page(page)
      assert %DateTime{} = archived.archived_at

      assert {:ok, _} = RecordHandler.unarchive_record(state, row(state, page, :archived))
      assert {:ok, %{archived_at: nil}} = live_page(page)

      assert {:ok, _} = RecordHandler.delete_record(state, row(state, page, :active))
      assert {:ok, _} = archived_page(page)

      assert {:ok, _} = RecordHandler.permanent_destroy_record(state, row(state, page, :archived))
      assert {:error, _} = archived_page(page)
    end

    test "still deletes, restores and deletes permanently on a tenant's own site", %{
      site: site,
      tenant_user: tenant_user
    } do
      state = page_state(tenant_user)
      page = create_page!(site_id: site.id, name: "about", path: "/about")

      assert {:ok, _} = RecordHandler.delete_record(state, row(state, page, :active))
      assert {:ok, archived} = archived_page(page)
      assert %DateTime{} = archived.archived_at

      assert {:ok, _} = RecordHandler.unarchive_record(state, row(state, page, :archived))
      assert {:ok, %{archived_at: nil}} = live_page(page)

      assert {:ok, _} = RecordHandler.delete_record(state, row(state, page, :active))
      assert {:ok, _} = archived_page(page)

      assert {:ok, _} = RecordHandler.permanent_destroy_record(state, row(state, page, :archived))
      assert {:error, _} = archived_page(page)
    end
  end

  describe "an internal caller" do
    test "still archives and restores with authorize?: false, as seeds and boot code do", %{
      site: site
    } do
      page = create_page!(site_id: site.id, name: "about", path: "/about")

      assert {:ok, _} =
               Ash.destroy(page,
                 action: :master_destroy,
                 authorize?: false,
                 return_destroyed?: true
               )

      assert {:ok, archived} = archived_page(page)
      assert %DateTime{} = archived.archived_at

      assert {:ok, _} = Ash.update(archived, action: :master_unarchive, authorize?: false)
      assert {:ok, %{archived_at: nil}} = live_page(page)
    end
  end
end
