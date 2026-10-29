# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Settings.PrefixDefinitionsTest do
  @moduledoc """
  A definition that covers every key under a prefix (`match: :prefix`).

  An extension writes keys of its own that no definition names — a switch per site, a preset per
  component — and gates them with one definition whose `:permission` is all that is read. The
  longest prefix a key starts with wins, an exact definition wins over every prefix, and a key no
  definition covers takes the setting area. A prefix definition names no setting: it is never
  listed, seeded or drawn.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.Plugins.PrefixSettingsProbe, as: Probe
  alias MishkaInstaller.Event.{Event, EventHandler}

  @event "settings:register"

  setup do
    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      Settings.load_definitions()
      SettingsState.restore(snapshot)
    end)

    {:ok, site: create_site!()}
  end

  defp register_probe! do
    {:ok, _} =
      Event.write(%{name: Probe, event: @event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(@event, :start, false)
    on_exit(fn -> Event.unregister(:name, Probe, false) end)
  end

  defp holder(names, site_id), do: create_user_with_permissions!(names, site_id: site_id)

  defp tenant_set(actor, site, key, value) do
    Setting
    |> Ash.Changeset.for_create(:set, %{key: key, value: %{"value" => value}},
      actor: actor,
      tenant: site.id
    )
    |> Ash.create()
  end

  describe "a key under a prefix" do
    setup do
      register_probe!()
      Settings.load_definitions()
      :ok
    end

    test "takes the permission the prefix declares" do
      assert Settings.write_permission("acme.k") == [Probe.prefix_permission()]
      assert Settings.write_permission("acme.studio.lock") == [Probe.prefix_permission()]
    end

    test "takes the longest prefix it starts with" do
      assert Settings.write_permission("acme.deep.k") == [Probe.deep_permission()]
    end

    test "takes what an exact definition declares over any prefix" do
      assert Settings.write_permission("acme.exact") == [Probe.exact_permission()]
    end

    test "a key the prefix does not start takes the setting area" do
      assert Settings.write_permission("acme") == ["admin:dashboard:setting"]
      assert Settings.write_permission("acmeish.k") == ["admin:dashboard:setting"]
    end

    test "is written by that permission, and not by the setting area", %{site: site} do
      assert {:ok, _} =
               tenant_set(holder([Probe.prefix_permission()], site.id), site, "acme.k", true)

      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(holder(["admin:dashboard:setting"], site.id), site, "acme.k", false)
    end
  end

  describe "a prefix definition" do
    setup do
      register_probe!()
      Settings.load_definitions()
      :ok
    end

    test "is never one of the definitions" do
      keys = Enum.map(Settings.definitions(), & &1.key)

      assert "acme.exact" in keys
      refute "acme." in keys
      refute "acme.deep." in keys
      assert Settings.definition("acme.") == nil
      refute Enum.any?(Settings.definitions("general"), &(&1.key in ["acme.", "acme.deep."]))
    end

    test "is never seeded" do
      refute Map.has_key?(Settings.all_global(), "acme.")
      refute Map.has_key?(Settings.all_global(), "acme.deep.")
      assert Map.has_key?(Settings.all_global(), "acme.exact")
    end
  end

  describe "a prefix registered after the definitions were loaded" do
    test "gates its keys without waiting for the next load" do
      Settings.load_definitions()
      register_probe!()

      assert Settings.write_permission("acme.k") == [Probe.prefix_permission()]
      assert Settings.definition("acme.") == nil
    end
  end
end
