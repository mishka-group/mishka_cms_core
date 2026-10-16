# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Settings.SettingAreasTest do
  @moduledoc """
  Which permission writes a setting: the one its definition declares, or `admin:dashboard:setting`
  when it declares none — the extension switches included. A declared `admin:dashboard:setting:<key>`
  is not covered by the leaf `admin:dashboard:setting`; `admin:dashboard:*` covers both. Each gate is
  asked as a holder of that one name and as a holder of another area.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.Plugins.GatedSettingsProvider

  setup do
    snapshot = SettingsState.snapshot()
    Application.put_env(:mishka_cms_core, :settings_providers, [GatedSettingsProvider])
    Settings.load_definitions()

    on_exit(fn ->
      Application.put_env(:mishka_cms_core, :settings_providers, [])
      Settings.load_definitions()
      SettingsState.restore(snapshot)
    end)

    {:ok, site: create_site!()}
  end

  defp holder(names, site_id \\ nil), do: create_user_with_permissions!(names, site_id: site_id)

  defp master_set(actor, key, value) do
    Setting
    |> Ash.Changeset.for_create(:master_set, %{key: key, value: %{"value" => value}},
      actor: actor,
      tenant: nil
    )
    |> Ash.create()
  end

  defp tenant_set(actor, site, key, value) do
    Setting
    |> Ash.Changeset.for_create(:set, %{key: key, value: %{"value" => value}},
      actor: actor,
      tenant: site.id
    )
    |> Ash.create()
  end

  describe "a setting that declares no permission" do
    test "the setting area writes a site's own row; another area does not", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               tenant_set(
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 ctx.site,
                 "site.title",
                 "A"
               )

      assert {:ok, _} =
               tenant_set(
                 holder(["admin:dashboard:setting"], ctx.site.id),
                 ctx.site,
                 "site.title",
                 "B"
               )
    end

    test "a master of the setting area writes the global row; a master of another area does not",
         _ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               master_set(holder(["admin:dashboard:user"]), "cms.maintenance_message", "x")

      assert {:ok, _} =
               master_set(holder(["admin:dashboard:setting"]), "cms.maintenance_message", "y")
    end

    test "a key nobody declared takes the setting area too", _ctx do
      assert {:error, _} =
               master_set(holder(["admin:dashboard:runtime:page"]), "undeclared.key", 1)

      assert {:ok, _} = master_set(holder(["admin:dashboard:setting"]), "undeclared.key", 1)
    end

    test "deleting a row takes the setting area too", _ctx do
      {:ok, row} = master_set(holder(["admin:dashboard:setting"]), "undeclared.gone", 1)

      destroy = fn actor ->
        row
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, actor: actor, tenant: nil)
        |> Ash.destroy()
      end

      assert {:error, _} = destroy.(holder(["admin:dashboard:runtime:page"]))
      assert :ok = destroy.(holder(["admin:dashboard:setting"]))
    end

    test "put_as follows the same rule", ctx do
      assert {:error, _} =
               Settings.put_as(
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 "site.title",
                 "C"
               )

      assert {:ok, "D"} =
               Settings.put_as(
                 holder(["admin:dashboard:setting"], ctx.site.id),
                 "site.title",
                 "D"
               )
    end
  end

  describe "the builder's own settings" do
    test "are written by any name that opens a builder, and not by the setting area alone", ctx do
      builders =
        Enum.map(
          [
            "admin:dashboard:runtime:page",
            "admin:dashboard:runtime:layout",
            "admin:dashboard:runtime:component",
            "admin:dashboard:runtime:error_page",
            "admin:dashboard:code"
          ],
          &holder([&1], ctx.site.id)
        )

      settings_admin = holder(["admin:dashboard:setting"], ctx.site.id)

      for key <- ["studio.lock_tokens", "builder:preset:probe_card"] do
        for builder <- builders, do: assert({:ok, _} = tenant_set(builder, ctx.site, key, true))
        assert {:error, _} = tenant_set(settings_admin, ctx.site, key, false)
      end
    end
  end

  describe "a setting that declares its own permission" do
    test "is written by that permission, not by the setting area", _ctx do
      assert {:error, _} = master_set(holder(["admin:dashboard:setting"]), "secret.token", "t1")

      assert {:ok, _} =
               master_set(holder([GatedSettingsProvider.permission()]), "secret.token", "t2")

      assert {:ok, _} = master_set(holder(["admin:dashboard:*"]), "secret.token", "t3")
    end
  end

  describe "who the settings page shows a setting to" do
    test "whoever may write it; a :user setting to everyone it is permitted to", ctx do
      page_admin = holder(["admin:dashboard:runtime:page"], ctx.site.id)
      setting_admin = holder(["admin:dashboard:setting"], ctx.site.id)
      secret = Settings.definition("secret.token")
      title = Settings.definition("site.title")
      preference = Settings.definition("notify.pref.cms_core.user.permissions_changed")

      assert Settings.write_permission(title) == ["admin:dashboard:setting"]
      assert Settings.write_permission("no.such.key") == ["admin:dashboard:setting"]
      assert Settings.write_permission(secret) == [GatedSettingsProvider.permission()]

      assert Settings.writable?(title, setting_admin)
      refute Settings.writable?(title, page_admin)
      refute Settings.writable?(secret, setting_admin)
      assert Settings.writable?(preference, page_admin)
      refute Settings.writable?(preference, nil)
    end
  end

  describe "the extension switches" do
    test "declare the setting area, and the setting area switches one", ctx do
      [installed, active] = Extensions.settings(:mishka_probe, "probe")

      assert active.permission == "admin:dashboard:setting"
      assert installed.permission == ["admin:dashboard:runtime:site", "admin:dashboard:setting"]

      # WHO RAN THE INSTALL HOLDS THE SITE AREA, and only they and the setting area see the record: a
      # pages-only admin is not shown an extension's tab for a line it may not write.
      assert Settings.writable?(installed, holder(["admin:dashboard:runtime:site"], ctx.site.id))
      refute Settings.writable?(installed, holder(["admin:dashboard:runtime:page"], ctx.site.id))

      Application.put_env(:mishka_cms_core, :settings_providers, [
        GatedSettingsProvider,
        MishkaCmsCore.Test.Plugins.ProbeExtensionSettings
      ])

      Settings.load_definitions()

      assert {:error, _} =
               tenant_set(
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 ctx.site,
                 "mishka_probe.active",
                 false
               )

      assert {:ok, _} =
               tenant_set(
                 holder(["admin:dashboard:setting"], ctx.site.id),
                 ctx.site,
                 "mishka_probe.active",
                 false
               )
    end

    test "record an install for the site area, which setting a site up takes", ctx do
      Application.put_env(:mishka_cms_core, :settings_providers, [
        MishkaCmsCore.Test.Plugins.ProbeExtensionSettings
      ])

      Settings.load_definitions()

      assert {:ok, _} =
               tenant_set(
                 holder(["admin:dashboard:runtime:site"], ctx.site.id),
                 ctx.site,
                 "mishka_probe.installed",
                 "1.0.0"
               )

      assert {:error, _} =
               tenant_set(
                 holder(["admin:dashboard:runtime:page"], ctx.site.id),
                 ctx.site,
                 "mishka_probe.installed",
                 "1.0.1"
               )

      assert {:error, _} =
               tenant_set(
                 holder(["admin:api:runtime:page"], ctx.site.id),
                 ctx.site,
                 "mishka_probe.installed",
                 "2"
               )
    end
  end
end
