defmodule MishkaCmsCore.Runtime.SiteShareCards do
  @moduledoc """
  A plain mishka_installer plugin: after a site is edited (`cms_core:site:after_update` — its
  address or its name), every share card of it is looked at again in the background
  (`MishkaCmsCore.Runtime.ShareCard.redraw_all/2`), and a card that shows the old address is drawn
  with the new one before anybody visits the page. The saves of a burst are one look. Registered
  in `MishkaCmsCore.Application`.
  """
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.event_name(MishkaCmsCore.Runtime.Site, :update),
    initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.ShareCard

  @doc "How many seconds a look waits for the rest of a burst of saves."
  @spec delay() :: pos_integer()
  def delay, do: 10

  @impl true
  def call(%{id: site_id} = site, _meta) when is_binary(site_id) do
    _ = ShareCard.redraw_all(site_id, schedule_in: delay())
    {:reply, site}
  end

  def call(site, _meta), do: {:reply, site}
end
