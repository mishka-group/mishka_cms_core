# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends a new user the link to confirm their email address, through `MishkaCmsCore.Mail` from the
  site they registered on (see `MishkaCmsCore.Accounts.Helper.send_auth_email/3`).

  The first-run installer (`MishkaCmsCore.Install.Bootstrap`) confirms the master user in place and
  must not email them: it tags that changeset with `mishka_install: true`, which AshAuthentication
  threads through to `context[:changeset]`, so `send/3` returns `:ok` without sending for that case.
  """

  use AshAuthentication.Sender
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def send(user, token, context) do
    case context[:changeset] do
      %Ash.Changeset{context: %{mishka_install: true}} ->
        :ok

      _ ->
        domain = Helper.get_email_sender_domain(user, context)

        if domain && Helper.may_email?(user, context) do
          link = Helper.auth_link(domain, "confirm-new-user", token, context[:tenant])
          line = gettext("Click this link to confirm your email:")

          Helper.send_auth_email(user, context,
            purpose: "confirmation",
            token: token,
            subject: gettext("Confirm your email address"),
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
end
