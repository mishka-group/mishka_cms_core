# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.AgentLifecycleProbe do
  @moduledoc """
  A plugin on an event of its own, never supervised, so the receipt tests can register and
  unregister it in the installer's registry without touching an event anything else listens on.
  """
  use MishkaInstaller.Event.Hook, event: "agent:test:lifecycle"

  @impl true
  def call(state), do: {:reply, state}
end
