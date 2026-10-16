# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SeoRobotsLines do
  @moduledoc """
  Test plugin for `seo:robots:lines`: adds a rule of its own under the ones every site has, proving
  a plugin shapes a site's robots.txt.
  """
  use MishkaInstaller.Event.Hook, event: "seo:robots:lines"

  @impl true
  def call(%{lines: lines} = data), do: {:reply, %{data | lines: lines ++ ["Disallow: /plugin/"]}}
end
