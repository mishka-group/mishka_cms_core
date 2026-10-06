defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Media.Index do
  @moduledoc """
  Media management LiveView with grid/list view and categories sidebar.
  Uses MishkaGervaz MediaGallery template for media display with real-time updates.
  Categories sidebar uses async streaming.
  Media upload/edit form powered by MishkaGervaz Form DSL.
  """
  use MishkaCmsCore.ExtensionLiveView
  alias Phoenix.LiveView.AsyncResult
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias MishkaGervaz.Table.Web.UrlSync

  @category_form_modal "media-category-form-modal"

  defp category_form_component_id,
    do: MishkaGervaz.Resource.Info.Form.component_id(MediaCategory)

  # The category Add/Edit form lives in a centered modal driven by the same `gervaz:exec-js` bridge the
  # blog and document card pages use, rather than crammed into the narrow rail. The element stays
  # rendered and JS is pushed to it, so it fades the way every other admin modal does.
  defp open_modal(socket, id),
    do: exec_modal_js(socket, id, MishkaCmsCore.CoreComponents.show_modal(id))

  defp close_modal(socket, id),
    do: exec_modal_js(socket, id, MishkaCmsCore.CoreComponents.hide_modal(id))

  defp exec_modal_js(socket, id, js),
    do: push_event(socket, "gervaz:exec-js", %{target: id, js: Jason.encode!(js.ops)})

  # The selected chip is highlighted client-side with the JS module — no server round-trip, so the
  # highlight is instant. This project's runtime CSS compiler only emits rules for classes present in
  # server-rendered HTML, so a class added by JS never gets a rule; an inline style set via JS needs no
  # compiler and outranks the mobile chip's own bg at any breakpoint. The HEEx template stays on classes
  # — this inline style lives only in the JS module, never in the markup.
  @active_category_style "background-color:#f2f1fc;border-color:#dcdbf5"

  defp apply_category_selection(nil), do: select_category_js("__all__")
  defp apply_category_selection(category_id), do: select_category_js(category_id)

  defp select_category_js(category_id) do
    JS.remove_attribute("style", to: ".category-chip")
    |> JS.set_attribute({"style", @active_category_style},
      to: "[data-category-id='#{category_id}']"
    )
  end

  @pubsub_topics ~w(created updated destroyed)
  @categories_page_size 20

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_master = is_nil(user.site_id)

    socket =
      socket
      |> assign(:page_title, gettext("Media Library"))
      |> assign(:url_state, nil)
      |> assign(:selected_category_id, nil)
      |> assign(:categories_page, 1)
      |> assign(:categories_has_more, false)
      |> assign(:categories_loading, AsyncResult.loading())
      |> assign(:has_categories_data, false)
      |> assign(:category_archive_status, :active)
      |> assign(:archived_categories_page, 1)
      |> assign(:archived_categories_has_more, false)
      |> assign(:archived_categories_loading, AsyncResult.ok(%AsyncResult{}, []))
      |> assign(:has_archived_categories_data, false)
      |> assign(:editing_category, nil)
      |> assign(:is_master, is_master)
      |> assign(
        :media_writer?,
        AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:runtime:media"])
      )
      |> assign(:preview_media, nil)
      |> stream(:categories, [])
      |> stream(:archived_categories, [])

    socket =
      if connected?(socket) do
        socket
        |> subscribe_to_pubsub(user)
        |> load_categories_async(page: 1, reset: true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, Media)
    category_id = Map.get(params, "filter_media_category_id")

    {:noreply,
     socket
     |> assign(:url_state, url_state)
     |> assign(:selected_category_id, category_id)}
  end

  @impl true
  def handle_event("toggle_category_form", _params, socket) do
    send_update(MishkaGervaz.Form.Web.Live, id: category_form_component_id(), record_id: nil)

    {:noreply,
     socket
     |> assign(:editing_category, nil)
     |> open_modal(@category_form_modal)}
  end

  def handle_event("cancel_category_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_category, nil)
     |> close_modal(@category_form_modal)}
  end

  def handle_event("edit_category", %{"id" => id}, socket) do
    send_update(MishkaGervaz.Form.Web.Live, id: category_form_component_id(), record_id: id)

    {:noreply,
     socket
     |> assign(:editing_category, id)
     |> open_modal(@category_form_modal)}
  end

  def handle_event("delete_category", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # `authorize?: true` ON EVERY DESTROY HERE, NOT THE DOMAIN'S DEFAULT: Ash resolves that default
    # for `Ash.destroy(record, action: ...)` only after the changeset has been built, so an archiving
    # destroy — which AshArchival routes through the soft clause — hands the action's validations
    # `authorize?: false` and `TenantContext` waves it through. The permanent ones are outside the
    # archive today and resolve it in time; they say it too, so removing them from
    # `exclude_destroy_actions` cannot quietly reopen this.
    case user do
      %User{site_id: nil} ->
        category = get_category(id, user)
        Ash.destroy!(category, action: :master_destroy, actor: user, authorize?: true)

      %User{site_id: site_id} ->
        category = get_category(id, user)
        Ash.destroy!(category, action: :destroy, actor: user, tenant: site_id, authorize?: true)
    end

    {:noreply,
     socket
     |> put_flash(:info, gettext("Category archived successfully"))
     |> stream_delete(:categories, %{id: id})}
  end

  def handle_event("toggle_category_archive_view", _params, socket) do
    new_status = (socket.assigns.category_archive_status == :active && :archived) || :active

    socket =
      socket
      |> assign(:category_archive_status, new_status)
      |> close_modal(@category_form_modal)
      |> assign(:editing_category, nil)

    new_socket =
      if new_status == :archived do
        load_archived_categories_async(socket, page: 1, reset: true)
      else
        socket
        |> assign(:archived_categories_page, 1)
        |> assign(:has_archived_categories_data, false)
        |> stream(:archived_categories, [], reset: true)
        |> load_categories_async(page: 1, reset: true)
      end

    {:noreply, new_socket}
  end

  def handle_event("load_more_archived_categories", _params, socket) do
    next_page = socket.assigns.archived_categories_page + 1
    {:noreply, load_archived_categories_async(socket, page: next_page, reset: false)}
  end

  def handle_event("restore_category", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case user do
      %User{site_id: nil} ->
        category = get_archived_category(id, user)
        Ash.update!(category, action: :master_unarchive, actor: user)

      %User{site_id: site_id} ->
        category = get_archived_category(id, user)
        Ash.update!(category, action: :unarchive, actor: user, tenant: site_id)
    end

    {:noreply,
     socket
     |> put_flash(:info, gettext("Category restored successfully"))
     |> stream_delete(:archived_categories, %{id: id})}
  end

  def handle_event("permanent_delete_category", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case user do
      %User{site_id: nil} ->
        category = get_archived_category(id, user)
        Ash.destroy!(category, action: :master_permanent_destroy, actor: user, authorize?: true)

      %User{site_id: site_id} ->
        category = get_archived_category(id, user)

        Ash.destroy!(category,
          action: :permanent_destroy,
          actor: user,
          tenant: site_id,
          authorize?: true
        )
    end

    {:noreply,
     socket
     |> put_flash(:info, gettext("Category permanently deleted"))
     |> stream_delete(:archived_categories, %{id: id})}
  end

  def handle_event("load_more_categories", _params, socket) do
    next_page = socket.assigns.categories_page + 1
    {:noreply, load_categories_async(socket, page: next_page, reset: false)}
  end

  def handle_event("show_preview", %{"name" => name, "url" => data_url}, socket) do
    {:noreply, assign(socket, :preview_media, %{name: name, data_url: data_url})}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :preview_media, nil)}
  end

  @impl true
  def handle_async(:load_categories, {:ok, {page, results, has_more, reset}}, socket) do
    socket =
      socket
      |> assign(:has_categories_data, true)
      |> assign(:categories_page, page)
      |> assign(:categories_has_more, has_more)
      |> assign(:categories_loading, AsyncResult.ok(socket.assigns.categories_loading, results))
      |> stream(:categories, results, reset: reset)

    {:noreply, socket}
  end

  def handle_async(:load_categories, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:has_categories_data, true)
     |> assign(:categories_loading, AsyncResult.failed(socket.assigns.categories_loading, reason))}
  end

  def handle_async(:load_archived_categories, {:ok, {page, results, has_more, reset}}, socket) do
    socket =
      socket
      |> assign(:has_archived_categories_data, true)
      |> assign(:archived_categories_page, page)
      |> assign(:archived_categories_has_more, has_more)
      |> assign(
        :archived_categories_loading,
        AsyncResult.ok(socket.assigns.archived_categories_loading, results)
      )
      |> stream(:archived_categories, results, reset: reset)

    {:noreply, socket}
  end

  def handle_async(:load_archived_categories, {:exit, reason}, socket) do
    new_socket =
      socket
      |> assign(:has_archived_categories_data, true)
      |> assign(
        :archived_categories_loading,
        AsyncResult.failed(socket.assigns.archived_categories_loading, reason)
      )

    {:noreply, new_socket}
  end

  @impl true
  def handle_info({:form_saved, :create, _results}, socket) do
    {:noreply,
     socket
     |> assign(:editing_category, nil)
     |> close_modal(@category_form_modal)
     |> put_flash(:info, gettext("Saved successfully"))}
  end

  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> assign(:editing_category, nil)
     |> close_modal(@category_form_modal)
     |> put_flash(:info, gettext("Saved successfully"))}
  end

  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply,
     socket
     |> assign(:editing_category, nil)
     |> close_modal(@category_form_modal)}
  end

  def handle_info({:row_action, "preview", %{"id" => id}}, socket) do
    media = get_media(id, socket.assigns.current_user)
    {:noreply, assign(socket, :preview_media, %{name: media.name, data_url: media.relative_path})}
  end

  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "media" <> _,
          payload: %Ash.Notifier.Notification{resource: Media} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "media-table",
      pubsub_notification: notification
    )

    {:noreply, refresh_categories_silently(socket)}
  end

  # THE TWO CLAUSES THAT NAME AN ACTION NAME BOTH NAMES A WRITE CAN CARRY; the ones after them match
  # on action type and take whatever is left. A master's restore is `:master_unarchive` and their
  # permanent delete is `:master_permanent_destroy`, and Ash publishes the name of the action it ran
  # — so a clause that names only the tenant's half drops a master's write through to the type
  # clauses below. `:master_permanent_destroy` is a destroy like archiving is, and the archive clause
  # put the row nobody can bring back into the archived rail.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{
            resource: MediaCategory,
            action: %{name: name},
            data: category
          }
        },
        socket
      )
      when name in [:unarchive, :master_unarchive] do
    user = socket.assigns.current_user
    socket = stream_delete(socket, :archived_categories, category)

    socket =
      if visible_to_user?(category, user) do
        insert_reread(socket, :categories, reread_category(category.id, user), at: 0)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{
            resource: MediaCategory,
            action: %{name: name},
            data: category
          }
        },
        socket
      )
      when name in [:permanent_destroy, :master_permanent_destroy] do
    {:noreply, stream_delete(socket, :archived_categories, category)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{
            resource: MediaCategory,
            action: %{type: :create},
            data: category
          }
        },
        socket
      ) do
    user = socket.assigns.current_user

    if visible_to_user?(category, user) do
      {:noreply, insert_reread(socket, :categories, reread_category(category.id, user), at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{
            resource: MediaCategory,
            action: %{type: :update},
            data: category
          }
        },
        socket
      ) do
    user = socket.assigns.current_user

    if visible_to_user?(category, user) do
      {:noreply, insert_reread(socket, :categories, reread_category(category.id, user))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          payload: %Ash.Notifier.Notification{
            resource: MediaCategory,
            action: %{type: :destroy},
            data: category
          }
        },
        socket
      ) do
    user = socket.assigns.current_user
    socket = stream_delete(socket, :categories, category)

    socket =
      if visible_to_user?(category, user) && socket.assigns.category_archive_status == :archived do
        insert_reread(
          socket,
          :archived_categories,
          reread_archived_category(category.id, user),
          at: 0
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{resource: MediaCategory}},
        socket
      ) do
    socket =
      if socket.assigns.category_archive_status == :archived,
        do: load_archived_categories_async(socket, page: 1, reset: true),
        else: load_categories_async(socket, page: 1, reset: true)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_categories_async(socket, opts) do
    user = socket.assigns.current_user
    page = Keyword.get(opts, :page, 1)
    reset = Keyword.get(opts, :reset, false)

    socket
    |> assign(:categories_loading, AsyncResult.loading())
    |> MishkaGervaz.Messages.start_async(:load_categories, fn ->
      {action, tenant} = user_action(user, {:master_read, :read})

      page_result =
        MediaCategory
        |> Ash.Query.for_read(action, %{}, actor: user, tenant: tenant)
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.load(category_loads(user))
        |> Ash.read!(
          page: [offset: (page - 1) * @categories_page_size, limit: @categories_page_size]
        )

      {page, page_result.results, page_result.more?, reset}
    end)
  end

  defp refresh_categories_silently(socket) do
    user = socket.assigns.current_user
    current_page = socket.assigns.categories_page
    {action, tenant} = user_action(user, {:master_read, :read})
    total_limit = current_page * @categories_page_size

    page_result =
      MediaCategory
      |> Ash.Query.for_read(action, %{}, actor: user, tenant: tenant)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.load(category_loads(user))
      |> Ash.read!(page: [limit: total_limit])

    socket
    |> assign(:categories_has_more, page_result.more?)
    |> stream(:categories, page_result.results, reset: true)
  end

  defp visible_to_user?(_record, %User{site_id: nil}), do: true
  defp visible_to_user?(record, %User{site_id: site_id}), do: record.site_id == site_id

  defp category_loads(%User{site_id: nil}), do: [:media_count, :site]
  defp category_loads(_user), do: [:media_count]

  # The archived rail counts nothing — it offers Restore and Delete permanently, not a way into the
  # files — so it asks for no count either.
  defp archived_category_loads(user), do: category_loads(user) -- [:media_count]

  defp user_action(%User{site_id: nil}, {master, _tenant}), do: {master, nil}
  defp user_action(%User{site_id: site_id}, {_master, tenant}), do: {tenant, site_id}

  defp get_media(id, user) do
    {action, tenant} = user_action(user, {:master_get, :read})
    Ash.get!(Media, id, action: action, actor: user, tenant: tenant)
  end

  defp get_category(id, user), do: Ash.get!(MediaCategory, id, category_read(user))

  defp get_archived_category(id, user),
    do: Ash.get!(MediaCategory, id, archived_category_read(user))

  # THE ROW A NOTIFICATION CARRIES IS THE ROW THE WRITE RETURNED: no `:site`, no count, and no
  # promise it is still there. The rail reads it back through its own action, actor and tenant —
  # loading onto the bare row asks this resource for a query carrying none of them, which a
  # resource that is never global refuses.
  #
  # `:master_get` is one of the archive's `exclude_read_actions`, so it answers for an archived row
  # as readily as a live one, while the tenant's `:read` and both of the active rail's list actions
  # do not. Two writers publish in no fixed order between them, so an update that reaches this
  # LiveView behind the archive that overtook it would otherwise leave a master looking at a row
  # their own list can never return — the active rail asks about the state its action does not.
  defp reread_category(id, user) do
    case Ash.get(MediaCategory, id, [load: category_loads(user)] ++ category_read(user)) do
      {:ok, %{archived_at: nil} = category} -> {:ok, category}
      _archived_or_gone -> :none
    end
  end

  defp reread_archived_category(id, user) do
    read =
      Ash.get(
        MediaCategory,
        id,
        [load: archived_category_loads(user)] ++ archived_category_read(user)
      )

    case read do
      {:ok, category} -> {:ok, category}
      {:error, _gone} -> :none
    end
  end

  # A row the rail's own read no longer answers for — deleted for good between the write and this,
  # or archived out from under the notification — is one to leave out, not a page to lose.
  defp insert_reread(socket, stream, read, opts \\ [])

  defp insert_reread(socket, stream, {:ok, category}, opts),
    do: stream_insert(socket, stream, category, opts)

  defp insert_reread(socket, _stream, :none, _opts), do: socket

  defp category_read(user) do
    {action, tenant} = user_action(user, {:master_get, :read})
    [action: action, actor: user, tenant: tenant]
  end

  defp archived_category_read(user) do
    {action, tenant} = user_action(user, {:master_get_archived, :get_archived})
    [action: action, actor: user, tenant: tenant]
  end

  defp load_archived_categories_async(socket, opts) do
    user = socket.assigns.current_user
    page = Keyword.get(opts, :page, 1)
    reset = Keyword.get(opts, :reset, false)

    socket
    |> assign(:archived_categories_loading, AsyncResult.loading())
    |> MishkaGervaz.Messages.start_async(:load_archived_categories, fn ->
      {action, tenant} = user_action(user, {:master_archived, :archived})

      page_result =
        MediaCategory
        |> Ash.Query.for_read(action, %{}, actor: user, tenant: tenant)
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.load(archived_category_loads(user))
        |> Ash.read!(
          page: [offset: (page - 1) * @categories_page_size, limit: @categories_page_size]
        )

      {page, page_result.results, page_result.more?, reset}
    end)
  end

  defp subscribe_to_pubsub(socket, user) do
    category_topics = pubsub_topics("media_category", user)

    for topic <- category_topics do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
    end

    socket
  end

  defp pubsub_topics(prefix, %User{site_id: nil}),
    do: Enum.map(@pubsub_topics, &"#{prefix}:#{&1}")

  defp pubsub_topics(prefix, %User{site_id: site_id}),
    do: Enum.flat_map(@pubsub_topics, &["#{prefix}:#{&1}", "#{prefix}:#{site_id}:#{&1}"])
end
