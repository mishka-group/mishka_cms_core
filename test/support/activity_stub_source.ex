defmodule MishkaCmsCore.Test.ActivityStubSource do
  @moduledoc """
  A `MishkaCmsCore.Activity.Behaviours.Source` stub for exercising the
  `ActivityFeed` component's own composition logic (topic fan-out, merge,
  sort, cap) without a database.

  A test sets what this source reports, then asserts what the component did
  with it:

      ActivityStubSource.put_entries([entry(id: "a"), entry(id: "b")])
      ActivityStubSource.put_topics(["stub:one"])

  State lives in a public ETS table rather than the process dictionary because
  `initial_fetch/2` is invoked from a `Task` process, not the test's. The table
  is owned by whichever process writes first (the test) and dies with it, so a
  test always starts from empty; the table name is global, so a suite using this
  stub must not be `async: true`.

  `entry/1` builds a row in the shared entry shape with sane defaults.
  """

  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  @table :activity_stub_source

  @doc "Set the entries `initial_fetch/2` returns."
  def put_entries(entries), do: put(:entries, entries)

  @doc "Set the topics `topics/1` returns."
  def put_topics(topics), do: put(:topics, topics)

  @doc """
  Hold `initial_fetch/2` open until released, so a test can observe the feed
  mid-load without sleeping. The fetching process announces itself to `pid` as
  `{:fetching, task_pid}` and resumes when sent `:release`.
  """
  def block_fetch(pid), do: put(:block, pid)

  @doc "Build an entry in the shared shape; `overrides` replace any default field."
  def entry(overrides \\ []) do
    Map.merge(
      %{
        id: "stub-1",
        resource_label: "Stub",
        action: :create,
        severity: :info,
        badge_label: "CREATE",
        badge_tone: :emerald,
        tone: :created,
        inserted_at: ~U[2026-01-01 00:00:00Z],
        source_id: "rec-1",
        site_id: nil,
        user_id: nil,
        message: "Stub created"
      },
      Map.new(overrides)
    )
  end

  @impl true
  def topics(_scope), do: get(:topics, ["stub:created"])

  @impl true
  def handles?(%Phoenix.Socket.Broadcast{topic: "stub" <> _}), do: true
  def handles?(_), do: false

  @impl true
  def to_entry(%Phoenix.Socket.Broadcast{payload: %{entry: entry}}), do: entry
  def to_entry(_), do: nil

  @impl true
  def initial_fetch(_scope, _limit) do
    await_release(get(:block, nil))
    get(:entries, [])
  end

  defp await_release(nil), do: :ok

  defp await_release(pid) do
    send(pid, {:fetching, self()})

    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end
  end

  defp put(key, value) do
    table()
    :ets.insert(@table, {key, value})
    value
  end

  defp get(key, default) do
    case :ets.whereis(@table) do
      :undefined -> default
      _ref -> lookup(key, default)
    end
  end

  defp lookup(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      ref -> ref
    end
  end
end
