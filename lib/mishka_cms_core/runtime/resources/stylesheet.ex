# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Stylesheet do
  @moduledoc """
  Manages CSS stylesheets in the MishkaCMS runtime system.

  Stylesheets are runtime CSS content stored in the database — kit themes
  (e.g. Chelekom's `@theme` block + CSS variables), reusable utility
  layers, and per-site custom user CSS. Each row is inlined into the
  Tailwind v4 compilation pipeline at build_css_content_*. Order is
  controlled by `kind`:

    * `:app_base` — mirrors the developer's `assets/css/app.css`. First.
    * `:theme`    — `@theme {}` blocks and `:root` CSS variables. Must
                    come BEFORE Tailwind class generation references them.
    * `:base`     — kit-shipped utility layers, animations, etc.
    * `:custom`   — user-added overrides. Last (highest precedence).

  Multi-tenancy mirrors `JsHook` — `site_id == nil` is global (kit themes
  default here), `site_id == <uuid>` is scoped to one site (user
  customizations default here).
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

  @kind_badge %{
    colors: %{
      "app_base" => "bg-[#f2f1ec] text-[#8a877f]",
      "theme" => "bg-[#eef1fc] text-[#4f4bcc]",
      "base" => "bg-[#f4ecfb] text-[#7a5bd0]",
      "custom" => "bg-[#fbf1df] text-[#a5691a]"
    },
    labels: %{
      "app_base" => dgettext_noop("mishka_gervaz", "App base"),
      "theme" => dgettext_noop("mishka_gervaz", "Theme"),
      "base" => dgettext_noop("mishka_gervaz", "Base"),
      "custom" => dgettext_noop("mishka_gervaz", "Custom")
    },
    default_color: "bg-[#f2f1ec] text-[#8a877f]"
  }

  @format_badge %{
    colors: %{"css" => "bg-[#e6f6ee] text-[#177a53]"},
    labels: %{"css" => dgettext_noop("mishka_gervaz", "CSS")},
    default_color: "bg-[#f2f1ec] text-[#8a877f]"
  }

  postgres do
    table "stylesheets"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :name, "stylesheet_name_length_check",
        check: "length(name) >= 3 AND length(name) <= 100",
        message: dgettext_noop("errors", "Name must be between 3 and 100 characters.")

      check_constraint :content, "stylesheet_content_length_check",
        check: "length(content) >= 1",
        message: dgettext_noop("errors", "Content cannot be empty.")

      check_constraint :priority, "stylesheet_priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      check_constraint [:name, :content], "stylesheet_no_empty_strings",
        check: "name != '' AND content != ''",
        message: dgettext_noop("errors", "Name and content cannot be empty.")
    end

    custom_statements do
      statement :prevent_archived_stylesheet_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_stylesheet_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived stylesheet'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_stylesheet_updates();"
      end

      statement :prevent_archived_stylesheet_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_stylesheet_updates_trigger
          BEFORE UPDATE ON stylesheets
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_stylesheet_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_stylesheet_updates_trigger ON stylesheets;"
      end
    end
  end

  @admin_fields [
    :name,
    :description,
    :content,
    :format,
    :kind,
    :priority,
    :active,
    :permissions,
    :extra,
    :site_id
  ]

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
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.StylesheetPaperTrailMixin, :postgres, []}
  end

  json_api do
    type "stylesheet"
  end

  mishka_gervaz do
    table do
      identity do
        name :stylesheets
        route "/admin/stylesheets"
        stream_name :stylesheets
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

        column :stylesheet_info do
          static true
          requires [:name, :description]
          label fn -> dgettext("mishka_gervaz", "Stylesheet") end
          position :first

          render fn record ->
            assigns = %{name: record.name, description: record.description}

            ~H"""
            <.cell_stacked variant={:title} primary={@name} secondary={@description} />
            """
          end
        end

        column :kind do
          label fn -> dgettext("mishka_gervaz", "Kind") end
          sortable true

          ui do
            type :badge
            extra @kind_badge
          end
        end

        column :format do
          label fn -> dgettext("mishka_gervaz", "Format") end
          sortable true

          ui do
            type :badge
            extra @format_badge
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

          render fn value ->
            assigns = %{active: value}

            ~H"""
            <span
              :if={@active}
              class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#e6f6ee] px-[10px] py-[3px] text-[10px] font-bold text-[#177a53]"
            >
              <span class="size-[5px] rounded-full bg-[#1f9d6b]"></span>{dgettext("mishka_gervaz", "Active")}
            </span>
            <span
              :if={!@active}
              class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#f2f1ec] px-[10px] py-[3px] text-[10px] font-bold text-[#8a877f]"
            >
              <span class="size-[5px] rounded-full bg-[#a8a5a0]"></span>{dgettext("mishka_gervaz", "Inactive")}
            </span>
            """
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
        filter :search, :text do
          fields [:name, :description]

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
          options fn ->
            [
              {dgettext("mishka_gervaz", "App base"), :app_base},
              {dgettext("mishka_gervaz", "Theme"), :theme},
              {dgettext("mishka_gervaz", "Base"), :base},
              {dgettext("mishka_gervaz", "Custom"), :custom}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Select kind...")
            label fn -> dgettext("mishka_gervaz", "Kind") end
          end
        end

        filter :format, :select do
          options fn -> [{dgettext("mishka_gervaz", "CSS"), :css}] end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Select format...")
            label fn -> dgettext("mishka_gervaz", "Format") end
          end
        end

        filter :active, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Active") end
          end
        end

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

        filter :created_at, :date_range do
          source :inserted_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Created at") end
          end
        end
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
              RuntimeHelpers.writes?(state, "stylesheet")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :expand, type: :accordion

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this stylesheet?") end

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "stylesheet")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this stylesheet?") end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "stylesheet")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Permanently delete this stylesheet? This cannot be undone."
                  )

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "stylesheet")
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
          confirm: dgettext_noop("mishka_gervaz", "Archive selected stylesheets?"),
          restricted: true

        action :unarchive,
          handler: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected stylesheets?"),
          visible: :archived,
          restricted: true

        action :permanent_destroy,
          handler: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected stylesheets? This cannot be undone."
            ),
          visible: :archived,
          restricted: true
      end

      realtime do
        prefix "stylesheet"

        visible fn record, user ->
          is_nil(user.site_id) or is_nil(record.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "stylesheets"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No stylesheets found"),
                  icon: "hero-paint-brush"

      hooks do
        on_bulk_action_success :unarchive, fn summary, _state, socket ->
          msg =
            if summary.skipped_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Restored %{restored} stylesheet(s) as inactive — activate them to go live; skipped %{skipped} (a stylesheet with the same name already exists).",
                restored: summary.succeeded_count,
                skipped: summary.skipped_count
              )
            else
              dgettext(
                "mishka_gervaz",
                "Restored %{restored} stylesheet(s) as inactive — activate them to go live.",
                restored: summary.succeeded_count
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
        name :stylesheet_form
      end

      fields do
        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :kind do
          options fn ->
            [
              {dgettext("mishka_gervaz", "App base"), :app_base},
              {dgettext("mishka_gervaz", "Theme"), :theme},
              {dgettext("mishka_gervaz", "Base"), :base},
              {dgettext("mishka_gervaz", "Custom"), :custom}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Kind") end
          end
        end

        field :format do
          options fn -> [{dgettext("mishka_gervaz", "CSS"), :css}] end

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

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            span 2
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "CSS content") end
            rows 16
            span 2
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
            :kind,
            :format,
            :priority,
            :site_id,
            :active
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
      derives: "sanitize(no_zero_width, no_control) validate(string, not_empty, min_len=1)"

    field :format, :atom, derives: "validate(atom, enum=Atom[css])"

    field :kind, :atom, derives: "validate(atom, enum=Atom[app_base::theme::base::custom])"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"
    field :active, :boolean, derives: "validate(boolean)"
    field :extra, :map, derives: "validate(map)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"
  end

  field_policies do
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

      change MishkaCmsCore.Runtime.Resources.Changes.SiteFromTenant

      change slugify(:name, into: :name)

      description "Creates stylesheet for tenant users — auto-assigns site_id from tenant context"
    end

    create :master_create do
      validate present([:name, :content])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change MishkaCmsCore.Runtime.Resources.Changes.TenantFromSite

      change slugify(:name, into: :name)

      description "Creates stylesheet for master users — can create global (nil site_id) or site-specific rows"
    end

    update :update do
      primary? true
      require_atomic? false
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived stylesheet. Please unarchive it first."
                )
      end

      validate fn changeset, context ->
        sheet = changeset.data

        if !is_nil(context.tenant) do
          cond do
            is_nil(sheet.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot modify global stylesheet. Global stylesheets can only be modified by master users."
                 )}

            sheet.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot modify stylesheet from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change slugify(:name, into: :name)

      description "Updates stylesheet for tenant users"
    end

    update :master_update do
      description "Updates stylesheet for master users — bypasses tenant filter"
      accept @admin_fields
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # A record other records name moves only where they can still name it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                moves: true, label: dgettext_noop("errors", "stylesheet")}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived stylesheet. Please unarchive it first."
                )
      end

      change slugify(:name, into: :name)
    end

    read :get_any do
      description "Get single stylesheet by ID, bypasses multitenancy"
      get? true
      multitenancy :bypass
    end

    read :master_read do
      description "List all stylesheets system-wide (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Get single stylesheet by ID (master users)"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Get a single archived stylesheet (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Get a single archived stylesheet (master users)"
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "List archived stylesheets in tenant context"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "List all archived stylesheets system-wide"
    end

    read :for_tenant_with_globals do
      pagination offset?: true, default_limit: 100
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id (master only); ignored if a tenant is set"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "List stylesheets for tenant + globals"
    end

    read :get_for_tenant_with_globals do
      get? true
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Get a single stylesheet for tenant + globals"
    end

    read :get_with_versions do
      get? true
      description "Gets a single stylesheet with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        filtered_query =
          if !is_nil(context.tenant) do
            Ash.Query.filter(query, site_id == ^context.tenant or is_nil(site_id))
          else
            query
          end

        Ash.Query.load(filtered_query,
          sorted_versions:
            MishkaCmsCore.Runtime.Stylesheet.Version
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
      description "Gets a single stylesheet with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Stylesheet.Version
            |> Ash.Query.for_read(:sorted_versions, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
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
      description "List all stylesheets system-wide (TailwindCompiler uses this)"
    end

    read :for_compiler do
      description """
      Returns active stylesheets for CSS compilation, ordered by kind then
      priority. Pass :site_id to scope to one tenant; nil returns globals only.
      """

      multitenancy :bypass
      pagination keyset?: true, default_limit: 1000, required?: false

      argument :site_id, :uuid do
        allow_nil? true
        description "Tenant site_id; nil = globals only"
      end

      prepare {MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals, shape: :exact}

      prepare fn query, _context ->
        query
        |> Ash.Query.filter(active == true)
        |> Ash.Query.sort([:priority, :inserted_at])
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      atomic_upgrade_with :archived

      description "Restores an archived stylesheet as inactive — activate it to compile and go live (tenant users)"
    end

    update :master_unarchive do
      description "Restores an archived stylesheet as inactive — activate it to compile and go live (master users)"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Stylesheet is not archived.")}
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
           field: :archived_at,
           message: dgettext_noop("errors", "Stylesheet is already archived.")}
        else
          :ok
        end
      end

      validate fn changeset, context ->
        sheet = changeset.data

        if !is_nil(context.tenant) do
          cond do
            is_nil(sheet.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot archive global stylesheet. Global stylesheets can only be archived by master users."
                 )}

            sheet.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot archive stylesheet from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change set_attribute(:active, false)

      description "Soft-delete stylesheet by archiving (tenant users)"
    end

    destroy :master_destroy do
      description "Soft-delete stylesheet by archiving (master users)"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Stylesheet is already archived.")}
        else
          :ok
        end
      end

      change set_attribute(:active, false)
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, context ->
        sheet = changeset.data

        if !is_nil(context.tenant) do
          cond do
            is_nil(sheet.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot permanently delete global stylesheet. Only master users can."
                 )}

            sheet.site_id != context.tenant ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot permanently delete stylesheet from another site."
                 )}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      description "Permanently remove stylesheet (tenant users)"
    end

    destroy :master_permanent_destroy do
      description "Permanently remove stylesheet (master users) — irreversible"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING, its CSS included, needs the stylesheet section or code on the request's surface;
    # reading, above, is open to anyone under the surface.
    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:stylesheet",
                      "admin:api:runtime:stylesheet",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}

      # What the builder generates — reusable classes, element CSS, design tokens — every builder
      # shares, so whoever opens any builder writes it. The builder is on the dashboard alone.
      forbid_unless context_equals(:page_code, :builder)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      "admin:dashboard:runtime:layout",
                      "admin:dashboard:runtime:component",
                      "admin:dashboard:runtime:error_page"
                    ]}
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
    prefix "stylesheet"

    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  changes do
    change {Changes.SendToOban, []}, on: [:create, :update, :destroy]
  end

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
      description "Human-readable stylesheet name (slugified)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "Optional description of the stylesheet's purpose"
    end

    attribute :content, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: false
      description "Raw CSS content"
    end

    attribute :format, :atom do
      default :css
      public? true
      constraints one_of: [:css]

      description "Stylesheet format (only :css supported today; reserved for future :scss / :postcss)"
    end

    attribute :kind, :atom do
      default :custom
      allow_nil? false
      public? true
      constraints one_of: [:app_base, :theme, :base, :custom]

      description """
      Pipeline-ordering discriminator. Determines where the row's content
      is inlined relative to other CSS:

        * :app_base — mirrors disk app.css; one row recommended.
        * :theme    — @theme blocks and :root vars (Tailwind needs these
                      BEFORE generating utility classes).
        * :base     — kit-shipped CSS layers / utilities.
        * :custom   — user overrides; applied last.
      """
    end

    attribute :priority, :integer do
      default 0
      public? true
      constraints min: 0, max: 100

      description "Load order within the same kind (lower loads first, so a higher value wins on equal specificity)"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether this stylesheet is included in the compiled CSS"
    end

    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to access this stylesheet"
    end

    attribute :extra, :map do
      default %{}
      public? true
      description "Free-form metadata (kit name, kit version, etc.)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this stylesheet belongs to (nil for global)"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.Stylesheet.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    calculate :is_global, :boolean do
      description "Whether this stylesheet applies to all sites"
      public? true

      calculation fn records, _context ->
        Enum.map(records, fn s -> is_nil(s.site_id) end)
      end
    end

    calculate :kind_order, :integer do
      description "Numeric position in the CSS pipeline (lower = earlier)"
      public? true

      calculation fn records, _context ->
        Enum.map(records, fn s ->
          case s.kind do
            :app_base -> 0
            :theme -> 1
            :base -> 2
            :custom -> 3
          end
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Stylesheet name must be unique within a site (or globally if site_id is nil)"
      message dgettext_noop("errors", "Stylesheet name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end

  @doc """
  The sort key deciding which sheet wins when two of them set the same thing.

  CSS is last-wins at equal specificity, so every component of this key ASCENDS: whichever sheet
  sorts last is the one the browser obeys. `priority` says so itself — *lower loads first, so a
  higher value wins* — and `:for_compiler` already sorted by it that way.

  Both consumers then re-sorted on `-priority`, which emitted the highest value FIRST and therefore
  let the LOWEST one win. They agreed with each other, so nothing looked wrong: Studio showed the
  same value the page rendered. Both were the opposite of what an operator setting `priority: 90`
  asked for, and there was no way to find that out except by reading two sorts in two modules.

  Owning the key here is what keeps them from drifting apart again — `TailwindCompiler` decides what
  the browser sees and `PageBuilder.Tokens` decides what Studio shows, and they must not disagree.

  A global sheet sorts before the site's own, so a site can always override what it inherited.
  """
  @spec load_order(struct()) :: {integer(), integer(), integer()}
  def load_order(%{kind: kind, site_id: site_id, priority: priority}),
    do: {kind_rank(kind), scope_rank(site_id), priority}

  defp kind_rank(:app_base), do: 0
  defp kind_rank(:theme), do: 1
  defp kind_rank(:base), do: 2
  defp kind_rank(:custom), do: 3
  defp kind_rank(_other), do: 4

  defp scope_rank(nil), do: 0
  defp scope_rank(_site_id), do: 1
end
