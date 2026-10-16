# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SiteAvailabilityChanged do
  @moduledoc """
  Test plugin for `runtime:state:site:availability_changed`: reports the site each change was
  announced for to the `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:state:site:availability_changed"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:availability_changed, data.key})

    {:reply, data}
  end
end
