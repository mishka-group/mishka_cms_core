defmodule MishkaCmsCore.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset link, through `MishkaCmsCore.Mail` from the site the request came to (see
  `MishkaCmsCore.Accounts.Helper.send_auth_email/3`).
  """

  use AshAuthentication.Sender
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def send(user, token, context) do
    domain = Helper.get_email_sender_domain(user, context)

    if domain && Helper.may_email?(user, context) do
      link = Helper.auth_link(domain, "password-reset", token, context[:tenant])
      line = gettext("Click this link to reset your password:")

      Helper.send_auth_email(user, context,
        purpose: "password_reset",
        token: token,
        subject: gettext("Reset your password"),
        html: """
        <p>#{line}</p>
        <p><a href="#{link}">#{link}</a></p>
        """,
        text: "#{line}\n\n#{link}\n"
      )
    else
      :ok
    end
  end
end
