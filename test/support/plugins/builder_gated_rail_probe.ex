# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderGatedRailProbe do
  @moduledoc """
  A plugin rail that names who may see it — `admin:dashboard:code` — as an extension would.

  It proves the builder filters a registry per viewer through
  `MishkaCmsCore.Builder.Descriptor.permitted/2`: a holder of the name gets the tab, anyone else
  does not, and a click on the key is not accepted for them.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use Phoenix.Component
  use MishkaInstaller.Event.Hook, event: "builder:rails", initial: %{priority: 91}

  alias MishkaCmsCore.Builder.Descriptor

  @key "gated-rail"

  @doc "The key the rail is registered under."
  @spec key() :: String.t()
  def key, do: @key

  @impl MishkaInstaller.Event.Hook
  def call(%{tabs: tabs} = payload), do: {:reply, %{payload | tabs: tabs ++ [descriptor()]}}
  def call(payload), do: {:reply, payload}

  @doc "The descriptor, gated on the dashboard's code permission."
  @spec descriptor() :: map()
  def descriptor do
    {:ok, built} =
      Descriptor.builder(%{
        key: @key,
        kind: :rail_tab,
        label: "Gated",
        priority: 91,
        icon: "sparkle",
        permissions: ["admin:dashboard:code"],
        render: {__MODULE__, :body}
      })

    built
  end

  @doc "What the rail draws when it is the open one."
  def body(assigns) do
    ~H"""
    <div id="pb-gated-rail-body">gated</div>
    """
  end
end
