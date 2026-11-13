# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.Dispatched do
  @moduledoc """
  The operation was asked for and resolved to a declaration.

  ## What verified means

  `MishkaCmsCore.Agent.Receipts` was entered with an operation that is declared, and the Ash action
  about to run is the declared action or its master twin.

  ## What it does not prove

  Anything about the work. A receipt whose only verified stage is this one is `:unverified`, never
  `:partial`. An undeclared operation is `:unverified` here (`:undeclared`), and an action that is
  not the declared one fails it (`:wrong_action`).
  """
  @behaviour MishkaCmsCore.Agent.Stages

  @impl true
  def layer(_opts), do: :app

  @impl true
  def verify(%{operation: nil, operation_name: name}, _opts),
    do: {:unverified, :undeclared, %{operation: name}}

  def verify(%{operation: %{name: name, action: nil}}, _opts), do: {:ok, %{operation: name}}
  def verify(%{operation: %{name: name}, action: nil}, _opts), do: {:ok, %{operation: name}}

  def verify(
        %{operation: %{name: name, action: declared, master_action: master}, action: action},
        _opts
      ) do
    case action in [declared, master] do
      true -> {:ok, %{operation: name, action: action}}
      false -> {:error, :wrong_action, %{operation: name, action: action}}
    end
  end
end
