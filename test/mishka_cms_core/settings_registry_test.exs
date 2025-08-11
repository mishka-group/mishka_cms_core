defmodule MishkaCmsCore.Settings.RegistryTest do
  @moduledoc """
  Real tests for the modular settings registry: it aggregates extension `Provider` definitions
  (config) AND runtime-plugin definitions (the `settings:register` mishka_installer hook), seeds the
  defaults into the durable store, and notifies plugins via `cms_core:setting:after_master_set` on a
  write. The registry cache (`:persistent_term`) and the settings ETS are process-global, so each test
  starts from a clean cache, resets both in `on_exit`, and unregisters its plugins.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.Plugins.{SettingsAfterChangeProbe, SettingsRegisterProbe}
  alias MishkaInstaller.Event.{Event, EventHandler}

  setup do
    # Start from a clean cache: another file's setting write may have leaked into the process-global
    # ETS (it isn't sandboxed), which would make `load_definitions/0`'s "seed if missing" skip a default.
    SettingsState.refresh()

    snapshot = SettingsState.snapshot()

    on_exit(fn ->
      :persistent_term.erase({Settings, :definitions})
      SettingsState.restore(snapshot)
    end)

    :ok
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
  end

  test "load_definitions/0 aggregates the (config-listed) core provider and seeds its defaults into the store" do
    Settings.load_definitions()

    keys = Settings.definitions() |> Enum.map(& &1.key)
    assert "cms.offline" in keys
    assert "mailer.from" in keys

    # Defaults were written through to the durable store + RAM cache.
    assert Settings.get("cms.offline") == false
    assert Settings.get("mailer.from") == ""
  end

  test "by_category/1 and categories/0 group the definitions for the settings page" do
    Settings.load_definitions()

    assert "general" in Settings.categories()
    assert "notifications" in Settings.categories()
    assert Enum.any?(Settings.definitions("general"), &(&1.key == "cms.offline"))
  end

  test "a runtime plugin contributes its own config via the settings:register hook" do
    register_plugin(SettingsRegisterProbe, "settings:register")
    on_exit(fn -> Event.unregister(:name, SettingsRegisterProbe, false) end)

    Settings.load_definitions()

    assert %{key: "test.plugin_setting", source: :plugin} =
             Settings.definition("test.plugin_setting")

    assert Settings.get("test.plugin_setting") == "from-plugin"
  end

  test "Settings.put/3 notifies plugins via the resource's cms_core:setting:after_master_set hook" do
    Process.register(self(), :__settings_probe__)
    register_plugin(SettingsAfterChangeProbe, "cms_core:setting:after_master_set")
    on_exit(fn -> Event.unregister(:name, SettingsAfterChangeProbe, false) end)

    {:ok, _} = Settings.put("site.title", "Changed Title")

    # The notifier hands plugins the changed record (value stored wrapped) + the read-only meta.
    assert_receive {:settings_after_change,
                    %{key: "site.title", value: %{"value" => "Changed Title"}},
                    %{actor: _, site_id: _}},
                   5000
  end
end
