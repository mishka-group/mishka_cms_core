# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Notify.Workers.PruneWorker do
  @moduledoc """
  Nightly retention sweep (Oban Cron). One bulk `:prune` across all sites keeps the table small no
  matter how many notifications are produced — read rows are dropped after `notify.retention_read_days`
  and everything after the hard cap `notify.retention_max_days` (both admin-editable Settings).

  Runs unscoped (`tenant: nil` on a `global? true` resource → all sites) with `authorize?: false`,
  streaming so a huge backlog prunes in constant memory. A single bulk sweep is used instead of
  per-record ash_oban triggers (house style).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Settings

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    read_days = Settings.get("notify.retention_read_days", 30)
    max_days = Settings.get("notify.retention_max_days", 180)

    Notification
    |> Ash.Query.for_read(:prunable, %{
      read_before: DateTime.add(now, -read_days * 86_400, :second),
      max_before: DateTime.add(now, -max_days * 86_400, :second)
    })
    |> Ash.bulk_destroy(:prune, %{}, authorize?: false, return_errors?: true)

    :ok
  end
end
