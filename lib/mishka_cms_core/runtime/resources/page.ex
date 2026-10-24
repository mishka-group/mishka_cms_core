# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Page do
  @moduledoc """
  Manages web pages in the MishkaCMS runtime system with full versioning support.

  This resource represents individual web pages that are dynamically compiled and rendered
  at runtime. Pages are the core content units of the CMS, containing templates, metadata,
  SEO configurations, and interactive elements. Each page belongs to a specific site and
  can optionally use a layout for consistent structure. The resource supports various
  template formats (HEEx, EEx, Markdown) and provides comprehensive content management
  including sections, schemas, events, and helper functions.

  Pages feature full version control through PaperTrail integration, tracking all changes
  with snapshot-based history and the ability to restore previous versions. The resource
  implements soft deletion via archival, priority-based ordering for path matching, and
  precompilation options for performance optimization. Pages can define custom event handlers
  for LiveView interactions and include resource links for external assets.

  Database-level constraints ensure data integrity with path validation, template presence
  checks, and prevention of modifications to archived pages. Multi-tenant isolation ensures
  pages are properly segregated between sites. The resource provides extensive API actions
  for external integrations and maintains complete audit trails of all modifications including
  actor tracking and action recording.
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
    notifiers: [
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
      MishkaCmsCore.Runtime.Resources.Notifiers.PageEditions
    ],
    authorizers: [Ash.Policy.Authorizer]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  require Ash.Query
  alias MishkaCmsCore.Runtime.Resources.Changes
  alias MishkaCmsCore.Runtime.Helpers, as: RuntimeHelpers
  alias MishkaCmsCore.{LanguageAccent, LanguageEditions}
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
  Format table column and the page detail modal so both draw the same badge from one definition.
  """
  def format_badge_config do
    Map.update!(@format_badge, :labels, fn labels ->
      Map.new(labels, fn {key, label} ->
        {key, Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)}
      end)
    end)
  end

  @doc "Unguessable token for the shareable preview URL (generated on create)."
  def generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @admin_fields [
    :name,
    :title,
    :path,
    :section,
    :template,
    :description,
    :format,
    :priority,
    :extra,
    :content,
    :seo_tags,
    :schema,
    :events,
    :infos,
    :state,
    :resource_links,
    :helpers,
    :uploads,
    :active,
    :precompile,
    :permissions,
    :layout_id,
    :language,
    :language_group_id,
    :site_id
  ]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for page storage with indexing
  postgres do
    table "pages"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:section]
      # A page's other editions are read by this on every mount — see
      # `MishkaCmsCore.Runtime.PageEditions`.
      index [:language_group_id]
    end

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 3 AND length(name) <= 200",
        message: dgettext_noop("errors", "Name must be between 3 and 200 characters.")

      check_constraint :title, "title_length_check",
        check: "length(title) >= 1 AND length(title) <= 200",
        message: dgettext_noop("errors", "Title must be between 1 and 200 characters.")

      check_constraint :path, "path_length_check",
        check: "length(path) >= 1 AND length(path) <= 255",
        message: dgettext_noop("errors", "Path must be between 1 and 255 characters.")

      check_constraint :template, "template_length_check",
        check: "length(template) >= 3",
        message: dgettext_noop("errors", "Template must be at least 3 characters.")

      check_constraint :priority, "priority_range_check",
        check: "priority >= 0 AND priority <= 100",
        message: dgettext_noop("errors", "Priority must be between 0 and 100.")

      # Multiple attributes can share the same constraint
      check_constraint [:name, :path, :template], "no_empty_strings",
        check: "name != '' AND path != '' AND template != ''",
        message: dgettext_noop("errors", "Name, path, and template cannot be empty.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_page_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_page_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived page'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_page_updates();"
      end

      statement :prevent_archived_page_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_page_updates_trigger
          BEFORE UPDATE ON pages
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_page_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_page_updates_trigger ON pages;"
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

  # Version control configuration for full page history tracking
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
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.PagePaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "page"
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :pages
        route "/admin/pages"
        stream_name :pages
      end

      source do
        # The sibling editions belong here rather than in the `on_load` hook: the hook only runs for the
        # list read, and a single-row re-read would come back without them and lose the row's chips.
        preload do
          always [:site]
          master [:layout, master_language_variants: :language_variants]
          tenant [:language_variants, tenant_layout: :layout]
        end
      end

      columns do
        default_sort [{:inserted_at, :desc}]

        column :page_info do
          static true
          requires [:id, :name, :title]
          label fn -> dgettext("mishka_gervaz", "Page") end
          position :first

          ui do
            width "minmax(150px,1.2fr)"
          end

          render fn record ->
            short_id = String.slice(record.id, 0, 8) <> "…" <> String.slice(record.id, -4, 4)

            assigns = %{
              name: record.name,
              title: record.title,
              id: record.id,
              short_id: short_id
            }

            ~H"""
            <div class="min-w-0">
              <div class="truncate text-[13.5px] font-semibold text-[#17161a]" title={@name}>
                {@title}
              </div>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">{@short_id}</span>
                <.copy_button
                  id={"page-id-copy-#{@id}"}
                  value={@id}
                  label={dgettext("mishka_gervaz", "Copy page ID")}
                />
              </div>
            </div>
            """
          end
        end

        column :path_section do
          static true
          requires [:path, :section]
          label fn -> dgettext("mishka_gervaz", "Path & Section") end

          ui do
            width "minmax(120px,1fr)"
          end

          render fn record ->
            assigns = %{path: record.path, section: record.section}

            ~H"""
            <div class="min-w-0">
              <div class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#3a382f]">{@path}</div>
              <div :if={@section} class="mt-[2px] truncate text-[11px] font-medium text-[#a8a5a0]">
                {@section}
              </div>
            </div>
            """
          end
        end

        # One row per page, not one per translation — see `MishkaCmsCore.LanguageEditions`. The row
        # names its own language and a chip for each other one, which opens that edition. A master's
        # editions arrive under `language_variants` too: the preload above names it as the alias.
        column :languages do
          static true
          requires [:id, :language, :language_group_id, :archived_at, :language_variants]
          label fn -> dgettext("mishka_gervaz", "Languages") end

          ui do
            width "minmax(110px,0.9fr)"
          end

          render fn record ->
            assigns = %{
              language: record.language,
              accent: LanguageAccent.of(record),
              editions: LanguageEditions.editions(record, &%{accent: LanguageAccent.of(&1)})
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-[5px]">
              <span class={[
                "inline-flex flex-none items-center gap-1 rounded-[20px] border px-2 py-[3px] text-[9.5px] font-bold",
                @accent.chip
              ]}>
                <span class={["size-1 rounded-full", @accent.fill]}></span>
                {String.upcase(@language || "")}
              </span>
              <button
                :for={edition <- @editions}
                type="button"
                id={"page-edition-#{edition.id}"}
                phx-click="show_edition"
                phx-value-id={edition.id}
                title={
                  dgettext("mishka_gervaz", "Open the %{language} edition",
                    language: String.upcase(edition.language)
                  )
                }
                class={[
                  "inline-flex flex-none items-center gap-1 rounded-[20px] border px-2 py-[3px] text-[9.5px] font-bold transition-opacity hover:opacity-70",
                  edition.accent.chip
                ]}
              >
                <span class={["size-1 rounded-full", edition.accent.fill]}></span>
                {String.upcase(edition.language)}
              </button>
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
            width "minmax(100px,0.85fr)"
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

        column :active_compile do
          static true
          requires [:active, :precompile]
          label fn -> dgettext("mishka_gervaz", "Active & Compile") end

          ui do
            width "minmax(150px,1.25fr)"
          end

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

          ui do
            width "minmax(160px,1.9fr)"
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
        filter :search, :text do
          fields [:title, :name, :path, :section]

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
              RuntimeHelpers.writes?(state, "page")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
          end
        end

        # The page in another language, as a page of its own — see
        # `MishkaCmsCore.Runtime.PageEditions`.
        action :add_translation do
          type :event
          event "add_translation"

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "page")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Add translation") end
            icon "hero-language"
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this page?") end

          visible fn record, state ->
            state.archive_status == :active and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "page")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this page?") end

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "page")
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
                    "Permanently delete this page? This cannot be undone."
                  )

          visible fn record, state ->
            state.archive_status == :archived and
              RuntimeHelpers.master_or_tenant_owned?(record, state) and
              RuntimeHelpers.writes?(state, "page")
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
          handler: {:master_destroy, :destroy},
          confirm: dgettext_noop("mishka_gervaz", "Archive selected pages?")

        action :unarchive,
          handler: {:master_unarchive, :unarchive},
          confirm: dgettext_noop("mishka_gervaz", "Restore selected pages?"),
          visible: :archived

        action :permanent_destroy,
          handler: {:master_permanent_destroy, :permanent_destroy},
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected pages? This cannot be undone."
            ),
          visible: :archived
      end

      realtime do
        prefix "page"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "pages"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No pages found"), icon: "hero-document"

      events do
        bulk_action MishkaCmsCore.LanguageEditions.BulkActionHandler
      end

      hooks do
        switch_to_active_on_empty_archive true
        clear_selection_after_bulk true
        reset_page_on_empty_current_page true

        on_bulk_action_success :unarchive, fn summary, _state, socket ->
          msg =
            if summary.skipped_count > 0 do
              dgettext(
                "mishka_gervaz",
                "Restored %{restored} page(s) as inactive — activate them to go live; skipped %{skipped} (a page with the same name already exists).",
                restored: summary.succeeded_count,
                skipped: summary.skipped_count
              )
            else
              dgettext(
                "mishka_gervaz",
                "Restored %{restored} page(s) as inactive — activate them to go live.",
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

        # A delete refused because the page's translations are live answers with an alert that
        # offers to archive — or delete for good — those translations at once.
        on_row_action_error [:delete, :permanent_destroy], &LanguageEditions.on_delete_refused/3
        on_bulk_action_error [:archive, :permanent_destroy], &LanguageEditions.on_delete_refused/3

        on_bulk_action_success [:archive, :permanent_destroy],
                               &LanguageEditions.on_delete_refused/3

        # One row per page rather than one per translation, lifted while searching — see
        # `MishkaCmsCore.LanguageEditions`. A hook and not the read action, because only a hook runs
        # late enough to see whether a search is active. A live update is asked of the same read, and
        # `on_realtime` redraws a translation's master.
        on_load fn query, state ->
          {:cont, LanguageEditions.scope_to_masters(query, state)}
        end

        on_realtime fn notification, socket ->
          LanguageEditions.on_realtime(notification, socket)
        end
      end
    end

    form do
      identity do
        name :page_form
      end

      fields do
        field :title do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Title") end
            placeholder fn -> dgettext("mishka_gervaz", "Pricing") end
          end
        end

        field :path do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Path") end
            placeholder "/my-page"
          end
        end

        # WHAT EACH ADDRESS OF THE PAGE SHOWS — a post at `/:lang/blog/:slug` — out of the kinds the
        # installed extensions name (`MishkaCmsCore.Runtime.Seo.record_types/1`), kept in `extra` by
        # `MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind`. The extension that owns the kind
        # fills the page's SEO from the record, and the record's own permissions apply.
        field :record, :relation do
          virtual true
          mode :search
          min_chars 0
          page_size 50
          depends_on :site_id

          # Each extension's kinds under its name. Hung on the site, as Layout is, and a function
          # of the form state: that is what has Gervaz load the kinds when the form opens, so a
          # saved one shows its label; a master picks the site first. The kinds are the same on
          # every site, and their samples are not needed here.
          options fn _state ->
            MishkaCmsCore.Runtime.Seo.record_types(nil)
            |> Enum.chunk_by(& &1.group)
            |> Enum.map(fn [%{group: group} | _] = types ->
              {group, Enum.map(types, &{&1.label, &1.id})}
            end)
          end

          include_nil fn -> dgettext("mishka_gervaz", "Custom page: one page, one address") end
          derive_value fn page -> MishkaCmsCore.Runtime.Seo.record_of(page.extra) end

          ui do
            label fn -> dgettext("mishka_gervaz", "This page shows each") end
            placeholder fn -> dgettext("mishka_gervaz", "Custom page: one page, one address") end
          end
        end

        field :section do
          ui do
            label fn -> dgettext("mishka_gervaz", "Section") end
            placeholder fn -> dgettext("mishka_gervaz", "blog, docs, etc.") end
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

        field :language, :combobox do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM pages WHERE language IS NOT NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} -> Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)
              _ -> []
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language") end
            placeholder "en, fa, ar, ..."

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Add this code under Settings → Languages as well, or its URL answers 404."
              )
            end
          end
        end

        # Only the groups of the site the page is on. A master reads every site's rows, and a group on
        # another site is one this page's editions would never be listed or checked with.
        field :language_group_id, :relation do
          value_field :language_group_id
          display_field fn record -> "#{record.name} (#{record.language})" end
          search_field :name
          mode :search
          depends_on :site_id
          include_nil fn -> dgettext("mishka_gervaz", "New Language Group (auto-generate)") end

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            Ash.Query.filter_input(query, %{site_id: site_id})
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language Group") end
          end
        end

        # Only the layouts the page's site may use: that site's and the shared ones. A master's list
        # follows the site the page is on, and holds only shared layouts until one is picked.
        field :layout_id, :relation do
          resource MishkaCmsCore.Runtime.Layout
          display_field :name
          search_field :name
          mode :search
          min_chars 1
          page_size 15
          include_nil fn -> dgettext("mishka_gervaz", "No Layout") end
          depends_on :site_id
          load_action {:master_read, :for_tenant_with_globals}

          load fn query, state ->
            page_site =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            case page_site do
              nil -> Ash.Query.filter(query, is_nil(site_id))
              page_site -> Ash.Query.filter(query, is_nil(site_id) or site_id == ^page_site)
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Layout") end
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

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end

            description fn ->
              dgettext("mishka_gervaz", "Shown by search engines and link previews.")
            end
          end
        end

        field :template, :textarea do
          required false

          ui do
            label fn -> dgettext("mishka_gervaz", "Template") end
            rows 8
          end
        end

        field :content do
          ui do
            label fn -> dgettext("mishka_gervaz", "Content (JSON)") end
            placeholder ~s({"key": "value"})
          end
        end

        field :extra do
          ui do
            label fn -> dgettext("mishka_gervaz", "Extra (JSON)") end
            placeholder ~s({"custom_field": "value"})
          end
        end

        # Above the page's defaults; see `MishkaCmsCore.Runtime.Seo` for what the head renders.
        field :seo_tags, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "SEO Tags") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add SEO Tag") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A title replaces the page's title; meta and link tags each replace the default with the same name. A value may name a variable such as {{page.title}}."
              )
            end
          end

          nested_field :tag, :select do
            options [{"title", "title"}, {"meta", "meta"}, {"link", "link"}]

            ui do
              label fn -> dgettext("mishka_gervaz", "Tag") end
              placeholder fn -> dgettext("mishka_gervaz", "Choose a tag") end
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

        field :schema do
          ui do
            label fn -> dgettext("mishka_gervaz", "Schema (JSON)") end
            placeholder ~s([{"@type": "WebPage", "name": "My Page"}])

            description fn ->
              dgettext("mishka_gervaz", "Leave empty to use the default WebPage.")
            end
          end
        end

        field :state, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "State (starting assigns)") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add State") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Assign Name") end
              placeholder "count"
            end
          end

          nested_field :code, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "First Value") end
              placeholder "0"
              rows 2
              class "font-mono text-sm"
            end
          end
        end

        field :events, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "Events (handle_event)") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Event") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Event Name") end
              placeholder "click, submit, toggle"
            end
          end

          nested_field :code, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Event Code") end
              placeholder "socket = assign(socket, :key, value)"
              rows 6
              class "font-mono text-sm"
            end
          end
        end

        field :infos, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "Infos (handle_info)") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Info Handler") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Info Name") end
              placeholder "update_data, refresh"
            end
          end

          nested_field :code, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Info Code") end
              placeholder "socket = assign(socket, :key, value)"
              rows 6
              class "font-mono text-sm"
            end
          end
        end

        # The label said "(JSON)" while the constraint had it drawing fields all along.
        field :resource_links do
          ui do
            label fn -> dgettext("mishka_gervaz", "Resource Links") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Resource Link") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end
        end

        field :uploads, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "File Uploads") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Upload") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Each one becomes an allow_upload/3 the page calls when a visitor opens it. Use the name in a file field: live and upload={@uploads.<name>}."
              )
            end
          end

          nested_field :name do
            ui do
              label fn -> dgettext("mishka_gervaz", "Upload Name") end
              placeholder "avatar, attachment, resume"
            end
          end

          nested_field :accept do
            ui do
              label fn -> dgettext("mishka_gervaz", "Accepted Types") end
              placeholder "image/*, .pdf"
            end
          end

          nested_field :max_entries, :number do
            ui do
              label fn -> dgettext("mishka_gervaz", "Maximum Files") end
              placeholder "1"
            end
          end

          nested_field :max_file_size, :number do
            ui do
              label fn -> dgettext("mishka_gervaz", "Maximum Size (bytes)") end
              placeholder "8000000"
            end
          end

          nested_field :auto_upload, :toggle do
            ui do
              label fn -> dgettext("mishka_gervaz", "Upload Immediately") end
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
              placeholder "arg1 <> \" \" <> arg2"
              rows 6
              class "font-mono text-sm"
            end
          end
        end

        # WHO MAY OPEN THE PAGE: any of the permission names that exist, stored by name. Empty, it is
        # public. `MishkaCmsWeb.RuntimeLive` shows the 404 to anybody holding none of them, a
        # signed-out visitor included. A page that shows a record (`extra`'s `"record"`) asks for
        # the record's own permissions as well.
        field :permissions, :relation do
          resource MishkaCmsCore.Accounts.Permission
          display_field :name
          search_field :name
          value_field :name
          mode :search_multi
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Permissions") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:title, :path]

          ui do
            columns 3
            class ""
          end
        end

        group :site do
          fields [:site_id]

          ui do
            columns 1
            class ""
          end
        end

        group :layout do
          fields [:layout_id]

          ui do
            columns 1
            class ""
          end
        end

        group :shows do
          fields [:record]

          ui do
            columns 1
            class ""
          end
        end

        group :access do
          fields [:permissions]

          ui do
            columns 1
            class ""
          end
        end

        group :settings do
          fields [
            :section,
            :format,
            :priority,
            :language,
            :language_group_id,
            :active,
            :precompile
          ]

          ui do
            columns 2
            class ""
          end
        end

        group :content do
          fields [:template]

          ui do
            columns 1
            class ""
          end
        end

        group :seo do
          fields [:description, :seo_tags, :schema]

          ui do
            label fn -> dgettext("mishka_gervaz", "SEO") end
            columns 1
            class ""
          end
        end

        group :data do
          fields [
            :content,
            :extra,
            :state,
            :events,
            :infos,
            :resource_links,
            :helpers
          ]

          ui do
            columns 1
            class ""
          end
        end
      end

      # Each help under the field it explains, drawn only while that field is on the form.
      layout do
        notice :record_help do
          position {:after_group, :shows}
          show_when fn state -> Enum.any?(state.static.fields, &(&1.name == :record)) end

          render fn assigns ->
            ~H"""
            <MishkaCmsCore.CoreComponents.tip id="pb-record-help" class="mt-2.5 mb-4">
              {dgettext(
                "mishka_gervaz",
                "Pick a kind when each address of this page shows one record, such as a post at /:lang/blog/:slug. Its extension then fills the SEO, and the record's own permissions apply."
              )}
            </MishkaCmsCore.CoreComponents.tip>
            """
          end
        end

        notice :permissions_help do
          position {:after_group, :access}
          show_when fn state -> Enum.any?(state.static.fields, &(&1.name == :permissions)) end

          render fn assigns ->
            ~H"""
            <MishkaCmsCore.CoreComponents.tip id="pb-permissions-help" class="mt-2.5 mb-4">
              {dgettext(
                "mishka_gervaz",
                "Who may open this page; empty means everyone. If the page shows records, leave it empty: each record's own Permissions are used."
              )}
            </MishkaCmsCore.CoreComponents.tip>
            """
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
      derives: "sanitize(trim) validate(optional=[string, not_empty, min_len=3, max_len=200])"

    field :title, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=200)"

    field :path, :string,
      derives:
        ~S|sanitize(trim) validate(string, not_empty, min_len=1, max_len=255, regex=^(?!.*\.\.)/[a-zA-Z0-9/_*.:-]*$)|

    field :section, :string, derives: "sanitize(trim) validate(optional=[string])"

    field :template, :string,
      derives: "sanitize(trim, no_zero_width, no_control) validate(string, not_empty, min_len=3)"

    field :description, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :format, :atom, derives: "validate(atom, enum=Atom[heex::eex::markdown])"

    field :priority, :integer, derives: "validate(integer, min_len=0, max_len=100)"
    field :active, :boolean, derives: "validate(boolean)"
    field :precompile, :boolean, derives: "validate(boolean)"
    field :extra, :map, derives: "validate(map)"
    field :content, :map, derives: "validate(map)"

    field :seo_tags, {:array, :map}, derives: "validate(list)"
    field :schema, {:array, :map}, derives: "validate(list)"
    field :events, {:array, :map}, derives: "validate(list)"
    field :infos, {:array, :map}, derives: "validate(list)"
    field :state, {:array, :map}, derives: "validate(list)"
    field :resource_links, {:array, :map}, derives: "validate(list)"
    field :helpers, {:array, :map}, derives: "validate(list)"
    field :uploads, {:array, :map}, derives: "validate(list)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=10, language_code])"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields
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
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      # Blank means "I will build it in the editor" — filled in before the validations below
      # ask for a template, so a document can be created without anyone writing HEEx first.
      change MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty

      primary? true

      # before/reject seam
      change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook
      accept List.delete(@admin_fields, :site_id)

      validate present([:title])
      validate present([:path])
      validate present([:template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageStateNames, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageUploads, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulIds, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Checked after the plugin seam above, which may set either link.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true},
               before_action?: true

      # A group's key is its master page's id, so a page joins only its own site's group.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")},
               before_action?: true

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      validate {MishkaCmsCore.Runtime.Resources.Validations.PublicAddress, []},
        before_action?: true

      validate fn changeset, _context ->
        template = Ash.Changeset.get_attribute(changeset, :template)

        if is_binary(template) and String.trim(template) == "" do
          {:error,
           field: :template, message: dgettext_noop("errors", "Template cannot be empty.")}
        else
          :ok
        end
      end

      change slugify(:name, into: :name)
      change Changes.NameFromTitle
      change {Changes.SetLanguageGroupId, before_action?: true}

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      description "Creates page for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      # Blank means "I will build it in the editor" — filled in before the validations below
      # ask for a template, so a document can be created without anyone writing HEEx first.
      change MishkaCmsCore.Runtime.Resources.Changes.BlankTemplateStartsEmpty

      multitenancy :bypass

      validate present([:title])
      validate present([:path])
      validate present([:template])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageStateNames, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageUploads, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulIds, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      # A group's key is its master page's id, so a page joins only its own site's group.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PublicAddress, []},
        before_action?: true

      validate fn changeset, _context ->
        template = Ash.Changeset.get_attribute(changeset, :template)

        if is_binary(template) and String.trim(template) == "" do
          {:error,
           field: :template, message: dgettext_noop("errors", "Template cannot be empty.")}
        else
          :ok
        end
      end

      change slugify(:name, into: :name)
      change Changes.NameFromTitle
      change {Changes.SetLanguageGroupId, before_action?: true}

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      description "Creates page for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      # A group's key is its master page's id, so a page joins only its own site's group.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived page. Please unarchive it first.")
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PublicAddress, []},
        before_action?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageStateNames, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageUploads, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulIds, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      validate fn changeset, _context ->
        template = Ash.Changeset.get_attribute(changeset, :template)

        if is_binary(template) and String.trim(template) == "" do
          {:error,
           field: :template, message: dgettext_noop("errors", "Template cannot be empty.")}
        else
          :ok
        end
      end

      change slugify(:name, into: :name)
      change {Changes.SetLanguageGroupId, before_action?: true}

      description "Updates page for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      description "Updates page for master users - bypasses tenant context, prevents site_id changes"
      require_atomic? false
      multitenancy :bypass
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      # A group's key is its master page's id, so a page joins only its own site's group.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived page. Please unarchive it first.")
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PublicAddress, []},
        before_action?: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.PageCodeCompiles, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageStateNames, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.PageUploads, []}
      validate {MishkaCmsCore.Runtime.Resources.Validations.StatefulIds, []}

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}
      change {MishkaCmsCore.Runtime.Resources.Changes.SignCode, []}

      validate fn changeset, _context ->
        template = Ash.Changeset.get_attribute(changeset, :template)

        if is_binary(template) and String.trim(template) == "" do
          {:error,
           field: :template, message: dgettext_noop("errors", "Template cannot be empty.")}
        else
          :ok
        end
      end

      change slugify(:name, into: :name)
      change {Changes.SetLanguageGroupId, before_action?: true}
    end

    read :archived do
      description "Lists archived pages within current tenant context"
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived pages system-wide, bypassing tenant filtering"
    end

    read :get_archived do
      description "Retrieves single archived page for recovery or inspection (tenant users)"
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived page for recovery or inspection (master users)"
    end

    read :master_read do
      description "Reads all pages system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single page by ID, bypassing tenant filtering (master users)"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_priority do
      description "Lists pages ordered by priority for path matching precedence"
      pagination offset?: true, default_limit: 100
      prepare build(sort: [priority: :desc, name: :asc])
    end

    read :by_path do
      description "Retrieves page by exact path match for routing"
      argument :path, :string, allow_nil?: false
      filter expr(path == ^arg(:path))
    end

    read :by_token do
      get? true
      multitenancy :bypass
      argument :preview_token, :string, allow_nil?: false
      filter expr(preview_token == ^arg(:preview_token))
      description "Resolve a live page by its preview token (for the shareable preview URL)."
    end

    read :by_section do
      description "Filters pages by section for content organization"
      argument :section, :string, allow_nil?: false
      filter expr(section == ^arg(:section))
    end

    read :by_layout do
      description "Lists all pages using a specific layout"
      argument :layout_id, :uuid, allow_nil?: false
      filter expr(layout_id == ^arg(:layout_id))
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
      description "Reads pages bypassing tenant filtering (internal use)"
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      multitenancy :bypass

      pagination keyset?: true,
                 offset?: true,
                 default_limit: 100,
                 max_page_size: 250,
                 countable: true,
                 required?: false
    end

    read :get_any do
      description "Retrieves single page by ID, bypassing tenant filtering (internal use)"
      get? true
      multitenancy :bypass
    end

    destroy :destroy do
      description "Soft deletes page by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Page is already archived.")}
        else
          :ok
        end
      end

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change set_attribute(:active, false)
    end

    destroy :master_destroy do
      description "Soft deletes page by archiving (master users) - bypasses tenant context"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Page is already archived.")}
        else
          :ok
        end
      end

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change set_attribute(:active, false)
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      # A PAGE ARCHIVED BEFORE IT HAD A LANGUAGE GROUP gets one here, in the restoring write: the
      # only write the archived-page trigger lets through, so `PageLanguageBackfill` skips it.
      change {Changes.SetLanguageGroupId, before_action?: true}
      change Changes.PreventOrphanedTranslationRestore
      atomic_upgrade_with :archived

      description "Restores an archived page as inactive — activate it to compile and go live (tenant users)"
    end

    update :master_unarchive do
      description "Restores an archived page as inactive — activate it to compile and go live (master users) - bypasses tenant context"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "Page is not archived.")
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:active, false)

      # A page archived before it had a language group, as in `:unarchive`.
      change {Changes.SetLanguageGroupId, before_action?: true}
      change Changes.PreventOrphanedTranslationRestore
      atomic_upgrade_with :master_get_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      description "Permanently removes page and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes page and version history from database (master users) - irreversible and extremely dangerous"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
    end

    # VERSION MANAGEMENT
    read :get_with_versions do
      get? true
      description "Gets a single page with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Page.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :master_get_with_versions do
      get? true
      multitenancy :bypass
      description "Gets a single page with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.Page.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a page with pagination (tenant users)"

      argument :page_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        page_id = Ash.Query.get_argument(query, :page_id)

        case Ash.get(MishkaCmsCore.Runtime.Page, page_id,
               tenant: acting_site,
               authorize?: false
             ) do
          {:ok, _page} ->
            query
            |> Ash.Query.filter(id == ^page_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaCmsCore.Runtime.Page.Version
                |> Ash.Query.for_read(:read_any)
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Page)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a page with pagination (master users)"

      argument :page_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        page_id = Ash.Query.get_argument(query, :page_id)

        query
        |> Ash.Query.filter(id == ^page_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.Page.Version
            |> Ash.Query.for_read(:read_any)
        )
      end
    end

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the page to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived page. Please unarchive it first."
                )
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.Page.Version}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PublicAddress, []},
        before_action?: true

      # A version written before the rule may name another site's record; restoring it does not.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}
    end

    action :restore_version_api, :struct do
      description "Restores page content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.Page

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run {MishkaCmsCore.Runtime.Resources.Actions.RestoreVersion,
           resource: MishkaCmsCore.Runtime.Page,
           version: MishkaCmsCore.Runtime.Page.Version,
           read: :read,
           tenant_read?: true,
           archived:
             dgettext_noop(
               "errors",
               "Cannot restore version of archived page. Please unarchive it first."
             ),
           foreign: dgettext_noop("errors", "Version does not belong to this page.")}
    end

    action :master_restore_version, :struct do
      description "Restores page content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Page

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run {MishkaCmsCore.Runtime.Resources.Actions.RestoreVersion,
           resource: MishkaCmsCore.Runtime.Page,
           version: MishkaCmsCore.Runtime.Page.Version,
           read: :master_get,
           archived:
             dgettext_noop(
               "errors",
               "Cannot restore version of archived page. Please unarchive it first."
             ),
           foreign: dgettext_noop("errors", "Version does not belong to this page.")}
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.Page

      argument :page_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        page_id = input.arguments.page_id
        version_id = input.arguments.version_id

        with {:ok, page} when not is_nil(page) <-
               Ash.get(MishkaCmsCore.Runtime.Page, page_id,
                 tenant: acting_site,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Page.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == page_id, do: :valid, else: :invalid) do
          preview_page =
            MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion.preview(
              page,
              MishkaCmsCore.Runtime.Page,
              version.changes
            )

          {:ok, preview_page}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this page.")
                 )
               ]
             )}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Page)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Page)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.Page

      argument :page_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        page_id = input.arguments.page_id
        version_id = input.arguments.version_id

        with {:ok, page} when not is_nil(page) <-
               Ash.get(MishkaCmsCore.Runtime.Page, page_id,
                 action: :master_get,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.Page.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == page_id, do: :valid, else: :invalid) do
          preview_page =
            MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion.preview(
              page,
              MishkaCmsCore.Runtime.Page,
              version.changes
            )

          {:ok, preview_page}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "Version does not belong to this page.")
                 )
               ]
             )}

          {:error, _} ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Page)}

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.Page)}
        end
      end
    end
  end

  # Authorization policies for page access
  policies do
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)
      authorize_if accessing_from(MishkaCmsCore.Runtime.Layout, :layout)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING, its code included, needs the page section or code on the request's surface;
    # reading, above, is open to anyone under the surface.
    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      "admin:api:runtime:page",
                      "admin:dashboard:code",
                      "admin:api:code"
                    ]}
    end

    policy action([:restore_version_api, :master_restore_version]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      "admin:api:runtime:page",
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

  # PubSub notifications for real-time updates
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "page"

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

  # Background job triggers for page compilation
  changes do
    change {Changes.SendToOban, []}, on: [:create, :update, :destroy]
    change Changes.RegisterTranslationKeys, on: [:create, :update]
    change {Changes.PurgePreviewAssets, []}, on: [:update, :destroy]
  end

  # Multi-tenancy configuration - pages are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
      description "Human-readable Page name"
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200, trim?: true
      description "What the page is called, in the language it is written in — never slugified"
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL path pattern for this page (e.g., '/blog/*', '/about')"
    end

    attribute :section, :string do
      allow_nil? true
      public? true
      constraints trim?: true
      description "Section or category this page belongs to"
    end

    attribute :template, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, trim?: true
      description "Template content (HTML, HEEx, etc.)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "The page's meta description, shown by search engines and link previews"
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
      description "Priority for page matching (higher = more priority)"
    end

    attribute :extra, :map do
      default %{}
      public? true
      description "Additional metadata or configuration"
    end

    attribute :content, :map do
      default %{}
      public? true
      description "Dynamic content data for the page"
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

    attribute :schema, {:array, :map} do
      default []
      public? true
      description "Schema.org structured data"
    end

    attribute :events, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      name: [
                        type: :string,
                        allow_nil?: false
                      ],
                      code: [
                        type: :string,
                        allow_nil?: false
                      ]
                    ]
                  ]

      description "Page-level event handlers with name and code"
    end

    attribute :infos, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      name: [
                        type: :string,
                        allow_nil?: false
                      ],
                      code: [
                        type: :string,
                        allow_nil?: false
                      ]
                    ]
                  ]

      description "Page-level info handlers with name and code"
    end

    attribute :state, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      name: [
                        type: :string,
                        allow_nil?: false
                      ],
                      code: [
                        type: :string,
                        allow_nil?: false
                      ]
                    ]
                  ]

      description "The assigns the page starts with: each name and the Elixir expression of its first value"
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

    attribute :helpers, {:array, MishkaCmsCore.Runtime.Resources.Embeddeds.Helper} do
      default []
      public? true
      description "Helper function definitions for the page"
    end

    attribute :uploads, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      name: [
                        type: :string,
                        allow_nil?: false
                      ],
                      accept: [
                        type: :string,
                        allow_nil?: true
                      ],
                      max_entries: [
                        type: :integer,
                        allow_nil?: true
                      ],
                      max_file_size: [
                        type: :integer,
                        allow_nil?: true
                      ],
                      auto_upload: [
                        type: :boolean,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "Live file uploads this page accepts, one per `allow_upload/3` the compiler emits"
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the page is active and available for use"
    end

    attribute :precompile, :boolean do
      default false
      public? true

      description "Whether to compile this resource immediately on application restart (true) or lazily on first use (false)"
    end

    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to access this page"
    end

    attribute :preview_token, :string do
      public? true
      description "Unguessable token for the shareable full-LiveView preview URL"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Language the page is written in (a language code, e.g. en, fa, pt-br)"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking every language edition of this page; the master's own id"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this page belongs to"
    end

    belongs_to :layout, MishkaCmsCore.Runtime.Layout do
      allow_nil? true
      public? true
      description "The layout this page uses (optional)"

      filter expr(is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :tenant_layout, MishkaCmsCore.Runtime.Layout do
      public? true
      source_attribute :layout_id
      define_attribute? false
      read_action :for_tenant_with_globals
      description "The layout this page uses (tenant access with globals)"
    end

    has_many :language_variants, MishkaCmsCore.Runtime.Page do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "Every language edition of this page, itself included"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_language_variants, MishkaCmsCore.Runtime.Page do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      read_action :read_any
      description "Every language edition of this page (master admin access, bypass tenant)"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.Page.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    calculate :page_module,
              :atom,
              {MishkaCmsCore.Runtime.Resources.Calculations.ModuleName, [global?: false]} do
      description "Generates the runtime module name for page compilation"
      public? true
    end

    # THE PAGE'S OWN SITE'S LAYOUT OR A SHARED ONE, and nothing else, whoever loads it: the compiler
    # wraps the public page in this, so a layout of another site would put that site's template on
    # this one. Read as the system through the page's site, not through the id alone.
    calculate :loaded_layout, :map do
      description "Loads the page's layout — its own site's or a shared one — if present"
      public? true

      calculation fn records, _context ->
        Enum.map(records, fn
          %{layout_id: layout_id, site_id: site_id} when is_binary(layout_id) ->
            MishkaCmsCore.Runtime.Layout
            |> Ash.Query.for_read(:get_for_tenant_with_globals, %{},
              tenant: site_id,
              authorize?: false
            )
            |> Ash.Query.filter(id == ^layout_id)
            |> Ash.Query.load([:site])
            |> Ash.read_one(authorize?: false)
            |> case do
              {:ok, layout} -> layout
              _error -> nil
            end

          _no_layout ->
            nil
        end)
      end
    end

    calculate :version_preview,
              :map,
              {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
               version: MishkaCmsCore.Runtime.Page.Version} do
      public? true
      argument :version_id, :uuid, allow_nil?: false

      description "Retrieves content from one of this record's own versions for preview before restoration"
    end

    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in page history"

      calculation fn records, _context ->
        Enum.map(records, fn page ->
          case MishkaCmsCore.Runtime.Page.Version
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(version_source_id == ^page.id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.Page.Version
      description "Returns the most recent version for the page"

      calculation fn records, _context ->
        page_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Page.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^page_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn page ->
          Map.get(versions_map, page.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.Page.Version]

      description "Returns the 10 most recent versions for the page in descending order by insertion date"

      calculation fn records, _context ->
        page_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.Page.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^page_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn page ->
          Map.get(versions_map, page.id, [])
        end)
      end
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures page names are unique within each site for clear identification"
      message dgettext_noop("errors", "Page name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_preview_token, [:preview_token] do
      description "Preview tokens are globally unique"
      message dgettext_noop("errors", "Preview token collision.")
      all_tenants? true
      nils_distinct? true
    end

    identity :unique_path_per_site, [:path, :site_id] do
      description "Prevents path conflicts by ensuring unique URLs per site for proper routing"
      message dgettext_noop("errors", "Page path must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    # NULLS DISTINCT, unlike blog posts and documents, which had the column from their first row. A
    # page stored before it has no group until `MishkaCmsCore.Runtime.PageLanguageBackfill` runs at
    # boot, and the migration creating this index runs before that — on a database where every old
    # page is (en, NULL, site), which an index whose NULLs are not distinct refuses. Every page written
    # since has a group, so nothing that holds one is left unchecked.
    identity :unique_language_per_group, [:language, :language_group_id, :site_id] do
      description "Ensures each language appears only once per language group within a site"

      message dgettext_noop(
                "errors",
                "A page with this language already exists in this language group."
              )

      all_tenants? true
    end
  end
end
