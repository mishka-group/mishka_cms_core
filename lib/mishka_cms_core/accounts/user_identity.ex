# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.UserIdentity do
  @moduledoc """
  One sign-in provider an account has used: AshAuthentication's user identity, a row per provider
  per account, keyed on the provider's stable user id (`uid`, its `sub`) — never the email. Google,
  GitHub and Slack can all sit on one account. See `MishkaCmsCore.Accounts.SignInProvider`.

  Kept per site, as accounts are: the same Google account signs in to each site as that site's own
  account. A master's identities have no site. Unique on the provider and its user id within a site,
  and among masters (`nils_distinct? false`), so a sign-in updates the row it made before.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.UserIdentity]

  postgres do
    table "user_identities"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :user, on_delete: :delete
      reference :site, on_delete: :delete
    end
  end

  user_identity do
    user_resource MishkaCmsCore.Accounts.User
  end

  # Written and read by the sign-in itself (`AshAuthentication.Checks.AshAuthenticationInteraction`)
  # and by nothing else.
  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  # The site's own column, made with the table: as a relationship's, the generated migration added
  # it after the unique index that names it.
  attributes do
    attribute :site_id, :uuid do
      allow_nil? true
      public? false
    end
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      define_attribute? false
      source_attribute :site_id
      allow_nil? true
      public? false
    end
  end

  identities do
    identity :unique_on_strategy_and_uid, [:strategy, :uid] do
      nils_distinct? false
    end
  end
end
