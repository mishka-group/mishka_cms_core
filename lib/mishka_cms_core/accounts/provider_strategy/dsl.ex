# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.ProviderStrategy.Dsl do
  @moduledoc false

  alias AshAuthentication.Strategy.{Custom, Oidc}
  alias MishkaCmsCore.Accounts.ProviderStrategy

  # AshAuthentication's OIDC entity, less everything a provider plugin supplies at a request: its
  # addresses, its keys and the callback address.
  @spec dsl :: Custom.entity()
  def dsl do
    Oidc.dsl()
    |> Map.merge(%{
      name: :sign_in_providers,
      target: ProviderStrategy,
      args: [{:optional, :name, :provider}],
      describe: """
      Signs in with whichever provider a `mishka_installer` plugin on `"auth:providers"` names in
      the request path — see `MishkaCmsCore.Accounts.ProviderStrategy`.
      """,
      auto_set_fields: [
        assent_strategy: Assent.Strategy.OAuth2,
        icon: :oauth2,
        provider: :sign_in_providers
      ],
      schema: schema()
    })
  end

  defp schema do
    Oidc.dsl()
    |> Map.get(:schema, [])
    |> Keyword.drop([
      :base_url,
      :client_id,
      :client_secret,
      :redirect_uri,
      :authorize_url,
      :token_url,
      :user_url,
      :private_key,
      :private_key_id,
      :private_key_path,
      :team_id,
      :nonce,
      :openid_default_scope,
      :authorization_params
    ])
    |> Keyword.put(:trust_email_verified?,
      type: :boolean,
      default: true,
      doc:
        "Every provider's `email_verified` claim is trusted, as Assent reads it for that provider."
    )
  end
end
