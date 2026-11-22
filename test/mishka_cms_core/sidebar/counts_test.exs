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

  describe "a number for each site" do
    test "a viewer of a site reads that site's number, never another's", %{key: key} do
      :ok = Counts.put(key, 4, :plain, "site-a")
      :ok = Counts.put(key, 9, :attention, "site-b")

      assert Counts.for_viewer("site-a")[key] == {4, :plain}
      assert Counts.for_viewer("site-b")[key] == {9, :attention}
      refute Map.has_key?(Counts.for_viewer("site-c"), key)
    end

    test "a viewer with no site reads the sum, in the warning tone when any site is", %{key: key} do
      :ok = Counts.put(key, 4, :plain, "site-a")
      :ok = Counts.put(key, 9, :attention, "site-b")

      assert Counts.for_viewer(nil)[key] == {13, :attention}
      assert Counts.all()[key] == {13, :attention}
    end

    test "a number set without a site is every viewer's until a site has its own", %{key: key} do
      :ok = Counts.put(key, 2)
      assert Counts.for_viewer("site-a")[key] == {2, :plain}
      assert Counts.for_viewer(nil)[key] == {2, :plain}

      :ok = Counts.put(key, 5, :plain, "site-a")
      assert Counts.for_viewer("site-a")[key] == {5, :plain}
      assert Counts.for_viewer("site-b")[key] == {2, :plain}
    end

    test "the open pages hear a site's change, and one site's change does not hold another's",
         %{key: key} do
      :ok = Counts.put(key, 1, :plain, "site-a")
      :ok = Counts.put(key, 2, :plain, "site-b")
      :ok = Counts.put(key, 3, :plain, "site-a")
      settled()

      assert_received {:sidebar_count, ^key, 1, :plain, "site-a"}
      assert_received {:sidebar_count, ^key, 2, :plain, "site-b"}
      refute_received {:sidebar_count, ^key, 3, :plain, "site-a"}

      end_second({key, "site-a"})
      assert_received {:sidebar_count, ^key, 3, :plain, "site-a"}
    end
  end
end
