defmodule MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser do
  @moduledoc """
  Media Manager inside the content editor's settings
  (`MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker`): the pictures, or the videos,
  of the site the record is on, newest first, 48 at a time with Load more for the next, searchable
  by name, and an upload that adds a file to the site's media and picks it. At the top, All media,
  every folder's files are listed and the folders beside them; a folder opened lists only its own,
  and the folders inside it, with the way back up above.

  A pick goes back to the settings that opened this as
  `send_update(ContentComponentPicker, id: target, media: %{url: url})`, and Back as
  `media: :closed` — or to the component `notify` names, a form's picture field
  (`MishkaCmsCoreWeb.Live.Admin.Components.MediaField`). The library is read as the signed-in user —
  a master's on the record's site, a site user's on their own — and an upload is the `Media`
  resource's own `upload` (or `master_upload`) action, so its checks are the library's.

  Given a `folder` name, an upload is filed in the folder of that name at the top of the site's
  media, made on the first upload; without one, at the top. The author may file it elsewhere — any
  folder of the site, none, or a new one made there and then. `library: :closed` shows the upload
  alone, and the files only once they are asked for; `back: false` leaves out Back; `in_form: true`
  is for a chooser drawn inside another form, whose upload and folder controls must not be a form
  inside it. `opened` is the count of the form it is drawn in (`MishkaGervaz.Form.Web.State`): when
  it changes, the chooser starts over, closed again as its opener asks.

  It is its own component because it reads its own query, in the background.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker
  alias Phoenix.LiveView.AsyncResult

  @extensions %{images: ~w(.jpg .jpeg .png .gif .webp .svg), videos: ~w(.mp4 .webm .mov)}
  @shown 48
  @folders_shown 100

  @impl true
  def mount(socket),
    do: {:ok, socket |> assign(back?: true, in_form?: false, opened: nil) |> fresh()}

  # What the chooser starts with, and starts over with when the form it is in opens again.
  defp fresh(socket) do
    assign(socket,
      query: "",
      library: AsyncResult.loading(),
      more?: false,
      loading_more?: false,
      failure: nil,
      notify: socket.assigns[:notify] || ContentComponentPicker,
      folder: socket.assigns[:folder],
      destination: :default,
      folders: nil,
      trail: [],
      subfolders: nil,
      choosing_folder?: false,
      naming_folder?: false,
      folder_failure: nil,
      browsing?: nil
    )
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> start_over(assigns)
      |> assign(
        Map.take(assigns, [:id, :target, :site_id, :current_user, :accepts, :notify, :folder])
      )
      |> assign(:back?, Map.get(assigns, :back, socket.assigns.back?))
      |> assign(:in_form?, Map.get(assigns, :in_form, socket.assigns.in_form?))
      |> browsing(assigns)
      |> allow()

    case socket.assigns.library do
      %AsyncResult{loading: nil, ok?: true} -> {:ok, socket}
      _first when socket.assigns.browsing? -> {:ok, load(socket)}
      _closed -> {:ok, socket}
    end
  end

  defp start_over(%{assigns: %{opened: seen}} = socket, %{opened: opened})
       when not is_nil(seen) and opened != seen do
    socket
    |> cancel_entries()
    |> fresh()
    |> assign(:opened, opened)
  end

  defp start_over(socket, %{opened: opened}), do: assign(socket, :opened, opened)
  defp start_over(socket, _assigns), do: socket

  defp cancel_entries(%{assigns: %{uploads: %{file: %{entries: entries}}}} = socket),
    do: Enum.reduce(entries, socket, &cancel_upload(&2, :file, &1.ref))

  defp cancel_entries(socket), do: socket

  # Whether the files are shown: as the opener asks the first time, then as the author leaves it.
  defp browsing(%{assigns: %{browsing?: nil}} = socket, assigns),
    do: assign(socket, :browsing?, Map.get(assigns, :library, :open) == :open)

  defp browsing(socket, _assigns), do: socket

  defp allow(%{assigns: %{uploads: %{file: _}}} = socket), do: socket

  defp allow(socket) do
    allow_upload(socket, :file,
      accept: Map.fetch!(@extensions, socket.assigns.accepts),
      max_entries: 1,
      max_file_size: 50_000_000,
      auto_upload: true,
      progress: &handle_progress/3
    )
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) when is_binary(query),
    do: {:noreply, socket |> assign(:query, String.trim(query)) |> load_files()}

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("pick", %{"url" => url}, socket) when is_binary(url) do
    send_update(socket.assigns.notify, id: socket.assigns.target, media: %{url: url})
    {:noreply, socket}
  end

  def handle_event("back", _params, socket) do
    send_update(socket.assigns.notify, id: socket.assigns.target, media: :closed)
    {:noreply, socket}
  end

  def handle_event("browse", _params, socket),
    do: {:noreply, socket |> assign(:browsing?, true) |> load()}

  def handle_event("more", _params, %{assigns: %{library: %AsyncResult{ok?: true}}} = socket) do
    %{current_user: user, site_id: site_id, accepts: accepts, query: query} = socket.assigns
    offset = length(socket.assigns.library.result)
    folder = open_folder_id(socket.assigns)

    {:noreply,
     socket
     |> assign(:loading_more?, true)
     |> MishkaGervaz.Messages.start_async(:more, fn ->
       {{query, folder}, read(user, site_id, accepts, query, folder, offset)}
     end)}
  end

  def handle_event("more", _params, socket), do: {:noreply, socket}

  def handle_event(
        "open_folder",
        %{"id" => id},
        %{assigns: %{subfolders: %AsyncResult{ok?: true}}} = socket
      ) do
    case List.keyfind(socket.assigns.subfolders.result, id, 0) do
      {id, name} ->
        {:noreply, socket |> assign(:trail, socket.assigns.trail ++ [{id, name}]) |> load()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("open_folder", _params, socket), do: {:noreply, socket}

  def handle_event("folder_up", %{"to" => ""}, socket),
    do: {:noreply, socket |> assign(:trail, []) |> load()}

  def handle_event("folder_up", %{"to" => id}, socket) do
    case Enum.find_index(socket.assigns.trail, &(elem(&1, 0) == id)) do
      nil ->
        {:noreply, socket}

      at ->
        {:noreply, socket |> assign(:trail, Enum.take(socket.assigns.trail, at + 1)) |> load()}
    end
  end

  def handle_event("choose_folder", _params, socket) do
    %{current_user: user, site_id: site_id} = socket.assigns

    {:noreply,
     socket
     |> assign(choosing_folder?: true, folder_failure: nil, folders: AsyncResult.loading())
     |> MishkaGervaz.Messages.start_async(:folders, fn -> read_folders(user, site_id) end)}
  end

  def handle_event("folder", %{"folder" => "new"}, socket),
    do: {:noreply, assign(socket, naming_folder?: true, folder_failure: nil)}

  def handle_event("folder", %{"folder" => value}, socket) when is_binary(value),
    do: {:noreply, socket |> assign(:destination, destination(value, socket)) |> folder_chosen()}

  def handle_event("folder", _params, socket), do: {:noreply, socket}

  def handle_event("create_folder", %{"name" => name}, socket) when is_binary(name) do
    %{current_user: user, site_id: site_id} = socket.assigns

    case String.trim(name) do
      "" ->
        {:noreply, assign(socket, :folder_failure, gettext("Name the folder first."))}

      name ->
        case new_folder(user, site_id, name) do
          {:ok, %{id: id, name: made}} ->
            {:noreply, socket |> assign(:destination, {id, made}) |> folder_chosen()}

          {:error, _reason} ->
            {:noreply,
             assign(
               socket,
               :folder_failure,
               gettext("The folder could not be made — its name may be taken here.")
             )}
        end
    end
  end

  def handle_event("create_folder", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_folder", _params, socket), do: {:noreply, folder_chosen(socket)}

  def handle_event("upload_validate", _params, socket), do: {:noreply, socket}
  def handle_event("upload_save", _params, socket), do: {:noreply, socket}

  def handle_event("upload_cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  @impl true
  def handle_async(:library, {:ok, {:ok, {files, more?}}}, socket),
    do: {:noreply, assign(socket, library: AsyncResult.ok(files), more?: more?)}

  def handle_async(:library, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :library, AsyncResult.failed(socket.assigns.library, reason))}

  def handle_async(:library, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :library, AsyncResult.failed(socket.assigns.library, reason))}

  # A page read for a search or a folder since left is dropped.
  def handle_async(:more, {:ok, {scope, {:ok, {files, more?}}}}, socket) do
    if scope == {socket.assigns.query, open_folder_id(socket.assigns)} do
      library = AsyncResult.ok(socket.assigns.library, socket.assigns.library.result ++ files)
      {:noreply, assign(socket, library: library, more?: more?, loading_more?: false)}
    else
      {:noreply, assign(socket, :loading_more?, false)}
    end
  end

  def handle_async(:more, {:ok, {_query, {:error, _reason}}}, socket),
    do:
      {:noreply,
       assign(socket,
         loading_more?: false,
         failure: gettext("The next files could not be read.")
       )}

  def handle_async(:more, _stale_or_exit, socket),
    do: {:noreply, assign(socket, :loading_more?, false)}

  def handle_async(:subfolders, {:ok, {parent, {:ok, folders}}}, socket) do
    if parent == open_folder_id(socket.assigns),
      do: {:noreply, assign(socket, :subfolders, AsyncResult.ok(folders))},
      else: {:noreply, socket}
  end

  def handle_async(:subfolders, {:ok, {_parent, {:error, reason}}}, socket),
    do: {:noreply, assign(socket, :subfolders, AsyncResult.failed(%AsyncResult{}, reason))}

  def handle_async(:subfolders, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :subfolders, AsyncResult.failed(%AsyncResult{}, reason))}

  def handle_async(:folders, {:ok, {:ok, folders}}, socket),
    do: {:noreply, assign(socket, :folders, AsyncResult.ok(folders))}

  def handle_async(:folders, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :folders, AsyncResult.failed(socket.assigns.folders, reason))}

  def handle_async(:folders, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :folders, AsyncResult.failed(socket.assigns.folders, reason))}

  # The file is the library's once the action has stored it; picking it is what the author came for.
  defp handle_progress(:file, %{done?: true}, socket) do
    %{current_user: user, site_id: site_id} = socket.assigns
    folder = destination_id(socket.assigns)

    [result] =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        {:ok, upload(user, site_id, path, entry.client_name, folder)}
      end)

    case result do
      {:ok, %{relative_path: path}} ->
        send_update(socket.assigns.notify, id: socket.assigns.target, media: %{url: href(path)})
        {:noreply, socket |> assign(:failure, nil) |> reload()}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :failure, gettext("The file could not be added to Media Manager."))}
    end
  end

  defp handle_progress(:file, _entry, socket), do: {:noreply, socket}

  defp upload(%{site_id: nil} = user, site_id, path, name, folder) do
    Media
    |> Ash.ActionInput.for_action(
      :master_upload,
      %{
        file: Ash.Type.File.from_path(path),
        original_filename: name,
        site_id: site_id,
        media_category_id: folder
      },
      actor: user
    )
    |> Ash.run_action()
  end

  defp upload(user, site_id, path, name, folder) do
    Media
    |> Ash.ActionInput.for_action(
      :upload,
      %{file: Ash.Type.File.from_path(path), original_filename: name, media_category_id: folder},
      actor: user,
      tenant: site_id
    )
    |> Ash.run_action()
  end

  # Where an upload is filed: the folder the author chose, none, or the opener's.
  defp destination_id(%{destination: {id, _name}}), do: id
  defp destination_id(%{destination: :none}), do: nil

  defp destination_id(%{destination: :default} = assigns),
    do: folder_id(assigns.current_user, assigns.site_id, assigns.folder)

  defp destination("", _socket), do: :none
  defp destination("default", _socket), do: :default

  defp destination(id, %{assigns: %{folders: %AsyncResult{ok?: true, result: folders}}}) do
    case List.keyfind(folders, id, 0) do
      {id, path} -> {id, path}
      nil -> :default
    end
  end

  defp destination(_id, _socket), do: :default

  defp folder_chosen(socket),
    do: assign(socket, choosing_folder?: false, naming_folder?: false, folder_failure: nil)

  defp destination_label(%{destination: {_id, path}}), do: path
  defp destination_label(%{destination: :none}), do: gettext("No folder")
  defp destination_label(%{destination: :default, folder: nil}), do: gettext("No folder")
  defp destination_label(%{destination: :default, folder: name}), do: name

  # THE SITE'S FOLDERS, each by its whole path, read as the author: a master's on the record's site, a
  # site user's on their own. The first 100 by name; the rest are reached by making one.
  defp read_folders(%{site_id: nil} = user, site_id) do
    MediaCategory
    |> Ash.Query.for_read(:master_read, %{}, actor: user)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(page: [limit: @folders_shown])
    |> with_paths(user)
  end

  defp read_folders(user, site_id) do
    MediaCategory
    |> Ash.Query.for_read(:read, %{}, actor: user, tenant: site_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@folders_shown)
    |> Ash.read()
    |> with_paths(user)
  end

  defp with_paths({:ok, %{results: folders}}, user), do: with_paths({:ok, folders}, user)

  defp with_paths({:ok, folders}, user) do
    paths = folders |> Enum.map(& &1.id) |> MediaCategory.paths(actor: user)

    {:ok,
     folders |> Enum.map(&{&1.id, Map.get(paths, &1.id, &1.name)}) |> Enum.sort_by(&elem(&1, 1))}
  end

  defp with_paths({:error, _reason} = error, _user), do: error

  # THE OPENER'S FOLDER, at the top of the site's media, read as the uploader and made by them the
  # first time. One that cannot be read or made — a user who may not make folders — files the upload
  # at the top, as an upload with no folder is.
  defp folder_id(_user, _site_id, nil), do: nil

  defp folder_id(user, site_id, name) do
    case existing_folder(user, site_id, name) do
      {:ok, %{id: id}} ->
        id

      _none ->
        case new_folder(user, site_id, name) do
          {:ok, %{id: id}} -> id
          {:error, _reason} -> nil
        end
    end
  end

  defp existing_folder(%{site_id: nil} = user, site_id, name) do
    MediaCategory
    |> Ash.Query.for_read(:master_read, %{}, actor: user)
    |> Ash.Query.filter(site_id == ^site_id and name == ^name and is_nil(parent_id))
    |> Ash.read_one(page: false)
  end

  defp existing_folder(user, site_id, name) do
    MediaCategory
    |> Ash.Query.for_read(:read, %{}, actor: user, tenant: site_id)
    |> Ash.Query.filter(name == ^name and is_nil(parent_id))
    |> Ash.read_one()
  end

  defp new_folder(%{site_id: nil} = user, site_id, name),
    do:
      Ash.create(MediaCategory, %{name: name, site_id: site_id},
        action: :master_create,
        actor: user
      )

  defp new_folder(user, site_id, name),
    do: Ash.create(MediaCategory, %{name: name}, action: :create, actor: user, tenant: site_id)

  defp reload(%{assigns: %{browsing?: true}} = socket), do: load(socket)
  defp reload(socket), do: socket

  # The open folder's files and the folders inside it.
  defp load(%{assigns: %{site_id: nil}} = socket),
    do: assign(socket, library: AsyncResult.ok([]), more?: false, subfolders: AsyncResult.ok([]))

  defp load(socket) do
    %{current_user: user, site_id: site_id} = socket.assigns
    parent = open_folder_id(socket.assigns)

    socket
    |> load_files()
    |> MishkaGervaz.Messages.start_async(:subfolders, fn ->
      {parent, read_subfolders(user, site_id, parent)}
    end)
  end

  defp load_files(%{assigns: %{site_id: nil}} = socket), do: socket

  defp load_files(socket) do
    %{current_user: user, site_id: site_id, accepts: accepts, query: query} = socket.assigns
    folder = open_folder_id(socket.assigns)

    socket
    |> assign(:loading_more?, false)
    |> MishkaGervaz.Messages.start_async(:library, fn ->
      read(user, site_id, accepts, query, folder, 0)
    end)
  end

  defp open_folder_id(%{trail: []}), do: nil
  defp open_folder_id(%{trail: trail}), do: trail |> List.last() |> elem(0)

  # A page of 48 from `offset`, newest first, and whether there are more after it: every folder's at
  # the top, one folder's own inside it.
  defp read(user, site_id, accepts, query, folder, offset) do
    user
    |> library(site_id)
    |> Ash.Query.filter(type == ^accepts)
    |> in_folder(folder)
    |> named(query)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> page(user, offset)
    |> case do
      {:ok, %{results: files}} ->
        {:ok, {Enum.take(files, @shown), length(files) > @shown}}

      {:ok, files} when is_list(files) ->
        {:ok, {Enum.take(files, @shown), length(files) > @shown}}

      {:error, _reason} = error ->
        error
    end
  end

  defp library(%{site_id: nil} = user, site_id) do
    Media
    |> Ash.Query.for_read(:master_read, %{}, actor: user)
    |> Ash.Query.filter(site_id == ^site_id)
  end

  defp library(user, site_id),
    do: Ash.Query.for_read(Media, :read, %{}, actor: user, tenant: site_id)

  # A master's read pages; a site user's does not, so it is cut to the same window.
  defp page(query, %{site_id: nil}, offset),
    do: Ash.read(query, page: [limit: @shown + 1, offset: offset])

  defp page(query, _user, offset),
    do: query |> Ash.Query.limit(@shown + 1) |> Ash.Query.offset(offset) |> Ash.read()

  defp in_folder(query, nil), do: query
  defp in_folder(query, folder), do: Ash.Query.filter(query, media_category_id == ^folder)

  # THE FOLDERS DIRECTLY INSIDE `parent` — at the top for none — by name, read as `read_folders/2`
  # reads.
  defp read_subfolders(%{site_id: nil} = user, site_id, parent) do
    MediaCategory
    |> Ash.Query.for_read(:master_read, %{}, actor: user)
    |> Ash.Query.filter(site_id == ^site_id)
    |> beneath(parent)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(page: [limit: @folders_shown])
    |> named_folders()
  end

  defp read_subfolders(user, site_id, parent) do
    MediaCategory
    |> Ash.Query.for_read(:read, %{}, actor: user, tenant: site_id)
    |> beneath(parent)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(@folders_shown)
    |> Ash.read()
    |> named_folders()
  end

  defp beneath(query, nil), do: Ash.Query.filter(query, is_nil(parent_id))
  defp beneath(query, parent), do: Ash.Query.filter(query, parent_id == ^parent)

  defp named_folders({:ok, %{results: folders}}), do: named_folders({:ok, folders})
  defp named_folders({:ok, folders}), do: {:ok, Enum.map(folders, &{&1.id, &1.name})}
  defp named_folders({:error, _reason} = error), do: error

  defp named(query, ""), do: query

  defp named(query, words) do
    words = String.downcase(words)
    Ash.Query.filter(query, contains(string_downcase(name), ^words))
  end

  defp href("/" <> _rest = path), do: path
  defp href("http://" <> _rest = url), do: url
  defp href("https://" <> _rest = url), do: url
  defp href(path) when is_binary(path), do: "/" <> path
  defp href(_path), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="content-media-chooser"
      class="flex min-h-0 min-w-0 flex-1 flex-col gap-3 px-4 py-4"
    >
      <div :if={@back?} class="flex items-center gap-2">
        <button
          type="button"
          id={@id <> "-back"}
          phx-click="back"
          phx-target={@myself}
          aria-label={gettext("Back")}
          class="flex size-8 items-center justify-center rounded-[9px] text-[#5c5a54] hover:bg-[#f6f5f2]"
        >
          <.icon name="hero-chevron-left" class="size-4 rtl:rotate-180" />
        </button>
        <span class="text-[13.5px] font-bold text-[#1b1a18]">
          {(@accepts == :videos && gettext("Choose a video")) || gettext("Choose a picture")}
        </span>
      </div>

      <p
        :if={is_nil(@site_id)}
        class="rounded-[10px] bg-[#f6f5f2] px-3 py-2 text-[12px] font-medium text-[#5c5a54]"
      >
        {gettext("Pick the record's site first — files belong to a site.")}
      </p>

      <form
        :if={@site_id && !@in_form?}
        id={@id <> "-upload"}
        phx-change="upload_validate"
        phx-submit="upload_save"
        phx-target={@myself}
      >
        <.upload_zone uploads={@uploads} failure={@failure} myself={@myself} />
      </form>

      <form
        :if={@site_id && !@in_form?}
        id={@id <> "-folder-form"}
        phx-submit="create_folder"
        phx-target={@myself}
        class="hidden"
      >
      </form>

      <div :if={@site_id && @in_form?}>
        <.upload_zone uploads={@uploads} failure={@failure} myself={@myself} form={@id <> "-upload"} />
        <.portal id={@id <> "-upload-portal"} target="body">
          <form
            id={@id <> "-upload"}
            phx-change="upload_validate"
            phx-submit="upload_save"
            phx-target={@myself}
          >
          </form>
          <form id={@id <> "-folder-form"} phx-submit="create_folder" phx-target={@myself}></form>
        </.portal>
      </div>

      <.destination
        :if={@site_id}
        id={@id}
        myself={@myself}
        label={destination_label(assigns)}
        destination={@destination}
        folder={@folder}
        folders={@folders}
        choosing?={@choosing_folder?}
        naming?={@naming_folder?}
        failure={@folder_failure}
      />

      <button
        :if={@site_id && !@browsing?}
        type="button"
        id={@id <> "-browse"}
        phx-click="browse"
        phx-target={@myself}
        class="inline-flex h-9 items-center gap-1.5 self-start rounded-[10px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[12px] font-semibold text-[#4f4bcc] hover:bg-[#e9e7fb]"
      >
        <.icon name="hero-photo-mini" class="size-4" />
        {gettext("Choose from Media Manager")}
      </button>

      <.folder_browser
        :if={@site_id && @browsing?}
        id={@id}
        myself={@myself}
        trail={@trail}
        subfolders={@subfolders}
      />

      <div :if={@site_id && @browsing?} class="relative">
        <.icon
          name="hero-magnifying-glass-mini"
          class="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-[#a8a49b]"
        />
        <input
          type="search"
          id={@id <> "-query"}
          form={@id <> "-detached"}
          value={@query}
          placeholder={gettext("Search Media Manager")}
          autocomplete="off"
          phx-keyup="search"
          phx-target={@myself}
          phx-debounce="250"
          dir="auto"
          class="h-10 w-full rounded-[11px] border border-[#ecebe6] bg-[#faf9f6] pe-3 ps-9 text-[13px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white"
        />
      </div>

      <.async_result :let={files} :if={@site_id && @browsing?} assign={@library}>
        <:loading>
          <p class="text-[12px] font-medium text-[#8a877f]">{gettext("Loading Media Manager…")}</p>
        </:loading>
        <:failed>
          <p class="text-[12px] font-medium text-[#b5495f]">
            {gettext("Media Manager could not be read.")}
          </p>
        </:failed>

        <p :if={files == []} class="text-[12px] font-medium text-[#8a877f]">
          {gettext("Nothing here yet — upload the first one.")}
        </p>

        <ul class="grid min-h-0 grid-cols-3 gap-2 overflow-y-auto">
          <li :for={file <- files}>
            <button
              type="button"
              id={@id <> "-file-" <> file.id}
              data-media-url={href(file.relative_path)}
              phx-click="pick"
              phx-value-url={href(file.relative_path)}
              phx-target={@myself}
              title={file.name}
              class="group flex w-full flex-col gap-1 rounded-[10px] border border-[#ecebe6] p-1 text-start hover:border-[#c3c1f0]"
            >
              <img
                :if={@accepts == :images}
                src={href(file.relative_path)}
                alt=""
                loading="lazy"
                class="aspect-square w-full rounded-[7px] bg-[#f6f5f2] object-cover"
              />
              <span
                :if={@accepts == :videos}
                class="grid aspect-square w-full place-items-center rounded-[7px] bg-[#17161a] text-white"
              >
                <.icon name="hero-play-mini" class="size-5" />
              </span>
              <span dir="ltr" class="truncate px-0.5 text-[10.5px] font-medium text-[#5c5a54]">
                {file.name}
              </span>
            </button>
          </li>
        </ul>

        <button
          :if={@more?}
          type="button"
          id={@id <> "-more"}
          phx-click="more"
          phx-target={@myself}
          disabled={@loading_more?}
          class="inline-flex h-9 items-center justify-center gap-1.5 self-center rounded-[10px] border border-[#ecebe6] bg-white px-4 text-[12px] font-semibold text-[#3a382f] hover:bg-[#f6f5f2] disabled:cursor-wait disabled:opacity-60"
        >
          {(@loading_more? && gettext("Loading…")) || gettext("Load more")}
        </button>
      </.async_result>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :label, :string, required: true
  attr :destination, :any, required: true
  attr :folder, :string, default: nil
  attr :folders, :any, default: nil
  attr :choosing?, :boolean, default: false
  attr :naming?, :boolean, default: false
  attr :failure, :string, default: nil

  # Where an upload is filed, and the way to file it elsewhere: one of the site's folders, none, or a
  # new one named here. The controls belong to the chooser's own folder form, drawn at the end of the
  # page inside another form, so a choice or a name never reaches the form around them.
  defp destination(assigns) do
    ~H"""
    <div id={@id <> "-destination"} class="flex flex-col gap-1.5">
      <div
        :if={!@choosing?}
        class="flex flex-wrap items-center gap-1.5 text-[11.5px] font-medium text-[#8a877f]"
      >
        <.icon name="hero-folder-mini" class="size-3.5" />
        <span>{gettext("Uploads go to")}</span>
        <span id={@id <> "-destination-name"} dir="auto" class="font-semibold text-[#3a382f]">
          {@label}
        </span>
        <button
          type="button"
          id={@id <> "-change-folder"}
          phx-click="choose_folder"
          phx-target={@myself}
          class="font-semibold text-[#4f4bcc] hover:underline"
        >
          {gettext("Change")}
        </button>
      </div>

      <.async_result :let={folders} :if={@choosing?} assign={@folders}>
        <:loading>
          <p class="text-[11.5px] font-medium text-[#8a877f]">{gettext("Loading folders…")}</p>
        </:loading>
        <:failed>
          <p class="text-[11.5px] font-medium text-[#b5495f]">
            {gettext("The folders could not be read.")}
          </p>
        </:failed>

        <div class="flex flex-wrap items-center gap-1.5 text-[11.5px] font-medium text-[#8a877f]">
          <label for={@id <> "-folder"}>{gettext("Uploads go to")}</label>
          <div class="relative min-w-0 max-w-full">
            <select
              id={@id <> "-folder"}
              name="folder"
              form={@id <> "-folder-form"}
              phx-change="folder"
              phx-target={@myself}
              dir="auto"
              class="h-8 w-full min-w-0 cursor-pointer appearance-none rounded-[9px] border border-[#ecebe6] bg-[#faf9f6] ps-2.5 pe-8 text-[12px] font-semibold text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white"
            >
              <option value="" selected={@destination == :none}>{gettext("No folder")}</option>
              <option
                :if={@folder && !Enum.any?(folders, &(elem(&1, 1) == @folder))}
                value="default"
                selected={@destination == :default}
              >
                {gettext("%{name} (made on the first upload)", name: @folder)}
              </option>
              <option
                :for={{id, path} <- folders}
                value={id}
                selected={chosen?(@destination, @folder, id, path)}
              >
                {path}
              </option>
              <option value="new">{gettext("New folder…")}</option>
            </select>
            <.icon
              name="hero-chevron-down-mini"
              class="pointer-events-none absolute end-2.5 top-1/2 size-3.5 -translate-y-1/2 text-[#a8a5a0]"
            />
          </div>
          <button
            type="button"
            phx-click="cancel_folder"
            phx-target={@myself}
            class="font-semibold text-[#8a877f] hover:text-[#3a382f]"
          >
            {gettext("Done")}
          </button>
        </div>
      </.async_result>

      <div :if={@naming?} class="flex items-center gap-1.5">
        <input
          type="text"
          id={@id <> "-folder-name"}
          name="name"
          form={@id <> "-folder-form"}
          placeholder={gettext("New folder's name")}
          autocomplete="off"
          dir="auto"
          class="h-8 min-w-0 flex-1 rounded-[9px] border border-[#ecebe6] bg-[#faf9f6] px-2.5 text-[12px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] focus:bg-white"
        />
        <button
          type="submit"
          id={@id <> "-create-folder"}
          form={@id <> "-folder-form"}
          class="h-8 rounded-[9px] bg-[#f2f1fc] px-3 text-[12px] font-semibold text-[#4f4bcc] hover:bg-[#e9e7fb]"
        >
          {gettext("Create")}
        </button>
      </div>

      <p :if={@failure} class="text-[11.5px] font-medium text-[#b5495f]">{@failure}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :trail, :list, required: true
  attr :subfolders, :any, default: nil

  # Where the files listed are, as the Media page says it — All media, then each folder down to the
  # one open, any of them a way back up — and the folders inside it, each opening its own files.
  defp folder_browser(assigns) do
    ~H"""
    <div id={@id <> "-browser"} class="flex min-w-0 flex-col gap-2">
      <nav
        id={@id <> "-trail"}
        aria-label={gettext("Folder path")}
        class="flex flex-wrap items-center gap-1 rounded-[11px] border border-[#ecebe6] bg-white px-2 py-1.5 text-[12px] font-semibold"
      >
        <.icon name="hero-folder-open" class="size-4 flex-none text-[#8a877f]" />
        <button
          :if={@trail != []}
          type="button"
          id={@id <> "-trail-root"}
          phx-click="folder_up"
          phx-value-to=""
          phx-target={@myself}
          class="rounded-[7px] px-1.5 py-0.5 text-[#5c5a54] transition-colors hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
        >
          {gettext("All media")}
        </button>
        <span
          :if={@trail == []}
          id={@id <> "-trail-root"}
          aria-current="page"
          class="px-1.5 py-0.5 text-[#1b1a18]"
        >
          {gettext("All media")}
        </span>
        <%= for {{folder_id, name}, index} <- Enum.with_index(@trail) do %>
          <.icon name="hero-chevron-right" class="size-3 flex-none text-[#a8a5a0] rtl:rotate-180" />
          <button
            :if={index < length(@trail) - 1}
            type="button"
            id={@id <> "-trail-" <> folder_id}
            phx-click="folder_up"
            phx-value-to={folder_id}
            phx-target={@myself}
            dir="auto"
            class="max-w-[160px] truncate rounded-[7px] px-1.5 py-0.5 text-[#5c5a54] transition-colors hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
          >
            {name}
          </button>
          <span
            :if={index == length(@trail) - 1}
            id={@id <> "-trail-" <> folder_id}
            aria-current="page"
            dir="auto"
            class="max-w-[160px] truncate px-1.5 py-0.5 text-[#1b1a18]"
          >
            {name}
          </span>
        <% end %>
      </nav>

      <.async_result :let={folders} :if={@subfolders} assign={@subfolders}>
        <:loading>
          <p class="text-[11.5px] font-medium text-[#8a877f]">{gettext("Loading folders…")}</p>
        </:loading>
        <:failed>
          <p class="text-[11.5px] font-medium text-[#b5495f]">
            {gettext("The folders could not be read.")}
          </p>
        </:failed>

        <ul
          :if={folders != []}
          id={@id <> "-folders"}
          class="flex min-w-0 gap-1.5 overflow-x-auto pb-1"
        >
          <li :for={{folder_id, name} <- folders} class="flex-none">
            <button
              type="button"
              id={@id <> "-open-" <> folder_id}
              phx-click="open_folder"
              phx-value-id={folder_id}
              phx-target={@myself}
              dir="auto"
              class="flex items-center gap-1.5 whitespace-nowrap rounded-[10px] border border-[#eceae4] bg-[#faf9f6] px-3 py-[7px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"
            >
              <.icon name="hero-folder" class="size-[15px] flex-none text-[#8a877f]" />
              {name}
            </button>
          </li>
        </ul>
      </.async_result>
    </div>
    """
  end

  defp chosen?({id, _path}, _folder, id, _path_shown), do: true
  defp chosen?(:default, folder, _id, path), do: folder == path
  defp chosen?(_destination, _folder, _id, _path), do: false

  attr :uploads, :map, required: true
  attr :failure, :string, default: nil
  attr :myself, :any, required: true
  attr :form, :string, default: nil

  # Where a file is dropped or picked, its progress and what went wrong. Inside another form the
  # upload's own form is drawn at the end of the page — a form inside a form is dropped by the
  # browser, and the file went to the outer one — and the input names it (`form`).
  defp upload_zone(assigns) do
    ~H"""
    <label
      for={@uploads.file.ref}
      phx-drop-target={@uploads.file.ref}
      class="flex cursor-pointer items-center justify-center gap-2 rounded-[12px] border border-dashed border-[#c3c1f0] bg-[#faf9ff] px-3 py-3 text-[12.5px] font-semibold text-[#4f4bcc] hover:bg-[#f2f1fc]"
    >
      <.icon name="hero-arrow-up-tray-mini" class="size-4" />
      {gettext("Upload a file, or drop it here")}
    </label>
    <.live_file_input upload={@uploads.file} form={@form} class="sr-only" />

    <div
      :for={entry <- @uploads.file.entries}
      class="mt-2 flex items-center gap-2 text-[11.5px] font-medium text-[#5c5a54]"
    >
      <span class="min-w-0 flex-1 truncate" dir="ltr">{entry.client_name}</span>
      <span>{entry.progress}%</span>
      <button
        type="button"
        phx-click="upload_cancel"
        phx-value-ref={entry.ref}
        phx-target={@myself}
        aria-label={gettext("Cancel")}
        class="text-[#8a877f] hover:text-[#b5495f]"
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>

    <p
      :for={error <- upload_errors(@uploads.file)}
      class="mt-2 text-[11.5px] font-medium text-[#b5495f]"
    >
      {upload_error(error)}
    </p>
    <p :if={@failure} class="mt-2 text-[11.5px] font-medium text-[#b5495f]">{@failure}</p>
    """
  end

  defp upload_error(:too_large), do: gettext("The file is larger than 50 MB.")
  defp upload_error(:not_accepted), do: gettext("This kind of file cannot be used here.")
  defp upload_error(:too_many_files), do: gettext("Add one file at a time.")
  defp upload_error(_error), do: gettext("The file could not be uploaded.")
end
