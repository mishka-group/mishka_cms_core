defmodule MishkaCmsCore.Test.Plugins.BuilderGatedCommandProbe do
  @moduledoc """
  A plugin ⌘K command that names who may see it — `admin:dashboard:code` — as an extension would.

  It proves the builder filters `builder:commands` per viewer through
  `MishkaCmsCore.Builder.Descriptor.permitted/2`: a holder of the name finds it in the palette, and
  anyone else does not.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:commands", initial: %{priority: 91}

  alias MishkaCmsCore.Builder.Descriptor

  @key "gated-command"

  @doc "The key the command is registered under."
  @spec key() :: String.t()
  def key, do: @key

  @impl MishkaInstaller.Event.Hook
  def call(%{commands: commands} = payload),
    do: {:reply, %{payload | commands: commands ++ [descriptor()]}}

  def call(payload), do: {:reply, payload}

  @doc "The descriptor, gated on the dashboard's code permission."
  @spec descriptor() :: map()
  def descriptor do
    {:ok, built} =
      Descriptor.builder(%{
        key: @key,
        kind: :command,
        label: "Gated",
        priority: 91,
        icon: "sparkle",
        description: "Only for a holder of code",
        permissions: ["admin:dashboard:code"]
      })

    built
  end
end
