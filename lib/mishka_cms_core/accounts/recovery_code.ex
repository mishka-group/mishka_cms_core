defmodule MishkaCmsCore.Accounts.RecoveryCode do
  @moduledoc """
  An account's one-time recovery codes, for signing in when its authenticator app is lost — the
  store of AshAuthentication's `recovery_code` strategy on `MishkaCmsCore.Accounts.User`. See
  `MishkaCmsCore.Accounts.SecondFactor`.

  Only a hash of each code is kept; the codes themselves are shown once, when they are made. A code
  that signs someone in is deleted. Like `MishkaCmsCore.Accounts.Token`, a row is reached through
  its account and never by site: the strategy's own reads and deletes carry AshAuthentication's
  context, and otherwise an account reaches only its own.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "recovery_codes"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:code]
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      description "An account's own codes, made and cleared by its own actions"
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :code, :string do
      allow_nil? false
      sensitive? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, MishkaCmsCore.Accounts.User do
      allow_nil? false
    end
  end
end
