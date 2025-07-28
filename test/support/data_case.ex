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

  @doc "Checks out a sandboxed connection for the test, shared with its spawned processes unless async."
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(@repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
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
