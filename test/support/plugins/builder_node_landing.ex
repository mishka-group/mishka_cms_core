# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.BuilderNodeLanding do
  @moduledoc """
  A plugin that lands a write inside the change that asks it.

  `builder:node:before_set_text` is asked from inside an `EditorSession` change, between its read of
  the session and its write — the one place code from outside the editor runs there. A test queues a
  write with `land/1`; the next time this is asked in that process it runs the write, once. That is
  exactly what another process storing the session at that moment looks like, with nothing left to
  timing. Every time it is asked it says so, which is how a test knows the change was tried again.

  Registered by the test that needs it rather than by the application, so a normal boot pays nothing.
  """
  use MishkaInstaller.Event.Hook, event: "builder:node:before_set_text"

  @doc "Queues `write` for the next time this plugin is asked in the calling process."
  @spec land((-> term())) :: :ok
  def land(write) when is_function(write, 0) do
    send(self(), {__MODULE__, :land, write})
    :ok
  end

  @impl true
  def call(payload) do
    receive do
      {__MODULE__, :land, write} -> write.()
    after
      0 -> :ok
    end

    send(self(), {__MODULE__, :asked})
    {:reply, payload}
  end
end
