# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageUpload do
  @moduledoc """
  Live file uploads on a published page, from a declaration an author writes rather than Elixir.

  ## The gap this closes

  `allow_upload/3` is a `Phoenix.LiveView` function and there was nowhere to call it: a compiled page
  is a LiveView but the compiler emitted no `mount/3`, so `@uploads` never existed and the one
  capability the UI kit already shipped and could not use — `chelekom-file-field`'s live mode, which
  renders `<.live_file_input upload={@upload}>` — had nothing to be given. A live component cannot
  supply it either: `allow_upload/3` is not a `Phoenix.LiveComponent` function.

  So the page declares its uploads, and this attaches them.

      # Page.uploads
      [%{"name" => "attachment", "accept" => "image/*,.pdf", "max_entries" => 2}]

      <.component component_name="chelekom-file-field" live upload={@uploads.attachment} />

  ## The ceilings are not the author's to raise

  A published page is a form an anonymous visitor posts to, so the numbers a declaration carries are
  read as requests and clamped: at most ten files of at most 20 MB each. An author who writes
  `max_file_size: 2_000_000_000` gets the ceiling, not an argument — and not a way to fill a disk
  from a page anybody can open.

  ## What a visitor may upload

  A declaration must say what it takes: `accept` is required, and a declaration without a usable one
  is not compiled. `image/*`, `application/pdf` and `.csv` are read against `allowed_types/0`, the
  one list of extensions a visitor can send — images, PDF, plain text and CSV, office and OpenDocument
  files, and zip. Everything else is dropped from the declaration, and HTML, SVG, XML and script
  files can never be on it: the endpoint serves what is stored from the site's own origin, where such
  a file would run with the session of whoever opens its link.

  The type a browser reports is a claim, so it is not believed. A file is stored only when its first
  bytes are one of the kinds the declaration takes — see `MishkaCmsCore.Runtime.FileSignature` — and
  a file that is not, whatever it is called, is left unstored.

  ## What a consumed file is named

  Never what the visitor called it. The stored name is a random id plus an extension taken from the
  kind of the file's own first bytes, and the client's own name rides the descriptor as metadata. A
  filename is visitor input that becomes a path, which is the shape of every traversal bug ever
  written; not using it at all is shorter than escaping it correctly.

  Files land under the page's own site, `priv/static/uploads/<site_id>/forms/`, which the endpoint
  serves while that site is up, so the descriptor's `url` is a link that works and follows the site's
  state. A page with no site stores nothing.

  ## How a stored file is served

  `static_headers/0` names the headers a stored file is served with: a download, never sniffed into
  another type, and sandboxed. `MishkaCmsCore.Runtime.ShareCard.static_headers/1` is the `Plug.Static`
  hook that adds them to every file under `/uploads/<site_id>/forms/`.

  ## Who calls what

  `MishkaCmsWeb.RuntimeLive` registers them at mount, because it is the LiveView — a compiled page
  module supplies `render/1` and `handle_event/3` to it rather than being one of its own.

  ## Where consumption happens

  `MishkaCmsCore.Runtime.PageForm.submit/5`, before the values are validated — so a form rule can
  require the field, and an author's own `run` function receives the descriptors with everything
  else. Consuming is what completes an upload in LiveView; a page that never consumes leaves the
  entry in the socket and the temporary file on disk.
  """

  require Logger

  alias MishkaCmsCore.Runtime.FileSignature

  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  @entries_ceiling 10
  @file_size_ceiling 20_000_000
  @default_entries 1
  @default_file_size 8_000_000

  @allowed ~w(png jpg jpeg gif webp pdf txt csv doc docx xls xlsx ppt pptx odt ods zip)

  @doc """
  Registers one `allow_upload/3` per declaration the page module carries.

  Called by whatever mounts a compiled page — `MishkaCmsWeb.RuntimeLive` for a published one — after
  the module is compiled and before the first render. Returns the socket untouched for a page that
  declares nothing, which is every page that does not ask for uploads.

  It is the MOUNTING LiveView that has to call this, and that is not a detail: a compiled page module
  supplies `render/1` and `handle_event/3` to a host LiveView rather than being one, so a hook
  attached to the page module would never run and `@uploads` would never exist. A generated `mount/3`
  on it would be dead code for the same reason.
  """
  @spec allow(Phoenix.LiveView.Socket.t(), module() | nil) :: Phoenix.LiveView.Socket.t()
  def allow(socket, page_module) do
    page_module
    |> declarations()
    |> Enum.reduce(socket, &register(&2, &1))
  end

  @doc """
  Consumes every completed entry on the socket and merges the descriptors into `params`.

  Answers `{socket, params}` untouched when the page registered no uploads, so every page that does
  not use this pays one map lookup for it.

  Each declared name gains a list of descriptors:

      %{"url" => "/uploads/…", "name" => "invoice.pdf", "type" => "application/pdf", "size" => 8112}

  A list even for a single-entry upload, so a rule reading the field does not have to know which
  kind it declared. `type` is the type of the file that was stored, read from its first bytes.

  An entry whose first bytes are none of the kinds its declaration takes is consumed and not
  stored, so it has no descriptor.
  """
  @spec consume(Phoenix.LiveView.Socket.t(), map()) :: {Phoenix.LiveView.Socket.t(), map()}
  def consume(socket, params) when is_map(params) do
    case registered(socket) do
      [] -> {socket, params}
      declarations -> Enum.reduce(declarations, {socket, params}, &consume_one/2)
    end
  end

  def consume(socket, params), do: {socket, params}

  @doc """
  What a page declared, as the compiler wrote it onto the module.

  `[]` for anything that is not a compiled page — a preview, the canvas, a LiveView of the admin's
  own — so the hook is inert wherever it does not apply.
  """
  @spec declarations(module() | nil) :: [map()]
  def declarations(module) when is_atom(module) and not is_nil(module) do
    case function_exported?(module, :__page_uploads__, 0) do
      true -> module.__page_uploads__()
      false -> []
    end
  end

  def declarations(_module), do: []

  @doc """
  The `allow_upload/3` options one declaration asks for, clamped to what a public page may have.

  `:accept` is the declaration's `accept` read against `allowed_types/0`, as dotted extensions; `[]`
  when nothing in it can be uploaded, which `allow/2` leaves unregistered.

  Exposed because the compiler is not the only caller that has to agree with the ceilings — a test
  that asserts them reads them from here rather than restating the numbers.
  """
  @spec options(map()) :: keyword()
  def options(declaration) do
    [
      accept: Enum.map(allowed_extensions(declaration[:accept]), &("." <> &1)),
      max_entries: bounded(declaration[:max_entries], @default_entries, @entries_ceiling),
      max_file_size: bounded(declaration[:max_file_size], @default_file_size, @file_size_ceiling),
      auto_upload: declaration[:auto_upload] == true
    ]
  end

  @doc "The most files and the largest file a declaration can ask for, whatever it says."
  @spec ceilings() :: %{entries: pos_integer(), file_size: pos_integer()}
  def ceilings, do: %{entries: @entries_ceiling, file_size: @file_size_ceiling}

  @doc """
  The extensions, without a dot, a visitor may upload: the only ones an `accept` can name.
  """
  @spec allowed_types() :: [String.t()]
  def allowed_types, do: @allowed

  @doc """
  The extensions an `accept` leaves a visitor to upload, in the order of `allowed_types/0`.

  `accept` is what a declaration writes — `"image/*, .pdf"`, or a list of those words — and a word
  is an extension (`.pdf`), a type (`application/pdf`) or a group of types (`image/*`). `[]` for an
  `accept` that is missing, blank or names nothing a visitor may upload.
  """
  @spec allowed_extensions(term()) :: [String.t()]
  def allowed_extensions(accept) do
    found = accept |> words() |> Enum.flat_map(&extensions/1)
    Enum.filter(@allowed, &(&1 in found))
  end

  @doc """
  The words of an `accept` that name nothing a visitor may upload: `.svg`, `text/html`, `*/*`.
  """
  @spec unsupported(term()) :: [String.t()]
  def unsupported(accept), do: accept |> words() |> Enum.filter(&(extensions(&1) == []))

  @doc """
  The headers a file stored for a visitor is served with: saved rather than shown, never sniffed into
  another type, and sandboxed in case a browser shows it anyway.
  """
  @spec static_headers() :: %{String.t() => String.t()}
  def static_headers do
    %{
      "content-disposition" => "attachment",
      "x-content-type-options" => "nosniff",
      "content-security-policy" => "sandbox"
    }
  end

  @doc """
  Where a site's consumed files are written: `<site_id>/forms/` under `priv/static/uploads/`, which
  the endpoint serves while that site is up.
  """
  @spec directory(String.t()) :: String.t()
  def directory(site_id) do
    base = Application.get_env(:mishka_cms_core, :page_upload_dir) || host_directory()
    Path.join([base, site_id, "forms"])
  end

  defp host_directory do
    case :code.priv_dir(@host_app) do
      {:error, _unnamed} -> Path.join(["priv", "static", "uploads"])
      priv -> Path.join([priv, "static", "uploads"])
    end
  end

  defp register(socket, %{name: name} = declaration) when is_atom(name) do
    options = options(declaration)

    cond do
      Map.has_key?(socket.assigns[:uploads] || %{}, name) ->
        socket

      options[:accept] == [] ->
        Logger.warning(
          "[PageUpload] #{name} was not registered: its accept names no type a visitor may upload"
        )

        socket

      true ->
        Phoenix.LiveView.allow_upload(socket, name, options)
    end
  end

  defp register(socket, _declaration), do: socket

  # ASKED OF THE PAGE, NOT OF `socket.assigns.uploads`. That map is not a list of upload names:
  # LiveView keeps `:__phoenix_refs_to_names__` in it beside the configs, and walking its atom keys
  # handed `consume_uploaded_entries/3` that bookkeeping map instead of an `UploadConfig` —
  # `key :entries not found`, inside the visitor's submit. The page's own declarations are the list;
  # the assigns are only asked whether each one was actually registered.
  #
  # `:page_module` and not `socket.view`, for the same reason `allow/2` takes a module: the view is
  # the host LiveView, and the declarations belong to the page it is drawing.
  defp registered(socket) do
    uploads = socket.assigns[:uploads] || %{}

    for %{name: name} = declaration <- declarations(socket.assigns[:page_module]),
        is_atom(name),
        Map.has_key?(uploads, name),
        do: declaration
  end

  # AN ENTRY LIVEVIEW REFUSED — too big, or a type the declaration does not take — never completes,
  # and `consume_uploaded_entries/3` raises while any entry is unfinished, which ended the visitor's
  # LiveView on submit. A refused entry is dropped here; one still uploading is left for the next
  # submit, so what is consumed is only ever what finished.
  defp consume_one(%{name: name} = declaration, {socket, params}) do
    socket = cancel_refused(socket, name)

    case Phoenix.LiveView.uploaded_entries(socket, name) do
      {_done, [_ | _unfinished]} -> {socket, params}
      {_done, []} -> consume_done(declaration, socket, params)
    end
  end

  defp consume_done(%{name: name} = declaration, socket, params) do
    site_id = site_id(socket)
    allowed = allowed_extensions(declaration[:accept])

    descriptors =
      Phoenix.LiveView.consume_uploaded_entries(socket, name, &store(&1, &2, site_id, allowed))

    case Enum.reject(descriptors, &is_nil/1) do
      [] -> {socket, params}
      stored -> {socket, Map.put(params, to_string(name), stored)}
    end
  end

  defp cancel_refused(socket, name) do
    socket.assigns.uploads[name].entries
    |> Enum.reject(& &1.valid?)
    |> Enum.reduce(socket, &Phoenix.LiveView.cancel_upload(&2, name, &1.ref))
  end

  defp site_id(socket) do
    case socket.assigns[:current_site] do
      %{id: site_id} when is_binary(site_id) -> site_id
      _no_site -> nil
    end
  end

  defp store(_file, entry, nil, _allowed) do
    Logger.error(
      "[PageUpload] #{inspect(entry.client_name)} was not stored: the page has no site"
    )

    {:ok, nil}
  end

  # `File.cp/2` and not `File.rename/2`: LiveView's temporary file may be on a different filesystem
  # from `priv/`, where a rename answers `{:error, :exxdev}` and the visitor is told the upload
  # failed for a reason nobody can act on. LiveView removes the temporary file itself once this
  # returns.
  defp store(%{path: path}, entry, site_id, allowed) do
    case stored_extension(path, entry, allowed) do
      {:ok, extension} -> copy(path, entry, site_id, extension)
      :error -> refuse(entry)
    end
  end

  defp copy(path, entry, site_id, extension) do
    directory = directory(site_id)
    stored = random_name() <> "." <> extension

    with :ok <- File.mkdir_p(directory),
         :ok <- File.cp(path, Path.join(directory, stored)) do
      {:ok,
       %{
         "url" => "/uploads/#{site_id}/forms/#{stored}",
         "name" => entry.client_name,
         "type" => MIME.type(extension),
         "size" => entry.client_size
       }}
    else
      {:error, reason} ->
        Logger.error(
          "[PageUpload] could not store #{inspect(entry.client_name)}: #{inspect(reason)}"
        )

        {:ok, nil}
    end
  end

  defp refuse(entry) do
    Logger.warning(
      "[PageUpload] #{inspect(entry.client_name)} was not stored: " <>
        "its content is none of the types this upload takes"
    )

    {:ok, nil}
  end

  # THE FILE DECIDES ITS OWN EXTENSION. The client's type and name are claims, so the first bytes
  # are read and the file is stored only as a kind the declaration takes. When the name's own
  # extension is one of that kind's — `.jpeg` for a JPEG — it is kept; otherwise the first one the
  # declaration allows for the kind is used. The extension is always one of `allowed_types/0`, so
  # nothing a visitor sends reaches the filesystem as text.
  defp stored_extension(path, entry, allowed) do
    with {:ok, kind} <- FileSignature.sniff(path),
         [first | _rest] = candidates <- Enum.filter(allowed, &(FileSignature.kind(&1) == kind)) do
      claimed =
        entry.client_name |> Path.extname() |> String.trim_leading(".") |> String.downcase()

      {:ok, (claimed in candidates && claimed) || first}
    else
      _refused -> :error
    end
  end

  defp random_name, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp words(nil), do: []
  defp words(accept) when is_list(accept), do: Enum.flat_map(accept, &words/1)

  defp words(accept) when is_binary(accept) do
    accept
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp words(_accept), do: []

  defp extensions("." <> extension), do: Enum.filter([extension], &(&1 in @allowed))

  defp extensions(word) do
    case String.split(word, "/") do
      [group, "*"] -> Enum.filter(@allowed, &String.starts_with?(MIME.type(&1), group <> "/"))
      [_group, _subtype] -> Enum.filter(MIME.extensions(word), &(&1 in @allowed))
      _not_a_type -> []
    end
  end

  defp bounded(asked, _fallback, ceiling) when is_integer(asked) and asked > 0,
    do: min(asked, ceiling)

  defp bounded(_asked, fallback, _ceiling), do: fallback
end
