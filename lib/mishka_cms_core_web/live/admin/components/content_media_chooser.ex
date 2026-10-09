defmodule MishkaCmsCoreWeb.Live.Admin.Components.ContentMediaChooser do
  @moduledoc """
  The media library inside the content editor's settings
  (`MishkaCmsCoreWeb.Live.Admin.Components.ContentComponentPicker`): the pictures, or the videos,
  of the site the record is on, newest first and searchable by name, and an upload that adds a
  file to that library and picks it.

  A pick goes back to the settings that opened this as
  `send_update(ContentComponentPicker, id: target, media: %{url: url})`, and Back as
  `media: :closed` — or to the component `notify` names, a form's picture field
  (`MishkaCmsCoreWeb.Live.Admin.Components.MediaField`). The library is read as the signed-in user —
  a master's on the record's site, a site user's on their own — and an upload is the `Media`
  resource's own `upload` (or `master_upload`) action, so its checks are the library's.

  Given a `folder` name, an upload is filed in the folder of that name at the top of the site's
  library, made on the first upload. `library: :closed` shows the upload alone, and the library
  only once it is asked for; `back: false` leaves out Back; `in_form: true` is for a library drawn
  inside another form, whose upload must not be a form inside it.

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

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       library: AsyncResult.loading(),
       failure: nil,
       notify: ContentComponentPicker,
       folder: nil,
       back?: true,
       in_form?: false,
       browsing?: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
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

  # Whether the library is shown: as the opener asks the first time, then as the author leaves it.
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
    do: {:noreply, socket |> assign(:query, String.trim(query)) |> load()}

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

  def handle_event("upload_validate", _params, socket), do: {:noreply, socket}
  def handle_event("upload_save", _params, socket), do: {:noreply, socket}

  def handle_event("upload_cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  @impl true
  def handle_async(:library, {:ok, {:ok, files}}, socket),
    do: {:noreply, assign(socket, :library, AsyncResult.ok(files))}

  def handle_async(:library, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :library, AsyncResult.failed(socket.assigns.library, reason))}

  def handle_async(:library, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :library, AsyncResult.failed(socket.assigns.library, reason))}

  # The file is the library's once the action has stored it; picking it is what the author came for.
  defp handle_progress(:file, %{done?: true}, socket) do
    %{current_user: user, site_id: site_id} = socket.assigns
    folder = folder_id(user, site_id, socket.assigns.folder)

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
         assign(socket, :failure, gettext("The file could not be added to the library."))}
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

  # THE FOLDER UPLOADS ARE FILED IN, at the top of the site's library, read as the uploader and made
  # by them the first time. One that cannot be read or made — a user who may not make folders — files
  # the upload at the top, as an upload with no folder is.
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

  defp load(%{assigns: %{site_id: nil}} = socket),
    do: assign(socket, :library, AsyncResult.ok([]))

  defp load(socket) do
    %{current_user: user, site_id: site_id, accepts: accepts, query: query} = socket.assigns

    MishkaGervaz.Messages.start_async(socket, :library, fn ->
      read(user, site_id, accepts, query)
    end)
  end

  defp read(user, site_id, accepts, query) do
    user
    |> library(site_id)
    |> Ash.Query.filter(type == ^accepts)
    |> named(query)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@shown)
    |> Ash.read(pages(user))
    |> case do
      {:ok, %{results: files}} -> {:ok, files}
      {:ok, files} when is_list(files) -> {:ok, files}
      {:error, _reason} = error -> error
    end
  end

  defp library(%{site_id: nil} = user, site_id) do
    Media
    |> Ash.Query.for_read(:master_read, %{}, actor: user)
    |> Ash.Query.filter(site_id == ^site_id)
  end

  defp library(user, site_id),
    do: Ash.Query.for_read(Media, :read, %{}, actor: user, tenant: site_id)

  # A master's read pages, twenty at a time unless asked; a site user's does not page.
  defp pages(%{site_id: nil}), do: [page: [limit: @shown]]
  defp pages(_user), do: []

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
      class="flex min-h-0 flex-1 flex-col gap-3 px-4 py-4"
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
        </.portal>
      </div>

      <button
        :if={@site_id && !@browsing?}
        type="button"
        id={@id <> "-browse"}
        phx-click="browse"
        phx-target={@myself}
        class="inline-flex h-9 items-center gap-1.5 self-start rounded-[10px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[12px] font-semibold text-[#4f4bcc] hover:bg-[#e9e7fb]"
      >
        <.icon name="hero-photo-mini" class="size-4" />
        {gettext("Choose from the library")}
      </button>

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
          placeholder={gettext("Search the library")}
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
          <p class="text-[12px] font-medium text-[#8a877f]">{gettext("Loading the library…")}</p>
        </:loading>
        <:failed>
          <p class="text-[12px] font-medium text-[#b5495f]">
            {gettext("The library could not be read.")}
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
      </.async_result>
    </div>
    """
  end

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
