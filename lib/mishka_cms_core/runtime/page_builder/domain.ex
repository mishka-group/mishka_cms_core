# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Domain do
  @moduledoc """
  The visual editor's Ash domain: the records only the editor writes and reads — its snippets, its
  change history and the snapshots that history restores from, its review notes — and the two
  resources with no data layer that back its Studio tables and its SEO form.

  None of them is part of the content a site serves, so they do not belong to
  `MishkaCmsCore.Runtime`, and a host that installs no editor lists no such domain: its
  `mix ash.codegen` then emits none of the editor's tables. A host with the editor lists this
  domain in its `:ash_domains` beside the core's.

  The tables keep their names (`builder_snippets`, `page_builder_events`, `page_builder_snapshots`,
  `page_comments`), so moving a resource here changes no database. The resources still write
  through the host's repo and broadcast on the host's endpoint, read from
  `config :mishka_cms_core, :repo` and `:endpoint` as every resource does.

  The MishkaGervaz defaults below are those of `MishkaCmsCore.Runtime` that the editor's tables and
  forms read, so they behave as they did in that domain: the PubSub server a live table subscribes
  on, the page sizes a reader may pick, the destroy action, and a form's actions and submit labels.
  Every table here names its own read, get and page size and none is archived, so the rest of that
  domain's defaults would change nothing.
  """
  use Ash.Domain,
    otp_app: :mishka_cms_core,
    validate_config_inclusion?: false,
    extensions: [MishkaGervaz.Domain]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  mishka_gervaz do
    table do
      pagination do
        page_size_options [20, 50, 100, 150]
      end

      realtime do
        pubsub MishkaCmsCore.PubSub
      end

      actions do
        destroy {:master_destroy, :destroy}
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
    resource MishkaCmsCore.Runtime.Snippet
    resource MishkaCmsCore.Runtime.PageBuilderEvent
    resource MishkaCmsCore.Runtime.PageBuilderSnapshot
    resource MishkaCmsCore.Runtime.PageComment

    # A resource with no data layer: the Studio's Design tokens tab, whose rows are parsed out of the
    # site's stylesheets and handed to `Ash.DataLayer.Simple` by the table's own `on_load` hook.
    resource MishkaCmsCore.Runtime.PageBuilder.DesignToken

    # Another: the SEO a page or a layout stores, as the builder's settings modal edits it — read
    # from the document and written back through the document's own action.
    resource MishkaCmsCore.Runtime.PageBuilder.SeoSettings
  end
end
