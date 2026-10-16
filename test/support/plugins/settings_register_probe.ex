# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SettingsRegisterProbe do
  @moduledoc """
  Test plugin: contributes a setting definition through the `settings:register` hook — proving an
  extension/plugin can add its own config to the settings store without touching core.
  """
  use MishkaInstaller.Event.Hook, event: "settings:register"

  alias MishkaCmsCore.Settings

  @impl true
  def call(%{definitions: definitions} = data) do
    contributed =
      Settings.define("test.plugin_setting", :string,
        default: "from-plugin",
        category: "test",
        source: :plugin,
        label: "Plugin setting"
      )

    {:reply, %{data | definitions: definitions ++ [contributed]}}
  end
end
