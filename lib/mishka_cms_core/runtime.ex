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

      base_route "/v1/tenant/admin/runtime/error-page",
                 MishkaCmsCore.Runtime.ErrorPage do
        index :read
        get :read, route: "/:id"
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:error_page_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:error_page_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/error-page",
                 MishkaCmsCore.Runtime.ErrorPage do
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
        index :master_list_versions, route: "/:error_page_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:error_page_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/runtime/js-hook", MishkaCmsCore.Runtime.JsHook do
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
        index :list_versions, route: "/:js_hook_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:js_hook_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/js-hook", MishkaCmsCore.Runtime.JsHook do
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
        index :master_list_versions, route: "/:js_hook_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:js_hook_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/runtime/stylesheet", MishkaCmsCore.Runtime.Stylesheet do
        index :for_tenant_with_globals
        get :get_for_tenant_with_globals
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/runtime/stylesheet", MishkaCmsCore.Runtime.Stylesheet do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, route: "/:id", read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
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

      base_route "/v1/tenant/admin/runtime/page", MishkaCmsCore.Runtime.Page do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:page_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:page_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/page", MishkaCmsCore.Runtime.Page do
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
        index :master_list_versions, route: "/:page_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:page_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/runtime/media", MishkaCmsCore.Runtime.Media do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:media_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:media_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/media", MishkaCmsCore.Runtime.Media do
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
        index :master_list_versions, route: "/:media_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:media_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/runtime/media-category",
                 MishkaCmsCore.Runtime.MediaCategory do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:category_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:category_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/runtime/media-category",
                 MishkaCmsCore.Runtime.MediaCategory do
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
        index :master_list_versions, route: "/:category_id/versions"

        patch :master_restore_version,
          route: "/:id/version/:version_id/restore",
          read_action: :master_get

        get :master_preview_version, route: "/:category_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/runtime/redirect", MishkaCmsCore.Runtime.Redirect do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/runtime/redirect", MishkaCmsCore.Runtime.Redirect do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, route: "/:id", read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
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
    resource MishkaCmsCore.Runtime.Translation

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

    resource MishkaCmsCore.Runtime.JsHook do
    end

    resource MishkaCmsCore.Runtime.Stylesheet do
    end

    resource MishkaCmsCore.Runtime.ErrorPage do
      define :get_error, action: :read, get_by: :id

      define :get_error_by_path,
        action: :by_path,
        args: [:path],
        get?: true,
        not_found_error?: false

      define :get_error_page_by_token,
        action: :by_token,
        args: [:preview_token],
        get?: true,
        not_found_error?: false
    end

    resource MishkaCmsCore.Runtime.Page do
      define :get_page, action: :read, get_by: :id

      define :get_page_by_token,
        action: :by_token,
        args: [:preview_token],
        get?: true,
        not_found_error?: false

      define :get_page_by_path,
        action: :by_path,
        args: [:path],
        get?: true,
        not_found_error?: false
    end

    resource MishkaCmsCore.Runtime.PageDraft do
      define :get_page_draft, action: :master_get, get_by: :id

      define :get_page_draft_by_token,
        action: :by_token,
        args: [:preview_token],
        get?: true,
        not_found_error?: false
    end

    resource MishkaCmsCore.Runtime.LayoutDraft do
      define :get_layout_draft, action: :master_get, get_by: :id

      define :get_layout_draft_by_token,
        action: :by_token,
        args: [:preview_token],
        get?: true,
        not_found_error?: false
    end

    resource MishkaCmsCore.Runtime.ErrorPageDraft do
      define :get_error_page_draft, action: :master_get, get_by: :id

      define :get_error_page_draft_by_token,
        action: :by_token,
        args: [:preview_token],
        get?: true,
        not_found_error?: false
    end

    resource MishkaCmsCore.Runtime.Media do
    end

    resource MishkaCmsCore.Runtime.MediaCategory do
    end

    resource MishkaCmsCore.Runtime.Redirect do
    end

    resource MishkaCmsCore.Runtime.Snippet do
    end

    resource MishkaCmsCore.Runtime.PageBuilderEvent do
    end

    resource MishkaCmsCore.Runtime.PageBuilderSnapshot do
    end

    resource MishkaCmsCore.Runtime.PageComment do
    end

    # A resource with no data layer: the Studio's Design tokens tab, whose rows are parsed out of the
    # site's stylesheets and handed to `Ash.DataLayer.Simple` by the table's own `on_load` hook.
    resource MishkaCmsCore.Runtime.PageBuilder.DesignToken do
    end

    # Another: the SEO a page or a layout stores, as the builder's settings modal edits it — read
    # from the document and written back through the document's own action.
    resource MishkaCmsCore.Runtime.PageBuilder.SeoSettings do
    end
  end
end
