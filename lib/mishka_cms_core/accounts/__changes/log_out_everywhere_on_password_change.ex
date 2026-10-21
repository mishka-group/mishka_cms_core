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

  **Whether the password changed is decided after the commit, not when the change is attached.**
  `AshAuthentication.Strategy.Password.HashPasswordChange` writes the hash in a `before_action` hook,
  so a `where: [changing(:hashed_password)]` on this change reads "not changing" for every action
  that hashes a password itself, and the change is never attached: a changed password then signed
  nobody out. The hook is attached to each action that can set a password, and does nothing when
  the write left the hash as it was.

      changes do
        change LogOutEverywhereOnPasswordChange,
          on: [:update],
          where: [action_is([:change_password, :set_password, :reset_password_with_token])]
      end
  """
  use Ash.Resource.Change

  alias AshAuthentication.{Info, Jwt, Strategy}

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, user} = result ->
        if Ash.Changeset.changing_attribute?(changeset, :hashed_password),
          do: log_out_everywhere(changeset, user, context),
          else: result

      _changeset, error ->
        error
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp log_out_everywhere(changeset, user, context) do
    strategy = Info.strategy!(changeset.resource, :log_out_everywhere)

    case Strategy.action(
           strategy,
           :log_out_everywhere,
           %{user: user},
           Ash.Context.to_opts(context)
         ) do
      :ok -> reissue(user, context)
      {:error, error} -> {:error, error}
    end
  end

  # THE WRITE'S OWN SIGN-IN SURVIVES. A reset signs the account in (`GenerateTokenChange`), and that
  # token was revoked with the rest, so the device that reset the password would be signed out at
  # once: it gets a new token in its place. A write that signed nobody in gets none.
  defp reissue(user, context) do
    case Ash.Resource.get_metadata(user, :token) do
      nil ->
        {:ok, user}

      _revoked ->
        case Jwt.token_for_user(user, %{"purpose" => "user"}, Ash.Context.to_opts(context)) do
          {:ok, token, _claims} -> {:ok, Ash.Resource.put_metadata(user, :token, token)}
          {:error, error} -> {:error, error}
        end
    end
  end
end
