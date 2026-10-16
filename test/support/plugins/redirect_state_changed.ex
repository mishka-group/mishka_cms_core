# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.RedirectStateChanged do
  @moduledoc """
  Test plugin for `runtime:state:redirect:changed`: reports each rule the redirects cache keeps or
  lets go to the `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:state:redirect:changed"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:redirect_changed, data.op, data.key})

    {:reply, data}
  end
end
