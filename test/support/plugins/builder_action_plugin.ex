defmodule MishkaCmsCore.Test.Plugins.BuilderActionPlugin do
  @moduledoc """
  Test plugin: contributes three On-click actions through `builder:interactions`.

  The seam existed for the LIST and stopped there — a contributed action appeared in the dropdown and
  wrote nothing, because the writer was a private table. These three are what proves it is a door
  now: one client verb, one server verb, and one that misbehaves and must be refused.
  """
  use MishkaInstaller.Event.Hook, event: "builder:interactions"

  alias MishkaCmsCore.Test.Plugins.Actions.PingAction
  alias MishkaCmsCore.Test.Plugins.Actions.RogueAction
  alias MishkaCmsCore.Test.Plugins.Actions.ScrollAction

  @impl true
  def call(%{actions: actions} = payload) do
    {:reply, %{payload | actions: actions ++ contributed()}}
  end

  def call(payload), do: {:reply, payload}

  @doc "The descriptors this plugin contributes, so tests can assert against them directly."
  @spec contributed() :: [map()]
  def contributed,
    do: [
      ScrollAction.descriptor(),
      PingAction.descriptor(),
      RogueAction.descriptor(),
      RogueAction.mistaken()
    ]
end
