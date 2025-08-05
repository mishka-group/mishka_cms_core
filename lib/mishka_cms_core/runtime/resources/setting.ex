defmodule MishkaCmsCore.Runtime.Setting do
  @moduledoc """
  Durable key/value CMS settings, multitenant like `MishkaCmsCore.Runtime.Layout` (`global? true`):
  a row with `site_id = nil` is a GLOBAL setting (one value for every site, master-managed); a row
  with a `site_id` is a PER-SITE setting owned by that tenant (site title, SEO, …). Both live in the
  one `cms_settings` table, keyed by `[:key, :site_id]`.

  Values are stored as JSON maps; the facade `MishkaCmsCore.Settings` wraps/unwraps scalars and the
  ETS cache `MishkaCmsCore.Runtime.States.SettingsState` serves them lock-free (site value → global
  default) on every request. Reads are open (non-secret config); a tenant writes only its own rows
  (the tenant `:set` auto-stamps `site_id`), the master writes any site or the global via `:master_set`.

  That split is enforced by the policies below, not by convention or by the caller. A write takes
  the permission the setting's definition declares, or `admin:dashboard:setting` when it declares
  none (`MishkaCmsCore.Runtime.Resources.Checks.SettingPermission`). Because every site's rows share
  one table, that permission alone cannot decide a write — every site's settings admin holds it — so
  a second policy pins the row to `actor.site_id` unless the actor is a master. Write through
  `MishkaCmsCore.Settings.put_as/4` to get that; `put/3` is the trusted infra path for boot seeding
  and passes `authorize?: false`, which skips all of it.

  PubSub topics: a nil `site_id` publishes to `"setting:updated"` only; a uuid `site_id` publishes to
  both `"setting:updated"` AND `"setting:{uuid}:updated"`, so a master watching the global topic sees
  every change while a tenant watches only its own.

  See `MishkaCmsCore.Settings`, `MishkaCmsCore.Runtime.States.SettingsState`,
  `MishkaCmsCore.Runtime.Layout` (the `global? true` reference) and
  `MishkaCmsCore.Runtime.Resources.Validations.TenantContext`.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook
    ]

  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  postgres do
    table "cms_settings"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :by_key do
      get? true
      argument :key, :string, allow_nil?: false
      filter expr(key == ^arg(:key))
      description "Get a single setting by key within the current tenant."
    end

    # NOT a TODO — verified reachable-by-nobody, recorded so the next reader need not re-derive it.
    # The action itself is unguarded (`multitenancy :bypass`, no `require_master`), but: it is not a
    # JSON:API route; of the relationships using it as `read_action`, only the includable one goes
    # through a resource whose OWN policies run on the relationship load, and an anonymous
    # `?include=` there answers 403; and the in-app callers select it by pattern-matching
    # `%User{site_id: nil}`. The missing guard is defence-in-depth, not an open door.
    #
    # If this action is ever routed, or another `master_*` relationship is added to `includes`, that
    # reasoning stops holding and it needs
    # `validate {..., TenantContext, require_master: true}` first.
    read :read_any do
      multitenancy :bypass
      description "Lists all settings system-wide (globals + every site) for cache loading."
    end

    read :master_read do
      multitenancy :bypass
      validate {TenantContext, require_master: true}
      description "Lists all settings system-wide (master only)."
    end

    read :for_tenant_with_globals do
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to scope to (master only); tenants use their bound tenant."
      end

      prepare {MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals, fallback: :globals}

      description "Lists a tenant's own settings + globals; master may pass site_id."
    end

    create :set do
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:value, :category, :source, :description, :editable?]

      accept [:key, :value, :category, :source, :description, :editable?]

      validate {TenantContext, require_master: false}

      change fn changeset, context ->
        if !is_nil(context.tenant),
          do: Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant),
          else: changeset
      end

      description "Create-or-update a setting for the current tenant (auto-stamps site_id)."
    end

    create :master_set do
      multitenancy :bypass

      upsert? true
      upsert_identity :unique_key
      upsert_fields [:value, :category, :source, :description, :editable?]

      accept [:key, :value, :category, :source, :description, :editable?, :site_id]

      validate {TenantContext, require_master: true}

      description "Create-or-update a global (nil site_id) or site-specific setting (master only)."
    end

    destroy :destroy do
      primary? true
      description "Delete a setting within the current tenant."
    end

    destroy :master_destroy do
      multitenancy :bypass
      validate {TenantContext, require_master: true}
      description "Delete any setting system-wide (master only)."
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if MishkaCmsCore.Runtime.Resources.Checks.SettingPermission
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end

    policy action([:master_set, :master_destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end

    # WHOSE ROWS A READ SHOWS, held to the actor when it runs, whichever read it is — `:read_any`,
    # `:get_any` and the shared-rows reads included: a master (`site_id` nil) reads any site's rows,
    # a site user its own site's and the shared ones, whatever it holds or passes as a tenant. See
    # `MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals` for the actor a shared-rows read
    # was built with. System reads pass `authorize?: false`.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(is_nil(site_id) or site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "setting"

    publish :set, [[nil, :site_id], "updated"]
    publish :master_set, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200, trim?: true
      description "Setting key, e.g. \"site.title\", \"cms.offline\", \"blog.posts_per_page\"."
    end

    attribute :value, :map do
      allow_nil? false
      default %{}
      public? true
      description "The setting payload, wrapped as %{\"value\" => term} by the facade."
    end

    attribute :category, :string do
      allow_nil? false
      default "general"
      public? true
      description "Grouping for the settings page (general / notifications / <extension>)."
    end

    attribute :source, :atom do
      allow_nil? false
      default :core
      public? true
      constraints one_of: [:core, :extension, :plugin]
      description "Who registered the setting."
    end

    attribute :description, :string, public?: true

    attribute :editable?, :boolean do
      allow_nil? false
      default true
      public? true
    end

    create_timestamp :created_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this setting belongs to (nil = global, shared by every site)."
    end
  end

  identities do
    identity :unique_key, [:key, :site_id], nils_distinct?: false
  end
end
