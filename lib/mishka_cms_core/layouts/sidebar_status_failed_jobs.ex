# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.SidebarStatus.FailedJobs do
  @moduledoc """
  The core's own line on `"sidebar:status"` (`MishkaCmsCore.Layouts.SidebarStatus`): how many
  background jobs were given up on (Oban's `discarded`) in the window, "8 failed jobs", linking to
  the activity log filtered to failed background jobs. A site admin counts their own site's jobs,
  a master every site's (`MishkaCmsCore.Activity.Sources.Oban.failed_count/2`); a job that names no
  site counts for a master only. It is for whoever may open the activity log
  (`admin:dashboard:runtime:activity`): for such a viewer it marks the data `checked: true` whether
  or not a job failed, so the sidebar can say "All clear"; for anyone else it reads nothing and
  marks nothing.

  One count on the jobs table, kept for the cache's short while (`SidebarStatus.cached/2`) and
  dropped when a job is given up on (`MishkaCmsCore.Activity.Sources.Oban` calls
  `SidebarStatus.changed/1`). A retryable job is not counted: it runs again, and the log's
  failed filter does not list it.
  """
  use MishkaInstaller.Event.Hook, event: "sidebar:status", initial: %{priority: 10}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.Sources.Oban, as: ObanActivity
  alias MishkaCmsCore.Layouts.SidebarStatus
  alias MishkaCmsCore.Settings

  @permission "admin:dashboard:runtime:activity"
  @link "/admin/dashboard/runtime/activity?activity_filter_kind=job&activity_filter_severity=error"

  @doc "The activity log filtered to the failed background jobs, where the line leads."
  @spec link() :: String.t()
  def link, do: @link

  @impl true
  def call(%{lines: lines, current_user: user, since: since} = data) when not is_nil(user) do
    with true <- Settings.permitted?(%{permission: @permission}, user),
         count when count > 0 <- count(user, since) do
      line = %{
        id: "core-failed-jobs",
        level: :error,
        label: ngettext("%{count} failed job", "%{count} failed jobs", count),
        count: count,
        link: @link,
        permission: @permission,
        site_id: user.site_id
      }

      {:reply, %{data | lines: lines ++ [line], checked: true}}
    else
      0 -> {:reply, %{data | checked: true}}
      false -> {:reply, data}
    end
  end

  def call(data), do: {:reply, data}

  defp count(user, since) do
    SidebarStatus.cached({user.site_id, :core_failed_jobs}, fn ->
      ObanActivity.failed_count(user, states: ["discarded"], since: since)
    end)
  end
end
