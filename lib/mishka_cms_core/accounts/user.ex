# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
      MishkaCmsCore.Accounts.Notifiers.DisconnectLiveSockets
    ],
    extensions: [AshAuthentication, AshJsonApi.Resource, MishkaGervaz.Resource, AshRateLimiter]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1]
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @admin_fields [:email]

  # The account actions that take `permission_ids`: changing what an account holds through them takes
  # the permission area as well as the user area.
  @granting_actions [
    :tenant_create,
    :master_create,
    :tenant_update,
    :master_update,
    :master_form_update
  ]

  # What an account holds rather than what it is: withheld when the account is reached through
  # another resource by someone who is not an admin.
  @account_relationships [:site, :permissions, :permissions_join_assoc]

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

      # An authenticator app as a second step after the password, for an account that sets one up
      # — see `MishkaCmsCore.Accounts.SecondFactor`. Set up in two steps, so nothing is stored until
      # a code from the app matches; a code on its own signs nobody in.
      totp do
        identity_field :email
        issuer "MishkaCMS"
        confirm_setup_enabled? true
        brute_force_strategy :rate_limit
      end

      # One-time codes for signing in when the authenticator app is lost, made with a current code
      # from it — see `MishkaCmsCore.Accounts.SecondFactor`. Hashed with bcrypt, salted per code: a
      # code holds about 62 bits, under the 112 that NIST SP 800-63B lets a fast hash keep, so a
      # stolen table must not be cheap to guess against.
      recovery_code do
        recovery_code_resource MishkaCmsCore.Accounts.RecoveryCode
        hash_provider AshAuthentication.BcryptProvider
        brute_force_strategy :rate_limit
        generate_action_name :generate_recovery_codes
      end
    end
  end

  # Database configuration for user storage
  postgres do
    table "users"
    repo Application.compile_env!(:mishka_cms_core, :repo)
  end

  # WHICH FIELDS of an account reached through another resource a caller may read.
  # Every relationship into User reads through `:related` (see that action): a comment's author, a
  # post's blogger, an issue's reporter. Public pages and JSON:API includes and filters are built
  # from exactly those relationships. The record and its id stay reachable, so a page can still say
  # who wrote something; the account's own fields answer only its owner and admins. Ash replaces a
  # withheld field with `%Ash.ForbiddenField{}`, JSON:API leaves it out, and a caller's filter on it
  # — `?filter[author][email]=` — sees nothing, because Ash authorizes the field a filter names
  # through the relationship's read action.
  #
  # Every other read keeps the whole account: signing in, registering, resetting a password, `/me`,
  # the actor read back from a token and `Ash.load/3` on it all read the account for its own holder,
  # and the row policies already limit them to that holder, AshAuthentication and admins.
  field_policies do
    field_policy [:email, :confirmed_at, :site_id, :permission_values, :totp_enabled?],
                 action(:related) do
      description "An account reached through another resource shows its own fields to its owner and admins"

      authorize_if expr(id == ^actor(:id))

      # A holder of the user area on the request's surface, of the account's own site, or a master;
      # a site's holder sees no other site's accounts and no master's.
      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:user", "admin:api:user"]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    field_policy :* do
      authorize_if always()
    end
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "user"

    default_fields [:id, :email, :confirmed_at, :permission_values, :site_id, :site]
  end

  mishka_gervaz do
    table do
      identity do
        name :users
        route "/admin/dashboard/account/users"
        stream_name :users
      end

      source do
        actions do
          destroy {:table_destroy, :destroy}
        end

        preload do
          always [:site, :permission_values, :totp_enabled?]
        end
      end

      columns do
        column :user_info do
          static true
          requires [:id, :email]
          label fn -> dgettext("mishka_gervaz", "User") end
          position :first

          ui do
            width "minmax(230px,1.8fr)"
          end

          render fn record ->
            id = to_string(record.id)
            assigns = %{email: to_string(record.email), id: id}

            ~H"""
            <.cell_stacked
              variant={:title}
              icon="hero-user"
              primary={@email}
              secondary={dgettext("mishka_gervaz", "ID: %{id}", id: @id)}
              copy={
                %{
                  id: "user-id-copy-#{@id}",
                  value: @id,
                  label: dgettext("mishka_gervaz", "Copy user ID")
                }
              }
            />
            """
          end
        end

        column :user_confirmed do
          source :confirmed_at
          label fn -> dgettext("mishka_gervaz", "Confirmed") end
          format fn confirmed_at -> if confirmed_at, do: "confirmed", else: "pending" end

          ui do
            type :badge
            width "minmax(140px,0.7fr)"

            extra %{
              variant: :pill,
              colors: %{
                "confirmed" => "bg-[#e6f6ee] text-[#177a53]",
                "pending" => "bg-[#fdf3f1] text-[#c0473d]"
              },
              labels: %{
                "confirmed" => dgettext_noop("mishka_gervaz", "Confirmed"),
                "pending" => dgettext_noop("mishka_gervaz", "Pending")
              },
              dots: %{"confirmed" => "bg-[#1f9d6b]", "pending" => "bg-[#e5484d]"},
              default_color: "bg-[#f4f3ef] text-[#8a877f]"
            }
          end
        end

        column :user_two_step do
          source :totp_enabled?
          label fn -> dgettext("mishka_gervaz", "Two-step") end
          format fn enabled? -> if enabled? == true, do: "on", else: "off" end

          ui do
            type :badge
            width "minmax(120px,0.6fr)"

            extra %{
              variant: :pill,
              colors: %{
                "on" => "bg-[#e6f6ee] text-[#177a53]",
                "off" => "bg-[#f4f3ef] text-[#8a877f]"
              },
              labels: %{
                "on" => dgettext_noop("mishka_gervaz", "On"),
                "off" => dgettext_noop("mishka_gervaz", "Off")
              },
              dots: %{"on" => "bg-[#1f9d6b]", "off" => "bg-[#b5b2aa]"},
              default_color: "bg-[#f4f3ef] text-[#8a877f]"
            }
          end
        end

        column :site_info do
          static true
          requires [:site_id, :site]
          label fn -> dgettext("mishka_gervaz", "Site") end

          ui do
            width "minmax(150px,0.9fr)"
          end

          render fn record, state ->
            site_name =
              case record.site do
                %{name: name} -> name
                _unloaded -> nil
              end

            display =
              if is_nil(record.site_id),
                do: dgettext("mishka_gervaz", "Global"),
                else: site_name || dgettext("mishka_gervaz", "Unknown")

            assigns = %{site: (state.master_user? && display) || nil}

            ~H"""
            <.cell_stacked variant={:meta} icon="hero-server-stack" primary={@site} />
            """
          end
        end

        column :permission_values do
          label fn -> dgettext("mishka_gervaz", "Permissions") end
          sortable false

          ui do
            type :tags
            width "minmax(180px,1.5fr)"

            extra %{
              max_items: 3,
              badge_class:
                "inline-flex items-center rounded-[7px] bg-[#f4f3ef] px-2 py-[3px] " <>
                  "text-[10.5px] font-semibold text-[#6d6a63]",
              empty: "—"
            }
          end
        end
      end

      filters do
        filter :search, :text, fields: [:email]

        filter :site_id, :relation do
          mode :search_multi
          display_field :name
          search_field :name
          min_chars 1
          page_size 15
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sites...") end
          end
        end
      end

      row_actions do
        action :show do
          type :event
          event "show_user_modal"

          ui do
            label fn -> dgettext("mishka_gervaz", "View") end
            icon "hero-eye"
          end
        end

        action :edit do
          type :event
          event "edit_user_modal"

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        # For someone who lost their authenticator app — see `MishkaCmsCore.Accounts.SecondFactor`.
        # Opens the user's modal on the step that asks the admin's own current code.
        action :turn_off_two_step do
          type :event
          event "turn_off_two_step_modal"
          # Not on the actor's own row: its own is turned off on Preferences, with a current code.
          visible fn record, state ->
            record.totp_enabled? == true and record.id != Map.get(state.current_user || %{}, :id)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Turn off two-step") end
            icon "hero-shield-exclamation"
          end
        end

        action :confirm_account do
          type :update
          action :confirm_by_admin
          visible fn record, _state -> is_nil(record.confirmed_at) end

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Confirm this account's email address without the confirmation email?"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Confirm account") end
            icon "hero-check-badge"
          end
        end

        action :delete do
          type :destroy

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Are you sure you want to delete this user? This action cannot be undone."
            )
          end
        end
      end

      bulk_actions do
        action :delete,
          type: :destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Delete the selected users? This action cannot be undone."
            )
      end

      row do
        selectable true
      end

      realtime do
        prefix "user"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search, :page_size]
        prefix "users"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No users found"), icon: "hero-users"
    end

    form do
      identity do
        name :user_form
      end

      source do
        actions do
          create {:master_create, :tenant_create}
          update {:master_form_update, :tenant_update}
        end

        preload do
          always [:permissions]
        end
      end

      fields do
        field :site_id, :relation do
          restricted true
          show_on :create
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end

            description fn ->
              dgettext("mishka_gervaz", "Leave empty for global (master) user")
            end
          end
        end

        field :email do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Email") end
            placeholder fn -> dgettext("mishka_gervaz", "user@example.com") end
            autocomplete "new-email"
          end
        end

        field :password, :password do
          virtual true

          ui do
            label fn -> dgettext("mishka_gervaz", "Password") end
            placeholder fn -> dgettext("mishka_gervaz", "Minimum 8 characters") end
            autocomplete "new-password"
          end
        end

        field :password_confirmation, :password do
          virtual true

          ui do
            label fn -> dgettext("mishka_gervaz", "Confirm Password") end
            placeholder fn -> dgettext("mishka_gervaz", "Confirm password") end
            autocomplete "new-password"
          end
        end

        field :permission_ids, :relation do
          virtual true
          resource MishkaCmsCore.Accounts.Permission
          display_field :name
          search_field :name
          mode :search_multi

          derive_value fn record ->
            permissions = Map.get(record, :permissions) || []

            case permissions do
              %Ash.NotLoaded{} -> []
              perms when is_list(perms) -> Enum.map(perms, &to_string(&1.id))
              _ -> []
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Permissions") end

            description fn ->
              dgettext("mishka_gervaz", "Select permissions to assign to this user")
            end

            span 2
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :email]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :security do
          fields [:password, :password_confirmation]

          ui do
            label fn -> dgettext("mishka_gervaz", "Security") end
            columns 2
          end
        end

        group :access do
          fields [:permission_ids]

          ui do
            label fn -> dgettext("mishka_gervaz", "Access Control") end
            columns 1
          end
        end
      end

      # A CANCEL CLOSES THE MODAL. Gervaz sends `{:form_cancelled, resource}` to the page only when
      # this hook exists; without it Cancel emptied the form and left the modal open.
      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  # Signing in with a password, asking for a reset and asking for a sign-in link are each limited
  # per address and per account, and changing the password per account, before any password is
  # checked or mail is sent. The numbers in those actions are the defaults; the `security.*`
  # settings change them — see `MishkaCmsCore.Accounts.AuthRateLimit`.
  rate_limit do
    backend MishkaCmsCore.Accounts.AuthRateLimit

    action :verify_with_totp,
      limit: 5,
      per: :timer.minutes(5),
      key: &MishkaCmsCore.Accounts.AuthRateLimit.by_user/2

    action :confirm_setup_with_totp,
      limit: 5,
      per: :timer.minutes(5),
      key: &MishkaCmsCore.Accounts.AuthRateLimit.by_user/2

    action :verify_with_recovery_code,
      limit: 5,
      per: :timer.minutes(5),
      key: &MishkaCmsCore.Accounts.AuthRateLimit.by_user/2
  end

  actions do
    defaults [:read]

    read :read_current_user do
      description "Retrieves the current authenticated user's record"
      get? true
      filter expr(id == ^actor(:id))
    end

    # AN ACCOUNT AS ANOTHER RESOURCE REACHES IT: a comment's author, a post's blogger, a
    # notification's actor. Every relationship into User names this as its `read_action`, so a load,
    # an include and a filter through one all meet the same rules — the row answers whoever came
    # through the relationship (`ExtensionInteraction`, below), the account's own fields answer its
    # owner and admins (the field policies above), and what it holds answers admins only
    # (`withhold_account_relationships/2`). A relationship that reads through `:read` instead
    # reaches nothing unless an admin is asking.
    #
    # Such a relationship is also `sortable? false`: Ash checks no field policy on a sort through a
    # relationship, so `sort=author.email` would put the rows in the order of the addresses.
    read :related do
      description "An account reached through another resource: its id for everyone, the rest for its owner and admins"
      prepare fn query, context -> withhold_account_relationships(query, context) end
    end

    create :create do
      description "Creates a new user with email and hashed password"
      # before/reject seam (e.g. ban-list / captcha / domain allow-list before account creation)
      change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook
      accept [:email, :hashed_password]

      # With no tenant this makes a master, which only a master may do. Asked when the action runs,
      # so of the actor, tenant and authorization it runs with.
      validate MishkaCmsCore.Accounts.Validations.MasterUserCreation, before_action?: true
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject

      prepare fn query, _context ->
        query
        |> Ash.Query.load([:permissions, :permission_values])
      end
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

      # Counted before the current password is checked, right or wrong, so a stolen session cannot
      # guess it; both run as before_action hooks, in this order, and a refusal stops the check.
      change AshRateLimiter.BuiltinChanges.rate_limit(
               limit: 10,
               per: :timer.minutes(15),
               key: &MishkaCmsCore.Accounts.AuthRateLimit.by_user/2
             )

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

      argument :totp_code, :string do
        description "A current code from the account's authenticator app, when it has one."
        allow_nil? true
        sensitive? true
      end

      argument :recovery_code, :string do
        description "One of the account's recovery codes, in place of `totp_code`."
        allow_nil? true
        sensitive? true
      end

      argument :captcha_token, :string do
        description "The token the site's captcha gave the browser, when the site asks one. The JSON:API never asks — see `MishkaCmsCore.Accounts.CaptchaCheck`."
        allow_nil? true
        sensitive? true
      end

      prepare AshRateLimiter.BuiltinPreparations.rate_limit(
                limit: 30,
                per: :timer.minutes(5),
                key: &MishkaCmsCore.Accounts.AuthRateLimit.by_address/2
              )

      # BETWEEN THE TWO LIMITS — see `MishkaCmsCore.Accounts.CaptchaCheck`.
      prepare &MishkaCmsCore.Accounts.CaptchaCheck.prepare(&1, &2, :sign_in)

      prepare AshRateLimiter.BuiltinPreparations.rate_limit(
                limit: 10,
                per: :timer.minutes(15),
                key: &MishkaCmsCore.Accounts.AuthRateLimit.by_account/2
              )

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

      # Refused here, after the password, when sign-in is closed — see `AuthGate`.
      prepare &MishkaCmsCore.Accounts.AuthGate.prepare(&1, &2, [:sign_in])

      # And without a current code from an account's authenticator — see `SecondFactor`.
      prepare &MishkaCmsCore.Accounts.SecondFactor.prepare(&1, &2, :code)

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

      # The step every browser sign-in ends with — password, registration, reset — so a closed
      # sign-in is closed whichever way led here. See `AuthGate`.
      prepare &MishkaCmsCore.Accounts.AuthGate.prepare(&1, &2, [:sign_in])

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
        |> Ash.Query.load([:permissions, :permission_values, :site])
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

      argument :captcha_token, :string do
        description "The token the site's captcha gave the browser, when the site asks one. The JSON:API never asks — see `MishkaCmsCore.Accounts.CaptchaCheck`."
        allow_nil? true
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

      validate MishkaCmsCore.Accounts.Validations.MasterUserCreation, before_action?: true

      validate MishkaCmsCore.Accounts.Validations.ValidEmail

      # The address's limit, then the captcha — see `CaptchaCheck` — as hooks that run once every
      # field below is valid, so a typo spends no token, and before the transaction and the hooks
      # that look the email up and hash the password, so a refused form costs none of them. The
      # installer and the seeds register with `authorize?: false` and are held to neither.
      change AshRateLimiter.BuiltinChanges.rate_limit(
               limit: 10,
               per: :timer.hours(1),
               key: &MishkaCmsCore.Accounts.AuthRateLimit.by_address/2,
               on: :before_transaction
             ),
             where: [MishkaCmsCore.Accounts.Validations.FromVisitor]

      change &MishkaCmsCore.Accounts.CaptchaCheck.change(&1, &2, :register)

      change {MishkaCmsCore.Accounts.Changes.EnforceMasterEmailSeparation, []}
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

      argument :captcha_token, :string do
        description "The token the site's captcha gave the browser, when the site asks one. The JSON:API never asks — see `MishkaCmsCore.Accounts.CaptchaCheck`."
        allow_nil? true
        sensitive? true
      end

      prepare AshRateLimiter.BuiltinPreparations.rate_limit(
                limit: 10,
                per: :timer.hours(1),
                key: &MishkaCmsCore.Accounts.AuthRateLimit.by_address/2
              )

      # BETWEEN THE TWO LIMITS — see `MishkaCmsCore.Accounts.CaptchaCheck`.
      prepare &MishkaCmsCore.Accounts.CaptchaCheck.prepare(&1, &2, :reset_request)

      prepare AshRateLimiter.BuiltinPreparations.rate_limit(
                limit: 3,
                per: :timer.hours(1),
                key: &MishkaCmsCore.Accounts.AuthRateLimit.by_account/2
              )

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

    read :users do
      description "Read users based on tenant context"
      pagination offset?: true, default_limit: 100

      prepare fn query, context ->
        query = Ash.Query.load(query, :site)

        case context.actor do
          nil ->
            query

          %{site_id: nil} ->
            query

          %{site_id: site_id} ->
            Ash.Query.filter(query, site_id == ^site_id)
        end
      end
    end

    read :tenant_read do
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        tenant = context.tenant

        query
        |> Ash.Query.filter(site_id == ^tenant)
        |> Ash.Query.load([:site, :permissions, :permission_values])
      end

      description "Lists users for tenant (filtered to their site)"
    end

    read :tenant_get do
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        tenant = context.tenant

        query
        |> Ash.Query.filter(site_id == ^tenant)
        |> Ash.Query.load([:site, :permissions, :permission_values])
      end

      description "Gets a single user for tenant (filtered to their site)"
    end

    read :master_read do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        Ash.Query.load(query, [:site, :permissions, :permission_values])
      end

      description "Lists all users (master users only)"
    end

    read :master_get do
      get? true
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        Ash.Query.load(query, [:site, :permissions, :permission_values])
      end

      description "Gets a single user by ID (master users only)"
    end

    create :tenant_create do
      accept @admin_fields

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 8
      end

      argument :password_confirmation, :string do
        allow_nil? false
        sensitive? true
      end

      argument :permission_ids, {:array, :uuid}, allow_nil?: true, default: []

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      validate confirm(:password, :password_confirmation)
      validate MishkaCmsCore.Accounts.Validations.ValidEmail

      change fn changeset, context ->
        Ash.Changeset.change_attribute(changeset, :site_id, context.tenant)
      end

      change set_context(%{strategy_name: :password})
      change AshAuthentication.Strategy.Password.HashPasswordChange

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error
             )

      description "Creates a new user for the tenant's site"
    end

    create :master_create do
      accept @admin_fields ++ [:site_id]

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 8
      end

      argument :password_confirmation, :string do
        allow_nil? false
        sensitive? true
      end

      argument :permission_ids, {:array, :uuid}, allow_nil?: true, default: []

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      validate confirm(:password, :password_confirmation)
      validate MishkaCmsCore.Accounts.Validations.ValidEmail

      change set_context(%{strategy_name: :password})
      change AshAuthentication.Strategy.Password.HashPasswordChange

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error
             )

      description "Creates a new user (master users only, can specify site_id)"
    end

    update :tenant_update do
      accept @admin_fields
      require_atomic? false

      argument :password, :string do
        allow_nil? true
        sensitive? true
        constraints min_length: 8
      end

      argument :password_confirmation, :string do
        allow_nil? true
        sensitive? true
      end

      argument :permission_ids, {:array, :uuid}, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      validate MishkaCmsCore.Accounts.Validations.ValidEmail

      # Validate password confirmation if password is provided
      validate fn changeset, _context ->
        password = Ash.Changeset.get_argument(changeset, :password)
        password_confirmation = Ash.Changeset.get_argument(changeset, :password_confirmation)

        cond do
          is_nil(password) or password == "" ->
            :ok

          password != password_confirmation ->
            {:error,
             field: :password_confirmation,
             message: dgettext_noop("errors", "does not match password")}

          true ->
            :ok
        end
      end

      # Ensure tenant can only update users in their site
      validate fn changeset, context ->
        user = changeset.data
        tenant = context.tenant

        if user.site_id == tenant do
          :ok
        else
          {:error,
           field: :id, message: dgettext_noop("errors", "Cannot update users from other sites.")}
        end
      end

      # Hash password if provided
      change fn changeset, _context ->
        password = Ash.Changeset.get_argument(changeset, :password)

        if password && password != "" do
          hashed = Bcrypt.hash_pwd_salt(password)
          Ash.Changeset.force_change_attribute(changeset, :hashed_password, hashed)
        else
          changeset
        end
      end

      # Manage permissions if provided
      change fn changeset, _context ->
        permission_ids = Ash.Changeset.get_argument(changeset, :permission_ids)

        if permission_ids do
          Ash.Changeset.manage_relationship(changeset, :permissions, permission_ids,
            type: :append_and_remove,
            on_no_match: :error
          )
        else
          changeset
        end
      end

      description "Updates a user in the tenant's site (including password reset)"
    end

    action :master_update, :struct do
      description "Updates any user (master users only, including password reset) - requires nil tenant context"
      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false
      argument :email, :ci_string, allow_nil?: true
      argument :site_id, :uuid, allow_nil?: true
      argument :permission_ids, {:array, :uuid}, allow_nil?: true

      argument :password, :string do
        allow_nil? true
        sensitive? true
        constraints min_length: 8
      end

      argument :password_confirmation, :string do
        allow_nil? true
        sensitive? true
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      run fn input, _context ->
        user_id = input.arguments.id
        email = input.arguments[:email]
        password = input.arguments[:password]
        password_confirmation = input.arguments[:password_confirmation]
        permission_ids = input.arguments[:permission_ids]

        # Validate password confirmation if password is provided
        cond do
          password && password != "" && password != password_confirmation ->
            {:error,
             Ash.Error.Changes.InvalidArgument.exception(
               field: :password_confirmation,
               message: dgettext_noop("errors", "does not match password")
             )}

          true ->
            # Fetch user with multitenancy bypass
            case Ash.get(__MODULE__, user_id, action: :master_get, authorize?: false) do
              {:ok, user} ->
                attrs =
                  %{}
                  |> then(fn a -> if email, do: Map.put(a, :email, email), else: a end)

                user
                |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
                |> then(fn cs ->
                  # Allow changing site_id (moving user between sites)
                  case Map.fetch(input.arguments, :site_id) do
                    {:ok, site_id} -> Ash.Changeset.force_change_attribute(cs, :site_id, site_id)
                    :error -> cs
                  end
                end)
                |> then(fn cs ->
                  # Hash and set password if provided
                  if password && password != "" do
                    hashed = Bcrypt.hash_pwd_salt(password)
                    Ash.Changeset.force_change_attribute(cs, :hashed_password, hashed)
                  else
                    cs
                  end
                end)
                |> then(fn cs ->
                  # Manage permissions if provided
                  if permission_ids do
                    Ash.Changeset.manage_relationship(cs, :permissions, permission_ids,
                      type: :append_and_remove,
                      on_no_match: :error
                    )
                  else
                    cs
                  end
                end)
                |> Ash.update()

              {:error, _} = error ->
                error
            end
        end
      end
    end

    destroy :tenant_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Ensure tenant can only delete users in their site and not themselves
      validate fn changeset, context ->
        user = changeset.data
        tenant = context.tenant
        actor = context.actor

        cond do
          user.site_id != tenant ->
            {:error,
             field: :id, message: dgettext_noop("errors", "Cannot delete users from other sites.")}

          actor && user.id == actor.id ->
            {:error, field: :id, message: dgettext_noop("errors", "Cannot delete yourself.")}

          true ->
            :ok
        end
      end

      # Clear permissions before delete (to avoid FK constraint)
      change fn changeset, _context ->
        Ash.Changeset.manage_relationship(changeset, :permissions, [], type: :append_and_remove)
      end

      description "Deletes a user from the tenant's site (cannot delete self)"
    end

    action :master_destroy, :struct do
      description "Deletes any user (master users only, cannot delete self) - requires nil tenant context"
      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        user_id = input.arguments.id
        actor = context.actor

        # Master user cannot delete themselves
        if actor && user_id == actor.id do
          {:error,
           Ash.Error.Changes.InvalidArgument.exception(
             field: :id,
             message: dgettext_noop("errors", "Cannot delete yourself.")
           )}
        else
          # Fetch user with multitenancy bypass
          case Ash.get(__MODULE__, user_id, action: :master_get, authorize?: false) do
            {:ok, user} ->
              # One transaction: the grants go with the account through their `on_delete: :delete`,
              # so a delete that is refused leaves the account as it was, permissions included.
              case Ash.destroy(user, authorize?: false) do
                :ok -> {:ok, user}
                {:error, _} = error -> error
              end

            {:error, _} = error ->
              error
          end
        end
      end
    end

    # Need a simple update action for master_update to use
    update :update do
      accept @admin_fields
      require_atomic? false

      # `master_update` sets the site after building this changeset, so this is asked when it runs.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                moves: true, label: dgettext_noop("errors", "account")},
               before_action?: true
    end

    update :master_form_update do
      accept @admin_fields ++ [:site_id]
      require_atomic? false
      multitenancy :bypass

      argument :password, :string do
        allow_nil? true
        sensitive? true
        constraints min_length: 8
      end

      argument :password_confirmation, :string do
        allow_nil? true
        sensitive? true
      end

      argument :permission_ids, {:array, :uuid}, allow_nil?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      # An account other records name moves only where they can still name it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                moves: true, label: dgettext_noop("errors", "account")}

      validate MishkaCmsCore.Accounts.Validations.ValidEmail

      validate fn changeset, _context ->
        password = Ash.Changeset.get_argument(changeset, :password)
        password_confirmation = Ash.Changeset.get_argument(changeset, :password_confirmation)

        cond do
          is_nil(password) or password == "" ->
            :ok

          password != password_confirmation ->
            {:error,
             field: :password_confirmation,
             message: dgettext_noop("errors", "does not match password")}

          true ->
            :ok
        end
      end

      change fn changeset, _context ->
        password = Ash.Changeset.get_argument(changeset, :password)

        if password && password != "" do
          hashed = Bcrypt.hash_pwd_salt(password)
          Ash.Changeset.force_change_attribute(changeset, :hashed_password, hashed)
        else
          changeset
        end
      end

      change fn changeset, _context ->
        permission_ids = Ash.Changeset.get_argument(changeset, :permission_ids)

        if permission_ids do
          Ash.Changeset.manage_relationship(changeset, :permissions, permission_ids,
            type: :append_and_remove,
            on_no_match: :error
          )
        else
          changeset
        end
      end

      description "Updates a user via MishkaGervaz form (master users only)"
    end

    # Simple destroy for internal use by master_destroy generic action
    destroy :destroy do
      primary? true
      require_atomic? false
    end

    destroy :table_destroy do
      require_atomic? false

      validate fn changeset, context ->
        user = changeset.data
        actor = context.actor

        if actor && user.id == actor.id do
          {:error, field: :id, message: dgettext_noop("errors", "Cannot delete yourself.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.manage_relationship(changeset, :permissions, [], type: :append_and_remove)
      end

      description "Deletes a user via MishkaGervaz table (handles permission cleanup)"
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
               ),
             # The reset below runs without its policies, so the gate is asked here — see `AuthGate`.
             :ok <- MishkaCmsCore.Accounts.AuthGate.check([:reset], tenant, %{user: user}) do
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

    # TWO-FACTOR, beside the `totp` strategy's own `setup_with_totp` and `verify_with_totp` — see
    # `MishkaCmsCore.Accounts.SecondFactor`. The confirmation is the strategy's own change, with the
    # confirming code spent as a sign-in's is, so it cannot sign anybody in within its 30 seconds.
    update :confirm_setup_with_totp do
      description "Confirm TOTP setup by verifying a code and activating the secret."
      accept []
      require_atomic? false
      touches_resources [MishkaCmsCore.Accounts.Token]

      argument :setup_token, :string do
        description "The setup token from the setup action."
        allow_nil? false
        sensitive? true
      end

      argument :code, :string do
        description "A current code from the authenticator app."
        allow_nil? false
        sensitive? true
      end

      change AshAuthentication.Strategy.Totp.ConfirmSetupChange
      change set_attribute(:last_totp_at, &DateTime.utc_now/0)
      change {MishkaCmsCore.Accounts.Changes.AnnounceSecondFactor, event: :enabled}
    end

    update :disable_totp do
      description "Turns off one's own authenticator, with a current code from it."
      accept []
      require_atomic? false

      argument :code, :string do
        allow_nil? false
        sensitive? true
      end

      change MishkaCmsCore.Accounts.Changes.RequireCurrentCode

      # Written whatever the record in hand says — a page's copy of the account can be older than
      # the authenticator it turns off.
      change atomic_update(:totp_secret, expr(nil))
      change atomic_update(:last_totp_at, expr(nil))
      change after_action(&MishkaCmsCore.Accounts.SecondFactor.cleared_recovery_codes/3)

      change {MishkaCmsCore.Accounts.Changes.AnnounceSecondFactor, event: :disabled}
    end

    update :turn_off_totp do
      description "Turns off an account's authenticator for someone who lost the app, with a current code from the admin's own."
      accept []
      require_atomic? false

      argument :code, :string do
        description "A current code from the authenticator app of the admin running this."
        allow_nil? false
        sensitive? true
      end

      change {MishkaCmsCore.Accounts.Changes.RequireCurrentCode, of: :actor}

      # Written whatever the record in hand says, so a row read before the app was set up still
      # turns it off.
      change atomic_update(:totp_secret, expr(nil))
      change atomic_update(:last_totp_at, expr(nil))
      change after_action(&MishkaCmsCore.Accounts.SecondFactor.cleared_recovery_codes/3)
      change {MishkaCmsCore.Accounts.Changes.AnnounceSecondFactor, event: :disabled}
      # So the Users table's row, redrawn from what this returns, says it is off.
      change load(:totp_enabled?)
    end

    # Written by `SecondFactor` alone, with the time a code was accepted, so it is not accepted again.
    update :record_totp_use do
      accept []
    end

    # The `recovery_code` strategy's own action, written here to ask a current code from the app
    # first: ten new codes replace any made before, hashed as they are stored, and handed back once
    # in the `:recovery_codes` metadata.
    update :generate_recovery_codes do
      description "Makes the account's recovery codes, with a current code from its authenticator."
      accept []
      require_atomic? false

      argument :code, :string do
        allow_nil? false
        sensitive? true
      end

      argument :recovery_codes, {:array, :string} do
        allow_nil? false
        public? false
        sensitive? true
        default {MishkaCmsCore.Accounts.SecondFactor, :fresh_recovery_codes, []}
      end

      change MishkaCmsCore.Accounts.Changes.RequireCurrentCode

      change {Ash.Resource.Change.CascadeDestroy,
              relationship: :recovery_codes, after_action?: false}

      change {AshAuthentication.Strategy.RecoveryCode.HashRecoveryCodesChange,
              hash_provider: AshAuthentication.BcryptProvider}

      change manage_relationship(:recovery_codes, :recovery_codes,
               type: :create,
               value_is_key: :code
             )

      change {MishkaCmsCore.Accounts.Changes.AnnounceSecondFactor, event: :recovery_codes}

      metadata :recovery_codes, {:array, :string} do
        allow_nil? false
      end
    end

    # For someone whose confirmation mail never came: the admin vouches for the address. Tells
    # plugins `"auth:account:confirmed"` with `%{user_id:, site_id:, by:}`, `by` the admin's id.
    update :confirm_by_admin do
      description "Confirms an account without its confirmation mail."
      accept []
      require_atomic? false

      validate absent(:confirmed_at),
        message: dgettext_noop("errors", "is already confirmed")

      change set_attribute(:confirmed_at, &DateTime.utc_now/0)

      change after_action(fn _changeset, user, context ->
               MishkaInstaller.Event.Hook.call(
                 "auth:account:confirmed",
                 %{
                   user_id: user.id,
                   site_id: user.site_id,
                   by: context.actor && context.actor.id
                 },
                 return: false
               )

               {:ok, user}
             end)
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

      # A sign-in, so closed with sign-in as well as with sign-in links — see `AuthGate`.
      prepare &MishkaCmsCore.Accounts.AuthGate.prepare(&1, &2, [:sign_in, :magic_link])

      # A link proves the mailbox, not the authenticator — see `SecondFactor`.
      prepare &MishkaCmsCore.Accounts.SecondFactor.prepare(&1, &2, :refuse)

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

      argument :captcha_token, :string do
        description "The token the site's captcha gave the browser, when the site asks one. The JSON:API never asks — see `MishkaCmsCore.Accounts.CaptchaCheck`."
        allow_nil? true
        sensitive? true
      end

      prepare AshRateLimiter.BuiltinPreparations.rate_limit(
                limit: 10,
                per: :timer.hours(1),
                key: &MishkaCmsCore.Accounts.AuthRateLimit.by_address/2
              )

      # BETWEEN THE TWO LIMITS — see `MishkaCmsCore.Accounts.CaptchaCheck`.
      prepare &MishkaCmsCore.Accounts.CaptchaCheck.prepare(&1, &2, :magic_link)

      prepare AshRateLimiter.BuiltinPreparations.rate_limit(
                limit: 3,
                per: :timer.hours(1),
                key: &MishkaCmsCore.Accounts.AuthRateLimit.by_account/2
              )

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

        # WHOSE LIVE SOCKETS GO WITH THE TOKEN, asked before the revocation below makes the answer
        # unreadable. The account is the one the TOKEN names and nobody else: the policy above lets
        # anyone call this with any string, and the router's `:api` pipeline puts an actor on every
        # request from its own bearer token — so a caller handing over somebody else's token would
        # otherwise revoke that account's token while cutting its own sockets.
        signed_out = token_holder(token)

        try do
          MishkaCmsCore.Accounts.Token
          |> AshAuthentication.TokenResource.revoke(token)
        rescue
          _ -> :ok
        end

        case signed_out do
          {:ok, user_id} -> MishkaCmsCore.Accounts.LiveSockets.disconnect(user_id)
          :error -> :ok
        end

        {:ok, %{success: true, message: gettext("Logged out successfully")}}
      end
    end

    update :assign_permissions do
      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      description "Replaces user's permissions with the provided list of permission IDs"
      accept []
      require_atomic? false

      argument :permission_ids, {:array, :uuid} do
        allow_nil? false
        description "List of permission IDs to assign to the user"
      end

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :create,
               on_match: :ignore
             )
    end

    update :add_permission do
      validate {MishkaCmsCore.Accounts.Validations.GrantWithinActorScope, []},
        before_action?: true

      description "Adds a single permission to the user's existing permissions"
      accept []
      require_atomic? false

      argument :permission_id, :uuid do
        allow_nil? false
      end

      change manage_relationship(:permission_id, :permissions, type: :append, on_no_match: :error)
    end

    update :remove_permission do
      description "Removes a single permission from the user's permissions"
      accept []
      require_atomic? false

      argument :permission_id, :uuid do
        allow_nil? false
      end

      change manage_relationship(:permission_id, :permissions, type: :remove)
    end
  end

  # Authorization policies for user operations
  policies do
    # BEFORE the AshAuthentication bypass, which authorizes every action that library runs — a
    # `policy` that fails forbids immediately, and a bypass that follows never gets the chance to
    # wave it through. Registration is the one part of the auth surface a site that is offline does
    # not want; signing in is how its admin gets back to turn it on.
    policy action(:register_with_password) do
      description "A site that is offline takes no new accounts"

      # Without this a refusal reaches the sign-up form as a bare "forbidden" — Ash withholds the
      # reason by default, and "forbidden" on a page that was working yesterday reads as a fault.
      error_message dgettext_noop(
                      "errors",
                      "This site is offline and is not taking new accounts. Sign in if you have one."
                    )

      forbid_unless {MishkaCmsCore.Accounts.Checks.RegistrationOpen, []}
      authorize_if always()
    end

    # THE WAYS IN A SITE CAN CLOSE (`MishkaCmsCore.Accounts.AuthGate`), here for the same reason:
    # before the bypass. The error is the gate's own, so the sign-up and reset forms, the JSON:API
    # and the browser routes say which way is closed. Signing in is asked after the password, in its
    # read actions.
    policy action(:register_with_password) do
      description "A site that closed registration takes no new accounts but the addresses it allows"
      error_message &MishkaCmsCore.Accounts.AuthGate.refused(&1, &2, :register)
      forbid_unless {MishkaCmsCore.Accounts.Checks.AuthGateOpen, action: :register}
      authorize_if always()
    end

    policy action(:reset_password_with_token) do
      description "A site that closed password reset resets only the accounts it allows"
      error_message &MishkaCmsCore.Accounts.AuthGate.refused(&1, &2, :reset)
      forbid_unless {MishkaCmsCore.Accounts.Checks.AuthGateOpen, action: :reset}
      authorize_if always()
    end

    # ONE'S OWN AUTHENTICATOR is set up, confirmed and turned off by the account itself and nobody
    # else: an admin who set one up for an account could sign in as it. One already set up is turned
    # off before another is. The code check and its record are the sign-in's own, never asked for.
    policy action([
             :setup_with_totp,
             :confirm_setup_with_totp,
             :disable_totp,
             :generate_recovery_codes
           ]) do
      description "Only the account itself sets up or turns off its authenticator, or makes its recovery codes"
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:setup_with_totp) do
      description "An authenticator already set up is turned off before another is set up"
      forbid_unless expr(is_nil(totp_secret))
      authorize_if always()
    end

    policy action(:generate_recovery_codes) do
      description "Recovery codes come with an authenticator"
      forbid_if expr(is_nil(totp_secret))
      authorize_if always()
    end

    policy action([:verify_with_totp, :verify_with_recovery_code, :record_totp_use]) do
      description "Run by the sign-in itself"
      forbid_if always()
    end

    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # A MASTER'S ACTIONS ARE A MASTER'S WITH THE USER AREA: a user whose `site_id` is nil, holding
    # `admin:<surface>:user`. Asked here of the actor the action RUNS with; `TenantContext` on each
    # of these asks it of the actor the input was BUILT with, which need not be the same one. BEFORE
    # the bypasses below: a failing `policy` forbids, and no later bypass gets to wave it through.
    #
    # AN ACCOUNT HOLDING MORE THAN ITS ACTOR keeps its email, password and site, and is not deleted,
    # here and in the two gates below that let an account be written: whoever set them on an account
    # holding `*` could sign in as it (`MishkaCmsCore.Accounts.Checks.WithinCeiling`).
    policy action([
             :master_read,
             :master_get,
             :master_create,
             :master_update,
             :master_destroy,
             :master_form_update,
             :table_destroy
           ]) do
      description "Only a master holding the user area: a user with no site"

      forbid_unless actor_attribute_equals(:site_id, nil)
      forbid_unless MishkaCmsCore.Accounts.Checks.WithinCeiling

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:user", "admin:api:user"]}
    end

    # Granting permissions is the one admin action that can escalate the grantor, so it is scoped
    # BEFORE the bypasses below. Only a holder of the permission area changes permissions, removing
    # included. A MASTER (site_id nil) may assign to any user; a site's holder only to users of its
    # own site.
    policy action([:assign_permissions, :add_permission, :remove_permission]) do
      description "Holders of the permission area: a master anywhere, a site's holder its own site"

      # A site's holder promotes colleagues, never itself — otherwise the ceiling that
      # `GrantWithinActorScope` puts on WHAT may be granted is trivially raised: grant a colleague
      # your own level, have them grant you more. A master is held to its ceiling alone.
      forbid_if expr(id == ^actor(:id) and not is_nil(^actor(:site_id)))

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:permission", "admin:api:permission"]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    # `:tenant_update` hands out permissions too, so it carries the same two rules: a site's holder
    # never changes its own permissions, and changes only accounts of its own site.
    policy action(:tenant_update) do
      description "A site's holder of the user area edits only its own site's accounts, and never its own permissions"

      forbid_if expr(
                  id == ^actor(:id) and not is_nil(^actor(:site_id)) and
                    not is_nil(^arg(:permission_ids))
                )

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:user", "admin:api:user"]}

      forbid_unless MishkaCmsCore.Accounts.Checks.WithinCeiling

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    # Turning off another account's authenticator weakens how it signs in, so it takes the user area
    # within the actor's own site and ceiling, as `:tenant_update` does. Never the actor's own: that
    # is `:disable_totp`, which asks a current code.
    policy action(:turn_off_totp) do
      description "A holder of the user area turns off authenticators of its own site's other accounts"

      forbid_if expr(id == ^actor(:id))

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:user", "admin:api:user"]}

      forbid_unless MishkaCmsCore.Accounts.Checks.WithinCeiling

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    # Confirming vouches for an account's email address, so it takes the user area, within the
    # actor's own site. It gives the actor no way in as the account, so no ceiling is asked.
    policy action(:confirm_by_admin) do
      description "A holder of the user area confirms its own site's accounts"

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:user", "admin:api:user"]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    # AN ACCOUNT ACTION THAT CHANGES WHAT THE ACCOUNT HOLDS is a grant, so it takes the permission
    # area as well as the user area the action itself asks for. Sending an account's permissions
    # back unchanged, as the account form does, is no grant. The user area is asked here too: for
    # `:tenant_create` only the bypass below asks it, and a policy that passes on its own authorizes.
    policy [action(@granting_actions), MishkaCmsCore.Accounts.Checks.ChangesPermissions] do
      description "Changing an account's permissions takes the permission area"

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:permission", "admin:api:permission"]}

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:user", "admin:api:user"]}

      authorize_if always()
    end

    # HOLDERS OF THE USER AREA. A master holding it reaches every account. A site's holder reaches
    # the accounts of its own site and no other — with or without a tenant, because `global? true`
    # leaves a call that names no tenant unscoped. One bypass that always applies, so a read it does
    # not let through comes back empty rather than as an error, as it always has.
    bypass always() do
      description "A master with the user area reaches every account; a site's holder its own site's accounts"

      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: ["admin:dashboard:user", "admin:api:user"]}

      forbid_unless MishkaCmsCore.Accounts.Checks.WithinCeiling

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    # An account reached through another resource's relationship — see `:related`. Only through
    # that action: a relationship reading the account through any other gets nothing past this, so
    # one that forgets its `read_action` reaches no account rather than a whole one.
    bypass action(:related) do
      authorize_if MishkaCmsCore.Accounts.Checks.ExtensionInteraction
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

    policy action(:users) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:user", "admin:api:user"]}
    end

    # The list's own prepare scopes it by the actor the query was BUILT with. Scoped here too, by
    # the actor it RUNS with: a master admin lists every account, a site's admin its own site's.
    policy action(:users) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  # Real-time updates via PubSub
  # Using [nil, :site_id] pattern to publish to both global and site-specific topics:
  # - nil site_id → "user:created" only (master users)
  # - uuid site_id → "user:created" AND "user:{uuid}:created" (both master and tenant)
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "user"

    publish :tenant_create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :tenant_update, [[nil, :site_id], "updated"]
    publish :update, [[nil, :site_id], "updated"]
    publish :master_form_update, [[nil, :site_id], "updated"]
    publish :turn_off_totp, [[nil, :site_id], "updated"]
    publish :confirm_by_admin, [[nil, :site_id], "updated"]
    publish :tenant_destroy, [[nil, :site_id], "destroyed"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :table_destroy, [[nil, :site_id], "destroyed"]
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

    # TWO-FACTOR (`MishkaCmsCore.Accounts.SecondFactor`): the authenticator's secret, and when a code
    # from it was last accepted. The names and types AshAuthentication's `totp` strategy asks for.
    attribute :totp_secret, :binary do
      allow_nil? true
      sensitive? true
      public? false
    end

    attribute :last_totp_at, :datetime do
      allow_nil? true
      sensitive? true
      public? false
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

    has_many :permissions_join_assoc, MishkaCmsCore.Accounts.UserPermission do
      description "This user's permission grants, the rows behind `permissions`"
      destination_attribute :user_id
      filter expr(is_nil(type(^actor(:site_id), :uuid)) or user.site_id == ^actor(:site_id))
    end

    has_many :recovery_codes, MishkaCmsCore.Accounts.RecoveryCode do
      description "The account's one-time recovery codes, as hashes"
    end

    many_to_many :permissions, MishkaCmsCore.Accounts.Permission do
      description "Permissions granted to this user for access control"
      through MishkaCmsCore.Accounts.UserPermission
      join_relationship :permissions_join_assoc
      source_attribute_on_join_resource :user_id
      destination_attribute_on_join_resource :permission_id
      public? true
    end
  end

  calculations do
    calculate :permission_values, {:array, :string} do
      description "Returns list of permission names assigned to the user"
      public? true

      calculation fn records, _context ->
        Enum.map(records, fn record ->
          record.permissions |> List.wrap() |> Enum.map(& &1.name)
        end)
      end

      load permissions: [:name]
    end

    calculate :totp_enabled?, :boolean, expr(not is_nil(totp_secret)) do
      description "Whether the account signs in with a code from its authenticator after its password"
      public? true
    end
  end

  identities do
    identity :unique_email, [:email] do
      description "Ensures email addresses are unique across all users"
      nils_distinct? false
    end
  end

  # An account reached through another resource — a comment's author, a post's blogger, a team
  # member — arrives with no site and no permissions unless an admin is asking, and a site's admin
  # gets them for its own site's accounts only (the filters on those relationships). The field
  # policies cover the account's own fields; they do not reach relationships, and JSON:API renders
  # `fields[user]=site,permissions` for any included user.
  #
  # The loads cannot be taken out here — Ash puts the caller's loads back after preparing — so the
  # read is marked instead, and the resources the account holds refuse loads under the mark (see
  # `MishkaCmsCore.Accounts.Checks.AccountWithheld`). `"auth:account:withheld"` receives the marked
  # query, and whatever `Ash.Query` it returns is the one that runs.
  defp withhold_account_relationships(query, %{authorize?: authorize?} = context)
       when authorize? != false do
    withheld = Enum.filter(@account_relationships, &Keyword.has_key?(query.load, &1))

    if withheld == [] or
         MishkaCmsCore.Accounts.Checks.AccessPermissions.match?(context.actor, query,
           permissions: ["admin:dashboard:user", "admin:api:user"]
         ) do
      query
    else
      marked = MishkaCmsCore.Accounts.Checks.AccountWithheld.mark(query)
      meta = %{actor: context.actor, site_id: query.tenant, withheld: withheld}

      case MishkaInstaller.Event.Hook.call("auth:account:withheld", marked, meta: meta) do
        %Ash.Query{} = adjusted -> adjusted
        _ -> marked
      end
    end
  end

  defp withhold_account_relationships(query, _context), do: query

  # The account a `:logout` is ending, or `:error` when the token proves none.
  # `AshAuthentication.Jwt.verify/3` is the whole test — signature, expiry, and a `jti` still present
  # and unrevoked in the token resource — so a token somebody once had, or one this application never
  # signed, cannot cut an account's sockets.
  #
  # THE TENANT COMES OUT OF THE TOKEN, NOT OUT OF THE REQUEST. A tenant user's token carries the site
  # it was issued for as a claim, and verification only checks that claim against the tenant it is
  # given — so reading it back first makes the check an identity and costs nothing, while the
  # signature is what makes the value trustworthy. Taking it from the request instead meant that
  # `POST /logout` without a tenant — which `MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug` allows
  # deliberately, for `x-no-tenant` on the master site's address — revoked the token and left its
  # live sockets running.
  defp token_holder(token) do
    with {:ok, claims} <- AshAuthentication.Jwt.peek(token),
         {:ok, %{"sub" => "user?id=" <> user_id}, _resource} <-
           AshAuthentication.Jwt.verify(token, __MODULE__, tenant: claims["tenant"]) do
      {:ok, user_id}
    else
      _no_live_token -> :error
    end
  end
end
