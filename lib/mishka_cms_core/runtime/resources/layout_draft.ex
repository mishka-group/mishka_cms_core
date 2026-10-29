# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.LayoutDraft do
  @moduledoc """
  An unpublished working copy of a runtime `MishkaCmsCore.Runtime.Layout` — the Layout analogue of
  `MishkaCmsCore.Runtime.PageDraft`.

  A draft holds the same editable fields as a Layout plus:

    * `source_layout_id` — the live Layout it edits, or `nil` for a brand-new draft-only layout.
    * `preview_token` — an unguessable token for the shareable `/_preview/layout/:token` URL.
    * `status` (`:draft` / `:published`) and `applied_at` — set when the draft is published.

  Publishing is explicit (`:publish` / `:master_publish`): it writes the draft's fields to the live
  Layout (creating it when `source_layout_id` is `nil`, otherwise updating all but its `helpers`),
  then marks the draft published. See `MishkaCmsCore.Runtime.Resources.Changes.PublishLayoutDraft`.

  Layouts can be **global** (`site_id` nil, master-managed), so — unlike `PageDraft` — this resource
  is `global? true` and its `site_id` is nullable; a draft inherits the source layout's site (nil for
  a global layout). The preview-modal UI only exposes drafts/editing to users who may edit the
  layout (master, or a tenant on its own non-global layout).
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
    :example,
    :source_layout_id
  ]

  @admin_fields @editable_fields ++ [:site_id]

  @doc "Generate an unguessable URL-safe preview token."
  def generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  postgres do
    table "layout_drafts"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :source_layout, on_delete: :delete
    end

    custom_indexes do
      index [:site_id]
      index [:source_layout_id]
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
        name :layout_drafts
        route "/admin/dashboard/runtime/layouts"
        stream_name :layout_drafts
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
          query, %{path_params: %{source_layout_id: id}} when not is_nil(id) ->
            {:cont, Ash.Query.filter(query, is_nil(applied_at) and source_layout_id == ^id)}

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
    # layout's own form, so a draft cannot be given what the layout itself would refuse.
    form do
      identity do
        name :layout_draft_form
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

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            span 2
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
      validate present([:template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      change slugify(:name, into: :name)

      description "Creates a layout draft for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      multitenancy :bypass

      validate present([:name])
      validate present([:path])
      validate present([:template])

      validate {MishkaCmsCore.Runtime.Resources.Validations.PathFormat, []}

      validate {TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

      change fn changeset, _context ->
        Ash.Changeset.change_new_attribute(changeset, :preview_token, generate_token())
      end

      change slugify(:name, into: :name)

      description "Creates a layout draft for master users - bypasses multi-tenancy; site_id may be nil (global layout)"
    end

    update :update do
      validate {MishkaCmsCore.Runtime.Resources.Validations.CodeChange, []}

      primary? true
      require_atomic? false
      accept @editable_fields

      validate {TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :source_layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

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
                field: :source_layout_id,
                resource: MishkaCmsCore.Runtime.Layout,
                label: dgettext_noop("errors", "layout"),
                shared?: true}

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

      change Changes.PublishLayoutDraft

      description "Publishes a draft to its live layout (tenant users)."
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

      change Changes.PublishLayoutDraft

      description "Publishes a draft to its live layout (master users)."
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

    read :by_source_layout do
      multitenancy :bypass
      argument :source_layout_id, :uuid, allow_nil?: false
      filter expr(source_layout_id == ^arg(:source_layout_id))
      prepare build(sort: [inserted_at: :desc])
    end

    # Paginated list of a layout's PENDING (unpublished) drafts, newest first — backs the
    # multi-draft picker in the preview modal. Tenant-scoped variant + master bypass variant.
    read :drafts_for_layout do
      argument :source_layout_id, :uuid, allow_nil?: false
      filter expr(source_layout_id == ^arg(:source_layout_id) and is_nil(applied_at))
      prepare build(sort: [inserted_at: :desc])
      pagination offset?: true, default_limit: 5, max_page_size: 50, countable: true
    end

    read :master_drafts_for_layout do
      multitenancy :bypass
      argument :source_layout_id, :uuid, allow_nil?: false
      filter expr(source_layout_id == ^arg(:source_layout_id) and is_nil(applied_at))
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

    # WRITING A DRAFT IS WRITING ITS LAYOUT: the layout section or code, on the request's surface;
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
    prefix "layout_draft"

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
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string do
      allow_nil? true
      public? true
      constraints max_length: 120, trim?: true
      description "Short human label that distinguishes one draft of a layout from another"
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
      description "URL path pattern for the layout this draft produces"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
    end

    attribute :template, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, trim?: true
      description "Layout template content (wraps a page via @inner_content)"
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

    attribute :resource_links, {:array, :map} do
      default []
      public? true
    end

    attribute :seo_tags, {:array, :map} do
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
      description "Whether the published layout should be active"
    end

    attribute :precompile, :boolean do
      default false
      public? true
    end

    attribute :permissions, {:array, :string} do
      default []
      public? true
    end

    attribute :example, :string do
      allow_nil? true
      public? true
      constraints min_length: 3, trim?: true
      description "HTML example page content shown inside the layout when previewing"
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
      description "When the draft was published to its live layout"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? true
      public? true
      description "The site this draft belongs to (nil for a global layout draft)"
    end

    belongs_to :source_layout, MishkaCmsCore.Runtime.Layout do
      read_action :read_any
      allow_nil? true
      public? true
      description "The live layout this draft edits (nil for a brand-new draft-only layout)"
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
