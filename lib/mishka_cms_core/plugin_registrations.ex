# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.PluginRegistrations do
  @moduledoc """
  Keeps every stored plugin registration on the event its module declares.

  mishka_installer keeps registrations in Mnesia, on disk, and a plugin that registers again takes
  its priority, dependencies and extra data from its code but keeps the EVENT it was first stored
  under. So correcting the event a plugin declares changes nothing on an install that has already
  run it: the registration still names the old event, the plugin is compiled into that event's chain
  and no other, and whatever fires the corrected event never reaches it.

  `reconcile/1` moves each such registration to the declared event and rebuilds both chains. The
  stored status is kept, so a plugin an operator stopped stays stopped. A registration whose module
  is not loaded, or declares no event, is left where it is: there is nothing to compare it with.

  Attached once on boot via `attach/0` (from MishkaCmsCore.Application.start/2); it runs each time
  mishka_installer finishes synchronizing its plugins, and at once if that has already happened.
  """

  alias MishkaInstaller.Event.{Event, EventHandler}

  @handler_id "mishka-cms-core-plugin-registrations"
  @event [:mishka_installer, :event, :synchronized]

  @doc "Attach the reconcile to mishka_installer's synchronized telemetry. Idempotent."
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_telemetry/4, nil)

    # The synchronize this waits for may already be over — the installer boots on its own schedule.
    if :persistent_term.get(:event_status, nil) == "ready", do: reconcile()

    :ok
  end

  # QUEUED, NEVER SYNCHRONOUS: this runs inside mishka_installer's event handler, and a synchronous
  # rebuild is a call to that same process — it would wait on itself forever.
  @doc false
  def handle_telemetry(@event, _measurements, _meta, _config) do
    reconcile()
    :ok
  end

  @doc """
  Moves every registration stored under an event its module no longer declares, and returns the
  plugins it moved.

  `queue` is mishka_installer's own: `true` queues the chain rebuilds, `false` finishes them before
  returning.
  """
  @spec reconcile(boolean()) :: [module()]
  def reconcile(queue \\ true) do
    Event.get()
    |> List.wrap()
    |> Enum.filter(&stale?/1)
    |> Enum.flat_map(&move(&1, queue))
  end

  defp stale?(%{name: plugin, event: stored}) do
    case declared_event(plugin) do
      declared when is_binary(declared) -> declared != stored
      _ -> false
    end
  end

  defp move(%{name: plugin, event: stored}, queue) do
    declared = declared_event(plugin)

    case Event.write(:name, plugin, %{event: declared}) do
      {:ok, _moved} ->
        EventHandler.do_compile(stored, :register, queue)
        EventHandler.do_compile(declared, :register, queue)
        [plugin]

      {:error, _errors} ->
        []
    end
  end

  defp declared_event(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :config, 1),
      do: plugin.config(:__event__)
  end
end
