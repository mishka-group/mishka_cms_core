defmodule MishkaCmsCore.Test.Plugins.SeoSitemapUrls do
  @moduledoc """
  Test plugin for `seo:sitemap:urls`: reports the paths of the pages it was handed to the
  `:__plugin_hook_probe__` process, and adds an address of its own with its images, one the site's
  pages already name, one that is not a path, and one a URL may not hold as it is — proving a plugin
  lists what core cannot, without taking over an address a page holds, slipping in one off the site
  or breaking the file.

  Its addresses are a stream that tells the probe `:sitemap_urls_read` each time it starts being
  read, so a test can count how often a build reads the chain.
  """
  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls"

  @impl true
  def call(%{pages: pages, urls: urls} = data) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:sitemap_pages, Enum.map(pages, & &1.path)})

    added = [
      %{
        path: "/from-plugin",
        lastmod: ~U[2026-01-02 03:04:05.123456Z],
        images: [
          "/media/cover.png",
          "https://cdn.example.com/a.jpg",
          "//cdn.example.com/b.jpg",
          "https://cdn.example.com/a b.jpg",
          "https://cdn.example.com/c\x01.jpg",
          "https://",
          "cover.png",
          nil
        ]
      },
      %{path: "/about", lastmod: nil},
      %{path: "elsewhere.example/page", lastmod: nil},
      %{path: "/über uns", lastmod: nil}
    ]

    {:reply, %{data | urls: Stream.concat(urls, read_once(added))}}
  end

  defp read_once(added) do
    Stream.resource(
      fn ->
        if pid = Process.whereis(:__plugin_hook_probe__), do: send(pid, :sitemap_urls_read)
        added
      end,
      fn
        [] -> {:halt, []}
        rows -> {rows, []}
      end,
      fn _rows -> :ok end
    )
  end
end
