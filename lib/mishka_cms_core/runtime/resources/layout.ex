defmodule MishkaCmsCore.Runtime.Layout do
  @moduledoc """
  Manages layout templates in the MishkaCMS runtime system.

  This resource handles the creation and management of layout templates that provide consistent
  structure and styling across pages. Layouts serve as wrappers for page content, defining
  common elements like headers, footers, navigation, and resource links. Each layout can be
  scoped to a specific site or made globally available, with path-based matching determining
  which layout applies to which pages based on URL patterns.

  Layouts support dynamic content sections, external resource management (CSS, JavaScript),
  and comprehensive SEO tag configuration. They integrate with the runtime compiler to generate
  optimized template modules that render efficiently. The resource implements helper functions
  for dynamic behavior, precompilation options for performance optimization, and priority-based
  matching when multiple layouts could apply to the same path.

  Database-level constraints ensure data integrity including path validation and prevention
  of modifications to archived layouts. The resource provides soft deletion through archival,
  allowing layouts to be temporarily disabled and later restored. Multi-tenant support ensures
  proper isolation between sites while allowing shared global layouts for common functionality.
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
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  require Ash.Query
  alias MishkaCmsCore.Runtime.Resources.Changes
  alias MishkaCmsCore.Runtime.Helpers, as: RuntimeHelpers
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @format_badge %{
    colors: %{
      "heex" => "bg-[#f1edfb] text-[#7a5bd0]",
      "eex" => "bg-[#eaf1fb] text-[#3a6cb5]",
      "markdown" => "bg-[#eaf6ee] text-[#177a53]"
    },
    labels: %{
      "heex" => dgettext_noop("mishka_gervaz", "Heex"),
      "eex" => dgettext_noop("mishka_gervaz", "EEx"),
      "markdown" => dgettext_noop("mishka_gervaz", "Markdown")
    },
    default_color: "bg-[#f2f1ec] text-[#8a877f]"
  }

  @doc """
  Format → badge colours and labels, in the shape the Gervaz `:badge` column type expects. Shared by the
  Format table column and the layout detail modal so both draw the same badge from one definition.
  """
  def format_badge_config do
    Map.update!(@format_badge, :labels, fn labels ->
      Map.new(labels, fn {key, label} ->
        {key, Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)}
      end)
    end)
  end

  @admin_fields [
    :name,
    :path,
    :description,
    :template,
    :format,
    :priority,
    :extra,
    :content,
    :resource_links,
    :seo_tags,
    :helpers,
    :active,
    :precompile,
    :permissions,
    :site_id,
    :example
  ]

  @doc "Unguessable token for the shareable preview URL (generated on create)."
  def generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  # Database configuration for layout storage
  postgres do
    table "layouts"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 3 AND length(name) <= 200",
        message: dgettext_noop("errors", "Title must be between 3 and 200 characters.")

      check_constraint :path, "path_length_check",
        check: "length(path) >= 1 AND length(path) <= 255",
        message: dgettext_noop("errors", "Path must be between 1 and 255 characters.")

      check_constraint :template, "template_length_check",
        check: "length(template) >= 1",
        message: dgettext_noop("errors", "Template must have at least 1 character.")

      check_constraint :priority, "priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      # Multiple attributes can share the same constraint
      check_constraint [:name, :path, :template], "no_empty_strings",
        check: "name != '' AND path != '' AND template != ''",
        message: dgettext_noop("errors", "Title, path, and template cannot be empty.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_layout_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_layout_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived layout'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_layout_updates();"
      end

      statement :prevent_archived_layout_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_layout_updates_trigger
          BEFORE UPDATE ON layouts
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_layout_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_layout_updates_trigger ON layouts;"
      end
    end
  end

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

  # Version control configuration for full layout history tracking
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
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.LayoutPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "layout"
  end

  mishka_gervaz do
    table do
      identity do
        name :layouts
        route "/admin/layouts"
        stream_name :layouts
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

        column :layout_info do
          static true
          requires [:id, :name]
          label fn -> dgettext("mishka_gervaz", "Layout") end
          position :first

          render fn record ->
            short_id = String.slice(record.id, 0, 8) <> "…" <> String.slice(record.id, -4, 4)
            assigns = %{name: record.name, id: record.id, short_id: short_id}

            ~H"""
            <div class="min-w-0">
              <div class="text-[13.5px] font-semibold text-[#17161a]">{@name}</div>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">{@short_id}</span>
                <.copy_button
                  id={"layout-id-copy-#{@id}"}
                  value={@id}
                  label={dgettext("mishka_gervaz", "Copy layout ID")}
                />
              </div>
            </div>
            """
          end
        end

        column :path_section do
          static true
          requires [:path, :description]
          label fn -> dgettext("mishka_gervaz", "Path & Section") end

          render fn record ->
            assigns = %{path: record.path, description: record.description}

            ~H"""
            <div class="min-w-0">
              <div class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#3a382f]">{@path}</div>
              <div :if={@description} class="mt-[2px] truncate text-[11px] font-medium text-[#a8a5a0]">
                {@description}
              </div>
            </div>
            """
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

        column :active_compile do
          static true
          requires [:active, :precompile]
          label fn -> dgettext("mishka_gervaz", "Active & Compile") end

          render fn record ->
            assigns = %{active: record.active, precompile: record.precompile}

            ~H"""
            <div class="flex flex-col gap-[5px]">
              <span
                :if={@active}
                class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#e6f6ee] px-[10px] py-[3px] text-[10px] font-bold text-[#177a53]"
              >
                <span class="size-[5px] rounded-full bg-[#1f9d6b]"></span>{dgettext("mishka_gervaz", "Active")}
              </span>
              <span
                :if={not @active}
                class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#f2f1ec] px-[10px] py-[3px] text-[10px] font-bold text-[#8a877f]"
              >
                <span class="size-[5px] rounded-full bg-[#a8a5a0]"></span>{dgettext(
                  "mishka_gervaz",
                  "Inactive"
                )}
              </span>
              <span class={[
                "inline-flex items-center gap-[5px] text-[10.5px] font-semibold",
                if(@precompile, do: "text-[#177a53]", else: "text-[#a8a5a0]")
              ]}>
                <svg
                  width="12"
                  height="12"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  class="shrink-0"
                >
                  <path :if={@precompile} d="M20 6 9 17l-5-5" />
                  <path :if={not @precompile} d="M18 6 6 18M6 6l12 12" />
                </svg>
                {if(@precompile,
                  do: dgettext("mishka_gervaz", "Precompiled"),
                  else: dgettext("mishka_gervaz", "Not precompiled")
                )}
              </span>
            </div>
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
          fields [:name, :path, :description]

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

        filter :format, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "HEEx"), :heex},
              {dgettext("mishka_gervaz", "EEx"), :eex},
              {dgettext("mishka_gervaz", "Markdown"), :markdown}
            ]
          end

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

        filter :precompile, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Precompile") end
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
        action :expand, type: :accordion

        action :preview_modal do
          type :event
          event "show_preview_modal"
          visible :active

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
              RuntimeHelpers.writes?(state, "layout")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this layout?") end

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "layout")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this layout?") end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "layout")
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
                    "Permanently delete this layout? This cannot be undone."
                  )

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "layout")
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
          possible ["bg-[#f6f4fd]"]
          apply fn record -> if is_nil(record.site_id), do: "bg-[#f6f4fd]" end
        end
      end

      bulk_actions do
        action :archive,
          handler: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected layouts?"),
          restricted: true

        action :unarchive,
          handler: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected layouts?"),
          visible: :archived,
          restricted: true

        action :permanent_destroy,
          handler: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected layouts? This cannot be undone."
            ),
          visible: :archived,
          restricted: true
      end

      realtime do
        prefix "layout"

        visible fn record, user ->
          is_nil(user.site_id) or is_nil(record.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "layouts"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No layouts found"),
                  icon: "hero-rectangle-group"

      hooks do
        on_bulk_action_success :unarchive, fn summary, _state, socket ->
          msg =
            if summary.skipped_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Restored %{restored} layout(s) as inactive — activate them to go live; skipped %{skipped} (a layout with the same name already exists).",
                restored: summary.succeeded_count,
                skipped: summary.skipped_count
              )
            else
              dgettext(
                "mishka_gervaz",
                "Restored %{restored} layout(s) as inactive — activate them to go live.",
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
        name :layout_form
      end

      fields do
        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :path do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Path") end
            placeholder "/blog/*"
          end
        end

        field :format do
          options fn ->
            [
              {dgettext("mishka_gervaz", "HEEx"), :heex},
              {dgettext("mishka_gervaz", "EEx"), :eex},
              {dgettext("mishka_gervaz", "Markdown"), :markdown}
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

        field :precompile do
          ui do
            label fn -> dgettext("mishka_gervaz", "Precompile") end
          end
        end

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            span 2
          end
        end

        field :template, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Template") end
            rows 10
            span 2
          end
        end

        field :content, :json do
          ui do
            label fn -> dgettext("mishka_gervaz", "Content (JSON Object)") end
            placeholder ~s({"header": {...}, "footer": {...}})
            span 2
          end
        end

        # DRAWN AS ROWS, THE WAY THE PAGE'S ALREADY IS. It is the same column — `{:array, :map}`
        # constrained to type / href / rel / media / integrity / crossorigin / attrs, byte for byte
        # the one on `Page` — and that constraint is what makes Gervaz infer a nested editor. Only
        # this declaration said `:json`, so one identical column was a set of fields on a page and a
        # hand-typed array of objects here.
        #
        # Left to be INFERRED rather than declared `:nested`, exactly as the page leaves it, so the
        # sub-fields keep coming from the constraint instead of being listed a second time here and
        # drifting from it.
        field :resource_links do
          ui do
            label fn -> dgettext("mishka_gervaz", "Resource Links") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Resource Link") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
            span 2
          end
        end

        field :seo_tags, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "SEO Tags") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add SEO Tag") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
            span 2
          end

          nested_field :tag do
            ui do
              label fn -> dgettext("mishka_gervaz", "Tag") end
              placeholder "title, meta, link"
            end
          end

          nested_field :attrs, :json do
            ui do
              label fn -> dgettext("mishka_gervaz", "Attributes") end
              placeholder ~s({"name": "description", "property": "og:title"})
            end
          end

          nested_field :content, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Content") end
              placeholder fn -> dgettext("mishka_gervaz", "Tag content text...") end
              rows 3
            end
          end
        end

        field :helpers, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "Helper Functions") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Helper Function") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Function Name") end
              placeholder "my_helper"
            end
          end

          nested_field :args do
            ui do
              label fn -> dgettext("mishka_gervaz", "Arguments") end
              placeholder "arg1, arg2"
            end
          end

          nested_field :code, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Function Body") end
              placeholder ~s(arg1 <> " " <> arg2)
              rows 3
              class "font-mono text-sm"
            end
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
            :path,
            :format,
            :priority,
            :site_id,
            :active,
            :precompile
          ]

          ui do
            columns 2
            class ""
          end
        end

        group :content do
          fields [:description, :template]

          ui do
            columns 1
            class ""
          end
        end

        group :data do
          fields [
            :content,
            :resource_links,
            :seo_tags,
            :helpers,
            :permissions
          ]

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
      derives: "sanitize(trim) validate(string, not_empty, min_len=3, max_len=200)"

    field :path, :string,
      derives:
        ~S|sanitize(trim) validate(string, not_empty, min_len=1, max_len=255, regex=^(?!.*\.\.)/[a-zA-Z0-9/_*.:-]*$)|

    field :description, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :template, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(string, not_empty, min_len=3)"

    field :format, :atom, derives: "validate(atom, enum=Atom[heex::eex::markdown])"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"
    field :active, :boolean, derives: "validate(boolean)"
    field :precompile, :boolean, derives: "validate(boolean)"
    field :extra, :map, derives: "validate(map)"
    field :content, :map, derives: "validate(map)"

    field :example, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(optional=[string, min_len=3])"

    field :resource_links, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"
    field :helpers, {:array, :map}, derives: "validate(list)"

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
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      # Blank means "I will build it in the editor" — filled in before the validations below
      # ask for a template, so a layout can be created without anyone writing HEEx first, the way a
      # page and a component already could.
      change {MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty, starter: :layout}

      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present([:name, :path, :template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change fn changeset, context ->
        if !is_nil(context.tenant) do
          Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
        else
          changeset
        end
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      description "Creates layout for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      # Blank means "I will build it in the editor" — filled in before the validations below
      # ask for a template, so a layout can be created without anyone writing HEEx first, the way a
      # page and a component already could.
      change {MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty, starter: :layout}

      validate present([:name, :path, :template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)

        if !is_nil(site_id) do
          Ash.Changeset.set_tenant(changeset, site_id)
        else
          changeset
        end
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      description "Creates layout for master users - can create global (nil site_id) or site-specific layouts"
    end

    update :update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      primary? true
      require_atomic? false
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived layout. Please unarchive it first.")
      end

      # Prevent tenant from modifying global layouts
      validate fn changeset, context ->
        layout = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(layout.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot modify global layout. Global layouts can only be modified by master users."
                 )}

            layout.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot modify layout from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)

      description "Updates layout for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      description "Updates layout for master users - requires nil tenant context"
      accept @admin_fields
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived layout. Please unarchive it first.")
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      # A record other records name moves only where they can still name it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                moves: true, label: dgettext_noop("errors", "layout")}

      change slugify(:name, into: :name)
    end

    read :get_any do
      description "Retrieves single layout by ID, bypassing tenant filtering for admin operations"
      get? true
      multitenancy :bypass
    end

    read :master_read do
      description "Reads all layouts system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single layout by ID, bypassing tenant filtering (master users)"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_token do
      get? true
      multitenancy :bypass
      argument :preview_token, :string, allow_nil?: false
      filter expr(preview_token == ^arg(:preview_token))
      description "Resolve a live layout by its preview token (for the shareable preview URL)."
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves a single archived layout by ID for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived layout for recovery or inspection (master users)"
    end

    read :by_path do
      get_by [:path]

      prepare fn query, context ->
        tenant = context.tenant

        if is_nil(tenant),
          do: Ash.Query.filter(query, is_nil(site_id)),
          else: Ash.Query.filter(query, site_id == ^tenant)
      end

      description "Retrieves layout by exact path match, filtering by site based on tenant context"
    end

    read :for_tenant_with_globals do
      pagination offset?: true, default_limit: 100
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to filter by (only for master users)"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Lists layouts for a specific tenant including global layouts, or filtered by site_id for master users"
    end

    read :get_for_tenant_with_globals do
      get? true
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to filter by (only for master users)"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Gets a single layout for a specific tenant including global layouts, or filtered by site_id for master users"
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived layouts within current tenant context"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived layouts system-wide, bypassing tenant filtering"
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
      pagination keyset?: true, default_limit: 100
      description "Lists all layouts system-wide for administrative operations"
    end

    read :get_with_versions do
      get? true
      description "Gets a single layout with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        # Filter by tenant: show site's layouts plus global ones
        filtered_query =
          if !is_nil(context.tenant) do
            Ash.Query.filter(query, site_id == ^context.tenant or is_nil(site_id))
          else
            query
          end

        Ash.Query.load(filtered_query,
          sorted_versions:
            MishkaCmsCore.Runtime.Layout.Version
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
      description "Gets a single layout with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Layout.Version
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

      description "Restores an archived layout as inactive — activate it to compile and go live (tenant users)"
    end

    update :master_unarchive do
      description "Restores an archived layout as inactive — activate it to compile and go live (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Layout is not archived.")}
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
           field: :archived_at, message: dgettext_noop("errors", "Layout is already archived.")}
        else
          :ok
        end
      end

      # Prevent tenant from archiving global layouts
      validate fn changeset, context ->
        layout = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(layout.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot archive global layout. Global layouts can only be archived by master users."
                 )}

            layout.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot archive layout from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change set_attribute(:active, false)

      description "Soft deletes layout by archiving (tenant users)"
    end

    destroy :master_destroy do
      description "Soft deletes layout by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Layout is already archived.")}
        else
          :ok
        end
      end

      change set_attribute(:active, false)
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Prevent tenant from permanently deleting global layouts
      validate fn changeset, context ->
        layout = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(layout.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot permanently delete global layout. Global layouts can only be deleted by master users."
                 )}

            layout.site_id != context.tenant ->
              {:error,
               message:
                 dgettext_noop("errors", "Cannot permanently delete layout from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      description "Permanently removes layout and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes layout and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    action :restore_version_api, :struct do
      description "Restores layout content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.Layout

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        layout_id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaCmsCore.Runtime.Layout, layout_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, layout} when not is_nil(layout) ->
            # Check tenant access: can access own site's layouts or global ones
            can_access =
              cond do
                is_nil(acting_site) -> false
                is_nil(layout.site_id) -> true
                layout.site_id == acting_site -> true
                true -> false
              end

            # Check if tenant can modify (not just access)
            can_modify =
              cond do
                is_nil(acting_site) -> false
                # Cannot modify global layouts
                is_nil(layout.site_id) -> false
                layout.site_id == acting_site -> true
                true -> false
              end

            cond do
              not can_access ->
                {:error,
                 Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}

              not can_modify ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :site_id,
                       message:
                         dgettext_noop(
                           "errors",
                           "Cannot restore version of global layout. Global layouts can only be modified by master users."
                         )
                     )
                   ]
                 )}

              !is_nil(layout.archived_at) ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :archived_at,
                       message:
                         dgettext_noop(
                           "errors",
                           "Cannot restore version of archived layout. Please unarchive it first."
                         )
                     )
                   ]
                 )}

              true ->
                tenant = layout.site_id

                case Ash.get(MishkaCmsCore.Runtime.Layout.Version, version_id,
                       action: :get_any,
                       authorize?: false
                     ) do
                  {:ok, version} when not is_nil(version) ->
                    if version.version_source_id != layout_id do
                      {:error,
                       Ash.Error.Invalid.exception(
                         errors: [
                           Ash.Error.Changes.InvalidAttribute.exception(
                             field: :version_id,
                             message:
                               dgettext_noop("errors", "Version does not belong to this layout.")
                           )
                         ]
                       )}
                    else
                      layout
                      |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                        tenant: tenant,
                        authorize?: false
                      )
                      |> Ash.update()
                    end

                  _ ->
                    {:error,
                     Ash.Error.Query.NotFound.exception(
                       resource: MishkaCmsCore.Runtime.Layout.Version
                     )}
                end
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}
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
                  "Cannot restore version of archived layout. Please unarchive it first."
                )
      end

      # A MISSING TENANT IS NOT A MASTER, and neither is anything that is not a site user. Without a
      # tenant, only a master (`site_id` nil) or the system (`authorize?: false`) restores; with one,
      # whoever acts on that site restores its layouts alone. See
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
                 "Cannot restore version of layout from another site."
               )}
        end
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.Layout.Version}

      description "Restores the layout to a previous version"
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.Layout

      argument :layout_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        layout_id = input.arguments.layout_id
        version_id = input.arguments.version_id

        with {:ok, layout} when not is_nil(layout) <-
               Ash.get(MishkaCmsCore.Runtime.Layout, layout_id,
                 action: :get_any,
                 authorize?: false
               ),
             # Check tenant access
             :authorized <-
               (cond do
                  is_nil(acting_site) -> :not_authorized
                  is_nil(layout.site_id) -> :authorized
                  layout.site_id == acting_site -> :authorized
                  true -> :not_authorized
                end),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Layout.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == layout_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.Layout
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_layout =
            Enum.reduce(restored_attrs, layout, fn {key, value}, acc ->
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

          {:ok, preview_layout}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this layout.")
                 )
               ]
             )}

          :not_authorized ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}
        end
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a layout with pagination (tenant users)"

      argument :layout_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        layout_id = Ash.Query.get_argument(query, :layout_id)

        # Verify the layout belongs to the tenant or is global
        case Ash.get(MishkaCmsCore.Runtime.Layout, layout_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, layout} ->
            # Check access: tenant can access their own layouts or global ones
            can_access =
              cond do
                is_nil(acting_site) -> false
                is_nil(layout.site_id) -> true
                layout.site_id == acting_site -> true
                true -> false
              end

            if can_access do
              query
              |> Ash.Query.filter(id == ^layout_id)
              |> Ash.Query.load(
                sorted_versions:
                  MishkaCmsCore.Runtime.Layout.Version
                  |> Ash.Query.for_read(:sorted_versions)
              )
            else
              Ash.Query.add_error(
                query,
                Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)
              )
            end

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a layout with pagination (master users)"

      argument :layout_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        layout_id = Ash.Query.get_argument(query, :layout_id)

        query
        |> Ash.Query.filter(id == ^layout_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.Layout.Version
            |> Ash.Query.for_read(:sorted_versions)
        )
      end
    end

    action :master_restore_version, :struct do
      description "Restores layout content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Layout

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        layout_id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaCmsCore.Runtime.Layout, layout_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, layout} when not is_nil(layout) ->
            if !is_nil(layout.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived layout. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = layout.site_id

              case Ash.get(MishkaCmsCore.Runtime.Layout.Version, version_id,
                     action: :get_any,
                     authorize?: false
                   ) do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != layout_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop("errors", "Version does not belong to this layout.")
                         )
                       ]
                     )}
                  else
                    layout
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.Layout.Version
                   )}
              end
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Layout

      argument :layout_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        layout_id = input.arguments.layout_id
        version_id = input.arguments.version_id

        with {:ok, layout} when not is_nil(layout) <-
               Ash.get(MishkaCmsCore.Runtime.Layout, layout_id,
                 action: :get_any,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Layout.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == layout_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.Layout
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_layout =
            Enum.reduce(restored_attrs, layout, fn {key, value}, acc ->
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

          {:ok, preview_layout}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this layout.")
                 )
               ]
             )}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Layout)}
        end
      end
    end
  end

  # Authorization policies for layout access
  policies do
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if accessing_from(MishkaCmsCore.Runtime.Page, :pages)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING, its code included, needs the layout section or code on the request's surface;
    # reading, above, is open to anyone under the surface.
    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:layout",
                      "admin:api:runtime:layout",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}
    end

    policy action([:restore_version_api, :master_restore_version]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:layout",
                      "admin:api:runtime:layout",
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

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "layout"

    # Publish to both global and site-specific topics using [nil, :site_id]:
    # - nil site_id → "layout:created" only
    # - uuid site_id → "layout:created" AND "layout:{uuid}:created"
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

  changes do
    change Changes.RegisterTranslationKeys, on: [:create, :update]
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
      constraints min_length: 3, max_length: 200, trim?: true
      description "Human-readable layout name"
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL path pattern for this layout (e.g., '/blog/*', '/about')"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "Optional description of the layout's purpose"
    end

    attribute :template, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, trim?: true
      description "Template content (HTML, HEEx, etc.)"
    end

    attribute :format, :atom do
      default :heex
      public? true
      constraints one_of: [:heex, :eex, :markdown]
      description "Template format (heex, eex, markdown)"
    end

    attribute :priority, :integer do
      default 0
      public? true
      constraints min: 0, max: 100
      description "Priority for layout matching (higher = more priority)"
    end

    attribute :extra, :map do
      default %{}
      public? true
      description "Additional metadata or configuration"
    end

    # Layout specific attributes
    attribute :content, :map do
      default %{}
      public? true
      description "Content sections and their configurations"
    end

    attribute :example, :string do
      default nil
      allow_nil? true
      public? true
      constraints min_length: 3, trim?: true
      description "HTML example showing how to use this layout"
    end

    attribute :resource_links, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      type: [
                        type: :string,
                        allow_nil?: false
                      ],
                      href: [
                        type: :string,
                        allow_nil?: false
                      ],
                      rel: [
                        type: :string,
                        allow_nil?: true
                      ],
                      media: [
                        type: :string,
                        allow_nil?: true
                      ],
                      integrity: [
                        type: :string,
                        allow_nil?: true
                      ],
                      crossorigin: [
                        type: :string,
                        allow_nil?: true
                      ],
                      attrs: [
                        type: :map,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "External resource links (CSS, JS, fonts, etc.)"
    end

    attribute :seo_tags, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      tag: [
                        type: :string,
                        allow_nil?: false
                      ],
                      attrs: [
                        type: :map,
                        allow_nil?: false
                      ],
                      content: [
                        type: :string,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "SEO meta tags and structured data"
    end

    attribute :helpers, {:array, MishkaCmsCore.Runtime.Resources.Embeddeds.Helper} do
      default []
      public? true
      description "Helper function definitions for the layout"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the layout is active and available for use"
    end

    attribute :precompile, :boolean do
      default false
      public? true

      description "Whether to compile this resource immediately on application restart (true) or lazily on first use (false)"
    end

    # ACL
    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to access this layout"
    end

    attribute :preview_token, :string do
      allow_nil? false
      public? true
      description "Unguessable token for the shareable full-LiveView preview URL"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this layout belongs to (nil for global layouts)"
    end

    has_many :pages, MishkaCmsCore.Runtime.Page do
      public? true
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.Layout.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    calculate :is_global, :boolean do
      description "Determines if the layout is globally available across all sites"
      public? true

      calculation fn records, _context ->
        Enum.map(records, fn layout ->
          is_nil(layout.site_id)
        end)
      end
    end

    calculate :version_preview,
              :map,
              {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
               version: MishkaCmsCore.Runtime.Layout.Version} do
      public? true
      argument :version_id, :uuid, allow_nil?: false

      description "Retrieves content from one of this record's own versions for preview before restoration"
    end

    calculate :version_count, :integer do
      public? true

      calculation fn records, context ->
        Enum.map(records, fn layout ->
          case MishkaCmsCore.Runtime.Layout.Version
               |> Ash.Query.filter(version_source_id == ^layout.id)
               |> Ash.Query.set_tenant(layout.site_id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end

      description "Counts total number of versions in layout history"
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.Layout.Version
      description "Returns the most recent version for the layout"

      calculation fn records, _context ->
        layout_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Layout.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^layout_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn layout ->
          Map.get(versions_map, layout.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.Layout.Version]

      description "Returns the 10 most recent versions for the layout in descending order by insertion date"

      calculation fn records, _context ->
        layout_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Layout.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^layout_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn layout ->
          Map.get(versions_map, layout.id, [])
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures layout names are unique within each site for clear identification"
      message dgettext_noop("errors", "Layout name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_path_per_site, [:path, :site_id] do
      description "Prevents path conflicts by ensuring unique paths per site for proper routing"
      message dgettext_noop("errors", "Layout path must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_preview_token, [:preview_token] do
      description "Preview tokens are globally unique"
      message dgettext_noop("errors", "Preview token collision.")
      all_tenants? true
    end
  end
end
