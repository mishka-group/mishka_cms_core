# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Sidebar.MenuSettings do
  @moduledoc """
  Registers every sidebar entry's position and on/off switch with the Settings page, through the
  `"settings:register"` mishka_installer hook — the same plugin shape
  `MishkaCmsCore.Dashboard.WidgetSettings` uses for widgets.

  It walks `MishkaCmsCore.Sidebar.collect/0`, so an extension that adds a menu gets its settings for
  free: there is no second list to keep in step, and no core file to edit when an extension ships a
  new section. Definitions land in the **Sidebar** tab, grouped by the section each entry belongs
  to, and each inherits the entry's own permissions so an admin is never shown a switch for a menu
  they cannot see.

  Registration priority is deliberately late (60): `Settings.load_definitions/0` calls every
  `settings:register` plugin, and this one is the only one whose definitions depend on OTHER plugins
  having registered first. Should this still run before an extension's `sidebar:menus` plugin is up,
  the settings page re-aggregates on mount (`MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive`)
  and the missing entries appear — and the sidebar itself never depended on the definitions, since
  every read passes the declared value as its default.

  Registered in MishkaCmsCore.Application.
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 60}

  alias MishkaCmsCore.Sidebar

  @impl true
  def call(%{definitions: definitions} = data),
    do: {:reply, %{data | definitions: definitions ++ Sidebar.settings_definitions()}}
end
