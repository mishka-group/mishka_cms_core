defmodule MishkaCmsCore.Accounts.AccountAreasTest do
  @moduledoc """
  The Users and Permissions areas, on each surface.

  An account is listed, read, created, edited and deleted with `admin:<surface>:user`. What it holds
  is changed with `admin:<surface>:permission`, within the granter's own ceiling — a master's
  included. The catalogue is read with the permission area and written by a master holding it.
  Each gate is asked as a holder of that one area, and as a holder of the other.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}

  require Ash.Query

  @password "Password123!"
  @api %{shared: %{admin_surface: :api}}

  setup do
    site = create_site!()
    {:ok, site: site, member: create_user!(site_id: site.id)}
  end

  defp holder(names, site_id \\ nil), do: create_user_with_permissions!(names, site_id: site_id)

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, found} -> found
    end
  end

  defp names_of(user) do
    user
    |> Ash.load!([permissions: [:name]], authorize?: false)
    |> Map.get(:permissions)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp list_users(actor, site_id, context \\ %{}) do
    User
    |> Ash.Query.for_read(:users, %{}, actor: actor, tenant: site_id, context: context)
    |> Ash.read()
    |> results()
  end

  defp results({:ok, %{results: results}}), do: {:ok, results}
  defp results(other), do: other

  defp ids({:ok, users}), do: Enum.map(users, & &1.id)
  defp ids({:error, _}), do: []

  defp tenant_create(actor, site_id, names, context \\ %{}) do
    User
    |> Ash.Changeset.for_create(
      :tenant_create,
      %{
        email: "made-#{System.unique_integer([:positive])}@example.com",
        password: @password,
        password_confirmation: @password,
        permission_ids: Enum.map(names, &permission!(&1).id)
      },
      actor: actor,
      tenant: site_id,
      context: context
    )
    |> Ash.create()
  end

  defp tenant_update(actor, target, params, context \\ %{}) do
    target
    |> Ash.Changeset.for_update(:tenant_update, params,
      actor: actor,
      tenant: target.site_id,
      context: context
    )
    |> Ash.update()
  end

  defp assign(actor, target, names, context \\ %{}) do
    target
    |> Ash.Changeset.for_update(
      :assign_permissions,
      %{permission_ids: Enum.map(names, &permission!(&1).id)},
      actor: actor,
      tenant: target.site_id,
      context: context
    )
    |> Ash.update()
  end

  defp current_ids(user),
    do:
      user
      |> Ash.load!([:permissions], authorize?: false)
      |> Map.get(:permissions)
      |> Enum.map(& &1.id)

  defp refusal(error), do: Exception.message(error)

  describe "listing and reading accounts" do
    test "the user area lists its site's accounts; the permission area lists none", ctx do
      assert ctx.member.id in ids(
               list_users(holder(["admin:dashboard:user"], ctx.site.id), ctx.site.id)
             )

      refute ctx.member.id in ids(
               list_users(holder(["admin:dashboard:permission"], ctx.site.id), ctx.site.id)
             )
    end

    test "on the API the API's user area lists them, and the dashboard's does not", ctx do
      api_admin = holder(["admin:api:user"], ctx.site.id)
      dashboard_admin = holder(["admin:dashboard:user"], ctx.site.id)

      assert ctx.member.id in ids(list_users(api_admin, ctx.site.id, @api))
      refute ctx.member.id in ids(list_users(dashboard_admin, ctx.site.id, @api))
      refute ctx.member.id in ids(list_users(api_admin, ctx.site.id))
    end
  end

  describe "creating and editing an account" do
    test "the user area creates an account with no permissions; the permission area does not",
         ctx do
      assert {:ok, _} =
               tenant_create(holder(["admin:dashboard:user"], ctx.site.id), ctx.site.id, [])

      assert {:error, _} =
               tenant_create(holder(["admin:dashboard:permission"], ctx.site.id), ctx.site.id, [])
    end

    test "the permission area alone creates no account, even one it gives permissions", ctx do
      perms_admin =
        holder(["admin:dashboard:permission", "admin:dashboard:runtime:media"], ctx.site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_create(perms_admin, ctx.site.id, ["admin:dashboard:runtime:media"])
    end

    test "giving the new account permissions also takes the permission area", ctx do
      users_admin = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"], ctx.site.id)

      both =
        holder(
          ["admin:dashboard:user", "admin:dashboard:permission", "admin:dashboard:runtime:media"],
          ctx.site.id
        )

      assert {:error, %Ash.Error.Forbidden{} = error} =
               tenant_create(users_admin, ctx.site.id, ["admin:dashboard:runtime:media"])

      assert refusal(error) =~ "Changing an account's permissions takes the permission area"

      assert {:ok, created} = tenant_create(both, ctx.site.id, ["admin:dashboard:runtime:media"])
      assert names_of(created) == ["admin:dashboard:runtime:media"]
    end

    test "the user area edits an account's email while the form sends its permissions back",
         ctx do
      target = holder(["admin:dashboard:runtime:media"], ctx.site.id)
      users_admin = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"], ctx.site.id)

      assert {:ok, updated} =
               tenant_update(users_admin, target, %{
                 email: "renamed-#{System.unique_integer([:positive])}@example.com",
                 permission_ids: current_ids(target)
               })

      assert names_of(updated) == ["admin:dashboard:runtime:media"]
    end

    test "changing an account's permissions in the form takes the permission area", ctx do
      target = create_user!(site_id: ctx.site.id)
      media = permission!("admin:dashboard:runtime:media")
      users_admin = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"], ctx.site.id)

      both =
        holder(
          ["admin:dashboard:user", "admin:dashboard:permission", "admin:dashboard:runtime:media"],
          ctx.site.id
        )

      assert {:error, _} = tenant_update(users_admin, target, %{permission_ids: [media.id]})
      assert names_of(target) == []

      assert {:ok, _} = tenant_update(both, target, %{permission_ids: [media.id]})
      assert names_of(target) == ["admin:dashboard:runtime:media"]
    end

    test "the permission area alone does not edit an account's email", ctx do
      target = create_user!(site_id: ctx.site.id)
      perms_admin = holder(["admin:dashboard:permission"], ctx.site.id)

      assert {:error, _} = tenant_update(perms_admin, target, %{email: "no@example.com"})
    end
  end

  describe "granting through the permission actions" do
    test "the permission area grants within what it holds; the user area grants nothing", ctx do
      target = create_user!(site_id: ctx.site.id)

      perms_admin =
        holder(["admin:dashboard:permission", "admin:dashboard:runtime:media"], ctx.site.id)

      users_admin = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"], ctx.site.id)

      assert {:error, _} = assign(users_admin, target, ["admin:dashboard:runtime:media"])
      assert names_of(target) == []

      assert {:ok, _} = assign(perms_admin, target, ["admin:dashboard:runtime:media"])
      assert names_of(target) == ["admin:dashboard:runtime:media"]
      assert {:error, _} = assign(perms_admin, target, ["admin:dashboard:runtime:site"])
    end

    test "the user area takes no permission away; the permission area does", ctx do
      target = holder(["admin:dashboard:runtime:media"], ctx.site.id)
      media = permission!("admin:dashboard:runtime:media")

      remove = fn actor ->
        target
        |> Ash.Changeset.for_update(:remove_permission, %{permission_id: media.id},
          actor: actor,
          tenant: ctx.site.id
        )
        |> Ash.update()
      end

      assert {:error, _} = remove.(holder(["admin:dashboard:user"], ctx.site.id))
      assert names_of(target) == ["admin:dashboard:runtime:media"]

      assert {:ok, _} = remove.(holder(["admin:dashboard:permission"], ctx.site.id))
      assert names_of(target) == []
    end

    test "on the API the API's permission area grants, and the dashboard's does not", ctx do
      target = create_user!(site_id: ctx.site.id)
      api_admin = holder(["admin:api:permission", "admin:api:runtime:media"], ctx.site.id)

      dashboard_admin =
        holder(["admin:dashboard:permission", "admin:api:runtime:media"], ctx.site.id)

      assert {:error, _} = assign(dashboard_admin, target, ["admin:api:runtime:media"], @api)
      assert names_of(target) == []

      assert {:ok, _} = assign(api_admin, target, ["admin:api:runtime:media"], @api)
      assert names_of(target) == ["admin:api:runtime:media"]
    end
  end

  describe "a master's grants" do
    defp master_create(actor, names) do
      User
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          email: "master-made-#{System.unique_integer([:positive])}@example.com",
          password: @password,
          password_confirmation: @password,
          permission_ids: Enum.map(names, &permission!(&1).id)
        },
        actor: actor,
        tenant: nil
      )
      |> Ash.create()
    end

    defp master_update(actor, target, params) do
      User
      |> Ash.ActionInput.for_action(:master_update, Map.put(params, :id, target.id), actor: actor)
      |> Ash.run_action()
    end

    defp master_form_update(actor, target, params) do
      User
      |> Ash.get!(target.id, action: :master_get, authorize?: false)
      |> Ash.Changeset.for_update(:master_form_update, params, actor: actor)
      |> Ash.update()
    end

    test "a master of the user area creates an account, but gives it nothing", _ctx do
      users_master = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"])

      assert {:ok, _} = master_create(users_master, [])
      assert {:error, _} = master_create(users_master, ["admin:dashboard:runtime:media"])
    end

    test "a master grants no more than it holds", _ctx do
      master =
        holder([
          "admin:dashboard:user",
          "admin:dashboard:permission",
          "admin:dashboard:runtime:media"
        ])

      assert {:ok, created} = master_create(master, ["admin:dashboard:runtime:media"])
      assert names_of(created) == ["admin:dashboard:runtime:media"]

      assert {:error, error} = master_create(master, ["*"])
      assert refusal(error) =~ ~s(cannot grant permissions you do not hold yourself: "*")
    end

    test "a master of the permission area gives itself nothing it does not hold", _ctx do
      master = holder(["admin:dashboard:permission"])

      assert {:error, _} = assign(master, master, ["*"])
      assert names_of(master) == ["admin:dashboard:permission"]
    end

    test "the master form changes permissions only with the permission area", ctx do
      media = permission!("admin:dashboard:runtime:media")
      users_master = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"])

      both =
        holder([
          "admin:dashboard:user",
          "admin:dashboard:permission",
          "admin:dashboard:runtime:media"
        ])

      assert {:error, _} =
               master_form_update(users_master, ctx.member, %{permission_ids: [media.id]})

      assert names_of(ctx.member) == []

      assert {:ok, _} =
               master_form_update(users_master, ctx.member, %{
                 email: "master-renamed-#{System.unique_integer([:positive])}@example.com",
                 permission_ids: []
               })

      assert {:error, _} =
               master_form_update(both, ctx.member, %{permission_ids: [permission!("*").id]})

      assert {:ok, _} = master_form_update(both, ctx.member, %{permission_ids: [media.id]})
      assert names_of(ctx.member) == ["admin:dashboard:runtime:media"]
    end

    test "the master update action changes permissions only with the permission area", ctx do
      media = permission!("admin:dashboard:runtime:media")
      users_master = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"])

      both =
        holder([
          "admin:dashboard:user",
          "admin:dashboard:permission",
          "admin:dashboard:runtime:media"
        ])

      assert {:error, _} = master_update(users_master, ctx.member, %{permission_ids: [media.id]})
      assert names_of(ctx.member) == []

      assert {:error, _} =
               master_update(both, ctx.member, %{permission_ids: [permission!("*").id]})

      assert names_of(ctx.member) == []

      assert {:ok, _} = master_update(both, ctx.member, %{permission_ids: [media.id]})
      assert names_of(ctx.member) == ["admin:dashboard:runtime:media"]
    end

    # Asked with `Ash.can?/2`, which runs the policies alone: acting refuses these a second time,
    # when `manage_relationship` looks the permissions up in a catalogue the user area cannot read.
    defp grant_asked(action, ctx, site_id) do
      media = permission!("admin:dashboard:runtime:media")
      users_only = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"], site_id)

      both =
        holder(
          ["admin:dashboard:user", "admin:dashboard:permission", "admin:dashboard:runtime:media"],
          site_id
        )

      {Ash.can?(grant_changeset(action, ctx, media, users_only), users_only),
       Ash.can?(grant_changeset(action, ctx, media, both), both)}
    end

    defp grant_changeset(:tenant_update, ctx, media, actor),
      do:
        Ash.Changeset.for_update(ctx.member, :tenant_update, %{permission_ids: [media.id]},
          actor: actor,
          tenant: ctx.site.id
        )

    defp grant_changeset(:master_create, _ctx, media, actor),
      do:
        Ash.Changeset.for_create(
          User,
          :master_create,
          %{
            email: "asked-#{System.unique_integer([:positive])}@example.com",
            password: @password,
            password_confirmation: @password,
            permission_ids: [media.id]
          },
          actor: actor,
          tenant: nil
        )

    defp grant_changeset(:master_form_update, ctx, media, actor),
      do:
        User
        |> Ash.get!(ctx.member.id, action: :master_get, authorize?: false)
        |> Ash.Changeset.for_update(:master_form_update, %{permission_ids: [media.id]},
          actor: actor
        )

    test "the grant gate refuses tenant_update to the user area alone", ctx do
      assert grant_asked(:tenant_update, ctx, ctx.site.id) == {false, true}
    end

    test "the grant gate refuses master_create to the user area alone", ctx do
      assert grant_asked(:master_create, ctx, nil) == {false, true}
    end

    test "the grant gate refuses master_form_update to the user area alone", ctx do
      assert grant_asked(:master_form_update, ctx, nil) == {false, true}
    end

    test "a master holding neither area reaches no account", ctx do
      master = holder(["admin:dashboard:runtime:media"])

      assert {:error, _} = master_create(master, [])
      assert {:error, _} = master_form_update(master, ctx.member, %{email: "x@example.com"})
    end
  end

  describe "an account holding more than its editor" do
    setup %{site: site} do
      {:ok, owner: holder(["*"], site.id)}
    end

    defp reload(user), do: Ash.get!(User, user.id, action: :master_get, authorize?: false)

    defp new_password,
      do: %{password: "Replaced123!", password_confirmation: "Replaced123!"}

    # As the table's bulk Delete runs one: a query over the chosen rows, by whichever strategy fits.
    defp bulk_delete(resource, action, actor, records) do
      ids = Enum.map(records, & &1.id)

      resource
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_destroy(action, %{},
        actor: actor,
        strategy: [:atomic, :atomic_batches, :stream],
        allow_stream_with: :full_read,
        return_errors?: true
      )
    end

    defp destroy(actor, target, action, context \\ %{}) do
      target
      |> Ash.Changeset.for_destroy(action, %{},
        actor: actor,
        tenant: target.site_id,
        context: context
      )
      |> Ash.destroy()
    end

    test "a site's holder of the user area sets no password or email on an account holding more",
         ctx do
      users_admin = holder(["admin:dashboard:user"], ctx.site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_update(users_admin, ctx.owner, new_password())

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_update(users_admin, ctx.owner, %{email: "taken@example.com"})

      assert reload(ctx.owner).hashed_password == ctx.owner.hashed_password
      assert to_string(reload(ctx.owner).email) == to_string(ctx.owner.email)
    end

    test "a site's holder of the user area sets the password of an account holding no more",
         ctx do
      users_admin = holder(["admin:dashboard:user"], ctx.site.id)
      peer = holder(["admin:dashboard:user"], ctx.site.id)

      assert {:ok, _} = tenant_update(users_admin, ctx.member, new_password())
      assert {:ok, _} = tenant_update(users_admin, peer, new_password())
      refute reload(peer).hashed_password == peer.hashed_password
    end

    test "a site's holder of the user area deletes no account holding more", ctx do
      users_admin = holder(["admin:dashboard:user"], ctx.site.id)

      for action <- [:tenant_destroy, :destroy] do
        assert {:error, %Ash.Error.Forbidden{}} = destroy(users_admin, ctx.owner, action)
      end

      assert reload(ctx.owner)
      assert :ok = destroy(users_admin, ctx.member, :tenant_destroy)
    end

    test "a site's owner holding everything edits any account of its site", ctx do
      target = holder(["admin:dashboard:user", "admin:api:runtime:page"], ctx.site.id)

      assert {:ok, _} = tenant_update(ctx.owner, target, new_password())
    end

    test "the permission area still changes what an account holding more holds", ctx do
      target = holder(["*", "admin:dashboard:runtime:media"], ctx.site.id)

      perms_admin =
        holder(
          ["admin:dashboard:user", "admin:dashboard:permission", "admin:dashboard:runtime:media"],
          ctx.site.id
        )

      assert {:ok, _} =
               tenant_update(perms_admin, target, %{
                 email: target.email,
                 permission_ids: [permission!("*").id]
               })

      assert names_of(target) == ["*"]
      assert {:error, %Ash.Error.Forbidden{}} = tenant_update(perms_admin, target, new_password())
    end

    test "a master of the user area neither moves nor resets an account holding more", ctx do
      users_master = holder(["admin:dashboard:user"])

      assert {:error, _} =
               master_update(users_master, ctx.owner, Map.put(new_password(), :site_id, nil))

      assert {:error, _} = master_update(users_master, ctx.owner, %{email: "taken@example.com"})

      assert {:error, %Ash.Error.Forbidden{}} =
               master_form_update(users_master, ctx.owner, Map.put(new_password(), :site_id, nil))

      owner = reload(ctx.owner)
      assert owner.site_id == ctx.site.id
      assert owner.hashed_password == ctx.owner.hashed_password
      assert to_string(owner.email) == to_string(ctx.owner.email)
    end

    test "a master of the user area deletes no account holding more", ctx do
      users_master = holder(["admin:dashboard:user"])

      assert {:error, _} =
               User
               |> Ash.ActionInput.for_action(:master_destroy, %{id: ctx.owner.id},
                 actor: users_master
               )
               |> Ash.run_action()

      assert reload(ctx.owner)
    end

    test "the users table deletes, one row or many, only accounts holding no more than its admin",
         ctx do
      users_master = holder(["admin:dashboard:user"])

      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.owner
               |> Ash.Changeset.for_destroy(:table_destroy, %{}, actor: users_master)
               |> Ash.destroy()

      assert %Ash.BulkResult{status: :error} =
               bulk_delete(User, :table_destroy, users_master, [ctx.owner])

      assert reload(ctx.owner)

      assert %Ash.BulkResult{status: :success} =
               bulk_delete(User, :table_destroy, users_master, [ctx.member])

      assert {:error, _} = Ash.get(User, ctx.member.id, action: :master_get, authorize?: false)
    end

    test "a master of the user area moves and resets an account holding no more", ctx do
      users_master = holder(["admin:dashboard:user", "admin:dashboard:runtime:media"])
      target = holder(["admin:dashboard:runtime:media"], ctx.site.id)

      assert {:ok, _} = master_update(users_master, target, new_password())
      assert {:ok, moved} = master_form_update(users_master, target, %{site_id: nil})
      assert moved.site_id == nil
    end

    test "on the API the API's user area is held to the same", ctx do
      api_admin = holder(["admin:api:user"], ctx.site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_update(api_admin, ctx.owner, new_password(), @api)

      assert {:error, %Ash.Error.Forbidden{}} =
               destroy(api_admin, ctx.owner, :tenant_destroy, @api)

      assert {:ok, _} = tenant_update(api_admin, ctx.member, new_password(), @api)
      assert reload(ctx.owner).hashed_password == ctx.owner.hashed_password
    end
  end

  describe "the catalogue" do
    defp catalogue(actor, site_id, context \\ %{}) do
      action = if site_id, do: :tenant_read, else: :master_read

      Permission
      |> Ash.Query.for_read(action, %{}, actor: actor, tenant: site_id, context: context)
      |> Ash.read()
      |> results()
    end

    defp create_row(actor, name) do
      Permission
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor, tenant: nil)
      |> Ash.create()
    end

    test "the permission area reads it; the user area does not", ctx do
      assert {:ok, [_ | _]} =
               catalogue(holder(["admin:dashboard:permission"], ctx.site.id), ctx.site.id)

      assert {:error, _} = catalogue(holder(["admin:dashboard:user"], ctx.site.id), ctx.site.id)
    end

    test "on the API the API's permission area reads it, and the dashboard's does not", ctx do
      assert {:ok, [_ | _]} =
               catalogue(holder(["admin:api:permission"], ctx.site.id), ctx.site.id, @api)

      assert {:error, _} =
               catalogue(holder(["admin:dashboard:permission"], ctx.site.id), ctx.site.id, @api)
    end

    test "a master of the permission area writes a row; a master of another area does not",
         _ctx do
      assert {:ok, _} = create_row(holder(["admin:dashboard:permission"]), "probe:row:one")
      assert {:error, _} = create_row(holder(["admin:dashboard:user"]), "probe:row:two")
    end

    test "a site's holder of the permission area writes no row", ctx do
      assert {:error, _} =
               create_row(holder(["admin:dashboard:permission"], ctx.site.id), "probe:row:three")
    end

    test "a row built by a master and run by a site's holder of the area is not written", ctx do
      master = holder(["admin:dashboard:permission"])

      assert {:error, %Ash.Error.Forbidden{}} =
               Permission
               |> Ash.Changeset.for_create(:create, %{name: "probe:row:four"},
                 actor: master,
                 tenant: nil
               )
               |> Ash.create(actor: holder(["admin:dashboard:permission"], ctx.site.id))
    end

    defp rename(actor, row, params, context \\ %{}) do
      row
      |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: nil, context: context)
      |> Ash.update()
    end

    defp delete_row(actor, row) do
      row
      |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, tenant: nil)
      |> Ash.destroy()
    end

    test "a master of the permission area renames no row into or out of what it does not hold",
         _ctx do
      master = holder(["admin:dashboard:permission"])
      star = permission!("*")
      own = permission!("admin:dashboard:permission")

      assert {:error, %Ash.Error.Forbidden{}} = rename(master, star, %{name: "retired:star"})
      assert {:error, %Ash.Error.Forbidden{}} = rename(master, own, %{name: "*"})

      assert {:error, %Ash.Error.Forbidden{}} =
               rename(master, permission!("admin:dashboard:runtime:media"), %{
                 name: "retired:media"
               })

      assert {:error, %Ash.Error.Forbidden{}} =
               rename(holder(["admin:dashboard:*"]), star, %{name: "admin:dashboard:probe_star"})

      assert Ash.get!(Permission, star.id, authorize?: false).name == "*"
      assert Ash.get!(Permission, own.id, authorize?: false).name == "admin:dashboard:permission"

      refute MishkaCmsCore.Accounts.Checks.AccessPermissions.match?(reload(master), %{},
               permissions: ["*"]
             )
    end

    test "a master renames a row within what it holds, and describes any row", _ctx do
      master = holder(["admin:dashboard:*"])
      row = permission!("admin:dashboard:probe_before")

      assert {:ok, renamed} = rename(master, row, %{name: "admin:dashboard:probe_after"})
      assert renamed.name == "admin:dashboard:probe_after"

      assert {:ok, described} =
               rename(holder(["admin:dashboard:permission"]), permission!("*"), %{
                 description: "Everything within the holder's site"
               })

      assert described.name == "*"
    end

    test "a master of the permission area deletes no row it does not hold", _ctx do
      master = holder(["admin:dashboard:permission"])

      assert {:error, %Ash.Error.Forbidden{}} = delete_row(master, permission!("*"))
      assert Ash.get!(Permission, permission!("*").id, authorize?: false)

      assert :ok =
               delete_row(
                 holder(["admin:dashboard:*"]),
                 permission!("admin:dashboard:probe_gone")
               )
    end

    test "the permissions table deletes many rows only within what its master holds", _ctx do
      master = holder(["admin:dashboard:*"])
      star = permission!("*")
      probe = permission!("admin:dashboard:probe_many")

      assert %Ash.BulkResult{status: :error} = bulk_delete(Permission, :destroy, master, [star])
      assert Ash.get!(Permission, star.id, authorize?: false)

      assert %Ash.BulkResult{status: :success} =
               bulk_delete(Permission, :destroy, master, [probe])

      assert {:error, _} = Ash.get(Permission, probe.id, authorize?: false)
    end

    test "on the API a master of the API's permission area renames no row it does not hold",
         _ctx do
      master = holder(["admin:api:permission"])

      assert {:error, %Ash.Error.Forbidden{}} =
               rename(master, permission!("*"), %{name: "retired:star"}, @api)

      assert {:ok, _} =
               rename(
                 holder(["admin:api:*"]),
                 permission!("admin:api:probe_before"),
                 %{name: "admin:api:probe_after"},
                 @api
               )
    end
  end

  describe "the grant rows" do
    defp grant_rows(actor, context \\ %{}) do
      UserPermission
      |> Ash.Query.for_read(:read, %{}, actor: actor, context: context)
      |> Ash.read()
    end

    test "the permission area reads its site's grant rows; the user area reads none", ctx do
      target = holder(["admin:dashboard:runtime:media"], ctx.site.id)

      {:ok, rows} = grant_rows(holder(["admin:dashboard:permission"], ctx.site.id))
      assert Enum.any?(rows, &(&1.user_id == target.id))

      assert {:ok, []} = grant_rows(holder(["admin:dashboard:user"], ctx.site.id))
    end

    defp write_grant(actor, user, name) do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, actor: actor)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(name).id)
      |> Ash.create(actor: actor)
    end

    test "a master of the permission area writes a row; a master of the user area does not",
         ctx do
      assert {:error, _} =
               write_grant(
                 holder(["admin:dashboard:user", "admin:dashboard:runtime:media"]),
                 ctx.member,
                 "admin:dashboard:runtime:media"
               )

      assert {:ok, _} =
               write_grant(
                 holder(["admin:dashboard:permission", "admin:dashboard:runtime:media"]),
                 ctx.member,
                 "admin:dashboard:runtime:media"
               )
    end

    test "a master of the permission area writes no grant beyond what it holds", ctx do
      master = holder(["admin:dashboard:permission"])

      assert {:error, %Ash.Error.Forbidden{}} = write_grant(master, master, "*")
      assert {:error, %Ash.Error.Forbidden{}} = write_grant(master, ctx.member, "*")
      assert names_of(master) == ["admin:dashboard:permission"]
      assert names_of(ctx.member) == []
    end
  end
end
