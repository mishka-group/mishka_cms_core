# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.AccountsUserAfterRegister do
  @moduledoc """
  Test plugin: reports `cms_core:user:after_register_with_password` to the `:__plugin_hook_probe__`
  process (the user factory registers via the password strategy).
  """
  use MishkaInstaller.Event.Hook, event: "cms_core:user:after_register_with_password"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:accounts_user_after_register, record.id, meta})

    {:reply, record}
  end
end
