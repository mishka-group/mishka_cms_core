# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.GrantScopeTest do
  @moduledoc """
  Who may hand out which permission.

  A CMS with many sites cannot route every routine grant through a master, so a tenant admin manages
  its own site's people. The two rules that make that safe are here: you may only grant what you
  already hold (`GrantWithinActorScope`), and you may never edit your own permissions (the policy on
  `assign_permissions`). Either alone is defeatable — grant a colleague your level and have them
  grant you more — so both are tested together.

  A tenant holding `*` is a site OWNER, not a superadmin: it may grant anything inside its own site,
  and `require_master` still shuts it out of master actions, because that gate reads `site_id`, not
  permissions.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}

  require Ash.Query

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, found} -> found
    end
  end

  defp grant(actor, target, names) do
    ids = Enum.map(names, &permission!(&1).id)

    target
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: ids},
      actor: actor,
      tenant: target.site_id
    )
    |> Ash.update()
  end

  defp names_of(user) do
    user
    |> Ash.load!([permissions: [:name]], authorize?: false)
    |> Map.get(:permissions)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  describe "a tenant admin runs its own site" do
    setup do
      site = create_site!()

      admin =
        create_user_with_permissions!(["admin:dashboard:permission", "admin:dashboard:blog:*"],
          site_id: site.id
        )

      {:ok, site: site, admin: admin, colleague: create_user!(site_id: site.id)}
    end

    test "grants a subset of what it holds", %{admin: admin, colleague: colleague} do
      assert {:ok, updated} = grant(admin, colleague, ["admin:dashboard:blog:post"])
      assert names_of(updated) == ["admin:dashboard:blog:post"]
    end

    test "grants the exact permission it holds", %{admin: admin, colleague: colleague} do
      assert {:ok, updated} = grant(admin, colleague, ["admin:dashboard:blog:*"])
      assert names_of(updated) == ["admin:dashboard:blog:*"]
    end

    test "cannot grant the star permission", %{admin: admin, colleague: colleague} do
      assert {:error, error} = grant(admin, colleague, ["*"])
      assert Exception.message(error) =~ "do not hold"
      assert names_of(colleague) == []
    end

    test "cannot grant a sibling area it does not hold", %{admin: admin, colleague: colleague} do
      assert {:error, _} = grant(admin, colleague, ["admin:dashboard:document:section"])
      assert names_of(colleague) == []
    end

    test "one allowed permission does not smuggle a disallowed one alongside it", %{
      admin: admin,
      colleague: colleague
    } do
      assert {:error, _} = grant(admin, colleague, ["admin:dashboard:blog:post", "*"])
      assert names_of(colleague) == []
    end

    test "cannot raise ITSELF, even to something it already holds", %{admin: admin} do
      assert {:error, error} = grant(admin, admin, ["admin:dashboard:blog:*"])
      assert Exception.message(error) =~ "forbidden"
    end

    test "cannot touch a user of another site", %{admin: admin} do
      stranger = create_user!(site_id: create_site!().id)

      assert {:error, _} = grant(admin, stranger, ["admin:dashboard:blog:post"])
      assert names_of(stranger) == []
    end
  end

  describe "a tenant holding the star permission is a site owner" do
    setup do
      site = create_site!()

      {:ok,
       site: site,
       owner: create_user_with_permissions!(["*"], site_id: site.id),
       colleague: create_user!(site_id: site.id)}
    end

    test "grants anything inside its own site", %{owner: owner, colleague: colleague} do
      assert {:ok, updated} =
               grant(owner, colleague, [
                 "admin:dashboard:document:section",
                 "admin:dashboard:permission"
               ])

      assert names_of(updated) == [
               "admin:dashboard:document:section",
               "admin:dashboard:permission"
             ]
    end

    test "including the star itself — contained, because both stay bound to the site", %{
      owner: owner,
      colleague: colleague
    } do
      assert {:ok, updated} = grant(owner, colleague, ["*"])
      assert names_of(updated) == ["*"]
      assert updated.site_id == colleague.site_id
    end

    test "still cannot reach another site", %{owner: owner} do
      stranger = create_user!(site_id: create_site!().id)

      assert {:error, _} = grant(owner, stranger, ["admin:dashboard:blog:post"])
    end

    test "and still cannot edit itself", %{owner: owner} do
      assert {:error, _} = grant(owner, owner, ["*"])
    end
  end

  describe "a master" do
    test "holding the star grants anything to anyone" do
      master = create_user_with_permissions!(["*"])
      target = create_user!(site_id: create_site!().id)

      assert {:ok, updated} = grant(master, target, ["*"])
      assert names_of(updated) == ["*"]
    end

    test "holding the permission area grants no more than it holds" do
      master =
        create_user_with_permissions!(["admin:dashboard:permission", "admin:dashboard:blog:*"])

      target = create_user!(site_id: create_site!().id)

      assert {:ok, _} = grant(master, target, ["admin:dashboard:blog:post"])
      assert {:error, error} = grant(master, target, ["*"])
      assert Exception.message(error) =~ "do not hold"
      assert names_of(target) == ["admin:dashboard:blog:post"]
    end

    test "may edit its own permissions within what it holds — bootstrap needs it" do
      master = create_user_with_permissions!(["*"])

      assert {:ok, _} = grant(master, master, ["*", "admin:dashboard:permission"])
    end
  end

  describe "internal callers" do
    test "seeding and bootstrap are unaffected — a system call has no ceiling" do
      target = create_user!()
      ids = [permission!("*").id]

      assert {:ok, updated} =
               target
               |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: ids},
                 authorize?: false
               )
               |> Ash.update()

      assert names_of(updated) == ["*"]
    end
  end

  describe "the ceiling is the actor that RUNS the grant" do
    # A changeset carries the actor it was built with, and `Ash.update/2` may be handed another. The
    # ceiling is asked of the one that runs the write — the one the policies ask — so a grant built
    # by a master, by a system call or by nobody gives a site's permission manager nothing more.
    setup do
      site = create_site!()

      {:ok,
       site: site,
       admin:
         create_user_with_permissions!(["admin:dashboard:permission", "admin:dashboard:blog:*"],
           site_id: site.id
         ),
       colleague: create_user!(site_id: site.id),
       master: create_user_with_permissions!(["*"])}
    end

    defp built_by(target, action, params, build_opts, site) do
      Ash.Changeset.for_update(target, action, params, [tenant: site.id] ++ build_opts)
    end

    test "assign_permissions built with a master, run by a site admin, grants nothing past it",
         ctx do
      assert {:error, error} =
               ctx.colleague
               |> built_by(
                 :assign_permissions,
                 %{permission_ids: [permission!("*").id]},
                 [actor: ctx.master],
                 ctx.site
               )
               |> Ash.update(actor: ctx.admin)

      assert Exception.message(error) =~ "do not hold"
      assert names_of(ctx.colleague) == []
    end

    test "assign_permissions built as a system call, run by a site admin, grants nothing past it",
         ctx do
      assert {:error, error} =
               ctx.colleague
               |> built_by(
                 :assign_permissions,
                 %{permission_ids: [permission!("*").id]},
                 [authorize?: false],
                 ctx.site
               )
               |> Ash.update(actor: ctx.admin, authorize?: true)

      assert Exception.message(error) =~ "do not hold"
      assert names_of(ctx.colleague) == []
    end

    test "assign_permissions built with no actor, run by a site admin, grants nothing past it",
         ctx do
      assert {:error, _} =
               ctx.colleague
               |> built_by(
                 :assign_permissions,
                 %{permission_ids: [permission!("*").id]},
                 [],
                 ctx.site
               )
               |> Ash.update(actor: ctx.admin)

      assert names_of(ctx.colleague) == []
    end

    test "and within the ceiling of the actor that runs it, the grant goes through", ctx do
      assert {:ok, updated} =
               ctx.colleague
               |> built_by(
                 :assign_permissions,
                 %{permission_ids: [permission!("admin:dashboard:blog:post").id]},
                 [],
                 ctx.site
               )
               |> Ash.update(actor: ctx.admin)

      assert names_of(updated) == ["admin:dashboard:blog:post"]
    end

    test "add_permission built with a master, run by a site admin, grants nothing past it", ctx do
      assert {:error, error} =
               ctx.colleague
               |> built_by(
                 :add_permission,
                 %{permission_id: permission!("*").id},
                 [actor: ctx.master],
                 ctx.site
               )
               |> Ash.update(actor: ctx.admin)

      assert Exception.message(error) =~ "do not hold"
      assert names_of(ctx.colleague) == []
    end

    test "tenant_update built with a master, run by a site admin, grants nothing past it", ctx do
      dashboard_admin =
        create_user_with_permissions!(["admin:dashboard:*", "admin:dashboard:blog:*"],
          site_id: ctx.site.id
        )

      assert {:error, error} =
               ctx.colleague
               |> built_by(
                 :tenant_update,
                 %{permission_ids: [permission!("*").id]},
                 [actor: ctx.master],
                 ctx.site
               )
               |> Ash.update(actor: dashboard_admin)

      assert Exception.message(error) =~ "do not hold"
      assert names_of(ctx.colleague) == []
    end

    test "tenant_create built with a master, run by a site admin, grants nothing past it", ctx do
      dashboard_admin =
        create_user_with_permissions!(["admin:dashboard:*", "admin:dashboard:blog:*"],
          site_id: ctx.site.id
        )

      email = "ceiling-#{System.unique_integer([:positive])}@example.com"

      assert {:error, error} =
               User
               |> Ash.Changeset.for_create(
                 :tenant_create,
                 %{
                   email: email,
                   password: "Password123!",
                   password_confirmation: "Password123!",
                   permission_ids: [permission!("*").id]
                 },
                 actor: ctx.master,
                 tenant: ctx.site.id
               )
               |> Ash.create(actor: dashboard_admin)

      assert Exception.message(error) =~ "do not hold"

      assert [] ==
               User
               |> Ash.Query.filter(email == ^email)
               |> Ash.read!(authorize?: false)
    end

    test "nobody grants anything with authorization on", ctx do
      assert {:error, _} =
               ctx.colleague
               |> Ash.Changeset.for_update(
                 :assign_permissions,
                 %{permission_ids: [permission!("admin:dashboard:blog:*").id]},
                 tenant: ctx.site.id,
                 authorize?: true
               )
               |> Ash.update()

      assert names_of(ctx.colleague) == []
    end
  end

  describe "the tenant actions keep the same ceiling" do
    setup do
      site = create_site!()

      {:ok,
       site: site,
       admin:
         create_user_with_permissions!(["admin:dashboard:*", "admin:dashboard:blog:*"],
           site_id: site.id
         ),
       colleague: create_user!(site_id: site.id)}
    end

    defp tenant_create(actor, site, names) do
      User
      |> Ash.Changeset.for_create(
        :tenant_create,
        %{
          email: "made-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          permission_ids: Enum.map(names, &permission!(&1).id)
        },
        actor: actor,
        tenant: site.id
      )
      |> Ash.create()
    end

    defp tenant_update(actor, target, params) do
      target
      |> Ash.Changeset.for_update(:tenant_update, params, actor: actor, tenant: target.site_id)
      |> Ash.update()
    end

    test "tenant_create cannot hand out more than the creator holds", ctx do
      assert {:error, error} = tenant_create(ctx.admin, ctx.site, ["*"])
      assert Exception.message(error) =~ "do not hold"
    end

    test "tenant_create hands out what the creator holds", ctx do
      assert {:ok, created} = tenant_create(ctx.admin, ctx.site, ["admin:dashboard:blog:post"])
      assert names_of(created) == ["admin:dashboard:blog:post"]
    end

    test "tenant_update cannot hand out more than the editor holds", ctx do
      assert {:error, error} =
               tenant_update(ctx.admin, ctx.colleague, %{permission_ids: [permission!("*").id]})

      assert Exception.message(error) =~ "do not hold"
      assert names_of(ctx.colleague) == []
    end

    test "tenant_update hands out what the editor holds", ctx do
      assert {:ok, updated} =
               tenant_update(ctx.admin, ctx.colleague, %{
                 permission_ids: [permission!("admin:dashboard:blog:*").id]
               })

      assert names_of(updated) == ["admin:dashboard:blog:*"]
    end

    test "tenant_update cannot raise ITSELF, even to what it already holds", ctx do
      assert {:error, _} =
               tenant_update(ctx.admin, ctx.admin, %{
                 permission_ids: [permission!("admin:dashboard:*").id, permission!("*").id]
               })

      assert {:error, _} =
               tenant_update(ctx.admin, ctx.admin, %{
                 permission_ids: [permission!("admin:dashboard:*").id]
               })

      assert names_of(ctx.admin) == ["admin:dashboard:*", "admin:dashboard:blog:*"]
    end

    test "tenant_update still changes its own email", ctx do
      assert {:ok, updated} =
               tenant_update(ctx.admin, ctx.admin, %{email: "own-email@example.com"})

      assert to_string(updated.email) == "own-email@example.com"
      assert names_of(updated) == ["admin:dashboard:*", "admin:dashboard:blog:*"]
    end

    test "a master holding the star hands out anything through the tenant actions", ctx do
      master = create_user_with_permissions!(["*"])

      assert {:ok, updated} =
               tenant_update(master, ctx.colleague, %{permission_ids: [permission!("*").id]})

      assert names_of(updated) == ["*"]
    end
  end

  describe "removing is not escalation" do
    test "a tenant admin may remove a permission it does not itself hold" do
      site = create_site!()
      admin = create_user_with_permissions!(["admin:dashboard:permission"], site_id: site.id)

      colleague =
        create_user_with_permissions!(["admin:dashboard:document:section"], site_id: site.id)

      assert {:ok, updated} =
               colleague
               |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: []},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.update()

      assert names_of(updated) == []
    end
  end

  describe "changing permissions takes the permission area" do
    # `admin:dashboard:permission`, or a wildcard that covers it. Anyone else of the site — a member
    # with nothing, an editor with `admin:dashboard:blog:*` — changes no one's permissions, removing
    # included.
    setup do
      site = create_site!()

      {:ok,
       site: site,
       owner: create_user_with_permissions!(["*"], site_id: site.id),
       member: create_user!(site_id: site.id),
       editor: create_user_with_permissions!(["admin:dashboard:blog:*"], site_id: site.id)}
    end

    defp change_permissions(actor, target, action, params, site) do
      target
      |> Ash.Changeset.for_update(action, params, actor: actor, tenant: site.id)
      |> Ash.update()
    end

    test "a member with no permission cannot take one away from the site's owner", ctx do
      assert {:error, _} =
               change_permissions(
                 ctx.member,
                 ctx.owner,
                 :remove_permission,
                 %{permission_id: permission!("*").id},
                 ctx.site
               )

      assert names_of(ctx.owner) == ["*"]
    end

    test "a member with no permission cannot clear the owner's permissions", ctx do
      assert {:error, _} =
               change_permissions(
                 ctx.member,
                 ctx.owner,
                 :assign_permissions,
                 %{permission_ids: []},
                 ctx.site
               )

      assert names_of(ctx.owner) == ["*"]
    end

    test "a blog editor cannot take a colleague's permission away", ctx do
      colleague =
        create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: ctx.site.id)

      assert {:error, _} =
               change_permissions(
                 ctx.editor,
                 colleague,
                 :remove_permission,
                 %{permission_id: permission!("admin:dashboard:blog:post").id},
                 ctx.site
               )

      assert names_of(colleague) == ["admin:dashboard:blog:post"]
    end

    test "a master without the permission area grants nothing" do
      master = create_user!()
      target = create_user!(site_id: create_site!().id)

      assert {:error, _} = grant(master, target, ["*"])
      assert {:error, _} = grant(master, master, ["*"])
      assert names_of(target) == []
      assert names_of(master) == []
    end
  end

  describe "a grant row is written through the account's own actions, or by a master admin" do
    # The join row itself carries neither the ceiling nor the no-self-edit rule, so a site's admin
    # writes it only through `assign_permissions`, `add_permission`, `remove_permission` and the
    # tenant actions, which carry both.
    setup do
      site = create_site!()

      {:ok,
       site: site,
       dashboard_admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
       owner: create_user_with_permissions!(["*"], site_id: site.id),
       colleague: create_user_with_permissions!(["admin:dashboard:blog:*"], site_id: site.id)}
    end

    defp grant_row(actor, action, user, name) do
      UserPermission
      |> Ash.Changeset.for_create(action, %{}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(name).id)
      |> Ash.create(actor: actor)
    end

    test "a site admin gives itself nothing by writing the row", ctx do
      assert {:error, _} = grant_row(ctx.dashboard_admin, :assign, ctx.dashboard_admin, "*")
      assert names_of(ctx.dashboard_admin) == ["admin:dashboard:*"]
    end

    test "a site admin gives a colleague nothing past its ceiling by writing the row", ctx do
      assert {:error, _} = grant_row(ctx.dashboard_admin, :create, ctx.colleague, "*")
      assert names_of(ctx.colleague) == ["admin:dashboard:blog:*"]
    end

    test "a site owner writes no row either; it grants through the account's actions", ctx do
      assert {:error, _} =
               grant_row(ctx.owner, :assign, ctx.colleague, "admin:dashboard:blog:post")

      assert names_of(ctx.colleague) == ["admin:dashboard:blog:*"]

      assert {:ok, _} =
               grant(ctx.owner, ctx.colleague, [
                 "admin:dashboard:blog:*",
                 "admin:dashboard:blog:post"
               ])

      assert names_of(ctx.colleague) == ["admin:dashboard:blog:*", "admin:dashboard:blog:post"]
    end

    test "a site admin deletes no row directly", ctx do
      row =
        UserPermission
        |> Ash.Query.filter(user_id == ^ctx.colleague.id)
        |> Ash.read_one!(authorize?: false)

      assert {:error, _} = Ash.destroy(row, actor: ctx.owner)
      assert names_of(ctx.colleague) == ["admin:dashboard:blog:*"]
    end

    test "a master admin writes the row", ctx do
      master = create_user_with_permissions!(["*"])

      assert {:ok, _} = grant_row(master, :assign, ctx.colleague, "admin:dashboard:blog:post")
      assert names_of(ctx.colleague) == ["admin:dashboard:blog:*", "admin:dashboard:blog:post"]
    end
  end

  describe "the catalogue" do
    test "grant checking uses the same wildcard rule as every other gate" do
      alias MishkaCmsCore.Accounts.Checks.AccessPermissions

      assert AccessPermissions.covers?("admin:dashboard:blog:*", "admin:dashboard:blog:post")
      assert AccessPermissions.covers?("*", "anything:at:all")
      refute AccessPermissions.covers?("admin:dashboard:blog:post", "*")

      refute AccessPermissions.covers?(
               "admin:dashboard:blog:*",
               "admin:dashboard:document:section"
             )
    end
  end

  test "the User resource still compiles its three permission actions" do
    for action <- [:assign_permissions, :add_permission, :remove_permission] do
      assert Ash.Resource.Info.action(User, action)
    end
  end
end
