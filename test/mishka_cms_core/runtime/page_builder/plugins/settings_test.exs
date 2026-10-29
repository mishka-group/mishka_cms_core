# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Plugins.SettingsTest do
  @moduledoc """
  The editor's own settings, from its `settings:register` plugin: one prefix definition that lets
  any name opening a builder write the keys the editor keeps for itself — the Studio's switches and
  the component presets — and the two switches of the mention notification.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Runtime.PageBuilder.Mentions
  alias MishkaCmsCore.Runtime.PageBuilder.Plugins.Settings, as: BuilderSettings
  alias MishkaCmsCore.Runtime.PageBuilder.Presets
  alias MishkaCmsCore.Runtime.Setting
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  setup do
    snapshot = SettingsState.snapshot()
    Settings.load_definitions()
    on_exit(fn -> SettingsState.restore(snapshot) end)

    {:ok, site: create_site!()}
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

  describe "the builder's own settings" do
    test "are written by any name that opens a builder, and not by the setting area alone", ctx do
      builders = Enum.map(BuilderSettings.opens(), &holder([&1], ctx.site.id))
      settings_admin = holder(["admin:dashboard:setting"], ctx.site.id)

      for key <- ["cms_builder.studio.lock_tokens", Presets.key("probe_card")] do
        for builder <- builders, do: assert({:ok, _} = tenant_set(builder, ctx.site, key, true))
        assert {:error, _} = tenant_set(settings_admin, ctx.site, key, false)
      end
    end

    test "are every cms_builder key, under one prefix that names no setting" do
      assert Settings.write_permission("cms_builder.studio.dark_pair") == BuilderSettings.opens()
      assert String.starts_with?(Presets.key("chelekom-button"), "cms_builder.")
      assert Settings.definition("cms_builder.") == nil
      refute Enum.any?(Settings.definitions(), &(&1.key == "cms_builder."))
    end
  end

  describe "the mention notification" do
    test "has a site switch and a personal one, under the keys delivery reads" do
      type = Mentions.notification_type()

      assert %{scope: :both, category: "notifications", default: true} =
               Settings.definition(Notify.setting_key(type))

      assert %{scope: :user, category: "preferences", default: true} =
               Settings.definition(Notify.user_setting_key(type))

      assert Notify.setting_key(type) == "notify.cms_builder.page_comment.mentioned"
      assert Notify.user_setting_key(type) == "notify.pref.cms_builder.page_comment.mentioned"
    end
  end
end
