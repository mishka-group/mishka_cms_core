defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaGervaz.Table.Web.UrlSync
  alias MishkaCmsCore.Accounts.User

  @user_modal_id "user-details-modal"
  @modal_actions [:confirm_by_admin]

  defp default_user_modal,
    do: %{
      record: nil,
      edit_mode?: false,
      loading?: false,
      form_record_id: nil,
      allowed: []
    }

  defp show_user_modal(socket),
    do: exec_user_modal_js(socket, MishkaCmsCore.CoreComponents.show_modal(@user_modal_id))

  defp hide_user_modal(socket),
    do: exec_user_modal_js(socket, MishkaCmsCore.CoreComponents.hide_modal(@user_modal_id))

  defp exec_user_modal_js(socket, js),
    do: push_event(socket, "gervaz:exec-js", %{target: @user_modal_id, js: Jason.encode!(js.ops)})

  defp close_user_modal(socket),
    do: socket |> assign(:user_modal, default_user_modal()) |> hide_user_modal()

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)

    new_socket =
      socket
      |> assign(:page_title, gettext("Users"))
      |> assign(:user_modal, default_user_modal())
      |> assign(:url_state, nil)

    {:ok, new_socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, User)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "user" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "users-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  # Eye action → open the details modal in read-only view; edit pencil → open straight in edit mode with
  # the record loaded into the form. Both load the full user (site + permissions) asynchronously.
  @impl true
  def handle_info({:row_action, "show_user_modal", %{"id" => id}}, socket),
    do: {:noreply, open_user_modal(socket, id, false)}

  @impl true
  def handle_info({:row_action, "edit_user_modal", %{"id" => id}}, socket),
    do: {:noreply, open_user_modal(socket, id, true)}

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_user_modal()
     |> put_flash(:info, dgettext("mishka_gervaz", "User created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_user_modal()
     |> put_flash(:info, dgettext("mishka_gervaz", "User updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    modal = socket.assigns.user_modal

    if modal.record do
      {:noreply, assign(socket, :user_modal, %{modal | edit_mode?: false})}
    else
      {:noreply, close_user_modal(socket)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:load_user_modal, _id}, {:ok, loaded}, socket) do
    {:noreply,
     assign(socket, :user_modal, %{
       socket.assigns.user_modal
       | record: loaded.user,
         allowed: loaded.allowed,
         loading?: false
     })}
  end

  def handle_async({:load_user_modal, _id}, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :user_modal, %{socket.assigns.user_modal | loading?: false})}
  end

  @impl true
  def handle_event("user_modal_add", _params, socket) do
    {:noreply,
     socket
     |> assign(:user_modal, %{default_user_modal() | edit_mode?: true})
     |> show_user_modal()}
  end

  def handle_event("user_modal_toggle_edit", _params, socket),
    do: {:noreply, assign(socket, :user_modal, %{socket.assigns.user_modal | edit_mode?: true})}

  def handle_event("close_user_modal", _params, socket),
    do: {:noreply, close_user_modal(socket)}

  def handle_event("user_modal_confirm", _params, socket),
    do:
      {:noreply,
       on_modal_user(socket, :confirm_by_admin, %{}, gettext("The account is confirmed."))}

  # `tab_event` placeholder for the tab-less DetailModal shell.
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  defp open_user_modal(socket, id, edit?) do
    socket
    |> assign(:user_modal, %{
      default_user_modal()
      | edit_mode?: edit?,
        loading?: true,
        form_record_id: id
    })
    |> show_user_modal()
    |> load_user_modal(id)
  end

  defp load_user_modal(socket, id) do
    current_user = socket.assigns.current_user

    MishkaGervaz.Messages.start_async(socket, {:load_user_modal, id}, fn ->
      user = get_user(id, current_user)

      %{
        user: user,
        allowed: Enum.filter(@modal_actions, &allowed?(user, &1, current_user))
      }
    end)
  end

  defp allowed?(user, action, actor),
    do: Ash.can?({user, action}, actor, tenant: user.site_id, maybe_is: false)

  # The header's buttons, each shown only when the policies let the admin run it on this account.
  # The record they write is read again after, as the table's row is.
  defp on_modal_user(socket, action, params, done) do
    %{record: user} = socket.assigns.user_modal

    if action in socket.assigns.user_modal.allowed do
      user
      |> Ash.Changeset.for_update(action, params,
        actor: socket.assigns.current_user,
        tenant: user.site_id
      )
      |> Ash.update()
      |> case do
        {:ok, _user} ->
          socket
          |> put_flash(:info, done)
          |> load_user_modal(user.id)

        {:error, _error} ->
          put_flash(socket, :error, gettext("This account could not be changed."))
      end
    else
      socket
    end
  end

  # Master users (`site_id` nil) read any user (`:master_get`); tenant users get only their own
  # site's users (`:tenant_get` requires the tenant in context). No other shape reads anything: the
  # load exits and `handle_async` clears the spinner.
  defp get_user(id, %{site_id: site_id} = actor) when is_binary(site_id),
    do:
      Ash.get!(User, id,
        action: :tenant_get,
        actor: actor,
        tenant: site_id
      )

  defp get_user(id, %{site_id: nil} = actor),
    do: Ash.get!(User, id, action: :master_get, actor: actor)
end
