# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Notify.PruneTest do
  @moduledoc """
  Phase 3 — retention. The nightly sweep keeps the table small no matter how many notifications are
  produced. We exercise the `:prunable` read + bulk destroy directly (the worker just feeds it the
  Settings windows) and confirm the worker runs and spares recent rows.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Notify.Workers.PruneWorker

  @content %{type: "test:event", title: "hi"}

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  defp prune(read_before, max_before) do
    Notification
    |> Ash.Query.for_read(:prunable, %{read_before: read_before, max_before: max_before})
    |> Ash.bulk_destroy(:prune, %{}, authorize?: false, return_errors?: true)
  end

  test "prunes rows past the hard cap, across sites (unscoped)" do
    site = create_site!()
    user = create_user!(site_id: site.id)
    Notify.deliver({:user, user.id}, @content)
    assert length(feed(user)) == 1

    # A future cutoff makes every current row prunable.
    future = DateTime.add(DateTime.utc_now(), 86_400, :second)
    prune(future, future)

    assert feed(user) == []
  end

  test "keeps rows still within the window" do
    site = create_site!()
    user = create_user!(site_id: site.id)
    Notify.deliver({:user, user.id}, @content)

    past = DateTime.add(DateTime.utc_now(), -86_400, :second)
    prune(past, past)

    assert length(feed(user)) == 1
  end

  test "the worker runs and spares recent notifications (default 30/180 day windows)" do
    site = create_site!()
    user = create_user!(site_id: site.id)
    Notify.deliver({:user, user.id}, @content)

    assert :ok = PruneWorker.perform(%Oban.Job{args: %{}})
    assert length(feed(user)) == 1
  end
end
