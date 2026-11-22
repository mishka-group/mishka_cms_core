# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Plugins.TopbarNeedsProbe do
  @moduledoc """
  Test plugin on `topbar:needs`: a refund item whose count a test sets with `put_count/1`, an item
  behind a permission the test admin does not hold, an item of 0, an item linking to another site
  and a second item reusing a taken id. The refund item and the one of another site are the only
  ones the bell may list, the second with no link. The refund item is in the group "Probe shop"; the
  others name none, so they fall in the core's group.
  """
  use MishkaInstaller.Event.Hook, event: "topbar:needs"

  @count {__MODULE__, :count}

  @doc "Sets the refund item's count until the test ends."
  def put_count(count), do: :persistent_term.put(@count, count)

  @doc "Forgets the count a test set."
  def reset, do: :persistent_term.erase(@count)

  @impl true
  def call(%{needs: needs} = data) do
    mine = [
      %{
        id: "probe-refunds",
        title: "A buyer asks for a refund",
        detail: "MS-4806 · wants Team instead",
        count: :persistent_term.get(@count, 3),
        tone: :warn,
        link: "/admin/dashboard/settings",
        priority: 10,
        group: "Probe shop",
        group_id: "probe"
      },
      %{id: "probe-gated", title: "Gated", count: 4, permission: "admin:api:probe"},
      %{id: "probe-zero", title: "Nothing", count: 0},
      %{id: "probe-away", title: "Elsewhere", count: 1, link: "//evil.com/steal"},
      %{id: "probe-refunds", title: "Twice", count: 9}
    ]

    {:reply, %{data | needs: needs ++ mine}}
  end
end
