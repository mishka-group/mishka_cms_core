# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Layout.Index do
  @moduledoc """
  The admin's layout list. Creating, viewing and editing all happen in the one inspector modal
  (`MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers`) — the eye opens it on Overview,
  the pencil on its Configuration tab, and "+ Add" on an empty form. There is no separate
  `layout-form-modal`: two mounts of one form component on a page collide on their DOM id.
  """
  use MishkaCmsCore.ExtensionLiveView
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.RuntimeStatusLive
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)
    socket = PreviewHelpers.assign_access(socket, MishkaCmsCore.Runtime.Layout)

    if connected?(socket),
      do:
        PreviewHelpers.subscribe_drafts(socket.assigns.current_user, MishkaCmsCore.Runtime.Layout)

    socket =
      RuntimeStatusLive.setup(socket,
        resource: MishkaCmsCore.Runtime.Layout,
        table_id: "layouts-table",
        tenant_action: :get_for_tenant_with_globals
      )

    socket = PreviewHelpers.setup(socket)

    socket =
      MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed.setup(socket,
        resources: [MishkaCmsCore.Runtime.Layout],
        feed_id: "layouts-activity"
      )

    new_socket =
      socket
      |> assign(:page_title, gettext("Listing Layouts"))
      |> assign(:url_state, nil)

    {:ok, assign(new_socket, :open_builder?, false)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaCmsCore.Runtime.Layout)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_info({:form_saved, :create, result}, %{assigns: %{open_builder?: true}} = socket) do
    {:noreply,
     socket
     |> assign(:open_builder?, false)
     |> push_navigate(to: Section.builder_path("layout", result.id))}
  end

  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> PreviewHelpers.dismiss()
     |> put_flash(:info, gettext("Layout created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> PreviewHelpers.dismiss()
     |> put_flash(:info, gettext("Layout updated successfully"))}
  end

  @impl true
  # AND FORGOTTEN IF THE FORM IS ABANDONED, or the next ordinary Create would carry someone else's
  # answer into the editor.
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, socket |> assign(:open_builder?, false) |> PreviewHelpers.dismiss()}
  end

  @impl true
  def handle_info({:row_action, "show_preview_modal", %{"id" => id}}, socket),
    do: {:noreply, PreviewHelpers.open(socket, id)}

  @impl true
  def handle_info({:row_action, "edit_preview_modal", %{"id" => id}}, socket),
    do: {:noreply, PreviewHelpers.open_configuration(socket, id)}

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  # Must precede the broad `topic: "layout" <> _` clause below — "layout_draft:…" also starts with
  # "layout", and a draft notification belongs to the modal picker, not the layouts table.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "layout_draft" <> _,
          payload: %Ash.Notifier.Notification{data: data}
        },
        socket
      ),
      do: {:noreply, PreviewHelpers.sync_draft(socket, data, socket.assigns.current_user)}

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "layout" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "layouts-table",
      pubsub_notification: notification
    )

    {:noreply, RuntimeStatusLive.refresh_if_match(socket, notification)}
  end

  @impl true
  def handle_info({:expand_row, id}, socket) do
    {:noreply, RuntimeStatusLive.expand(socket, id)}
  end

  @impl true
  def handle_async({:runtime_status_load, _id}, result, socket) do
    {:noreply, RuntimeStatusLive.loaded(socket, result)}
  end

  def handle_async(name, result, socket)
      when name in [:load_preview, :preview_versions, :preview_compile],
      do: {:noreply, PreviewHelpers.async_result(socket, name, result)}

  @impl true
  # THE INTENT IS RECORDED BEFORE THE FORM IS FILLED, because that is where the reader chooses it:
  # the caret beside "+ Add" asks how they want to make one, and this remembers the answer until the
  # save arrives. It used to ride the form as a hidden param on a second submit button, which put the
  # question at the bottom of a modal the reader had already committed to.
  def handle_event("create_and_open", _params, socket) do
    {:noreply, socket |> assign(:open_builder?, true) |> PreviewHelpers.open_new()}
  end

  @impl true
  def handle_event("preview_add", _params, socket),
    do: {:noreply, socket |> assign(:open_builder?, false) |> PreviewHelpers.open_new()}

  @impl true
  def handle_event("preview_force_compile", _params, socket),
    do: {:noreply, PreviewHelpers.force_compile(socket)}

  def handle_event("preview_set_tab", %{"tab" => tab}, socket),
    do: {:noreply, PreviewHelpers.set_tab(socket, tab)}

  @impl true
  def handle_event("preview_set_device", %{"device" => device}, socket),
    do: {:noreply, PreviewHelpers.set_device(socket, device)}

  @impl true
  def handle_event("preview_set_source", %{"source" => source}, socket),
    do: {:noreply, PreviewHelpers.set_preview_source(socket, source)}

  @impl true
  def handle_event("preview_edit_code", _params, socket),
    do: {:noreply, PreviewHelpers.edit_code(socket)}

  @impl true
  def handle_event("preview_cancel_edit", _params, socket),
    do: {:noreply, PreviewHelpers.cancel_edit(socket)}

  @impl true
  def handle_event("preview_code_change", %{"source" => source} = params, socket),
    do: {:noreply, PreviewHelpers.type_code(socket, source, params["label"])}

  @impl true
  def handle_event("preview_code_submit", %{"op" => "save", "source" => source} = params, socket),
    do: {:noreply, PreviewHelpers.save_draft(socket, source, Map.get(params, "label"))}

  @impl true
  def handle_event("preview_code_submit", %{"source" => source}, socket),
    do: {:noreply, PreviewHelpers.rerender(socket, source)}

  @impl true
  def handle_event("preview_select_draft", %{"id" => id}, socket),
    do: {:noreply, PreviewHelpers.select_draft(socket, id)}

  @impl true
  def handle_event("preview_new_draft", _params, socket),
    do: {:noreply, PreviewHelpers.new_draft(socket)}

  @impl true
  def handle_event("preview_drafts_page", %{"page" => page}, socket),
    do: {:noreply, PreviewHelpers.drafts_paginate(socket, page)}

  @impl true
  def handle_event("preview_publish_draft", _params, socket),
    do: {:noreply, PreviewHelpers.publish_draft(socket)}

  @impl true
  def handle_event("preview_discard_draft", params, socket),
    do: {:noreply, PreviewHelpers.discard_draft(socket, params["id"])}

  @impl true
  def handle_event("close_preview_modal", _params, socket),
    do: {:noreply, PreviewHelpers.close(socket)}

  @impl true
  def handle_event("preview_versions_page", %{"page" => page}, socket),
    do: {:noreply, PreviewHelpers.versions_paginate(socket, page)}

  @impl true
  def handle_event("preview_version_toggle", %{"id" => id}, socket),
    do: {:noreply, PreviewHelpers.toggle_version(socket, id)}

  @impl true
  def handle_event("preview_version_restore", %{"id" => id}, socket),
    do: {:noreply, PreviewHelpers.restore_version(socket, id)}
end
