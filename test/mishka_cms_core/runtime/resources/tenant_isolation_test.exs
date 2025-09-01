defmodule MishkaCmsCore.Runtime.Resources.Validations.TenantIsolationTest do
  @moduledoc """
  A write may name only a record of the site it is made for.

  A site user writes for its own site and no other: naming another site as the tenant does not make
  that site's records its own. A master writes for whichever site it names. A visitor with no actor
  writes for the site it is visiting.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.{User, UserPermission}
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation

  setup do
    site_a = create_site!()
    site_b = create_site!()
    {:ok, opts} = TenantIsolation.init(field: :user_id, resource: User)

    {:ok,
     opts: opts,
     site_a: site_a,
     site_b: site_b,
     user_a: create_user!(site_id: site_a.id),
     other_a: create_user!(site_id: site_a.id),
     user_b: create_user!(site_id: site_b.id),
     master: create_user_with_permissions!(["*"])}
  end

  defp naming(id) do
    UserPermission
    |> Ash.Changeset.new()
    |> Ash.Changeset.change_attribute(:user_id, id)
  end

  defp validate(ctx, id, tenant, actor) do
    TenantIsolation.validate(naming(id), ctx.opts, %Ash.Resource.Validation.Context{
      tenant: tenant,
      actor: actor,
      authorize?: true
    })
  end

  test "a site user names a record of its own site", ctx do
    assert :ok = validate(ctx, ctx.other_a.id, ctx.site_a.id, ctx.user_a)
    assert :ok = validate(ctx, ctx.other_a.id, nil, ctx.user_a)
  end

  test "a site user names no record of another site, even with that site as the tenant", ctx do
    assert {:error, field: :user_id, message: message} =
             validate(ctx, ctx.user_b.id, ctx.site_b.id, ctx.user_a)

    assert message =~ "does not belong to your site"
  end

  test "a site user names no record of its own site under another site's tenant", ctx do
    assert {:error, field: :user_id, message: _} =
             validate(ctx, ctx.other_a.id, ctx.site_b.id, ctx.user_a)
  end

  test "a site user with no tenant names no record of another site", ctx do
    assert {:error, field: :user_id, message: _} = validate(ctx, ctx.user_b.id, nil, ctx.user_a)
  end

  test "a master names a record of the site it names", ctx do
    assert :ok = validate(ctx, ctx.user_b.id, ctx.site_b.id, ctx.master)
    assert {:error, _} = validate(ctx, ctx.user_b.id, ctx.site_a.id, ctx.master)
  end

  test "with no site to hold it to, a master names any record as an admin of the write's surface",
       ctx do
    api_master = create_user_with_permissions!(["admin:api:user"])

    api_write =
      Ash.Changeset.set_context(naming(ctx.user_b.id), %{shared: %{admin_surface: :api}})

    no_tenant = fn changeset, actor ->
      TenantIsolation.validate(changeset, ctx.opts, %Ash.Resource.Validation.Context{
        tenant: nil,
        actor: actor,
        authorize?: true
      })
    end

    assert :ok = no_tenant.(api_write, api_master)
    assert {:error, _} = no_tenant.(naming(ctx.user_b.id), api_master)
  end

  test "a visitor with no actor names a record of the site it visits", ctx do
    assert :ok = validate(ctx, ctx.user_b.id, ctx.site_b.id, nil)
    assert {:error, _} = validate(ctx, ctx.user_b.id, ctx.site_a.id, nil)
  end

  test "a system call is not checked", ctx do
    assert :ok =
             TenantIsolation.validate(
               naming(ctx.user_b.id),
               ctx.opts,
               %Ash.Resource.Validation.Context{
                 tenant: ctx.site_b.id,
                 actor: ctx.user_a,
                 authorize?: false
               }
             )
  end
end
