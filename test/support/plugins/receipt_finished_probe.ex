# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ReceiptFinishedProbe do
  @moduledoc """
  Test plugin for `agent:receipt:finished`: sends what it was handed to the
  `:__receipt_finished_probe__` process, then raises for the operation `"test:plugin_raises"`.
  """
  use MishkaInstaller.Event.Hook, event: "agent:receipt:finished"

  @impl true
  def call(payload) do
    if pid = Process.whereis(:__receipt_finished_probe__),
      do: send(pid, {:receipt_finished, payload})

    case payload do
      %{operation: "test:plugin_raises"} -> raise "a plugin of agent:receipt:finished broke"
      _other -> {:reply, payload}
    end
  end
end
