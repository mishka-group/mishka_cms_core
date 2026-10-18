# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.Token do
  @moduledoc """
  Manages authentication tokens in the MishkaCMS system.

  This resource serves as the token store for AshAuthentication, handling the lifecycle
  of JWT tokens used throughout the authentication system. It stores tokens for various
  purposes including authentication, password reset, magic links, and session management.
  The resource tracks token metadata including JTI (JWT ID), subject (user identifier),
  expiration times, and any additional data associated with the token.

  Tokens can be revoked individually or in bulk for a specific subject, enabling secure
  session management and the ability to log users out across all devices. The resource
  provides automatic expiration handling with the ability to purge expired tokens from
  the database. Token revocation is implemented through revocation tokens that mark
  specific JTIs as invalid.

  Access to this resource is strictly controlled through policies that only allow
  AshAuthentication to interact with tokens directly, preventing unauthorized token
  manipulation. The resource supports various token operations including storage,
  retrieval, revocation, and validation checks, forming the backbone of the system's
  token-based authentication infrastructure.

  ## Revoking

  `revoke/1`, `revoke_unissued/1` and `revoke_minted/1` are the ways this application revokes a
  token. Each answers `:ok` or `{:error, error}` and never raises, so a caller that says "logged
  out" knows whether the token still works. `revoked/1` asks whether one already was. `failure/1`
  names a failed revocation for a log line without the token in it.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource]

  # Database configuration for token storage
  postgres do
    table "tokens"
    repo Application.compile_env!(:mishka_cms_core, :repo)
  end

  require Logger

  @doc """
  Revokes `token`, a token this application signed and handed out. `:ok` when it no longer works,
  `{:error, error}` when it may still.
  """
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(token) when is_binary(token),
    do: AshAuthentication.TokenResource.revoke(__MODULE__, token)

  @doc """
  Whether `token` has been revoked: `{:ok, true | false}`, or `{:error, error}` when the revocation
  list could not be read. AshAuthentication's own `token_revoked?/3` answers `true` for a list it
  could not read, which would let a caller report a token as ended that may still work.
  """
  @spec revoked(String.t()) :: {:ok, boolean()} | {:error, term()}
  def revoked(token) when is_binary(token) do
    __MODULE__
    |> Ash.ActionInput.for_action(:revoked?, %{token: token}, domain: MishkaCmsCore.Accounts)
    |> Ash.ActionInput.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.run_action()
  end

  @doc """
  Revokes `token`, one that was signed and never handed to anybody — a sign-in turned away after
  AshAuthentication had already minted its token — so no unused one is left valid.

  `:ok`, or `{:error, error}` once the failure is logged.
  """
  @spec revoke_unissued(String.t()) :: :ok | {:error, term()}
  def revoke_unissued(token) when is_binary(token) do
    case revoke(token) do
      :ok ->
        :ok

      {:error, error} = failed ->
        Logger.error(
          "[Token] a token that was never handed out could not be revoked: #{failure(error)}"
        )

        failed
    end
  end

  @doc """
  `revoke_unissued/1` for the token AshAuthentication put on `user`'s metadata as it signed them
  in; `:ok` for a user that carries none.
  """
  @spec revoke_minted(struct()) :: :ok | {:error, term()}
  def revoke_minted(user) do
    case Ash.Resource.get_metadata(user, :token) do
      token when is_binary(token) -> revoke_unissued(token)
      _none -> :ok
    end
  end

  @doc """
  What failed, for a log line: the modules of the errors and nothing of their values, which can hold
  the token.
  """
  @spec failure(term()) :: String.t()
  def failure(%{errors: [_ | _] = errors}), do: Enum.map_join(errors, ", ", &failure/1)
  def failure(%{__struct__: module}), do: inspect(module)
  def failure(_other), do: "an unexpected error"

  actions do
    defaults [:read]

    read :expired do
      description "Look up all expired tokens."
      filter expr(expires_at < now())
    end

    read :get_token do
      description "Look up a token by JTI or token, and an optional purpose."
      get? true
      argument :token, :string, sensitive?: true
      argument :jti, :string, sensitive?: true
      argument :purpose, :string, sensitive?: false

      prepare AshAuthentication.TokenResource.GetTokenPreparation
    end

    action :revoked?, :boolean do
      description "Returns true if a revocation token is found for the provided token"
      argument :token, :string, sensitive?: true
      argument :jti, :string, sensitive?: true

      run AshAuthentication.TokenResource.IsRevoked
    end

    create :revoke_token do
      description "Revoke a token. Creates a revocation token corresponding to the provided token."
      accept [:extra_data]
      argument :token, :string, allow_nil?: false, sensitive?: true

      change AshAuthentication.TokenResource.RevokeTokenChange
    end

    create :revoke_jti do
      description "Revoke a token by JTI. Creates a revocation token corresponding to the provided jti."
      accept [:extra_data]
      argument :subject, :string, allow_nil?: false, sensitive?: true
      argument :jti, :string, allow_nil?: false, sensitive?: true

      change AshAuthentication.TokenResource.RevokeJtiChange
    end

    create :store_token do
      description "Stores a token used for the provided purpose."
      accept [:extra_data, :purpose]
      argument :token, :string, allow_nil?: false, sensitive?: true
      change AshAuthentication.TokenResource.StoreTokenChange
    end

    destroy :expunge_expired do
      description "Deletes expired tokens."
      change filter expr(expires_at < now())
    end

    update :revoke_all_stored_for_subject do
      description "Revokes all stored tokens for a specific subject."
      accept [:extra_data]
      argument :subject, :string, allow_nil?: false, sensitive?: true
      change AshAuthentication.TokenResource.RevokeAllStoredForSubjectChange
    end
  end

  # Authorization policies - restricted to AshAuthentication only
  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      description "AshAuthentication can interact with the token resource"
      authorize_if always()
    end

    policy always() do
      description "No one aside from AshAuthentication can interact with the tokens resource."
      forbid_if always()
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key? true
      public? true
      allow_nil? false
      sensitive? true
      description "JWT ID - unique identifier for the token"
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      description "Subject claim identifying the user or entity the token belongs to"
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
      description "Timestamp when the token expires and becomes invalid"
    end

    attribute :purpose, :string do
      allow_nil? false
      public? true
      description "Purpose of the token (e.g., authentication, reset, confirmation)"
    end

    attribute :extra_data, :map do
      public? true
      description "Additional metadata associated with the token"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
