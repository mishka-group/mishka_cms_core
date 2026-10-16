# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.PluginReadiness do
  @moduledoc """
  Holds a test run until the plugins it names are live: each `:started` in `mishka_installer`, and
  every event they joined rebuilt with them in it.

  A plugin registers from its own `handle_continue`, once `mishka_installer` says it is ready — and
  on a slow boot, such as the first run after a recompile, it is not ready yet, so the plugin tries
  again a second later. By then the first tests have run against events that do not have it: the
  mail provider is not found, and every test that sends an email fails, once, and passes on the next
  run. `await/2` makes the run start after that second instead of during it.

      MishkaCmsCore.Test.PluginReadiness.await(MishkaCmsCore.Application.plugins())

  It waits on `mishka_installer`'s own `:start` broadcast for each plugin not started yet, then on
  `MishkaInstaller.Event.EventHandler` until no event is waiting to be rebuilt — `Event.start/3`
  queues the rebuild before it broadcasts, so the rebuild is queued by the time the wait sees it.
  """

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaInstaller.QueueAssistant

  @spec await([module()], timeout()) :: :ok
  def await(plugins, timeout \\ :timer.seconds(30)) do
    MishkaInstaller.subscribe("event")

    plugins
    |> Enum.reject(&started?/1)
    |> wait(timeout)

    MishkaInstaller.unsubscribe("event")
    flush()
    drain()
  end

  defp started?(plugin), do: match?(%{status: :started}, Event.get(:name, plugin))

  defp wait([], _timeout), do: :ok

  defp wait(waiting, timeout) do
    receive do
      %{channel: "event", status: :start, data: %{name: name}} ->
        waiting |> List.delete(name) |> Enum.reject(&started?/1) |> wait(timeout)
    after
      timeout -> raise "these plugins never started: #{inspect(waiting)}"
    end
  end

  defp flush do
    receive do
      %{channel: "event"} -> flush()
    after
      0 -> :ok
    end
  end

  defp drain do
    state = EventHandler.get()

    if Keyword.get(state, :running, []) == [] and
         QueueAssistant.empty?(Keyword.get(state, :queues)),
       do: :ok,
       else: drain()
  end
end
