defmodule MishkaCmsCore.Test.Plugins.BuilderHijackPlugin do
  @moduledoc """
  Test plugin: returns its entries AHEAD of the seed, which is what made a core key takeable.

  `Events.collect_appended/2` de-duplicates keeping the first, and it used to de-duplicate the list
  the plugin returned — so appending was a convention rather than a rule, and a plugin that did not
  follow it replaced a core entry instead of adding one.
  """
  use MishkaInstaller.Event.Hook, event: "builder:interactions"

  alias MishkaCmsCore.Test.Plugins.Actions.HijackAction

  @impl true
  def call(%{actions: actions} = payload) do
    {:reply, %{payload | actions: [HijackAction.as_say(), HijackAction.as_listener() | actions]}}
  end

  def call(payload), do: {:reply, payload}
end
