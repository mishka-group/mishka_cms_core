# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.User.Senders.SendMagicLinkEmail do
  @moduledoc """
  Sends a sign-in link, through `MishkaCmsCore.Mail` from the site the request came to (see
  `MishkaCmsCore.Accounts.Helper.send_auth_email/3`). Nothing is sent where the site cannot be told
  apart or may not email (`Helper.may_email?/2`).
  """

  use AshAuthentication.Sender
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Helper

  @impl true
  def send(user_or_email, token, context) do
    domain = Helper.get_email_sender_domain(user_or_email, context)

    if domain && Helper.may_email?(user_or_email, context) do
      email = to_string(Map.get(map(user_or_email), :email, user_or_email))
      link = Helper.auth_link(domain, "magic-link", token, context[:tenant])
      greeting = gettext("Hello, %{email}! Click this link to sign in:", email: email)

      Helper.send_auth_email(user_or_email, context,
        purpose: "magic_link",
        token: token,
        subject: gettext("Your login link"),
        html: """
        <p>#{escape(greeting)}</p>
        <p><a href="#{escape(link)}">#{escape(link)}</a></p>
        """,
        text: "#{greeting}\n\n#{link}\n"
      )
    else
      :ok
    end
  end

  defp map(%{} = user), do: user
  defp map(_email), do: %{}

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
