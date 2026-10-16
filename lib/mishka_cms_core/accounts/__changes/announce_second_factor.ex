# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Changes.AnnounceSecondFactor do
  @moduledoc """
  Tells plugins an account turned its authenticator on or off, or made recovery codes, once the
  write succeeds: `"auth:second_factor:enabled"` and `"auth:recovery_codes:generated"` with
  `%{user_id:, site_id:}`, `"auth:second_factor:disabled"` with `%{user_id:, site_id:, by:}` — `by`
  the id of the admin who turned it off, `nil` when the account did. All with `return: false`.

      change {AnnounceSecondFactor, event: :enabled}
  """
  use Ash.Resource.Change

  alias MishkaInstaller.Event.Hook

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      Hook.call(event(opts[:event]), payload(opts[:event], user, context.actor), return: false)
      {:ok, user}
    end)
  end

  defp event(:enabled), do: "auth:second_factor:enabled"
  defp event(:disabled), do: "auth:second_factor:disabled"
  defp event(:recovery_codes), do: "auth:recovery_codes:generated"

  defp payload(:disabled, user, actor),
    do: %{user_id: user.id, site_id: user.site_id, by: by(actor, user)}

  defp payload(_event, user, _actor), do: %{user_id: user.id, site_id: user.site_id}

  defp by(%{id: id}, %{id: user_id}) when id != user_id, do: id
  defp by(_actor, _user), do: nil
end
