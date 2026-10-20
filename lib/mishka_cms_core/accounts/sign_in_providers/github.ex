# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SignInProviders.GitHub do
  @moduledoc """
  Signing in with a GitHub account: the `github` strategy on `MishkaCmsCore.Accounts.User`, with an
  OAuth app made under GitHub → Settings → Developer settings → OAuth Apps. Its authorization
  callback URL is the site's `MishkaCmsCore.Accounts.SignInProvider.callback_url/2`. The account's
  primary email is the one used, and only when GitHub says it is verified.
  """

  use MishkaCmsCore.Accounts.SignInProvider,
    id: "github",
    strategy: :github,
    label: gettext_noop("GitHub"),
    priority: 20

  @client_id "auth.providers.github.client_id"
  @client_secret "auth.providers.github.client_secret"

  @impl true
  def icon,
    do: %{
      color: "text-[#1b1a18]",
      path:
        "M12 2a10 10 0 0 0-3.2 19.5c.5.1.7-.2.7-.5v-1.8c-2.8.6-3.4-1.3-3.4-1.3-.4-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.3 1.1 2.9.8.1-.7.4-1.1.7-1.4-2.2-.3-4.6-1.1-4.6-5 0-1.1.4-2 1-2.7-.1-.3-.4-1.3.1-2.7 0 0 .8-.3 2.7 1a9.4 9.4 0 0 1 5 0c1.9-1.3 2.7-1 2.7-1 .5 1.4.2 2.4.1 2.7.6.7 1 1.6 1 2.7 0 3.9-2.4 4.7-4.6 5 .4.3.7 1 .7 2v3c0 .3.2.6.7.5A10 10 0 0 0 12 2z"
    }

  @impl true
  def settings do
    [
      key(@client_id, gettext_noop("GitHub client ID"),
        description:
          gettext_noop(
            "From the OAuth app made for this site in GitHub's developer settings. Its redirect address is this site's address followed by /api/auth/user/github/callback."
          )
      ),
      key(@client_secret, :secret, gettext_noop("GitHub client secret"),
        description: gettext_noop("From the same app. Stored sealed and never shown again.")
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
