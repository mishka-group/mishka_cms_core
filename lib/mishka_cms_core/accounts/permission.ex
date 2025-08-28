defmodule MishkaCmsCore.Accounts.Permission do
  @moduledoc """
  Defines system permissions for role-based access control.

  This resource represents individual permissions that can be granted to users,
  forming the basis of the authorization system. An admin permission is named
  `admin:<surface>:<area>` (e.g. `admin:dashboard:runtime:page`, `admin:api:blog:post`), written as a
  plain string where it is used. A `*` as the whole last segment covers everything below it
  (`admin:dashboard:*`, `admin:*`), and `*` alone covers everything. See
  `MishkaCmsCore.Accounts.Checks.AccessPermissions`.

  Each permission has a unique name and optional description explaining its purpose.
  Permissions are assigned to users through the UserPermission join table, creating
  a many-to-many relationship that allows users to have multiple permissions and
  permissions to be shared across multiple users.

  Access to manage permissions is restricted through policies to users who already
  have administrative privileges, ensuring that only authorized actors can modify
  the permission structure. The unique constraint on permission names prevents
  duplicate permissions and maintains consistency in the authorization system.

  ## Access Control
  - Masters (`site_id` nil) holding `admin:<surface>:permission`: full CRUD access
  - Site users holding `admin:<surface>:permission`: read-only access
  - Anyone else: no access, except a user's own permissions read through its account
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, MishkaGervaz.Resource, GuardedStruct.AshResource],
    notifiers: [
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook
    ],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  @admin_fields [:name, :description]

  # Database configuration for permission storage
  postgres do
    table "permissions"
    repo Application.compile_env!(:mishka_cms_core, :repo)
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "permission"
  end

  mishka_gervaz do
    table do
      identity do
        name :permissions
        route "/admin/dashboard/account/permissions"
        stream_name :permissions
      end

      source do
        actions do
          read {:master_read, :tenant_read}
          get {:master_get, :tenant_get}
          destroy {:destroy, :destroy}
        end
      end

      columns do
        default_sort [{:name, :asc}]

        # A permission is a scope string, not prose — it reads as a key you look up, so the design
        # sets it in the indigo it uses for identifiers and pairs it with a key tile.
        column :permission_name do
          static true
          requires [:name]
          label fn -> dgettext("mishka_gervaz", "Permission Name") end
          position :first
          sortable true
          sort_field [:name]

          ui do
            width "minmax(220px,1.4fr)"
          end

          render fn record ->
            assigns = %{name: record.name}

            ~H"""
            <div class="flex min-w-0 items-center gap-2.5">
              <span class="grid size-7 flex-none place-items-center rounded-[8px] border border-[#ecebe6] bg-[#faf9f6] text-[#8a877f]">
                <.icon name="hero-key" class="size-[15px]" />
              </span>
              <span class="truncate font-['Space_Grotesk'] text-[13px] font-bold text-[#4f4bcc]" title={@name}>
                {@name}
              </span>
            </div>
            """
          end
        end

        column :description do
          static true
          requires [:description]
          label fn -> dgettext("mishka_gervaz", "Description") end

          ui do
            width "minmax(280px,2fr)"
          end

          render fn record ->
            assigns = %{description: record.description}

            ~H"""
            <p
              :if={@description not in [nil, ""]}
              class="line-clamp-2 text-[12.5px] leading-[1.5] text-[#6d6a63]"
              title={@description}
            >
              {@description}
            </p>
            <span :if={@description in [nil, ""]} class="text-[12px] font-medium text-[#a8a5a0]">
              —
            </span>
            """
          end
        end

        # The React design keeps created and updated as their own columns — a calendar for one, a
        # clock for the other — rather than stacking them, so each timestamp reads on its own line.
        column :created do
          static true
          requires [:created_at]
          label fn -> dgettext("mishka_gervaz", "Created") end
          sortable true
          sort_field [:created_at]

          ui do
            width "minmax(155px,1fr)"
          end

          render fn record ->
            assigns = %{created: permission_date(record.created_at)}

            ~H"""
            <div :if={@created} class="flex items-center gap-[7px] text-[12px] font-medium text-[#3a382f]">
              <.icon name="hero-calendar" class="size-[14px] shrink-0 text-[#a8a5a0]" />
              {@created}
            </div>
            <span :if={is_nil(@created)} class="text-[12px] font-medium text-[#a8a5a0]">—</span>
            """
          end
        end

        column :updated do
          static true
          requires [:updated_at]
          label fn -> dgettext("mishka_gervaz", "Updated") end
          sortable true
          sort_field [:updated_at]

          ui do
            width "minmax(155px,1fr)"
          end

          render fn record ->
            assigns = %{updated: permission_date(record.updated_at)}

            ~H"""
            <div :if={@updated} class="flex items-center gap-[7px] text-[12px] font-medium text-[#3a382f]">
              <.icon name="hero-clock" class="size-[14px] shrink-0 text-[#a8a5a0]" />
              {@updated}
            </div>
            <span :if={is_nil(@updated)} class="text-[12px] font-medium text-[#a8a5a0]">—</span>
            """
          end
        end
      end

      filters do
        filter :search, :text, fields: [:name, :description]
      end

      row_actions do
        action :show do
          type :event
          event "show_permission_modal"

          ui do
            label fn -> dgettext("mishka_gervaz", "View") end
            icon "hero-eye"
          end
        end

        action :edit do
          type :event
          event "edit_permission_modal"
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Delete this permission?") end
          restricted true
        end
      end

      bulk_actions do
        action :delete,
          type: :destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Delete the selected permissions? This action cannot be undone."
            ),
          restricted: true
      end

      row do
        selectable true
      end

      pagination do
        type :numbered
        page_size 20
        page_size_options [20, 50, 100]
      end

      realtime do
        prefix "permission"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :page_size, :search]
        prefix "permissions"
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No permissions found"),
                  icon: "hero-key"
    end

    form do
      identity do
        name :permission_form
      end

      source do
        access :create, restricted: true
        access :update, restricted: true

        actions do
          create {:create, :create}
          update {:update, :update}
          read {:master_get, :tenant_get}
        end
      end

      fields do
        field :name do
          required true
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end

            placeholder fn ->
              dgettext("mishka_gervaz", "e.g., admin:dashboard:runtime:page, *")
            end
          end
        end

        field :description do
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end

            placeholder fn ->
              dgettext("mishka_gervaz", "Describe what this permission allows")
            end
          end
        end
      end

      groups do
        group :main_fields do
          fields [:name, :description]

          ui do
            columns 1
            class ""
          end
        end
      end

      presentation do
        features :all
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      derives:
        ~S{sanitize(trim, downcase) validate(string, not_empty, min_len=1, max_len=200, regex=^(\*|[a-z][a-z0-9_]*(:[a-z0-9_]+)*(:\*)?)$)}

    field :description, :string, derives: "sanitize(trim) validate(optional=[string])"
  end

  actions do
    default_accept @admin_fields

    read :read do
      primary? true
      pagination offset?: true, default_limit: 100, countable: true, required?: false

      description "Default list action for reading permissions"
    end

    read :get do
      get? true

      description "Default get action for reading a single permission"
    end

    # Backward compatibility alias
    read :permissions do
      pagination offset?: true, default_limit: 100, countable: true

      description "Read all permissions with pagination support (backward compatibility)"
    end

    read :tenant_read do
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists all permissions for tenant users (read-only)"
    end

    read :tenant_get do
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Gets a single permission for tenant users (read-only)"
    end

    read :master_read do
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all permissions (master users only)"
    end

    read :master_get do
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Gets a single permission by ID (master users only)"
    end

    create :create do
      primary? true

      validate present(:name)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Creates a new permission (master users only)"
    end

    update :update do
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Updates a permission (master users only)"
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Permanently deletes a permission (master users only)"
    end
  end

  # Authorization policies for permission management
  policies do
    # The permissions of an account the caller reached through another resource and may not see.
    # A filter policy, so the load answers with no permissions rather than failing the request.
    policy MishkaCmsCore.Accounts.Checks.AccountWithheld do
      forbid_if always()
    end

    # THE CATALOGUE IS A MASTER'S TO CHANGE: a user whose `site_id` is nil, holding the permission
    # area the policy below asks of every action. Asked of the actor the write RUNS with;
    # `TenantContext` on each write asks it of the actor the changeset was BUILT with, which need not
    # be the same one. A site user holding `*` reads the catalogue and changes none of it.
    policy action_type([:create, :update, :destroy]) do
      description "Only a master: a user with no site"

      forbid_unless actor_attribute_equals(:site_id, nil)
      authorize_if always()
    end

    policy always() do
      access_type :strict

      # Every permission check in the system loads a user's own permissions through this
      # relationship. Without it, authorization cannot bootstrap itself.
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :permissions)

      # The permission area reaches the catalogue: browsing what exists is the first half of
      # assigning it, and `manage_relationship` reads Permission on the granter's behalf.
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:permission", "admin:api:permission"]}
    end
  end

  # Real-time updates via PubSub
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "permission"

    publish :create, ["created"]
    publish :update, [[nil, :_pkey], "updated"]
    publish :destroy, [[nil, :_pkey], "destroyed"]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200, trim?: true
      description "Permission name like 'admin:dashboard:runtime:page' or '*'"
    end

    attribute :description, :string do
      public? true
      description "Human-readable description of what this permission allows"
    end

    create_timestamp :created_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    many_to_many :users, MishkaCmsCore.Accounts.User do
      description "Users who have been granted this permission"
      through MishkaCmsCore.Accounts.UserPermission
      source_attribute_on_join_resource :permission_id
      destination_attribute_on_join_resource :user_id
    end
  end

  identities do
    identity :unique_name, [:name] do
      description "Ensures permission names are globally unique for consistent authorization"
    end
  end

  defp permission_date(nil), do: nil

  defp permission_date(datetime),
    do:
      Calendar.strftime(
        datetime,
        "%b %-d, %Y, %I:%M %p",
        MishkaCmsCore.Activity.Helpers.strftime_names()
      )
end
