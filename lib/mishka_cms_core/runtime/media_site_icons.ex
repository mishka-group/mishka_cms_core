# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.MediaSiteIcons do
  @moduledoc """
  A plain mishka_installer plugin: after a media file is saved (`cms_core:media:after_save` —
  replaced in place, archived), what is kept of its site's icons is dropped when the site's
  favicon or the picture of its icons is that file, and the next request for one reads it again
  (`MishkaCmsCore.Runtime.SiteIcon.forget_file/2`). Registered in `MishkaCmsCore.Application`.
  """
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaCmsCore.Runtime.Media),
    initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.SiteIcon

  @impl true
  def call(%{relative_path: path, site_id: site_id} = media, _meta)
      when is_binary(path) and is_binary(site_id) do
    SiteIcon.forget_file(site_id, path)
    {:reply, media}
  end

  def call(media, _meta), do: {:reply, media}
end
