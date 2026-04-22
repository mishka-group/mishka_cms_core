defmodule MishkaCmsCore.Runtime.ErrorPage do
  @moduledoc """
  Manages custom error page configurations in the MishkaCMS runtime system.

  This resource handles the creation and management of error page templates that are dynamically
  compiled and rendered when HTTP errors occur. Each error page configuration can define multiple
  status code handlers (404, 500, etc.) with custom templates and layouts, allowing sites to
  provide branded and informative error experiences. Error pages are strictly site-specific,
  ensuring proper isolation in multi-tenant environments.

  One more status sits beside the codes: `:offline`, the page the site shows its visitors while it
  is switched offline. `MishkaCms.Plugs.MaintenanceGate` answers it as a 503 at the address asked
  for, and draws its built-in page when the site has no such entry. See
  `MishkaCmsCore.Runtime.ErrorStatus`.

  The resource supports priority-based path matching for flexible error handling strategies,
  helper functions for dynamic content generation, and optional precompilation for improved
  performance. It implements soft deletion through archival, allowing error configurations
  to be temporarily disabled and later restored. Database-level constraints ensure data
  integrity, including prevention of empty error page arrays and modifications to archived records.

  Error page configurations automatically trigger background compilation jobs when modified,
  integrating with the runtime compiler to generate optimized error handling modules. The
  resource provides both standard CRUD operations and specialized API actions for external
  integrations, with comprehensive tenant isolation and permission-based access control.

  ## The two `style` attributes in the codes column

  Everything else the admin renders paints through classes so the policy in
  `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` can close `style-src-attr` — a directive no nonce can
  reopen, because CSP has no mechanism for an attribute. The error-codes tooltip is the exception:
  it is a CSS-anchor-positioned popover, and `anchor-name` / `position-anchor` both carry the RECORD's
  id. A per-record name is the whole point — one shared name would make every row's tooltip resolve
  to the same anchor — so the value is unbounded, which is exactly what a Tailwind class cannot be:
  the scanner reads source text, and no `@source inline` can declare a uuid that does not exist yet.
  Closing these two means giving the popover its anchor through the HTML `anchor` attribute instead,
  which needs verifying in a browser rather than assuming.
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

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]

  require Ash.Query
  alias MishkaCmsCore.Runtime.Resources.Changes
  alias MishkaCmsCore.Runtime.Helpers, as: RuntimeHelpers

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
  Format table column and the error-page detail modal so both draw the same badge from one definition.
  """
  def format_badge_config, do: @format_badge

  @admin_fields [
    :name,
    :path,
    :root_layout_template,
    :format,
    :priority,
    :error_pages,
    :helpers,
    :active,
    :precompile,
    :extra,
    :site_id
  ]

  @doc "Unguessable token for the shareable preview URL (generated on create)."
  def generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  # Database configuration for error page storage
  postgres do
    table "error_pages"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 3 AND length(name) <= 200",
        message: dgettext_noop("errors", "Name must be between 3 and 200 characters.")

      check_constraint :path, "path_length_check",
        check: "length(path) >= 1 AND length(path) <= 255",
        message: dgettext_noop("errors", "Path must be between 1 and 255 characters.")

      check_constraint :priority, "priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      # Multiple attributes can share the same constraint
      check_constraint [:name, :path], "no_empty_strings",
        check: "name != '' AND path != ''",
        message: dgettext_noop("errors", "Name and path cannot be empty.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_error_page_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_error_page_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived error page'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_error_page_updates();"
      end

      statement :prevent_archived_error_page_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_error_page_updates_trigger
          BEFORE UPDATE ON error_pages
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_error_page_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_error_page_updates_trigger ON error_pages;"
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
      :master_archived
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

    belongs_to_actor :user, MishkaCmsCore.Accounts.User, domain: MishkaCmsCore.Accounts

    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.ErrorPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "error_page"
  end

  # MishkaGervaz table configuration for admin interface
  mishka_gervaz do
    table do
      identity do
        name :error_pages
        route "/admin/error_pages"
        stream_name :error_pages
      end

      source do
        preload do
          always [:site]
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        column :page_info do
          static true
          requires [:id, :name]
          label fn -> dgettext("mishka_gervaz", "Page") end
          position :first

          ui do
            width "minmax(160px,1.2fr)"
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
                  id={"error-page-id-copy-#{@id}"}
                  value={@id}
                  label={dgettext("mishka_gervaz", "Copy error page ID")}
                />
              </div>
            </div>
            """
          end
        end

        column :path_error_count do
          static true
          requires [:id, :path, :error_pages]
          label fn -> dgettext("mishka_gervaz", "Path & Error Count") end

          ui do
            width "minmax(260px,2.2fr)"
          end

          render fn record ->
            codes =
              record.error_pages
              |> Enum.map(&(Map.get(&1, "status") || Map.get(&1, :status)))
              |> Enum.reject(&is_nil/1)
              |> Enum.sort()

            assigns = %{
              id: record.id,
              path: record.path,
              count: length(record.error_pages),
              shown: codes |> Enum.take(4) |> Enum.join(", "),
              more: max(0, length(codes) - 4),
              full: Enum.join(codes, ", "),
              has_codes?: codes != []
            }

            ~H"""
            <div class="min-w-0">
              <div
                class="truncate font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#3a382f]"
                title={@path}
              >
                {@path}
              </div>
              <div class="mt-[6px] flex flex-wrap items-center gap-[9px]">
                <span class="inline-flex items-center gap-[5px] rounded-[20px] bg-[#fbe9e7] px-[9px] py-[3px] text-[10px] font-bold text-[#c0473d]">
                  <svg
                    width="11"
                    height="11"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    class="shrink-0"
                  >
                    <path d="M12 3 22 20H2z" />
                    <path d="M12 10v3M12 16h.01" />
                  </svg>
                  {dngettext("mishka_gervaz", "%{count} error", "%{count} errors", @count)}
                </span>
                <button
                  :if={@has_codes?}
                  type="button"
                  popovertarget={"epc-#{@id}"}
                  style={"anchor-name:--epc-#{@id}"}
                  class="inline-flex min-w-0 cursor-pointer items-center gap-[5px] text-[11px] font-medium text-[#a8a5a0] hover:text-[#6d6a63]"
                >
                  <svg
                    width="12"
                    height="12"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="#cf8a24"
                    stroke-width="1.8"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    class="shrink-0"
                  >
                    <path d="M10.3 3.3 2.6 17a2 2 0 0 0 1.7 3h15.4a2 2 0 0 0 1.7-3L13.7 3.3a2 2 0 0 0-3.4 0z" />
                    <path d="M12 9v4M12 17h.01" />
                  </svg>
                  <span class="truncate">{if @more > 0,
                    do: dgettext("mishka_gervaz", "%{shown} and %{more} more", shown: @shown, more: @more),
                    else: @shown}</span>
                </button>
                <div
                  :if={@has_codes?}
                  id={"epc-#{@id}"}
                  popover="auto"
                  style={"position-anchor:--epc-#{@id}"}
                  class="fixed top-auto right-auto bottom-[anchor(top)] left-[anchor(left)] m-0 mb-[6px] w-max max-w-[240px] rounded-[10px] bg-[#1c1b22] px-[12px] py-[9px] text-[11px] leading-relaxed text-white shadow-[0_10px_30px_-8px_rgba(0,0,0,0.5)]"
                >
                  <div class="mb-[3px] text-[10px] font-bold uppercase tracking-[0.04em] text-[#8f8ca3]">
                    {dgettext("mishka_gervaz", "Error codes")}
                  </div>
                  {@full}
                </div>
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
            width "95px"
          end
        end

        column :priority do
          label fn -> dgettext("mishka_gervaz", "Priority") end
          sortable true

          ui do
            type :bars
            extra %{max: 4, percent: true}
            width "110px"
          end
        end

        column :active_compile do
          static true
          requires [:active, :precompile]
          label fn -> dgettext("mishka_gervaz", "Active & Compile") end

          ui do
            width "minmax(150px,1.4fr)"
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

        column :layout do
          static true
          requires [:root_layout_template]
          label fn -> dgettext("mishka_gervaz", "Layout") end
          position :last

          render fn record ->
            custom? =
              is_binary(record.root_layout_template) and
                String.trim(record.root_layout_template || "") != ""

            assigns = %{custom?: custom?}

            ~H"""
            <div class="flex items-center gap-[7px]">
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
                <rect x="3" y="3" width="18" height="18" rx="2.5" />
                <path d="M3 9h18M9 9v12" />
              </svg>
              <span class="text-[12.5px] font-medium text-[#3a382f]">
                {if(@custom?,
                  do: dgettext("mishka_gervaz", "Custom"),
                  else: dgettext("mishka_gervaz", "Default")
                )}
              </span>
            </div>
            """
          end
        end
      end

      filters do
        filter :search, :text, fields: [:name, :path]

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

        filter :active, :boolean
        filter :precompile, :boolean
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
              RuntimeHelpers.writes?(state, "error_page")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this error page?") end

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "error_page")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this error page?") end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "error_page")
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
              "Permanently delete this error page? This cannot be undone."
            )
          end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "error_page")
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
          handler: :master_destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected error pages?"),
          restricted: true

        action :unarchive,
          handler: :master_unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected error pages?"),
          visible: :archived,
          restricted: true

        action :permanent_destroy,
          handler: :master_permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected error pages? This cannot be undone."
            ),
          visible: :archived,
          restricted: true
      end

      realtime do
        prefix "error_page"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "error_pages"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No error pages found"),
                  icon: "hero-exclamation-triangle"

      hooks do
        on_bulk_action_success :unarchive, fn summary, _state, socket ->
          msg =
            if summary.skipped_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Restored %{succeeded} error page(s) as inactive — activate them to go live; skipped %{skipped} (an error page with the same name already exists).",
                succeeded: summary.succeeded_count,
                skipped: summary.skipped_count
              )
            else
              dgettext(
                "mishka_gervaz",
                "Restored %{succeeded} error page(s) as inactive — activate them to go live.",
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
        name :error_page_form
      end

      fields do
        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        # NOT A FIELD ANYBODY FILLS IN. `Changes.ErrorPageAddress` writes it from the site, so
        # `readonly` is what makes the form agree with the action: Gervaz draws it and drops it from
        # what is submitted. Shown rather than hidden because the address is worth knowing — it is
        # the one the renderer looks this row up by. See `MishkaCmsCore.Runtime.ErrorAddress`.
        field :path do
          required true
          readonly true

          ui do
            label fn -> dgettext("mishka_gervaz", "Path") end
            placeholder "/mishka-cms/errors/<site>"

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Taken from the site — it is the address the renderer looks this row up by."
              )
            end
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
          required true
          restricted true
          show_on :create

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

        field :root_layout_template, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Root Layout Template") end
            rows 4
          end
        end

        field :error_pages, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "Error Pages") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Error Page") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          # `:offline` is the page an offline site shows, answered as a 503 by
          # `MishkaCms.Plugs.MaintenanceGate`; the codes are the ones a failed request answers with.
          nested_field :status, :select do
            options MishkaCmsCore.Runtime.ErrorStatus.choices()

            ui do
              label fn -> dgettext("mishka_gervaz", "Status") end
              placeholder fn -> dgettext("mishka_gervaz", "Choose a status") end
            end
          end

          nested_field :template, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Template") end
              rows 4
              span 2
            end
          end

          # ONE KEY, AND THE COMPILER READS ONLY THAT ONE.
          # `MishkaCmsCore.Runtime.Compilers.ErrorCompiler.build_layout_function/2` looks for
          # `template` and nothing else — anything else written beside it is stored and ignored — so
          # a JSON box asking for `{}` was asking an author to type braces around a single string.
          nested_field :layout, :key_map do
            options [
              [
                name: :template,
                type: :textarea,
                label: dgettext_noop("mishka_gervaz", "Wrapper template"),
                placeholder: ~s(<div class="error-layout">{@inner_content}</div>)
              ]
            ]

            ui do
              label fn -> dgettext("mishka_gervaz", "Layout") end
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
              rows 6
              class "font-mono text-sm"
            end
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
          fields [:root_layout_template]

          ui do
            columns 1
            class ""
          end
        end

        group :data do
          fields [:error_pages, :helpers]

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

    field :root_layout_template, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(optional=[string])"

    field :format, :atom, derives: "validate(atom, enum=Atom[heex::eex::markdown])"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"
    field :active, :boolean, derives: "validate(boolean)"
    field :precompile, :boolean, derives: "validate(boolean)"
    field :extra, :map, derives: "validate(map)"

    field :error_pages, {:array, :map}, derives: "validate(list)"
    field :helpers, {:array, :map}, derives: "validate(list)"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields for version calculations
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
      change {MishkaCmsCore.Runtime.Resources.Changes.ErrorPageAddress, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "An error page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present([:name, :path])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change slugify(:name, into: :name)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      description "Creates error page for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      change {MishkaCmsCore.Runtime.Resources.Changes.ErrorPageAddress, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "An error page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      validate present([:name, :path, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change slugify(:name, into: :name)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      description "Creates error page for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      change {MishkaCmsCore.Runtime.Resources.Changes.ErrorPageAddress, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "An error page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived error page. Please unarchive it first."
                )
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)

      description "Updates error page for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      change {MishkaCmsCore.Runtime.Resources.Changes.ErrorPageAddress, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TemplateCompiles, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "An error page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      description "Updates error page for master users - requires nil tenant context, prevents site_id changes"
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived error page. Please unarchive it first."
                )
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)

      # Set tenant from record's site_id for version tracking
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived error pages within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived error page for recovery or inspection (tenant users)"
    end

    read :by_priority do
      description "Lists error pages ordered by priority for path matching precedence"
      pagination offset?: true, default_limit: 100

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare build(sort: [priority: :desc, name: :asc])
    end

    read :by_path do
      description "Retrieves error page configuration by exact path match"
      argument :path, :string, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      filter expr(path == ^arg(:path))
    end

    read :master_read do
      description "Reads all error pages system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single error page by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_token do
      get? true
      multitenancy :bypass
      argument :preview_token, :string, allow_nil?: false
      filter expr(preview_token == ^arg(:preview_token))

      description "Resolve a live error page by its preview token (for the shareable preview URL)."
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived error pages system-wide, bypassing tenant filtering"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived error page for recovery or inspection (master users)"
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
      pagination keyset?: true, default_limit: 100, max_page_size: 250
      description "Efficiently streams all error pages using keyset pagination for large datasets"
    end

    destroy :destroy do
      description "Soft deletes error page by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Error page is already archived.")}
        else
          :ok
        end
      end

      change set_attribute(:active, false)
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      atomic_upgrade_with :archived

      description "Restores an archived error page as inactive — activate it to compile and go live (tenant users)"
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Permanently removes error page and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_destroy do
      description "Soft deletes error page by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Error page is already archived.")}
        else
          :ok
        end
      end

      change set_attribute(:active, false)

      # Set tenant from record's site_id for version tracking
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end
    end

    update :master_unarchive do
      description "Restores an archived error page as inactive — activate it to compile and go live (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Error page is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      # Set tenant from record's site_id for version tracking
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      atomic_upgrade_with :master_archived
    end

    destroy :master_permanent_destroy do
      description "Permanently removes error page and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # Set tenant from record's site_id for version tracking
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end
    end

    read :get_with_versions do
      get? true
      description "Gets a single error page with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.ErrorPage.Version
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
      description "Gets a single error page with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.ErrorPage.Version
            |> Ash.Query.for_read(:sorted_versions, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for an error page with pagination (tenant users)"

      argument :error_page_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        error_page_id = Ash.Query.get_argument(query, :error_page_id)

        # First verify the error page belongs to the tenant
        case Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page_id,
               tenant: acting_site,
               authorize?: false
             ) do
          {:ok, _error_page} ->
            query
            |> Ash.Query.filter(id == ^error_page_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaCmsCore.Runtime.ErrorPage.Version
                |> Ash.Query.for_read(:sorted_versions)
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for an error page with pagination (master users)"

      argument :error_page_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        error_page_id = Ash.Query.get_argument(query, :error_page_id)

        query
        |> Ash.Query.filter(id == ^error_page_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.ErrorPage.Version
            |> Ash.Query.for_read(:sorted_versions)
        )
      end
    end

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the error page to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived error page. Please unarchive it first."
                )
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.ErrorPage.Version}

      # AFTER THE CHANGE THAT COPIES THE SNAPSHOT, because validations and changes run in the order
      # they are declared, and a restore writes markup like any other save.
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement,
                noun: dgettext_noop("errors", "An error page")}
    end

    action :restore_version_api, :struct do
      description "Restores error page content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.ErrorPage

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        error_page_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page_id,
          action: :read,
          tenant: acting_site,
          authorize?: false
        )
        |> case do
          {:ok, error_page} when not is_nil(error_page) ->
            if !is_nil(error_page.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived error page. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = error_page.site_id

              Ash.get(MishkaCmsCore.Runtime.ErrorPage.Version, version_id,
                action: :get_any,
                authorize?: false
              )
              |> case do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != error_page_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop(
                               "errors",
                               "Version does not belong to this error page."
                             )
                         )
                       ]
                     )}
                  else
                    error_page
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.ErrorPage.Version
                   )}
              end
            end

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)}
        end
      end
    end

    action :master_restore_version, :struct do
      description "Restores error page content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.ErrorPage

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        error_page_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page_id,
          action: :master_get,
          authorize?: false
        )
        |> case do
          {:ok, error_page} when not is_nil(error_page) ->
            if !is_nil(error_page.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived error page. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = error_page.site_id

              Ash.get(MishkaCmsCore.Runtime.ErrorPage.Version, version_id,
                action: :get_any,
                authorize?: false
              )
              |> case do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != error_page_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop(
                               "errors",
                               "Version does not belong to this error page."
                             )
                         )
                       ]
                     )}
                  else
                    error_page
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.ErrorPage.Version
                   )}
              end
            end

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)}
        end
      end
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.ErrorPage

      argument :error_page_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        error_page_id = input.arguments.error_page_id
        version_id = input.arguments.version_id

        with {:ok, error_page} when not is_nil(error_page) <-
               Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page_id,
                 tenant: acting_site,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.ErrorPage.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == error_page_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            @admin_fields
            |> Enum.filter(&(&1 != :site_id))
            |> Enum.map(&to_string/1)

          preview_error_page =
            Enum.reduce(restored_attrs, error_page, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)

                value =
                  cond do
                    key_atom == :format and is_binary(value) ->
                      String.to_atom(value)

                    true ->
                      value
                  end

                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_error_page}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this error page.")
                 )
               ]
             )}

          {:error, _} ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)}

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.ErrorPage

      argument :error_page_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        error_page_id = input.arguments.error_page_id
        version_id = input.arguments.version_id

        with {:ok, error_page} when not is_nil(error_page) <-
               Ash.get(MishkaCmsCore.Runtime.ErrorPage, error_page_id,
                 action: :master_get,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.ErrorPage.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == error_page_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            @admin_fields
            |> Enum.filter(&(&1 != :site_id))
            |> Enum.map(&to_string/1)

          preview_error_page =
            Enum.reduce(restored_attrs, error_page, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)

                value =
                  cond do
                    key_atom == :format and is_binary(value) ->
                      String.to_atom(value)

                    true ->
                      value
                  end

                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_error_page}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this error page.")
                 )
               ]
             )}

          {:error, _} ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)}

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.ErrorPage)}
        end
      end
    end
  end

  # Authorization policies for error page access
  policies do
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING, its code included, needs the error page section or code on the request's surface;
    # reading, above, is open to anyone under the surface.
    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:error_page",
                      "admin:api:runtime:error_page",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}
    end

    policy action([:restore_version_api, :master_restore_version]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:error_page",
                      "admin:api:runtime:error_page",
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

    # WHOSE ROWS A READ SHOWS, held to the actor when it runs, whichever read it is — `:read_any`
    # and `:get_any` included: a master (`site_id` nil) reads any site's rows, a site user its own
    # site's, whatever it holds or passes as a tenant. System reads pass `authorize?: false`.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "error_page"

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

  # Background job triggers for error page compilation
  changes do
    change {Changes.SendToOban, []}, on: [:create, :update, :destroy]
    change {Changes.PurgePreviewAssets, []}, on: [:update, :destroy]
  end

  # Multi-tenancy configuration - error pages are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Error pages are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
      description "Human-readable error page configuration name"
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL path pattern for this error page configuration (e.g., '/errors/*', '/404')"
    end

    attribute :root_layout_template, :string do
      allow_nil? true
      public? true
      constraints trim?: true
      description "Root layout template that wraps all error pages"
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
      description "Priority for error page matching (higher = more priority)"
    end

    attribute :extra, :map do
      default %{}
      public? true
      description "Additional metadata or configuration"
    end

    attribute :error_pages, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      status: [
                        type: MishkaCmsCore.Runtime.ErrorStatus,
                        allow_nil?: false
                      ],
                      template: [
                        type: :string,
                        allow_nil?: false
                      ],
                      layout: [
                        type: :map,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "Array of error page configurations: an HTTP status code or :offline, a template and a layout"
    end

    attribute :helpers, {:array, MishkaCmsCore.Runtime.Resources.Embeddeds.Helper} do
      default []
      public? true
      description "Helper function definitions for the error pages"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the error page is active and available for use"
    end

    attribute :precompile, :boolean do
      default false
      public? true

      description "Whether to compile this resource immediately on application restart (true) or lazily on first use (false)"
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
      # Error pages MUST belong to a site
      allow_nil? false
      public? true
      description "The site this error page configuration belongs to"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.ErrorPage.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      read_action :sorted_versions
      sort version_inserted_at: :desc
      description "Versions sorted by insertion time (newest first)"
    end
  end

  calculations do
    calculate :error_module,
              :atom,
              {MishkaCmsCore.Runtime.Resources.Calculations.ModuleName, [global?: false]} do
      description "Generates the runtime module name for error page compilation"
    end

    calculate :configured_statuses, {:array, MishkaCmsCore.Runtime.ErrorStatus} do
      description "Extracts and sorts all configured statuses (HTTP codes, then :offline) from error pages array"

      calculation fn records, _context ->
        Enum.map(records, fn error_page ->
          error_page.error_pages
          |> Enum.map(fn page -> Map.get(page, "status") || Map.get(page, :status) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()
        end)
      end
    end

    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in error page history"

      calculation fn records, _context ->
        Enum.map(records, fn error_page ->
          case MishkaCmsCore.Runtime.ErrorPage.Version
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(version_source_id == ^error_page.id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.ErrorPage.Version
      description "Returns the most recent version for the error page"

      calculation fn records, _context ->
        error_page_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.ErrorPage.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^error_page_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn error_page ->
          Map.get(versions_map, error_page.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.ErrorPage.Version]

      description "Returns the 10 most recent versions for the error page in descending order by insertion date"

      calculation fn records, _context ->
        error_page_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.ErrorPage.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^error_page_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn error_page ->
          Map.get(versions_map, error_page.id, [])
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures error page names are unique within each site for clear identification"
      message dgettext_noop("errors", "Error page name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    # THE PATH IS THE SITE'S OWN ADDRESS, so this identity is what says "one error page per site" —
    # it is no longer a conflict between two paths somebody chose. The message says the thing a
    # reader can act on rather than naming a field they were never shown.
    identity :unique_path_per_site, [:path, :site_id] do
      description "One error page per site: its path is the site's own address"

      message dgettext_noop(
                "errors",
                "This site already has an error page — open that one instead of making another."
              )

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
