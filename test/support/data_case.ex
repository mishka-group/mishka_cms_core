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
  found it when the test ends.

  A site a test creates is saved to `SiteState`, which is the node's, not the test's: the rollback
  takes the row back and leaves the entry, and a later test that saves a site of the same name or
  host is refused — its pages and its email then read as a site the node does not know. ExUnit runs
  the async modules first and the others one at a time after them, so a test that is not async is
  the only one touching the tables while it runs.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(@repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    restore_sites_on_exit(tags)
  end

  defp restore_sites_on_exit(%{async: true}), do: :ok

  defp restore_sites_on_exit(_tags) do
    snapshot = MishkaCmsCore.Runtime.States.SiteState.snapshot()
    on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.restore(snapshot) end)
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
