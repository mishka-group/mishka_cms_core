defmodule MishkaCmsCore.Runtime do
  @moduledoc """
  MishkaCms Runtime Domain - Core domain for CMS runtime resources and operations.

  This domain serves as the central orchestrator for all runtime CMS operations,
  providing a clean API interface for managing sites, pages, components, layouts,
  error pages, and JavaScript hooks with built-in auditing and JSON API capabilities.
  """
  use Ash.Domain,
    otp_app: :mishka_cms_core,
    validate_config_inclusion?: false,
    extensions: [
      AshPaperTrail.Domain,
      AshJsonApi.Domain,
      MishkaGervaz.Domain
    ]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  paper_trail do
    include_versions? true
  end

  json_api do
    routes do
      base_route "/v1/master/admin/runtime/site", MishkaCmsCore.Runtime.Site do
        index :master_read
        get :master_get
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update, read_action: :master_get
        patch :activate, route: "/:id/activate", read_action: :master_get
        patch :deactivate, route: "/:id/deactivate", read_action: :master_get
        patch :set_as_master, route: "/:id/set-master", read_action: :master_get
        patch :unset_as_master, route: "/:id/unset-master", read_action: :master_get
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive", read_action: :master_get
        delete :permanent_destroy, route: "/:id/permanent", read_action: :get_any
      end

      base_route "/v1/tenant/admin/runtime/site", MishkaCmsCore.Runtime.Site do
        index :tenant_read
        get :tenant_get
      end

      base_route "/v1/tenant/admin/runtime/component", MishkaCmsCore.Runtime.Component do
        post :create
        patch :update
        delete :destroy, route: "/:id/archive"
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived

        delete :permanent_destroy, route: "/:id/permanent"

        index :for_tenant_with_globals
        get :get_for_tenant_with_globals
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:component_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:component_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/component", MishkaCmsCore.Runtime.Component do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, route: "/:id", read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get

        get :master_get_with_versions, route: "/:id/with-versions"
        index :master_list_versions, route: "/:component_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:component_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/runtime/layout", MishkaCmsCore.Runtime.Layout do
        index :for_tenant_with_globals
        get :get_for_tenant_with_globals
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:layout_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:layout_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/layout", MishkaCmsCore.Runtime.Layout do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, route: "/:id", read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get

        get :master_get_with_versions, route: "/:id/with-versions"
        index :master_list_versions, route: "/:layout_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:layout_id/version/:version_id/preview"
      end
    end
  end

  mishka_gervaz do
    table do
      actor_key :current_user

      pagination do
        type :load_more
        page_size 20
        page_size_options [20, 50, 100, 150]
      end

      realtime do
        pubsub MishkaCmsCore.PubSub
      end

      actions do
        read {:master_read, :read}
        get {:master_get, :read}
        destroy {:master_destroy, :destroy}
      end

      archive do
        read_action {:master_archived, :archived}
        get_action {:master_get_archived, :get_archived}
        restore_action {:master_unarchive, :unarchive}
        destroy_action {:master_permanent_destroy, :permanent_destroy}
      end
    end

    form do
      actions do
        create {:master_create, :create}
        update {:master_update, :update}
        read {:master_get, :read}
      end

      submit do
        create label: fn -> dgettext("mishka_gervaz", "Create") end
        update label: fn -> dgettext("mishka_gervaz", "Save Changes") end
        cancel label: fn -> dgettext("mishka_gervaz", "Cancel") end
        position :bottom
      end
    end
  end

  resources do
    resource MishkaCmsCore.Runtime.Setting

    resource MishkaCmsCore.Runtime.Site

    resource MishkaCmsCore.Runtime.Component do
      define :get_component, action: :read, get_by: :id

      define :get_component_by_name,
        action: :by_name,
        args: [:name],
        get?: true,
        not_found_error?: false
    end

    resource MishkaCmsCore.Runtime.Layout do
      define :get_layout, action: :read, get_by: :id

      define :get_layout_by_path,
        action: :by_path,
        args: [:path],
        get?: true,
        not_found_error?: false

      define :get_layout_by_token,
        action: :by_token,
        args: [:preview_token],
        get?: true,
        not_found_error?: false
    end
  end
end
