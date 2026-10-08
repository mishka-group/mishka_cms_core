defmodule MishkaCmsCoreWeb.Live.Admin.Components.MediaMove do
  @moduledoc """
  Moves a file or a folder of the media library into another folder of its site, chosen by browsing
  the folders the way the library's own rail does.

  Its own component because it reads its own folders, as the reader opens them, and answers its own
  clicks; the page only says what to move.

  ## Usage

      <.live_component
        module={MishkaCmsCoreWeb.Live.Admin.Components.MediaMove}
        id="media-move"
        current_user={@current_user}
      />

      send_update(MediaMove, id: "media-move", open: {:media, media_id})
      send_update(MediaMove, id: "media-move", open: {:folder, folder_id})

  It opens on the folder the item is in, lists the folders inside the one being browsed with a path
  back up to the top level, and moves the item with "Move here" — through the resource's own update,
  as the reader, so the resource's rules decide: a folder never goes inside itself or one of its own
  folders, and the folder being moved is never listed, so nothing under it can be opened. A refusal
  is shown in the dialog, and it stays open.

  A move that lands sends `{:put_flash, :info, message}` to the page and closes. The page hears the
  write itself the way it hears anybody's — the row's own broadcast.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1, modal: 1]

  require Ash.Query

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias Phoenix.LiveView.{AsyncResult, JS}

  # The folders inside one folder, read at once. A folder holding more than this has a different
  # problem than how to move a file into one of them.
  @listing_limit 200

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:item, nil)
     |> assign(:browse, nil)
     |> assign(:listing, AsyncResult.loading())
     |> assign(:error, nil)}
  end

  @impl true
  def update(%{open: {kind, id}}, socket) when kind in [:media, :folder] do
    user = socket.assigns.current_user

    socket =
      case read_item(kind, id, user) do
        {:ok, record} ->
          item = %{kind: kind, record: record, location: location(kind, record)}

          socket
          |> assign(:item, item)
          |> assign(:error, nil)
          |> browse(item.location)

        {:error, error} ->
          send(self(), {:put_flash, :error, MishkaGervaz.Errors.extract_error_message(error)})
          assign(socket, :item, nil)
      end

    {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("browse", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(:error, nil) |> browse(blank_to_nil(id))}

  def handle_event("move_here", _params, %{assigns: %{item: %{} = item}} = socket) do
    user = socket.assigns.current_user

    case move(item, socket.assigns.browse, user) do
      {:ok, _moved} ->
        send(self(), {:put_flash, :info, moved_message(item, socket.assigns.listing)})
        {:noreply, assign(socket, :item, nil)}

      {:error, error} ->
        {:noreply, assign(socket, :error, MishkaGervaz.Errors.extract_error_message(error))}
    end
  end

  def handle_event("move_here", _params, socket), do: {:noreply, socket}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :item, nil)}

  @impl true
  def handle_async(:listing, {:ok, {:ok, listing}}, socket),
    do: {:noreply, assign(socket, :listing, AsyncResult.ok(socket.assigns.listing, listing))}

  def handle_async(:listing, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, :listing, AsyncResult.failed(socket.assigns.listing, error))}

  def handle_async(:listing, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :listing, AsyncResult.failed(socket.assigns.listing, reason))}

  defp browse(%{assigns: %{item: %{} = item, current_user: user}} = socket, folder_id) do
    site_id = item.record.site_id
    moving = if item.kind == :folder, do: item.record.id

    socket
    |> assign(:browse, folder_id)
    |> assign(:listing, AsyncResult.loading())
    |> MishkaGervaz.Messages.start_async(:listing, fn ->
      listing(user, site_id, folder_id, moving)
    end)
  end

  # The folders above the one being browsed and the folders inside it, the one being moved left out.
  defp listing(user, site_id, folder_id, moving) do
    with {:ok, trail} <- trail(folder_id, user),
         {:ok, folders} <- folders_inside(user, site_id, folder_id, moving) do
      {:ok, %{trail: trail, folders: folders}}
    end
  end

  defp trail(nil, _user), do: {:ok, []}
  defp trail(folder_id, user), do: MediaCategory.trail(folder_id, actor: user)

  defp folders_inside(user, site_id, folder_id, moving) do
    {action, tenant} = scope(user, {:master_read, :read})

    MediaCategory
    |> Ash.Query.for_read(action, %{}, actor: user, tenant: tenant)
    |> Ash.Query.filter(site_id == ^site_id)
    |> inside(folder_id)
    |> leave_out(moving)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(page: [limit: @listing_limit])
    |> case do
      {:ok, %{results: folders}} -> {:ok, folders}
      {:ok, folders} when is_list(folders) -> {:ok, folders}
      {:error, error} -> {:error, error}
    end
  end

  defp inside(query, nil), do: Ash.Query.filter(query, is_nil(parent_id))
  defp inside(query, folder_id), do: Ash.Query.filter(query, parent_id == ^folder_id)

  defp leave_out(query, nil), do: query
  defp leave_out(query, id), do: Ash.Query.filter(query, id != ^id)

  defp read_item(:media, id, user) do
    {action, tenant} = scope(user, {:master_get, :read})
    Ash.get(Media, id, action: action, actor: user, tenant: tenant)
  end

  defp read_item(:folder, id, user) do
    {action, tenant} = scope(user, {:master_get, :read})
    Ash.get(MediaCategory, id, action: action, actor: user, tenant: tenant)
  end

  defp location(:media, media), do: media.media_category_id
  defp location(:folder, folder), do: folder.parent_id

  defp move(%{kind: :media, record: media}, folder_id, user),
    do: write(media, %{media_category_id: folder_id}, user)

  defp move(%{kind: :folder, record: folder}, folder_id, user),
    do: write(folder, %{parent_id: folder_id}, user)

  defp write(record, changes, user) do
    {action, tenant} = scope(user, {:master_update, :update})
    Ash.update(record, changes, action: action, actor: user, tenant: tenant)
  end

  defp scope(%User{site_id: nil}, {master, _tenant}), do: {master, nil}
  defp scope(%User{site_id: site_id}, {_master, tenant}), do: {tenant, site_id}

  defp moved_message(item, %AsyncResult{ok?: true, result: %{trail: [_ | _] = trail}}) do
    gettext("Moved “%{name}” to %{folder}.",
      name: item.record.name,
      folder: Enum.map_join(trail, " / ", & &1.name)
    )
  end

  defp moved_message(item, _top_level),
    do: gettext("Moved “%{name}” to the top level.", name: item.record.name)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(id), do: id

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal
        :if={@item}
        id={"#{@id}-modal"}
        show
        width_class="max-w-[520px]"
        padding_class="p-0"
        on_cancel={JS.push("close", target: @myself)}
      >
        <div class="flex items-center gap-3 border-b border-[#f0efea] px-5 py-[14px] pe-14">
          <span class="grid size-9 flex-none place-items-center rounded-[11px] bg-[#f2f1fc] text-[#4f4bcc]">
            <.icon name="hero-folder-arrow-down" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <h2
              id={"#{@id}-modal-title"}
              class="truncate font-['Space_Grotesk'] text-[14.5px] font-bold text-[#17161a]"
            >
              {gettext("Move “%{name}”", name: @item.record.name)}
            </h2>
            <p
              id={"#{@id}-modal-description"}
              class="mt-0.5 text-[11.5px] font-medium text-[#6d6a63]"
            >
              {gettext("Open the folder it goes in, then press Move here.")}
            </p>
          </div>
        </div>

        <nav
          id={"#{@id}-trail"}
          aria-label={gettext("Folder path")}
          class="flex flex-wrap items-center gap-1 border-b border-[#f0efea] bg-[#faf9f6] px-5 py-2.5 text-[12px] font-semibold"
        >
          <button
            type="button"
            id={"#{@id}-crumb-top"}
            phx-click="browse"
            phx-value-id=""
            phx-target={@myself}
            class={crumb_class(is_nil(@browse))}
          >
            {gettext("Top level")}
          </button>
          <.async_result :let={listing} assign={@listing}>
            <:loading></:loading>
            <:failed :let={_reason}></:failed>
            <span :for={folder <- listing.trail} class="contents">
              <.icon name="hero-chevron-right" class="size-3 flex-none text-[#a8a5a0] rtl:rotate-180" />
              <button
                type="button"
                id={"#{@id}-crumb-#{folder.id}"}
                dir="auto"
                phx-click="browse"
                phx-value-id={folder.id}
                phx-target={@myself}
                class={crumb_class(folder.id == @browse)}
              >
                {folder.name}
              </button>
            </span>
          </.async_result>
        </nav>

        <div class="max-h-[46vh] min-h-[120px] overflow-y-auto px-3 py-2">
          <.async_result :let={listing} assign={@listing}>
            <:loading>
              <div
                :for={_row <- 1..3//1}
                aria-hidden="true"
                class="flex items-center gap-2.5 px-2 py-2.5"
              >
                <span class="size-7 flex-none animate-pulse rounded-[8px] bg-[#f2f1ec]"></span>
                <span class="h-[9px] w-1/2 animate-pulse rounded-full bg-[#f4f3ee]"></span>
              </div>
            </:loading>
            <:failed :let={_reason}>
              <p class="px-2 py-4 text-[12px] font-medium text-[#c0473d]">
                {gettext("Could not load folders")}
              </p>
            </:failed>

            <p
              :if={listing.folders == []}
              id={"#{@id}-empty"}
              class="px-2 py-6 text-center text-[12px] font-medium text-[#a8a5a0]"
            >
              {gettext("No folders in here.")}
            </p>

            <ul class="flex flex-col gap-0.5">
              <li :for={folder <- listing.folders}>
                <button
                  type="button"
                  id={"#{@id}-folder-#{folder.id}"}
                  phx-click="browse"
                  phx-value-id={folder.id}
                  phx-target={@myself}
                  class="flex w-full items-center gap-2.5 rounded-[10px] px-2 py-2 text-start transition-colors hover:bg-[#f7f6f3]"
                >
                  <span class="grid size-7 flex-none place-items-center rounded-[8px] bg-[#f4f3ee] text-[#6d6a63]">
                    <.icon name="hero-folder" class="size-4" />
                  </span>
                  <span
                    dir="auto"
                    class="min-w-0 flex-1 truncate text-[12.5px] font-semibold text-[#3a382f]"
                  >
                    {folder.name}
                  </span>
                  <.icon
                    name="hero-chevron-right"
                    class="size-4 flex-none text-[#a8a5a0] rtl:rotate-180"
                  />
                </button>
              </li>
            </ul>
          </.async_result>
        </div>

        <p
          :if={@error}
          id={"#{@id}-error"}
          role="alert"
          class="mx-5 mb-1 rounded-[10px] border border-[#f4d6d2] bg-[#fdf0ee] px-3 py-2 text-[12px] font-medium text-[#b13a2f]"
        >
          {@error}
        </p>

        <div class="flex flex-wrap items-center justify-end gap-2 border-t border-[#f0efea] px-5 py-3">
          <span
            :if={@browse == @item.location}
            id={"#{@id}-already-here"}
            class="me-auto text-[11.5px] font-medium text-[#8a877f]"
          >
            {gettext("It is already here.")}
          </span>
          <button
            type="button"
            id={"#{@id}-cancel"}
            phx-click={JS.exec("data-cancel", to: "##{@id}-modal")}
            class="rounded-[10px] border border-[#ecebe6] bg-white px-3.5 py-2 text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            id={"#{@id}-confirm"}
            phx-click="move_here"
            phx-target={@myself}
            disabled={@browse == @item.location or not @listing.ok?}
            class="rounded-[10px] bg-[#4f4bcc] px-3.5 py-2 text-[12px] font-semibold text-white transition-colors hover:bg-[#433fb8] disabled:cursor-not-allowed disabled:opacity-50"
          >
            {gettext("Move here")}
          </button>
        </div>
      </.modal>
    </div>
    """
  end

  defp crumb_class(true),
    do: "max-w-[180px] truncate rounded-[7px] bg-[#eae8f7] px-2 py-1 text-[#4f4bcc]"

  defp crumb_class(false),
    do:
      "max-w-[180px] truncate rounded-[7px] px-2 py-1 text-[#5c5a54] transition-colors hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
end
