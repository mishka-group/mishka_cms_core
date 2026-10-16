# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Redirect.Index do
  @moduledoc """
  The admin's list of a site's redirect rules — a Gervaz table and a Gervaz form, nothing drawn by
  hand.

  Every dashboard admin reads the list; its buttons that write are offered to the holders of the
  redirect section (`MishkaCmsCore.Runtime.Redirects.writes?/1`), and the resource's policies hold
  each write to the actor's own site. See `MishkaCmsCore.Runtime.Redirect` for the table, filter, row
  action and form definitions.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.{Redirect, Redirects}
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaGervaz.Table.Web.UrlSync

  @form_modal "redirect-form-modal"
  @table_id "redirects-table"

  # The user's permissions are loaded once here, so the table asking each row whether it may be
  # edited reads them rather than the database.
  @impl true
  def mount(_params, _session, socket) do
    user = AccessPermissions.with_permissions(socket.assigns[:current_user])

    socket =
      socket
      |> assign(:current_user, user)
      |> ActivityFeed.setup(resources: [Redirect], feed_id: "redirects-activity")

    {:ok,
     socket
     |> assign(:page_title, gettext("Redirects"))
     |> assign(:url_state, nil)
     |> assign(:form_modal, @form_modal)
     |> assign(:table_id, @table_id)
     |> assign(:writable?, Redirects.writes?(user))}
  end

  @impl true
  def handle_params(params, uri, socket),
    do: {:noreply, assign(socket, :url_state, UrlSync.decode(params, uri, Redirect))}

  # A NEW RULE OPENS AN EMPTY FORM, whichever rule the form was last opened on.
  @impl true
  def handle_event("redirect_add", _params, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(Redirect),
      record_id: nil,
      reset: true
    )

    {:noreply, modal(socket, MishkaCmsCore.CoreComponents.show_modal(@form_modal))}
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket),
    do: {:noreply, socket |> close_form() |> put_flash(:info, gettext("Redirect created"))}

  def handle_info({:form_saved, :update, _result}, socket),
    do: {:noreply, socket |> close_form() |> put_flash(:info, gettext("Redirect updated"))}

  def handle_info({:form_cancelled, _resource}, socket), do: {:noreply, close_form(socket)}

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "redirect" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, pubsub_notification: notification)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp close_form(socket), do: modal(socket, MishkaCmsCore.CoreComponents.hide_modal(@form_modal))

  defp modal(socket, js),
    do: push_event(socket, "gervaz:exec-js", %{target: @form_modal, js: Jason.encode!(js.ops)})
end
