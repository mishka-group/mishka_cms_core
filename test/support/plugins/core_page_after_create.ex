# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.CorePageAfterCreate do
  @moduledoc "Test plugin: reports `cms_core:page:after_create` to the `:__plugin_hook_probe__` process."
  use MishkaInstaller.Event.Hook, event: "cms_core:page:after_create"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:core_page_after_create, record.id, meta})

    {:reply, record}
  end
end
