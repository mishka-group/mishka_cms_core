# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Changes.LogOutEverywhereOnPasswordChange do
  @moduledoc """
  Revokes every token a user holds once a write that changed their password has committed, through
  the `log_out_everywhere` add-on's own action, and hands the device that made the change a new one.

  | Event | Other sessions | The device that did it | Old reset links, sign-in links, pending codes |
  |---|---|---|---|
  | Password reset | signed out | stays signed in (new token) | all dead |
  | Password change, or a first password | signed out | stays signed in (new token, the API's `meta.token`) | all dead |
  | An admin sets someone's password | that account's sessions signed out | the admin is unaffected | all dead |

  Every token the account holds is revoked, not only its sessions: a reset or sign-in link sent
  before the change no longer works. The device that did it is the one the write signed in (a reset)
  or the account changing its own password; an admin's edit gives the account no token.

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
      :ok -> reissue(changeset, user, context)
      {:error, error} -> {:error, error}
    end
  end

  # THE DEVICE THAT DID IT STAYS SIGNED IN. A reset signs the account in (`GenerateTokenChange`), and
  # an account changing its own password is signed in where it made the change; both tokens went with
  # the rest, so that device gets a new one in its place. Anybody else's write gives none.
  defp reissue(changeset, user, context) do
    if signed_in?(changeset, user) or own?(user, context) do
      case Jwt.token_for_user(user, %{"purpose" => "user"}, Ash.Context.to_opts(context)) do
        {:ok, token, _claims} -> {:ok, Ash.Resource.put_metadata(user, :token, token)}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, user}
    end
  end

  # The write signed the account in when it handed back a token the record it started from did not
  # carry; a record read with one already keeps it through any write.
  defp signed_in?(changeset, user) do
    token = Ash.Resource.get_metadata(user, :token)
    token != nil and token != Ash.Resource.get_metadata(changeset.data, :token)
  end

  defp own?(%{id: id}, %{actor: %{id: id}}), do: true
  defp own?(_user, _context), do: false
end
