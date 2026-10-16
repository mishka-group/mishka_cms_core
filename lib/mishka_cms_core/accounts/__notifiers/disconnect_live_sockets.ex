# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Notifiers.DisconnectLiveSockets do
  @moduledoc """
  Cuts a user's live sockets after any write that can shrink what they may reach or end their being
  signed in at all — see `MishkaCmsCore.Accounts.LiveSockets` for what "cut" means here.

  In the notifier rather than in the actions, because a permission is taken away from the admin
  form, from a JSON:API request and from in-app code, and all three arrive here. Notifiers run after
  the transaction commits, so a socket is only cut once the change it is being cut for is real.

  ## What it watches

  * `MishkaCmsCore.Accounts.UserPermission` — the grant itself. Every add and every removal writes a
    row of this join, whichever action on `User` asked for it, so watching the join catches the
    whole class instead of a list of action names that the next action would not be on.
  * `MishkaCmsCore.Accounts.User` — a destroy, because the account is gone, and an update that
    writes anything but the address the account signs in with.
  * `MishkaCmsCore.Accounts.Permission` — renaming one changes what
    `MishkaCmsCore.Accounts.Checks.AccessPermissions` answers for everyone holding it, and deleting
    one takes their grants with it. Who held it is read before the write by
    `MishkaCmsCore.Accounts.Changes.RememberPermissionHolders`, because by the time this runs the
    grant rows of a deleted permission are gone.
  """
  @behaviour Ash.Notifier

  alias MishkaCmsCore.Accounts.{LiveSockets, Permission, User, UserPermission}

  # THE ONLY THINGS AN UPDATE MAY WRITE WITHOUT COSTING THE SOCKETS: the email, and the account's
  # authenticator — turned on or off, or a code from it accepted on another device — which asks
  # something of the next sign-in and nothing of a session that is already open. Everything else
  # counts, named or not: the password the account is entered with, the site it belongs to, a column
  # added to the resource long after this line. A socket kept by mistake is a page still answering
  # somebody it should not; a socket cut by mistake is a reconnect nobody notices.
  @indifferent_attributes [:email, :totp_secret, :last_totp_at]

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: User,
        action: %{type: :destroy},
        data: %{id: user_id}
      }),
      do: LiveSockets.disconnect(user_id)

  def notify(%Ash.Notifier.Notification{
        resource: User,
        action: %{type: :update},
        data: %{id: user_id},
        changeset: changeset
      }) do
    if reaches_the_sockets?(changeset), do: LiveSockets.disconnect(user_id), else: :ok
  end

  def notify(%Ash.Notifier.Notification{resource: UserPermission, data: %{user_id: user_id}}),
    do: LiveSockets.disconnect(user_id)

  def notify(%Ash.Notifier.Notification{
        resource: Permission,
        changeset: %{context: %{permission_holders: holders}}
      }),
      do: Enum.each(holders, &LiveSockets.disconnect/1)

  def notify(_notification), do: :ok

  # Never ask for the original record: requesting it forces a pre-action load, which makes the
  # action non-atomic. Nothing here reads it — the notification carries the acted-on record, and an
  # update is judged by what its changeset wrote.
  @impl true
  def requires_original_data?(_resource, _action), do: false

  # AN UPDATE THAT CANNOT BE READ IS AN UPDATE THAT COUNTS. The attributes a write touches are in the
  # changeset either as cast values or as atomic expressions, and both are asked; anything that is
  # not a changeset at all leaves nothing to judge by, so the sockets go.
  defp reaches_the_sockets?(%Ash.Changeset{attributes: attributes, atomics: atomics}) do
    written = Map.keys(attributes) ++ Keyword.keys(atomics)
    Enum.any?(written, &(&1 not in @indifferent_attributes))
  end

  defp reaches_the_sockets?(_no_changeset), do: true
end
