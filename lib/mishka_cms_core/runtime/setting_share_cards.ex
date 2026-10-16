# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SettingShareCards do
  @moduledoc """
  A plain mishka_installer plugin: after a setting every core share card shows is saved
  (`cms_core:setting:after_save`, `MishkaCmsCore.Runtime.ShareCard.site_settings/0` — the site's
  name and logo), every share card of its site is looked at again in the background
  (`MishkaCmsCore.Runtime.ShareCard.redraw_all/2`), of every active site for a global value. Only a
  card whose data changed is drawn. Registered in `MishkaCmsCore.Application`.
  """
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaCmsCore.Runtime.Setting),
    initial: %{priority: 61}

  alias MishkaCmsCore.Runtime.{ShareCard, SiteShareCards}

  @impl true
  def call(%{key: key, site_id: site_id} = setting, _meta) do
    if key in ShareCard.site_settings(),
      do: ShareCard.redraw_all(site_id, schedule_in: SiteShareCards.delay())

    {:reply, setting}
  end

  def call(setting, _meta), do: {:reply, setting}
end
