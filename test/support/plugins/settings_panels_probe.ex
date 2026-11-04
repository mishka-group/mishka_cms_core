# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.SettingsPanelsProbe do
  @moduledoc """
  Test plugin on `settings:panels`: a LiveComponent panel, a function-component panel, a panel
  that reuses a settings category's id, and a panel with nothing to draw it. The first two are
  the only ones the page may draw.
  """
  use MishkaInstaller.Event.Hook, event: "settings:panels"

  import Phoenix.Component, only: [sigil_H: 2]

  @doc "The panel drawn by a LiveComponent."
  def component_panel,
    do: %{
      id: "probe-component",
      label: "Probe component",
      icon: "hero-bolt",
      priority: 20,
      module: __MODULE__.Panel
    }

  @doc "The panel drawn by a function."
  def function_panel,
    do: %{
      id: "probe-function",
      label: "Probe function",
      icon: "hero-cube",
      priority: 10,
      description: "From a function",
      render: &render/1
    }

  @doc "Draws the function panel."
  def render(assigns) do
    ~H"""
    <p id="probe-function-body">Function panel for {@current_user.email}</p>
    """
  end

  @impl true
  def call(%{panels: panels} = data) do
    extra = [
      component_panel(),
      function_panel(),
      %{function_panel() | id: "email"},
      %{id: "probe-bare", label: "Bare", icon: "hero-bolt", priority: 1}
    ]

    {:reply, %{data | panels: panels ++ extra}}
  end

  defmodule Panel do
    @moduledoc "The LiveComponent panel."
    use Phoenix.LiveComponent

    @impl true
    def render(assigns) do
      ~H"""
      <div id="probe-component-body">Component panel</div>
      """
    end
  end
end
