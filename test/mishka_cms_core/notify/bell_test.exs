# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Notify.BellTest do
  @moduledoc """
  The topbar bell's data source (`LiveHooks`): the unseen count and the dropdown's recent list, which
  prioritises unread notifications over already-read ones.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.{LiveHooks, Notification}

  defp mark_read_except(user, keep_unread_titles) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
    |> Enum.reject(&(&1.title in keep_unread_titles))
    |> Enum.each(fn n ->
      n
      |> Ash.Changeset.for_update(:mark_read, %{}, actor: user, tenant: user.site_id)
      |> Ash.update!()
    end)
  end

  test "recent/1 surfaces scattered unread notifications first, then fills the rest with read ones" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    for i <- 1..10, do: Notify.deliver({:user, user.id}, %{type: "test:x", title: "n#{i}"})

    # Unread is scattered across the timeline: the oldest, a middle one, and the newest.
    mark_read_except(user, ["n1", "n5", "n10"])

    recent = LiveHooks.recent(user)

    assert length(recent) == 6
    # All three scattered unread notifications lead the dropdown, ahead of any read one...
    assert recent |> Enum.take(3) |> Enum.map(& &1.title) |> Enum.sort() == ["n1", "n10", "n5"]
    assert recent |> Enum.take(3) |> Enum.all?(&is_nil(&1.read_at))
    # ...and read notifications only fill the remaining slots.
    assert recent |> Enum.drop(3) |> Enum.all?(&(!is_nil(&1.read_at)))
  end

  test "recent/1 and unread_count/1 are empty for a signed-out user" do
    assert LiveHooks.recent(nil) == []
    assert LiveHooks.unread_count(nil) == 0
  end

  test "unread_count/1 counts only unread rows and drops as they are read" do
    site = create_site!()
    user = create_user!(site_id: site.id)

    for i <- 1..3, do: Notify.deliver({:user, user.id}, %{type: "t:x", title: "n#{i}"})
    assert LiveHooks.unread_count(user) == 3

    mark_read_except(user, ["n1", "n2"])
    assert LiveHooks.unread_count(user) == 2
  end
end
