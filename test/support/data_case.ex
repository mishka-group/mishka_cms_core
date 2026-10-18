# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.DataCase do
  @moduledoc """
  Test case for anything that touches the database but not the web layer — the resources, their
  actions and policies, the version trail, the dashboard queries.

  Stands in for the CMS's `MishkaCms.DataCase` so this suite runs without the CMS around it. Each
  test gets its own sandboxed connection and everything it writes is rolled back at the end;
  `async: false` (the default here) shares that connection with any process the test spawns, which
  the async data loaders behind the dashboard widgets rely on.

  See `MishkaCmsCore.ConnCase` for tests that go through the JSON API instead.
  """

  use ExUnit.CaseTemplate

  # The configured repo, so the same case works standalone (MishkaCmsCore.Repo) and inside a host
  # (the CMS's MishkaCms.Repo) without the tests knowing which.
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MishkaCmsCore.DataCase
      import MishkaCmsCore.Test.Factory
      import MishkaCmsCore.Test.VersionHelpers
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc """
  Checks out a sandboxed connection for the test, shared with its spawned processes unless async,
  and — for a test that is not async — puts `MishkaCmsCore.Runtime.States.SiteState` back as it
  found it when the test ends, and unloads the runtime modules the test built.

  A site a test creates is saved to `SiteState`, which is the node's, not the test's: the rollback
  takes the row back and leaves the entry, and a later test that saves a site of the same name or
  host is refused — its pages and its email then read as a site the node does not know. ExUnit runs
  the async modules first and the others one at a time after them, so a test that is not async is
  the only one touching the tables while it runs.

  A runtime module is the node's too — see `unload_built_on_exit/0`.
  """
  def setup_sandbox(%{module_sandbox: pid} = tags) when is_pid(pid),
    do: forget_runtime_on_exit(tags)

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(@repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    forget_runtime_on_exit(tags)
  end

  @doc """
  One sandboxed connection for a whole module, opened in its `setup_all` and shared with every test
  and every process they spawn; what the module wrote is rolled back after its last test.

  For a module whose tests only READ what one slow setup writes — a UI kit installed into the
  database, seconds each time — so it is written once instead of before every test:

      setup_all do
        context = module_sandbox()
        UiKitHandler.install_chelekom!(site_id: nil)
        context
      end

  A test in such a module sees what the tests before it wrote, so keep them to reading. Only for a
  module that is not async.
  """
  @spec module_sandbox() :: %{module_sandbox: pid()}
  def module_sandbox do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(@repo, shared: true)
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    unload_built_on_exit()
    %{module_sandbox: pid}
  end

  @doc """
  Unloads, when the test (or the `setup_all`) that calls it ends, every runtime module —
  `MishkaCmsCore.Runtime.<hash>.Component`, `.Page`, `.Layout`, … — that was built while it ran,
  and forgets the compile failures recorded while it ran.

  `setup_sandbox/1` calls it for every test that is not async, and `module_sandbox/0` for the
  module. A module built from a row is node-wide and outlives the rollback that takes the row away,
  and the runtime reaches a loaded module by its name without reading the row again; so a later
  test that writes its own row of the same name, from another bundle or with other attributes,
  would be drawn with the earlier test's build. What was loaded before the call is left as it was,
  unless it was rebuilt while the test ran.
  """
  @spec unload_built_on_exit() :: :ok
  def unload_built_on_exit do
    modules = runtime_modules()
    failures = MapSet.new(CompileFailureState.matching(:_))

    ExUnit.Callbacks.on_exit(fn ->
      for {module, md5} <- runtime_modules(),
          Map.get(modules, module) != md5,
          do: ModuleCompiler.unload(module)

      for {key, _reason} = failure <- CompileFailureState.matching(:_),
          not MapSet.member?(failures, failure),
          do: CompileFailureState.clear(key)
    end)

    :ok
  end

  # Each loaded module whose name has the shape `Helpers.module_name/3` gives a runtime module,
  # with the checksum of the code it was built with.
  defp runtime_modules do
    for {module, _file} <- :code.all_loaded(),
        runtime_module?(Atom.to_string(module)),
        into: %{},
        do: {module, module.module_info(:md5)}
  end

  defp runtime_module?(
         "Elixir.MishkaCmsCore.Runtime." <> <<hash::binary-size(32), ".", _::binary>>
       ),
       do: String.match?(hash, ~r/\A[0-9a-f]+\z/)

  defp runtime_module?(_name), do: false

  defp forget_runtime_on_exit(%{async: true}), do: :ok

  defp forget_runtime_on_exit(_tags) do
    snapshot = MishkaCmsCore.Runtime.States.SiteState.snapshot()
    on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.restore(snapshot) end)
    unload_built_on_exit()
  end

  @doc """
  Drops settings keys from the RAM cache when the test ends.

      setup do
        forget_settings(~w(cms.offline), [nil, site.id])
        :ok
      end

  The cache is process-global rather than sandboxed, so a value a test writes is still in it when
  the next suite runs — and `cms.offline` is not an inert one: left on, it takes the front end down
  and closes registration for everything that follows. A write reaches the cache through the
  `"setting:updated"` broadcast, so this is needed whether the test went through
  `MishkaCmsCore.Settings` or straight at the `Setting` resource.

  The keys are dropped rather than re-read: `on_exit` runs in its own process, which does not hold
  the sandbox's connection, so there is no database to re-read them from.
  """
  @spec forget_settings([String.t()], [String.t() | nil]) :: :ok
  def forget_settings(keys, scopes \\ [nil]) do
    ExUnit.Callbacks.on_exit(fn ->
      for key <- keys, scope <- scopes do
        MishkaCmsCore.Runtime.States.SettingsState.delete(scope, key)
      end

      :ok
    end)
  end

  @doc """
  Makes this node one that serves the site (`MishkaCmsCore.Runtime.Handlers.BootHandler.serving?/0`)
  until the test ends, by setting the host's endpoint to serve — what `mix phx.server` and a
  release's `PHX_SERVER` do. The suite's endpoint does not serve, so a test without it runs as a node
  that does not. Only for a test that is not async: the setting is the node's.

      setup :serve_the_site
  """
  @spec serve_the_site(map()) :: :ok
  def serve_the_site(_context) do
    app = Application.fetch_env!(:mishka_cms_core, :host_app)
    endpoint = Application.fetch_env!(:mishka_cms_core, :endpoint)
    config = Application.get_env(app, endpoint, [])

    Application.put_env(app, endpoint, Keyword.put(config, :server, true))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(app, endpoint, config) end)
    :ok
  end

  @doc """
  Sends the test `{:signal, payload}` for every Oban queue signal — a pause, resume, scale, start or
  stop — sent from then on until it ends, by any Oban instance on the node.
  """
  @spec watch_queue_signals() :: :ok
  def watch_queue_signals do
    test = self()
    handler = "queue-signals-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:oban, :notifier, :notify, :start],
        fn _event, _measure, meta, _config ->
          if meta.channel == :signal, do: send(test, {:signal, meta.payload})
        end,
        nil
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc """
  Turns changeset errors into a map of field to messages.

      assert %{password: ["password is too short"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
