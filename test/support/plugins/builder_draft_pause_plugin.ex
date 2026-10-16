# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderDraftPausePlugin do
  @moduledoc """
  Test plugin: holds a draft write open at `builder:draft:before_save` until the test releases it.

  The editor hands a draft write to a task and answers it later, so what it does with an edit made
  WHILE one is in flight cannot be tested by racing the two — the order comes out differently on a
  warm run and a cold one. This stops the write inside the task, tells the waiter which process is
  holding it, and goes on when that process replies `:release`, which makes the order exact.

  The waiter is whatever process is registered as `:builder_draft_pause_waiter`. With none
  registered every write passes straight through, so the plugin is inert until a test asks for it.
  """
  use MishkaInstaller.Event.Hook, event: "builder:draft:before_save"

  @waiter :builder_draft_pause_waiter
  @patience :timer.seconds(5)

  @doc "The name a test registers itself under to be told when a draft write reaches this gate."
  def waiter, do: @waiter

  @impl true
  def call(payload) do
    case Process.whereis(@waiter) do
      nil ->
        {:reply, payload}

      waiter ->
        send(waiter, {:draft_write_paused, self()})

        receive do
          :release -> {:reply, payload}
        after
          @patience -> {:reply, payload}
        end
    end
  end
end
