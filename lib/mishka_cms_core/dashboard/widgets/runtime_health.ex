# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dashboard.Widgets.RuntimeHealth do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): Oban job health — how many compile/runtime jobs
  are running, retrying, or failed. Counts the `Oban.Job` table via `Oban.Repo.one(Oban.config(), q)`
  (Oban has no read API). A master counts every job; a tenant admin only jobs carrying their site
  in `args.data.site_id` (how the runtime workers address a site).
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 98}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  import Ecto.Query

  alias MishkaCmsCore.Dashboard.Widget

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "runtime-health",
        priority: 200,
        default_hidden: true,
        title: gettext_noop("Runtime health"),
        component: {__MODULE__, :render},
        permission: {:under, "admin:dashboard"},
        icon: "hero-bolt",
        link: "/admin/dashboard/runtime/activity"
      })

    widget
  end

  @doc "Loads this widget's data off the dashboard render (in a Task), scoped to the viewer."
  def load(user) do
    scope = Widget.scope(user)

    %{
      in_progress: count_jobs(["executing", "available", "scheduled"], scope),
      retrying: count_jobs(["retryable"], scope),
      failed: count_jobs(["retryable", "discarded"], scope)
    }
  end

  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-3">
      <Widget.stat
        label={gettext("Running")}
        value={@data.in_progress}
        icon="hero-play-circle"
        tone={:sky}
      />
      <Widget.stat
        label={gettext("Retrying")}
        value={@data.retrying}
        icon="hero-arrow-path"
        tone={:amber}
      />
      <Widget.stat
        label={gettext("Failed")}
        value={@data.failed}
        icon="hero-exclamation-triangle"
        tone={:rose}
      />
    </div>
    """
  end

  defp count_jobs(states, nil) do
    query = from(j in Oban.Job, where: j.state in ^states, select: count())
    Oban.Repo.one(Oban.config(), query) || 0
  end

  defp count_jobs(states, site_id) do
    query =
      from(j in Oban.Job,
        where: j.state in ^states,
        where: fragment("?->'data'->>'site_id' = ?", j.args, ^site_id),
        select: count()
      )

    Oban.Repo.one(Oban.config(), query) || 0
  end
end
