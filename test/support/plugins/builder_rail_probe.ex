# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderRailProbe do
  @moduledoc """
  A plugin that adds a rail to the page builder, exactly as an extension would.

  It exists to prove the seam end to end: the tab appears, it can be opened, and its BODY draws. Each
  of those three was separately broken — the registry fired into an assign nothing rendered, the rail
  bodies were hardcoded `:if` branches, and an atom whitelist rejected the click before it arrived.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use Phoenix.Component
  use MishkaInstaller.Event.Hook, event: "builder:rails", initial: %{priority: 90}

  alias MishkaCmsCore.Builder.Descriptor

  @key "probe-rail"
  @marker "the probe rail drew"

  @doc "The key the rail is registered under."
  @spec key() :: String.t()
  def key, do: @key

  @doc "What the rail's body says when it draws, so a test can look for it."
  @spec marker() :: String.t()
  def marker, do: @marker

  @impl MishkaInstaller.Event.Hook
  def call(%{tabs: tabs} = payload), do: {:reply, %{payload | tabs: tabs ++ [descriptor()]}}
  def call(payload), do: {:reply, payload}

  @doc "The descriptor an extension would contribute."
  @spec descriptor() :: map()
  def descriptor do
    {:ok, built} =
      Descriptor.builder(%{
        key: @key,
        kind: :rail_tab,
        label: "Probe",
        priority: 90,
        icon: "sparkle",
        render: {__MODULE__, :body}
      })

    built
  end

  @doc "What the rail draws when it is the open one."
  def body(assigns) do
    assigns = assign(assigns, :marker, @marker)

    ~H"""
    <div id="pb-probe-rail-body" class="p-3 text-[12px]">{@marker}</div>
    """
  end
end
