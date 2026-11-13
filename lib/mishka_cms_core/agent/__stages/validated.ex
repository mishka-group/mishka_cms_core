# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.Validated do
  @moduledoc """
  The changeset was valid when it was built.

  ## What verified means

  The `Ash.Changeset` handed to `MishkaCmsCore.Agent.Receipts.run/3` was `valid?` before the action
  ran. Failed (`:invalid`) carries the names of the fields that were refused, never their values or
  messages.

  ## What it does not prove

  That the action will commit. Validations and changes that run inside the action (a
  `before_action` hook, a plugin's before seam, a database constraint, a policy) can still refuse
  it; that shows on `:action_committed`. Outside an Ash action (`track/3`) there is no changeset and
  the stage is skipped (`:not_applicable`).
  """
  @behaviour MishkaCmsCore.Agent.Stages

  alias MishkaCmsCore.Agent.Redactor

  @impl true
  def layer(_opts), do: :app

  @impl true
  def verify(%{changeset: %{valid?: true}}, _opts), do: {:ok, %{valid?: true}}

  def verify(%{changeset: %{valid?: false, errors: errors}}, _opts),
    do: {:error, :invalid, %{valid?: false, fields: Redactor.fields(errors)}}

  def verify(_ctx, _opts), do: {:skip, :not_applicable}
end
