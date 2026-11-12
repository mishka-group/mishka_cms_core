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
  mounts, so the chip costs no query.

  A tone is `:plain` or `:attention`, which is drawn in the warning colour. A count of zero hides
  the chip. The table is this node's: an extension in a cluster puts the count on each node.
  """
  use GenServer

  @table :mishka_cms_sidebar_counts
  @tones [:plain, :attention]

  @type tone :: :plain | :attention

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sets the count of the entry `key`."
  @spec put(String.t(), non_neg_integer(), tone()) :: :ok
  def put(key, number, tone \\ :plain)
      when is_binary(key) and is_integer(number) and number >= 0 and tone in @tones do
    :ets.insert(@table, {key, number, tone})
    :ok
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
end
