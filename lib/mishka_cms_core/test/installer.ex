# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Installer do
  @moduledoc """
  `mishka_installer` plugins in a test run: wait until a list of them is live, register one for the
  length of a test, and sweep away the test plugins an earlier run left registered.

  ## Waiting for plugins

  A plugin registers from its own `handle_continue`, once `mishka_installer` says it is ready — and
  on a slow boot, such as the first run after a recompile, it is not ready yet, so the plugin tries
  again a second later. By then the first tests have run against events that do not have it: the
  mail provider is not found, and every test that sends an email fails, once, and passes on the next
  run. `await/2` makes the run start after that second instead of during it.

      MishkaCmsCore.Test.Installer.await(MishkaCmsCore.Application.plugins())

  It waits on `mishka_installer`'s own `:start` broadcast for each plugin not started yet, then on
  `MishkaInstaller.Event.EventHandler` until no event is waiting to be rebuilt — `Event.start/3`
  queues the rebuild before it broadcasts, so the rebuild is queued by the time the wait sees it.

  ## A plugin for one test

  `register!/2` registers a module on an event exactly as an extension registers one, rebuilds the
  event with it, and unregisters it when the test exits. The compiled event is global, so a test
  using it is `async: false`.

  ## Plugins that outlived their run

  `mishka_installer` keeps registrations in Mnesia, which is on disk and survives the run that made
  them — so a suite killed part-way (a crash, a Ctrl-C, a timeout) leaves its plugin registered, and
  every later run boots with it live. That is invisible and it changes unrelated suites: a leftover
  `builder:components` plugin puts an extra card in the palette, and a test asserting on one card
  sees two. `sweep!/1` unregisters every plugin whose module name starts with one of the prefixes
  given — a project's own test plugins only, since a real plugin belongs to whoever installed it.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaInstaller.QueueAssistant

  @doc "Waits until every plugin in `plugins` is started and every event they joined is rebuilt."
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

  @doc """
  Registers `module` as a started plugin of `event` and rebuilds the event, for the length of the
  calling test.
  """
  @spec register!(module(), String.t()) :: :ok
  def register!(module, event) do
    {:ok, _} =
      Event.write(%{name: module, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn -> Event.unregister(:name, module, false) end)
    :ok
  end

  @doc """
  Unregisters every plugin whose module name (`"Elixir.My.Test.Plugins.Probe"`) starts with one of
  `prefixes`.
  """
  @spec sweep!([String.t()]) :: :ok
  def sweep!(prefixes) do
    for event <- List.wrap(Event.get()),
        String.starts_with?(to_string(event.name), prefixes) do
      Event.unregister(:name, event.name, false)
    end

    :ok
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
