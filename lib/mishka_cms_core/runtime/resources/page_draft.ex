# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageDraft do
  @moduledoc """
  An unpublished working copy of a runtime `MishkaCmsCore.Runtime.Page`.

  A draft holds the same editable fields as a Page plus:

    * `source_page_id` — the live Page it edits, or `nil` for a brand-new draft-only page.
    * `preview_token` — an unguessable token for the shareable `/_preview/:token` URL.
    * `status` (`:draft` / `:published`) and `applied_at` — set when the draft is published.

  Publishing is explicit (`:publish` / `:master_publish`): it writes the draft's fields to the
  live Page (creating it when `source_page_id` is `nil`, otherwise updating all but the page's
  `events`, `infos` and `helpers`), which runs the normal Page compile pipeline, then marks the
  draft published. See `MishkaCmsCore.Runtime.Resources.Changes.PublishPageDraft`.

  Mirrors `MishkaCmsCore.Runtime.Page`'s conventions (tenant-scoped, master/tenant action
  pairs) but carries no version history of its own — the live Page already versions on publish.

  ## Upgrading across 2026-08-01

  This resource and its two siblings — `MishkaCmsCore.Runtime.LayoutDraft` and
  `MishkaCmsCore.Runtime.ErrorPageDraft` — used `AshArchival` until 2026-08-01. Discarding a draft
  set `archived_at` instead of removing the row, and a `base_filter_sql "(archived_at IS NULL)"`
  kept it out of every read.

  Removing the extension made discard a real delete, and took the base filter with it. Any row still
  carrying an `archived_at` therefore became **visible again** — a draft its author threw away is
  back in the picker, publishable over the live page, and reachable at its preview token. That
  happens on `git pull`, before any migration runs.

  If your database predates that date, run the purge BEFORE the migration that drops the column,
  because afterwards a discarded draft is indistinguishable from live work:

      mix mishka_cms_core.purge_draft_archival --dry-run
      mix mishka_cms_core.purge_draft_archival

  See `Mix.Tasks.MishkaCmsCore.PurgeDraftArchival` for the release equivalent and the exact rows it
  matches. A database created after that date needs nothing; the task is a no-op there.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSlug, MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Runtime.Resources.Changes
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  require Ash.Query

  @editable_fields [
    :label,
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
    :active,
    :precompile,
    :permissions,
    :source_page_id,
    :layout_id,
    :language,
    :language_group_id
  ]

  @admin_fields @editable_fields ++ [:site_id]

  @doc "Generate an unguessable URL-safe preview token."
  def generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  postgres do
    table "page_drafts"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :source_page, on_delete: :delete
      reference :layout, on_delete: :nilify
    end

    custom_indexes do
      index [:site_id]
      index [:source_page_id]
      index [:status]
      index [:applied_at]
      # The activity log orders this table by `updated_at DESC LIMIT k` (see
      # `MishkaCmsCore.Activity.Query`, which pushes the ORDER BY into each branch so it can ride an
      # index). It could not use one while the branch ordered by `COALESCE(archived_at, updated_at)`;
      # now that these resources no longer archive and the branch orders by the bare column, it can.
      # AshPostgres prefixes the multitenancy attribute, so this is `(site_id, updated_at)` — which
      # serves a TENANT read. A master read carries no site predicate at all, and Postgres cannot
      # order by the second column of a composite whose first is unconstrained, so it needs the bare
      # index too. Same pair the paper-trail mixins declare for `version_inserted_at`.
      index [:updated_at]
      index [:updated_at], all_tenants?: true
    end
  end

  # The page builder's draft picker. It reads one document's pending drafts and nothing else, which
  # is what `hooks` enforces: the scoping id arrives as a path param, and a request without one is
  # answered with an empty list rather than with every site's drafts.
  mishka_gervaz do
    table do
      identity do
        name :page_drafts
        route "/admin/dashboard/runtime/pages"
        stream_name :page_drafts
      end

      pagination do
        type :load_more
        page_size 50
      end

      columns do
        default_sort updated_at: :desc

        column :label do
          label fn -> dgettext("mishka_gervaz", "Label") end
        end
      end

      # Searching by name is the only filter a draft list needs: the rows are already scoped to one
      # document, and what an author looks for is the name they gave it.
      filters do
        filter :search, :text do
          fields [:label]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end
      end

      # Deleting is the only thing worth doing to several drafts at once. Everything else — opening,
      # forking — is inherently one at a time.
      bulk_actions do
        action :destroy,
          type: :destroy,
          confirm:
            dgettext_noop("mishka_gervaz", "Delete the selected drafts? This cannot be undone.")
      end

      # Every editor on the site would otherwise be subscribed to every draft write, including drafts
      # of documents it is not showing. The list is reread when the editor says so, not when someone
      # else saves.
      realtime do
        enabled false
      end

      # Open, copy, delete — declared here rather than hand-drawn in the template, so the visibility
      # rule, the confirm text and the icon all live with the resource like every other table's.
      #
      # `:event` rather than `:destroy` even for Delete: all three have to reach the EDITOR, not just
      # the row. Deleting the draft being edited must also clear the save target and the resume bar,
      # and opening one replaces the working tree — none of which the table can do for itself.
      row_actions do
        # No built-in copies a record, so this is a TYPE the table understands rather than a custom
        # event routed around it — see `MishkaCmsCoreWeb.TableActions.Fork`.
        action :fork_draft do
          type MishkaCmsCoreWeb.TableActions.Fork

          ui do
            label fn -> dgettext("mishka_gervaz", "Copy") end
            icon "hero-document-duplicate"

            class "grid size-[22px] flex-none place-items-center rounded-[7px] text-[#a8a5a0] hover:bg-white hover:text-[#4f4bcc] [&_.lbl]:hidden"
          end
        end

        # The BUILT-IN destroy — the table already knows how to delete a row, and now that these
        # resources no longer archive, destroying one is a real delete. `after_row_action` is what
        # tells the editor, because the row it removed may be the one being saved to.
        action :delete_draft do
          type :destroy

          # `:destroy` defaults to `visible :active`, which asks the table for an archive status
          # these resources no longer have — so the button silently never drew. Nothing to scope it
          # to any more: a draft is always deletable.
          visible true

          confirm fn record ->
            dgettext("mishka_gervaz", "Delete the draft “%{label}”? This cannot be undone.",
              label: record.label
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"

            class "grid size-[22px] flex-none place-items-center rounded-[7px] text-[#a8a5a0] hover:bg-white hover:text-[#c0392b] [&_.lbl]:hidden"
          end
        end
      end

      hooks do
        # The table deletes the row itself; only the EDITOR's share of the consequence is left — the
        # deleted draft may be the one being saved to, or the one the resume bar is offering. A
        # LiveComponent's `self()` is the parent LiveView, which is what makes this a message.
        after_row_action :delete_draft, fn result, state ->
          send(self(), {:draft_row_action, "delete_draft", record_id(result)})
          {:ok, state}
        end

        # Forking has no built-in to defer to, so the whole of it happens in the editor, which is
        # where the working document and the free-name rule already live.
        override_row_action :fork, fn payload, state ->
          send(self(), {:draft_row_action, "fork_draft", payload["id"]})
          {:ok, state}
        end

        on_load fn
          query, %{path_params: %{source_page_id: id}} when not is_nil(id) ->
            {:cont, Ash.Query.filter(query, is_nil(applied_at) and source_page_id == ^id)}

          query, _unscoped ->
            {:cont, Ash.Query.filter(query, false)}
        end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.DraftList
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end
    end

    # WHAT AN EDITOR'S SETTINGS EDIT ON A DRAFT — the same fields, with the same rules, as the
    # page's own form, so a draft cannot be given what the page itself would refuse.
    form do
      identity do
        name :page_draft_form
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

        # WHO MAY OPEN THE PAGE: any of the permission names that exist, stored by name. Empty, it is
        # public. `MishkaCmsWeb.RuntimeLive` shows the 404 to anybody holding none of them, a
        # signed-out visitor included.
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

      # The page's own rows: name, address and layout; what each address shows; who may open it.
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
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      primary? true
      accept @editable_fields

      validate present([:name])
      validate present([:title])
      validate present([:path])
      validate present([:template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_page_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      change slugify(:name, into: :name)

      description "Creates a draft for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      multitenancy :bypass

      validate present([:name])
      validate present([:title])
      validate present([:path])
      validate present([:template])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_page_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      change slugify(:name, into: :name)

      description "Creates a draft for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      primary? true
      require_atomic? false
      accept @editable_fields

      validate {TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_page_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)
    end

    update :master_update do
      # The kind of record each address shows, written into `extra`.
      argument :record, :string, allow_nil?: true
      change MishkaCmsCore.Runtime.Resources.Changes.SetRecordKind

      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      require_atomic? false
      multitenancy :bypass
      accept @editable_fields

      validate {TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_page_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :language_group_id,
                resource: MishkaCmsCore.Runtime.Page,
                label: dgettext_noop("errors", "language group")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)
    end

    update :publish do
      require_atomic? false
      transaction? true
      accept []

      validate {TenantContext, require_master: false}

      validate absent(:applied_at) do
        message dgettext_noop("errors", "This draft has already been published.")
      end

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :published)
        |> Ash.Changeset.force_change_attribute(
          :applied_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
      end

      change Changes.PublishPageDraft

      description "Publishes a draft to its live page (tenant users)."
    end

    update :master_publish do
      require_atomic? false
      transaction? true
      multitenancy :bypass
      accept []

      validate {TenantContext, require_master: true}

      validate absent(:applied_at) do
        message dgettext_noop("errors", "This draft has already been published.")
      end

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :published)
        |> Ash.Changeset.force_change_attribute(
          :applied_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
      end

      change Changes.PublishPageDraft

      description "Publishes a draft to its live page (master users)."
    end

    read :master_read do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      validate {TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true

      validate {TenantContext, require_master: true}
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

      pagination keyset?: true,
                 offset?: true,
                 default_limit: 100,
                 countable: true,
                 required?: false
    end

    read :get_any do
      get? true
      multitenancy :bypass
    end

    read :by_token do
      get? true
      multitenancy :bypass
      argument :preview_token, :string, allow_nil?: false
      filter expr(preview_token == ^arg(:preview_token))
      description "Resolve a draft by its preview token (for the shareable preview URL)."
    end

    read :by_source_page do
      multitenancy :bypass
      argument :source_page_id, :uuid, allow_nil?: false
      filter expr(source_page_id == ^arg(:source_page_id))
      prepare build(sort: [inserted_at: :desc])
    end

    # Paginated list of a page's PENDING (unpublished) drafts, newest first — backs the
    # multi-draft picker in the preview modal. Tenant-scoped variant + master bypass variant.
    read :drafts_for_page do
      argument :source_page_id, :uuid, allow_nil?: false
      filter expr(source_page_id == ^arg(:source_page_id) and is_nil(applied_at))
      prepare build(sort: [inserted_at: :desc])
      pagination offset?: true, default_limit: 5, max_page_size: 50, countable: true
    end

    read :master_drafts_for_page do
      multitenancy :bypass
      argument :source_page_id, :uuid, allow_nil?: false
      filter expr(source_page_id == ^arg(:source_page_id) and is_nil(applied_at))
      prepare build(sort: [inserted_at: :desc])
      pagination offset?: true, default_limit: 5, max_page_size: 50, countable: true

      validate {TenantContext, require_master: true}
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate {TenantContext, require_master: false}
    end

    destroy :master_destroy do
      require_atomic? false
      multitenancy :bypass
      validate {TenantContext, require_master: true}
    end
  end

  policies do
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING A DRAFT IS WRITING ITS PAGE: the page section or code, on the request's surface;
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
    prefix "page_draft"

    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :publish, [[nil, :site_id], "updated"]
    publish :master_publish, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string do
      allow_nil? true
      public? true
      constraints max_length: 120, trim?: true
      description "Short human label that distinguishes one draft of a page from another"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
      description "Human-readable draft name"
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200, trim?: true
      description "What the page this draft produces is called — never slugified"
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL path pattern for the page this draft produces"
    end

    attribute :section, :string do
      allow_nil? true
      public? true
      constraints trim?: true
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
    end

    attribute :format, :atom do
      default :heex
      public? true
      constraints one_of: [:heex, :eex, :markdown]
    end

    attribute :priority, :integer do
      default 0
      public? true
      constraints min: 0, max: 100
    end

    attribute :extra, :map do
      default %{}
      public? true
    end

    attribute :content, :map do
      default %{}
      public? true
    end

    attribute :seo_tags, {:array, :map} do
      default []
      public? true
    end

    attribute :schema, {:array, :map} do
      default []
      public? true
    end

    attribute :events, {:array, :map} do
      default []
      public? true
    end

    attribute :infos, {:array, :map} do
      default []
      public? true
    end

    attribute :state, {:array, :map} do
      default []
      public? true
    end

    attribute :resource_links, {:array, :map} do
      default []
      public? true
    end

    attribute :helpers, {:array, MishkaCmsCore.Runtime.Resources.Embeddeds.Helper} do
      default []
      public? true
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the published page should be active"
    end

    attribute :precompile, :boolean do
      default false
      public? true
    end

    attribute :permissions, {:array, :string} do
      default []
      public? true
    end

    attribute :preview_token, :string do
      allow_nil? false
      public? true
      description "Unguessable token for the shareable preview URL"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Language the published page is written in"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "The page's language group; nil keeps the page's own or starts a new one"
    end

    # THE DOCUMENT AS IT WAS WHEN THIS DRAFT WAS MADE, as `MishkaCmsCore.Runtime.Authoring.Drafts.hash/2`
    # fingerprints it, so the editor can say the original changed since. Written by `Drafts` alone.
    attribute :source_hash, :integer do
      public? true
      description "Fingerprint of the original document when this draft was made"
    end

    attribute :status, :atom do
      default :draft
      public? true
      constraints one_of: [:draft, :published]
      description "Draft lifecycle state"
    end

    attribute :applied_at, :utc_datetime do
      allow_nil? true
      public? true
      description "When the draft was published to its live page"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this draft belongs to"
    end

    belongs_to :source_page, MishkaCmsCore.Runtime.Page do
      read_action :read_any
      allow_nil? true
      public? true
      description "The live page this draft edits (nil for a brand-new draft-only page)"
    end

    belongs_to :layout, MishkaCmsCore.Runtime.Layout do
      read_action :read_any
      allow_nil? true
      public? true
      description "The layout the published page uses (optional)"
    end
  end

  identities do
    identity :unique_preview_token, [:preview_token] do
      description "Preview tokens are globally unique"
      message dgettext_noop("errors", "Preview token collision.")
      all_tenants? true
    end
  end

  defp record_id(%{id: id}), do: id
  defp record_id({:ok, %{id: id}}), do: id
  defp record_id(_other), do: nil
end
