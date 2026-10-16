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

  ## What a consumed file is named

  Never what the visitor called it. The stored name is a random id plus an extension taken from the
  entry's declared MIME type, and the client's own name rides the descriptor as metadata. A filename
  is visitor input that becomes a path, which is the shape of every traversal bug ever written; not
  using it at all is shorter than escaping it correctly.

  Files land under the page's own site, `priv/static/uploads/<site_id>/forms/`, which the endpoint
  serves while that site is up, so the descriptor's `url` is a link that works and follows the site's
  state. A page with no site stores nothing.

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

  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  @entries_ceiling 10
  @file_size_ceiling 20_000_000
  @default_entries 1
  @default_file_size 8_000_000

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
  kind it declared.
  """
  @spec consume(Phoenix.LiveView.Socket.t(), map()) :: {Phoenix.LiveView.Socket.t(), map()}
  def consume(socket, params) when is_map(params) do
    case registered(socket) do
      [] -> {socket, params}
      names -> Enum.reduce(names, {socket, params}, &consume_one/2)
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

  Exposed because the compiler is not the only caller that has to agree with the ceilings — a test
  that asserts them reads them from here rather than restating the numbers.
  """
  @spec options(map()) :: keyword()
  def options(declaration) do
    [
      accept: accept(declaration[:accept]),
      max_entries: bounded(declaration[:max_entries], @default_entries, @entries_ceiling),
      max_file_size: bounded(declaration[:max_file_size], @default_file_size, @file_size_ceiling),
      auto_upload: declaration[:auto_upload] == true
    ]
  end

  @doc "The most files and the largest file a declaration can ask for, whatever it says."
  @spec ceilings() :: %{entries: pos_integer(), file_size: pos_integer()}
  def ceilings, do: %{entries: @entries_ceiling, file_size: @file_size_ceiling}

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
    case Map.has_key?(socket.assigns[:uploads] || %{}, name) do
      true -> socket
      false -> Phoenix.LiveView.allow_upload(socket, name, options(declaration))
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

    for %{name: name} <- declarations(socket.assigns[:page_module]),
        is_atom(name),
        Map.has_key?(uploads, name),
        do: name
  end

  defp consume_one(name, {socket, params}) do
    site_id = site_id(socket)
    descriptors = Phoenix.LiveView.consume_uploaded_entries(socket, name, &store(&1, &2, site_id))

    case Enum.reject(descriptors, &is_nil/1) do
      [] -> {socket, params}
      stored -> {socket, Map.put(params, to_string(name), stored)}
    end
  end

  defp site_id(socket) do
    case socket.assigns[:current_site] do
      %{id: site_id} when is_binary(site_id) -> site_id
      _no_site -> nil
    end
  end

  defp store(_file, entry, nil) do
    Logger.error(
      "[PageUpload] #{inspect(entry.client_name)} was not stored: the page has no site"
    )

    {:ok, nil}
  end

  # `File.cp!/2` and not `File.rename/2`: LiveView's temporary file may be on a different filesystem
  # from `priv/`, where a rename answers `{:error, :exxdev}` and the visitor is told the upload
  # failed for a reason nobody can act on. LiveView removes the temporary file itself once this
  # returns.
  defp store(%{path: path}, entry, site_id) do
    directory = directory(site_id)
    File.mkdir_p!(directory)
    stored = stored_name(entry)

    case File.cp(path, Path.join(directory, stored)) do
      :ok ->
        {:ok,
         %{
           "url" => "/uploads/#{site_id}/forms/#{stored}",
           "name" => entry.client_name,
           "type" => entry.client_type,
           "size" => entry.client_size
         }}

      {:error, reason} ->
        Logger.error(
          "[PageUpload] could not store #{inspect(entry.client_name)}: #{inspect(reason)}"
        )

        {:ok, nil}
    end
  end

  # THE CLIENT'S NAME IS NEVER PART OF THE PATH. It is visitor input that would become a filename,
  # which is where `../../etc/passwd` gets in — and sanitising it correctly is longer than not using
  # it. The extension comes from the entry's declared type, through a map, so nothing a visitor sends
  # reaches the filesystem as text at all.
  defp stored_name(entry) do
    id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case extension(entry.client_type) do
      nil -> id
      ext -> id <> ext
    end
  end

  defp extension(type) when is_binary(type) do
    case MIME.extensions(type) do
      [ext | _rest] -> "." <> ext
      [] -> nil
    end
  end

  defp extension(_type), do: nil

  defp accept(nil), do: :any
  defp accept(""), do: :any

  defp accept(list) when is_list(list), do: list

  defp accept(accept) when is_binary(accept) do
    accept
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :any
      parts -> parts
    end
  end

  defp accept(_accept), do: :any

  defp bounded(asked, _fallback, ceiling) when is_integer(asked) and asked > 0,
    do: min(asked, ceiling)

  defp bounded(_asked, fallback, _ceiling), do: fallback
end
