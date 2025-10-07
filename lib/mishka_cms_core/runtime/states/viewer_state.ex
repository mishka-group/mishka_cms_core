defmodule MishkaCmsCore.Runtime.States.ViewerState do
  @moduledoc """
  ETS cache of who a signed-in user is to the site gates: their site, their address and the names of
  the permissions they hold, and whether they are a dashboard admin and an API admin
  (`MishkaCmsCore.Accounts.Helper.dashboard_admin?/1` and `api_admin?/1`). A request that has not
  loaded its user — a file, a live navigation — is answered from here by the user's id, with no
  query, and every `Helper` admin predicate and `MishkaCmsCore.Accounts.AuthGate.signs_out?/2`
  answer a cached viewer exactly as they answer the user.

  An entry is written by the page pipeline, which loads the user fresh on every request, and is
  dropped whenever that user's access changes: `MishkaCmsCore.Accounts.LiveSockets.disconnect/1` calls
  `forget/1`, which clears it on every node. A user with no entry is answered as someone who is not
  an admin until their next page load writes one, so a gap closes rather than opens.

  Each write and drop is announced on `runtime:state:viewer:changed` as `%{op: :save | :delete, key:
  user_id}`, once per node.
  """
  use GenServer

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.Helper

  @table :mishka_cms_viewers
  @pubsub MishkaCmsCore.PubSub
  @topic "viewer_state"

  @typedoc "A user as the site gates see them."
  @type viewer :: %{
          id: String.t(),
          site_id: String.t() | nil,
          email: String.t(),
          permissions: [%{name: String.t()}],
          dashboard_admin?: boolean(),
          api_admin?: boolean()
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Writes `user` as the gates should see them, when it differs from what is cached.
  """
  @spec remember(map() | nil) :: :ok
  def remember(%{id: id, site_id: site_id} = user) when is_binary(id) do
    user = AccessPermissions.with_permissions(user)

    viewer = %{
      id: id,
      site_id: site_id,
      email: user |> Map.get(:email) |> to_string(),
      permissions:
        for(%{name: name} <- List.wrap(Map.get(user, :permissions)), do: %{name: name}),
      dashboard_admin?: Helper.dashboard_admin?(user),
      api_admin?: Helper.api_admin?(user)
    }

    case :ets.lookup(@table, id) do
      [{^id, ^viewer}] ->
        :ok

      _stale_or_absent ->
        :ets.insert(@table, {id, viewer})
        announce(:save, id)
    end

    :ok
  end

  def remember(_no_user), do: :ok

  @doc """
  The cached viewer for a user id, or `nil`.
  """
  @spec get(String.t() | nil) :: viewer() | nil
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, viewer}] -> viewer
      [] -> nil
    end
  end

  def get(_no_id), do: nil

  @doc """
  Drops a user's entry on every node.
  """
  @spec forget(String.t()) :: :ok
  def forget(id) when is_binary(id) do
    drop(id)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:forget_viewer, id, node()})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl true
  # A forget this node sent has already been applied here.
  def handle_info({:forget_viewer, _id, from}, state) when from == node(), do: {:noreply, state}

  def handle_info({:forget_viewer, id, _from}, state) do
    drop(id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drop(id) do
    :ets.delete(@table, id)
    announce(:delete, id)
  end

  defp announce(op, id) do
    MishkaInstaller.Event.Hook.call("runtime:state:viewer:changed", %{op: op, key: id},
      return: false
    )
  end
end
