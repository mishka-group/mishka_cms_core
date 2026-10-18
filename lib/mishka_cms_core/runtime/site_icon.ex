# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteIcon do
  @moduledoc """
  A site's icons and its web manifest, each its own, answered on the site's own address
  (`MishkaCmsCoreWeb.SeoController`):

    * `/favicon.ico` — the file the `site.favicon` setting names (`favicon/1`);
    * `/apple-touch-icon.png` and `/apple-touch-icon-precomposed.png` — 180×180, the icon a phone
      puts on its home screen;
    * `/site-icon-192.png` and `/site-icon-512.png` — the icons of the manifest;
    * `/site.webmanifest` — what a browser installs the site with (`manifest/1`).

  ## What the icons are drawn from

  The site's `site.app_icon` setting, else its `site.favicon` — the first that names a picture of
  the site's own (`MishkaCmsCore.Runtime.ShareCard.site_file/2`): a file of its media or under the
  host's static folder that is a PNG, JPEG, WebP, GIF or SVG (`source/1`). An `http(s)://`
  address is never fetched, so a site whose pictures are elsewhere has no icons but its favicon
  link. Each icon is the picture fitted whole in its square and centered on transparency, never
  stretched (`MishkaCmsCore.Runtime.ShareCard.squares/2`).

  ## When they are drawn

  On the first request for one: every size at once, by libvips in a separate process, as a share
  card is drawn. A site draws one at a time; the requests that come meanwhile wait for it and send
  what it drew. The files are stored at `/uploads/<site_id>/icons/<hash>-<size>.png`, `hash` named
  by the picture's bytes, and every later request sends the file. A picture libvips cannot draw is
  not tried again until the setting or the file changes. Drawing them fires
  `"runtime:site:after_icons"` with `%{site_id:, hash:, files: %{size => path}}`; a site's
  older icons are deleted then.

  ## What a page reads

  Which files the favicon and the picture are, and the picture's hash, are kept in ETS
  (`MishkaCmsCore.Runtime.States.AssetsState`, under `{site_id, "site_icon"}`) beside the values of
  the two settings they were read for. The head of every page reads them from there
  (`url/2`, `manifest_url/1`); a setting that holds another value — on any node — has the files
  read again. A media file replaced in place is caught by `MishkaCmsCore.Runtime.MediaSiteIcons`,
  and saving either setting by `MishkaCmsCore.Runtime.SettingSiteIcons`: both `forget/1` it.

  ## The manifest

  `name` and `short_name` are the site's name in its primary language
  (`MishkaCmsCore.Runtime.Seo.site_name/2`), `start_url` is `/`, `display` is `browser` and `icons`
  are the 192×192 and 512×512 PNGs. A plugin on `"runtime:site:manifest"` is handed
  `%{site: site, manifest: manifest}` and returns the map with its `manifest`: a `theme_color`, a
  `background_color`, another `display`.

      SiteIcon.url(site.id, 180) #=> "/apple-touch-icon.png?v=4be1f0a3c2d9e8b7"
  """

  require Logger

  alias MishkaCmsCore.Runtime.{Languages, Media, Seo, ShareCard}
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook

  # Raise it when how an icon is drawn changes: every icon is drawn again under a new name.
  @version 1

  @apple_touch 180
  @manifest_sizes [192, 512]
  @sizes [@apple_touch | @manifest_sizes]

  @settings ~w(site.app_icon site.favicon)
  @entry "site_icon"

  # The types a picture the icons are drawn from may be: what `ShareCard.squares/2` reads.
  @drawable ~w(image/png image/jpeg image/webp image/gif image/svg+xml)

  @manifest_event "runtime:site:manifest"
  @drawn_event "runtime:site:after_icons"

  @typedoc "A file of the site's own: where it is on disk and its type, read off its first bytes."
  @type file :: %{path: Path.t(), type: String.t()}

  @typedoc "The picture the icons are drawn from, and the hash their names carry."
  @type source :: %{path: Path.t(), type: String.t(), hash: String.t(), failed?: boolean()}

  @doc "The settings the icons are read from: `#{inspect(@settings)}`."
  @spec settings() :: [String.t()]
  def settings, do: @settings

  @doc "Every size an icon is drawn at, in pixels: `#{inspect(@sizes)}`."
  @spec sizes() :: [pos_integer()]
  def sizes, do: @sizes

  @doc "The event a plugin changes a site's manifest on: `\"#{@manifest_event}\"`."
  @spec manifest_event() :: String.t()
  def manifest_event, do: @manifest_event

  @doc "The event fired after a site's icons are drawn: `\"#{@drawn_event}\"`."
  @spec drawn_event() :: String.t()
  def drawn_event, do: @drawn_event

  @doc """
  The site's favicon as a file of its own: `%{path:, type:}`, `type` one of
  `MishkaCmsCore.Runtime.ShareCard.picture_type/1`'s. `nil` for no favicon, and for one that is an
  address elsewhere or a file the site does not own.
  """
  @spec favicon(String.t() | nil) :: file() | nil
  def favicon(site_id) when is_binary(site_id), do: entry(site_id).favicon
  def favicon(_no_site), do: nil

  @doc """
  The picture the site's icons are drawn from: its app icon, else its favicon, when it is a
  drawable file of its own. `nil` when neither is.
  """
  @spec source(String.t() | nil) :: source() | nil
  def source(site_id) when is_binary(site_id), do: entry(site_id).source
  def source(_no_site), do: nil

  @doc """
  The address the site's icon of `size` is served at, with the hash of the picture it is drawn
  from: `"/apple-touch-icon.png?v=…"` for 180, `"/site-icon-192.png?v=…"`. `nil` for a site with
  no picture to draw it from.
  """
  @spec url(String.t() | nil, pos_integer()) :: String.t() | nil
  def url(site_id, size) when size in @sizes do
    case source(site_id) do
      %{hash: hash} -> path(size) <> "?v=" <> hash
      nil -> nil
    end
  end

  @doc "The site's `/site.webmanifest`, for a site with icons; `nil` for one with none."
  @spec manifest_url(String.t() | nil) :: String.t() | nil
  def manifest_url(site_id) do
    case source(site_id) do
      %{hash: _hash} -> "/site.webmanifest"
      nil -> nil
    end
  end

  @doc "The path the icon of `size` is served at, with no hash."
  @spec path(pos_integer()) :: String.t()
  def path(@apple_touch), do: "/apple-touch-icon.png"
  def path(size) when size in @manifest_sizes, do: "/site-icon-#{size}.png"

  @doc """
  The site's web manifest: `%{"name", "short_name", "start_url", "display", "icons"}` as a plugin
  on `manifest_event/0` leaves it, with string keys, ready to be encoded. `nil` for a site with no
  icons.
  """
  @spec manifest(%{id: String.t()}) :: map() | nil
  def manifest(%{id: site_id} = site) when is_binary(site_id) do
    case source(site_id) do
      %{hash: _hash} -> site |> own_manifest() |> through_plugins(site)
      nil -> nil
    end
  end

  defp own_manifest(%{id: site_id}) do
    name = Seo.site_name(site_id, Languages.primary(site_id))

    icons =
      for size <- @manifest_sizes,
          do: %{"src" => url(site_id, size), "sizes" => "#{size}x#{size}", "type" => "image/png"}

    %{
      "name" => name,
      "short_name" => name,
      "start_url" => "/",
      "display" => "browser",
      "icons" => icons
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp through_plugins(manifest, site) do
    case Hook.call(@manifest_event, %{site: site, manifest: manifest}) do
      %{manifest: %{} = changed} -> changed
      _refused -> manifest
    end
  end

  @doc """
  The PNG of the site's icon of `size` on disk, drawn now when it is not there yet:
  `{:ok, %{path:, hash:}}`, `hash` the one its address carries (`url/2`). `:error` for a site with
  no picture to draw it from, and for a picture libvips could not draw.
  """
  @spec file(String.t() | nil, pos_integer()) ::
          {:ok, %{path: Path.t(), hash: String.t()}} | :error
  def file(site_id, size) when is_binary(site_id) and size in @sizes do
    case source(site_id) do
      %{failed?: true} -> :error
      %{hash: hash} = source -> drawn(site_id, source, disk_path(site_id, hash, size))
      nil -> :error
    end
  end

  def file(_no_site, _size), do: :error

  defp drawn(site_id, %{hash: hash} = source, path) do
    case File.regular?(path) do
      true ->
        {:ok, %{path: path, hash: hash}}

      false ->
        :global.trans(
          {{__MODULE__, site_id, hash}, self()},
          fn -> draw_once(site_id, source, path) end,
          [node()]
        )
    end
  end

  # Asked again inside the lock: whoever held it was drawing these very icons.
  defp draw_once(site_id, %{hash: hash} = source, path) do
    cond do
      File.regular?(path) -> {:ok, %{path: path, hash: hash}}
      failed?(site_id, hash) -> :error
      draw(site_id, source) == :ok -> {:ok, %{path: path, hash: hash}}
      true -> :error
    end
  end

  defp draw(site_id, %{path: picture, hash: hash}) do
    folder = dir(site_id)

    with {:ok, pngs} <- ShareCard.squares(picture, @sizes),
         :ok <- File.mkdir_p(folder),
         {:ok, files} <- write(site_id, hash, pngs) do
      sweep(folder, hash)

      Hook.call(@drawn_event, %{site_id: site_id, hash: hash, files: files}, return: false)
      :ok
    else
      {:error, reason} ->
        Logger.warning("[SiteIcon] not drawn for site #{site_id}: #{inspect(reason)}")
        fail(site_id, hash)
        :error
    end
  end

  defp write(site_id, hash, pngs) do
    Enum.reduce_while(pngs, {:ok, %{}}, fn {size, png}, {:ok, files} ->
      target = disk_path(site_id, hash, size)

      with :ok <- File.write(target <> ".part", png),
           :ok <- File.rename(target <> ".part", target) do
        {:cont, {:ok, Map.put(files, size, target)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A site's icons drawn from an older picture: no page names them any more.
  defp sweep(folder, hash) do
    with {:ok, names} <- File.ls(folder) do
      for name <- names,
          not String.starts_with?(name, hash <> "-"),
          do: File.rm(Path.join(folder, name))
    end

    :ok
  end

  defp failed?(site_id, hash) do
    match?(%{source: %{hash: ^hash, failed?: true}}, AssetsState.get_value(site_id, @entry))
  end

  defp fail(site_id, hash) do
    case AssetsState.get_value(site_id, @entry) do
      %{source: %{hash: ^hash} = source} = entry ->
        AssetsState.update_value(site_id, @entry, %{entry | source: %{source | failed?: true}})

      _moved_on ->
        :ok
    end
  end

  @doc """
  Drops what is kept of the icons of the site `site_id` — of every site for `nil` — so the next
  request reads its settings and files again, and draws its icons again when their picture
  changed.
  """
  @spec forget(String.t() | nil) :: :ok
  def forget(nil) do
    for %{id: site_id} <- AssetsState.get_by_type(@entry), do: AssetsState.delete(site_id, @entry)
    :ok
  end

  def forget(site_id) when is_binary(site_id), do: AssetsState.delete(site_id, @entry)

  @doc """
  `forget/1` for the site `site_id` when its favicon or the picture of its icons is the media file
  `relative_path`, `/uploads/<site_id>/media/…`; anything else is left as it is.
  """
  @spec forget_file(String.t(), String.t()) :: :ok
  def forget_file(site_id, relative_path) when is_binary(site_id) and is_binary(relative_path) do
    with {:ok, %{active: active}} <- Media.storage_paths(relative_path, site_id),
         %{} = entry <- AssetsState.get_value(site_id, @entry),
         true <- active in for(%{path: path} <- [entry.favicon, entry.source], do: path) do
      forget(site_id)
    else
      _not_an_icon -> :ok
    end
  end

  @doc "The folder the icons of the site `site_id` are written to."
  @spec dir(String.t()) :: String.t()
  def dir(site_id), do: Path.join([Media.static_dir(), "uploads", site_id, "icons"])

  defp disk_path(site_id, hash, size), do: Path.join(dir(site_id), "#{hash}-#{size}.png")

  # What is kept for the settings as they are now; read again when either holds another value.
  defp entry(site_id) do
    values = for key <- @settings, do: Settings.get(key, nil, site_id)

    case AssetsState.get_value(site_id, @entry) do
      %{settings: ^values} = entry -> entry
      _stale_or_none -> remember(site_id, values)
    end
  end

  defp remember(site_id, values) do
    favicon = own_file(Seo.favicon(site_id), site_id)
    app_icon = own_file(Seo.site_picture("site.app_icon", site_id), site_id)
    source = Enum.find_value([app_icon, favicon], &drawable/1)
    entry = %{settings: values, favicon: favicon, source: source}

    AssetsState.save(%{
      id: site_id,
      type: @entry,
      value: entry,
      hash: source && source.hash,
      updated_at: DateTime.utc_now()
    })

    entry
  end

  defp own_file("/" <> _ = address, site_id) do
    with path when is_binary(path) <- ShareCard.site_file(URI.parse(address).path, site_id),
         type when is_binary(type) <- ShareCard.picture_type(path) do
      %{path: path, type: type}
    end
  end

  defp own_file(_elsewhere_or_none, _site_id), do: nil

  defp drawable(%{path: path, type: type}) when type in @drawable do
    case File.read(path) do
      {:ok, bytes} -> %{path: path, type: type, hash: hash(bytes), failed?: false}
      {:error, _reason} -> nil
    end
  end

  defp drawable(_not_drawable), do: nil

  defp hash(bytes) do
    :sha256
    |> :crypto.hash([Integer.to_string(@version), bytes])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
