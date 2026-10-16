# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderFormRenamedProbe do
  @moduledoc """
  Test plugin: sends what `builder:form:after_rename` announced to the process registered as
  `waiter/0`, and does nothing when none is registered.
  """
  use MishkaInstaller.Event.Hook, event: "builder:form:after_rename"

  @waiter :builder_form_renamed_waiter

  @doc "The name a test registers itself under to receive the announcement."
  @spec waiter() :: atom()
  def waiter, do: @waiter

  @impl MishkaInstaller.Event.Hook
  def call(summary) do
    case Process.whereis(@waiter) do
      nil -> :ok
      waiter -> send(waiter, {__MODULE__, summary})
    end

    {:reply, summary}
  end
end
