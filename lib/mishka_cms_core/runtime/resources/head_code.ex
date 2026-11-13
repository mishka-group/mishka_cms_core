# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.HeadCode do
  @moduledoc """
  One entry of a site's head code: tags its public pages carry in their `<head>`, such as an
  analytics script, a search engine's verification tag or a font link.

  An entry is a site's own (`global? false`). `code` is what the admin pasted, kept as written and
  parsed into tags when it is served (see `MishkaCmsCore.Runtime.HeadCodes` for what is kept).
  `scope` is where it goes: `:all` pages, `:only` the pages in `paths`, or every page `:except`
  them. A path matches a page's address or its stored pattern exactly. `origins` are the
  `https://` origins the code reaches, added to the site's Content Security Policy.

  ## Draft and published

  An entry is a draft until `published`, and only a published one is served. Every save is a
  version (AshPaperTrail), listed in the activity log as the other runtime records are.

  ## Served from memory

  Published entries are held in `MishkaCmsCore.Runtime.States.SiteState`, loaded at boot and kept
  current by `MishkaCmsCore.Runtime.Resources.Notifiers.HeadCodes` and this resource's broadcasts.

  ## Who writes them

  The code runs for every visitor of the site, so writing an entry is a master's alone: every write
  action requires a master (`TenantContext`, `require_master: true`) holding
  `admin:dashboard:runtime:head_code`. Dashboard admins under the request's surface read their own
  site's entries.

  A site holds at most `MishkaCmsCore.Runtime.HeadCodes.max_entries/0` entries, and an entry's code
  at most `MishkaCmsCore.Runtime.HeadCodes.max_code_bytes/0` bytes.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshPaperTrail.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.HeadCodes],
    authorizers: [Ash.Policy.Authorizer]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [badge: 1, cell_stacked: 1]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.HeadCodes
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @admin_fields [:name, :code, :scope, :paths, :origins, :published]

  postgres do
    table "cms_head_codes"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    base_filter_sql "(archived_at IS NULL)"
  end

  archive do
    exclude_read_actions [:archived, :get_archived, :master_get_archived, :master_archived]
    exclude_destroy_actions [:master_permanent_destroy]
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    store_action_inputs? true
    ignore_attributes [:inserted_at, :updated_at, :archived_at]
    ignore_actions [:master_unarchive, :master_permanent_destroy]
    attributes_as_attributes [:site_id]
    create_version_on_destroy? true
    only_when_changed? true
    relationship_opts public?: true

    belongs_to_actor :user, MishkaCmsCore.Accounts.User,
      domain: MishkaCmsCore.Accounts,
      on_delete: :nilify

    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.HeadCodePaperTrailMixin, :postgres, []}
  end

  mishka_gervaz do
    table do
      identity do
        name :head_codes
        route "/admin/dashboard/runtime/pages"
        stream_name :head_codes
      end

      source do
        actions do
          read {:master_read, :read}
          get {:master_get, :read}
          destroy :master_destroy
        end

        archive do
          read_action {:master_archived, :archived}
          get_action {:master_get_archived, :get_archived}
          restore_action :master_unarchive
          destroy_action :master_permanent_destroy
        end

        preload do
          always [:site, :version_count]
        end
      end

      columns do
        default_sort [{:inserted_at, :asc}]

        column :entry do
          static true
          requires [:name, :scope, :paths]
          label fn -> dgettext("mishka_gervaz", "Entry") end
          position :first

          ui do
            width "minmax(220px,2fr)"
          end

          render fn record ->
            assigns = %{
              name: record.name,
              where:
                Enum.join(
                  [
                    HeadCodes.scope_label(record.scope)
                    | (record.scope != :all && record.paths) || []
                  ],
                  " · "
                )
            }

            ~H"""
            <.cell_stacked variant={:title} primary={@name} secondary={@where} />
            """
          end
        end

        column :status do
          static true
          requires [:published, :version_count]
          label fn -> dgettext("mishka_gervaz", "Status") end

          render fn record ->
            assigns = %{
              published?: record.published,
              label:
                case record.published do
                  true ->
                    dgettext("mishka_gervaz", "Published v%{count}", count: record.version_count)

                  false ->
                    dgettext("mishka_gervaz", "Draft")
                end
            }

            ~H"""
            <.badge
              label={@label}
              class={if(@published?, do: "bg-[#e6f6ee] text-[#177a53]", else: "bg-[#f2f1ec] text-[#8a877f]")}
            />
            """
          end
        end

        column :site_info do
          static true
          requires [:site_id, :site]
          label fn -> dgettext("mishka_gervaz", "Site") end
          position :last
          visible fn state -> state.master_user? end

          render fn record ->
            assigns = %{name: record.site && record.site.name}

            ~H"""
            <MishkaCmsCore.CoreComponents.site_cell global?={false} name={@name} />
            """
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:name, :code]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

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
        action :edit do
          type :event
          event "head_code_edit"

          visible fn _record, state ->
            state.archive_status == :active and HeadCodes.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this head code entry?") end

          visible fn _record, state ->
            state.archive_status == :active and HeadCodes.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this head code entry?") end

          visible fn _record, state ->
            state.archive_status == :archived and HeadCodes.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Permanently delete this head code entry? This cannot be undone."
            )
          end

          visible fn _record, state ->
            state.archive_status == :archived and HeadCodes.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete permanently") end
            icon "hero-trash"
          end
        end
      end

      realtime do
        prefix "head_code"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No head code yet"),
                  icon: "hero-code-bracket"
    end

    form do
      identity do
        name :head_code_form
      end

      source do
        actions do
          create :master_create
          update :master_update
          read :master_get
        end
      end

      fields do
        field :site_id, :relation do
          resource MishkaCmsCore.Runtime.Site
          display_field :name
          search_field :name
          mode :search
          min_chars 1
          page_size 15
          restricted true
          required true
          show_on :create

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :name, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
            placeholder "Plausible"
          end
        end

        field :code, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Code") end
            rows 8
            extra %{code: "html"}

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Script, meta, link and noscript tags. Anything else, and every inline event handler, is left out. Each script gets the page's nonce."
              )
            end
          end
        end

        field :scope, :select do
          options fn -> HeadCodes.scope_options() end

          ui do
            label fn -> dgettext("mishka_gervaz", "Where") end
          end
        end

        field :paths, :string_list do
          visible fn state -> HeadCodes.form_scope(state) != :all end

          ui do
            label fn -> dgettext("mishka_gervaz", "Pages") end
            placeholder "/pricing"
            add_label fn -> dgettext("mishka_gervaz", "+ Add page") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A page's address or its path pattern, such as /pricing or /blog/:slug. A script on these pages stays loaded until the visitor reloads, even after moving to another page."
              )
            end
          end
        end

        field :origins, :string_list do
          ui do
            label fn -> dgettext("mishka_gervaz", "Allowed origins") end
            placeholder "https://plausible.io"
            add_label fn -> dgettext("mishka_gervaz", "+ Add origin") end
            extra %{dir: "ltr"}

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Where the code loads scripts from or sends data to. Each is added to this site's Content Security Policy."
              )
            end
          end
        end

        field :published do
          ui do
            label fn -> dgettext("mishka_gervaz", "Published") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A draft is saved and kept out of the pages until you publish it."
              )
            end
          end
        end
      end

      groups do
        group :entry do
          fields [:site_id, :name, :code]

          ui do
            columns 1
            class ""
          end
        end

        group :where do
          fields [:scope, :paths, :origins, :published]

          ui do
            columns 1
            class ""
          end
        end
      end

      presentation do
        features :all
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      derives: "sanitize(trim, no_control) validate(string, not_empty, max_len=100)"

    field :code, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(string, not_empty)"

    field :scope, :atom, derives: "validate(atom, enum=Atom[all::only::except])"

    field :paths, {:array, :string},
      derives: "sanitize(each=[trim], reject_empty, uniq) validate(list)"

    field :origins, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :published, :boolean, derives: "validate(boolean)"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :master_create do
      primary? true
      accept [:site_id | @admin_fields]
      validate present([:site_id])

      validate {TenantContext, require_master: true}
      # Counted as the action runs, so typing in the form costs no query.
      validate &HeadCodes.check_room/2, only_when_valid?: true, before_action?: true

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, Ash.Changeset.get_attribute(changeset, :site_id))
      end

      description "Creates a head code entry for a site (master users)"
    end

    update :master_update do
      primary? true
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit an archived entry. Restore it first.")
      end

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      description "Updates a head code entry (master users)"
    end

    read :master_read do
      multitenancy :bypass

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {TenantContext, require_master: true}

      description "Reads every site's head code entries (master users)"
    end

    read :master_get do
      get? true
      multitenancy :bypass

      validate {TenantContext, require_master: true}

      description "Retrieves one head code entry by ID (master users)"
    end

    read :read_any do
      multitenancy :bypass
      pagination keyset?: true, offset?: true, required?: false

      description "Every live head code entry, for loading the ETS cache"
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {TenantContext, require_master: false}

      description "Lists archived head code entries within the current tenant"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {TenantContext, require_master: true}

      description "Lists every site's archived head code entries (master users)"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {TenantContext, require_master: false}

      description "Retrieves one archived head code entry (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {TenantContext, require_master: true}

      description "Retrieves one archived head code entry (master users)"
    end

    destroy :master_destroy do
      primary? true
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      description "Archives a head code entry (master users)"
    end

    update :master_unarchive do
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "This entry is not archived.")
      end

      change set_attribute(:archived_at, nil)
      atomic_upgrade_with :master_archived

      description "Restores an archived head code entry (master users)"
    end

    destroy :master_permanent_destroy do
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      description "Permanently removes a head code entry and its versions (master users)"
    end
  end

  policies do
    # Reached only with `authorize?: false`: `SiteState` loads through it at boot.
    policy action(:read_any) do
      forbid_if always()
    end

    # Writing takes the head code section; anyone under the request's surface reads.
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if {AccessPermissions, permissions: ["admin:dashboard:runtime:head_code"]}

      forbid_unless action_type(:read)
      authorize_if {AccessPermissions, under: :surface}
    end

    # The code runs for every visitor of the site, so only a master writes it.
    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end

    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  # `SiteState` listens on the topics without a site; the dashboard on the site's own.
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "head_code"

    publish_all :create, [[nil, :site_id], "created"]
    publish_all :update, [[nil, :site_id], "updated"]
    publish_all :destroy, [[nil, :site_id], "destroyed"]
  end

  validations do
    validate &HeadCodes.check_entry/2, on: [:create, :update], where: [present(:code)]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
      description "What the entry is, for the people who keep it, such as Plausible"
    end

    attribute :code, :string do
      allow_nil? false
      public? true
      constraints trim?: false

      description "The tags as the admin wrote them, at most HeadCodes.max_code_bytes/0 bytes; parsed by HeadCodes.parse/1 when served"
    end

    attribute :scope, :atom do
      allow_nil? false
      public? true
      default :all
      constraints one_of: [:all, :only, :except]
      description "Where the entry goes: all pages, only the pages in paths, or all except them"
    end

    attribute :paths, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "The page addresses or path patterns the scope names"
    end

    attribute :origins, {:array, :string} do
      allow_nil? false
      public? true
      default []

      description "The https origins the code reaches, added to the site's Content Security Policy"
    end

    attribute :published, :boolean do
      allow_nil? false
      public? true
      default false
      description "Whether the entry is served; a draft is not"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site the entry belongs to"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.HeadCode.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  aggregates do
    count :version_count, :sorted_versions do
      public? true
      description "How many versions the entry has, the current one included"
    end
  end
end
