defmodule MishkaCmsCore.Test.Plugins.SeoManyUrls do
  @moduledoc """
  Test plugin for `seo:sitemap:urls`: adds 50,001 addresses, one more than a sitemap file may hold,
  as a stream nothing reads before the build does.
  """
  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls"

  @impl true
  def call(%{urls: urls} = data) do
    added = Stream.map(1..50_001, &%{path: "/item/#{&1}", lastmod: nil})
    {:reply, %{data | urls: Stream.concat(urls, added)}}
  end
end
