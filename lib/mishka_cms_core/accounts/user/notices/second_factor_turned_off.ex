# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.User.Notices.SecondFactorTurnedOff do
  @moduledoc """
  A mishka_installer plugin on `"auth:second_factor:disabled"`: emails the account that its two-step
  sign-in was turned off — by an admin, or by the account itself — so whoever did not do it hears
  of it. Sent as the sign-in emails are (`MishkaCmsCore.Accounts.Helper.send_auth_email/3`), from
  the account's own site, the installation's for a master. Registered in
  `MishkaCmsCore.Application`.
  """
  use MishkaInstaller.Event.Hook, event: "auth:second_factor:disabled", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.{Helper, User}

  @impl true
  def call(%{user_id: user_id, site_id: site_id} = event) do
    context = %{tenant: site_id}

    with {:ok, user} <- Ash.get(User, user_id, tenant: site_id, authorize?: false),
         true <- Helper.may_email?(user, context) do
      line = line(event[:by])

      next =
        gettext(
          "You now sign in with your password alone. If you did not ask for this, change your password and set up two-step sign-in again."
        )

      Helper.send_auth_email(user, context,
        purpose: "second_factor_off",
        token: "#{user_id}:#{System.system_time(:nanosecond)}",
        subject: subject(event[:by]),
        html: "<p>#{line}</p><p>#{next}</p>",
        text: "#{line}\n\n#{next}\n"
      )
    end

    {:reply, event}
  end

  def call(event), do: {:reply, event}

  defp subject(nil), do: gettext("Two-step sign-in was turned off")
  defp subject(_admin), do: gettext("An administrator turned off your two-step sign-in")

  defp line(nil), do: gettext("Two-step sign-in was turned off for your account.")

  defp line(_admin),
    do: gettext("An administrator turned off two-step sign-in for your account.")
end
