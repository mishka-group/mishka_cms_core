# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SignInProviders.Google do
  @moduledoc """
  Signing in with a Google account: the `google` strategy on `MishkaCmsCore.Accounts.User`, with an
  OAuth client made in the Google Cloud console (APIs & Services → Credentials → OAuth client ID,
  type "Web application"). Its authorized redirect URI is the site's
  `MishkaCmsCore.Accounts.SignInProvider.callback_url/2`. Google says whether the email is verified,
  and only a verified one signs in.
  """

  use MishkaCmsCore.Accounts.SignInProvider,
    id: "google",
    strategy: :google,
    label: gettext_noop("Google"),
    priority: 10

  @client_id "auth.providers.google.client_id"
  @client_secret "auth.providers.google.client_secret"

  @impl true
  def icon,
    do: %{
      color: "text-[#4285f4]",
      path:
        "M21.4 12.2c0-.7-.1-1.4-.2-2H12v3.9h5.3a4.5 4.5 0 0 1-2 3v2.4h3.1c1.9-1.7 3-4.3 3-7.3z M12 22c2.7 0 5-.9 6.7-2.4l-3.2-2.4c-.9.6-2 1-3.5 1a5.9 5.9 0 0 1-5.5-4H3.2v2.5A10 10 0 0 0 12 22z M6.5 14.2a6 6 0 0 1 0-3.8V7.9H3.2a10 10 0 0 0 0 8.6l3.3-2.3z M12 6c1.5 0 2.8.5 3.8 1.5l2.8-2.8A10 10 0 0 0 3.2 7.9l3.3 2.5A5.9 5.9 0 0 1 12 6z"
    }

  @impl true
  def settings do
    group = gettext_noop("Google sign-in")

    [
      key(@client_id, gettext_noop("Google client ID"),
        group: group,
        description:
          gettext_noop(
            "From the OAuth client made for this site in the Google Cloud console, type \"Web application\"."
          )
      ),
      key(@client_secret, :secret, gettext_noop("Google client secret"),
        group: group,
        description: gettext_noop("From the same client. Stored sealed and never shown again.")
      )
    ]
  end

  @impl true
  def ready?(site_id), do: own(@client_id, site_id) != nil and secret?(@client_secret, site_id)

  @impl true
  def secret(:client_id, site_id), do: present(own(@client_id, site_id))

  def secret(:client_secret, site_id),
    do: present(MishkaCmsCore.Settings.secret(@client_secret, site_id))

  def secret(_name, _site_id), do: :error

  defp present(value) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_none), do: :error
end
