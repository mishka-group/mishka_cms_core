defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Stylesheet.Index do
  @moduledoc """
  Admin dashboard LiveView for runtime CSS stylesheets.

  Uses the shared `RuntimePreviewModal` (driven by `PreviewHelpers`) for the record modal —
  Overview · Code · Versions · Configuration — with add/edit happening inside the Configuration tab.
  """
  use MishkaCmsCore.ExtensionLiveView
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.RuntimeStatusLive
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)
    socket = PreviewHelpers.assign_access(socket, MishkaCmsCore.Runtime.Stylesheet)

    socket =
      RuntimeStatusLive.setup(socket,
        resource: MishkaCmsCore.Runtime.Stylesheet,
        table_id: "stylesheets-table",
        tenant_action: :get_for_tenant_with_globals
      )

    socket = PreviewHelpers.setup(socket)

    socket =
      MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed.setup(socket,
        resources: [MishkaCmsCore.Runtime.Stylesheet],
        feed_id: "stylesheets-activity"
      )

    new_socket =
      socket
      |> assign(:page_title, gettext("Listing Stylesheets"))
      |> assign(:url_state, nil)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaCmsCore.Runtime.Stylesheet)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  # The Configuration form lives in the preview modal now; a save/cancel closes that modal.
  @impl true
  def handle_info({:form_saved, :create, _result}, socket),
    do:
      {:noreply,
       socket
       |> PreviewHelpers.dismiss()
       |> put_flash(:info, gettext("Stylesheet created successfully"))}

  @impl true
  def handle_info({:form_saved, :update, _result}, socket),
    do:
      {:noreply,
       socket
       |> PreviewHelpers.dismiss()
       |> put_flash(:info, gettext("Stylesheet updated successfully"))}

  @impl true
  def handle_info({:form_cancelled, _resource}, socket),
    do: {:noreply, PreviewHelpers.dismiss(socket)}

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

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "stylesheet" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "stylesheets-table",
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

  ## Preview modal

  @impl true
  def handle_event("preview_add", _params, socket),
    do: {:noreply, PreviewHelpers.open_new(socket)}

  @impl true
  def handle_event("preview_set_tab", %{"tab" => tab}, socket),
    do: {:noreply, PreviewHelpers.set_tab(socket, tab)}

  @impl true
  def handle_event("close_preview_modal", _params, socket),
    do: {:noreply, PreviewHelpers.close(socket)}

  @impl true
  def handle_event("preview_versions_page", %{"page" => page}, socket),
    do: {:noreply, PreviewHelpers.versions_paginate(socket, String.to_integer(page))}

  @impl true
  def handle_event("preview_version_toggle", %{"id" => id}, socket),
    do: {:noreply, PreviewHelpers.toggle_version(socket, id)}

  @impl true
  def handle_event("preview_version_restore", %{"id" => id}, socket),
    do: {:noreply, PreviewHelpers.restore_version(socket, id)}

  @impl true
  def handle_event("preview_edit_code", _params, socket),
    do: {:noreply, PreviewHelpers.edit_code(socket)}

  @impl true
  def handle_event("preview_cancel_edit", _params, socket),
    do: {:noreply, PreviewHelpers.cancel_edit(socket)}

  @impl true
  def handle_event("preview_code_save", %{"source" => source}, socket),
    do: {:noreply, PreviewHelpers.save_source(socket, source)}
end
