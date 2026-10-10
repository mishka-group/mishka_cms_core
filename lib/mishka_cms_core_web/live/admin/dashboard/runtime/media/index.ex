defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Media.Index do
  @moduledoc """
  Media management LiveView with grid/list view and a folders sidebar.
  Uses MishkaGervaz MediaGallery template for media display with real-time updates.
  Media upload/edit form powered by MishkaGervaz Form DSL.

  ## Folders

  The library opens on a folder, `filter_media_category_id` in the URL — the same param the
  gallery's own Folder filter writes, so either one moves the other — or on none, the top level. The
  breadcrumb above names the folders down to it, the rail lists the folders directly inside it, read
  async a page at a time, and the gallery its files. A new folder is made inside it, and a file
  dropped on the upload form lands in it. Each folder in the rail opens, renames, moves and archives;
  each file in the gallery moves too, through
  `MishkaCmsCoreWeb.Live.Admin.Components.MediaMove`.

  At the top level, All media, the gallery shows every file of every folder, newest first; a folder
  shows only its own. Each card names its folder by the whole path to it.

  The folder is the only thing the rail reads again for: the gallery's own filters, sort and page
  patch the same URL and leave it as it is.
  """
  use MishkaCmsCore.ExtensionLiveView
  require Ash.Query
  alias Phoenix.LiveView.AsyncResult
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias MishkaCmsCoreWeb.Live.Admin.Components.MediaMove
  alias MishkaGervaz.Table.Web.UrlSync

  @category_form_modal "media-category-form-modal"
  @media_path "/admin/dashboard/runtime/medias"

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
      |> assign(:folder_id, nil)
      |> assign(:folder_read?, false)
      |> assign(:folder_missing?, false)
      |> assign(:trail, [])
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

    socket = if connected?(socket), do: subscribe_to_pubsub(socket, user), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    folder_id = blank_to_nil(Map.get(params, "filter_media_category_id"))
    url_state = UrlSync.decode(params, uri, Media)

    {:noreply,
     socket
     |> assign(:url_state, url_state)
     |> open_folder(folder_id)}
  end

  # The rail and the breadcrumb are read when the folder changes, and once the socket connects.
  defp open_folder(%{assigns: %{folder_id: folder_id, folder_read?: true}} = socket, folder_id),
    do: socket

  defp open_folder(socket, folder_id) do
    socket = socket |> assign(:folder_id, folder_id) |> assign(:folder_missing?, false)

    if connected?(socket) do
      socket
      |> assign(:folder_read?, true)
      |> load_trail_async()
      |> load_categories_async(page: 1, reset: true)
    else
      socket
    end
  end

  @impl true
  def handle_event("toggle_category_form", _params, socket) do
    send_update(MishkaGervaz.Form.Web.Live,
      id: category_form_component_id(),
      record_id: nil,
      reset: true
    )

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
    send_update(MishkaGervaz.Form.Web.Live,
      id: category_form_component_id(),
      record_id: id,
      reset: true
    )

    {:noreply,
     socket
     |> assign(:editing_category, id)
     |> open_modal(@category_form_modal)}
  end

  def handle_event("move_category", %{"id" => id}, socket) do
    send_update(MediaMove, id: "media-move", open: {:folder, id})
    {:noreply, socket}
  end

  def handle_event("delete_category", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # `authorize?: true` ON EVERY DESTROY HERE, NOT THE DOMAIN'S DEFAULT: Ash resolves that default
    # for `Ash.destroy(record, action: ...)` only after the changeset has been built, so an archiving
    # destroy — which AshArchival routes through the soft clause — hands the action's validations
    # `authorize?: false` and `TenantContext` waves it through. The permanent ones are outside the
    # archive today and resolve it in time; they say it too, so removing them from
    # `exclude_destroy_actions` cannot quietly reopen this.
    #
    # A folder that still holds anything is refused, and the refusal is the reader's to see.
    destroyed =
      with {:ok, category} <- Ash.get(MediaCategory, id, category_read(user)) do
        {action, tenant} = user_action(user, {:master_destroy, :destroy})
        Ash.destroy(category, action: action, actor: user, tenant: tenant, authorize?: true)
      end

    case destroyed do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Folder archived."))
         |> stream_delete(:categories, %{id: id})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refusal(error))}
    end
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

  # A restore is refused when a live folder beside it has taken its name since.
  def handle_event("restore_category", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    restored =
      with {:ok, category} <- Ash.get(MediaCategory, id, archived_category_read(user)) do
        {action, tenant} = user_action(user, {:master_unarchive, :unarchive})
        Ash.update(category, %{}, action: action, actor: user, tenant: tenant)
      end

    case restored do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Folder restored."))
         |> stream_delete(:archived_categories, %{id: id})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refusal(error))}
    end
  end

  def handle_event("permanent_delete_category", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    destroyed =
      with {:ok, category} <- Ash.get(MediaCategory, id, archived_category_read(user)) do
        {action, tenant} = user_action(user, {:master_permanent_destroy, :permanent_destroy})
        Ash.destroy(category, action: action, actor: user, tenant: tenant, authorize?: true)
      end

    case destroyed do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Folder deleted for good."))
         |> stream_delete(:archived_categories, %{id: id})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, refusal(error))}
    end
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

  # A folder the reader cannot open — archived, deleted, another site's, or a mistyped id — is said
  # to be gone in the breadcrumb, beside the way back to the top level, rather than drawn as an empty
  # folder that is there. A path read for a folder the reader has since left is dropped.
  def handle_async(
        :load_trail,
        {:ok, {folder_id, read}},
        %{assigns: %{folder_id: folder_id}} = socket
      ) do
    case read do
      {:ok, [_ | _] = trail} -> {:noreply, assign(socket, :trail, trail)}
      {:ok, []} -> {:noreply, socket |> assign(:trail, []) |> assign(:folder_missing?, true)}
      {:error, _unread} -> {:noreply, assign(socket, :trail, [])}
    end
  end

  def handle_async(:load_trail, _left_or_failed, socket), do: {:noreply, socket}

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

  def handle_info({:row_action, "move_media", %{"id" => id}}, socket) do
    send_update(MediaMove, id: "media-move", open: {:media, id})
    {:noreply, socket}
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
    {:noreply,
     socket
     |> stream_delete(:archived_categories, category)
     |> place_category(category, at: 0)}
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
    {:noreply, place_category(socket, category, at: 0)}
  end

  # A rename or a move. The breadcrumb is read again when the folder is on it: a folder above this
  # one renamed, or this one moved, changes the path to it.
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
    {:noreply,
     socket
     |> place_category(category)
     |> retrail(category)}
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
    socket = socket |> stream_delete(:categories, category) |> retrail(category)

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
    folder_id = socket.assigns.folder_id
    page = Keyword.get(opts, :page, 1)
    reset = Keyword.get(opts, :reset, false)

    socket
    |> assign(:categories_loading, AsyncResult.loading())
    |> MishkaGervaz.Messages.start_async(:load_categories, fn ->
      page_result =
        user
        |> folders_query(folder_id)
        |> Ash.read!(
          page: [offset: (page - 1) * @categories_page_size, limit: @categories_page_size]
        )

      {page, page_result.results, page_result.more?, reset}
    end)
  end

  defp refresh_categories_silently(socket) do
    user = socket.assigns.current_user
    total_limit = socket.assigns.categories_page * @categories_page_size

    page_result =
      user
      |> folders_query(socket.assigns.folder_id)
      |> Ash.read!(page: [limit: total_limit])

    socket
    |> assign(:categories_has_more, page_result.more?)
    |> stream(:categories, page_result.results, reset: true)
  end

  # The folders directly inside `folder_id`, or at the top level for none — every site's top level,
  # for a master.
  defp folders_query(user, folder_id) do
    {action, tenant} = user_action(user, {:master_read, :read})

    MediaCategory
    |> Ash.Query.for_read(action, %{}, actor: user, tenant: tenant)
    |> inside(folder_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.load(category_loads(user))
  end

  defp inside(query, nil), do: Ash.Query.filter(query, is_nil(parent_id))
  defp inside(query, folder_id), do: Ash.Query.filter(query, parent_id == ^folder_id)

  defp load_trail_async(%{assigns: %{folder_id: nil}} = socket), do: assign(socket, :trail, [])

  defp load_trail_async(socket) do
    user = socket.assigns.current_user
    folder_id = socket.assigns.folder_id

    MishkaGervaz.Messages.start_async(socket, :load_trail, fn ->
      {folder_id, MediaCategory.trail(folder_id, actor: user)}
    end)
  end

  defp retrail(socket, category) do
    if Enum.any?(socket.assigns.trail, &(&1.id == category.id)),
      do: load_trail_async(socket),
      else: socket
  end

  # A folder written elsewhere goes in the rail when it sits in the folder the rail lists, and out of
  # it when it does not — a folder moved in arrives, one moved away leaves.
  defp place_category(socket, category, opts \\ []) do
    user = socket.assigns.current_user
    folder_id = socket.assigns.folder_id

    read =
      if visible_to_user?(category, user),
        do: reread_category(category.id, user),
        else: :none

    case read do
      {:ok, %{parent_id: ^folder_id} = here} -> stream_insert(socket, :categories, here, opts)
      _elsewhere_or_gone -> stream_delete(socket, :categories, category)
    end
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

  defp refusal(error), do: MishkaGervaz.Errors.extract_error_message(error, MediaCategory)

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
  defp insert_reread(socket, stream, read, opts)

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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Where a folder opens: the library filtered to it, and to its site for a master, whose Site
  # filter would otherwise go on listing every site.
  defp folder_path(nil, _master?), do: @media_path

  defp folder_path(%{id: id, site_id: site_id}, true),
    do: "#{@media_path}?filter_media_category_id=#{id}&filter_site_id=#{site_id}"

  defp folder_path(%{id: id}, false), do: "#{@media_path}?filter_media_category_id=#{id}"

  # The folder above the one open, `nil` for the top level.
  defp parent_folder(trail), do: trail |> Enum.drop(-1) |> List.last()

  # WHAT A NEW FOLDER AND A NEW FILE START IN: the folder open, and for a master its site, once the
  # breadcrumb has said which — until then the master's form still asks. Each is a default the form
  # drops again when the reader picks another.
  defp form_defaults(nil, _trail, _master?, _field), do: %{}

  defp form_defaults(folder_id, trail, true, field) do
    case List.last(trail) do
      %{id: ^folder_id, site_id: site_id} -> %{:site_id => site_id, field => folder_id}
      _not_read_yet -> %{field => folder_id}
    end
  end

  defp form_defaults(folder_id, _trail, false, field), do: %{field => folder_id}
end
