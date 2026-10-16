# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.RedirectsState do
  @moduledoc """
  ETS copy of the active `MishkaCmsCore.Runtime.Redirect` rules, so a request is answered without a
  query.

  The same shape as `MishkaCmsCore.Runtime.States.TranslationsState`, for the same reasons: loaded
  once at boot, then kept current off the resource's own PubSub broadcasts, which reach every node —
  a rule saved on one server is served by all of them without a restart. Nothing is read again until
  a rule changes.

  Each entry is `{{site_id, from_path}, id, to, status}`; a second table maps a rule's id to its key,
  so a rule whose `from_path` changed, or that was archived, deactivated or deleted, leaves its old
  key behind it. Only active, unarchived rules are kept.

  Every change is heard on `runtime:state:redirect:changed` with `%{op: :save | :delete, key: id}`.

  Started by the host after `Phoenix.PubSub` and before the endpoint, like the other states:

      MishkaCmsCore.Runtime.States.RedirectsState,
  """
  use GenServer

  require Ash.Query

  @table :mishka_cms_redirects
  @ids :mishka_cms_redirect_ids
  @pubsub MishkaCmsCore.PubSub

  # `MishkaCmsCore.Runtime.Redirect` publishes `[[nil, :site_id], ...]`, which puts every write on these
  # three topics as well as its site-scoped ones.
  @topics ["redirect:created", "redirect:updated", "redirect:destroyed"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The rule `site_id` serves for `path` — a key `MishkaCmsCore.Runtime.Redirects` built — as
  `{to, status}`, else `nil`.

  One lookup, no GenServer hop. Never raises: a table that is not there yet is the same as one with
  nothing in it, so a request answered before this process starts is served as if no rule existed.
  """
  @spec lookup(String.t(), String.t()) :: {String.t(), pos_integer()} | nil
  def lookup(site_id, path) do
    case :ets.whereis(@table) do
      :undefined -> nil
      table -> find(table, site_id, path)
    end
  end

  defp find(table, site_id, path) do
    case :ets.lookup(table, {site_id, path}) do
      [{_key, _id, to, status}] -> {to, status}
      [] -> nil
    end
  end

  @doc "Reload every rule from the database."
  @spec refresh() :: :ok
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@ids, [:named_table, :set, :protected])
    for topic <- @topics, do: Phoenix.PubSub.subscribe(@pubsub, topic)
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    load_all()
    {:reply, :ok, state}
  end

  # TAKES THE ROW OFF THE BROADCAST, as `TranslationsState` does and for its reasons: this process owns
  # no sandbox connection under test, and a query here would put every request in the system behind
  # it. The notification already carries the row as Ash just wrote it.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: topic,
          payload: %Ash.Notifier.Notification{data: %{id: _id} = rule}
        },
        state
      )
      when topic in ["redirect:created", "redirect:updated"] do
    keep(rule)
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "redirect:destroyed",
          payload: %Ash.Notifier.Notification{data: %{id: id}}
        },
        state
      ) do
    forget(id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp keep(%{active: true, archived_at: nil} = rule) do
    drop(rule.id)
    key = {rule.site_id, rule.from_path}
    :ets.insert(@table, {key, rule.id, rule.to, rule.status})
    :ets.insert(@ids, {rule.id, key})
    changed(:save, rule.id)
  end

  defp keep(rule), do: forget(rule.id)

  defp forget(id) do
    drop(id)
    changed(:delete, id)
  end

  # THE KEY GOES ONLY WHILE IT IS STILL THIS RULE'S. Another rule may hold the address by now — one
  # created after this one was archived — and a late broadcast must not take it from that rule.
  defp drop(id) do
    case :ets.lookup(@ids, id) do
      [{^id, key}] ->
        :ets.match_delete(@table, {key, id, :_, :_})
        :ets.delete(@ids, id)

      [] ->
        true
    end
  end

  defp changed(op, id) do
    MishkaInstaller.Event.Hook.call("runtime:state:redirect:changed", %{op: op, key: id},
      return: false
    )
  end

  defp load_all do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@ids)

    MishkaCmsCore.Runtime.Redirect
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(active == true)
    |> Ash.stream!(authorize?: false)
    |> Enum.each(fn rule ->
      key = {rule.site_id, rule.from_path}
      :ets.insert(@table, {key, rule.id, rule.to, rule.status})
      :ets.insert(@ids, {rule.id, key})
    end)
  end
end
