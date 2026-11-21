# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SidebarStatusProbe do
  @moduledoc """
  Test plugin on `sidebar:status`: answers the lines a test put in
  `Application.put_env(:mishka_cms_core, :sidebar_status_probe, lines)` (none when it put none), and
  keeps the data it was handed under `:sidebar_status_probe_data`, so a test can read the window it
  was given.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:status"

  @impl true
  def call(%{lines: lines} = data) do
    Application.put_env(:mishka_cms_core, :sidebar_status_probe_data, Map.delete(data, :lines))
    extra = Application.get_env(:mishka_cms_core, :sidebar_status_probe, [])
    {:reply, %{data | lines: lines ++ extra}}
  end
end
