defmodule MishkaCmsCore.Accounts.UserPermission do
  @moduledoc """
  Manages the many-to-many relationship between users and permissions.

  This resource serves as the join table that associates users with their granted
  permissions, forming the foundation of the role-based access control system.
  Each record represents a single permission assignment to a user, enabling
  fine-grained control over what actions users can perform throughout the system.

  The resource implements upsert functionality through the assign action, preventing
  duplicate permission assignments while allowing efficient bulk permission updates.
  The unique constraint on user_id and permission_id pairs ensures that each user
  can only have a permission assigned once, maintaining data integrity.

  A row is written through `MishkaCmsCore.Accounts.User`'s own actions, which hold a grant to the
  granter's ceiling and keep a site's admin off its own permissions, or directly by a master holding
  the permission area (`admin:<surface>:permission`). A site's holder of that area reads the grants
  of its own site's users only.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook
    ]

  # Database configuration for join table
  postgres do
    table "user_permissions"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :user, on_delete: :delete
      reference :permission, on_delete: :delete
    end

    # WHO HOLDS THIS PERMISSION. Both existing indexes lead with another column — the key is
    # `(id, user_id, permission_id)` and the identity `(user_id, permission_id)` — so a read by
    # permission alone can use neither and scans the table. That read is what tells a permission
    # change whose sessions to recheck, so it runs on an admin's save: measured on 200k rows with
    # eight holders, 6.7 ms of sequential scan against 0.034 ms through this.
    custom_indexes do
      index [:permission_id]
    end
  end

  actions do
    defaults [:create, :read, :destroy]

    create :assign do
      description "Assigns a permission to a user, updating if already exists"
      primary? true
      upsert? true
      upsert_identity :unique_user_permission
    end
  end

  # Authorization policies for permission assignment.
  # A row is READ within the actor's site: a master may reach any grant, a site's admin only the
  # grants of its own site's users. The join has no multitenancy of its own, so nothing else holds a
  # site's admin to its site here, tenant or not.
  #
  # Every permission check in the system loads a user's permissions THROUGH the user
  # (`accessing_from(User, :permissions_join_assoc)`), which each policy lets through first, so the
  # scope never reaches authorization itself.
  policies do
    policy action_type([:create, :destroy]) do
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :permissions_join_assoc)
      forbid_unless actor_attribute_equals(:site_id, nil)
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :permissions_join_assoc)
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(user.site_id == ^actor(:site_id))
    end

    policy always() do
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :permissions_join_assoc)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:permission", "admin:api:permission"]}
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :created_at
  end

  relationships do
    belongs_to :user, MishkaCmsCore.Accounts.User do
      description "The user being granted the permission"
      primary_key? true
      allow_nil? false
    end

    belongs_to :permission, MishkaCmsCore.Accounts.Permission do
      description "The permission being granted to the user"
      primary_key? true
      allow_nil? false
    end
  end

  identities do
    identity :unique_user_permission, [:user_id, :permission_id] do
      description "Ensures each user-permission pair is unique"
    end
  end
end
