defmodule MishkaCmsCore.Runtime.MediaCategory do
  @moduledoc """
  Manages media categories in the MishkaCMS runtime system with full versioning support.

  This resource represents categories for organizing media files. Each category belongs
  to a specific site and can have multiple media files associated with it. Categories
  help organize and filter media content within the CMS.

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
    :site_id
  ]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for media category storage
  postgres do
    table "media_categories"
    repo @repo

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

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

        field :description do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:name, :site_id, :description]

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

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change slugify(:name, into: :name)

      description "Creates media category for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present([:name, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

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
                  "Cannot edit archived media category. Please unarchive it first."
                )
      end

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
                  "Cannot edit archived media category. Please unarchive it first."
                )
      end

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
           message: dgettext_noop("errors", "Media category is already archived.")}
        else
          :ok
        end
      end
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
           message: dgettext_noop("errors", "Media category is already archived.")}
        else
          :ok
        end
      end

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
           field: :archived_at,
           message: dgettext_noop("errors", "Media category is not archived.")}
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

      description "Permanently removes media category and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes media category and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
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
                  "Cannot restore version of archived media category. Please unarchive it first."
                )
      end

      change {MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion,
              version: MishkaCmsCore.Runtime.MediaCategory.Version}
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
                         "Cannot restore version of archived media category. Please unarchive it first."
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
                               "Version does not belong to this media category."
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
                         "Cannot restore version of archived media category. Please unarchive it first."
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
                               "Version does not belong to this media category."
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
                   message:
                     dgettext_noop("errors", "Version does not belong to this media category.")
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
                   message:
                     dgettext_noop("errors", "Version does not belong to this media category.")
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
        Enum.map(records, fn record ->
          sql = """
          SELECT COUNT(*)
          FROM media
          WHERE media_category_id = $1
          AND archived_at IS NULL
          """

          case Ecto.Adapters.SQL.query(@repo, sql, [Ecto.UUID.dump!(record.id)]) do
            {:ok, %{rows: [[count]]}} -> count
            _ -> 0
          end
        end)
      end

      description "Returns total number of media files in this category using raw SQL"
    end
  end

  identities do
    identity :unique_name_per_site, [:name, :site_id] do
      description "Ensures category names are unique within each site"
      message dgettext_noop("errors", "Media category name must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end
end
