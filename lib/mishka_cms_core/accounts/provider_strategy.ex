# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.ProviderStrategy do
  @moduledoc """
  One AshAuthentication strategy for every sign-in provider, whichever the installed plugins are:
  the core names none of them.

  Modelled on AshAuthentication's own `dynamic_oidc`, with the provider coming from a
  `mishka_installer` plugin (`MishkaCmsCore.Accounts.SignInProvider`) instead of a database row,
  and any Assent provider rather than OpenID Connect alone. At a request,
  `MishkaCmsCore.Accounts.ProviderStrategy.Plug` finds the plugin the path names, fills this
  struct with its Assent strategy, Assent's own defaults for it and the site's keys, and hands it
  to AshAuthentication's `OAuth2.Plug`, which does the sign-in. The provider's id is the
  connection id, so each provider's identities are kept apart (`"provider/<id>"`).

      authentication do
        strategies do
          sign_in_providers :provider do
            identity_resource MishkaCmsCore.Accounts.UserIdentity
            register_action_name :register_with_provider
          end
        end
      end

  Its routes, under the host's auth mount: `/user/provider/:provider/request` starts a sign-in, and
  `/user/provider/callback` is where every provider sends the visitor back — the provider the sign-in
  started with waits in the session, as `dynamic_oidc` keeps its connection.
  """

  alias __MODULE__.Dsl
  alias AshAuthentication.Strategy.OAuth2

  # One field per option of the strategy, as AshAuthentication's own OAuth2 strategy has.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct assent_strategy: Assent.Strategy.OAuth2,
            auth_method: nil,
            authorization_params: [],
            authorize_url: nil,
            base_url: nil,
            client_authentication_method: nil,
            client_id: nil,
            client_secret: nil,
            code_verifier: false,
            email_field: :email,
            icon: :oauth2,
            id_token_signed_response_alg: "RS256",
            id_token_ttl_seconds: nil,
            identity_relationship_name: :identities,
            identity_relationship_user_id_attribute: :user_id,
            identity_resource: false,
            idp_initiated_login?: false,
            name: nil,
            nonce: false,
            on_untrusted_email_match: :reject,
            openid_configuration: nil,
            openid_configuration_uri: "/.well-known/openid-configuration",
            openid_default_scope: nil,
            prevent_hijacking?: true,
            private_key: nil,
            private_key_id: nil,
            private_key_path: nil,
            provider: :sign_in_providers,
            redirect_uri: nil,
            register_action_name: nil,
            registration_enabled?: true,
            resource: nil,
            session_identifier: :unsafe,
            sign_in_action_name: nil,
            site: nil,
            strategy_module: __MODULE__,
            team_id: nil,
            token_url: nil,
            trust_email_verified?: true,
            trusted_audiences: nil,
            user_url: nil,
            warn_on_missing_identity_resource?: true,
            __connection_id__: nil,
            __spark_metadata__: nil

  use AshAuthentication.Strategy.Custom, entity: Dsl.dsl()

  @type t :: %__MODULE__{}

  # The register action and the identity relationship are AshAuthentication's OAuth2 ones.
  @impl true
  def transform(strategy, dsl_state),
    do: OAuth2.transform(strategy, dsl_state)

  @impl true
  def verify(strategy, dsl_state) do
    with :ok <- OAuth2.Verifier.validate_confirmation_for_untrusted_match(dsl_state, strategy) do
      OAuth2.Verifier.prevent_hijacking(dsl_state, strategy)
    end
  end
end
