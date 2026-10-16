# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageShareCard do
  @moduledoc """
  A plain mishka_installer plugin: after a page of a site is saved (`cms_core:page:after_save` —
  created, updated, published, a master's twin alike), its share card is looked at in the
  background and drawn when what it shows changed (`MishkaCmsCore.Runtime.ShareCard.refresh/3`), so
  it is ready before the first visitor. A save that leaves the card's title, description and picture
  alone draws nothing. A page that shows records is left to the plugins of those records' own
  after-save events. Registered in `MishkaCmsCore.Application`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaCmsCore.Runtime.Page),
    initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.ShareCard

  @impl true
  def call(%{id: id, site_id: site_id} = page, _meta) when is_binary(site_id) do
    ShareCard.refresh(site_id, {:page, id})
    {:reply, page}
  end

  def call(page, _meta), do: {:reply, page}
end
