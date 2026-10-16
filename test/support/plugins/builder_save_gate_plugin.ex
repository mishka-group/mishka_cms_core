# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderSaveGatePlugin do
  @moduledoc """
  Test plugin: vetoes a builder save through `builder:save:before`.

  This is the gate the plan calls the "money seam" — content lint, broken-link checks, schema
  validation all hang off it. A gate that cannot actually stop a write is decoration, so this proves
  a plugin's refusal really does prevent the live row being touched.

  It refuses only when the serialized template contains the sentinel, so the same registered plugin
  can be present for both the allow and the deny case in one test run.
  """
  use MishkaInstaller.Event.Hook, event: "builder:save:before"

  @sentinel "FORBIDDEN"

  @doc "The marker a template must contain for this plugin to veto its save."
  def sentinel, do: @sentinel

  @impl true
  def call(%{serialized: serialized} = payload) when is_binary(serialized) do
    case String.contains?(serialized, @sentinel) do
      true ->
        {:reply, %{payload | error: "A plugin refused this save: it contains #{@sentinel}."}}

      false ->
        {:reply, payload}
    end
  end

  def call(payload), do: {:reply, payload}
end
