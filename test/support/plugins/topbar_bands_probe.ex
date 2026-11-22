# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarBandsProbe do
  @moduledoc """
  Test plugin on `topbar:bands`: a LiveComponent band and a function band declared out of their
  priority order, plus a band behind a permission the test admin does not hold, a band with
  nothing to draw it and a second band reusing a taken id. The first two are the only ones the
  page may draw, the LiveComponent first.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:bands"

  import Phoenix.Component, only: [sigil_H: 2]

  @doc "Draws the function band: the path it was drawn on."
  def render(assigns) do
    ~H"""
    <p id="probe-band-function">Function band on {@current_path}</p>
    """
  end

  @impl true
  def call(%{bands: bands} = data) do
    extra = [
      %{id: "probe-function", priority: 30, render: &render/1},
      %{id: "probe-component", priority: 10, module: __MODULE__.Strip},
      %{id: "probe-gated", priority: 20, permission: "admin:api:probe", render: &render/1},
      %{id: "probe-bare", priority: 1},
      %{id: "probe-function", priority: 5, module: __MODULE__.Strip}
    ]

    {:reply, %{data | bands: bands ++ extra}}
  end

  defmodule Strip do
    @moduledoc "The LiveComponent band: the view it was drawn for."
    use Phoenix.LiveComponent

    @impl true
    def render(assigns) do
      ~H"""
      <p id="probe-band-component">{inspect(@view)}</p>
      """
    end
  end
end
