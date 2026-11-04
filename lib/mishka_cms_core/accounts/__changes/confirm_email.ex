# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Changes.ConfirmEmail do
  @moduledoc """
  Marks an account's email address as confirmed on behalf of an admin, and tells plugins once the
  write succeeds: `"auth:account:confirmed"` with `%{user_id:, site_id:, by:}`, `by` the admin's id,
  with `return: false`.

  An account confirmed already is left as it is and announces nothing, so the change is safe to
  run over a mixed set of accounts.

      change MishkaCmsCore.Accounts.Changes.ConfirmEmail
  """
  use Ash.Resource.Change

  @impl true
  def change(%{data: %{confirmed_at: nil}} = changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
    |> Ash.Changeset.after_action(fn _changeset, user ->
      MishkaInstaller.Event.Hook.call(
        "auth:account:confirmed",
        %{user_id: user.id, site_id: user.site_id, by: by(changeset)},
        return: false
      )

      {:ok, user}
    end)
  end

  def change(changeset, _opts, _context), do: changeset

  defp by(%{context: %{private: %{actor: %{id: id}}}}), do: id
  defp by(_changeset), do: nil
end
