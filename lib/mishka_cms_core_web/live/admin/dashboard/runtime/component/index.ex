# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Component.Index do
  @moduledoc """
  The admin's component list, and the modal that makes a new one.

  ## Two ways to create, both on the "+ Add" button

  The button that opens the create modal carries a caret, and the caret holds the two ways of ending
  up in the visual editor with a new component:

    * **Fill in the details, then open the editor** — pressing it records the intent in
      `open_builder?` and opens the ordinary modal. The save that follows is the ordinary save; the
      guarded `{:form_saved, :create, result}` clause below turns it into a redirect. The question is
      asked where the reader is choosing how to make one, not at the bottom of a modal they have
      already committed to.
    * **Create empty & open editor** — the button's main half, a plain link to the editor's address
      for a new component. It LEAVES without opening the modal at all, so none of this form's validations
      fire on a form the reader has just said they do not want to fill in; the editor asks for the
      two or three things a record cannot exist without and makes it there.

  Both ask `runtime:document:editor_url` for that address (`Section.editor_url/2`). With no editor
  installed it answers `nil`: the main half opens the full form and the first way is not offered.

  ## One modal for everything

  Creating, viewing and editing all happen in the inspector modal's Configuration tab
  (`MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers`). There is no separate
  `component-form-modal`: two mounts of one form component on a page collide on their DOM id, and the
  form is what an author edits after reading the very tabs beside it.

  ## Duplicate

  The inspector's header offers **Duplicate** on this page and on no other runtime table: it writes
  `<name>-copy-<4 characters>` beside the open component, closes the modal and flashes the new name.
  The copy reaches the table through the resource's own `component:*` broadcast, like any create.
  See `MishkaCmsCore.Runtime.ComponentCopy`.
  """

  use MishkaCmsCore.ExtensionLiveView
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.RuntimeStatusLive
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)
    socket = PreviewHelpers.assign_access(socket, MishkaCmsCore.Runtime.Component)

    socket =
      RuntimeStatusLive.setup(socket,
        resource: MishkaCmsCore.Runtime.Component,
        table_id: "components-table",
        tenant_action: :get_for_tenant_with_globals
      )

    socket = PreviewHelpers.setup(socket)

    socket =
      MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed.setup(socket,
        resources: [MishkaCmsCore.Runtime.Component],
        feed_id: "components-activity"
      )

    new_socket =
      socket
      |> assign(:page_title, gettext("Listing Components"))
      |> assign(:url_state, nil)

    {:ok,
     new_socket
     |> assign(:open_builder?, false)
     |> assign(:editor_url, Section.editor_url("component"))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaCmsCore.Runtime.Component)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  # THE EDITOR IS ASKED AGAIN, NOT REMEMBERED from mount: it answers with the new record's own
  # address, and an editor gone since the menu was drawn leaves the plain create behind.
  def handle_info({:form_saved, :create, result}, %{assigns: %{open_builder?: true}} = socket) do
    socket = assign(socket, :open_builder?, false)

    case Section.editor_url("component", result.id) do
      nil -> {:noreply, created(socket)}
      url -> {:noreply, push_navigate(socket, to: url)}
    end
  end

  def handle_info({:form_saved, :create, _result}, socket), do: {:noreply, created(socket)}

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> PreviewHelpers.dismiss()
     |> put_flash(:info, gettext("Component updated successfully"))}
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

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "component" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "components-table",
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
      when name in [
             :load_preview,
             :preview_versions,
             :preview_compile,
             :preview_duplicate,
             :preview_metrics
           ],
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

  def handle_event("preview_duplicate", _params, socket),
    do: {:noreply, PreviewHelpers.duplicate(socket)}

  def handle_event("preview_set_tab", %{"tab" => tab}, socket),
    do: {:noreply, PreviewHelpers.set_tab(socket, tab)}

  @impl true
  def handle_event("preview_set_device", %{"device" => device}, socket),
    do: {:noreply, PreviewHelpers.set_device(socket, device)}

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
  def handle_event("preview_code_save", %{"source" => source}, socket),
    do: {:noreply, PreviewHelpers.save_source(socket, source)}

  defp created(socket),
    do:
      socket
      |> PreviewHelpers.dismiss()
      |> put_flash(:info, gettext("Component created successfully"))
end
