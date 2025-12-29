defmodule MishkaCmsCore.Test.Plugins.BuilderToolbarProbe do
  @moduledoc """
  Test plugin: adds a button to the canvas element toolbar through `builder:canvas:toolbar`.

  The registry accepted a descriptor and drew a real button for it, and then pressing that button
  duplicated the selected element — the only thing a toolbar action could do, because "not delete"
  meant "duplicate". What it should do arrives at
  `MishkaCmsCore.Test.Plugins.BuilderToolbarInvokedProbe`, which is the other half of this pair.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:canvas:toolbar", initial: %{priority: 90}

  alias MishkaCmsCore.Builder.Descriptor

  @key "probe-toolbar"
  @waiter :builder_toolbar_collect_waiter

  @doc "The key the action is registered under."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The name a test registers itself under to be told every time the registry is collected."
  @spec waiter() :: atom()
  def waiter, do: @waiter

  @impl MishkaInstaller.Event.Hook
  def call(%{actions: actions} = payload) do
    if pid = Process.whereis(@waiter), do: send(pid, {__MODULE__, :collected})
    {:reply, %{payload | actions: actions ++ [descriptor()]}}
  end

  def call(payload), do: {:reply, payload}

  @doc "The descriptor an extension would contribute."
  @spec descriptor() :: map()
  def descriptor do
    {:ok, built} =
      Descriptor.builder(%{
        key: @key,
        kind: :toolbar_action,
        label: "Probe",
        priority: 90,
        icon: "sparkle"
      })

    built
  end
end
