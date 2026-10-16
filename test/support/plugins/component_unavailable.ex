# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.ComponentUnavailable do
  @moduledoc """
  Test plugin for `runtime:render:component_unavailable`: draws a note of its own where another
  site's component was refused, naming what the template asked for and the site being rendered,
  proving a plugin hears the refusal and may answer it.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:render:component_unavailable"

  import Phoenix.Component, only: [sigil_H: 2]

  @impl true
  def call(_nothing, meta) do
    assigns = meta

    {:reply,
     ~H"""
     <p data-role="refused" data-name={@component_name} data-site={@site} data-rendering={@site_id}>
       not here
     </p>
     """}
  end
end
