# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.SignInProviders do
  @moduledoc """
  Sign-in providers for the core's own tests, standing in for the `mishka_cms_auth_*` packages: one
  plugin per strategy the User resource declares, with a client ID and a sealed secret per site.
  `start/0` registers them for a test module and waits until they are live.

      setup_all do
        MishkaCmsCore.Test.SignInProviders.start()
      end
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias MishkaCmsCore.Settings

  @providers [
    MishkaCmsCore.Test.Plugins.SignInGoogle,
    MishkaCmsCore.Test.Plugins.SignInGitHub,
    MishkaCmsCore.Test.Plugins.SignInSlack,
    MishkaCmsCore.Test.Plugins.SignInDiscord
  ]

  @doc "The test providers."
  def all, do: @providers

  @doc "Starts every test provider and waits until each is registered on `auth:providers`."
  def start do
    Enum.each(@providers, &start_supervised!/1)
    MishkaCmsCore.Test.Installer.await(@providers)
    :ok
  end

  @doc "A provider's key fields, as a package's are."
  def settings(id) do
    [
      MishkaCmsCore.Accounts.SignInProvider.key(
        "auth.providers.#{id}.client_id",
        "Client ID",
        []
      ),
      MishkaCmsCore.Accounts.SignInProvider.key(
        "auth.providers.#{id}.client_secret",
        :secret,
        "Client secret",
        []
      )
    ]
  end

  @doc "Whether `site_id` holds both keys."
  def ready?(id, site_id),
    do:
      MishkaCmsCore.Captcha.Provider.own("auth.providers.#{id}.client_id", site_id) != nil and
        Settings.secret("auth.providers.#{id}.client_secret", site_id) != nil

  @doc "A key by the name AshAuthentication asks it by."
  def secret(id, :client_id, site_id),
    do: present(MishkaCmsCore.Captcha.Provider.own("auth.providers.#{id}.client_id", site_id))

  def secret(id, :client_secret, site_id),
    do: present(Settings.secret("auth.providers.#{id}.client_secret", site_id))

  def secret(_id, _name, _site_id), do: :error

  defp present(value) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_none), do: :error
end
