# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderGatedStudioProbe do
  @moduledoc """
  A plugin Studio tab that names who may see it — `admin:dashboard:code` — as an extension would, so a
  test can show the Studio draws it for a holder of the name and for nobody else.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:studio:tabs", initial: %{priority: 91}

  alias MishkaCmsCore.Builder.Descriptor

  @key "gated-studio"

  @doc "The key the tab is registered under."
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
        kind: :studio_tab,
        label: "Gated",
        priority: 91,
        permissions: ["admin:dashboard:code"]
      })

    built
  end
end
