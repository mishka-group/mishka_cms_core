# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Notifiers.ReceiptHook do
  @moduledoc """
  An Ash notifier that tells a receipt its action's notifications ran, which Ash does after the
  transaction commits. With it, `MishkaCmsCore.Agent.Stages.ActionCommitted` says
  `source: :notifier` rather than trusting the return value alone.

      use Ash.Resource,
        ...,
        notifiers: [
          Ash.Notifier.PubSub,
          MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
          MishkaCmsCore.Agent.Notifiers.ReceiptHook
        ]

  A notification with no receipt id in its shared context (every action not run through
  `MishkaCmsCore.Agent.Receipts`) costs one map lookup. It never requires original data, so the
  action stays atomic.

  It is heard in the process that ran the action, where Ash sends the notifications. Notifications
  Ash sends from another process are not seen, and the stage falls back to the return value.
  """
  @behaviour Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{changeset: %{context: %{shared: %{receipt_id: id}}}})
      when is_binary(id) do
    if MishkaCmsCore.Agent.Receipts.current() == id, do: Process.put({__MODULE__, id}, true)
    :ok
  end

  def notify(_notification), do: :ok

  @impl true
  def requires_original_data?(_resource, _action), do: false

  @doc "Whether this process heard the notifications of receipt `id`'s action."
  @spec committed?(String.t()) :: boolean()
  def committed?(id), do: Process.delete({__MODULE__, id}) == true
end
