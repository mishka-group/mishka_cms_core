# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.LanguageGroupChanged do
  @moduledoc """
  Test plugin for `runtime:state:language_group:changed`: reports each change to the
  `:__plugin_hook_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:state:language_group:changed"

  @impl true
  def call(data, _meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:language_group_changed, data.op, data.key, data.translations})

    {:reply, data}
  end
end
