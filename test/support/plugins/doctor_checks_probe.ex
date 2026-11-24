# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.DoctorChecksProbe do
  @moduledoc """
  Test plugin on `doctor:checks`: answers the window of `:mishka_kit_host` (the extension of
  `MishkaCmsCore.Test.KitUpgradeHostLive`) with the checks a test put in `answer/1`, a function of
  the payload, so a test decides what the plugins add. `:hang` makes its `call/1` wait for ever, a
  plugin that never answers. It does NOT stand for any real extension's checks.
  """
  use MishkaInstaller.Event.Hook, event: "doctor:checks"

  @key {__MODULE__, :answer}

  @doc "What the plugin adds: a function of the payload answering a list of checks, or `:hang`."
  @spec answer((map() -> [map()]) | :hang) :: :ok
  def answer(answer), do: :persistent_term.put(@key, answer)

  @doc "Forgets the answer."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @impl true
  def call(%{app: :mishka_kit_host, checks: checks} = data) do
    case :persistent_term.get(@key, fn _data -> [] end) do
      :hang ->
        receive do
          :never -> {:reply, data}
        end

      answer ->
        {:reply, %{data | checks: checks ++ answer.(data)}}
    end
  end

  def call(data), do: {:reply, data}
end
