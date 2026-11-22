# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarItemsProbe do
  @moduledoc """
  Test plugin on `topbar:items`: a LiveComponent item and a function item, declared out of their
  priority order, plus an item behind a permission the test admin does not hold, an item with
  nothing to draw it and a second item reusing a taken id. The first two are the only ones the top
  bar may draw, the LiveComponent first.

  Each call emits `[:mishka_cms_core, :test, :topbar_items_probe]` with the path and view it was
  handed, so a test can count the calls without waiting on anything.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:items"

  import Phoenix.Component, only: [sigil_H: 2]

  @called [:mishka_cms_core, :test, :topbar_items_probe]

  @doc "The telemetry event each call emits."
  def called, do: @called

  @doc "Draws the function item: the path it was drawn on."
  def render(assigns) do
    ~H"""
    <span id="probe-function-body">Function item on {@current_path}</span>
    """
  end

  @impl true
  def call(%{items: items, current_path: path, view: view} = data) do
    :telemetry.execute(@called, %{count: 1}, %{path: path, view: view})

    extra = [
      %{id: "probe-function", priority: 30, render: &render/1},
      %{id: "probe-component", priority: 10, module: __MODULE__.Badge},
      %{id: "probe-gated", priority: 20, permission: "admin:api:probe", render: &render/1},
      %{id: "probe-bare", priority: 1},
      %{id: "probe-function", priority: 5, module: __MODULE__.Badge}
    ]

    {:reply, %{data | items: items ++ extra}}
  end

  defmodule Badge do
    @moduledoc "The LiveComponent item: the site and the view it was drawn for."
    use Phoenix.LiveComponent

    @impl true
    def render(assigns) do
      ~H"""
      <span id="probe-component-body">{@current_site && @current_site.name} {inspect(@view)}</span>
      """
    end
  end
end
