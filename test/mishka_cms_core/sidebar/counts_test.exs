# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Sidebar.CountsTest do
  @moduledoc """
  The numbers sidebar entries show: kept in memory for a page that mounts, and sent to the open
  pages at most once a second for one entry, the latest value last.

  The second is ended by hand, with the message the timer would send, so nothing here waits on a
  clock.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Sidebar.Counts

  setup do
    key = "probe.count.#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, Counts.topic())
    {:ok, key: key}
  end

  # A cast is handled, and its broadcast sent, before the server answers the next call.
  defp settled, do: :sys.get_state(Counts)

  defp end_second(key) do
    %{^key => {token, _state}} = settled()
    send(Counts, {:release, key, token})
    settled()
  end

  test "a count is read from memory, and the open pages hear it", %{key: key} do
    :ok = Counts.put(key, 4, :attention)
    settled()

    assert Counts.all()[key] == {4, :attention}
    assert_received {:sidebar_count, ^key, 4, :attention}
  end

  test "changes within the second are held, and the last one is sent when it ends", %{key: key} do
    :ok = Counts.put(key, 1)
    :ok = Counts.put(key, 2)
    :ok = Counts.put(key, 3)
    settled()

    assert_received {:sidebar_count, ^key, 1, :plain}
    refute_received {:sidebar_count, ^key, _number, _tone}
    assert Counts.all()[key] == {3, :plain}

    end_second(key)

    assert_received {:sidebar_count, ^key, 3, :plain}
    refute_received {:sidebar_count, ^key, _number, _tone}
  end

  test "a quiet second lets the next change through at once", %{key: key} do
    :ok = Counts.put(key, 1)
    end_second(key)
    refute Map.has_key?(settled(), key)

    :ok = Counts.put(key, 0)
    settled()

    assert_received {:sidebar_count, ^key, 1, :plain}
    assert_received {:sidebar_count, ^key, 0, :plain}
  end

  test "a timer from an earlier second changes nothing", %{key: key} do
    :ok = Counts.put(key, 1)
    :ok = Counts.put(key, 2)
    send(Counts, {:release, key, make_ref()})

    assert %{^key => {_token, {:sidebar_count, ^key, 2, :plain}}} = settled()
  end
end
