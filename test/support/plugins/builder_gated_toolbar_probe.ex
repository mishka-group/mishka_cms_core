defmodule MishkaCmsCore.Test.Plugins.BuilderGatedToolbarProbe do
  @moduledoc """
  A plugin canvas toolbar action that names who may see it — `admin:dashboard:code` — as an extension
  would, so a test can show the canvas draws it for a holder of the name and for nobody else.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:canvas:toolbar", initial: %{priority: 91}

  alias MishkaCmsCore.Builder.Descriptor

  @key "gated-toolbar"

  @doc "The key the action is registered under."
  @spec key() :: String.t()
  def key, do: @key

  @impl MishkaInstaller.Event.Hook
  def call(%{actions: actions} = payload),
    do: {:reply, %{payload | actions: actions ++ [descriptor()]}}

  def call(payload), do: {:reply, payload}

  @doc "The descriptor, gated on the dashboard's code permission."
  @spec descriptor() :: map()
  def descriptor do
    {:ok, built} =
      Descriptor.builder(%{
        key: @key,
        kind: :toolbar_action,
        label: "Gated",
        priority: 91,
        icon: "sparkle",
        permissions: ["admin:dashboard:code"]
      })

    built
  end
end
