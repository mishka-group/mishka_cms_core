# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.JsHook do
  @moduledoc """
  Manages JavaScript and TypeScript hooks in the MishkaCMS runtime system.

  This resource handles client-side code hooks that can be dynamically injected into pages
  for enhanced interactivity and custom behaviors. JS hooks support both JavaScript and
  TypeScript formats, can be scoped globally or to specific sites, and are loaded based
  on priority ordering. Each hook contains executable code that integrates with the
  Phoenix LiveView hook system or runs as standalone scripts.

  The resource implements activation/deactivation controls allowing hooks to be temporarily
  disabled without deletion, and soft deletion through archival for recovery capabilities.
  Hooks automatically trigger background compilation jobs when modified, ensuring optimized
  delivery to client browsers. Priority-based loading ensures critical hooks execute first.

  Database-level constraints prevent empty content and modifications to archived hooks,
  while multi-tenant support ensures proper isolation between sites. The resource provides
  specialized queries for retrieving active hooks with global fallback, making it easy
  to gather all applicable hooks for a given site context.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshSlug,
      AshPaperTrail.Resource,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1]
  require Ash.Query
  alias MishkaCmsCore.Runtime.Resources.Changes
  alias MishkaCmsCore.Runtime.Helpers, as: RuntimeHelpers
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # Database configuration for JS hook storage
  postgres do
    table "js_hooks"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :name, "js_hook_name_length_check",
        check: "length(name) >= 3 AND length(name) <= 100",
        message: dgettext_noop("errors", "Name must be between 3 and 100 characters.")

      check_constraint :content, "js_hook_content_length_check",
        check: "length(content) >= 1",
        message: dgettext_noop("errors", "Content cannot be empty.")

      check_constraint :priority, "js_hook_priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      # Ensure name and content are not empty strings
      check_constraint [:name, :content], "js_hook_no_empty_strings",
        check: "name != '' AND content != ''",
        message: dgettext_noop("errors", "Name and content cannot be empty.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_js_hook_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_js_hook_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived JS hook'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_js_hook_updates();"
      end

      statement :prevent_archived_js_hook_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_js_hook_updates_trigger
          BEFORE UPDATE ON js_hooks
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_js_hook_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_js_hook_updates_trigger ON js_hooks;"
      end
    end
  end

  @admin_fields [
    :name,
    :description,
    :content,
    :format,
    :priority,
    :active,
    :lazy,
    :permissions,
    :npm,
    :modules,
    :site_id
  ]

  # Soft deletion configuration using archived_at timestamp
  archive do
    exclude_read_actions [
      :archived,
      :get_archived,
      :master_get_archived,
      :master_get,
      :master_archived,
      :get_any
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  # Version control configuration for full js_hook history tracking
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

    belongs_to_actor :user, MishkaCmsCore.Accounts.User, domain: MishkaCmsCore.Accounts

    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.JsHookPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "js_hook"
  end

  mishka_gervaz do
    table do
      identity do
        name :js_hooks
        route "/admin/js_hooks"
        stream_name :js_hooks
      end

      source do
        actions do
          read {:master_read, :for_tenant_with_globals}
          get {:master_get, :get_for_tenant_with_globals}
          destroy {:master_destroy, :destroy}
        end

        preload do
          always [:site]
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        column :js_hook_info do
          static true
          requires [:name, :description]
          label fn -> dgettext("mishka_gervaz", "JS Hook") end
          position :first

          render fn record ->
            assigns = %{name: record.name, description: record.description}

            ~H"""
            <.cell_stacked variant={:title} primary={@name} secondary={@description} />
            """
          end
        end

        column :format do
          label fn -> dgettext("mishka_gervaz", "Format") end
          sortable true

          ui do
            type :badge

            extra %{
              colors: %{
                "js" => "bg-[#fbf1df] text-[#a5691a]",
                "ts" => "bg-[#eaf1fb] text-[#3a6cb5]"
              },
              labels: %{
                "js" => dgettext_noop("mishka_gervaz", "JavaScript"),
                "ts" => dgettext_noop("mishka_gervaz", "TypeScript")
              },
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
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

        column :site_info do
          static true
          requires [:site_id, :site]
          label fn -> dgettext("mishka_gervaz", "Site") end
          position :last

          render fn record ->
            assigns = %{global?: is_nil(record.site_id), name: record.site && record.site.name}

            ~H"""
            <MishkaCmsCore.CoreComponents.site_cell global?={@global?} name={@name} />
            """
          end
        end
      end

      filters do
        filter :search, :text, fields: [:name, :description]

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

        filter :format, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "JavaScript"), :js},
              {dgettext("mishka_gervaz", "TypeScript"), :ts}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Select format...")
            label fn -> dgettext("mishka_gervaz", "Format") end
          end
        end

        filter :active, :boolean

        filter :global_only, :boolean do
          virtual true

          apply fn query, value, _assigns ->
            if value do
              Ash.Query.filter(query, is_nil(site_id))
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Global Only") end
          end
        end

        filter :created_at, :date_range, source: :inserted_at
      end

      row_actions do
        action :preview_modal do
          type :event
          event "show_preview_modal"

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "View") end
            icon "hero-eye"
          end
        end

        action :edit do
          type :event
          event "edit_preview_modal"

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "js_hook")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :expand, type: :accordion

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this JS hook?") end

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "js_hook")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this JS hook?") end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "js_hook")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Permanently delete this JS hook? This cannot be undone.")
          end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "js_hook")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete permanently") end
            icon "hero-trash"
          end
        end
      end

      row do
        selectable true

        class do
          possible ["bg-purple-50"]
          apply fn record -> if is_nil(record.site_id), do: "bg-purple-50" end
        end
      end

      bulk_actions do
        action :archive,
          handler: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected JS hooks?"),
          restricted: true

        action :unarchive,
          handler: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected JS hooks?"),
          visible: :archived,
          restricted: true

        action :permanent_destroy,
          handler: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected JS hooks? This cannot be undone."
            ),
          visible: :archived,
          restricted: true
      end

      realtime do
        prefix "js_hook"

        visible fn record, user ->
          is_nil(user.site_id) or is_nil(record.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "js_hooks"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No JS hooks found"),
                  icon: "hero-code-bracket"

      hooks do
        on_bulk_action_success :unarchive, fn summary, _state, socket ->
          msg =
            if summary.skipped_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Restored %{succeeded} JS hook(s) as inactive — activate them to go live; skipped %{skipped} (a JS hook with the same name already exists).",
                succeeded: summary.succeeded_count,
                skipped: summary.skipped_count
              )
            else
              dgettext(
                "mishka_gervaz",
                "Restored %{succeeded} JS hook(s) as inactive — activate them to go live.",
                succeeded: summary.succeeded_count
              )
            end

          socket
          |> MishkaGervaz.Table.Web.Events.BulkActionHooks.put_flash(:info, msg)
          |> MishkaGervaz.Table.Web.Events.BulkActionHooks.silence()
        end

        on_row_action_success :unarchive, fn _record, _state, socket ->
          Phoenix.LiveView.put_flash(
            socket,
            :info,
            dgettext("mishka_gervaz", "Restored as inactive — activate it to go live.")
          )
        end
      end
    end

    form do
      identity do
        name :js_hook_form
      end

      fields do
        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :format do
          options fn ->
            [
              {dgettext("mishka_gervaz", "JavaScript"), :js},
              {dgettext("mishka_gervaz", "TypeScript"), :ts}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Format") end
          end
        end

        field :priority do
          ui do
            label fn -> dgettext("mishka_gervaz", "Priority") end
          end
        end

        field :site_id, :relation do
          resource MishkaCmsCore.Runtime.Site
          display_field :name
          search_field :name
          mode :search
          min_chars 1
          page_size 15
          restricted true
          show_on :create
          include_nil fn -> dgettext("mishka_gervaz", "Global (no site)") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :active do
          ui do
            label fn -> dgettext("mishka_gervaz", "Active") end
          end
        end

        field :lazy do
          ui do
            label fn -> dgettext("mishka_gervaz", "Load on first use") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Keeps this hook out of the site's script: a page downloads it only when it shows an element that uses it. For a large hook few pages use."
              )
            end
          end
        end

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            span 2
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Content (JavaScript/TypeScript)") end
            rows 12
            span 2

            # A REAL EDITOR, not a textarea: this field is the hook's JavaScript, and it was being
            # written in a box with no line numbers, no bracket matching and no colour.
            # `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` is what reads this.
            extra %{code: "js"}
          end
        end

        field :permissions do
          add_label fn -> dgettext("mishka_gervaz", "Add Permission") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Permissions") end
            placeholder "permission.string"
          end
        end
      end

      groups do
        group :basic_info do
          fields [
            :name,
            :format,
            :priority,
            :site_id,
            :active,
            :lazy
          ]

          ui do
            columns 2
            class ""
          end
        end

        group :content do
          fields [:description, :content]

          ui do
            columns 1
            class ""
          end
        end

        group :data do
          fields [:permissions]

          ui do
            columns 1
            class ""
          end
        end
      end

      presentation do
        features :all

        # For `textarea/1` only — the adapter falls back to Tailwind for everything else. It is what
        # turns the `content` field's `extra %{code: "js"}` into a real editor.
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
      derives: "sanitize(trim) validate(string, not_empty, min_len=3, max_len=100)"

    field :description, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :content, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(string, not_empty, min_len=1)"

    field :format, :atom, derives: "validate(atom, enum=Atom[js::ts])"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"
    field :active, :boolean, derives: "validate(boolean)"
    field :lazy, :boolean, derives: "validate(boolean)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields for version management
    field_policy [:version_count, :latest_version, :recent_versions] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # All other fields are publicly accessible
    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present([:name, :content])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change fn changeset, context ->
        if !is_nil(context.tenant) do
          Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
        else
          changeset
        end
      end

      change slugify(:name, into: :name)

      description "Creates JS hook for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present([:name, :content])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)

        if !is_nil(site_id) do
          Ash.Changeset.set_tenant(changeset, site_id)
        else
          changeset
        end
      end

      change slugify(:name, into: :name)

      description "Creates JS hook for master users - can create global (nil site_id) or site-specific hooks"
    end

    update :update do
      primary? true
      require_atomic? false
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived JS hook. Please unarchive it first."
                )
      end

      # Prevent tenant from modifying global js_hooks
      validate fn changeset, context ->
        js_hook = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(js_hook.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot modify global JS hook. Global JS hooks can only be modified by master users."
                 )}

            js_hook.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot modify JS hook from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change slugify(:name, into: :name)

      description "Updates JS hook for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates JS hook for master users - requires nil tenant context"
      accept @admin_fields
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # A record other records name moves only where they can still name it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                moves: true, label: dgettext_noop("errors", "JS hook")}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived JS hook. Please unarchive it first."
                )
      end

      change slugify(:name, into: :name)
    end

    read :get_any do
      description "Retrieves single JS hook by ID, bypassing tenant filtering for admin operations"
      get? true
      multitenancy :bypass
    end

    read :master_read do
      description "Reads all JS hooks system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single JS hook by ID, bypassing tenant filtering (master users)"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived JS hook for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived JS hook for recovery or inspection (master users)"
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived JS hooks within current tenant context"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived JS hooks system-wide, bypassing tenant filtering"
    end

    read :for_tenant_with_globals do
      pagination offset?: true, default_limit: 100
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to filter by (only for master users)"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Lists JsHooks for a specific tenant including global JsHooks, or filtered by site_id for master users"
    end

    read :get_for_tenant_with_globals do
      get? true
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to filter by (only for master users)"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Gets a single JsHook for a specific tenant including global JsHooks, or filtered by site_id for master users"
    end

    read :get_with_versions do
      get? true
      description "Gets a single js_hook with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        # Filter by tenant: show site's js_hooks plus global ones
        filtered_query =
          if !is_nil(context.tenant) do
            Ash.Query.filter(query, site_id == ^context.tenant or is_nil(site_id))
          else
            query
          end

        Ash.Query.load(filtered_query,
          sorted_versions:
            MishkaCmsCore.Runtime.JsHook.Version
            |> Ash.Query.for_read(:sorted_versions, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :master_get_with_versions do
      get? true
      multitenancy :bypass
      description "Gets a single js_hook with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.JsHook.Version
            |> Ash.Query.for_read(:sorted_versions, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      atomic_upgrade_with :archived

      description "Restores an archived JS hook as inactive — activate it to compile and go live (tenant users)"
    end

    update :master_unarchive do
      description "Restores an archived JS hook as inactive — activate it to compile and go live (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "JS hook is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      atomic_upgrade_with :master_archived
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "JS hook is already archived.")}
        else
          :ok
        end
      end

      # Prevent tenant from archiving global js_hooks
      validate fn changeset, context ->
        js_hook = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(js_hook.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot archive global JS hook. Global JS hooks can only be archived by master users."
                 )}

            js_hook.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot archive JS hook from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change set_attribute(:active, false)

      description "Soft deletes JS hook by archiving (tenant users)"
    end

    destroy :master_destroy do
      description "Soft deletes JS hook by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "JS hook is already archived.")}
        else
          :ok
        end
      end

      change set_attribute(:active, false)
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Prevent tenant from permanently deleting global js_hooks
      validate fn changeset, context ->
        js_hook = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(js_hook.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot permanently delete global JS hook. Global JS hooks can only be deleted by master users."
                 )}

            js_hook.site_id != context.tenant ->
              {:error,
               message:
                 dgettext_noop("errors", "Cannot permanently delete JS hook from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      description "Permanently removes JS hook and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes JS hook and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
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
      pagination keyset?: true, default_limit: 1000, required?: false
      description "Lists all JsHooks system-wide for administrative operations"
    end

    action :restore_version_api, :struct do
      description "Restores js_hook content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.JsHook

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        js_hook_id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaCmsCore.Runtime.JsHook, js_hook_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, js_hook} when not is_nil(js_hook) ->
            # Check tenant access: can access own site's js_hooks or global ones
            can_access =
              cond do
                is_nil(acting_site) -> false
                is_nil(js_hook.site_id) -> true
                js_hook.site_id == acting_site -> true
                true -> false
              end

            # Check if tenant can modify (not just access)
            can_modify =
              cond do
                is_nil(acting_site) -> false
                # Cannot modify global js_hooks
                is_nil(js_hook.site_id) -> false
                js_hook.site_id == acting_site -> true
                true -> false
              end

            cond do
              not can_access ->
                {:error,
                 Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}

              not can_modify ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :site_id,
                       message:
                         dgettext_noop(
                           "errors",
                           "Cannot restore version of global js_hook. Global js_hooks can only be modified by master users."
                         )
                     )
                   ]
                 )}

              !is_nil(js_hook.archived_at) ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :archived_at,
                       message:
                         dgettext_noop(
                           "errors",
                           "Cannot restore version of archived js_hook. Please unarchive it first."
                         )
                     )
                   ]
                 )}

              true ->
                tenant = js_hook.site_id

                case Ash.get(MishkaCmsCore.Runtime.JsHook.Version, version_id,
                       action: :get_any,
                       authorize?: false
                     ) do
                  {:ok, version} when not is_nil(version) ->
                    if version.version_source_id != js_hook_id do
                      {:error,
                       Ash.Error.Invalid.exception(
                         errors: [
                           Ash.Error.Changes.InvalidAttribute.exception(
                             field: :version_id,
                             message:
                               dgettext_noop("errors", "Version does not belong to this js_hook.")
                           )
                         ]
                       )}
                    else
                      js_hook
                      |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                        tenant: tenant,
                        authorize?: false
                      )
                      |> Ash.update()
                    end

                  _ ->
                    {:error,
                     Ash.Error.Query.NotFound.exception(
                       resource: MishkaCmsCore.Runtime.JsHook.Version
                     )}
                end
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}
        end
      end
    end

    update :restore_version do
      accept []
      require_atomic? false

      argument :version_id, :uuid do
        allow_nil? false
        description "The ID of the version to restore"
      end

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived js_hook. Please unarchive it first."
                )
      end

      # A MISSING TENANT IS NOT A MASTER, and neither is anything that is not a site user. Without a
      # tenant, only a master (`site_id` nil) or the system (`authorize?: false`) restores; with one,
      # whoever acts on that site restores its js_hooks alone. See
      # `MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acts_on?/2`.
      validate fn changeset, context ->
        case MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acts_on?(
               context,
               changeset.data.site_id
             ) do
          true ->
            :ok

          false ->
            {:error,
             message:
               dgettext_noop(
                 "errors",
                 "Cannot restore version of js_hook from another site."
               )}
        end
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.JsHook.Version}

      description "Restores the js_hook to a previous version"
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.JsHook

      argument :js_hook_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        js_hook_id = input.arguments.js_hook_id
        version_id = input.arguments.version_id

        with {:ok, js_hook} when not is_nil(js_hook) <-
               Ash.get(MishkaCmsCore.Runtime.JsHook, js_hook_id,
                 action: :get_any,
                 authorize?: false
               ),
             # Check tenant access
             :authorized <-
               (cond do
                  is_nil(acting_site) -> :not_authorized
                  is_nil(js_hook.site_id) -> :authorized
                  js_hook.site_id == acting_site -> :authorized
                  true -> :not_authorized
                end),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.JsHook.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == js_hook_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.JsHook
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_js_hook =
            Enum.reduce(restored_attrs, js_hook, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)

                value =
                  if key_atom == :format and is_binary(value),
                    do: String.to_atom(value),
                    else: value

                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_js_hook}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this js_hook.")
                 )
               ]
             )}

          :not_authorized ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}
        end
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a js_hook with pagination (tenant users)"

      argument :js_hook_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        js_hook_id = Ash.Query.get_argument(query, :js_hook_id)

        # Verify the js_hook belongs to the tenant or is global
        case Ash.get(MishkaCmsCore.Runtime.JsHook, js_hook_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, js_hook} ->
            # Check access: tenant can access their own js_hooks or global ones
            can_access =
              cond do
                is_nil(acting_site) -> false
                is_nil(js_hook.site_id) -> true
                js_hook.site_id == acting_site -> true
                true -> false
              end

            if can_access do
              query
              |> Ash.Query.filter(id == ^js_hook_id)
              |> Ash.Query.load(
                sorted_versions:
                  MishkaCmsCore.Runtime.JsHook.Version
                  |> Ash.Query.for_read(:sorted_versions)
              )
            else
              Ash.Query.add_error(
                query,
                Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)
              )
            end

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a js_hook with pagination (master users)"

      argument :js_hook_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        js_hook_id = Ash.Query.get_argument(query, :js_hook_id)

        query
        |> Ash.Query.filter(id == ^js_hook_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.JsHook.Version
            |> Ash.Query.for_read(:sorted_versions)
        )
      end
    end

    action :master_restore_version, :struct do
      description "Restores js_hook content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.JsHook

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        js_hook_id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaCmsCore.Runtime.JsHook, js_hook_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, js_hook} when not is_nil(js_hook) ->
            if !is_nil(js_hook.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived js_hook. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = js_hook.site_id

              case Ash.get(MishkaCmsCore.Runtime.JsHook.Version, version_id,
                     action: :get_any,
                     authorize?: false
                   ) do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != js_hook_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop("errors", "Version does not belong to this js_hook.")
                         )
                       ]
                     )}
                  else
                    js_hook
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.JsHook.Version
                   )}
              end
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.JsHook

      argument :js_hook_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        js_hook_id = input.arguments.js_hook_id
        version_id = input.arguments.version_id

        with {:ok, js_hook} when not is_nil(js_hook) <-
               Ash.get(MishkaCmsCore.Runtime.JsHook, js_hook_id,
                 action: :get_any,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.JsHook.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == js_hook_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.JsHook
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_js_hook =
            Enum.reduce(restored_attrs, js_hook, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)

                value =
                  if key_atom == :format and is_binary(value),
                    do: String.to_atom(value),
                    else: value

                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_js_hook}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this js_hook.")
                 )
               ]
             )}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.JsHook)}
        end
      end
    end
  end

  # Authorization policies for JS hook access. A hook's content is JavaScript shipped into the site's
  # bundle, written by whoever writes the rest of the row. Cross-site and global hooks also require a
  # master.
  policies do
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING, its code included, needs the JS hook section or code on the request's surface;
    # reading, above, is open to anyone under the surface.
    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:js_hook",
                      "admin:api:runtime:js_hook",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}
    end

    policy action([:restore_version_api, :master_restore_version]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:js_hook",
                      "admin:api:runtime:js_hook",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}
    end

    # A RESTORE WRITES THE RECORD, so it is held to the actor at the moment it runs: a master
    # (`site_id` nil) restores any site's record, a site user only its own site's, whatever it holds
    # and whichever tenant it passed. The API and master wrappers restore as the system.
    policy action(:restore_version) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
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

  # Real-time update notifications
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "js_hook"

    # Publish to both global and site-specific topics using [nil, :site_id]:
    # - nil site_id → "js_hook:created" only
    # - uuid site_id → "js_hook:created" AND "js_hook:{uuid}:created"
    # This allows master users to see everything via global topic
    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Background job triggers for JS hook processing
  changes do
    change {Changes.SendToOban, []}, on: [:create, :update, :destroy]
  end

  # What the JavaScript compiler fetches and writes to disk for this hook.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.HookPackages, []},
      on: [:create, :update]
  end

  # Multi-tenancy configuration using site_id attribute
  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 100, trim?: true
      description "Human-readable JS hook name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "Optional description of the JS hook's purpose"
    end

    attribute :content, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true
      description "JavaScript/TypeScript code content"
    end

    attribute :format, :atom do
      default :js
      public? true
      constraints one_of: [:js, :ts]
      description "Code format (js for JavaScript, ts for TypeScript)"
    end

    attribute :priority, :integer do
      default 0
      public? true
      constraints min: 0, max: 100
      description "Priority for hook loading (higher = more priority)"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the hook is active and should be loaded"
    end

    # A LAZY HOOK IS NOT IN THE SITE'S BUNDLE. The bundle carries a stub under the same browser name,
    # and the stub downloads the hook from its own content-addressed file the first time an element
    # mounts it — see `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler`.
    attribute :lazy, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether the hook is left out of the site's bundle and downloaded on first use"
    end

    # ACL
    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to access this JS hook"
    end

    # THE PACKAGES THIS HOOK IMPORTS, as its kit pinned them: the whole tree, each entry with its
    # place in `node_modules`, exact version and integrity hash. The JavaScript compiler fetches
    # them once — see `MishkaCmsCore.Runtime.Compilers.NpmPackages`.
    attribute :npm, {:array, :map} do
      default []
      public? true
      description "npm packages this hook imports: name, version, path and integrity"
    end

    # THE FILES THIS HOOK IMPORTS BESIDE ITSELF — `%{"file" => "chart_extensions.js", "content" => …}`
    # — written next to it at every compile. A kit ships their first content; once installed they
    # are the site's own, and a reinstall keeps them.
    attribute :modules, {:array, :map} do
      default []
      public? true
      description "Files this hook imports from beside itself, as file name and content"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this JS hook belongs to (nil for global hooks)"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.JsHook.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    calculate :is_global, :boolean do
      description "Determines if the JS hook is globally available across all sites"
      public? true

      calculation fn records, _context ->
        Enum.map(records, fn hook -> is_nil(hook.site_id) end)
      end
    end

    calculate :file_extension, :string do
      description "Returns the appropriate file extension based on format (.js or .ts)"
      public? true
      calculation fn records, _context -> Enum.map(records, &".#{&1.format}") end
    end

    calculate :version_preview,
              :map,
              {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
               version: MishkaCmsCore.Runtime.JsHook.Version} do
      public? true
      argument :version_id, :uuid, allow_nil?: false

      description "Retrieves content from one of this record's own versions for preview before restoration"
    end

    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in js_hook history"

      calculation fn records, _context ->
        Enum.map(records, fn js_hook ->
          case MishkaCmsCore.Runtime.JsHook.Version
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(version_source_id == ^js_hook.id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.JsHook.Version
      description "Returns the most recent version for the js_hook"

      calculation fn records, _context ->
        js_hook_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.JsHook.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^js_hook_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn js_hook ->
          Map.get(versions_map, js_hook.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.JsHook.Version]

      description "Returns the 10 most recent versions for the js_hook in descending order by insertion date"

      calculation fn records, _context ->
        js_hook_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.JsHook.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^js_hook_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn js_hook ->
          Map.get(versions_map, js_hook.id, [])
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures JS hook names are unique within each site for clear identification"
      message dgettext_noop("errors", "JS hook name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end
end
