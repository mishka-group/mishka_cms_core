# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ComponentCrashed do
  @moduledoc """
  Test plugin for `runtime:component:crashed`: sends what it hears to the process drawing the page,
  proving a plugin is told when a component's raise is contained, with its name, site and error.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:component:crashed"

  @impl true
  def call(data, _meta) do
    send(self(), {:component_crashed, data})
    {:reply, data}
  end
end
