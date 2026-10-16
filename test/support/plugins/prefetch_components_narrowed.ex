# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.PrefetchComponentsNarrowed do
  @moduledoc """
  Test plugin for `runtime:compile:before_page_prefetch`: takes out every component whose name ends
  in `-held`, and adds the global `prefetch-from-plugin`, the same name under another site, and an
  entry that is not a component at all — proving a plugin decides what a cold page builds before it
  draws, and that only the rendered site's own and global components are built from its answer.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:compile:before_page_prefetch"

  @impl true
  def call(%{components: components} = data, _meta) do
    kept = Enum.reject(components, &String.ends_with?(&1.name, "-held"))

    added = [
      %{name: "prefetch-from-plugin", site: "Global"},
      %{name: "prefetch-from-plugin", site: "someone-else"},
      :not_a_component
    ]

    {:reply, %{data | components: kept ++ added}}
  end
end
