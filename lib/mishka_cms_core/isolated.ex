defmodule MishkaCmsCore.Isolated do
  @moduledoc """
  Runs one function in a separate operating-system process: a peer BEAM started for the call
  (`:peer`, in OTP's `stdlib`) and stopped after it.

  For work done by native code that could take the server down with it: a NIF that crashes on a
  malformed file ends the whole BEAM, and no supervisor can catch that. Run through `run/4`, the
  crash ends the peer, and the caller gets `{:error, reason}` back. Every site keeps serving.

      {:ok, png} = Isolated.run(MyApp.Thumbnail, :draw, [path])
      {:error, _reason} = Isolated.run(:erlang, :halt, [139])

  ## What the peer has

  The caller's code path (`:code.get_path/0`), so every module of the release or the project is
  there to call; no application is started, and no configuration is loaded. `function` starts
  what it needs.

  It is the same Erlang the caller runs: the `erl` of its own ERTS, booted with the `start_clean`
  boot file beside the caller's own — in a release `releases/<version>/start_clean`, with its
  `RELEASE_LIB` — so it starts the same in development and in a release, with nothing on `PATH`.

  ## Options

    * `:timeout` — milliseconds to wait for the answer, default `30_000`; past it the peer is
      killed and the answer is `{:error, :timeout}`
    * `:env` — `[{name, value}]` of charlists for the peer's environment; `false` as the value
      removes a variable the caller has
    * `:nice` — `0..19`, the peer's scheduling priority below the caller's, given to it by the
      system's `nice` (`/usr/bin/nice` or `/bin/nice`); default `0`. Where neither is there, the
      peer runs at the caller's priority

  ## Answers

  `{:ok, result}` with what `function` returned, else `{:error, reason}`: it raised, it exited, the
  peer died, or it took too long. The caller is never linked to the peer, so nothing it does can
  end the caller.
  """

  @type option ::
          {:timeout, timeout()}
          | {:env, [{charlist(), charlist() | false}]}
          | {:nice, 0..19}

  @nice_paths ["/usr/bin/nice", "/bin/nice"]

  @spec run(module(), atom(), list(), [option()]) :: {:ok, term()} | {:error, term()}
  def run(module, function, args, opts \\ [])
      when is_atom(module) and is_atom(function) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    exec = exec(Keyword.get(opts, :nice, 0))
    env = Keyword.get(opts, :env, [])
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(caller, {ref, call(module, function, args, exec, env)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  # Linked to the process `run/4` spawned: when that one ends, for any reason, so does the peer.
  defp call(module, function, args, exec, env) do
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        exec: exec,
        args: boot_args(),
        env: env,
        wait_boot: 30_000
      })

    :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
    result = :peer.call(peer, module, function, args, :infinity)
    :peer.stop(peer)
    result
  end

  @doc false
  @spec exec(0..19) :: charlist() | {charlist(), [charlist()]}
  def exec(nice) when is_integer(nice) and nice in 1..19 do
    case Enum.find(@nice_paths, &File.exists?/1) do
      nil -> erl()
      path -> {String.to_charlist(path), [~c"-n", Integer.to_charlist(nice), erl()]}
    end
  end

  def exec(_nice), do: erl()

  @doc false
  @spec erl() :: charlist()
  def erl do
    erts = "erts-" <> List.to_string(:erlang.system_info(:version))
    Path.join([List.to_string(:code.root_dir()), erts, "bin", "erl"]) |> String.to_charlist()
  end

  @doc false
  @spec boot_args() :: [charlist()]
  def boot_args do
    vars =
      for {:ok, pairs} <- [:init.get_argument(:boot_var)],
          [name, value] <- pairs,
          arg <- [~c"-boot_var", name, value],
          do: arg

    case :init.get_argument(:boot) do
      {:ok, [[boot]]} -> clean_boot(boot) ++ vars
      _no_boot -> vars
    end
  end

  defp clean_boot(boot) do
    clean = boot |> List.to_string() |> Path.dirname() |> Path.join("start_clean")

    if File.exists?(clean <> ".boot"),
      do: [~c"-boot", String.to_charlist(clean)],
      else: []
  end
end
