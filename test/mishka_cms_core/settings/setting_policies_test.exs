defmodule MishkaCmsCore.Runtime.SettingPoliciesTest do
  @moduledoc """
  The authorization boundary on `MishkaCmsCore.Runtime.Setting`.

  Settings live in one table shared by every site: a row with `site_id = nil` is the GLOBAL value
  and a row with a `site_id` is that site's override. The permission that writes a setting
  (`admin:dashboard:setting`, or a wildcard covering it) is held by every site's settings admin, so
  it cannot be the only gate — these tests pin the second one: a master writes any site and the
  global row, a tenant writes only its own, and someone with no roles writes nothing at all.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Setting

  require Ash.Query

  setup do
    forget_settings(~w(cms.offline site.title))

    site = create_site!()
    other_site = create_site!()

    %{
      site: site,
      other_site: other_site,
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      other_tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: other_site.id),
      roleless: create_user!(site_id: site.id)
    }
  end

  defp master_set(actor, params, opts \\ []) do
    Setting
    |> Ash.Changeset.for_create(:master_set, params, [actor: actor, tenant: nil] ++ opts)
    |> Ash.create()
  end

  defp tenant_set(actor, tenant, params) do
    Setting
    |> Ash.Changeset.for_create(:set, params, actor: actor, tenant: tenant)
    |> Ash.create()
  end

  defp value(%{value: %{"value" => value}}), do: value

  # A tenant reaching for a master-only action is stopped twice over: the action's own
  # `TenantContext` validate rejects it (an `Invalid`, raised before policies run) AND the policies
  # would refuse it anyway. The validate wins the race, so that is what an end-to-end call returns.
  # The validate is also the layer `authorize?: false` may skip, so every use of this pairs with a
  # `can_master_set?/2` that reads the policy verdict on its own.
  defp assert_master_action_refused(result) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} = result

    assert Enum.any?(errors, fn
             %Ash.Error.Changes.InvalidChanges{message: message} ->
               message =~ "requires a master user"

             _other ->
               false
           end)
  end

  # `maybe_is: false` because the default is optimistic: a policy Ash cannot settle without looking
  # at data answers "maybe", which `can?/3` reports as `true`. These assertions are about the
  # verdict, so an undecided policy has to read as a refusal.
  defp can_master_set?(actor, params) do
    Ash.can?({Setting, :master_set, params}, actor, tenant: nil, maybe_is: false)
  end

  describe "master user with roles" do
    test "writes the GLOBAL row", %{master: master} do
      assert {:ok, setting} = master_set(master, %{key: "cms.offline", value: %{"value" => true}})
      assert is_nil(setting.site_id)
      assert value(setting) == true
    end

    test "writes ANY site's row, including one it does not belong to", %{
      master: master,
      site: site,
      other_site: other_site
    } do
      assert {:ok, one} =
               master_set(master, %{
                 key: "site.title",
                 value: %{"value" => "A"},
                 site_id: site.id
               })

      assert {:ok, two} =
               master_set(master, %{
                 key: "site.title",
                 value: %{"value" => "B"},
                 site_id: other_site.id
               })

      assert one.site_id == site.id
      assert two.site_id == other_site.id
    end

    test "may also act through the tenant action on any site", %{master: master, site: site} do
      assert {:ok, setting} =
               tenant_set(master, site.id, %{key: "site.title", value: %{"value" => "A"}})

      assert setting.site_id == site.id
    end
  end

  describe "tenant user with roles" do
    test "writes its OWN site's row", %{tenant: tenant, site: site} do
      assert {:ok, setting} =
               tenant_set(tenant, site.id, %{key: "site.title", value: %{"value" => "Mine"}})

      assert setting.site_id == site.id
      assert value(setting) == "Mine"
    end

    test "is REFUSED another site's row through the tenant action", %{
      tenant: tenant,
      other_site: other_site
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(tenant, other_site.id, %{
                 key: "site.title",
                 value: %{"value" => "Theirs"}
               })
    end

    test "is REFUSED another site's row through the master action", %{
      tenant: tenant,
      other_site: other_site
    } do
      params = %{key: "site.title", value: %{"value" => "Theirs"}, site_id: other_site.id}

      assert_master_action_refused(master_set(tenant, params))
      refute can_master_set?(tenant, params)
    end

    test "is REFUSED the shared GLOBAL row", %{tenant: tenant} do
      params = %{key: "cms.offline", value: %{"value" => true}}

      assert_master_action_refused(master_set(tenant, params))
      refute can_master_set?(tenant, params)
    end

    test "cannot reach another site by writing its own row first", %{
      tenant: tenant,
      site: site,
      other_site: other_site
    } do
      assert {:ok, _} =
               tenant_set(tenant, site.id, %{key: "site.title", value: %{"value" => "Mine"}})

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(tenant, other_site.id, %{
                 key: "site.title",
                 value: %{"value" => "Mine"}
               })

      assert Setting
             |> Ash.Query.filter(key == "site.title" and site_id == ^other_site.id)
             |> Ash.read!(action: :read_any, authorize?: false) == []
    end
  end

  describe "tenant user without roles" do
    test "is REFUSED its own site's row", %{roleless: roleless, site: site} do
      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(roleless, site.id, %{key: "site.title", value: %{"value" => "Nope"}})
    end

    test "is REFUSED the global row", %{roleless: roleless} do
      params = %{key: "cms.offline", value: %{"value" => true}}

      assert_master_action_refused(master_set(roleless, params))
      refute can_master_set?(roleless, params)
    end

    test "holding an unrelated permission is not enough", %{site: site} do
      bystander =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(bystander, site.id, %{key: "site.title", value: %{"value" => "Nope"}})
    end
  end

  describe "no actor" do
    test "is REFUSED even on the global row" do
      assert {:error, %Ash.Error.Forbidden{}} =
               master_set(nil, %{key: "cms.offline", value: %{"value" => true}})
    end

    test "is REFUSED on a tenant row", %{site: site} do
      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(nil, site.id, %{key: "site.title", value: %{"value" => "Nope"}})
    end
  end

  describe "two tenants in the same table" do
    test "neither can write into the other's site", %{
      tenant: tenant,
      other_tenant: other_tenant,
      site: site,
      other_site: other_site
    } do
      params = %{key: "site.title", value: %{"value" => "x"}}

      assert {:error, %Ash.Error.Forbidden{}} = tenant_set(tenant, other_site.id, params)
      assert {:error, %Ash.Error.Forbidden{}} = tenant_set(other_tenant, site.id, params)
    end

    test "each still sees only its own value under the same key", %{
      tenant: tenant,
      other_tenant: other_tenant,
      site: site,
      other_site: other_site
    } do
      assert {:ok, _} =
               tenant_set(tenant, site.id, %{key: "site.title", value: %{"value" => "Mine"}})

      assert {:ok, _} =
               tenant_set(other_tenant, other_site.id, %{
                 key: "site.title",
                 value: %{"value" => "Theirs"}
               })

      assert [mine] =
               Setting
               |> Ash.Query.filter(key == "site.title")
               |> Ash.read!(actor: tenant, tenant: site.id)

      assert value(mine) == "Mine"
    end
  end

  describe "the trusted infra path" do
    test "still bypasses every policy, which is what boot seeding relies on", %{site: site} do
      assert {:ok, setting} =
               master_set(nil, %{key: "seeded", value: %{"value" => 1}, site_id: site.id},
                 authorize?: false
               )

      assert setting.site_id == site.id
    end
  end
end
