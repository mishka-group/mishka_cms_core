# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.LiveSiteUnavailable do
  @moduledoc """
  Test plugin for `web:live:site_unavailable`: sends a refused LiveView to an address of its own,
  proving a plugin can decide where it goes.
  """
  use MishkaInstaller.Event.Hook, event: "web:live:site_unavailable"

  @impl true
  def call(socket, _meta),
    do: {:reply, Phoenix.LiveView.redirect(socket, to: "/closed-by-plugin")}
end
