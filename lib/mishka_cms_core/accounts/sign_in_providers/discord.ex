# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.SignInProviders.Discord do
  @moduledoc """
  Signing in with a Discord account: AshAuthentication's generic `oauth2` strategy, named `discord`
  on `MishkaCmsCore.Accounts.User`, pointed at Discord's OAuth2 addresses with the `identify` and
  `email` scopes, and an application made at discord.com/developers/applications. Under OAuth2 its
  redirect is the site's `MishkaCmsCore.Accounts.SignInProvider.callback_url/2`.

  Discord answers its own user object, so `user_info/1` reads it as the other providers' claims:
  its `id` is the `sub`, and its `verified` — whether Discord confirmed the email — is
  `email_verified`, true only when Discord says exactly `true`. An account with no email, or one
  Discord has not verified, does not sign in.
  """

  use MishkaCmsCore.Accounts.SignInProvider,
    id: "discord",
    strategy: :discord,
    label: gettext_noop("Discord"),
    priority: 40

  @client_id "auth.providers.discord.client_id"
  @client_secret "auth.providers.discord.client_secret"

  @impl true
  def icon,
    do: %{
      color: "text-[#5865f2]",
      path:
        "M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z"
    }

  @impl true
  def settings do
    group = gettext_noop("Discord sign-in")

    [
      key(@client_id, gettext_noop("Discord client ID"),
        group: group,
        description:
          gettext_noop(
            "From the OAuth2 page of the Discord application made for this site, at discord.com/developers/applications."
          )
      ),
      key(@client_secret, :secret, gettext_noop("Discord client secret"),
        group: group,
        description: gettext_noop("From the same page. Stored sealed and never shown again.")
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

  @impl true
  def user_info(%{} = info) do
    info
    |> Map.put("sub", to_string(info["id"]))
    |> Map.put("email_verified", info["verified"] == true)
  end

  defp present(value) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_none), do: :error
end
