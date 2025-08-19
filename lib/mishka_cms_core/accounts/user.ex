defmodule MishkaCmsCore.Accounts.User do
  @moduledoc """
  Manages user accounts and authentication in the MishkaCMS system.

  This resource implements comprehensive user authentication using AshAuthentication,
  supporting multiple strategies including password-based login, magic links, and
  password reset flows. Users can be associated with specific sites for multi-tenant
  isolation or exist as global users with cross-site access. The resource includes
  email confirmation, token-based authentication, and session management with the
  ability to log out everywhere on password changes.

  Users maintain many-to-many relationships with permissions, enabling fine-grained
  access control throughout the system. The resource enforces email uniqueness,
  validates email formats, and ensures master user separation for system security.
  Authentication tokens are stored and validated, with JWT-based token generation
  for API access and session management.

  The resource implements sophisticated policies for authorization, controlling who
  can register users, change passwords, and access user data. It integrates with
  custom senders for email notifications including confirmation emails, password
  reset instructions, and magic link delivery. Multi-tenancy support ensures users
  are properly isolated between sites while allowing authorized cross-site operations.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook
    ],
    extensions: [AshAuthentication, AshJsonApi.Resource]

  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  authentication do
    add_ons do
      # A changed password revokes every token, after the write commits: see
      # `MishkaCmsCore.Accounts.Changes.LogOutEverywhereOnPasswordChange` in `changes`.
      log_out_everywhere do
        apply_on_password_change? false
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at

        # Magic-link sign-in is a read now, and a read runs no change, so the confirmation hook that
        # reads this list never sees it. Someone who signed up and never confirmed still confirms
        # from the mail they were sent.
        auto_confirm_actions [:reset_password_with_token]
        sender MishkaCmsCore.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource MishkaCmsCore.Accounts.Token
      signing_secret MishkaCmsCore.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender MishkaCmsCore.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      magic_link do
        identity_field :email
        # Sign-in only. With this on, a link requested for an address nobody holds creates the
        # account on the way in — a second sign-up route with none of `register_with_password`'s
        # validations, and one that mints a MASTER user when the request carries no tenant. Off, the
        # library builds the sign-in as a read instead of an upsert, so an address with no account
        # has nothing to sign in to.
        registration_enabled? false
        require_interaction? true

        sender MishkaCmsCore.Accounts.User.Senders.SendMagicLinkEmail
      end
    end
  end

  # Database configuration for user storage
  postgres do
    table "users"
    repo Application.compile_env!(:mishka_cms_core, :repo)
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "user"

    default_fields [:id, :email, :confirmed_at, :site_id, :site]
  end

  actions do
    defaults [:read]

    read :read_current_user do
      description "Retrieves the current authenticated user's record"
      get? true
      filter expr(id == ^actor(:id))
    end

    create :create do
      description "Creates a new user with email and hashed password"
      # before/reject seam (e.g. ban-list / captcha / domain allow-list before account creation)
      change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook
      accept [:email, :hashed_password]
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :change_password do
      description "Allows authenticated users to change their password with current password verification"
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password},
               before_action?: true

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      prepare fn query, _context ->
        query = Ash.Query.set_context(query, %{private: %{ash_authentication?: true}})
        current_tenant = query.tenant

        query =
          if current_tenant,
            do: Ash.Query.filter(query, site_id == ^current_tenant),
            else: Ash.Query.filter(query, is_nil(site_id))

        query |> Ash.Query.load(:site)
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      description "Exchanges a short-lived sign in token for a standard authentication token"
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :me, :struct do
      description "Get the current authenticated user"
      constraints instance_of: MishkaCmsCore.Accounts.User

      run fn _input, context ->
        MishkaCmsCore.Accounts.User
        |> Ash.Query.new()
        |> Ash.Query.filter(id == ^context.actor.id)
        |> Ash.Query.load([:site])
        |> Ash.read_one(authorize?: false)
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))

      change fn changeset, context ->
        current_tenant = changeset.tenant

        if current_tenant do
          Ash.Changeset.change_attribute(changeset, :site_id, current_tenant)
        else
          changeset
        end
      end

      validate MishkaCmsCore.Accounts.Validations.ValidEmail

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get? true

      argument :email, :ci_string do
        allow_nil? false
      end

      filter expr(email == ^arg(:email))

      # WITH NO TENANT, ONLY A MASTER. A reset or a magic link asked for on the master accounts' sign-in
      # finds the master holding the address and nobody else, as `sign_in_with_password` does — never
      # a site's user who happens to share it, for whom a link would be minted and not sent.
      prepare fn query, _context ->
        if query.tenant, do: query, else: Ash.Query.filter(query, is_nil(site_id))
      end
    end

    action :reset_password_api, :struct do
      description "API endpoint for resetting password with token validation"
      constraints instance_of: MishkaCmsCore.Accounts.User

      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      run fn input, context ->
        reset_token = input.arguments.reset_token
        password = input.arguments.password
        password_confirmation = input.arguments.password_confirmation

        verification_opts = if context.tenant, do: [tenant: context.tenant], else: []

        with {:ok, %{"sub" => sub} = claims, _} <-
               AshAuthentication.Jwt.verify(
                 reset_token,
                 MishkaCmsCore.Accounts.User,
                 verification_opts
               ),
             "user?id=" <> user_id = sub,
             tenant = Map.get(claims, "tenant"),
             {:ok, user} <-
               Ash.get(MishkaCmsCore.Accounts.User, user_id,
                 tenant: tenant,
                 authorize?: false
               ) do
          user
          |> Ash.Changeset.for_update(
            :reset_password_with_token,
            %{
              reset_token: reset_token,
              password: password,
              password_confirmation: password_confirmation
            },
            authorize?: false,
            tenant: tenant
          )
          |> Ash.update()
        else
          {:error, _} = error ->
            error

          _ ->
            {:error,
             Ash.Error.Changes.InvalidArgument.exception(
               field: :reset_token,
               message: dgettext_noop("errors", "is invalid or expired")
             )}
        end
      end
    end

    update :reset_password_with_token do
      description "Resets user password using a valid reset token"

      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end

    read :sign_in_with_magic_link do
      description "Sign in an existing user with a magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      # The shape `AshAuthentication` builds for a magic link that does not register: the token names
      # the account, and the account has to be there already.
      prepare AshAuthentication.Strategy.MagicLink.SignInPreparation

      metadata :token, :string do
        allow_nil? false
      end

      get? true
    end

    action :request_magic_link do
      description "Sends a magic link for passwordless authentication to the user's email"

      argument :email, :ci_string do
        allow_nil? false
      end

      run AshAuthentication.Strategy.MagicLink.Request
    end

    action :logout, :map do
      description "Logs out the current user by revoking their authentication token"

      argument :token, :string do
        allow_nil? false
        sensitive? true
        description "The JWT token to revoke"
      end

      run fn input, _context ->
        token = input.arguments.token

        try do
          MishkaCmsCore.Accounts.Token
          |> AshAuthentication.TokenResource.revoke(token)
        rescue
          _ -> :ok
        end

        {:ok, %{success: true, message: gettext("Logged out successfully")}}
      end
    end
  end

  # Authorization policies for user operations
  policies do
    # Registration is open to every caller.
    bypass action(:register_with_password) do
      authorize_if always()
    end

    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    bypass action(:sign_in_with_password) do
      authorize_if always()
    end

    bypass action(:request_password_reset_token) do
      authorize_if always()
    end

    bypass action(:reset_password_api) do
      authorize_if always()
    end

    # The action's own filter is filled with the actor the query was BUILT with; this one with the
    # actor it RUNS with, so the record is always the runner's own.
    bypass action(:read_current_user) do
      description "Users can read their own record for password change"
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:me) do
      access_type :strict
      forbid_unless actor_present()
      authorize_if always()
    end

    policy action(:change_password) do
      access_type :strict
      forbid_unless actor_present()
      authorize_if always()
    end

    bypass action(:logout) do
      description "Anyone can attempt logout - no authentication required"
      authorize_if always()
    end
  end

  changes do
    change MishkaCmsCore.Accounts.Changes.LogOutEverywhereOnPasswordChange,
      on: [:update],
      where: [changing(:hashed_password, touching?: true)]
  end

  # Multi-tenancy configuration using site_id attribute
  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      sensitive? true
    end

    attribute :confirmed_at, :utc_datetime_usec do
      public? true
    end
  end

  # WHAT AN ACCOUNT HOLDS ANSWERS ITS OWN SITE. A site user reads the site and the permissions of
  # its own site's accounts only; a master's account and another site's arrive without them, row by
  # row, whichever tenant the read names. A master, and a read with no actor, read every account's.
  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      description "The site this user belongs to (nil for global users with cross-site access)"
      public? true
      filter expr(is_nil(type(^actor(:site_id), :uuid)) or id == ^actor(:site_id))
    end
  end

  identities do
    identity :unique_email, [:email] do
      description "Ensures email addresses are unique across all users"
      nils_distinct? false
    end
  end
end
