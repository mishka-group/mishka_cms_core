# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderTokenGate do
  @moduledoc """
  A design-system plugin as an extension would write it: one value is refused, one is snapped to the
  palette, every other value passes through.

  It is what the Studio's token write is asked through `builder:token:before_set`.
  """
  use MishkaInstaller.Event.Hook, event: "builder:token:before_set"

  @refused "not-on-the-scale"
  @snapped "#101010"

  @doc "The value this plugin refuses."
  @spec refused() :: String.t()
  def refused, do: @refused

  @doc "The value this plugin writes in place of `\"snap-me\"`."
  @spec snapped() :: String.t()
  def snapped, do: @snapped

  @impl true
  def call(%{value: @refused} = payload),
    do: {:reply, %{payload | error: "That value is not on the scale."}}

  def call(%{value: "snap-me"} = payload), do: {:reply, %{payload | value: @snapped}}

  def call(payload), do: {:reply, payload}
end
