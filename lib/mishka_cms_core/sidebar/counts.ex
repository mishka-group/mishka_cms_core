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

  ## One number per site

  An extension whose data belongs to a site gives `put/4` the site, because the people who read the
  chip are not all of one site: a site's admin must never see the number of another site.

      MishkaCmsCore.Sidebar.Counts.put("shop.orders", 3, :plain, site.id)

  `for_viewer/1` answers what one viewer is shown: a viewer who belongs to a site reads that site's
  number (or the one set without a site, when the entry has none for it), and a viewer with no site,
  a master, reads the sum of every site's number (`:attention` when any of them is), or the number
  set without a site when the entry has no per-site one. Open pages hear a per-site change as
  `{:sidebar_count, key, number, tone, site_id}` and read their own number again.

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
  @spec put(String.t(), non_neg_integer(), tone(), String.t() | nil) :: :ok
  def put(key, number, tone \\ :plain, site_id \\ nil)
      when is_binary(key) and is_integer(number) and number >= 0 and tone in @tones and
             (is_nil(site_id) or is_binary(site_id)) do
    :ets.insert(@table, {{key, site_id}, number, tone})

    change =
      if site_id,
        do: {:sidebar_count, key, number, tone, site_id},
        else: {:sidebar_count, key, number, tone}

    GenServer.cast(__MODULE__, change)
  end

  @doc "Every count as a viewer with no site reads it (`for_viewer/1`), as `%{key => {number, tone}}`."
  @spec all() :: %{String.t() => {non_neg_integer(), tone()}}
  def all, do: for_viewer(nil)

  @doc """
  What a viewer of `site_id` is shown, as `%{key => {number, tone}}`: the site's own number, else the
  one set without a site. With `nil`, the sum of the sites' numbers, else the one set without a site.
  """
  @spec for_viewer(String.t() | nil) :: %{String.t() => {non_neg_integer(), tone()}}
  def for_viewer(site_id) do
    case :ets.whereis(@table) do
      :undefined ->
        %{}

      table ->
        table
        |> :ets.tab2list()
        |> Enum.group_by(fn {{key, _site}, _number, _tone} -> key end)
        |> Map.new(fn {key, rows} -> {key, shown(rows, site_id)} end)
        |> Map.reject(fn {_key, shown} -> is_nil(shown) end)
    end
  end

  defp shown(rows, site_id) do
    global = Enum.find(rows, &match?({{_key, nil}, _number, _tone}, &1))
    sites = Enum.reject(rows, &match?({{_key, nil}, _number, _tone}, &1))
    own = site_id && Enum.find(sites, &match?({{_key, ^site_id}, _number, _tone}, &1))

    case {own, global, sites} do
      {{_, number, tone}, _global, _sites} -> {number, tone}
      {_none, {_, number, tone}, _sites} when not is_nil(site_id) -> {number, tone}
      {_none, _global, [_ | _]} when is_nil(site_id) -> sum(sites)
      {_none, {_, number, tone}, []} -> {number, tone}
      _other_site_only -> nil
    end
  end

  defp sum(rows) do
    tone = if Enum.any?(rows, &match?({_, _, :attention}, &1)), do: :attention, else: :plain
    {Enum.sum_by(rows, &elem(&1, 1)), tone}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # `held` holds each entry sent within the last second, with the token of its timer and the
  # change waiting for the second to end, or `nil` when none came after it.
  @impl true
  def handle_cast(change, held) do
    key = hold_key(change)

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

  defp send_count(held, change) do
    key = hold_key(change)
    Phoenix.PubSub.local_broadcast(MishkaCmsCore.PubSub, @topic, change)

    token = make_ref()
    Process.send_after(self(), {:release, key, token}, @interval)
    Map.put(held, key, {token, nil})
  end

  # An entry without a site is held under its key, as it always was; one site's number under the
  # key and the site, so one site's change never holds back another's.
  defp hold_key({:sidebar_count, key, _number, _tone}), do: key
  defp hold_key({:sidebar_count, key, _number, _tone, site_id}), do: {key, site_id}
end
