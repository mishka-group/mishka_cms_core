defmodule MishkaCmsCore.Test.Plugins.BuilderDraftAnnounceProbe do
  @moduledoc """
  Test plugin: tells the registered waiter what `builder:draft:after_save` announced.

  This is the announcement a backup or a sync integration listens on, and it is made in the process
  that wrote the draft — the LiveView, not the test — so a test cannot count it in its own mailbox
  the way `MishkaCmsCore.Test.Plugins.BuilderNodeProbe` does. It is sent to whatever process is
  registered as `:builder_draft_announce_waiter`, and with none registered the plugin does nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:draft:after_save"

  @waiter :builder_draft_announce_waiter

  @doc "The name a test registers itself under to be told what a draft write announced."
  def waiter, do: @waiter

  @impl true
  def call(summary) do
    case Process.whereis(@waiter) do
      nil -> :ok
      waiter -> send(waiter, {__MODULE__, summary})
    end

    {:reply, summary}
  end
end
