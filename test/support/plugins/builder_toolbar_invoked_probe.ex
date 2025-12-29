defmodule MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe do
  @moduledoc """
  Test plugin: tells the registered waiter what `builder:canvas:toolbar:invoked` announced.

  A hook is one module per event, so this is the receiving half of
  `MishkaCmsCore.Test.Plugins.BuilderToolbarProbe`'s button. The announcement is made in the canvas
  LiveView rather than in the test, so it is sent to whatever process is registered as
  `:builder_toolbar_invoked_waiter` — the `MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe`
  arrangement — and with none registered the plugin does nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:canvas:toolbar:invoked"

  @waiter :builder_toolbar_invoked_waiter

  @doc "The name a test registers itself under to be told what a pressed toolbar button announced."
  @spec waiter() :: atom()
  def waiter, do: @waiter

  @impl MishkaInstaller.Event.Hook
  def call(summary) do
    case Process.whereis(@waiter) do
      nil -> :ok
      waiter -> send(waiter, {__MODULE__, summary})
    end

    {:reply, summary}
  end
end
