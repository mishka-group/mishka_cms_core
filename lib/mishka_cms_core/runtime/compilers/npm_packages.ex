# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.NpmPackages do
  @moduledoc """
  The npm packages a JS hook imports, fetched once into the folder esbuild resolves bare imports from.

  A kit hook carries its whole pinned tree in its `npm` field, resolved by the kit's exporter:

      [%{"name" => "echarts", "version" => "6.1.0", "path" => "node_modules/echarts",
         "integrity" => "sha512-…"}, …]

  Nothing is resolved here. Each entry is downloaded from the registry by its exact name and version,
  checked against its integrity hash and unpacked at its `path` under the root — with no node, npm
  or shell involved.

  ## Once

  A package already in place with the same integrity is not fetched again; the check is one small
  file read, so a compile with every package present makes no request. One process fetches a given
  package at a time. A folder this module did not write — a package the CMS provisions itself — is
  used as it is and never replaced.

  ## Safely

    * name, version, path and integrity are checked before anything is requested or written;
    * the download URL is built from the configured registry, never read from a bundle;
    * the download is capped in size and must match its integrity hash before it is unpacked;
    * every file must land inside the package's own folder — an absolute path or a `..` refuses
      the whole package;
    * the package is unpacked into a temporary folder and moved into place only once complete, so
      an interrupted fetch leaves nothing half-written for esbuild to read.

  `config :mishka_cms_core, :npm_registry, url` names another registry; `:npm_req_options` passes
  options to every request — a test's `plug:`.
  """

  require Logger

  @registry "https://registry.npmjs.org"

  # Beside each unpacked package: the integrity it was verified against, which is what "in place"
  # means. A folder without it was not written here.
  @marker ".mishka-integrity"

  # ECharts is the largest a kit ships today, at about 13 MB packed; these are headroom.
  @max_tarball_bytes 64 * 1024 * 1024
  @max_unpacked_bytes 256 * 1024 * 1024
  @max_files 20_000

  @name ~r/\A(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*\z/
  @version ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z/
  @integrity ~r/\Asha512-[A-Za-z0-9+\/]{86}==\z/

  @doc """
  Puts every package of `entries` in place under `root`, in path order so a package is in place
  before any nested under it. `{:error, reason}` names the first that could not be.
  """
  @spec ensure([map()] | nil, String.t()) :: :ok | {:error, String.t()}
  def ensure(entries, root) when is_list(entries) do
    entries
    |> Enum.map(&stringify/1)
    |> Enum.sort_by(&(is_map(&1) && &1["path"]))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case ensure_one(entry, root) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def ensure(nil, _root), do: :ok
  def ensure(_entries, _root), do: {:error, "the package list is not a list"}

  @doc """
  Whether `entry` is a package this module can fetch: a valid npm name, an exact version, a path
  inside `node_modules` that ends in the name, and a sha512 integrity hash.
  """
  @spec valid_entry?(term()) :: boolean()
  def valid_entry?(entry), do: entry |> stringify() |> valid?()

  @doc """
  `entry` with string keys. Ash's map type turns a key that already exists as an atom into one, so
  a changeset holds `%{:name => …, "integrity" => …}` where the database gives strings back.
  """
  @spec stringify(term()) :: term()
  def stringify(%{} = entry), do: Map.new(entry, fn {key, value} -> {to_string(key), value} end)
  def stringify(entry), do: entry

  defp valid?(%{
         "name" => name,
         "version" => version,
         "path" => path,
         "integrity" => integrity
       })
       when is_binary(name) and is_binary(version) and is_binary(path) and is_binary(integrity) do
    byte_size(name) <= 214 and Regex.match?(@name, name) and Regex.match?(@version, version) and
      Regex.match?(@integrity, integrity) and path?(path, name)
  end

  defp valid?(_entry), do: false

  # `node_modules/<name>`, or nested under other packages: `node_modules/a/node_modules/<name>`.
  defp path?(path, name) do
    case String.split(path, "node_modules/") do
      ["" | owners] ->
        owners != [] and List.last(owners) == name and
          Enum.all?(Enum.drop(owners, -1), &owner?/1)

      _other ->
        false
    end
  end

  defp owner?(segment) do
    case String.split(segment, "/") do
      [_name, ""] -> Regex.match?(@name, String.trim_trailing(segment, "/"))
      [scope, name, ""] -> Regex.match?(@name, "#{scope}/#{name}")
      _other -> false
    end
  end

  defp ensure_one(entry, root) do
    cond do
      not valid?(entry) ->
        {:error, "#{describe(entry)} is not a package this CMS can fetch"}

      ready?(Path.join(root, entry["path"]), entry["integrity"]) ->
        :ok

      true ->
        target = Path.join(root, entry["path"])

        # One fetch per package at a time: a site and the shared base compiling together would
        # otherwise both download it, and the second rename would find the first one's folder.
        :global.trans(
          {{__MODULE__, target}, self()},
          fn ->
            if ready?(target, entry["integrity"]), do: :ok, else: fetch_into(entry, target)
          end,
          [node()]
        )
    end
  end

  defp describe(%{"name" => name, "version" => version}),
    do: "#{inspect(name)}@#{inspect(version)}"

  defp describe(entry), do: inspect(entry, limit: 5)

  # In place with this integrity, or a folder the CMS provisioned itself — never replaced.
  defp ready?(target, integrity) do
    case File.read(Path.join(target, @marker)) do
      {:ok, ^integrity} -> true
      {:ok, _other_version} -> false
      {:error, _absent} -> File.dir?(target)
    end
  end

  defp fetch_into(entry, target) do
    url = tarball_url(entry["name"], entry["version"])

    with {:ok, tgz} <- download(url),
         :ok <- verify(tgz, entry["integrity"]),
         {:ok, files} <- unpack(tgz),
         :ok <- place(files, target, entry["integrity"]) do
      Logger.info("[NpmPackages] #{entry["name"]}@#{entry["version"]} placed at #{entry["path"]}")
      :ok
    else
      {:error, reason} -> {:error, "#{entry["name"]}@#{entry["version"]}: #{reason}"}
    end
  end

  defp tarball_url(name, version) do
    registry = Application.get_env(:mishka_cms_core, :npm_registry, @registry)

    "#{String.trim_trailing(registry, "/")}/#{name}/-/#{name |> String.split("/") |> List.last()}-#{version}.tgz"
  end

  defp download(url) do
    request =
      [url: url, raw: true, max_retries: 1, receive_timeout: 60_000, into: bounded()] ++
        Application.get_env(:mishka_cms_core, :npm_req_options, [])

    case Req.get(request) do
      {:ok, %{status: 200, body: {:too_large, _limit}}} ->
        {:error, "larger than #{div(@max_tarball_bytes, 1024 * 1024)} MB"}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "the registry answered HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp bounded do
    fn {:data, chunk}, {request, response} ->
      case response.body do
        {:too_large, _limit} = stop ->
          {:halt, {request, %{response | body: stop}}}

        body when byte_size(body) + byte_size(chunk) > @max_tarball_bytes ->
          {:halt, {request, %{response | body: {:too_large, @max_tarball_bytes}}}}

        body ->
          {:cont, {request, %{response | body: body <> chunk}}}
      end
    end
  end

  defp verify(tgz, "sha512-" <> expected) do
    if Base.encode64(:crypto.hash(:sha512, tgz)) == expected,
      do: :ok,
      else: {:error, "the download does not match its integrity hash"}
  end

  # npm packs every file under one top folder, `package/` by convention; the files are what is
  # below it.
  defp unpack(tgz) do
    case :erl_tar.extract({:binary, tgz}, [:compressed, :memory]) do
      {:ok, entries} -> inside(entries)
      {:error, reason} -> {:error, "the archive cannot be read: #{inspect(reason)}"}
    end
  end

  defp inside(entries) do
    Enum.reduce_while(entries, {:ok, [], 0}, fn {name, content}, {:ok, files, size} ->
      relative = name |> to_string() |> String.split("/", parts: 2) |> Enum.at(1)
      size = size + byte_size(content)

      cond do
        not safe?(relative) ->
          {:halt, {:error, "the archive holds #{inspect(to_string(name))}, outside the package"}}

        size > @max_unpacked_bytes or length(files) >= @max_files ->
          {:halt, {:error, "the archive unpacks to more than this CMS accepts"}}

        true ->
          {:cont, {:ok, [{relative, content} | files], size}}
      end
    end)
    |> case do
      {:ok, files, _size} -> {:ok, files}
      error -> error
    end
  end

  defp safe?(relative) when is_binary(relative) and relative != "" do
    segments = String.split(relative, "/")

    not String.starts_with?(relative, "/") and
      not String.contains?(relative, ["\\", <<0>>, ":"]) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp safe?(_relative), do: false

  # Unpacked beside its target and renamed into place, so esbuild never reads half a package. A
  # folder there already is an older version this module wrote: `ready?/2` keeps everything else.
  defp place(files, target, integrity) do
    staging = "#{target}.#{System.unique_integer([:positive])}.partial"

    result =
      with :ok <- write_all(files, staging),
           :ok <- File.write(Path.join(staging, @marker), integrity),
           {:ok, _removed} <- File.rm_rf(target),
           :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.rename(staging, target) do
        :ok
      else
        {:error, reason, _path} -> {:error, "cannot replace #{target}: #{inspect(reason)}"}
        {:error, reason} -> {:error, "cannot write #{target}: #{inspect(reason)}"}
      end

    _ = File.rm_rf(staging)
    result
  end

  defp write_all(files, staging) do
    Enum.reduce_while(files, :ok, fn {relative, content}, :ok ->
      destination = Path.join(staging, relative)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, content) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end
