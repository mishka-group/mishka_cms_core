# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SeoSitemapSlashes do
  @moduledoc """
  Test plugin for `seo:sitemap:urls`: lists the home page and a page core lists already with a slash
  at their end, one of its own twice, once with doubled and trailing slashes — proving each address
  is listed once, with no slash at its end, whoever lists it and however it is written.
  """
  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls"

  @impl true
  def call(%{urls: urls} = data) do
    added = [
      %{path: "/about/", lastmod: nil},
      %{path: "/guides", lastmod: nil},
      %{path: "//guides/", lastmod: nil},
      %{path: "/guides/", lastmod: nil},
      %{path: "/", lastmod: nil}
    ]

    {:reply, %{data | urls: Stream.concat(urls, added)}}
  end
end
