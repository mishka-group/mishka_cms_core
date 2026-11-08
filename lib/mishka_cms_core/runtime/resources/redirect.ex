# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Redirect do
  @moduledoc """
  One address of a site answered by a rule — a page or a file that moved, and the visitors, search
  engines and shared links that still ask for its old address.

  A rule is a site's own (`global? false`): `from_path` is the address asked for, and `kind` what it
  answers — see `MishkaCmsCore.Runtime.Redirects`:

    * `:redirect` (the default) sends the visitor to `to` — a path on the same site or a full
      `http(s)` address — with `status` 301, 302, 307 or 308;
    * `:rewrite` serves `to`, a page or a media file of the same site, at the address asked for,
      which stays in the browser;
    * `:gone` and `:not_found` answer the site's error page with 410 or 404, and keep no `to`.

  `status` is a redirect's alone. An inactive rule is kept and answers nothing.

  ## Addresses

  `from_path` is stored as `MishkaCmsCore.Runtime.Redirects.normalize_path/1` writes it: one leading
  `/`, no scheme or host, no query or fragment, no trailing `/` but the root's, and its
  percent-escapes decoded, so a rule matches the address however a browser spelled it. A redirect's
  `to` is stored as written, a rewrite's as `normalize_path/1` writes it. A rule is refused when its
  target is its own source, a redirect when following the site's active redirects from its target
  comes back to an address already on the way, and a rewrite whose target is on another host, one of
  the CMS's own addresses, or a file outside its site's media folder.

  `from_query` narrows a rule to a query string, as `MishkaCmsCore.Runtime.Redirects.normalize_query/1`
  writes it: `p=123` on `/` answers WordPress's `/?p=123`, and `page_id=7` or `cat=3` the same. Such a
  rule answers only a request that carries that query, alone or among other parameters, and sends
  the visitor on without it. `p=*` answers `p` with any value, at its own path, when no rule on the
  exact query does. A rule with none answers its path whatever the query.

  ## Served from ETS

  Every rule that is active is held by `MishkaCmsCore.Runtime.States.RedirectsState`, loaded at boot
  and kept current off this resource's broadcasts. `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` asks
  it once the request's site is known, before any page is resolved — see
  `MishkaCmsCore.Runtime.Redirects.redirect/2`.

  ## Who writes them

  Anyone under the request's surface reads a site's rules; writing them takes the redirect section,
  `admin:dashboard:runtime:redirect` or `admin:api:runtime:redirect`. A master reaches every site, a
  site user its own.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshPaperTrail.Resource,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [badge: 1, cell_stacked: 1]

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Redirects
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @admin_fields [:kind, :from_path, :from_query, :to, :status, :active, :description, :site_id]

  @form_modal "redirect-form-modal"

  postgres do
    table "cms_redirects"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # The unique index on `(site_id, from_path)` leaves the archived rows out with it, so an archived
    # rule never holds its address against a new one.
    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :status, "redirect_status_check",
        check: "status IN (301, 302, 307, 308)",
        message: dgettext_noop("errors", "Status must be 301, 302, 307 or 308.")
    end
  end

  archive do
    exclude_read_actions [
      :archived,
      :get_archived,
      :master_get_archived,
      :master_get,
      :master_archived
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    store_action_inputs? true
    ignore_attributes [:inserted_at, :updated_at, :archived_at]
    ignore_actions [:unarchive, :master_unarchive, :permanent_destroy, :master_permanent_destroy]
    attributes_as_attributes [:site_id]
    create_version_on_destroy? true
    only_when_changed? true
    relationship_opts public?: true

    # The version stays, with no author, when the account that made it is deleted.
    belongs_to_actor :user, MishkaCmsCore.Accounts.User,
      domain: MishkaCmsCore.Accounts,
      on_delete: :nilify

    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.RedirectPaperTrailMixin, :postgres, []}
  end

  json_api do
    type "redirect"
  end

  mishka_gervaz do
    table do
      identity do
        name :redirects
        route "/admin/dashboard/runtime/redirects"
        stream_name :redirects
      end

      source do
        preload do
          always [:site]
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        column :rule do
          static true
          requires [:from_path, :from_query, :to]
          label fn -> dgettext("mishka_gervaz", "Rule") end
          position :first

          ui do
            width "minmax(260px,2fr)"
          end

          render fn record ->
            assigns = %{
              from: Enum.join([record.from_path | List.wrap(record.from_query)], "?"),
              to: record.to && "→ " <> record.to
            }

            ~H"""
            <.cell_stacked variant={:title} primary={@from} secondary={@to} />
            """
          end
        end

        column :kind do
          static true
          requires [:kind]
          label fn -> dgettext("mishka_gervaz", "Kind") end
          sortable true
          sort_field [:kind]

          render fn record ->
            assigns = %{label: Redirects.kind_label(record.kind)}

            ~H"""
            <.badge label={@label} class="bg-[#f2f1ec] text-[#5c5a55]" />
            """
          end
        end

        # DRAWN HERE, NOT BY THE `:badge` TYPE, which reads a value as a string or an atom and a
        # status is an integer. A permanent move is blue, a temporary one amber; a rule that is not a
        # redirect has no status of its own.
        column :status do
          static true
          requires [:kind, :status]
          label fn -> dgettext("mishka_gervaz", "Status") end
          sortable true
          sort_field [:status]

          render fn record ->
            assigns = %{
              redirect?: record.kind == :redirect,
              label: Redirects.status_label(record.status),
              class:
                if(Redirects.permanent?(record.status),
                  do: "bg-[#eaf1fb] text-[#3a6cb5]",
                  else: "bg-[#fbf1df] text-[#a5691a]"
                )
            }

            ~H"""
            <.badge :if={@redirect?} label={@label} class={@class} />
            """
          end
        end

        column :active do
          label fn -> dgettext("mishka_gervaz", "Active") end

          ui do
            type :badge

            extra %{
              variant: :pill,
              colors: %{
                "true" => "bg-[#e6f6ee] text-[#177a53]",
                "false" => "bg-[#f2f1ec] text-[#8a877f]"
              },
              labels: %{
                "true" => dgettext_noop("mishka_gervaz", "Active"),
                "false" => dgettext_noop("mishka_gervaz", "Inactive")
              },
              dots: %{"true" => "bg-[#1f9d6b]", "false" => "bg-[#a8a5a0]"},
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
          end
        end

        # A site user reads its own site's rules alone, so the column is a master's.
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
          fields [:from_path, :from_query, :to, :description]

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

        filter :kind, :select do
          options fn -> Redirects.kind_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any kind")
            label fn -> dgettext("mishka_gervaz", "Kind") end
          end
        end

        filter :status, :select do
          options fn -> Redirects.status_options() end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Any status")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :active, :boolean
      end

      row_actions do
        action :edit do
          type :edit
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal(@form_modal) end

          visible fn _record, state ->
            state.archive_status == :active and Redirects.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this redirect?") end

          visible fn _record, state ->
            state.archive_status == :active and Redirects.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this redirect?") end

          visible fn _record, state ->
            state.archive_status == :archived and Redirects.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Permanently delete this redirect? This cannot be undone.")
          end

          visible fn _record, state ->
            state.archive_status == :archived and Redirects.writes?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete permanently") end
            icon "hero-trash"
          end
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :archive,
          handler: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected redirects?"),
          visible: fn state ->
            state.archive_status == :active and Redirects.writes?(state.current_user)
          end

        action :unarchive,
          handler: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected redirects?"),
          visible: fn state ->
            state.archive_status == :archived and Redirects.writes?(state.current_user)
          end

        action :permanent_destroy,
          handler: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected redirects? This cannot be undone."
            ),
          visible: fn state ->
            state.archive_status == :archived and Redirects.writes?(state.current_user)
          end
      end

      realtime do
        prefix "redirect"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "redirects"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No redirects yet"), icon: "hero-link"
    end

    form do
      identity do
        name :redirect_form
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

        field :kind, :select do
          options fn -> Redirects.kind_options() end

          ui do
            label fn -> dgettext("mishka_gervaz", "Kind") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "What this address answers: send the visitor on, serve another page here, or show the error page."
              )
            end
          end
        end

        field :from_path, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "From") end
            placeholder "/images/blog/old-photo.jpg"
            extra %{dir: "ltr"}

            description fn ->
              dgettext(
                "mishka_gervaz",
                "The old address still being asked for."
              )
            end
          end
        end

        field :match_query, :checkbox do
          virtual true

          ui do
            label fn -> dgettext("mishka_gervaz", "Match a query string") end

            description fn ->
              dgettext("mishka_gervaz", "For links such as WordPress ?p= addresses.")
            end
          end
        end

        field :from_query, :text do
          visible fn state -> Redirects.form_match_query?(state) end

          ui do
            label fn -> dgettext("mishka_gervaz", "From query") end
            placeholder "p=123"
            extra %{dir: "ltr"}

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Only when the address is asked with this query, such as p=123 or page_id=7 from WordPress. p=* answers p with any value when no rule names its exact value. Empty answers the address whatever its query."
              )
            end
          end
        end

        field :to, :text do
          required true
          visible fn state -> Redirects.form_kind(state) in [:redirect, :rewrite] end

          ui do
            label fn -> dgettext("mishka_gervaz", "To") end
            placeholder "/uploads/site/media/photo.jpg"
            extra %{dir: "ltr"}

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A path on this site, or a full http(s) address."
              )
            end
          end
        end

        field :status, :select do
          visible fn state -> Redirects.form_kind(state) == :redirect end
          options fn -> Redirects.status_options() end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        field :active do
          ui do
            label fn -> dgettext("mishka_gervaz", "Active") end
          end
        end

        field :description, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 2
          end
        end
      end

      groups do
        group :addresses do
          fields [:site_id, :kind, :from_path, :match_query, :from_query, :to]

          ui do
            columns 1
            class ""
          end
        end

        group :behaviour do
          fields [:status, :active]

          ui do
            columns 2
            class ""
          end
        end

        group :details do
          fields [:description]
          collapsed true

          ui do
            label fn -> dgettext("mishka_gervaz", "Add a note") end
            columns 1
            class ""
          end
        end
      end

      presentation do
        features :all
      end

      hooks do
        on_init &Redirects.tick_match_query/2
        before_save fn params, _state -> Redirects.clear_unmatched_query(params) end
        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :from_path, :string, derives: "sanitize(trim) validate(string, not_empty, max_len=2000)"

    field :from_query, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=2000])"

    field :kind, :atom, derives: "validate(atom, enum=Atom[redirect::rewrite::gone::not_found])"

    field :to, :string, derives: "sanitize(trim) validate(optional=[string, max_len=2000])"

    field :status, :integer, derives: "validate(integer, enum=Integer[301::302::307::308])"
    field :active, :boolean, derives: "validate(boolean)"

    field :description, :string,
      derives: "sanitize(trim, no_control) validate(optional=[string, max_len=1000])"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate {TenantContext, require_master: false}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "Creates a redirect for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present([:site_id])

      validate {TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, Ash.Changeset.get_attribute(changeset, :site_id))
      end

      description "Creates a redirect for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      accept List.delete(@admin_fields, :site_id)

      validate {TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit an archived redirect. Restore it first.")
      end

      description "Updates a redirect for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit an archived redirect. Restore it first.")
      end

      # The version is written under the rule's own site.
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      description "Updates a redirect for master users - bypasses multi-tenancy, prevents site_id changes"
    end

    read :master_read do
      multitenancy :bypass

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {TenantContext, require_master: true}

      description "Reads every site's redirects (master users)"
    end

    read :master_get do
      get? true
      multitenancy :bypass

      validate {TenantContext, require_master: true}

      description "Retrieves one redirect by ID, bypassing tenant filtering (master users)"
    end

    # THE CACHE'S OWN READ, and nobody else's — see the `:read_any` policy below. Keyset, because
    # `MishkaCmsCore.Runtime.States.RedirectsState` streams the whole table through it at boot.
    read :read_any do
      multitenancy :bypass
      pagination keyset?: true, offset?: true, required?: false

      description "Every live redirect in the system, for loading the ETS cache"
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {TenantContext, require_master: false}

      description "Lists archived redirects within the current tenant"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {TenantContext, require_master: true}

      description "Lists every site's archived redirects (master users)"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {TenantContext, require_master: false}

      description "Retrieves one archived redirect (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {TenantContext, require_master: true}

      description "Retrieves one archived redirect (master users)"
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      validate {TenantContext, require_master: false}

      description "Archives a redirect (tenant users)"
    end

    destroy :master_destroy do
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      description "Archives a redirect (master users)"
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      atomic_upgrade_with :archived

      description "Restores an archived redirect (tenant users)"
    end

    update :master_unarchive do
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "This redirect is not archived.")
      end

      change set_attribute(:archived_at, nil)
      atomic_upgrade_with :master_archived

      description "Restores an archived redirect (master users)"
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {TenantContext, require_master: false}

      description "Permanently removes a redirect and its versions (tenant users)"
    end

    destroy :master_permanent_destroy do
      multitenancy :bypass
      require_atomic? false

      validate {TenantContext, require_master: true}

      description "Permanently removes a redirect and its versions (master users)"
    end
  end

  policies do
    # REACHED ONLY WITH `authorize?: false`: `RedirectsState` loads through it at boot. An actor is
    # refused outright rather than trusted to be the system.
    policy action(:read_any) do
      forbid_if always()
    end

    # A SITE'S ADDRESSES ARE CONTENT: anyone under the request's surface reads them, and writing them
    # takes the redirect section, `admin:<surface>:runtime:redirect`.
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if {AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:redirect",
                      "admin:api:runtime:redirect"
                    ]}

      forbid_unless action_type(:read)
      authorize_if {AccessPermissions, under: :surface}
    end

    # WHOSE ROWS, held to the actor when it runs: a master (`site_id` nil) reaches any site's rules, a
    # site user its own site's, whatever tenant it passed.
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  # `RedirectsState` listens on the topics without a site; the dashboard on the site's own.
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "redirect"

    publish_all :create, [[nil, :site_id], "created"]
    publish_all :update, [[nil, :site_id], "updated"]
    publish_all :destroy, [[nil, :site_id], "destroyed"]
  end

  # BOTH ADDRESSES ARE WRITTEN AS THEY WILL BE MATCHED before anything checks them, so the rules below
  # compare what is stored.
  changes do
    change &Redirects.normalize/2, on: [:create, :update]
  end

  # Read as the action runs, so typing in the form costs no query.
  validations do
    validate present(:to),
      on: [:create, :update],
      where: [attribute_in(:kind, [:redirect, :rewrite])],
      message: dgettext_noop("errors", "Enter where this rule sends or serves the address.")

    validate &Redirects.check_target/2,
      on: [:create, :update],
      only_when_valid?: true,
      before_action?: true
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :from_path, :string do
      allow_nil? false
      public? true
      constraints max_length: 2000
      description "The address the rule answers, as normalize_path/1 writes it"
    end

    attribute :from_query, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000

      description "The query string the rule answers alone, as normalize_query/1 writes it; nil for any"
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :redirect
      constraints one_of: [:redirect, :rewrite, :gone, :not_found]

      description "What the rule answers: a redirect, a rewrite served at the same address, a 410 or a 404"
    end

    attribute :to, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000

      description "Where a redirect sends the visitor (a path on the site, or an absolute http(s) URL) or the path a rewrite serves; nil for a 410 or a 404"
    end

    attribute :status, :integer do
      allow_nil? false
      public? true
      default 301
      description "The HTTP status a redirect is answered with: 301, 302, 307 or 308"
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether the rule is served"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000
      description "Why the rule exists, for the people who keep it"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site the rule belongs to"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.Redirect.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  identities do
    identity :unique_from_path_per_site, [:site_id, :from_path, :from_query] do
      description "One live rule per address on a site"
      message dgettext_noop("errors", "This site already redirects that address.")
      all_tenants? true
      nils_distinct? false
    end
  end
end
