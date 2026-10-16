# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.CompiledModuleCache do
  @moduledoc """
  Keeps the runtime modules the CMS builds — pages, layouts, error pages and components — as `.beam`
  files on disk, so a node that restarts, or is redeployed with the same code, loads a module it
  built before instead of compiling it again.

  Off unless it is given a directory. `MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler` asks
  for it through `ModuleCompiler.compile_module/3`; nothing else is cached.

  ## Turning it on

      config :mishka_cms_core, :compiled_module_cache,
        dir: Path.join(System.fetch_env!("MISHKA_DATA_DIR"), "compiled_modules"),
        max_age_days: 7

    * `:dir` — where the files go. Point it at storage that outlives the release: in Docker, the
      persistent data volume. Missing or `nil`, the cache is off and a module is compiled exactly as
      it is without this module: no file is read or written and nothing is hashed.
    * `:max_age_days` — how long the files of an earlier build are kept after it last ran, so a
      rollback to it still finds them. Defaults to `7`.

  The directory is created mode `0700` and every file in it `0600`. A directory this node cannot
  make `0700` is not used at all: the files in it are code the node runs.

  ## What a file is found by

  The SHA-256 of the module's name, the file name it is compiled as, the quoted code
  `ModuleCompiler` is handed (see `canonical/1`), and the build that compiles it (`generation/0`):
  the Elixir, OTP and ERTS versions, the versions of `:phoenix`, `:phoenix_live_view` and
  `:mishka_cms_core`, and the MD5 of every module of the host application and of every application
  it depends on. A row that changed, a code generator that changed, or a macro, struct or import any
  generated module expands from that changed, files it under another key — there is nothing to
  invalidate by hand.

  Configuration is not part of the key. A module reads the application environment when it runs, as
  it does without the cache; a value read while it compiles — `Application.compile_env/3` in a
  helper's code, say — stays the one it was saved with until its row changes. Empty the directory
  after changing such a value.

  ## What a file holds

  The binary the compiler produced, with one more chunk, `MCMC`, carrying the key it was filed under
  and a SHA-256 of every other chunk. A file is loaded only when its chunks read, the module it holds
  is the one asked for, and both of those match. Anything else — a truncated or flipped file, one
  holding another module, one the code server refuses — is deleted, and the module is compiled.

  ## Where it is on disk

      <dir>/<generation id>/<module>/<key>.beam

  A module has one file per build. Writing a new one deletes the one before it, and
  `ModuleCompiler.unload/1` deletes the module's folder. The first time a node uses the cache it
  deletes the folders of other builds that have not run for `:max_age_days`, at most 16 of
  them, in a task of its own. Nothing runs on a timer.

  ## Plugin events

    * `runtime:compile:cache_hit` — `%{module: module, key: key}`, a module loaded from its file.
    * `runtime:compile:cache_miss` — `%{module: module, key: key, reason: reason}`, a module that is
      compiled because there was no usable file. `reason` is `:absent`, `:unreadable`, `:corrupt`,
      `:wrong_module` or `:load_failed`.
  """
  require Logger

  @host_app Application.compile_env!(:mishka_cms_core, :host_app)

  @chunk ~c"MCMC"
  @format 1
  @default_max_age_days 7
  @sweep_limit 16
  @generation_key {__MODULE__, :generation}

  @typedoc "Where one module's file is, and the key it is filed under."
  @type entry :: %{
          module: module(),
          key: binary(),
          folder: Path.t(),
          path: Path.t()
        }

  @typedoc "The build the cache files modules under: `id` names its folder."
  @type generation :: %{id: String.t(), digest: binary()}

  @typedoc "Why a module was compiled instead of loaded."
  @type miss :: :absent | :unreadable | :corrupt | :wrong_module | :load_failed

  @doc """
  The configured directory, or `nil` when the cache is off.

  ## Examples

      # config :mishka_cms_core, :compiled_module_cache, dir: "/data/compiled_modules"
      dir()
      #=> "/data/compiled_modules"

      # no :compiled_module_cache, or dir: nil
      dir()
      #=> nil
  """
  @spec dir() :: Path.t() | nil
  def dir do
    case Application.get_env(:mishka_cms_core, :compiled_module_cache) do
      opts when is_list(opts) -> present(Keyword.get(opts, :dir))
      _off -> nil
    end
  end

  defp present(dir) when is_binary(dir) and dir != "", do: dir
  defp present(_missing), do: nil

  @doc """
  Where the module `quoted` defines, compiled as `file`, is filed in `dir`, or `:off` when it cannot
  be cached there: a module name that is not a plain dotted alias, or a directory this node could
  not make `0700`.

  Hashes `quoted`. The first call in a node also works out `generation/0` and readies `dir`.
  """
  @spec entry(Path.t(), module(), String.t(), Macro.t()) :: {:ok, entry()} | :off
  def entry(dir, module, file, quoted) do
    generation = generation()

    with {:ok, name} <- folder_name(module),
         :ready <- ready(dir, generation.id) do
      key = key(module, file, quoted, generation.digest)
      folder = Path.join([dir, generation.id, name])

      {:ok,
       %{
         module: module,
         key: key,
         folder: folder,
         path: Path.join(folder, Base.encode16(key, case: :lower) <> ".beam")
       }}
    else
      _not_cacheable -> :off
    end
  end

  @doc """
  The SHA-256 a module is filed under: of `digest` (a `generation/0`), the module's name, the file
  name it is compiled as and the quoted code that defines it, as `canonical/1` writes it.
  """
  @spec key(module(), String.t(), Macro.t(), binary()) :: binary()
  def key(module, file, quoted, digest) do
    :crypto.hash(:sha256, [
      digest,
      Atom.to_string(module),
      0,
      file,
      0,
      :erlang.term_to_binary(canonical(quoted), [:deterministic])
    ])
  end

  @doc """
  `quoted` with the two things HEEx writes differently from one node to the next made the same, so
  the same template is found under the same key after a restart.

  `Phoenix.LiveView.Engine` decides whether a part of a template is drawn again by a chain of
  `changed_assign?/2` and `nested_changed_assign?/4` checks joined with `or`, in the order it reads
  them out of a map — and a map of more than 32 assigns is read in an order that differs between
  nodes. The fingerprint of the `%Phoenix.LiveView.Rendered{}` or `%Phoenix.LiveView.Comprehension{}`
  holding that chain is a hash of it, so it differs too. Here the checks of such a chain are put in
  one order and the fingerprint left out: the checks are side-effect free, so their order does not
  change what the module does, and the fingerprint is a function of the code beside it.

  Only the key is computed from this; the module is compiled from `quoted` as it is.
  """
  @spec canonical(Macro.t()) :: term()
  def canonical({:or, meta, [left, right]} = chain) do
    checks = or_operands(chain, [])

    case Enum.all?(checks, &change_check?/1) do
      true ->
        [first | rest] = Enum.sort(checks)
        Enum.reduce(rest, first, &{:or, meta, [&2, &1]})

      false ->
        {:or, meta, [canonical(left), canonical(right)]}
    end
  end

  def canonical({:%, meta, [{:__aliases__, _, [:Phoenix, :LiveView, struct]} = name, fields]})
      when struct in [:Rendered, :Comprehension] do
    {:%, meta, [name, unfingerprinted(fields)]}
  end

  def canonical(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> canonical_list() |> List.to_tuple()

  def canonical(list) when is_list(list), do: canonical_list(list)
  def canonical(other), do: other

  defp canonical_list([head | tail]), do: [canonical(head) | canonical_list(tail)]
  defp canonical_list([]), do: []
  defp canonical_list(improper_tail), do: canonical(improper_tail)

  defp or_operands({:or, _meta, [left, right]}, acc),
    do: or_operands(left, or_operands(right, acc))

  defp or_operands(operand, acc), do: [operand | acc]

  defp change_check?({{:., _, [Phoenix.LiveView.Engine, check]}, _, args})
       when check in [:changed_assign?, :nested_changed_assign?] and is_list(args),
       do: true

  defp change_check?(_operand), do: false

  defp unfingerprinted({:%{}, meta, fields}), do: {:%{}, meta, unfingerprinted_fields(fields)}
  defp unfingerprinted(fields), do: canonical(fields)

  defp unfingerprinted_fields([{:fingerprint, fingerprint} | rest]) when is_integer(fingerprint),
    do: [{:fingerprint, 0} | unfingerprinted_fields(rest)]

  defp unfingerprinted_fields([field | rest]),
    do: [canonical(field) | unfingerprinted_fields(rest)]

  defp unfingerprinted_fields(rest), do: canonical(rest)

  @doc """
  Loads the module from its file, as `ModuleCompiler` loads one it compiled: the version before the
  loaded one is purged first. `:ok`, or `{:miss, reason}` when it has to be compiled — and then a
  file that was there but could not be used is gone.
  """
  @spec load(entry(), String.t()) :: :ok | {:miss, miss()}
  def load(%{module: module, key: key, path: path} = entry, file) do
    result =
      with {:ok, binary} <- read(path),
           :ok <- verify(binary, module, key) do
        install(module, file, binary)
      end

    loaded(result, entry)
  end

  defp loaded(:ok, %{module: module, key: key}) do
    Logger.debug("loaded #{inspect(module)} from the compiled-module cache")

    MishkaInstaller.Event.Hook.call(
      "runtime:compile:cache_hit",
      %{module: module, key: Base.encode16(key, case: :lower)},
      meta: %{module: module},
      return: false
    )

    :ok
  end

  defp loaded({:miss, reason} = miss, %{module: module, key: key, path: path}) do
    if reason != :absent do
      _ = File.rm(path)

      Logger.warning(
        "compiled-module cache: #{path} for #{inspect(module)} could not be used (#{reason}); deleted it, compiling instead"
      )
    end

    MishkaInstaller.Event.Hook.call(
      "runtime:compile:cache_miss",
      %{module: module, key: Base.encode16(key, case: :lower), reason: reason},
      meta: %{module: module, reason: reason},
      return: false
    )

    miss
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> {:miss, :absent}
      {:error, _reason} -> {:miss, :unreadable}
    end
  end

  # A WHOLE FILE FIRST: `:beam_lib` reads a file cut short inside its last chunk's padding, and the
  # code server then refuses it with an error of its own in the log.
  defp verify(<<"FOR1", size::32, "BEAM", _chunks::binary>> = binary, module, key)
       when size == byte_size(binary) - 8 do
    case :beam_lib.all_chunks(binary) do
      {:ok, ^module, chunks} -> stamped(chunks, key)
      {:ok, _another, _chunks} -> {:miss, :wrong_module}
      {:error, :beam_lib, _reason} -> {:miss, :corrupt}
    end
  end

  defp verify(_not_a_whole_beam, _module, _key), do: {:miss, :corrupt}

  defp stamped(chunks, key) do
    with {{@chunk, <<@format, ^key::binary-size(32), digest::binary-size(32)>>}, rest} <-
           List.keytake(chunks, @chunk, 0),
         ^digest <- digest(rest) do
      :ok
    else
      _unstamped_or_changed -> {:miss, :corrupt}
    end
  end

  defp digest(chunks), do: :crypto.hash(:sha256, for({id, data} <- chunks, do: [id, data]))

  defp install(module, file, binary) do
    if :code.is_loaded(module) != false, do: :code.purge(module)

    case :code.load_binary(module, String.to_charlist(file), binary) do
      {:module, ^module} -> :ok
      {:error, _reason} -> {:miss, :load_failed}
    end
  end

  @doc """
  Writes `binary`, the module just compiled for `entry`, to its file, and deletes the module's file
  from before. A file that cannot be written is logged and left out; the module is loaded either way.
  """
  @spec store(entry(), binary()) :: :ok
  def store(%{module: module, key: key, folder: folder, path: path}, binary) do
    temporary = path <> ".#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}.tmp"

    result =
      with {:ok, ^module, chunks} <- :beam_lib.all_chunks(binary),
           {:ok, stamped} <- :beam_lib.build_module(chunks ++ [{@chunk, stamp(key, chunks)}]),
           :ok <- File.mkdir_p(folder),
           :ok <- private(folder),
           :ok <- File.write(temporary, stamped),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        drop_older(folder, Path.basename(path))
      end

    stored(result, module, path, temporary)
  end

  defp stamp(key, chunks), do: <<@format, key::binary-size(32), digest(chunks)::binary>>

  # The module's folder, its build's and the cache's own, `0700` — `File.mkdir_p/1` makes any of them
  # again with the default mode when it was deleted while the node ran.
  defp private(folder) do
    generation = Path.dirname(folder)

    Enum.reduce_while([Path.dirname(generation), generation, folder], :ok, fn path, :ok ->
      case File.chmod(path, 0o700) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stored(:ok, _module, _path, _temporary), do: :ok

  defp stored(failure, module, path, temporary) do
    _ = File.rm(temporary)

    Logger.warning(
      "compiled-module cache: could not write #{path} for #{inspect(module)}: #{inspect(failure)}"
    )

    :ok
  end

  defp drop_older(folder, keep) do
    case File.ls(folder) do
      {:ok, names} ->
        for name <- names, name != keep, do: File.rm(Path.join(folder, name))
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Deletes `module`'s files of the running build, when the cache is on and this node has used it.
  Called by `ModuleCompiler.unload/1`.
  """
  @spec forget(module()) :: :ok
  def forget(module) do
    with dir when is_binary(dir) <- dir(),
         %{id: id} <- :persistent_term.get(@generation_key, nil),
         :ready <- :persistent_term.get({__MODULE__, dir, id}, nil),
         {:ok, name} <- folder_name(module) do
      _ = File.rm_rf(Path.join([dir, id, name]))
    end

    :ok
  end

  # A NAME THAT IS ALSO A SAFE FOLDER NAME. Every module the handler builds is
  # `Elixir.MishkaCmsCore.Runtime.<hash>.<Type>`; anything with a separator, a space or a quote in it
  # is compiled and not cached.
  defp folder_name(module) do
    name = Atom.to_string(module)

    case byte_size(name) <= 200 and folder_safe?(name) do
      true -> {:ok, name}
      false -> :error
    end
  end

  defp folder_safe?(<<>>), do: true

  defp folder_safe?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?.],
       do: folder_safe?(rest)

  defp folder_safe?(_other), do: false

  @doc """
  The build this node compiles modules with, worked out once per node: its `digest` is part of every
  key and its `id` names the folder its files go in.

  In a release every module is already loaded and this takes a few milliseconds. Started with
  `mix`, the modules not loaded yet are read from their `.beam` files, which can take a second.
  """
  @spec generation() :: generation()
  def generation do
    case :persistent_term.get(@generation_key, nil) do
      nil -> :global.trans({@generation_key, self()}, &generation_once/0, [node()])
      generation -> generation
    end
  end

  defp generation_once do
    case :persistent_term.get(@generation_key, nil) do
      nil ->
        digest = fingerprint()

        generation = %{
          id: digest |> binary_part(0, 8) |> Base.encode16(case: :lower),
          digest: digest
        }

        :persistent_term.put(@generation_key, generation)
        generation

      generation ->
        generation
    end
  end

  defp fingerprint do
    versions = [
      elixir: System.version(),
      otp: System.otp_release(),
      erts: List.to_string(:erlang.system_info(:version)),
      phoenix: vsn(:phoenix),
      phoenix_live_view: vsn(:phoenix_live_view),
      mishka_cms_core: vsn(:mishka_cms_core)
    ]

    code =
      for app <- applications(@host_app),
          module <- Enum.sort(List.wrap(Application.spec(app, :modules))),
          do: {module, module_md5(module)}

    :crypto.hash(:sha256, :erlang.term_to_binary({versions, code}, [:deterministic]))
  end

  defp vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  # The host application and every application it depends on, sorted.
  defp applications(root), do: [root] |> reach(MapSet.new()) |> Enum.sort()

  defp reach([], seen), do: seen

  defp reach([app | rest], seen) do
    case MapSet.member?(seen, app) do
      true ->
        reach(rest, seen)

      false ->
        needs =
          List.wrap(Application.spec(app, :applications)) ++
            List.wrap(Application.spec(app, :included_applications))

        reach(needs ++ rest, MapSet.put(seen, app))
    end
  end

  # THE SAME MD5 EITHER WAY. A loaded module's is the code server's; the one of a module not loaded
  # yet is read from its file, and `:beam_lib.md5/1` is what `:code.module_status/1` compares the two
  # with — so the answer does not depend on which modules happen to be loaded yet.
  defp module_md5(module) do
    case :erlang.module_loaded(module) do
      true -> :erlang.get_module_info(module, :md5)
      false -> file_md5(:code.which(module))
    end
  end

  defp file_md5(path) when is_list(path) do
    case :beam_lib.md5(path) do
      {:ok, {_module, md5}} -> md5
      {:error, :beam_lib, _reason} -> nil
    end
  end

  defp file_md5(_preloaded_or_missing), do: nil

  # ONCE PER DIRECTORY AND BUILD IN A NODE: the directory is made `0700` before anything is read from
  # it, and the folders of builds that have not run for a while are swept.
  defp ready(dir, id) do
    case :persistent_term.get({__MODULE__, dir, id}, nil) do
      nil ->
        :global.trans({{__MODULE__, dir, id}, self()}, fn -> ready_once(dir, id) end, [node()])

      ready_or_refused ->
        ready_or_refused
    end
  end

  defp ready_once(dir, id) do
    case :persistent_term.get({__MODULE__, dir, id}, nil) do
      nil ->
        answer = prepare(dir, id)
        :persistent_term.put({__MODULE__, dir, id}, answer)
        answer

      answer ->
        answer
    end
  end

  defp prepare(dir, id) do
    folder = Path.join(dir, id)

    with :ok <- File.mkdir_p(folder),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.chmod(folder, 0o700),
         :ok <- File.touch(folder) do
      sweep_later(dir, id)
      :ready
    else
      {:error, reason} ->
        Logger.warning(
          "compiled-module cache is off: #{dir} could not be made a private directory (#{inspect(reason)})"
        )

        :refused
    end
  end

  defp sweep_later(dir, id) do
    seconds = max_age_days() * 86_400
    work = fn -> sweep(dir, id, seconds) end

    case Process.whereis(MishkaCmsCore.Runtime.TaskSupervisor) do
      nil -> Task.start(work)
      _supervisor -> Task.Supervisor.start_child(MishkaCmsCore.Runtime.TaskSupervisor, work)
    end
  end

  defp max_age_days do
    case Application.get_env(:mishka_cms_core, :compiled_module_cache) do
      opts when is_list(opts) -> days(Keyword.get(opts, :max_age_days))
      _off -> @default_max_age_days
    end
  end

  defp days(days) when is_integer(days) and days >= 0, do: days
  defp days(_unset), do: @default_max_age_days

  @doc false
  # Deletes, from `dir`, the folders of builds other than `current` that have not run for `seconds`
  # — at most `@sweep_limit` of them. Only a folder named like a generation id is ever touched, so
  # a `dir` that also holds something else keeps it.
  @spec sweep(Path.t(), String.t(), non_neg_integer()) :: [Path.t()]
  def sweep(dir, current, seconds) do
    cutoff = System.os_time(:second) - seconds

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(generation_id?(&1) and &1 != current))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&idle_since?(&1, cutoff))
        |> Enum.take(@sweep_limit)
        |> Enum.filter(&match?({:ok, _removed}, File.rm_rf(&1)))

      {:error, _reason} ->
        []
    end
  end

  defp generation_id?(name), do: byte_size(name) == 16 and hex?(name)

  defp hex?(<<>>), do: true
  defp hex?(<<char, rest::binary>>) when char in ?0..?9 or char in ?a..?f, do: hex?(rest)
  defp hex?(_other), do: false

  defp idle_since?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} -> mtime < cutoff
      _not_a_folder -> false
    end
  end
end
