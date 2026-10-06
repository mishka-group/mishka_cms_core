defmodule MishkaCmsCore.Test.Plugins.BuilderDraftGatePlugin do
  @moduledoc """
  Test plugin: refuses every draft write through `builder:draft:before_save`.

  The draft write is the save the editor makes on its own, so making it fail on purpose is the only
  way to watch the editor answer a failed one. It refuses unconditionally rather than on a sentinel:
  while this plugin is registered no draft of any document can be written, which is exactly the
  state the tests using it are about.
  """
  use MishkaInstaller.Event.Hook, event: "builder:draft:before_save"

  @refusal "A plugin refused this draft."

  @impl true
  def call(payload), do: {:reply, %{payload | error: @refusal}}
end
