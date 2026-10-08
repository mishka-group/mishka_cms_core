defmodule MishkaCmsCore.Test.Plugins.ContentComponentBeforeDraw do
  @moduledoc """
  Test plugin for `runtime:render:before_content_component`: refuses a marker whose title is
  `refuse`, and writes any other title in capitals with the marker's index after it — proving a
  plugin hears each marker before it is drawn, and may change or refuse what it draws.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:render:before_content_component"

  @impl true
  def call(%{attrs: %{title: "refuse"}} = data, _meta),
    do: {:reply, Map.put(data, :suppress, true)}

  def call(%{attrs: %{title: title} = attrs} = data, meta),
    do: {:reply, %{data | attrs: %{attrs | title: "#{String.upcase(title)}-#{meta[:index]}"}}}

  def call(data, _meta), do: {:reply, data}
end
