# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index do
  @moduledoc """
  The admin's list of the words runtime templates ask `t/1` for — a Gervaz table and a Gervaz form,
  nothing drawn by hand.

  A row is a word, its languages shown as chips. **Translate** opens every language of it at once —
  see `MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup`, which the visual editor's sheet
  shares — and **Delete** removes it in every language.

  Two actions sit above the table that no row can offer: **Scan templates**, the backfill for
  templates saved before `t/1` existed or before the site gained a language, and **Remove unused**,
  which deletes the rows no template asks for any more. See `MishkaCmsCore.Runtime.Translations`.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Runtime.{Translation, Translations}
  alias MishkaCmsCoreWeb.Live.Admin.Components.TranslationGroup
  alias MishkaGervaz.Table.Web.UrlSync

  @modal_id "translation-modal"
  @table_id "translations-table"
  @unused_modal_id "translations-unused-modal"
  @unused_table_id "translations-unused"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn -> nil end)
      |> assign(:page_title, gettext("Translations"))
      |> assign(:url_state, nil)
      |> assign(:modal_id, @modal_id)
      |> assign(:table_id, @table_id)
      |> assign(:translation_group, nil)
      |> assign(:unused_modal_id, @unused_modal_id)
      |> assign(:unused_table_id, @unused_table_id)
      |> assign(:unused_ids, nil)

    {:ok, assign(socket, :writable?, writable?(socket))}
  end

  @impl true
  def handle_params(params, uri, socket),
    do: {:noreply, assign(socket, :url_state, UrlSync.decode(params, uri, Translation))}

  # EVERY CHANGE REACHES THE TABLE AS A NOTIFICATION — a save, a delete, and the rows Scan templates
  # and Remove unused write or take away. Nothing here reloads it: a reload rewrites the address, and
  # that took the flash the page had just shown down with it.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "translation" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, pubsub_notification: notification)

    if socket.assigns.unused_ids,
      do:
        send_update(MishkaGervaz.Table.Web.Live,
          id: @unused_table_id,
          pubsub_notification: notification
        )

    {:noreply, socket}
  end

  def handle_info({:row_action, "edit_translation", %{"id" => id}}, socket) do
    socket = TranslationGroup.open(socket, id)

    {:noreply,
     if(socket.assigns.translation_group, do: open_modal(socket, @modal_id), else: socket)}
  end

  def handle_info({:row_action, "delete_translation_key", %{"id" => id}}, socket) do
    case Translations.delete_key(socket.assigns.current_user, id) do
      {:ok, removed} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Deleted in every language (%{removed})", removed: removed)
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("That word is no longer there."))}
    end
  end

  # A NEW WORD OPENS IN EVERY LANGUAGE. "Add translation" wrote one; the rest are what comes next.
  def handle_info({:form_saved, :create, %Translation{id: id}}, socket) do
    {:noreply,
     socket |> TranslationGroup.open(id) |> put_flash(:info, gettext("Translation saved"))}
  end

  def handle_info({:form_saved, _mode, _result}, socket),
    do:
      {:noreply,
       socket |> TranslationGroup.saved() |> put_flash(:info, gettext("Translation saved"))}

  def handle_info({:form_cancelled, _resource}, socket), do: {:noreply, close_modal(socket)}

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("translation_add", _params, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: MishkaGervaz.Resource.Info.Form.component_id(Translation),
      record_id: nil,
      reset: true
    )

    {:noreply, socket |> TranslationGroup.close() |> open_modal(@modal_id)}
  end

  def handle_event("translation_pick", %{"id" => id}, socket),
    do: {:noreply, TranslationGroup.pick(socket, id)}

  def handle_event("translation_add_language", %{"language" => language}, socket),
    do: {:noreply, TranslationGroup.add_language(socket, language)}

  def handle_event("close_translation_modal", _params, socket),
    do: {:noreply, close_modal(socket)}

  def handle_event("translations_sync", _params, socket) do
    case {scope(socket), writable?(socket)} do
      {scope, true} when scope != :none ->
        :ok = Translations.sync(scope)

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Templates scanned — every key they ask for has a row now")
         )}

      _not_theirs ->
        {:noreply, put_flash(socket, :error, gettext("You cannot scan the templates."))}
    end
  end

  # REMOVE UNUSED SHOWS WHAT IT WOULD DELETE FIRST — the same table, scoped to those rows, each with
  # its own Translate and Delete — and deletes the lot only when asked again.
  def handle_event("translations_unused", _params, socket) do
    ids = Translations.unused_ids(socket.assigns.current_user, scope(socket))
    {:noreply, socket |> assign(:unused_ids, ids) |> open_modal(@unused_modal_id)}
  end

  def handle_event("translations_purge_unused", _params, socket) do
    removed = Translations.purge_unused(socket.assigns.current_user, scope(socket))

    {:noreply,
     socket
     |> close_unused()
     |> put_flash(
       :info,
       gettext("%{removed} unused translation(s) removed", removed: removed)
     )}
  end

  def handle_event("close_unused_modal", _params, socket), do: {:noreply, close_unused(socket)}

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Whether the viewer may write words at all: the page shows the list to every dashboard admin, and
  # its buttons to the holders of the translation section.
  defp writable?(socket) do
    case scope(socket) do
      :none -> false
      :all -> Translations.may_write?(socket.assigns.current_user, nil)
      site_id -> Translations.may_write?(socket.assigns.current_user, site_id)
    end
  end

  # A SITE ADMIN'S BUTTONS REACH THEIR OWN SITE; a master's (`site_id` nil) reach every site; no user
  # reaches nothing. The actor decides, not anything the page was sent — the same rule the resource's
  # policies hold every read and write to.
  defp scope(socket) do
    case socket.assigns.current_user do
      %{site_id: site_id} when is_binary(site_id) -> site_id
      %{site_id: nil} -> :all
      _nobody -> :none
    end
  end

  defp open_modal(socket, id) do
    push_event(socket, "gervaz:exec-js", %{
      target: id,
      js: Jason.encode!(MishkaCmsCore.CoreComponents.show_modal(id).ops)
    })
  end

  defp hide_modal_by(socket, id) do
    push_event(socket, "gervaz:exec-js", %{
      target: id,
      js: Jason.encode!(MishkaCmsCore.CoreComponents.hide_modal(id).ops)
    })
  end

  defp close_modal(socket), do: socket |> TranslationGroup.close() |> hide_modal_by(@modal_id)

  defp close_unused(socket),
    do: socket |> assign(:unused_ids, nil) |> hide_modal_by(@unused_modal_id)
end
