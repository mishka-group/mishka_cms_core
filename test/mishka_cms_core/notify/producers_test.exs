defmodule MishkaCmsCore.Test.Notify.ProducersTest do
  @moduledoc """
  The reference producer plugin end-to-end. `assign_permissions` fires
  `cms_core:user:after_assign_permissions` through mishka_installer → `PermissionsChanged.call/2` →
  `Notify.deliver/3`, so these tests exercise the full dynamic wiring, not just the producer function.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Notify.Notification

  defp assign_permissions(user, permission_ids, opts \\ []) do
    user
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: permission_ids},
      Keyword.put(opts, :authorize?, false)
    )
    |> Ash.update!()
  end

  defp with_permission(user, permission), do: assign_permissions(user, [permission.id])

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  describe "PermissionsChanged (via the mishka_installer event chain)" do
    test "changing a user's permissions notifies that site's full dashboard admins" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:*")
      admin = with_permission(create_user!(site_id: site.id), perm)
      target = create_user!(site_id: site.id)
      before = admin |> feed() |> length()

      with_permission(target, perm)

      after_feed = feed(admin)
      assert length(after_feed) == before + 1
      n = hd(after_feed)
      assert n.type == "cms_core:user:permissions_changed"
      assert n.metadata["email"] == to_string(target.email)
      assert n.link == "/admin/dashboard/account/users"
    end

    test "a master admin is notified of a tenant permission change" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:*")
      star = create_permission!(name: "*")
      master_admin = with_permission(create_user!(), star)
      target = create_user!(site_id: site.id)
      before = master_admin |> feed() |> length()

      with_permission(target, perm)

      after_feed = feed(master_admin)
      assert length(after_feed) == before + 1
      assert hd(after_feed).type == "cms_core:user:permissions_changed"
      # The row carries the originating site so the master can see/filter it.
      assert hd(after_feed).site_id == site.id
    end

    test "the admin who makes the change is not notified about it" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:*")
      actor_admin = with_permission(create_user!(site_id: site.id), perm)
      other_admin = with_permission(create_user!(site_id: site.id), perm)
      target = create_user!(site_id: site.id)

      before_actor = actor_admin |> feed() |> length()
      before_other = other_admin |> feed() |> length()

      assign_permissions(target, [perm.id], actor: actor_admin)

      # The actor is excluded; the other admin still gets it.
      assert length(feed(actor_admin)) == before_actor
      assert length(feed(other_admin)) == before_other + 1
    end

    test "the site's holder of the permission area is told; a holder of another area is not" do
      site = create_site!()

      manager =
        with_permission(
          create_user!(site_id: site.id),
          create_permission!(name: "admin:dashboard:permission")
        )

      media_admin =
        with_permission(
          create_user!(site_id: site.id),
          create_permission!(name: "admin:dashboard:runtime:media")
        )

      target = create_user!(site_id: site.id)
      before = {length(feed(manager)), length(feed(media_admin))}

      with_permission(target, create_permission!(name: "admin:dashboard:runtime:page"))

      assert [%{type: "cms_core:user:permissions_changed"} | _] = feed(manager)

      assert {length(feed(manager)), length(feed(media_admin))} ==
               {elem(before, 0) + 1, elem(before, 1)}
    end

    test "a master holding the permission area is told; a master of another area is not" do
      site = create_site!()

      manager =
        with_permission(create_user!(), create_permission!(name: "admin:dashboard:permission"))

      media_master =
        with_permission(create_user!(), create_permission!(name: "admin:dashboard:runtime:media"))

      target = create_user!(site_id: site.id)
      before = {length(feed(manager)), length(feed(media_master))}

      with_permission(target, create_permission!(name: "admin:dashboard:runtime:page"))

      assert [%{type: "cms_core:user:permissions_changed"} | _] = feed(manager)

      assert {length(feed(manager)), length(feed(media_master))} ==
               {elem(before, 0) + 1, elem(before, 1)}
    end

    test "a non-admin on the site is not notified" do
      site = create_site!()
      perm = create_permission!(name: "admin:dashboard:*")
      plain = create_user!(site_id: site.id)
      target = create_user!(site_id: site.id)
      before = plain |> feed() |> length()

      with_permission(target, perm)

      assert length(feed(plain)) == before
    end
  end
end
