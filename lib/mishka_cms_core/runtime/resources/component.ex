# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Component do
  @moduledoc """
  Manages reusable UI components in the MishkaCMS runtime system.

  This resource handles the lifecycle of dynamically compiled UI components that can be shared across
  different sites in a multi-tenant environment. Components are template-based building blocks supporting
  HEEx, EEx, and Markdown formats, with the ability to define custom attributes, slots, and helper functions.
  Each component can be scoped to a specific site or made globally available.

  The resource implements soft deletion through archival, allowing components to be recovered after deletion.
  It enforces strict validation rules including name uniqueness per site, template presence, and priority
  ordering for rendering sequences. Components automatically trigger background compilation jobs when
  created, updated, or destroyed, integrating seamlessly with the runtime compiler system.

  Database-level constraints and triggers ensure data integrity, particularly preventing modifications
  to archived components except for unarchiving operations. The resource supports permission-based
  access control and maintains full audit trails through timestamps.
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

  @type_badge %{
    colors: %{
      "general" => "bg-[#eef1fc] text-[#4f4bcc]",
      "forms" => "bg-[#eaf6ee] text-[#177a53]",
      "navigations" => "bg-[#fbf1df] text-[#c17d1a]",
      "overlays" => "bg-[#fbe8f0] text-[#c94f86]",
      "feedback" => "bg-[#e6f1fa] text-[#2f86c4]",
      "media" => "bg-[#f1edfb] text-[#7a5bd0]"
    },
    labels: %{
      "general" => dgettext_noop("mishka_gervaz", "General"),
      "forms" => dgettext_noop("mishka_gervaz", "Forms"),
      "navigations" => dgettext_noop("mishka_gervaz", "Navigations"),
      "overlays" => dgettext_noop("mishka_gervaz", "Overlays"),
      "feedback" => dgettext_noop("mishka_gervaz", "Feedback"),
      "media" => dgettext_noop("mishka_gervaz", "Media")
    },
    default_color: "bg-[#f2f1ec] text-[#8a877f]"
  }

  # THE VOCABULARY PHOENIX ACCEPTS FOR `attr :name, <type>`, read from the one module that already
  # had to know it: `MishkaCmsCore.Runtime.PageBuilder.Interface` refuses anything outside this list
  # at the action boundary, and it is asked for in two places in this form — a component's own
  # attributes and a slot's. Written out again here, the form would sooner or later offer a type the
  # validation then rejects.
  @attr_types Enum.map(
                MishkaCmsCore.Runtime.PageBuilder.Interface.types(),
                &{Phoenix.Naming.humanize(&1), &1}
              )

  @admin_fields [
    :name,
    :description,
    :template,
    :body,
    :format,
    :priority,
    :extra,
    :attrs,
    :slots,
    :helpers,
    :active,
    :precompile,
    :required,
    :stateful,
    :permissions,
    :examples,
    :type,
    :dependencies,
    :site_id
  ]

  # Database configuration for component storage
  postgres do
    table "components"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 3 AND length(name) <= 100",
        message: dgettext_noop("errors", "Name must be between 3 and 100 characters.")

      check_constraint :template, "template_length_check",
        check: "length(template) >= 1",
        message: dgettext_noop("errors", "Template must have at least 1 character.")

      check_constraint :priority, "priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      # Multiple attributes can share the same constraint
      check_constraint [:name, :template], "no_empty_strings",
        check: "name != '' AND template != ''",
        message: dgettext_noop("errors", "Name and template cannot be empty.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_component_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived component'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_component_updates();"
      end

      statement :prevent_archived_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_updates_trigger
          BEFORE UPDATE ON components
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_component_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_updates_trigger ON components;"
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

  # Version control configuration for full component history tracking
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
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.ComponentPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "component"
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :components
        route "/admin/components"
        stream_name :components
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

        column :component_info do
          static true
          requires [:id, :name]
          label fn -> dgettext("mishka_gervaz", "Component") end
          position :first

          ui do
            width "minmax(150px,1.4fr)"
          end

          render fn record ->
            short_id = String.slice(record.id, 0, 8) <> "…" <> String.slice(record.id, -4, 4)
            assigns = %{name: record.name, id: record.id, short_id: short_id}

            ~H"""
            <div class="min-w-0">
              <div class="text-[13.5px] font-semibold text-[#17161a]">{@name}</div>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">{@short_id}</span>
                <.copy_button
                  id={"component-id-copy-#{@id}"}
                  value={@id}
                  label={dgettext("mishka_gervaz", "Copy component ID")}
                />
              </div>
            </div>
            """
          end
        end

        column :type do
          label fn -> dgettext("mishka_gervaz", "Type") end
          sortable true

          ui do
            type :badge
            extra @type_badge
            width "minmax(110px,0.9fr)"
          end
        end

        column :format do
          label fn -> dgettext("mishka_gervaz", "Format") end
          sortable true

          ui do
            type :badge
            extra @format_badge
            width "minmax(95px,0.8fr)"
          end
        end

        column :priority do
          label fn -> dgettext("mishka_gervaz", "Priority") end
          sortable true

          ui do
            type :bars
            extra %{max: 4, percent: true}
            width "minmax(105px,0.9fr)"
          end
        end

        # WHAT KIND OF COMPONENT THIS ROW IS. Two components in one list, one of which answers
        # clicks and holds state and one of which structurally cannot, used to look identical — and
        # the difference decides whether a page can use it for anything interactive. Beside the
        # name, because that is where a reader is already looking.
        column :kind_dependencies do
          static true

          # `id` IS REQUIRED BECAUSE THE CELL USES IT. A column's render function is handed a map of
          # exactly the fields it declares here and nothing else, so reading `record.id` without
          # asking for it raises `key :id not found` on every row — which takes the LiveView down,
          # reconnects, and takes it down again.
          requires [:stateful, :dependencies, :id]
          label fn -> dgettext("mishka_gervaz", "Kind & Dependencies") end

          ui do
            width "minmax(150px,1.2fr)"
          end

          # THE TAGS ARE GERVAZ'S OWN CELL, not chips written a second time here. `type :tags` is what
          # this column had before the merge, and it brings a `+N` expand toggle, `max_items`, an
          # empty placeholder and the adapter's theming with it — all of which hand-rolled markup
          # throws away. Only the arrangement around the cell is this column's.
          render fn record ->
            items = record.dependencies |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
            max_items = 2

            assigns = %{
              stateful: record.stateful == true,
              tags: %{
                __changed__: %{},
                id: tags_dom_id(record),
                shown: Enum.take(items, max_items),
                rest: Enum.drop(items, max_items),
                more: max(0, length(items) - max_items),
                badge_class: nil,
                empty: nil
              }
            }

            ~H"""
            <div class="flex flex-col gap-[5px]">
              <span
                :if={@stateful}
                data-role="component-kind"
                data-kind="live"
                title={
                  dgettext(
                    "mishka_gervaz",
                    "A Phoenix LiveComponent: keeps state between renders and answers its own events"
                  )
                }
                class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#f2f1fc] px-[10px] py-[3px] text-[10px] font-bold text-[#4f4bcc]"
              >
                <span class="size-[5px] rounded-full bg-[#6d69e6]"></span>{dgettext(
                  "mishka_gervaz",
                  "Live"
                )}
              </span>
              <span
                :if={!@stateful}
                data-role="component-kind"
                data-kind="function"
                title={
                  dgettext(
                    "mishka_gervaz",
                    "A function component: draws what it is given and holds nothing"
                  )
                }
                class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#f2f1ec] px-[10px] py-[3px] text-[10px] font-bold text-[#8a877f]"
              >
                <span class="size-[5px] rounded-full bg-[#a8a5a0]"></span>{dgettext(
                  "mishka_gervaz",
                  "Function"
                )}
              </span>

              <div data-role="component-dependencies">
                {MishkaGervaz.UIAdapters.Tailwind.cell_tags(@tags)}
              </div>
            </div>
            """
          end
        end

        column :active_compile do
          static true
          requires [:active, :precompile]
          label fn -> dgettext("mishka_gervaz", "Active & Compile") end

          ui do
            width "minmax(130px,1.1fr)"
          end

          render fn record ->
            assigns = %{active: record.active, precompile: record.precompile}

            ~H"""
            <div class="flex flex-col gap-[5px]">
              <span
                :if={@active}
                class="inline-flex w-fit items-center gap-[6px] rounded-[20px] bg-[#e6f6ee] px-[10px] py-[3px] text-[10px] font-bold text-[#177a53]"
              >
                <span class="size-[5px] rounded-full bg-[#1f9d6b]"></span>{dgettext(
                  "mishka_gervaz",
                  "Active"
                )}
              </span>
              <span
                :if={!@active}
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
                  <path :if={!@precompile} d="M18 6 6 18M6 6l12 12" />
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

          ui do
            width "minmax(150px,1.6fr)"
          end

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

        filter :type, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "General"), "general"},
              {dgettext("mishka_gervaz", "Forms"), "forms"},
              {dgettext("mishka_gervaz", "Navigations"), "navigations"},
              {dgettext("mishka_gervaz", "Overlays"), "overlays"},
              {dgettext("mishka_gervaz", "Feedback"), "feedback"},
              {dgettext("mishka_gervaz", "Media"), "media"}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "Select type...")
            label fn -> dgettext("mishka_gervaz", "Type") end
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

        filter :local_only, :boolean do
          virtual true

          apply fn query, value, _assigns ->
            if value do
              Ash.Query.filter(query, not is_nil(site_id))
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Non-global Only") end
          end
        end

        filter :created_at, :date_range, source: :inserted_at
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
              RuntimeHelpers.writes?(state, "component")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this component?") end

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "component")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this component?") end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "component")
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
              "Permanently delete this component? This cannot be undone."
            )
          end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "component")
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
          confirm: dgettext_noop("mishka_gervaz", "Archive selected components?"),
          restricted: true

        action :unarchive,
          handler: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected components?"),
          visible: :archived,
          restricted: true

        action :permanent_destroy,
          handler: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected components? This cannot be undone."
            ),
          visible: :archived,
          restricted: true
      end

      realtime do
        prefix "component"

        visible fn record, user ->
          is_nil(user.site_id) or is_nil(record.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "components"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No components found"),
                  icon: "hero-puzzle-piece"

      hooks do
        on_bulk_action_success :archive, fn summary, _state, socket ->
          msg =
            if summary.failed_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Archived %{succeeded} component(s); %{failed} failed.",
                succeeded: summary.succeeded_count,
                failed: summary.failed_count
              )
            else
              dgettext("mishka_gervaz", "Archived %{succeeded} component(s).",
                succeeded: summary.succeeded_count
              )
            end

          socket
          |> MishkaGervaz.Table.Web.Events.BulkActionHooks.put_flash(:info, msg)
          |> MishkaGervaz.Table.Web.Events.BulkActionHooks.silence()
        end

        on_bulk_action_success :unarchive, fn summary, _state, socket ->
          msg =
            if summary.skipped_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Restored %{succeeded} component(s) as inactive — activate them to go live; skipped %{skipped} (a component with the same name already exists).",
                succeeded: summary.succeeded_count,
                skipped: summary.skipped_count
              )
            else
              dgettext(
                "mishka_gervaz",
                "Restored %{succeeded} component(s) as inactive — activate them to go live.",
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
        name :component_form
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

        # WHICH KIND OF COMPONENT THIS IS, said once here and read everywhere a reader meets one —
        # the list, the palette card, the Inspector header. It changes which `use` line the compiled
        # module carries and therefore what the component can do, so it is not a detail to leave the
        # form silent about: two components in the same list, one of which answers clicks and one of
        # which cannot, are indistinguishable without it.
        field :stateful, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Live component") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Keeps its own state between renders and answers its own events, as a Phoenix LiveComponent. Off, it is a function component: it draws what it is given and holds nothing."
              )
            end
          end
        end

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
          end
        end

        field :template, :textarea do
          required false

          ui do
            label fn -> dgettext("mishka_gervaz", "Template") end
            rows 6
          end
        end

        field :body, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Body") end
            rows 4
          end
        end

        field :attrs, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "Attributes") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Attribute") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Name") end
              placeholder fn -> dgettext("mishka_gervaz", "e.g. id, class, type") end
            end
          end

          nested_field :type, :select do
            options @attr_types

            ui do
              label fn -> dgettext("mishka_gervaz", "Type") end
            end
          end

          nested_field :struct_name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Struct Module") end
              placeholder fn -> dgettext("mishka_gervaz", "e.g. Phoenix.HTML.FormField") end
            end
          end

          # THE KEYS ARE KNOWN, so they are drawn rather than typed as JSON. A Phoenix attribute's
          # options are these three and nothing else, forever — and asking an author to write
          # `{"required": true}` by hand to tick one box is how a declaration ends up with a typo in
          # a key name that nothing reads and nothing reports.
          nested_field :opts, :key_map do
            options [
              [name: :required, type: :toggle, label: dgettext_noop("mishka_gervaz", "Required")],
              [
                name: :default,
                type: :text,
                label: dgettext_noop("mishka_gervaz", "Default"),
                placeholder: dgettext_noop("mishka_gervaz", "e.g. medium")
              ],
              [name: :doc, type: :text, label: dgettext_noop("mishka_gervaz", "What it is for")]
            ]

            ui do
              label fn -> dgettext("mishka_gervaz", "Options") end
            end
          end
        end

        field :slots, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "Slots") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Slot") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Name") end
              placeholder fn -> dgettext("mishka_gervaz", "e.g. inner_block") end
            end
          end

          # Phoenix allows exactly one option inside a slot block — `:required` — plus the doc every
          # declaration can carry.
          nested_field :opts, :key_map do
            options [
              [name: :required, type: :toggle, label: dgettext_noop("mishka_gervaz", "Required")],
              [name: :doc, type: :text, label: dgettext_noop("mishka_gervaz", "What goes in it")]
            ]

            ui do
              label fn -> dgettext("mishka_gervaz", "Options") end
            end
          end

          # A SLOT'S ATTRIBUTES ARE A LIST OF THE SAME THREE THINGS, so they are declared the same
          # way and drawn the same way — a row of controls with a button to add another. Asked for
          # as JSON, declaring one attribute on one slot meant typing
          # `[{"name": "label", "type": "string"}]` by hand, brackets and quotes included.
          nested_field :attrs, :key_list do
            options [
              [
                name: :name,
                type: :text,
                label: dgettext_noop("mishka_gervaz", "Name"),
                placeholder: dgettext_noop("mishka_gervaz", "e.g. label")
              ],
              [
                name: :type,
                type: :select,
                label: dgettext_noop("mishka_gervaz", "Type"),
                options: @attr_types
              ],
              [name: :required, type: :toggle, label: dgettext_noop("mishka_gervaz", "Required")],
              [name: :doc, type: :text, label: dgettext_noop("mishka_gervaz", "What it is for")]
            ]

            ui do
              label fn -> dgettext("mishka_gervaz", "Slot Attributes") end
              add_label fn -> dgettext("mishka_gervaz", "+ Add Attribute") end
              remove_label fn -> dgettext("mishka_gervaz", "Remove") end
            end
          end
        end

        field :examples do
          ui do
            label fn -> dgettext("mishka_gervaz", "Examples (JSON)") end
            placeholder ~s(["<.button text=\\"Click me\\" />"])
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
              placeholder "arg1 <> \" \" <> arg2"
              rows 6
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
          fields [:description, :template, :body]

          ui do
            columns 1
            class ""
          end
        end

        group :data do
          fields [
            :attrs,
            :slots,
            :examples,
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

      # The options it draws are fewer than a declaration holds, and a save keeps the rest — see
      # `MishkaCmsCoreWeb.Forms.ComponentSubmit`.
      events do
        submit MishkaCmsCoreWeb.Forms.ComponentSubmit
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

    field :template, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(string, not_empty, min_len=3)"

    field :body, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(optional=[string])"

    field :format, :atom, derives: "validate(atom, enum=Atom[heex::eex::markdown])"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"

    field :active, :boolean, derives: "validate(boolean)"
    field :precompile, :boolean, derives: "validate(boolean)"
    field :extra, :map, derives: "validate(map)"

    field :attrs, {:array, :map}, derives: "validate(list)"
    field :slots, {:array, :map}, derives: "validate(list)"
    field :helpers, {:array, :map}, derives: "validate(list)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :examples, {:array, :string}, derives: "sanitize(reject_empty, uniq) validate(list)"

    field :type, :string, derives: "sanitize(trim) validate(optional=[string, max_len=50])"

    field :dependencies, {:array, :string}, derives: "sanitize(reject_empty, uniq) validate(list)"
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
      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulShape, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      # A declaration that will not compile is refused wherever it is written — the builder's
      # Interface tab, the Components form, an import. See `Validations.InterfaceDeclaration`.
      validate {MishkaCmsCore.Runtime.Resources.Validations.InterfaceDeclaration, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      # Blank means "I will build it in the editor" — filled in before the validations below
      # ask for a template, so a document can be created without anyone writing HEEx first.
      change MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty

      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present([:name])
      validate present([:template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change fn changeset, context ->
        if !is_nil(context.tenant) do
          Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
        else
          changeset
        end
      end

      change slugify(:name, into: :name)

      description "Creates component for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulShape, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      # A declaration that will not compile is refused wherever it is written — the builder's
      # Interface tab, the Components form, an import. See `Validations.InterfaceDeclaration`.
      validate {MishkaCmsCore.Runtime.Resources.Validations.InterfaceDeclaration, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      # Blank means "I will build it in the editor" — filled in before the validations below
      # ask for a template, so a document can be created without anyone writing HEEx first.
      change MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty

      validate present([:name])
      validate present([:template])

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

      description "Creates component for master users - can create global (nil site_id) or site-specific components"
    end

    update :update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulShape, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      # A declaration that will not compile is refused wherever it is written — the builder's
      # Interface tab, the Components form, an import. See `Validations.InterfaceDeclaration`.
      validate {MishkaCmsCore.Runtime.Resources.Validations.InterfaceDeclaration, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      primary? true
      require_atomic? false
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived component. Please unarchive it first."
                )
      end

      # Prevent tenant from modifying global components
      validate fn changeset, context ->
        component = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(component.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot modify global component. Global components can only be modified by master users."
                 )}

            component.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot modify component from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change slugify(:name, into: :name)

      description "Updates component for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulShape, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      # A declaration that will not compile is refused wherever it is written — the builder's
      # Interface tab, the Components form, an import. See `Validations.InterfaceDeclaration`.
      validate {MishkaCmsCore.Runtime.Resources.Validations.InterfaceDeclaration, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      description "Updates component for master users - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # A record other records name moves only where they can still name it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                moves: true, label: dgettext_noop("errors", "component")}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived component. Please unarchive it first."
                )
      end

      change slugify(:name, into: :name)
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Component is already archived.")}
        else
          :ok
        end
      end

      # Prevent tenant from archiving global components
      validate fn changeset, context ->
        component = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(component.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot archive global component. Global components can only be archived by master users."
                 )}

            component.site_id != context.tenant ->
              {:error,
               message: dgettext_noop("errors", "Cannot archive component from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      change set_attribute(:active, false)

      description "Soft deletes component by archiving (tenant users)"
    end

    destroy :master_destroy do
      description "Soft deletes component by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Component is already archived.")}
        else
          :ok
        end
      end

      change set_attribute(:active, false)
    end

    read :get_any do
      get? true
      multitenancy :bypass

      description "Retrieves a single component by ID, bypassing tenant filtering for admin operations"
    end

    read :master_read do
      description "Reads all components system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single component by ID, bypassing tenant filtering (master users)"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves a single archived component by ID for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived component for recovery or inspection (master users)"
    end

    read :by_priority do
      pagination offset?: true, default_limit: 100
      prepare build(sort: [priority: :desc, name: :asc])

      description "Lists active components ordered by priority (descending) then name for rendering sequences"
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived components within current tenant context"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived components system-wide, bypassing tenant filtering"
    end

    read :by_name do
      get_by [:name]

      prepare fn query, context ->
        tenant = context.tenant

        if is_nil(tenant),
          do: Ash.Query.filter(query, is_nil(site_id)),
          else: Ash.Query.filter(query, site_id == ^tenant)
      end

      description "Retrieves component by exact name, filtering by site based on tenant context"
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

      description "Lists all components system-wide, bypassing tenant filtering for administrative operations"
    end

    read :for_tenant_with_globals do
      pagination offset?: true, default_limit: 100
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to filter by (only for master users)"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Lists components for a specific tenant including global components, or filtered by site_id for master users"
    end

    read :get_for_tenant_with_globals do
      get? true
      multitenancy :bypass

      argument :site_id, :uuid do
        allow_nil? true
        description "Optional site_id to filter by (only for master users)"
      end

      prepare MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals

      description "Gets a single component for a specific tenant including global components, or filtered by site_id for master users"
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      # A LIVE COMPONENT COMING BACK is one more way into reach of whatever already names it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      atomic_upgrade_with :archived

      description "Restores an archived component as inactive — activate it to compile and go live (tenant users)"
    end

    update :master_unarchive do
      description "Restores an archived component as inactive — activate it to compile and go live (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Component is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      # A LIVE COMPONENT COMING BACK is one more way into reach of whatever already names it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Prevent tenant from permanently deleting global components
      validate fn changeset, context ->
        component = changeset.data

        # Only check for tenant operations, not master operations
        if !is_nil(context.tenant) do
          cond do
            is_nil(component.site_id) ->
              {:error,
               message:
                 dgettext_noop(
                   "errors",
                   "Cannot permanently delete global component. Global components can only be deleted by master users."
                 )}

            component.site_id != context.tenant ->
              {:error,
               message:
                 dgettext_noop("errors", "Cannot permanently delete component from another site.")}

            true ->
              :ok
          end
        else
          :ok
        end
      end

      description "Permanently removes component and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes component and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :get_with_versions do
      get? true
      description "Gets a single component with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        # Filter by tenant: show site's components plus global ones
        filtered_query =
          if !is_nil(context.tenant) do
            Ash.Query.filter(query, site_id == ^context.tenant or is_nil(site_id))
          else
            query
          end

        Ash.Query.load(filtered_query,
          sorted_versions:
            MishkaCmsCore.Runtime.Component.Version
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
      description "Gets a single component with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Component.Version
            |> Ash.Query.for_read(:sorted_versions, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    action :restore_version_api, :struct do
      description "Restores component content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.Component

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        component_id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaCmsCore.Runtime.Component, component_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, component} when not is_nil(component) ->
            # Check tenant access: can access own site's components or global ones
            can_access =
              cond do
                is_nil(acting_site) -> false
                is_nil(component.site_id) -> true
                component.site_id == acting_site -> true
                true -> false
              end

            # Check if tenant can modify (not just access)
            can_modify =
              cond do
                is_nil(acting_site) -> false
                # Cannot modify global components
                is_nil(component.site_id) -> false
                component.site_id == acting_site -> true
                true -> false
              end

            cond do
              not can_access ->
                {:error,
                 Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}

              not can_modify ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :site_id,
                       message:
                         dgettext_noop(
                           "errors",
                           "Cannot restore version of global component. Global components can only be modified by master users."
                         )
                     )
                   ]
                 )}

              !is_nil(component.archived_at) ->
                {:error,
                 Ash.Error.Invalid.exception(
                   errors: [
                     Ash.Error.Changes.InvalidAttribute.exception(
                       field: :archived_at,
                       message:
                         dgettext_noop(
                           "errors",
                           "Cannot restore version of archived component. Please unarchive it first."
                         )
                     )
                   ]
                 )}

              true ->
                tenant = component.site_id

                case Ash.get(MishkaCmsCore.Runtime.Component.Version, version_id,
                       action: :get_any,
                       authorize?: false
                     ) do
                  {:ok, version} when not is_nil(version) ->
                    if version.version_source_id != component_id do
                      {:error,
                       Ash.Error.Invalid.exception(
                         errors: [
                           Ash.Error.Changes.InvalidAttribute.exception(
                             field: :version_id,
                             message:
                               dgettext_noop(
                                 "errors",
                                 "Version does not belong to this component."
                               )
                           )
                         ]
                       )}
                    else
                      component
                      |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                        tenant: tenant,
                        authorize?: false
                      )
                      |> Ash.update()
                    end

                  _ ->
                    {:error,
                     Ash.Error.Query.NotFound.exception(
                       resource: MishkaCmsCore.Runtime.Component.Version
                     )}
                end
            end

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}
        end
      end
    end

    action :master_restore_version, :struct do
      description "Restores component content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Component

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        component_id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaCmsCore.Runtime.Component, component_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, component} when not is_nil(component) ->
            if !is_nil(component.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived component. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = component.site_id

              case Ash.get(MishkaCmsCore.Runtime.Component.Version, version_id,
                     action: :get_any,
                     authorize?: false
                   ) do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != component_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop("errors", "Version does not belong to this component.")
                         )
                       ]
                     )}
                  else
                    component
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.Component.Version
                   )}
              end
            end

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}
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
                  "Cannot restore version of archived component. Please unarchive it first."
                )
      end

      # A MISSING TENANT IS NOT A MASTER, and neither is anything that is not a site user. Without a
      # tenant, only a master (`site_id` nil) or the system (`authorize?: false`) restores; with one,
      # whoever acts on that site restores its components alone. See
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
                 "Cannot restore version of component from another site."
               )}
        end
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.Component.Version}

      # AFTER THE CHANGE THAT COPIES THE SNAPSHOT, because validations and changes run in the order
      # they are declared, and a restore is a write of the markup and the live flag like any other.
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "A component")}

      description "Restores the component to a previous version"
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.Component

      argument :component_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        component_id = input.arguments.component_id
        version_id = input.arguments.version_id

        with {:ok, component} when not is_nil(component) <-
               Ash.get(MishkaCmsCore.Runtime.Component, component_id,
                 action: :get_any,
                 authorize?: false
               ),
             # Check tenant access
             :authorized <-
               (cond do
                  is_nil(acting_site) -> :not_authorized
                  is_nil(component.site_id) -> :authorized
                  component.site_id == acting_site -> :authorized
                  true -> :not_authorized
                end),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Component.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == component_id, do: :valid, else: :invalid) do
          preview_component =
            MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion.preview(
              component,
              MishkaCmsCore.Runtime.Component,
              version.changes
            )

          {:ok, preview_component}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this component.")
                 )
               ]
             )}

          :not_authorized ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}

          {:error, _} ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Component

      argument :component_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        component_id = input.arguments.component_id
        version_id = input.arguments.version_id

        with {:ok, component} when not is_nil(component) <-
               Ash.get(MishkaCmsCore.Runtime.Component, component_id,
                 action: :get_any,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Component.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == component_id, do: :valid, else: :invalid) do
          preview_component =
            MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion.preview(
              component,
              MishkaCmsCore.Runtime.Component,
              version.changes
            )

          {:ok, preview_component}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this component.")
                 )
               ]
             )}

          {:error, _} ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)}
        end
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a component with pagination (tenant users)"

      argument :component_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        component_id = Ash.Query.get_argument(query, :component_id)

        # Verify the component belongs to the tenant or is global
        case Ash.get(MishkaCmsCore.Runtime.Component, component_id,
               action: :get_any,
               authorize?: false
             ) do
          {:ok, component} ->
            # Check access: tenant can access their own components or global ones
            can_access =
              cond do
                is_nil(acting_site) -> false
                is_nil(component.site_id) -> true
                component.site_id == acting_site -> true
                true -> false
              end

            if can_access do
              query
              |> Ash.Query.filter(id == ^component_id)
              |> Ash.Query.load(
                sorted_versions:
                  MishkaCmsCore.Runtime.Component.Version
                  |> Ash.Query.for_read(:sorted_versions)
              )
            else
              Ash.Query.add_error(
                query,
                Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)
              )
            end

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Component)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a component with pagination (master users)"

      argument :component_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        component_id = Ash.Query.get_argument(query, :component_id)

        query
        |> Ash.Query.filter(id == ^component_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.Component.Version
            |> Ash.Query.for_read(:sorted_versions)
        )
      end
    end
  end

  # Authorization policies for component access
  policies do
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING, its code included, needs the component section or code on the request's surface;
    # reading, above, is open to anyone under the surface.
    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:component",
                      "admin:api:runtime:component",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}
    end

    policy action([:restore_version_api, :master_restore_version]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:component",
                      "admin:api:runtime:component",
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
    prefix "component"

    # Publish to both global and site-specific topics using [nil, :site_id]:
    # - nil site_id → "component:created" only
    # - uuid site_id → "component:created" AND "component:{uuid}:created"
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

  # Background job triggers for component compilation
  changes do
    change {Changes.SendToOban, []}, on: [:create, :update, :destroy]
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
      constraints min_length: 3, max_length: 100, trim?: true
      description "Human-readable component name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "Optional description of the component's purpose"
    end

    attribute :template, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, trim?: true
      description "Template content (HTML, HEEx, etc.)"
    end

    attribute :body, :string do
      allow_nil? true
      public? true
      constraints trim?: true
      description "Optional body content for the component"
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
      description "Priority for component rendering (higher = more priority)"
    end

    attribute :extra, :map do
      default %{}
      public? true
      description "Additional metadata or configuration"
    end

    # Component specific
    attribute :attrs, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      name: [
                        type: :string,
                        allow_nil?: false
                      ],
                      type: [
                        type: :string,
                        allow_nil?: false
                      ],
                      struct_name: [
                        type: :string,
                        allow_nil?: true
                      ],
                      opts: [
                        type: :map,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "Component attribute definitions"
    end

    attribute :slots, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      name: [
                        type: :string,
                        allow_nil?: false
                      ],
                      opts: [
                        type: :map,
                        allow_nil?: true
                      ],
                      attrs: [
                        type: {:array, :map},
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "Component slot definitions"
    end

    attribute :helpers, {:array, MishkaCmsCore.Runtime.Resources.Embeddeds.Helper} do
      default []
      public? true
      description "Helper function definitions for the component"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the component is active and available for use"
    end

    # EXACTLY THE SAME MEANING AS ON A PAGE OR A LAYOUT: when to build the module, and nothing else.
    # Set, and `MishkaCmsCore.Runtime.Handlers.BootHandler.compile_components/1` builds it at boot.
    # Unset, and the first render that names it builds it —
    # `MishkaCmsCore.Runtime.LiveViewHelpers.component/1`.
    #
    # It says nothing about CSS. A site's stylesheet covers the components that site actually
    # reaches, computed per site by `MishkaCmsCore.Runtime.Compilers.CssClosure`, and boot writes
    # every active component's template file whether or not it compiles one — so a lazy component
    # renders styled the first time it is seen.
    attribute :precompile, :boolean do
      default false
      public? true

      description "Whether the module is built at boot (true) or on the first render that uses it (false)"
    end

    # DECLARED BY THE KIT, not inferred. An icon is drawn by half of Chelekom's other components and
    # nothing in the markup says so, which is why the installer could offer to deselect it and leave
    # the rest unable to render. `dependencies` covers "this component needs that one"; this covers
    # "the CMS needs this one at all".
    attribute :required, :boolean do
      default false
      public? true

      description "Whether the CMS cannot run without this component, so the installer may not deselect it"
    end

    # A COMPONENT THAT KEEPS STATE BETWEEN RENDERS. False is a function component — the shape every
    # component has had until now, rendered by applying its name and holding nothing. True compiles
    # to a `Phoenix.LiveComponent`: per-instance server state that survives the hosting page's
    # re-renders, its own event channel through `@myself`, and its own diff.
    #
    # A BOOLEAN AND NOT AN ATOM, deliberately. `preview_version` rebuilds this struct from a JSON
    # snapshot and coerces exactly one key back to an atom (`:format`), so an atom here would come
    # back from a version preview as the string "live" while every other read path held `:live`. A
    # boolean round-trips through JSON unchanged.
    #
    # A RESTORE BRINGS THE SHAPE BACK WITH THE MARKUP. `restore_version` reduces over the keys
    # PRESENT in the snapshot, and every snapshot taken since this column existed carries one — so
    # rolling back to a version this component was a function component at makes it one again. A
    # snapshot written BEFORE the column existed has no such key, the reduce never sees it, and that
    # restore leaves the flag alone. Both are consequences of the same reduce and neither is
    # guessable from the outside, which is why they are written down.
    attribute :stateful, :boolean do
      default false
      public? true

      description "Whether this component compiles to a LiveComponent (keeps state) or a function component"
    end

    # ACL
    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to access this component"
    end

    attribute :examples, {:array, :string} do
      default []
      allow_nil? true
      public? true
      description "HTML examples showing how to use this component"
    end

    attribute :type, :string do
      allow_nil? true
      public? true
      constraints max_length: 50, trim?: true
      description ~s|Component category/type (e.g. "general", "media", "form")|
    end

    attribute :dependencies, {:array, :string} do
      default []
      public? true

      description ~s|Components / JS files this component needs (e.g. "chelekom-icon", "collapsible.js")|
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this component belongs to (nil for global components)"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.Component.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    # The palette needs two facts out of `extra` and nothing else: which glyph to draw, and whether
    # there is anything in the Examples modal. Selecting the whole column to learn them shipped
    # 2.9 MB of `demo_examples` per page load — Postgres answers both in the query instead.
    calculate :icon_name, :string, expr(fragment("?->>'icon'", extra)) do
      public? true
      description "The palette glyph this component names for itself, if any"
    end

    # WHERE THE KIT DOCUMENTS THIS COMPONENT. All 136 Chelekom components ship one and nothing read
    # it, so an author stuck on what `variant` means had the answer in the database and no way to
    # reach it. Same reason as `icon_name` for it being a calculation: one short string out of a
    # column the palette must not pull whole.
    calculate :doc_url, :string, expr(fragment("?->>'doc_url'", extra)) do
      public? true
      description "The kit's documentation page for this component, if it names one"
    end

    # WHOSE MARKUP THIS IS. The builder's Custom CSS panel says so when a rule reaches past the
    # element into the component's own elements — `& > .badge` — because that markup belongs to the
    # kit and the next version of it is free to rename. Naming the version is the whole value: "the
    # component's own markup" is not something a reader can act on, and `chelekom 0.0.9` is.
    #
    # A calculation for the same reason as `icon_name` and `doc_url`: two short strings out of a
    # column the palette must not pull whole. Concatenated in SQL so it stays one selected value
    # rather than two, and null for a component nobody imported from a kit.
    calculate :ui_kit_label,
              :string,
              expr(
                fragment(
                  "NULLIF(TRIM(CONCAT_WS(' ', ?->>'ui_kit', ?->>'ui_kit_version')), '')",
                  extra,
                  extra
                )
              ) do
      public? true
      description "The kit and version this component was imported from, if any"
    end

    # Same reason as `icon_name`: the palette needs this one small object and must not pull the whole
    # `extra` column to reach it. What a component says it should look like when dropped —
    # `MishkaCmsCore.Builder.Furnishing` validates the shape.
    calculate :furnishing, :map, expr(fragment("?->'furnishing'", extra)) do
      public? true
      description "The sample content this component declares for a fresh drop, if any"
    end

    # Same reason as `furnishing`: one small object out of a column the palette must not pull whole.
    # What part of a form this component says it plays, so the editor writes a binding on the
    # attribute the kit named rather than on one guessed from the word "field" —
    # `MishkaCmsCore.Builder.FormRole` validates the shape.
    calculate :form_meta, :map, expr(fragment("?->'form'", extra)) do
      public? true
      description "What part of a form this component says it plays, if the kit says so"
    end

    # Not `examples?` — Ash refuses a calculation name ending in `?`, so the house predicate style
    # gives way here.
    calculate :has_examples,
              :boolean,
              expr(
                fragment(
                  "(jsonb_typeof(?->'examples') = 'array' AND jsonb_array_length(?->'examples') > 0) OR (jsonb_typeof(?->'demo_examples') = 'array' AND jsonb_array_length(?->'demo_examples') > 0)",
                  extra,
                  extra,
                  extra,
                  extra
                )
              ) do
      public? true
      description "Whether the Examples modal would have anything to show"
    end

    calculate :component_module,
              :atom,
              {MishkaCmsCore.Runtime.Resources.Calculations.ModuleName,
               [global?: true, field: :name]} do
      public? true
      description "Generates the runtime module name for the component based on its name and site"
    end

    calculate :is_global, :boolean do
      public? true
      description "Determines if the component is globally available (not site-specific)"

      calculation fn records, _context ->
        Enum.map(records, fn component ->
          is_nil(component.site_id)
        end)
      end
    end

    calculate :version_preview,
              :map,
              {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
               version: MishkaCmsCore.Runtime.Component.Version} do
      public? true
      argument :version_id, :uuid, allow_nil?: false

      description "Retrieves content from one of this record's own versions for preview before restoration"
    end

    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in component history"

      calculation fn records, _context ->
        Enum.map(records, fn component ->
          case MishkaCmsCore.Runtime.Component.Version
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(version_source_id == ^component.id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.Component.Version
      description "Returns the most recent version for the component"

      calculation fn records, _context ->
        component_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Component.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^component_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn component ->
          Map.get(versions_map, component.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.Component.Version]

      description "Returns the 10 most recent versions for the component in descending order by insertion date"

      calculation fn records, _context ->
        component_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Component.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^component_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn component ->
          Map.get(versions_map, component.id, [])
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures component names are unique within each site, allowing same names across different sites"
      message dgettext_noop("errors", "Component name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end

  # ONE TOGGLE PER ROW, and a row that somehow arrives without an id still gets a stable name rather
  # than sharing one with every other row — `MishkaGervaz.Table.Types.Column.Tags` hashes the same
  # way for the same reason.
  defp tags_dom_id(record) do
    base = Map.get(record, :id) || :erlang.phash2(Map.get(record, :dependencies))
    "gz-tags-dependencies-#{base}"
  end
end
