# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.WarmComponentsNarrowed do
  @moduledoc """
  Test plugin for `runtime:compile:warm_components`: takes out every component whose name ends in
  `-held`, and adds the global `warm-from-plugin`, the same name under another site, and an entry
  that is not a component at all — proving a plugin decides what a site's warm job builds, and that
  only the site's own and global components are built from its answer.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:compile:warm_components"

  @impl true
  def call(%{components: components} = data, _meta) do
    kept = Enum.reject(components, &String.ends_with?(&1.name, "-held"))

    added = [
      %{name: "warm-from-plugin", site: "Global"},
      %{name: "warm-from-plugin", site: "someone-else"},
      :not_a_component
    ]

    {:reply, %{data | components: kept ++ added}}
  end
end
