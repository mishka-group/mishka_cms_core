defmodule MishkaCmsCore.Dashboard.WidgetAccessTest do
  @moduledoc """
  Who a dashboard widget answers to.

  Three things decide that, and they are independent: WHICH permissions the viewer holds (does the
  widget appear at all), WHICH site they belong to (whose rows its `load` may read), and WHO they
  are (whose saved configuration it reads back). Each is exercised here against the same three
  actors — a master with roles, a tenant with roles, and a tenant with none.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Dashboard.Widget

  setup do
    site = create_site!()

    %{
      site: site,
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      roleless: create_user!(site_id: site.id)
    }
  end

  defp widget(overrides) do
    {:ok, widget} =
      Map.merge(
        %{
          id: "w",
          title: "W",
          component: {__MODULE__, :render},
          permission: "admin:dashboard:*"
        },
        overrides
      )
      |> Widget.builder()

    widget
  end

  describe "scope/1 — the master vs missing-user distinction" do
    test "a master scopes to nil, meaning every site", %{master: master} do
      assert Widget.scope(master) == nil
    end

    test "a tenant scopes to its own site and nothing else", %{tenant: tenant, site: site} do
      assert Widget.scope(tenant) == site.id
    end

    test "a user with no roles still scopes to its site — permissions are a separate gate", %{
      roleless: roleless,
      site: site
    } do
      assert Widget.scope(roleless) == site.id
    end

    # The whole point of the change: `nil` used to be accepted and returned `nil`, which every
    # widget's `scope_filter(query, nil)` reads as "no filter" — so a caller that had lost its user
    # quietly read every tenant's data. A master is a user with `site_id: nil`, never no user.
    test "a missing user raises instead of reading as a master" do
      assert_raise ArgumentError, ~r/needs the viewing user/, fn -> Widget.scope(nil) end
    end

    test "a map with no site_id raises rather than defaulting to every site" do
      assert_raise ArgumentError, ~r/needs the viewing user/, fn ->
        Widget.scope(%{id: Ecto.UUID.generate()})
      end
    end
  end

  describe "collect/1 — permissions decide which widgets exist" do
    test "a widget naming a permission is hidden from someone without it", %{
      tenant: tenant,
      roleless: roleless
    } do
      gated = widget(%{permission: "admin:dashboard:*"})

      assert Widget.permitted?(gated, tenant)
      refute Widget.permitted?(gated, roleless)
    end

    test "a master with the permission sees it too", %{master: master} do
      assert Widget.permitted?(widget(%{permission: "admin:dashboard:*"}), master)
    end

    test "a widget naming several permissions needs only one of them", %{tenant: tenant} do
      assert Widget.permitted?(widget(%{permission: ["nope:*", "admin:dashboard:*"]}), tenant)
      refute Widget.permitted?(widget(%{permission: ["nope:*", "also:nope:*"]}), tenant)
    end

    test "a widget naming no permission is visible to everyone, roles or not", %{
      roleless: roleless
    } do
      assert Widget.permitted?(widget(%{permission: nil}), roleless)
      assert Widget.permitted?(widget(%{permission: []}), roleless)
    end

    test "nobody is never permitted, whatever the widget declares" do
      refute Widget.permitted?(widget(%{permission: nil}), nil)
      refute Widget.permitted?(widget(%{permission: "admin:dashboard:*"}), nil)
    end
  end

  describe "config — one admin cannot read or write another's" do
    setup do
      %{
        configurable:
          widget(%{
            id: "cfg",
            config: [%{key: "count", type: :integer, label: "Rows", default: 4, min: 1, max: 12}]
          })
      }
    end

    test "two admins on the same widget keep separate values", %{
      configurable: configurable,
      master: master,
      tenant: tenant
    } do
      assert {:ok, 9} = Widget.set_config(master, configurable, "count", "9")
      assert {:ok, 2} = Widget.set_config(tenant, configurable, "count", "2")

      assert Widget.config(configurable, master) == %{"count" => 9}
      assert Widget.config(configurable, tenant) == %{"count" => 2}
    end

    test "an admin who has saved nothing gets the declared default, not a neighbour's value", %{
      configurable: configurable,
      master: master,
      tenant: tenant
    } do
      assert {:ok, 9} = Widget.set_config(master, configurable, "count", "9")

      assert Widget.config(configurable, tenant) == %{"count" => 4}
    end

    test "a tenant without roles still owns its own preference", %{
      configurable: configurable,
      roleless: roleless
    } do
      assert {:ok, 3} = Widget.set_config(roleless, configurable, "count", "3")
      assert Widget.config(configurable, roleless) == %{"count" => 3}
    end

    test "the value is clamped to the widget's own bounds however it is written", %{
      configurable: configurable,
      tenant: tenant
    } do
      assert {:ok, 12} = Widget.set_config(tenant, configurable, "count", "500")
      assert {:ok, 1} = Widget.set_config(tenant, configurable, "count", "-9")
    end

    test "a key the widget never declared writes nothing", %{
      configurable: configurable,
      tenant: tenant
    } do
      assert :error = Widget.set_config(tenant, configurable, "sneaky", "1")
      assert Widget.config(configurable, tenant) == %{"count" => 4}
    end

    test "a value the declaration cannot coerce writes nothing", %{
      configurable: configurable,
      tenant: tenant
    } do
      assert :error = Widget.set_config(tenant, configurable, "count", "abc")
      assert Widget.config(configurable, tenant) == %{"count" => 4}
    end

    test "there is no user to write for, so nothing is written", %{configurable: configurable} do
      assert :error = Widget.set_config(nil, configurable, "count", "9")
      assert Widget.config(configurable, nil) == %{"count" => 4}
    end
  end
end
