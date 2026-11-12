# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Sidebar.CountsTest do
  @moduledoc """
  The numbers sidebar entries show, kept in memory for a page that mounts.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Sidebar.Counts

  test "a count is read from memory, the last one put winning" do
    key = "probe.count.#{System.unique_integer([:positive])}"

    :ok = Counts.put(key, 4, :attention)
    :ok = Counts.put(key, 5)

    assert Counts.all()[key] == {5, :plain}
  end
end
