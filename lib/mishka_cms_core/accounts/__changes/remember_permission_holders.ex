# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Changes.RememberPermissionHolders do
  @moduledoc """
  Puts the ids of the users holding this permission into the changeset, before the write.

  `MishkaCmsCore.Accounts.Notifiers.DisconnectLiveSockets` cuts their live sockets once the write
  commits, and by then it can no longer find them on its own: `user_permissions` declares the
  permission `on_delete: :delete`, so a deleted permission takes its grant rows with it inside the
  database, without an action of its own to notify about. A rename leaves the rows alone but changes
  what `MishkaCmsCore.Accounts.Checks.AccessPermissions` answers for every one of them.

  Added for every update and every destroy on the resource rather than to the two actions there are
  today, so an action written later cannot be the one that forgets it.

  ONLY A WRITE THAT CHANGES THE ANSWER PAYS FOR IT. `AccessPermissions` reads nothing of a permission
  but its name, so correcting a description cannot take anybody's access away — and a permission held
  by every signed-in account would otherwise cost a read of every grant row inside the transaction
  and a reconnect for every holder, from a typo fix. The holders are remembered for a destroy,
  because the rows are about to go, and for an update that writes `:name`.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changes_the_answer?(changeset),
        do: Ash.Changeset.put_context(changeset, :permission_holders, holders(changeset.data.id)),
        else: changeset
    end)
  end

  # The attributes a write touches are in the changeset either as cast values or as atomic
  # expressions, and both are asked, so an action that renames atomically is not missed.
  defp changes_the_answer?(%Ash.Changeset{action: %{type: :destroy}}), do: true

  defp changes_the_answer?(%Ash.Changeset{attributes: attributes, atomics: atomics}),
    do: :name in Map.keys(attributes) or Keyword.has_key?(atomics, :name)

  defp holders(permission_id) do
    MishkaCmsCore.Accounts.UserPermission
    |> Ash.Query.filter(permission_id == ^permission_id)
    |> Ash.Query.select([:user_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.user_id)
  end
end
