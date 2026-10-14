defmodule MishkaCmsCore.Runtime.States.SettingsState do
  @moduledoc """
  ETS-backed cache of the CMS settings, loaded once at boot and refreshed on change so reads are
  lock-free on every request (mirrors `MishkaCmsCore.Runtime.States.SiteState`). The durable source
  of truth is `MishkaCmsCore.Runtime.Setting`; application code should go through the
  `MishkaCmsCore.Settings` facade rather than this module directly.

  Settings are multitenant (see `MishkaCmsCore.Runtime.Setting`), so each entry is keyed by
  `{site_id, key}` — `site_id = nil` is the GLOBAL value, a `site_id` is that site's override. A read
  for a site resolves **site value → global value → default**, all from ETS with no GenServer hop.
  """
  use GenServer

  require Ash.Query

  @table :mishka_cms_settings
  @pubsub MishkaCmsCore.PubSub

  # Both topics `MishkaCmsCore.Runtime.Setting`'s `pub_sub` block publishes without a site segment.
  # Its `[[nil, :site_id], "updated"]` shape emits the site-scoped topic AND this one for every
  # write, global or per-site, so these two see everything.
  @topics ["setting:updated", "setting:destroyed"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Lock-free read of a setting's stored map for `site_id` (nil = global). A per-site lookup that misses
  falls back to the global value, then to `default`.
  """
  @spec get(term(), String.t(), term()) :: term()
  def get(site_id, key, default \\ nil)

  def get(nil, key, default) do
    case :ets.lookup(@table, {nil, key}) do
      [{_, value}] -> value
      [] -> default
    end
  end

  def get(site_id, key, default) do
    case :ets.lookup(@table, {site_id, key}) do
      [{_, value}] -> value
      [] -> get(nil, key, default)
    end
  end

  @doc """
  Lock-free read of a site's OWN stored map, with no fallback to the global value: `default` when the
  site holds none.
  """
  @spec get_own(String.t(), String.t(), term()) :: term()
  def get_own(site_id, key, default \\ nil) do
    case :ets.lookup(@table, {site_id, key}) do
      [{_, value}] -> value
      [] -> default
    end
  end

  @doc "All GLOBAL settings (site_id nil) as `%{key => value_map}` — used for default seeding."
  @spec all_global() :: %{optional(String.t()) => term()}
  def all_global do
    @table
    |> :ets.match_object({{nil, :_}, :_})
    |> Map.new(fn {{nil, key}, value} -> {key, value} end)
  end

  @doc """
  Reconcile one `{site_id, key}` entry with the database (called by the facade after a durable write).
  Re-reading inside the serialized GenServer makes the cache reflect DB-commit order, not caller
  arrival order — so concurrent writes to the same key converge on the committed value, and a removed
  row drops from the cache.
  """
  @spec refresh_key(term(), String.t()) :: :ok
  def refresh_key(site_id, key), do: GenServer.call(__MODULE__, {:refresh_key, site_id, key})

  @doc "Upsert a setting into the cache directly (test/seed helper; the façade uses `refresh_key/2`)."
  @spec put(term(), String.t(), term()) :: :ok
  def put(site_id, key, value), do: GenServer.call(__MODULE__, {:put, site_id, key, value})

  @doc "Drop a setting from the cache."
  @spec delete(term(), String.t()) :: :ok
  def delete(site_id, key), do: GenServer.call(__MODULE__, {:delete, site_id, key})

  @doc """
  Everything the cache holds now, for `restore/1` (test helper).

      snapshot = SettingsState.snapshot()
      on_exit(fn -> SettingsState.restore(snapshot) end)
  """
  @spec snapshot() :: [{{String.t() | nil, String.t()}, term()}]
  def snapshot, do: :ets.tab2list(@table)

  @doc """
  Puts the cache back to a `snapshot/0` (test helper). It reads no database, so it works from an
  `on_exit`, which a `refresh/0` there does not: that one runs before the test's transaction rolls
  back, and loads the test's own writes back into the cache.
  """
  @spec restore([{{String.t() | nil, String.t()}, term()}]) :: :ok
  def restore(entries), do: GenServer.call(__MODULE__, {:restore, entries})

  @doc "Reload every setting from the database into ETS."
  @spec refresh() :: :ok
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # THE WRITE IS OFTEN NOT THIS NODE'S. `MishkaCmsCore.Settings.put/3` refreshes the key locally
    # the moment its Ash write returns, which is the whole story on one machine — but this cache is
    # per node and `DNSCluster` means there are usually several, so a setting changed on one node
    # stayed stale on every other one until that node restarted. Nothing new is needed to fix it:
    # `MishkaCmsCore.Runtime.Setting` already publishes through `Ash.Notifier.PubSub`, and
    # Phoenix.PubSub carries a broadcast across every connected node. Only the listening was missing.
    for topic <- @topics, do: Phoenix.PubSub.subscribe(@pubsub, topic)

    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:refresh_key, site_id, key}, _from, state) do
    refresh_one(site_id, key)
    {:reply, :ok, state}
  end

  def handle_call({:put, site_id, key, value}, _from, state) do
    :ets.insert(@table, {{site_id, key}, value})
    written(site_id, key)
    {:reply, :ok, state}
  end

  def handle_call({:delete, site_id, key}, _from, state) do
    :ets.delete(@table, {site_id, key})
    written(site_id, key)
    {:reply, :ok, state}
  end

  def handle_call(:refresh, _from, state) do
    load_all()
    {:reply, :ok, state}
  end

  def handle_call({:restore, entries}, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, entries)
    MishkaCmsCore.Runtime.SiteAvailability.changed(nil)
    {:reply, :ok, state}
  end

  # TAKES THE ROW OFF THE BROADCAST, AND DOES NOT GO BACK TO THE DATABASE FOR IT. Re-reading would
  # be the obvious thing and is wrong here twice over: this process owns no Ecto sandbox connection,
  # so under test the read kills the cache and the supervision tree with it, and in production it
  # would put a query on a GenServer that every setting read in the system waits behind. The
  # notification already carries the row Ash just wrote, which is the value as of that write — the
  # only thing a re-read could add is a LATER write, and that one is arriving on this same topic
  # right behind it.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "setting:updated",
          payload: %Ash.Notifier.Notification{data: %{key: key, value: value} = data}
        },
        state
      ) do
    :ets.insert(@table, {{Map.get(data, :site_id), key}, value})
    written(Map.get(data, :site_id), key)
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "setting:destroyed",
          payload: %Ash.Notifier.Notification{data: %{key: key} = data}
        },
        state
      ) do
    :ets.delete(@table, {Map.get(data, :site_id), key})
    written(Map.get(data, :site_id), key)
    {:noreply, state}
  end

  # A subscriber hears whatever else shares its topics; anything not shaped like a setting is not ours.
  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_one(site_id, key) do
    case load_one(site_id, key) do
      {:ok, value} -> :ets.insert(@table, {{site_id, key}, value})
      :none -> :ets.delete(@table, {site_id, key})
    end

    written(site_id, key)
  end

  # A SITE'S OFFLINE SWITCH AND ITS SIGN-IN GATE TELL ITS OPEN PAGES, once this node's cache holds the
  # new value, so a page that checks again reads it. `nil` is the global switch, which holds every
  # site.
  defp written(site_id, "cms.offline"),
    do: MishkaCmsCore.Runtime.SiteAvailability.changed(site_id)

  defp written(site_id, "auth." <> _gate),
    do: MishkaCmsCore.Runtime.SiteAvailability.changed(site_id)

  # A SIDEBAR PLACE'S POSITION OR SWITCH is drawn by every open admin page, so they are told once the
  # cache holds the value.
  defp written(site_id, "sidebar." <> _entry),
    do: MishkaCmsCore.Sidebar.changed(site_id)

  defp written(_site_id, _key), do: :ok

  defp load_all do
    load_rows()
    MishkaCmsCore.Runtime.SiteAvailability.changed(nil)
  end

  defp load_rows do
    :ets.delete_all_objects(@table)

    MishkaCmsCore.Runtime.Setting
    |> Ash.read!(action: :read_any, authorize?: false)
    |> Enum.each(fn setting ->
      :ets.insert(@table, {{setting.site_id, setting.key}, setting.value})
    end)
  end

  defp load_one(site_id, key) do
    base = Ash.Query.filter(MishkaCmsCore.Runtime.Setting, key == ^key)

    query =
      if is_nil(site_id),
        do: Ash.Query.filter(base, is_nil(site_id)),
        else: Ash.Query.filter(base, site_id == ^site_id)

    case Ash.read(query, action: :read_any, authorize?: false) do
      {:ok, [setting | _]} -> {:ok, setting.value}
      _ -> :none
    end
  end
end
