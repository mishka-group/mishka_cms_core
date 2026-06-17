defmodule MishkaCmsCore.Test.Plugins.BuilderNodeProbe do
  @moduledoc """
  A plugin that tells the process which set a node's text that the editor announced it.

  `builder:node:after_set_text` is announced in the process that made the change, so a test counts
  the announcements in its own mailbox.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:node:after_set_text"

  @impl true
  def call(summary) do
    send(self(), {__MODULE__, summary})
    {:reply, summary}
  end
end
