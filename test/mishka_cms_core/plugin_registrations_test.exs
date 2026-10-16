# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.PluginRegistrationsTest do
  @moduledoc """
  A registration mishka_installer stored under an event its plugin no longer declares is moved to
  the declared event — asserted through the real action that fires the declared event, not only by
  reading the registration back.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.PluginRegistrations
  alias MishkaCmsCore.Test.Plugins.CorePageAfterCreate
  alias MishkaInstaller.Event.{Event, EventHandler, ModuleStateCompiler}

  # Where the probe is stored before the reconcile runs: an event nothing fires.
  @stale "cms_core:page:created"
  @declared CorePageAfterCreate.config(:__event__)

  # A module that does not exist, standing in for a plugin whose extension was removed.
  @uninstalled MishkaCmsCore.Test.Plugins.UninstalledPlugin

  setup do
    Process.register(self(), :__plugin_hook_probe__)

    on_exit(fn ->
      Event.unregister(:name, CorePageAfterCreate, false)
      Event.unregister(:name, @uninstalled, false)
    end)

    :ok
  end

  defp store(plugin, status) do
    {:ok, _} =
      Event.write(%{name: plugin, event: @stale, extension: :mishka_installer, status: status})

    :ok = EventHandler.do_compile(@stale, :start, false)
    :ok = EventHandler.do_compile(@declared, :start, false)
  end

  defp create_page_and_await do
    id = create_page!().id
    assert_receive {:core_page_after_create, ^id, _meta}, 2_000
  end

  defp create_page_and_refute do
    id = create_page!().id
    refute_receive {:core_page_after_create, ^id, _meta}, 300
  end

  defp in_chain?(event, plugin) do
    module = ModuleStateCompiler.module_event_name(event)
    Code.ensure_loaded?(module) and Enum.any?(module.initialize().plugins, &(&1.name == plugin))
  end

  # The telemetry-driven reconcile queues its rebuilds, so the only signal to wait on is the chain.
  defp wait_for_chain(event, plugin, remaining \\ 5_000) do
    cond do
      in_chain?(event, plugin) ->
        :ok

      remaining <= 0 ->
        flunk("#{inspect(plugin)} never joined the #{event} chain")

      true ->
        Process.sleep(50)
        wait_for_chain(event, plugin, remaining - 50)
    end
  end

  test "a plugin stored under an event it no longer declares moves and hears the declared one" do
    store(CorePageAfterCreate, :started)
    assert in_chain?(@stale, CorePageAfterCreate)
    create_page_and_refute()

    assert CorePageAfterCreate in PluginRegistrations.reconcile(false)
    assert Event.get(:name, CorePageAfterCreate).event == @declared
    refute in_chain?(@stale, CorePageAfterCreate)

    create_page_and_await()
  end

  test "a plugin an operator stopped is moved and stays stopped" do
    store(CorePageAfterCreate, :stopped)

    assert CorePageAfterCreate in PluginRegistrations.reconcile(false)
    assert %{event: @declared, status: :stopped} = Event.get(:name, CorePageAfterCreate)

    create_page_and_refute()
  end

  test "a registration whose module is not loaded stays where it is" do
    store(@uninstalled, :started)

    refute @uninstalled in PluginRegistrations.reconcile(false)
    assert Event.get(:name, @uninstalled).event == @stale
  end

  test "the reconcile runs when mishka_installer finishes synchronizing its plugins" do
    store(CorePageAfterCreate, :started)

    :telemetry.execute([:mishka_installer, :event, :synchronized], %{system_time: 0}, %{})

    assert Event.get(:name, CorePageAfterCreate).event == @declared
    wait_for_chain(@declared, CorePageAfterCreate)
    create_page_and_await()
  end
end
