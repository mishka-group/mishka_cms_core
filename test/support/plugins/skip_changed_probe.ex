# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SkipChangedProbe do
  @moduledoc """
  Test plugin on `failure:skip:changed` (`MishkaCmsCore.Skip.changed/1`): sends the calling process
  `{:skip_changed_probe, change}`, so a test sees what a plugin is handed.
  """
  use MishkaInstaller.Event.Hook, event: "failure:skip:changed"

  @impl true
  def call(change) do
    send(self(), {:skip_changed_probe, change})
    {:reply, change}
  end
end
