# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.MasterCreationRefused do
  @moduledoc """
  Test plugin for `cms_core:user:master_creation_refused`: reports each refused master creation to the
  `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "cms_core:user:master_creation_refused"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:master_creation_refused, data.action, data.actor_id, data.email})

    {:reply, data}
  end
end
