# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.ActionCommitted do
  @moduledoc """
  The action reported that it ran.

  ## What verified means

  The work returned success: `{:ok, record}` or `:ok` from the Ash action, or what a `track/3`
  function returned. When the resource lists `MishkaCmsCore.Agent.Notifiers.ReceiptHook`, Ash ran
  its notifiers for this receipt, which it does after the transaction commits, and `observed` says
  `source: :notifier`; otherwise `source: :return_value`. A refused action fails it (`:refused`) with
  the error classes and the field names, never the messages.

  ## What it does not prove

  This is the application's own account. It does not prove the row holds what was asked (that is
  `:db_read_back`), nor any side effect. Inside an outer transaction Ash holds the notifications
  until that transaction ends, so `:return_value` there says nothing about a commit. With no
  declaration, a result that is neither success nor an error is unverified (`:unknown_result`).
  """
  @behaviour MishkaCmsCore.Agent.Stages

  alias MishkaCmsCore.Agent.Notifiers.ReceiptHook
  alias MishkaCmsCore.Agent.Redactor

  @impl true
  def layer(_opts), do: :app

  @impl true
  def verify(%{result: {:ok, record}} = ctx, _opts),
    do: {:ok, %{source: source(ctx), record_id: Redactor.id(id_of(record))}}

  def verify(%{result: :ok} = ctx, _opts), do: {:ok, %{source: source(ctx)}}

  def verify(%{result: {:error, error}}, _opts),
    do: {:error, :refused, %{classes: Redactor.classes(error), fields: Redactor.fields(error)}}

  def verify(%{result: :error}, _opts), do: {:error, :refused}
  def verify(_ctx, _opts), do: {:unverified, :unknown_result}

  defp source(%{id: id}) do
    if ReceiptHook.committed?(id), do: :notifier, else: :return_value
  end

  defp id_of(%{id: id}), do: id
  defp id_of(_record), do: nil
end
