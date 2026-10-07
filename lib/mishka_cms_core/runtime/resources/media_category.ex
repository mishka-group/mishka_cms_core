defmodule MishkaCmsCore.Runtime.MediaCategory do
  @moduledoc """
  Manages media categories in the MishkaCMS runtime system with full versioning support.

  This resource represents categories for organizing media files. Each category belongs
  to a specific site and can have multiple media files associated with it. Categories
  help organize and filter media content within the CMS.

  A category is a folder, and a folder sits inside another one of its site through `parent_id`, or
  at the top level when it has none. Its name is unique among the folders beside it, not across the
  site. A folder never goes inside itself or one of its own subfolders, and is archived or deleted
  only once nothing is left in it — not a file and not a folder, archived ones included. Moving a
  folder moves everything under it: the folders below name it, not where it is. `trail/2` reads the
  folders above one, and `:path_label` names a folder by them.

  Media categories feature full version control through PaperTrail integration, tracking all changes
  with snapshot-based history and the ability to restore previous versions. The resource
  implements soft deletion via archival and provides comprehensive metadata management
  including name and description tracking.

  The resource implements soft deletion via archival and provides tenant-aware access
  control. Multi-tenant isolation ensures categories are properly segregated between sites.
  The resource provides extensive API actions for external integrations and maintains
  complete audit trails of all modifications including actor tracking and action recording.
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
  require Ash.Query

  @admin_fields [
    :name,
    :description,
    :parent_id,
    :site_id
  ]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for media category storage
  postgres do
    table "media_categories"
    repo @repo

    references do
      reference :site, on_delete: :delete
      reference :parent
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    # A folder's subfolders are read by their parent, a master's across every site.
    custom_indexes do
      index [:parent_id], all_tenants?: true
    end

    check_constraints do
      check_constraint :name, "name_length_check",
        check: "length(name) >= 2 AND length(name) <= 200",
        message: dgettext_noop("errors", "Name must be between 2 and 200 characters.")

      check_constraint :name, "no_empty_name",
        check: "name != ''",
        message: dgettext_noop("errors", "Name cannot be empty.")
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

  # Version control configuration for full media category history tracking
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
    mixin {MishkaCmsCore.Runtime.Resources.Mixins.MediaCategoryPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "media_category"
    includes [:media]
  end

  mishka_gervaz do
    form do
      identity do
        name :media_category_form
      end

      fields do
        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
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

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        # Left empty, the folder sits at the top level; changed on an edit, it moves the folder and
        # everything inside it.
        field :parent_id, :relation do
          resource MishkaCmsCore.Runtime.MediaCategory
          display_field &MishkaCmsCore.Runtime.MediaCategory.picker_label/1
          search_field :name
          mode :search
          min_chars 1
          page_size 15
          depends_on :site_id
          load &MishkaCmsCore.Runtime.MediaCategory.offer/2

          ui do
            label fn -> dgettext("mishka_gervaz", "Inside folder") end
            placeholder fn -> dgettext("mishka_gervaz", "Top level") end
          end
        end

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:name, :site_id, :parent_id, :description]

          ui do
            columns 1
          end
        end
      end

      presentation do
        features :all
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      derives:
        "sanitize(trim, squish, no_control) validate(string, not_empty, min_len=2, max_len=200)"

    field :description, :string,
      derives: "sanitize(trim, squish, no_zero_width) validate(optional=[string, max_len=1000])"
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
      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present([:name])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :parent_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "folder")}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change slugify(:name, into: :name)

      description "Creates media category for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present([:name, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :parent_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "folder")}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change slugify(:name, into: :name)

      description "Creates media category for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit an archived folder. Restore it first."
                )
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :parent_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "folder")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderParent, []}

      change slugify(:name, into: :name)

      description "Updates media category for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates media category for master users - requires nil tenant context, prevents site_id changes"
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit an archived folder. Restore it first."
                )
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :parent_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "folder")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderParent, []}

      change slugify(:name, into: :name)

      # Set tenant from record's site_id for version tracking
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end
    end

    read :archived do
      description "Lists archived media categories within current tenant context"
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived media categories system-wide, bypassing tenant filtering"
    end

    read :get_archived do
      description "Retrieves single archived media category for recovery or inspection (tenant users)"
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived media category for recovery or inspection (master users)"
    end

    read :master_read do
      description "Reads all media categories system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true

      description "Retrieves single media category by ID, bypassing tenant filtering (master users)"

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
      description "Reads media categories bypassing tenant filtering (internal use)"
      multitenancy :bypass

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :get_any do
      description "Retrieves single media category by ID, bypassing tenant filtering (internal use)"
      get? true
      multitenancy :bypass
    end

    destroy :destroy do
      description "Soft deletes media category by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "This folder is already archived.")}
        else
          :ok
        end
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderIsEmpty, []}
    end

    destroy :master_destroy do
      description "Soft deletes media category by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "This folder is already archived.")}
        else
          :ok
        end
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderIsEmpty, []}

      # Set tenant from record's site_id for version tracking
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      atomic_upgrade_with :archived

      description "Restores archived media category to active status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived media category to active status (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "This folder is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderIsEmpty, []}

      description "Permanently removes media category and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes media category and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderIsEmpty, []}
    end

    read :get_with_versions do
      get? true
      description "Gets a single media category with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.MediaCategory.Version
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
      description "Gets a single media category with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaCmsCore.Runtime.MediaCategory.Version
            |> Ash.Query.for_read(:read_any, %{}, actor: context.actor)
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a media category with pagination (tenant users)"

      argument :category_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        # WHOSE SITE THIS READ READS comes from the actor, not from the tenant alone. No site,
        # no versions.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.reading_site(context)

        category_id = Ash.Query.get_argument(query, :category_id)

        # First verify the category belongs to the tenant
        case Ash.get(MishkaCmsCore.Runtime.MediaCategory, category_id,
               tenant: acting_site,
               authorize?: false
             ) do
          {:ok, _category} ->
            query
            |> Ash.Query.filter(id == ^category_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaCmsCore.Runtime.MediaCategory.Version
                |> Ash.Query.for_read(:read_any)
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a media category with pagination (master users)"

      argument :category_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        category_id = Ash.Query.get_argument(query, :category_id)

        query
        |> Ash.Query.filter(id == ^category_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaCmsCore.Runtime.MediaCategory.Version
            |> Ash.Query.for_read(:read_any)
        )
      end
    end

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the media category to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore a version of an archived folder. Restore the folder first."
                )
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.MediaCategory.Version}

      # A version can put the folder back inside one that has since been archived, or moved under
      # it.
      validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
                field: :parent_id,
                resource: MishkaCmsCore.Runtime.MediaCategory,
                label: dgettext_noop("errors", "folder")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.FolderParent, []}
    end

    action :restore_version_api, :struct do
      description "Restores media category content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaCmsCore.Runtime.MediaCategory

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        category_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaCmsCore.Runtime.MediaCategory, category_id,
          action: :read,
          tenant: acting_site,
          authorize?: false
        )
        |> case do
          {:ok, category} when not is_nil(category) ->
            if !is_nil(category.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore a version of an archived folder. Restore the folder first."
                       )
                   )
                 ]
               )}
            else
              tenant = category.site_id

              Ash.get(MishkaCmsCore.Runtime.MediaCategory.Version, version_id,
                action: :get_any,
                authorize?: false
              )
              |> case do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != category_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop(
                               "errors",
                               "That version is not one of this folder's."
                             )
                         )
                       ]
                     )}
                  else
                    category
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.MediaCategory.Version
                   )}
              end
            end

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)}
        end
      end
    end

    action :master_restore_version, :struct do
      description "Restores media category content from a specific version in history (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.MediaCategory

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        category_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaCmsCore.Runtime.MediaCategory, category_id,
          action: :master_get,
          authorize?: false
        )
        |> case do
          {:ok, category} when not is_nil(category) ->
            if !is_nil(category.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore a version of an archived folder. Restore the folder first."
                       )
                   )
                 ]
               )}
            else
              tenant = category.site_id

              Ash.get(MishkaCmsCore.Runtime.MediaCategory.Version, version_id,
                action: :get_any,
                authorize?: false
              )
              |> case do
                {:ok, version} when not is_nil(version) ->
                  if version.version_source_id != category_id do
                    {:error,
                     Ash.Error.Invalid.exception(
                       errors: [
                         Ash.Error.Changes.InvalidAttribute.exception(
                           field: :version_id,
                           message:
                             dgettext_noop(
                               "errors",
                               "That version is not one of this folder's."
                             )
                         )
                       ]
                     )}
                  else
                    category
                    |> Ash.Changeset.for_update(:restore_version, %{version_id: version_id},
                      tenant: tenant,
                      authorize?: false
                    )
                    |> Ash.update()
                  end

                _ ->
                  {:error,
                   Ash.Error.Query.NotFound.exception(
                     resource: MishkaCmsCore.Runtime.MediaCategory.Version
                   )}
              end
            end

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)}
        end
      end
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaCmsCore.Runtime.MediaCategory

      argument :category_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        # WHOSE SITE THIS CALL ACTS ON comes from the actor, not from the tenant alone: the reads
        # and the restore below run as the system.
        acting_site =
          MishkaCmsCore.Runtime.Resources.Preparations.SiteWithGlobals.acting_site(context)

        category_id = input.arguments.category_id
        version_id = input.arguments.version_id

        with {:ok, category} when not is_nil(category) <-
               Ash.get(MishkaCmsCore.Runtime.MediaCategory, category_id,
                 tenant: acting_site,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.MediaCategory.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == category_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.MediaCategory
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_category =
            Enum.reduce(restored_attrs, category, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)
                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_category}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "That version is not one of this folder's.")
                 )
               ]
             )}

          {:error, _} ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)}

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)}
        end
      end
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaCmsCore.Runtime.MediaCategory

      argument :category_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, _context ->
        category_id = input.arguments.category_id
        version_id = input.arguments.version_id

        with {:ok, category} when not is_nil(category) <-
               Ash.get(MishkaCmsCore.Runtime.MediaCategory, category_id,
                 action: :master_get,
                 authorize?: false
               ),
             {:ok, version} when not is_nil(version) <-
               Ash.get(MishkaCmsCore.Runtime.MediaCategory.Version, version_id,
                 action: :get_any,
                 authorize?: false
               ),
             :valid <- if(version.version_source_id == category_id, do: :valid, else: :invalid) do
          restored_attrs =
            case version.changes do
              nil -> %{}
              changes when is_map(changes) -> changes
              changes when is_binary(changes) -> Jason.decode!(changes)
            end

          accepted_fields =
            MishkaCmsCore.Runtime.MediaCategory
            |> Ash.Resource.Info.actions()
            |> Enum.find(fn action -> action.name == :update and action.primary? end)
            |> Map.get(:accept)
            |> Enum.map(&to_string/1)

          preview_category =
            Enum.reduce(restored_attrs, category, fn {key, value}, acc ->
              if key in accepted_fields do
                key_atom = String.to_atom(key)
                Map.put(acc, key_atom, value)
              else
                acc
              end
            end)

          {:ok, preview_category}
        else
          :invalid ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidAttribute.exception(
                   field: :version_id,
                   message: dgettext_noop("errors", "That version is not one of this folder's.")
                 )
               ]
             )}

          {:error, _} ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)}

          _ ->
            {:error,
             Ash.Error.Query.NotFound.exception(resource: MishkaCmsCore.Runtime.MediaCategory)}
        end
      end
    end
  end

  # Authorization policies for media category access
  policies do
    # PREVIEWING A VERSION IS READING IT, though it is a generic action.
    bypass action([:preview_version, :master_preview_version]) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end

    # MEDIA CATEGORIES ARE CONTENT: anyone under the request's surface reads them, and writing them
    # takes the media section, `admin:<surface>:runtime:media`.
    policy always() do
      access_type :strict
      authorize_if accessing_from(MishkaCmsCore.Accounts.User, :site)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:runtime:media", "admin:api:runtime:media"]}

      forbid_unless action_type(:read)
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
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
    prefix "media_category"

    # Tenant actions
    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Multi-tenancy configuration - categories are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Categories are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 200, trim?: true
      description "Name of the media category"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000, trim?: true
      description "Optional description of the media category"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this media category belongs to"
    end

    belongs_to :parent, MishkaCmsCore.Runtime.MediaCategory do
      read_action :read_any
      allow_nil? true
      public? true
      description "The folder this one sits inside, or none for a folder at the top level"
    end

    has_many :media, MishkaCmsCore.Runtime.Media do
      public? true
      description "Media files in this category"
    end

    has_many :sorted_versions, MishkaCmsCore.Runtime.MediaCategory.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      sort version_inserted_at: :desc
    end
  end

  calculations do
    calculate :version_preview,
              :map,
              {MishkaCmsCore.Runtime.Resources.Calculations.VersionPreview,
               version: MishkaCmsCore.Runtime.MediaCategory.Version} do
      public? true
      argument :version_id, :uuid, allow_nil?: false

      description "Retrieves content from one of this record's own versions for preview before restoration"
    end

    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in media category history"

      calculation fn records, _context ->
        Enum.map(records, fn category ->
          case MishkaCmsCore.Runtime.MediaCategory.Version
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(version_source_id == ^category.id)
               |> Ash.count(authorize?: false) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaCmsCore.Runtime.MediaCategory.Version
      description "Returns the most recent version for the media category"

      calculation fn records, _context ->
        category_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.MediaCategory.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^category_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn category ->
          Map.get(versions_map, category.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaCmsCore.Runtime.MediaCategory.Version]

      description "Returns the 10 most recent versions for the media category in descending order by insertion date"

      calculation fn records, _context ->
        category_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaCmsCore.Runtime.MediaCategory.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^category_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(authorize?: false)
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn category ->
          Map.get(versions_map, category.id, [])
        end)
      end
    end

    calculate :media_count, :integer do
      public? true

      calculation fn records, _context ->
        MishkaCmsCore.Runtime.MediaCategory.media_counts(records)
      end

      description "Returns how many live media files are directly in this category"
    end

    calculate :path_label, :string do
      public? true

      calculation fn records, context ->
        MishkaCmsCore.Runtime.MediaCategory.path_labels(records,
          actor: context.actor,
          authorize?: context.authorize?
        )
      end

      description "Returns the category's name after the names of the folders above it, outermost first"
    end
  end

  identities do
    # Two folders at the top level of a site have no parent between them, and still clash.
    identity :unique_name_per_parent, [:name, :site_id, :parent_id] do
      description "Ensures category names are unique among the folders beside each other"
      message dgettext_noop("errors", "Another folder in the same place already has this name.")
      all_tenants? true
      nils_distinct? false
    end
  end

  @doc """
  What a folder picker shows for `folder`: its `:path_label` when that was loaded, its name when not.
  """
  @spec picker_label(map()) :: String.t()
  def picker_label(%{path_label: label}) when is_binary(label), do: label
  def picker_label(%{name: name}), do: name

  @doc """
  The folders a form's folder picker offers, as its `load`: those of the site the form is for, each
  with its `:path_label`. The site is the one picked on the form, else the edited record's, else the
  user's own; a form with no site yet is offered no folder.
  """
  @spec offer(Ash.Query.t(), map()) :: Ash.Query.t()
  def offer(query, state) do
    case form_site(state) do
      nil -> Ash.Query.filter(query, false)
      site_id -> query |> Ash.Query.filter(site_id == ^site_id) |> Ash.Query.load(:path_label)
    end
  end

  defp form_site(%{field_values: %{site_id: site_id}}) when is_binary(site_id) and site_id != "",
    do: site_id

  defp form_site(%{form: %{source: %{source: %{data: %{site_id: site_id}}}}})
       when is_binary(site_id),
       do: site_id

  defp form_site(%{current_user: %{site_id: site_id}}) when is_binary(site_id), do: site_id
  defp form_site(_state), do: nil

  @doc """
  The folder `id` and every folder above it, outermost first, each with its `:id`, `:name`,
  `:parent_id` and `:site_id` — what a breadcrumb draws.

  Read through `:read_any` as `opts[:actor]`, with `opts[:authorize?]`, one level at a time: one
  small read per folder up the chain. `{:ok, []}` when the folder is archived, gone, or not one the
  actor reads.
  """
  @spec trail(Ecto.UUID.t(), keyword()) :: {:ok, [%__MODULE__{}]} | {:error, term()}
  def trail(id, opts) do
    with {:ok, known} <- climb([id], %{}, opts), do: {:ok, chain(known, id)}
  end

  @doc """
  Each of `folders` named after the folders above it, outermost first: `photos / 2024 / covers`.

  The folders above are read as `trail/2` reads them, one level at a time for all of `folders`
  together. When they cannot be read, each folder is named by its own name.
  """
  @spec path_labels([%__MODULE__{}], keyword()) :: [String.t()]
  def path_labels(folders, opts) do
    known = Map.new(folders, &{&1.id, &1})

    case climb(above(folders, known), known, opts) do
      {:ok, known} ->
        Enum.map(folders, &path(known, &1.id))

      {:error, _unread} ->
        Enum.map(folders, & &1.name)
    end
  end

  @doc """
  The whole path of each folder `ids` names, outermost first, keyed by id: `photos / 2024`. Read as
  `trail/2` reads, one level at a time for all of them together. A `nil`, a folder the actor cannot
  read, and every one when the folders cannot be read, are left out.
  """
  @spec paths([Ecto.UUID.t() | nil], keyword()) :: %{Ecto.UUID.t() => String.t()}
  def paths(ids, opts) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case climb(ids, %{}, opts) do
      {:ok, known} ->
        for id <- ids, Map.has_key?(known, id), into: %{}, do: {id, path(known, id)}

      {:error, _unread} ->
        %{}
    end
  end

  defp path(known, id), do: known |> chain(id) |> Enum.map_join(" / ", & &1.name)

  defp climb([], known, _opts), do: {:ok, known}

  defp climb(ids, known, opts) do
    read_opts = read_opts(opts)

    __MODULE__
    |> Ash.Query.for_read(:read_any, %{}, read_opts)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :name, :parent_id, :site_id])
    |> Ash.read([page: false] ++ read_opts)
    |> case do
      {:ok, folders} ->
        known = Enum.reduce(folders, known, &Map.put(&2, &1.id, &1))
        climb(above(folders, known), known, opts)

      {:error, error} ->
        {:error, error}
    end
  end

  # An `authorize?: nil` handed on would read unauthorized; left out, the actor is authorized as on
  # any read.
  defp read_opts(opts) do
    case Keyword.get(opts, :authorize?) do
      authorize? when is_boolean(authorize?) -> [actor: opts[:actor], authorize?: authorize?]
      nil -> [actor: opts[:actor]]
    end
  end

  defp above(folders, known) do
    folders
    |> Enum.map(& &1.parent_id)
    |> Enum.reject(&(is_nil(&1) or Map.has_key?(known, &1)))
    |> Enum.uniq()
  end

  # Up from `id` through the folders read, stopping at the top, at one that was not read, or at one
  # already on the way.
  defp chain(known, id, below \\ []) do
    case Map.fetch(known, id) do
      {:ok, folder} ->
        if Enum.any?(below, &(&1.id == id)),
          do: below,
          else: chain(known, folder.parent_id, [folder | below])

      :error ->
        below
    end
  end

  @doc """
  How many live files sit directly in each of `folders`, in their order — one query for all of them.
  """
  @spec media_counts([%__MODULE__{}]) :: [non_neg_integer()]
  def media_counts(folders) do
    sql = """
    SELECT media_category_id, COUNT(*)
    FROM media
    WHERE media_category_id = ANY($1)
    AND archived_at IS NULL
    GROUP BY media_category_id
    """

    ids = Enum.map(folders, &Ecto.UUID.dump!(&1.id))

    counts =
      case Ecto.Adapters.SQL.query(@repo, sql, [ids]) do
        {:ok, %{rows: rows}} -> Map.new(rows, fn [id, count] -> {Ecto.UUID.cast!(id), count} end)
        _unread -> %{}
      end

    Enum.map(folders, &Map.get(counts, &1.id, 0))
  end
end
