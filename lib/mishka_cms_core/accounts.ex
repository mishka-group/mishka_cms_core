defmodule MishkaCmsCore.Accounts do
  @moduledoc """
  MishkaCms Accounts Domain - Complete user authentication and authorization system.

  This Ash domain provides comprehensive user management capabilities including
  authentication, authorization, permission management, and secure token handling
  for the MishkaCms platform. Built with security-first principles and modern
  authentication patterns.

  ## Domain Architecture

  Organizes user and security resources into a cohesive system:
  - **User Management**: User registration, authentication, and profile management
  - **Permission System**: Role-based access control with granular permissions
  - **Token Management**: Secure token generation and validation
  - **Password Security**: Secure password handling with reset capabilities
  - **API Integration**: RESTful endpoints for authentication workflows

  ## Resource Organization

  ```
  MishkaCmsCore.Accounts/
  ├── User - Core user accounts with authentication
  ├── Token - Secure token management for sessions/API access
  ├── Permission - System permissions and capabilities
  └── UserPermission - User-permission relationship mapping
  ```

  ## Key Features

  - **Password Authentication**: Secure password-based user authentication
  - **Token-based API Access**: JWT or similar token system for API authentication
  - **Permission Management**: Granular permission assignment and validation
  - **Password Reset**: Secure password reset via email tokens
  - **User Registration**: Streamlined user onboarding process
  - **Profile Management**: User profile updates and management
  - **Admin Controls**: Administrative user and permission management

  ### Permission Management

  An admin permission is `admin:<surface>:<area>`, a plain string written where it is used.
  Accounts are managed with the user area, and what they hold with the permission area:

  ```elixir
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  # Grant an account what the granter holds (`admin:<surface>:permission`, within its ceiling)
  user
  |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: ids}, actor: granter)
  |> Ash.update()

  # Ask what a user holds
  AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:runtime:page"])
  ```

  ## Security Features

  ### Password Security
  - Secure password hashing (likely Argon2 or bcrypt)
  - Password strength validation
  - Secure password reset workflow
  - Protection against timing attacks

  ### Token Security
  - Secure token generation and validation
  - Token expiration and refresh capabilities
  - API endpoint protection via token authentication
  - Automatic token metadata in authentication responses

  ### Permission System
  - Granular permission assignment
  - Role-based access control (RBAC)
  - Permission validation middleware
  - Administrative permission management

  ## Error Handling

  The domain includes comprehensive error handling:
  - Authentication failures with proper HTTP status codes
  - Invalid token handling
  - Permission denied responses
  - User not found scenarios
  - Password reset token validation

  ## Multi-tenant Considerations

  - Users can have different permissions per site/tenant
  - Token validation respects tenant boundaries
  - Permission checks include tenant context
  - Administrative operations scoped to appropriate tenants

  ## Production Considerations

  - Monitor authentication attempt rates and patterns
  - Implement proper session timeout policies
  - Regular audit of user permissions and access
  - Secure token storage and transmission
  - Password policy enforcement
  - Account lockout policies for security
  - Regular cleanup of expired tokens
  - Comprehensive audit logging of authentication events
  """
  use Ash.Domain,
    otp_app: :mishka_cms_core,
    validate_config_inclusion?: false,
    extensions: [AshJsonApi.Domain, MishkaGervaz.Domain]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  json_api do
    log_errors? true

    routes do
      base_route "/v1/auth/admin", MishkaCmsCore.Accounts.User do
        index :users, route: "/users"
        patch :assign_permissions, route: "/:id/permissions"
        patch :add_permission, route: "/:id/permissions/add"
        patch :remove_permission, route: "/:id/permissions/remove"
      end

      base_route "/v1/tenant/admin/permissions", MishkaCmsCore.Accounts.Permission do
        index :tenant_read
        get :tenant_get
      end

      base_route "/v1/master/admin/permissions", MishkaCmsCore.Accounts.Permission do
        index :master_read
        get :master_get
        post :create
        patch :update, read_action: :master_get
        delete :destroy
      end

      base_route "/v1/auth/user", MishkaCmsCore.Accounts.User do
        post :sign_in_with_password do
          route "/sign-in"

          metadata fn _subject, user, _request ->
            %{token: user.__metadata__.token}
          end
        end

        route :post, "/reset-request", :request_password_reset_token

        get :me, route: "/me"

        post :register_with_password do
          route "/register"

          metadata fn _subject, user, _request ->
            %{token: user.__metadata__.token}
          end
        end

        get :read

        patch :change_password, route: "/change-password", read_action: :read_current_user

        post :reset_password_api do
          route "/reset-password"

          metadata fn _subject, user, _request ->
            %{token: user.__metadata__.token}
          end
        end

        route :post, "/logout", :logout
      end
    end
  end

  mishka_gervaz do
    table do
      actor_key :current_user

      pagination do
        type :numbered
        page_size 20
        page_size_options [20, 50, 100, 150]
      end

      realtime do
        pubsub MishkaCmsCore.PubSub
      end

      actions do
        read {:master_read, :read}
        get {:master_get, :read}
        destroy {:master_destroy, :destroy}
      end

      archive do
        read_action {:master_archived, :archived}
        get_action {:master_get_archived, :get_archived}
        restore_action {:master_unarchive, :unarchive}
        destroy_action {:master_permanent_destroy, :permanent_destroy}
      end
    end

    form do
      actions do
        create {:master_create, :create}
        update {:master_update, :update}
        read {:master_get, :read}
      end

      submit do
        create label: fn -> dgettext("mishka_gervaz", "Create") end
        update label: fn -> dgettext("mishka_gervaz", "Save Changes") end
        cancel label: fn -> dgettext("mishka_gervaz", "Cancel") end
        position :bottom
      end
    end
  end

  resources do
    resource MishkaCmsCore.Accounts.Token
    resource MishkaCmsCore.Accounts.User
    resource MishkaCmsCore.Accounts.Permission
    resource MishkaCmsCore.Accounts.UserPermission
  end
end
