defmodule MishkaCmsCore.Runtime.Site do
  @moduledoc """
  Manages sites in the MishkaCMS multi-tenant runtime system.

  This resource represents individual sites (tenants) in the CMS, each with its own domain,
  content, and configuration. Sites serve as the top-level organizational unit, containing
  pages, layouts, components, error pages, and JavaScript hooks. The host-based routing system
  uses priority ordering to determine which site handles incoming requests when multiple sites
  might match a domain pattern.

  Sites implement activation/deactivation controls allowing temporary disabling without data
  loss, and soft deletion through archival for recovery capabilities. Each site maintains
  relationships with all its associated resources, providing complete content isolation in
  the multi-tenant architecture. The resource enforces unique constraints on both site names
  and hosts to prevent conflicts.

  Database-level constraints ensure valid domain formats and prevent modifications to archived
  sites. When sites are modified, background jobs are triggered to recompile associated resources.
  The resource provides comprehensive access control through the policy system, ensuring proper
  authorization for site management operations.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshSlug,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Runtime.Resources.Changes
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @admin_fields [
    :name,
    :host,
    :priority,
    :active,
    :master,
    :mode,
    :frontend_domain,
    :allowed_origins
  ]

  @mode_badge %{
    colors: %{
      "api_only" => "bg-[#eef1fc] text-[#4f4bcc]",
      "hybrid" => "bg-[#f1edfb] text-[#7a5bd0]",
      "phoenix_only" => "bg-[#eaf6ee] text-[#177a53]"
    },
    labels: %{
      "api_only" => dgettext_noop("mishka_gervaz", "API Only"),
      "hybrid" => dgettext_noop("mishka_gervaz", "Hybrid"),
      "phoenix_only" => dgettext_noop("mishka_gervaz", "Phoenix Only")
    },
    default_color: "bg-[#f2f1ec] text-[#8a877f]"
  }

  @doc """
  Mode → badge colours and labels, in the shape the Gervaz `:badge` column type expects. Shared by the
  Mode table column and the site detail modal so both draw the same badge from one definition.
  """
  def mode_badge_config do
    Map.update!(@mode_badge, :labels, fn labels ->
      Map.new(labels, fn {key, label} ->
        {key, Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)}
      end)
    end)
  end

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  postgres do
    table "sites"
    repo @repo

    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 3 AND length(name) <= 70",
        message: dgettext_noop("errors", "Name must be between 3 and 70 characters.")

      check_constraint :host, "host_length_check",
        check: "length(host) >= 3 AND length(host) <= 200",
        message: dgettext_noop("errors", "Host must be between 3 and 200 characters.")

      check_constraint :priority, "priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      check_constraint :mode, "mode_values_check",
        check: "mode IN ('api_only', 'phoenix_only', 'hybrid')",
        message: dgettext_noop("errors", "Mode must be one of: api_only, phoenix_only, hybrid.")

      check_constraint [:name, :host], "no_empty_strings",
        check: "name != '' AND host != ''",
        message: dgettext_noop("errors", "Name and host cannot be empty.")
    end

    custom_statements do
      statement :prevent_archived_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_site_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived site'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_site_updates();"
      end

      statement :prevent_archived_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_updates_trigger
          BEFORE UPDATE ON sites
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_site_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_updates_trigger ON sites;"
      end

      statement :ensure_single_master_function do
        up """
        CREATE OR REPLACE FUNCTION ensure_single_master_site()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Only check if setting master to true
          IF NEW.master = true THEN
            -- Check if another master site already exists
            IF EXISTS (
              SELECT 1 FROM sites
              WHERE master = true
              AND id != NEW.id
              AND archived_at IS NULL
            ) THEN
              RAISE EXCEPTION 'Only one master site is allowed'
                USING ERRCODE = 'check_violation';
            END IF;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS ensure_single_master_site();"
      end

      statement :ensure_single_master_trigger do
        up """
        CREATE TRIGGER ensure_single_master_trigger
          BEFORE INSERT OR UPDATE ON sites
          FOR EACH ROW
          EXECUTE FUNCTION ensure_single_master_site();
        """

        down "DROP TRIGGER IF EXISTS ensure_single_master_trigger ON sites;"
      end

      statement :create_partial_unique_index_master do
        up """
        CREATE UNIQUE INDEX unique_master_site
        ON sites (master)
        WHERE master = true AND archived_at IS NULL;
        """

        down "DROP INDEX IF EXISTS unique_master_site;"
      end
    end
  end

  archive do
    exclude_read_actions [:archived, :get_archived, :get_any]
    exclude_destroy_actions [:permanent_destroy]
  end

  json_api do
    type "site"
  end

  mishka_gervaz do
    table do
      identity do
        name :sites
        route "/admin/sites"
        stream_name :sites
      end

      source do
        actions do
          read {:master_read, :tenant_read}
          get {:master_get, :tenant_get}
          destroy {:destroy, :destroy}
        end

        archive do
          restricted true
          read_action {:archived, :archived}
          get_action {:get_archived, :get_archived}
          restore_action {:unarchive, :unarchive}
          destroy_action {:permanent_destroy, :permanent_destroy}
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        # A site taken offline for maintenance carries a pill under its ID saying by which switch:
        # `MishkaCmsCore.Settings.offline_by/1`, two ETS reads a row. The width fits that pill on
        # the starred master row too.
        column :site_info do
          static true
          requires [:id, :name, :master]
          label fn -> dgettext("mishka_gervaz", "Site") end
          position :first

          ui do
            width "minmax(185px,1.7fr)"
          end

          render fn record ->
            id = to_string(record.id)

            short =
              if String.length(id) > 16,
                do: String.slice(id, 0, 8) <> "…" <> String.slice(id, -6, 6),
                else: id

            assigns = %{
              name: record.name,
              master: record.master,
              id: id,
              short: short,
              by: MishkaCmsCore.Settings.offline_by(record)
            }

            ~H"""
            <div class="flex items-center gap-[9px]">
              <svg
                :if={@master}
                width="15"
                height="15"
                viewBox="0 0 24 24"
                fill="#e6b422"
                stroke="#e6b422"
                stroke-width="1.4"
                stroke-linejoin="round"
                class="shrink-0"
              >
                <path d="M12 3l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9 6.8 19.2l1-5.8L3.5 9.2l5.9-.9z" />
              </svg>
              <div class="min-w-0">
                <div class="text-[13.5px] font-semibold text-[#17161a]">{@name}</div>
                <div class="mt-[2px] flex items-center gap-[5px]">
                  <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">{@short}</span>
                  <.copy_button
                    id={"site-id-copy-#{@id}"}
                    value={@id}
                    label={dgettext("mishka_gervaz", "Copy site ID")}
                  />
                </div>
                <div :if={@by != []} class="mt-[6px] flex">
                  <span
                    id={"site-offline-#{@id}"}
                    class="inline-flex items-center gap-[6px] rounded-[20px] bg-[#fbf1df] px-[9px] py-[3px] text-[11px] font-bold text-[#a5691a]"
                  >
                    <span class="size-[6px] rounded-full bg-[#cf8a24]"></span>
                    {if(:global in @by,
                      do: dgettext("mishka_gervaz", "Offline · Global"),
                      else: dgettext("mishka_gervaz", "Offline · Own switch")
                    )}
                  </span>
                </div>
              </div>
            </div>
            """
          end
        end

        column :mode do
          label fn -> dgettext("mishka_gervaz", "Mode") end
          sortable true

          ui do
            type :badge
            extra @mode_badge
          end
        end

        column :priority do
          label fn -> dgettext("mishka_gervaz", "Priority") end
          sortable true

          ui do
            type :bars
            extra %{max: 4, percent: true}
          end
        end

        column :active do
          label fn -> dgettext("mishka_gervaz", "Status") end
          sortable true

          ui do
            type :badge

            extra %{
              variant: :pill,
              colors: %{
                "true" => "bg-[#e6f6ee] text-[#177a53]",
                "false" => "bg-[#fbf1df] text-[#a5691a]"
              },
              labels: %{
                "true" => dgettext_noop("mishka_gervaz", "Active"),
                "false" => dgettext_noop("mishka_gervaz", "Inactive")
              },
              dots: %{"true" => "bg-[#1f9d6b]", "false" => "bg-[#cf8a24]"}
            }
          end
        end

        column :domain do
          static true
          requires [:mode, :frontend_domain, :host]
          label fn -> dgettext("mishka_gervaz", "Domain") end

          ui do
            width "minmax(135px,1.6fr)"
          end

          render fn record ->
            domain = record.frontend_domain || record.host

            url =
              cond do
                domain in [nil, ""] -> nil
                String.starts_with?(domain, "http") -> domain
                true -> "https://" <> domain
              end

            assigns = %{api_only?: record.mode == :api_only, url: url}

            ~H"""
            <div :if={@api_only?} class="flex items-center gap-[7px]">
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="#a8a5a0"
                stroke-width="1.7"
                stroke-linecap="round"
                stroke-linejoin="round"
                class="shrink-0"
              >
                <rect x="3" y="4" width="18" height="7" rx="1.5" />
                <rect x="3" y="13" width="18" height="7" rx="1.5" />
                <path d="M7 7.5h.01M7 16.5h.01" />
              </svg>
              <span class="text-[12.5px] font-medium text-[#3a382f]">
                {dgettext("mishka_gervaz", "API Only")}
              </span>
            </div>
            <div :if={not @api_only? and @url} class="flex items-center gap-[7px]">
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="#a8a5a0"
                stroke-width="1.7"
                stroke-linecap="round"
                stroke-linejoin="round"
                class="shrink-0"
              >
                <circle cx="12" cy="12" r="9" />
                <path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18" />
              </svg>
              <span class="truncate text-[12.5px] font-medium text-[#3a382f]">{@url}</span>
            </div>
            <span
              :if={not @api_only? and is_nil(@url)}
              class="font-['Space_Grotesk'] text-[13px] font-semibold text-[#a8a5a0]"
            >
              —
            </span>
            """
          end
        end

        column :allowed_origins do
          label fn -> dgettext("mishka_gervaz", "Origins") end

          ui do
            type :tags
            width "minmax(105px,1.2fr)"

            extra %{max_items: 1, empty: "—"}
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:name, :host]
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :mode, :select do
          restricted true

          options fn ->
            [
              {dgettext("mishka_gervaz", "API Only"), :api_only},
              {dgettext("mishka_gervaz", "Phoenix Only"), :phoenix_only},
              {dgettext("mishka_gervaz", "Hybrid"), :hybrid}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Select mode...")
            label fn -> dgettext("mishka_gervaz", "Mode") end
          end
        end

        filter :active, :boolean do
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Active") end
          end
        end

        filter :master, :boolean do
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Master") end
          end
        end

        filter :created_at, :date_range do
          source :inserted_at
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Created at") end
          end
        end
      end

      row_actions do
        action :preview_modal do
          type :event
          event "show_site_modal"
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "View") end
            icon "hero-eye"
          end
        end

        action :edit do
          type :event
          event "edit_site_modal"
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :expand, type: :accordion

        # Never on the master site: archiving it would lock every master out.
        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this site?") end

          visible fn record, state ->
            state.archive_status == :active and record.master != true
          end

          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          restricted true
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this site?") end
          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Permanently delete this site? This cannot be undone."
                  )

          visible :archived
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete permanently") end
            icon "hero-trash"
          end
        end
      end

      row do
        selectable true

        class do
          possible ["bg-[#fdf9ec]"]
          apply fn record -> if record.master, do: "bg-[#fdf9ec]" end
        end
      end

      bulk_actions do
        action :activate,
          handler: :activate,
          confirm: dgettext_noop("mishka_gervaz", "Activate selected sites?"),
          restricted: true

        action :deactivate,
          handler: :deactivate,
          confirm: dgettext_noop("mishka_gervaz", "Deactivate selected sites?"),
          restricted: true

        action :archive,
          handler: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected sites?"),
          restricted: true

        action :unarchive,
          handler: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected sites?"),
          visible: :archived,
          restricted: true

        action :permanent_destroy,
          handler: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected sites? This cannot be undone."
            ),
          visible: :archived,
          restricted: true
      end

      realtime do
        prefix "site"

        visible fn record, user ->
          is_nil(user.site_id) or record.id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "sites"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No sites found"),
                  icon: "hero-globe-alt"
    end

    form do
      identity do
        name :site_form
      end

      source do
        access :create, restricted: true

        actions do
          create {:create, :create}
          update {:update, :update}
          read {:master_get, :tenant_get}
        end
      end

      fields do
        field :name do
          required true
          readonly fn state -> !state.master_user? end

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :host do
          required true
          readonly fn state -> !state.master_user? end

          ui do
            label fn -> dgettext("mishka_gervaz", "Host") end
          end
        end

        field :priority do
          readonly fn state -> !state.master_user? end

          ui do
            label fn -> dgettext("mishka_gervaz", "Priority") end
          end
        end

        field :mode do
          readonly fn state -> !state.master_user? end

          options fn ->
            [
              {dgettext("mishka_gervaz", "API Only"), :api_only},
              {dgettext("mishka_gervaz", "Phoenix Only"), :phoenix_only},
              {dgettext("mishka_gervaz", "Hybrid"), :hybrid}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Mode") end
          end
        end

        field :active do
          readonly fn state -> !state.master_user? end

          ui do
            label fn -> dgettext("mishka_gervaz", "Active") end
          end
        end

        field :frontend_domain do
          readonly fn state -> !state.master_user? end

          ui do
            label fn -> dgettext("mishka_gervaz", "Frontend Domain") end
          end
        end

        field :allowed_origins do
          readonly fn state -> !state.master_user? end
          add_label fn -> dgettext("mishka_gervaz", "Add Origin") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Allowed Origins") end
            placeholder "https://example.com"
          end
        end

        field :master do
          readonly fn state -> !state.master_user? end

          ui do
            label fn -> dgettext("mishka_gervaz", "Master Site") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:name, :host, :priority]

          ui do
            columns 3
          end
        end

        group :settings do
          fields [:mode, :active, :master]

          ui do
            columns 3
          end
        end

        group :domain_config do
          fields [:frontend_domain, :allowed_origins]

          ui do
            columns 2
          end
        end
      end

      presentation do
        features :all
        debounce 300
      end

      hooks do
        on_validate fn params, state ->
          updated_params =
            case get_in(params, ["form", "mode"]) do
              "phoenix_only" ->
                params
                |> put_in(["form", "frontend_domain"], "")
                |> put_in(["form", "allowed_origins"], [])

              _ ->
                params
            end

          MishkaGervaz.Helpers.validate_field_errors(
            state.form.source,
            updated_params,
            state.errors
          )
        end

        on_cancel fn state -> state end
      end

      submit do
        create disabled: fn state -> !state.master_user? end
        update disabled: fn state -> !state.master_user? end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=3, max_len=70)"

    field :host, :string,
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, min_len=3, max_len=200, hostname)"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"
    field :active, :boolean, derives: "validate(boolean)"
    field :master, :boolean, derives: "validate(boolean)"

    field :mode, :atom, derives: "validate(atom, enum=Atom[api_only::phoenix_only::hybrid])"

    field :frontend_domain, :string, derives: "sanitize(trim, downcase)"

    field :allowed_origins, {:array, :string},
      derives:
        "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list, each=[regex=^https?://[a-z0-9.-]+(:[0-9]+)?(/.*)?$])"
  end

  actions do
    default_accept @admin_fields

    # Site declares no `multitenancy` block, so nothing scopes these two on its own — they used to
    # return every site to any actor the policies admit. The filter says: a MASTER (site_id nil)
    # sees all, a TENANT sees only its own. A nil actor — an internal call, seeds, boot — reads
    # `is_nil(nil)` as true and is unaffected, which matters because preparations run even under
    # `authorize?: false`.
    #
    # The `:tenant_read`/`:tenant_get` variants below still exist and are what the admin UI maps a
    # tenant to; this makes the primaries agree with them instead of quietly being wider.
    read :read do
      primary? true

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      prepare build(filter: expr(is_nil(^actor(:site_id)) or id == ^actor(:site_id)))
      description "Default list action for reading sites"
    end

    read :get do
      get? true

      prepare build(filter: expr(is_nil(^actor(:site_id)) or id == ^actor(:site_id)))
      description "Default get action for reading a single site"
    end

    read :tenant_read do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare build(filter: expr(id == ^actor(:site_id)))
      description "Lists sites for tenant users (filtered to their own site)"
    end

    read :tenant_get do
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare build(filter: expr(id == ^actor(:site_id)))
      description "Gets a single site for tenant users (their own site only)"
    end

    read :master_read do
      multitenancy :bypass

      pagination offset?: true,
                 keyset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all sites system-wide, bypassing tenant filtering (master users only)"
    end

    read :master_get do
      multitenancy :bypass
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single site by ID, bypassing tenant filtering (master users only)"
    end

    read :get_any do
      multitenancy :bypass
      get? true

      description "Retrieves a single site by ID, archived included: any site for a master or a system call (authorize?: false), a site user's own site only"
    end

    read :read_any do
      multitenancy :bypass

      description "Retrieves sites across every tenant, excluding archived ones: every site for a master or a system call (authorize?: false), a site user's own site only. Every belongs_to :site reads through it. Use :get_any to reach an archived site."
    end

    read :get_archived do
      multitenancy :bypass
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived site for recovery or inspection (master users only)"
    end

    read :archived do
      multitenancy :bypass
      pagination offset?: true, default_limit: 100
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived sites for bulk recovery management (master users only)"
    end

    create :create do
      primary? true

      validate present([:name])
      validate present([:host])
      validate {MishkaCmsCore.Runtime.Resources.Validations.DomainValidator, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays, on: :create}

      change slugify(:name, into: :name)

      description "Creates site with validated name and host domain, ensuring unique identification"
    end

    update :update do
      primary? true
      require_atomic? false

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived site. Please unarchive it first.")
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.DomainValidator, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays, on: :update}

      change slugify(:name, into: :name)

      description "Updates active site configuration (master users only)"
    end

    update :activate do
      accept []
      require_atomic? false

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot activate archived site. Please unarchive it first."
                )
      end

      change set_attribute(:active, true)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Enables a site to handle incoming requests and serve content (master users only)"
    end

    update :deactivate do
      accept []
      require_atomic? false

      validate MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays

      change set_attribute(:active, false)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Disables a site without archiving, temporarily preventing access (master users only)"
    end

    update :unarchive do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, nil)

      # A RESTORED MASTER KEEPS ITS FLAG ONLY WHILE NO LIVE SITE HOLDS ONE. An archived site keeps the
      # flag it was archived with and `:set_as_master` passes it over, so once another site was made
      # master the `ensure_single_master_site` trigger refused this restore for good.
      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          import Ecto.Query

          site_id = changeset.data.id

          taken? =
            changeset.data.master == true and
              from(s in "sites",
                where:
                  s.master == true and s.id != type(^site_id, :binary_id) and
                    is_nil(s.archived_at)
              )
              |> @repo.exists?()

          if taken?,
            do: Ash.Changeset.force_change_attribute(changeset, :master, false),
            else: changeset
        end)
      end

      atomic_upgrade_with :archived

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Restores archived site to active status, enabling modifications (master users only)"
    end

    update :set_as_master do
      accept []
      require_atomic? false

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot set archived site as master.")
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays, on: :set_as_master}

      # THE OTHER MASTER LOSES ITS FLAG IN A BEFORE-ACTION, once this write is validated and
      # authorized and inside its transaction. Run while the changeset was being built, it took the
      # flag off the live master even when the write was then refused — an archived site, or an actor
      # who may not make one master.
      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:master, true)
        |> Ash.Changeset.before_action(fn changeset ->
          import Ecto.Query

          site_id = changeset.data.id

          # LIVE SITES ONLY. An archived site keeps the flag it was archived with, and the
          # `prevent_archived_site_updates` trigger refuses any write to it but its restore, so one
          # archived master in this statement failed it and no site could be made master.
          from(s in "sites",
            where:
              s.master == true and s.id != type(^site_id, :binary_id) and is_nil(s.archived_at),
            update: [set: [master: false]]
          )
          |> @repo.update_all([])

          changeset
        end)
      end

      description "Sets this site as the master site, removing master status from any other site (master users only)"
    end

    update :unset_as_master do
      accept []
      require_atomic? false

      validate MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays

      change set_attribute(:master, false)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Removes master status from this site (master users only)"
    end

    destroy :destroy do
      description "Soft deletes site by archiving (master users only)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
      validate MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
      validate MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays

      change {Changes.ScheduleSiteTeardown, []}

      description "Permanently removes site and all associated data (master users only) - extremely destructive operation"
    end
  end

  policies do
    # The site of an account the caller reached through another resource and may not see. A filter
    # policy, so the load answers with no site rather than failing the request.
    policy MishkaCmsCore.Accounts.Checks.AccountWithheld do
      forbid_if always()
    end

    # THE SITES SCREEN AND SITE DATA ARE THE SITE SECTION'S: `admin:<surface>:runtime:site` reads and
    # writes sites. The site a record belongs to is another thing: every `belongs_to :site` reads
    # through `:read_any`/`:get_any`, and those answer anyone under the request's surface, so a page or
    # a post still names its site to an admin without the site section.
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:runtime:site", "admin:api:runtime:site"]}

      forbid_unless action([:read_any, :get_any])
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # EVERY READ REACHES EVERY SITE FOR A MASTER ALONE — the bypass reads and the primary ones, whose
    # own filter reads an actor with no `site_id` as a master. A master (`site_id` nil) reads any
    # site; a site user, whatever it holds, reads its own site and no other — which is all a
    # `belongs_to :site` on its own records asks for. An account's own site loads with it, as the
    # policy above lets it. Anybody else reads none. System calls pass `authorize?: false`.
    policy action_type(:read) do
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "site"

    publish :create, ["created"]
    publish :update, [[nil, :_pkey], "updated"]
    publish :activate, [[nil, :_pkey], "updated"]
    publish :deactivate, [[nil, :_pkey], "updated"]
    publish :unarchive, [[nil, :_pkey], "updated"]
    publish :destroy, [[nil, :_pkey], "destroyed"]
    publish :permanent_destroy, [[nil, :_pkey], "destroyed"]
  end

  changes do
    change {Changes.ScheduleSiteRuntime, []}, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 70, trim?: true

      description "Human-readable site name"
    end

    attribute :host, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
      description "Domain name for the site (e.g., example.com)"
    end

    attribute :priority, :integer do
      default 0
      public? true
      constraints min: 0, max: 100
      description "Priority for site routing (higher = more priority)"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the site is currently active"
    end

    attribute :mode, :atom do
      default :hybrid
      public? true
      constraints one_of: [:api_only, :phoenix_only, :hybrid]

      description "Site operation mode: 'api_only' (headless), 'phoenix_only' (LiveView only), 'hybrid' (both API and LiveView)"
    end

    attribute :frontend_domain, :string do
      allow_nil? true
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
      description "Frontend application domain for API-only sites (e.g., app.example.com)"
    end

    attribute :allowed_origins, {:array, :string} do
      default []
      public? true
      description "Additional allowed CORS origins for API access"
    end

    attribute :master, :boolean do
      default false
      public? true
      description "Whether this site is the master site (only one allowed)"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    has_many :users, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      public? true
    end

    has_many :components, MishkaCmsCore.Runtime.Component do
      public? true
    end

    has_many :error_pages, MishkaCmsCore.Runtime.ErrorPage do
      public? true
    end

    has_many :js_hooks, MishkaCmsCore.Runtime.JsHook do
      public? true
    end

    has_many :layouts, MishkaCmsCore.Runtime.Layout do
      public? true
    end

    has_many :pages, MishkaCmsCore.Runtime.Page do
      public? true
    end
  end

  identities do
    identity :unique_name, [:name] do
      description "Ensures site names are globally unique for clear identification"
      message dgettext_noop("errors", "Site name must be unique.")
    end

    identity :unique_host, [:host] do
      description "Prevents host conflicts ensuring proper domain-based routing"
      message dgettext_noop("errors", "Host must be unique.")
    end
  end
end
