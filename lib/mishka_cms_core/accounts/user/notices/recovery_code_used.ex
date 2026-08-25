defmodule MishkaCmsCore.Accounts.User.Notices.RecoveryCodeUsed do
  @moduledoc """
  A mishka_installer plugin on `"auth:recovery_code:used"`: emails the account that one of its
  recovery codes signed someone in, and how many are left, so whoever did not do it hears of it.
  Sent as the sign-in emails are (`MishkaCmsCore.Accounts.Helper.send_auth_email/3`), from the
  account's own site, the installation's for a master. Registered in `MishkaCmsCore.Application`.
  """
  use MishkaInstaller.Event.Hook, event: "auth:recovery_code:used", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.{Helper, User}

  @impl true
  def call(%{user_id: user_id, site_id: site_id, left: left} = event) do
    context = %{tenant: site_id}

    with {:ok, user} <- Ash.get(User, user_id, tenant: site_id, authorize?: false),
         true <- Helper.may_email?(user, context) do
      line =
        ngettext(
          "A recovery code was used to sign in to your account. You have %{count} left.",
          "A recovery code was used to sign in to your account. You have %{count} left.",
          left
        )

      next =
        gettext(
          "If this was not you, change your password and make new recovery codes on Settings → Preferences."
        )

      Helper.send_auth_email(user, context,
        purpose: "recovery_code_used",
        token: "#{user_id}:#{System.system_time(:nanosecond)}",
        subject: gettext("A recovery code was used"),
        html: "<p>#{line}</p><p>#{next}</p>",
        text: "#{line}\n\n#{next}\n"
      )
    end

    {:reply, event}
  end

  def call(event), do: {:reply, event}
end
