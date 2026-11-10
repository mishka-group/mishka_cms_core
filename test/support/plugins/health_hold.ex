# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.HealthHold do
  @moduledoc """
  Test plugin for `runtime:health:ready`: holds the node at 503 with a reason of its own, as an
  extension still warming something up would.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:health:ready"

  @impl true
  def call(:ok), do: {:reply, :halt, {:error, "search index loading"}}
  def call(error), do: {:reply, error}
end
