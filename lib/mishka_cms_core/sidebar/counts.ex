# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Sidebar.Counts do
  @moduledoc """
  The numbers sidebar entries show beside their label, kept in memory.

  An extension calls `put/3` with the key of its entry whenever its data changes, for example after
  an order is saved:

      MishkaCmsCore.Sidebar.Counts.put("shop.orders", waiting, :attention)

  The value goes to an ETS table, which `MishkaCmsCore.Layouts.Nav` reads when an admin page
  mounts, so the chip costs no query. Open pages hear the change on the `"sidebar:counts"` PubSub
  topic as `{:sidebar_count, key, number, tone}` and redraw the chip. At most one message a second
  is sent for one entry: the first change is sent at once, and the last of the changes that follow
  within the second is sent when it ends.

  A tone is `:plain` or `:attention`, which is drawn in the warning colour. A count of zero hides
  the chip. The table is this node's, like the PubSub broadcast: an extension in a cluster puts the
  count on each node.
  """
  use GenServer

  @table :mishka_cms_sidebar_counts
  @topic "sidebar:counts"
  @interval 1_000
  @tones [:plain, :attention]

  @type tone :: :plain | :attention

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic open pages hear a count on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Sets the count of the entry `key`, and tells the open pages."
  @spec put(String.t(), non_neg_integer(), tone()) :: :ok
  def put(key, number, tone \\ :plain)
      when is_binary(key) and is_integer(number) and number >= 0 and tone in @tones do
    :ets.insert(@table, {key, number, tone})
    GenServer.cast(__MODULE__, {:sidebar_count, key, number, tone})
  end

  @doc "Every count set on this node, as `%{key => {number, tone}}`."
  @spec all() :: %{String.t() => {non_neg_integer(), tone()}}
  def all do
    case :ets.whereis(@table) do
      :undefined -> %{}
      table -> Map.new(:ets.tab2list(table), fn {key, number, tone} -> {key, {number, tone}} end)
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # `held` holds each entry sent within the last second, with the token of its timer and the
  # change waiting for the second to end, or `nil` when none came after it.
  @impl true
  def handle_cast({:sidebar_count, key, _number, _tone} = change, held) do
    case held do
      %{^key => {token, _waiting}} -> {:noreply, Map.put(held, key, {token, change})}
      _free -> {:noreply, send_count(held, change)}
    end
  end

  @impl true
  def handle_info({:release, key, token}, held) do
    case held do
      %{^key => {^token, nil}} -> {:noreply, Map.delete(held, key)}
      %{^key => {^token, change}} -> {:noreply, send_count(held, change)}
      _stale -> {:noreply, held}
    end
  end

  defp send_count(held, {:sidebar_count, key, _number, _tone} = change) do
    Phoenix.PubSub.local_broadcast(MishkaCmsCore.PubSub, @topic, change)

    token = make_ref()
    Process.send_after(self(), {:release, key, token}, @interval)
    Map.put(held, key, {token, nil})
  end
end
