defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.Permission.Index do
  use MishkaCmsCore.ExtensionLiveView
  alias MishkaGervaz.Table.Web.UrlSync
  alias MishkaCmsCore.Accounts.Permission

  @permission_modal_id "permission-details-modal"

  defp default_permission_modal,
    do: %{record: nil, edit_mode?: false, loading?: false, form_record_id: nil}

  defp show_permission_modal(socket),
    do:
      exec_permission_modal_js(
        socket,
        MishkaCmsCore.CoreComponents.show_modal(@permission_modal_id)
      )

  defp hide_permission_modal(socket),
    do:
      exec_permission_modal_js(
        socket,
        MishkaCmsCore.CoreComponents.hide_modal(@permission_modal_id)
      )

  defp exec_permission_modal_js(socket, js),
    do:
      push_event(socket, "gervaz:exec-js", %{
        target: @permission_modal_id,
        js: Jason.encode!(js.ops)
      })

  defp close_permission_modal(socket),
    do: socket |> assign(:permission_modal, default_permission_modal()) |> hide_permission_modal()

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    new_socket =
      socket
      |> assign(:page_title, gettext("Listing Permissions"))
      |> assign(:permission_modal, default_permission_modal())
      |> assign(:url_state, nil)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, Permission)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "permission" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "permissions-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:row_action, "show_permission_modal", %{"id" => id}}, socket),
    do: {:noreply, open_permission_modal(socket, id, false)}

  @impl true
  def handle_info({:row_action, "edit_permission_modal", %{"id" => id}}, socket),
    do: {:noreply, open_permission_modal(socket, id, true)}

  @impl true
  def handle_info({:form_saved, _mode, _result}, socket) do
    {:noreply,
     socket
     |> close_permission_modal()
     |> put_flash(:info, gettext("Permission saved successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    modal = socket.assigns.permission_modal

    if modal.record do
      {:noreply, assign(socket, :permission_modal, %{modal | edit_mode?: false})}
    else
      {:noreply, close_permission_modal(socket)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:load_permission_modal, _id}, {:ok, %{permission: permission}}, socket) do
    modal = %{socket.assigns.permission_modal | record: permission, loading?: false}
    {:noreply, assign(socket, :permission_modal, modal)}
  end

  def handle_async({:load_permission_modal, _id}, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket, :permission_modal, %{socket.assigns.permission_modal | loading?: false})}
  end

  @impl true
  def handle_event("permission_modal_toggle_edit", _params, socket),
    do:
      {:noreply,
       assign(socket, :permission_modal, %{socket.assigns.permission_modal | edit_mode?: true})}

  # + Add Permission → open the modal straight into an empty create form.
  def handle_event("permission_modal_add", _params, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(Permission),
      record_id: nil,
      reset: true
    )

    {:noreply,
     socket
     |> assign(:permission_modal, %{default_permission_modal() | edit_mode?: true})
     |> show_permission_modal()}
  end

  def handle_event("close_permission_modal", _params, socket),
    do: {:noreply, close_permission_modal(socket)}

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  defp open_permission_modal(socket, id, edit?) do
    current_user = socket.assigns.current_user

    socket
    |> assign(:permission_modal, %{
      default_permission_modal()
      | edit_mode?: edit?,
        loading?: true,
        form_record_id: id
    })
    |> show_permission_modal()
    |> MishkaGervaz.Messages.start_async({:load_permission_modal, id}, fn ->
      %{permission: get_permission(id, current_user)}
    end)
  end

  # Master users (`site_id` nil) read through `:master_get`, tenant users through `:tenant_get`
  # under their own site. No other shape reads anything: the load exits and `handle_async` clears
  # the spinner.
  defp get_permission(id, %{site_id: site_id} = actor) when is_binary(site_id),
    do: Ash.get!(Permission, id, action: :tenant_get, actor: actor, tenant: site_id)

  defp get_permission(id, %{site_id: nil} = actor),
    do: Ash.get!(Permission, id, action: :master_get, actor: actor)
end
