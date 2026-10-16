# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dashboard.WidgetSettings do
  @moduledoc """
  Registers every CORE dashboard widget's own settings with the Settings page through the
  `settings:register` mishka_installer hook. Core widgets belong to no extension, so their settings
  land in the **General** tab (group **Dashboard widgets**) — the same place the rest of the CMS's
  own settings live.

  It walks `MishkaCmsCore.Application.dashboard_widgets/0` and asks each descriptor for its
  definitions (`MishkaCmsCore.Dashboard.Widget.settings_definitions/1`), which derives the key from
  `Widget.setting_key/2` — the same function the dashboard reads through. A widget that adds a
  setting is registered by declaring it; there is no second list to keep in step.

  Every definition is `scope: :user`: the value belongs to the admin reading the board, and both
  editors — the card's gear and this tab — write the same `Settings.put_user/3` row. Registered in
  `MishkaCmsCore.Application`.

  See `MishkaBlog.Dashboard.WidgetSettings` for an extension's copy of this plugin, and
  `MishkaCmsCore.Settings.define/3`.
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 30}

  alias MishkaCmsCore.Dashboard.Widget

  @impl true
  def call(%{definitions: definitions} = data) do
    widget_definitions =
      Enum.flat_map(
        MishkaCmsCore.Application.dashboard_widgets(),
        fn plugin -> Widget.settings_definitions(plugin.widget()) end
      )

    {:reply, %{data | definitions: definitions ++ widget_definitions}}
  end
end
