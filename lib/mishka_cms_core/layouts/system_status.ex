# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.SystemStatus do
  @moduledoc """
  What the admin sidebar's footer says about the system, read from the system itself.

  `read/1` asks the database one question: how many background jobs the viewer may see failed in
  the last hour (`MishkaCmsCore.Activity.Sources.Oban.failed_count/2` with `since:`, every site's for
  a master, their own site's for a site user). The answer proves two things at once: the database
  answers, and the jobs run without failing. A read that raises means the database did not answer.

  `MishkaCmsCore.Layouts.Nav` reads it with `assign_async/3` when an admin page connects, as
  `@system_status`, so the check never holds a render and costs one count on the jobs table per
  page opened, none per render. `line/1` turns that `Phoenix.LiveView.AsyncResult` into what the
  footer draws:

    * no job failed: **All systems operational**;
    * some failed: **N background jobs failed in the last hour**, in the warning colour;
    * the read failed: **The database does not answer**, in the error colour;
    * still reading (the first, disconnected render): **Checking the system**.

  Nothing measures uptime, so the footer shows none.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.Sources.Oban, as: ObanActivity
  alias Phoenix.LiveView.AsyncResult

  @window_seconds 3_600

  @typedoc "What `read/1` found."
  @type t :: %{failed: non_neg_integer()}

  @typedoc "What the footer draws: its tone, its bold line and the line under it."
  @type line :: %{tone: :ok | :warn | :bad | :checking, title: String.t(), detail: String.t()}

  @doc "How many background jobs `viewer` may see failed in the last hour. Raises when the database does not answer."
  @spec read(map() | nil, DateTime.t()) :: t()
  def read(viewer, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@window_seconds, :second)
    %{failed: ObanActivity.failed_count(viewer, since: since)}
  end

  @doc "What the footer draws for the `@system_status` read; see the moduledoc."
  @spec line(AsyncResult.t() | nil) :: line()
  def line(%AsyncResult{ok?: true, result: %{failed: 0}}),
    do: %{
      tone: :ok,
      title: gettext("All systems operational"),
      detail: gettext("No background job failed in the last hour.")
    }

  def line(%AsyncResult{ok?: true, result: %{failed: failed}}),
    do: %{
      tone: :warn,
      title:
        ngettext(
          "%{count} background job failed in the last hour",
          "%{count} background jobs failed in the last hour",
          failed
        ),
      detail: gettext("The database answers. The activity log shows each failed job.")
    }

  def line(%AsyncResult{failed: failed}) when not is_nil(failed),
    do: %{
      tone: :bad,
      title: gettext("The database does not answer"),
      detail: gettext("Background jobs could not be checked.")
    }

  def line(_reading),
    do: %{
      tone: :checking,
      title: gettext("Checking the system"),
      detail: gettext("The database and the background jobs.")
    }
end
