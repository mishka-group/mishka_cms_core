# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Changes.LogOutEverywhereOnPasswordChange do
  @moduledoc """
  Revokes every token a user holds once a write that changed their password has committed, through
  the `log_out_everywhere` add-on's own action.

  AshAuthentication's `apply_on_password_change?` does the same inside the write. A password reset
  then fails: the reset token is stored like any other token, the add-on revokes it with the rest,
  and the reset's own single-use revocation of that token finds it revoked already ("token has
  already been revoked"). After the commit, the reset has spent its token first.

      changes do
        change LogOutEverywhereOnPasswordChange,
          on: [:update],
          where: [changing(:hashed_password, touching?: true)]
      end
  """
  use Ash.Resource.Change

  alias AshAuthentication.{Info, Strategy}

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, user} ->
        strategy = Info.strategy!(changeset.resource, :log_out_everywhere)

        case Strategy.action(
               strategy,
               :log_out_everywhere,
               %{user: user},
               Ash.Context.to_opts(context)
             ) do
          :ok -> {:ok, user}
          {:error, error} -> {:error, error}
        end

      _changeset, error ->
        error
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
