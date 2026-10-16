# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.MasterIdentityTest do
  @moduledoc """
  A master is a user whose `site_id` is nil, and nothing else makes one.

  A site user holding `*` owns its site and nothing more: it reads and changes the accounts of its
  own site, never another site's and never a master's, whether or not the call names a tenant. The
  master's actions ask who the actor is when they RUN, so an input built with no actor, or with
  somebody else's, gets a site user nowhere. A master admin keeps every account in reach.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}

  require Ash.Query

  @password "Password123!"

  setup do
    site_a = create_site!()
    site_b = create_site!()

    {:ok,
     site_a: site_a,
     site_b: site_b,
     star_a: create_user_with_permissions!(["*"], site_id: site_a.id),
     colleague_a: create_user_with_permissions!(["probe:role"], site_id: site_a.id),
     user_b: create_user_with_permissions!(["probe:role"], site_id: site_b.id),
     master: create_user_with_permissions!(["*"]),
     other_master: create_user_with_permissions!(["probe:role"])}
  end

  defp stored(id) do
    {:ok, user} = Ash.get(User, id, action: :master_get, authorize?: false)
    user
  end

  defp ids(users), do: users |> Enum.map(& &1.id) |> MapSet.new()

  defp star_permission do
    Permission
    |> Ash.Query.filter(name == "*")
    |> Ash.read_one!(authorize?: false)
  end

  describe "a site user holding * reads" do
    test "no other site's users and no masters when it names no tenant", ctx do
      assert {:ok, users} = Ash.read(User, actor: ctx.star_a)
      seen = ids(users)

      assert ctx.colleague_a.id in seen
      refute ctx.user_b.id in seen
      refute ctx.master.id in seen
      refute ctx.other_master.id in seen
    end

    test "no other site's users through a permission's holders", ctx do
      holders =
        Permission
        |> Ash.Query.filter(name == "probe:role")
        |> Ash.Query.load(:users)
        |> Ash.read_one!(actor: ctx.star_a)
        |> Map.fetch!(:users)
        |> ids()

      assert ctx.colleague_a.id in holders
      refute ctx.user_b.id in holders
      refute ctx.other_master.id in holders
    end

    test "nothing of the master's list, however the query was built", ctx do
      assert {:ok, %{results: []}} =
               User
               |> Ash.Query.for_read(:master_read, %{}, actor: ctx.master)
               |> Ash.read(actor: ctx.star_a, page: [limit: 10])

      assert {:ok, nil} =
               User
               |> Ash.Query.for_read(:master_get, %{}, actor: ctx.master)
               |> Ash.Query.filter(id == ^ctx.master.id)
               |> Ash.read_one(actor: ctx.star_a)
    end

    test "no other site's users and no masters through the users list, however it was built",
         ctx do
      for build_opts <- [[], [actor: ctx.master]] do
        assert {:ok, %{results: users}} =
                 User
                 |> Ash.Query.for_read(:users, %{}, build_opts)
                 |> Ash.read(actor: ctx.star_a, page: [limit: 100])

        seen = ids(users)

        assert ctx.colleague_a.id in seen
        refute ctx.user_b.id in seen
        refute ctx.master.id in seen
        refute ctx.other_master.id in seen
      end
    end

    test "not a master's own record through the current-user read a master built", ctx do
      assert {:ok, nil} =
               User
               |> Ash.Query.for_read(:read_current_user, %{}, actor: ctx.master)
               |> Ash.read_one(actor: ctx.star_a)
    end

    test "only its own site's permission grants", ctx do
      for tenant <- [nil, ctx.site_a.id] do
        assert {:ok, rows} = Ash.read(UserPermission, actor: ctx.star_a, tenant: tenant)
        holders = rows |> Enum.map(& &1.user_id) |> MapSet.new()

        assert ctx.colleague_a.id in holders
        refute ctx.user_b.id in holders
        refute ctx.master.id in holders
      end
    end
  end

  describe "a site user holding * changes" do
    test "no master's account", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.master
               |> Ash.Changeset.for_update(:update, %{email: "taken@example.com"},
                 actor: ctx.star_a
               )
               |> Ash.update()

      assert stored(ctx.master.id).email == ctx.master.email
    end

    test "no other site's account", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.user_b
               |> Ash.Changeset.for_update(:update, %{email: "taken@example.com"},
                 actor: ctx.star_a
               )
               |> Ash.update()

      assert stored(ctx.user_b.id).email == ctx.user_b.email
    end

    test "and deletes no master, through the table or the plain destroy", ctx do
      assert {:error, _} = Ash.destroy(ctx.master, action: :table_destroy, actor: ctx.star_a)
      assert {:error, _} = Ash.destroy(ctx.master, action: :destroy, actor: ctx.star_a)
      assert {:error, _} = Ash.destroy(ctx.user_b, action: :destroy, actor: ctx.star_a)

      assert stored(ctx.master.id)
      assert stored(ctx.user_b.id)
    end
  end

  describe "a site user holding * never becomes a master" do
    test "through master_update built with no actor", ctx do
      assert {:error, _} =
               User
               |> Ash.ActionInput.for_action(
                 :master_update,
                 %{id: ctx.star_a.id, site_id: nil, email: to_string(ctx.star_a.email)},
                 []
               )
               |> Ash.run_action(actor: ctx.star_a)

      assert stored(ctx.star_a.id).site_id == ctx.site_a.id
    end

    test "through master_update built with a master's actor and run as itself", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.ActionInput.for_action(
                 :master_update,
                 %{id: ctx.star_a.id, site_id: nil, email: to_string(ctx.star_a.email)},
                 actor: ctx.master
               )
               |> Ash.run_action(actor: ctx.star_a)

      assert stored(ctx.star_a.id).site_id == ctx.site_a.id
    end

    test "through the admin form's update", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.star_a.id
               |> stored()
               |> Ash.Changeset.for_update(:master_form_update, %{site_id: nil},
                 actor: ctx.master
               )
               |> Ash.update(actor: ctx.star_a)

      assert stored(ctx.star_a.id).site_id == ctx.site_a.id
    end

    test "through master_create", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{
                   email: "new-master@example.com",
                   password: @password,
                   password_confirmation: @password
                 },
                 actor: ctx.master
               )
               |> Ash.create(actor: ctx.star_a)

      assert {:ok, nil} =
               User
               |> Ash.Query.filter(email == "new-master@example.com")
               |> Ash.read_one(authorize?: false)
    end
  end

  describe "a site user holding * deletes no master through master_destroy" do
    test "built with no actor", ctx do
      assert {:error, _} =
               User
               |> Ash.ActionInput.for_action(:master_destroy, %{id: ctx.master.id}, [])
               |> Ash.run_action(actor: ctx.star_a)

      assert stored(ctx.master.id)
    end

    test "built with a master's actor and run as itself", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.ActionInput.for_action(:master_destroy, %{id: ctx.other_master.id},
                 actor: ctx.master
               )
               |> Ash.run_action(actor: ctx.star_a)

      assert stored(ctx.other_master.id)
    end
  end

  describe "the permission catalogue" do
    test "a site user holding * changes none of it, however the write was built", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Permission
               |> Ash.Changeset.for_create(:create, %{name: "made:by:site"}, actor: ctx.master)
               |> Ash.create(actor: ctx.star_a)

      blog =
        Permission |> Ash.Query.filter(name == "probe:role") |> Ash.read_one!(authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               blog
               |> Ash.Changeset.for_update(:update, %{description: "renamed by a site"},
                 actor: ctx.master
               )
               |> Ash.update(actor: ctx.star_a)

      assert {:error, %Ash.Error.Forbidden{}} =
               blog
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: ctx.master)
               |> Ash.destroy(actor: ctx.star_a)

      assert {:ok, nil} =
               Permission
               |> Ash.Query.filter(name == "made:by:site")
               |> Ash.read_one(authorize?: false)

      assert Ash.get!(Permission, blog.id, authorize?: false).description == blog.description
    end

    test "a master admin changes it", ctx do
      assert {:ok, _} =
               Permission
               |> Ash.Changeset.for_create(:create, %{name: "made:by:master"}, actor: ctx.master)
               |> Ash.create()
    end
  end

  describe "a site admin runs its own site's accounts" do
    test "reads, updates and deletes them", ctx do
      assert {:ok, users} = Ash.read(User, actor: ctx.star_a, tenant: ctx.site_a.id)
      assert ctx.colleague_a.id in ids(users)

      assert {:ok, updated} =
               ctx.colleague_a
               |> Ash.Changeset.for_update(:update, %{email: "renamed-a@example.com"},
                 actor: ctx.star_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.update()

      assert to_string(updated.email) == "renamed-a@example.com"

      assert :ok =
               Ash.destroy(ctx.colleague_a,
                 action: :destroy,
                 actor: ctx.star_a,
                 tenant: ctx.site_a.id
               )
    end

    test "creates and edits them through the tenant actions", ctx do
      assert {:ok, created} =
               User
               |> Ash.Changeset.for_create(
                 :tenant_create,
                 %{
                   email: "made-by-site-a@example.com",
                   password: @password,
                   password_confirmation: @password
                 },
                 actor: ctx.star_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.create()

      assert created.site_id == ctx.site_a.id

      assert {:ok, _} =
               created
               |> Ash.Changeset.for_update(:tenant_update, %{email: "edited-a@example.com"},
                 actor: ctx.star_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.update()

      assert {:ok, %{id: id}} =
               Ash.get(User, created.id,
                 action: :tenant_get,
                 actor: ctx.star_a,
                 tenant: ctx.site_a.id
               )

      assert id == created.id
    end
  end

  describe "a master admin" do
    test "reads every site's accounts and every master through the users list", ctx do
      assert {:ok, %{results: users}} =
               User
               |> Ash.Query.for_read(:users, %{}, actor: ctx.master)
               |> Ash.read(actor: ctx.master, page: [limit: 1000])

      seen = ids(users)

      assert ctx.user_b.id in seen
      assert ctx.colleague_a.id in seen
      assert ctx.other_master.id in seen
    end

    test "reads every site's accounts and every master", ctx do
      assert {:ok, users} = Ash.read(User, actor: ctx.master)
      seen = ids(users)

      for user <- [ctx.star_a, ctx.colleague_a, ctx.user_b, ctx.other_master],
          do: assert(user.id in seen)

      assert {:ok, rows} = Ash.read(UserPermission, actor: ctx.master)
      assert ctx.user_b.id in (rows |> Enum.map(& &1.user_id) |> MapSet.new())
    end

    test "changes, moves and deletes any account", ctx do
      assert {:ok, _} =
               ctx.user_b
               |> Ash.Changeset.for_update(:update, %{email: "renamed-b@example.com"},
                 actor: ctx.master
               )
               |> Ash.update()

      assert {:ok, moved} =
               User
               |> Ash.ActionInput.for_action(
                 :master_update,
                 %{id: ctx.user_b.id, site_id: ctx.site_a.id},
                 actor: ctx.master
               )
               |> Ash.run_action()

      assert moved.site_id == ctx.site_a.id

      assert :ok = Ash.destroy(ctx.colleague_a, action: :table_destroy, actor: ctx.master)
    end
  end

  test "a master with no admin permission runs no master action", ctx do
    plain_master = create_user!()

    assert {:ok, %{results: []}} =
             Ash.read(User, action: :master_read, actor: plain_master, page: [limit: 10])

    assert {:error, %Ash.Error.Forbidden{}} =
             User
             |> Ash.ActionInput.for_action(
               :master_update,
               %{id: ctx.user_b.id, email: "by-plain@example.com"},
               actor: plain_master
             )
             |> Ash.run_action()
  end

  describe "master_update changes only what it is given" do
    test "a password alone leaves the email and the site", ctx do
      assert {:ok, updated} =
               User
               |> Ash.ActionInput.for_action(
                 :master_update,
                 %{
                   id: ctx.user_b.id,
                   password: "NewPassword123!",
                   password_confirmation: "NewPassword123!"
                 },
                 actor: ctx.master
               )
               |> Ash.run_action()

      assert updated.email == ctx.user_b.email
      assert updated.site_id == ctx.site_b.id
    end

    test "an email alone leaves the site", ctx do
      assert {:ok, updated} =
               User
               |> Ash.ActionInput.for_action(
                 :master_update,
                 %{id: ctx.user_b.id, email: "only-email@example.com"},
                 actor: ctx.master
               )
               |> Ash.run_action()

      assert to_string(updated.email) == "only-email@example.com"
      assert updated.site_id == ctx.site_b.id
    end

    test "permissions alone leave the email and the site", ctx do
      assert {:ok, updated} =
               User
               |> Ash.ActionInput.for_action(
                 :master_update,
                 %{id: ctx.user_b.id, permission_ids: [star_permission().id]},
                 actor: ctx.master
               )
               |> Ash.run_action()

      assert updated.email == ctx.user_b.email
      assert updated.site_id == ctx.site_b.id
    end
  end
end
