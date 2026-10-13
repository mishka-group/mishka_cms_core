defmodule MishkaCmsCore.Runtime.TranslationShareCards do
  @moduledoc """
  A plain mishka_installer plugin: after a translation of a site's name is saved
  (`cms_core:translation:after_save` — a row whose key is the `site.title` setting,
  `MishkaCmsCore.Runtime.Seo.site_name/2`), every share card of that site is looked at again in
  the background (`MishkaCmsCore.Runtime.ShareCard.redraw_all/2`); for a global row, of every
  active site named so. Only a card whose data changed is drawn. Registered in
  `MishkaCmsCore.Application`.
  """
  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaCmsCore.Runtime.Translation),
    initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.{ShareCard, SiteShareCards}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @impl true
  def call(%{key: key, site_id: site_id} = translation, _meta) when is_binary(key) do
    for id <- sites(site_id),
        Settings.get("site.title", nil, id) == key,
        do: ShareCard.redraw_all(id, schedule_in: SiteShareCards.delay())

    {:reply, translation}
  end

  def call(translation, _meta), do: {:reply, translation}

  defp sites(site_id) when is_binary(site_id), do: [site_id]
  defp sites(_global), do: Enum.map(SiteState.get_active_sites(), & &1.id)
end
