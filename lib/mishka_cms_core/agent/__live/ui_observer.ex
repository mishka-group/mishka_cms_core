# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.UiObserver do
  @moduledoc """
  Lets a LiveView vouch that it received an operation's broadcast, for the receipt's
  `:ui_observed` stage (`MishkaCmsCore.Agent.Stages.UiObserved`).

      on_mount MishkaCmsCore.Agent.UiObserver

  It attaches a `handle_info` hook that looks at every Ash broadcast the view receives. One whose
  notification carries a receipt id (`context.shared.receipt_id`) is reported to that receipt with
  the view's module, the topic and the event, and passed on to the view untouched (`{:cont, socket}`).
  Nothing is read from the socket's assigns. Other messages cost one pattern match.

  The hook is attached only while receipts are on (`MishkaCmsCore.Agent.Receipts.on?/0`) when the
  view mounts; a view mounted before they were turned on does not report.
  """

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias MishkaCmsCore.Agent.Receipt.Stage
  alias MishkaCmsCore.Agent.Receipts

  @doc false
  def on_mount(_name, _params, _session, socket) do
    case Receipts.on?() do
      true -> {:cont, attach_hook(socket, :agent_ui_observer, :handle_info, &observe/2)}
      false -> {:cont, socket}
    end
  end

  @doc false
  def observe(
        %Phoenix.Socket.Broadcast{
          topic: topic,
          event: event,
          payload: %Ash.Notifier.Notification{changeset: %{context: %{shared: %{receipt_id: id}}}}
        },
        socket
      )
      when is_binary(id) do
    spec = %{
      kind: :ui_observed,
      name: :ui_observed,
      layer: :ui,
      key: nil,
      module: MishkaCmsCore.Agent.Stages.UiObserved
    }

    _ =
      Receipts.late(id, Stage.new(spec, {:ok, %{view: socket.view, topic: topic, event: event}}))

    {:cont, socket}
  end

  def observe(_message, socket), do: {:cont, socket}
end
