defmodule MishkaCmsCore.Runtime.ErrorPageDraft do
  @moduledoc """
  An unpublished working copy of a runtime `MishkaCmsCore.Runtime.ErrorPage` — the ErrorPage analogue
  of `MishkaCmsCore.Runtime.PageDraft`.

  Unlike Page/Layout (a single `:template`), an ErrorPage's editable content is the **`error_pages`
  collection** (a list of `%{status, template, layout}`), so a draft carries that whole collection.
  The preview modal's Code tab edits the collection serialized as `<!-- 404 -->`-delimited blocks —
  `<!-- offline -->` for the offline page, see `MishkaCmsCore.Runtime.ErrorStatus` — (round-tripped
  via `RuntimePreview.source/1` + `RuntimePreview.parse_error_pages/1`).

  Publishing is explicit (`:publish` / `:master_publish`): it writes the draft's fields to the live
  ErrorPage (creating it when `source_error_page_id` is `nil`, otherwise updating all but its
  `helpers`). See `MishkaCmsCore.Runtime.Resources.Changes.PublishErrorPageDraft`. Per-site only
  (`global? false`), like Page.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshSlug, MishkaGervaz.Resource],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Runtime.Resources.Changes
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  require Ash.Query

  @editable_fields [
    :label,
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
    :source_error_page_id
  ]

  @admin_fields @editable_fields ++ [:site_id]

  @doc "Generate an unguessable URL-safe preview token."
  def generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  postgres do
    table "error_page_drafts"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :source_error_page, on_delete: :delete
    end

    custom_indexes do
      index [:site_id]
      index [:source_error_page_id]
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
        name :error_page_drafts
        route "/admin/dashboard/runtime/error-pages"
        stream_name :error_page_drafts
      end

      pagination do
        type :load_more
        page_size 50
      end

      columns do
        default_sort updated_at: :desc

        column :label
      end

      # Searching by name is the only filter a draft list needs: the rows are already scoped to one
      # document, and what an author looks for is the name they gave it.
      filters do
        filter :search, :text, fields: [:label]
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
          query, %{path_params: %{source_error_page_id: id}} when not is_nil(id) ->
            {:cont, Ash.Query.filter(query, is_nil(applied_at) and source_error_page_id == ^id)}

          query, _unscoped ->
            {:cont, Ash.Query.filter(query, false)}
        end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.DraftList
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end
    end

    # WHAT THE BUILDER'S SETTINGS EDIT ON A DRAFT — the same fields, with the same rules, as the
    # error page's own form; see `MishkaCmsCoreWeb.Live.Admin.Builder.Panels.settings_modal/1`.
    form do
      identity do
        name :error_page_draft_form
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
      end
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      primary? true
      accept @editable_fields

      validate present([:name])
      validate present([:path])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_error_page_id,
                resource: MishkaCmsCore.Runtime.ErrorPage,
                label: dgettext_noop("errors", "error page")}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      change slugify(:name, into: :name)

      description "Creates an error-page draft for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      multitenancy :bypass

      validate present([:name])
      validate present([:path])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_error_page_id,
                resource: MishkaCmsCore.Runtime.ErrorPage,
                label: dgettext_noop("errors", "error page")}

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      change slugify(:name, into: :name)

      description "Creates an error-page draft for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      primary? true
      require_atomic? false
      accept @editable_fields

      validate {TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_error_page_id,
                resource: MishkaCmsCore.Runtime.ErrorPage,
                label: dgettext_noop("errors", "error page")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      change slugify(:name, into: :name)
    end

    update :master_update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      require_atomic? false
      multitenancy :bypass
      accept @editable_fields

      validate {TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_error_page_id,
                resource: MishkaCmsCore.Runtime.ErrorPage,
                label: dgettext_noop("errors", "error page")}

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

      change Changes.PublishErrorPageDraft

      description "Publishes a draft to its live error page (tenant users)."
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

      change Changes.PublishErrorPageDraft

      description "Publishes a draft to its live error page (master users)."
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

    read :by_source_error_page do
      multitenancy :bypass
      argument :source_error_page_id, :uuid, allow_nil?: false
      filter expr(source_error_page_id == ^arg(:source_error_page_id))
      prepare build(sort: [inserted_at: :desc])
    end

    # Paginated list of an error page's PENDING (unpublished) drafts, newest first — backs the
    # multi-draft picker in the preview modal. Tenant-scoped variant + master bypass variant.
    read :drafts_for_error_page do
      argument :source_error_page_id, :uuid, allow_nil?: false
      filter expr(source_error_page_id == ^arg(:source_error_page_id) and is_nil(applied_at))
      prepare build(sort: [inserted_at: :desc])
      pagination offset?: true, default_limit: 5, max_page_size: 50, countable: true
    end

    read :master_drafts_for_error_page do
      multitenancy :bypass
      argument :source_error_page_id, :uuid, allow_nil?: false
      filter expr(source_error_page_id == ^arg(:source_error_page_id) and is_nil(applied_at))
      prepare build(sort: [inserted_at: :desc])
      pagination offset?: true, default_limit: 5, max_page_size: 50, countable: true

      validate {TenantContext, require_master: true}
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change MishkaCmsCore.Runtime.Resources.Changes.ReleaseBuilderHistory
      validate {TenantContext, require_master: false}
    end

    destroy :master_destroy do
      require_atomic? false
      multitenancy :bypass
      change MishkaCmsCore.Runtime.Resources.Changes.ReleaseBuilderHistory
      validate {TenantContext, require_master: true}
    end
  end

  policies do
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # WRITING A DRAFT IS WRITING ITS ERROR PAGE: the error page section or code, on the request's
    # surface; reading, above, is open to anyone under the surface.
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
    prefix "error_page_draft"

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
      description "Short human label that distinguishes one draft of an error page from another"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
      description "Human-readable draft name"
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL path pattern for the error pages this draft produces"
    end

    attribute :root_layout_template, :string do
      allow_nil? true
      public? true
      constraints trim?: true
      description "Root layout template wrapping all error pages"
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

    attribute :error_pages, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      status: [type: MishkaCmsCore.Runtime.ErrorStatus, allow_nil?: false],
                      template: [type: :string, allow_nil?: false],
                      layout: [type: :map, allow_nil?: true]
                    ]
                  ]

      description "Array of error page configurations with status codes, templates, and layouts"
    end

    attribute :helpers, {:array, MishkaCmsCore.Runtime.Resources.Embeddeds.Helper} do
      default []
      public? true
    end

    attribute :active, :boolean do
      default true
      public? true
      description "Whether the published error page should be active"
    end

    attribute :precompile, :boolean do
      default false
      public? true
    end

    attribute :extra, :map do
      default %{}
      public? true
    end

    attribute :preview_token, :string do
      allow_nil? false
      public? true
      description "Unguessable token for the shareable preview URL"
    end

    # THE DOCUMENT AS IT WAS WHEN THIS DRAFT WAS MADE, as `MishkaCmsCore.Runtime.PageBuilder.Drafts.hash/2`
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
      description "When the draft was published to its live error page"
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

    belongs_to :source_error_page, MishkaCmsCore.Runtime.ErrorPage do
      read_action :read_any
      allow_nil? true
      public? true

      description "The live error page this draft edits (nil for a brand-new draft-only error page)"
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
