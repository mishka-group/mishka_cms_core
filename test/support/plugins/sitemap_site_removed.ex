defmodule MishkaCmsCore.Test.Plugins.SitemapSiteRemoved do
  @moduledoc """
  Test plugin for `seo:sitemap:urls`: removes the site it is handed from `SiteState` and adds
  nothing — a site removed while its sitemap is being built.
  """
  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls"

  @impl true
  def call(%{site: site} = data) do
    :ok = MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
    {:reply, data}
  end
end
