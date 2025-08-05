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
  end
end
