defmodule MishkaCmsCore.Runtime.States.TranslationsState do
  @moduledoc """
  ETS copy of `MishkaCmsCore.Runtime.Translation`, so `t/1` is answered without a query.

  The same shape as `MishkaCmsCore.Runtime.States.SettingsState`, for the same reasons: loaded once
  at boot, then kept current off the resource's own PubSub broadcasts, which reach every node — a
  translation saved on one server is on all of them without a restart.

  Each entry is `{{site_id, language, key}, value}`, `site_id` nil for a global row. Only rows that
  HAVE a value are kept: a registered key nobody has translated is the same to `t/1` as no row at
  all, and it would only cost memory.
  """
  use GenServer

  require Ash.Query

  @table :mishka_cms_translations
  @pubsub MishkaCmsCore.PubSub

  # `MishkaCmsCore.Runtime.Translation` publishes `[[nil, :site_id], ...]`, which puts every write —
  # global or per site — on these two topics as well as its site-scoped one.
  @topics ["translation:updated", "translation:destroyed"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The value for `key` in `language` on `site_id`, falling back to the global row, else `nil`.

  Two lookups at most, no GenServer hop. Never raises: a table that is not there yet is the same as
  one with nothing in it, so a template rendered before this process starts shows its keys.
  """
  @spec lookup(String.t() | nil, String.t(), String.t()) :: String.t() | nil
  def lookup(site_id, language, key) do
    case :ets.whereis(@table) do
      :undefined -> nil
      table -> find(table, site_id, language, key)
    end
  end

  defp find(table, site_id, language, key) do
    case :ets.lookup(table, {site_id, language, key}) do
      [{_entry, value}] -> value
      [] when not is_nil(site_id) -> find(table, nil, language, key)
      [] -> nil
    end
  end

  @doc "Every language a cached translation is written in."
  @spec languages() :: [String.t()]
  def languages do
    case :ets.whereis(@table) do
      :undefined ->
        []

      table ->
        table
        |> :ets.match({{:_, :"$1", :_}, :_})
        |> List.flatten()
        |> Enum.uniq()
    end
  end

  @doc "Put one translation in the cache directly (test and seed helper)."
  @spec put(String.t() | nil, String.t(), String.t(), String.t() | nil) :: :ok
  def put(site_id, language, key, value),
    do: GenServer.call(__MODULE__, {:put, site_id, language, key, value})

  @doc "Reload every translation from the database."
  @spec refresh() :: :ok
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    for topic <- @topics, do: Phoenix.PubSub.subscribe(@pubsub, topic)
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, site_id, language, key, value}, _from, state) do
    keep(site_id, language, key, value)
    {:reply, :ok, state}
  end

  def handle_call(:refresh, _from, state) do
    load_all()
    {:reply, :ok, state}
  end

  # TAKES THE ROW OFF THE BROADCAST, as `SettingsState` does and for its reasons: this process owns no
  # sandbox connection under test, and a query here would put every render in the system behind it.
  # The notification already carries the row as Ash just wrote it.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "translation:updated",
          payload: %Ash.Notifier.Notification{
            data: %{language: language, key: key, value: value} = data
          }
        },
        state
      ) do
    keep(Map.get(data, :site_id), language, key, value)
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "translation:destroyed",
          payload: %Ash.Notifier.Notification{data: %{language: language, key: key} = data}
        },
        state
      ) do
    :ets.delete(@table, {Map.get(data, :site_id), language, key})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # AN EMPTIED TRANSLATION LEAVES THE CACHE. Clearing a value in the admin means "show the key again",
  # and a stale entry left behind would keep showing the old word.
  defp keep(site_id, language, key, value) when value in [nil, ""],
    do: :ets.delete(@table, {site_id, language, key})

  defp keep(site_id, language, key, value),
    do: :ets.insert(@table, {{site_id, language, key}, value})

  defp load_all do
    :ets.delete_all_objects(@table)

    MishkaCmsCore.Runtime.Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(not is_nil(value))
    |> Ash.Query.select([:site_id, :language, :key, :value])
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&keep(&1.site_id, &1.language, &1.key, &1.value))
  end
end
