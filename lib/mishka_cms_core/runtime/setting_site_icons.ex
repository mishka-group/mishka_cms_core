# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SettingSiteIcons do
  @moduledoc """
  A plain mishka_installer plugin: after the `site.app_icon` or the `site.favicon` setting is saved
  (`cms_core:setting:after_save`, `MishkaCmsCore.Runtime.SiteIcon.settings/0`), what is kept of its
  site's icons is dropped — of every site for a global value — and the next request for one draws
  them from the new picture (`MishkaCmsCore.Runtime.SiteIcon.forget/1`). Registered in
  MishkaCmsCore.Application.
  """
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaCmsCore.Runtime.Setting),
    initial: %{priority: 62}

  alias MishkaCmsCore.Runtime.SiteIcon

  @impl true
  def call(%{key: key, site_id: site_id} = setting, _meta) do
    if key in SiteIcon.settings(), do: SiteIcon.forget(site_id)
    {:reply, setting}
  end

  def call(setting, _meta), do: {:reply, setting}
end
