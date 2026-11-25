# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index do
  @moduledoc """
  Admin activity-log page at `/admin/dashboard/runtime/activity`. Mounts the
  standard `MishkaGervaz.Table.Web.Live` over `MishkaCmsCore.Activity.ActivityEntry`
  — a read-only resource whose manual read merges AshPaperTrail + AshEvents + Oban
  into one filterable, paginated timeline.

  Renders from the sibling `index.html.heex`.

  ## Skipping a failed job

  A failed job's Skip (the resource's `:skip_job` row action) opens
  `MishkaCmsCoreWeb.Live.Admin.Components.SkipQuestion` for an optional reason; its button skips the
  job (`MishkaCmsCore.Activity.Sources.Oban.skip/3`) and shows a toast whose Undo brings it back
  (`MishkaGervaz.Toast`, answered in `handle_info({:toast_undo, ...})`). A skipped job's Bring back
  (`:bring_back_job`) brings it back at once. Every open log of the job's site, this one included,
  hears the change on `MishkaCmsCore.Skip.topic/0` and reads its rows and counts again.

  ## A union source's new rows

  The core's records reach the page as they change. A union source's table is the extension's own,
  so it says when it wrote rows (`MishkaCmsCore.Activity.Behaviours.UnionSource.changed/1`), and
  the page reads its first page and counts again. The changes that wait in the page's mailbox
  together are one read: the first asks for it with a message to itself, which the page answers after
  the ones already waiting, and those ask for nothing more.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Activity.{ActivityEntry, Helpers, Query}
  alias MishkaCmsCore.Activity.Behaviours.UnionSource
  alias MishkaCmsCore.Activity.Events.SearchAsTyped
  alias MishkaCmsCore.Activity.Sources.{EventLog, Oban, RuntimeDraft, PaperTrail}
  alias MishkaCmsCore.Layouts.TopbarNeeds
  alias MishkaCmsCore.Skip
  alias MishkaCmsCoreWeb.Live.Admin.Components.{ActivityFeed, SkipQuestion}
  alias MishkaGervaz.Table.Web.UrlSync
  alias MishkaGervaz.Toast

  @sources [PaperTrail, EventLog, Oban, RuntimeDraft]
  @table_id "activity-table"

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_new(socket, :current_user, fn -> nil end)
    resources = Helpers.resources_for(socket.assigns.current_user)

    if connected?(socket) do
      for topic <- ActivityFeed.topics_for(socket.assigns.current_user, @sources, nil) do
        Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
      end

      Skip.subscribe()
      UnionSource.subscribe(socket.assigns.current_user)
    end

    new_socket =
      socket
      |> Toast.attach()
      |> assign(:resources, resources)
      |> assign(:page_title, gettext("Activity Logs"))
      |> assign(:url_state, nil)
      |> assign(:counts, nil)
      |> assign(:skip_job, nil)
      |> assign(:reread?, false)
      |> load_counts()

    {:ok, new_socket}
  end

  @doc """
  The KPI totals, off the render path: each is a COUNT over the same union the table reads, so four
  of them should never hold the timeline up.
  """
  @impl true
  def handle_async(:counts, {:ok, counts}, socket),
    do: {:noreply, assign(socket, :counts, counts)}

  def handle_async(:counts, {:exit, _reason}, socket), do: {:noreply, socket}

  # Scoped to the viewer's sites and areas by `ActivityEntry.counts/1`, as the table is.
  defp load_counts(socket) do
    user = socket.assigns[:current_user]

    if connected?(socket),
      do:
        MishkaGervaz.Messages.start_async(socket, :counts, fn -> ActivityEntry.counts(user) end),
      else: socket
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state =
      params
      |> UrlSync.decode(uri, ActivityEntry)
      |> SearchAsTyped.keep_search(params)

    {:noreply, assign(socket, :url_state, url_state)}
  end

  # Bridge live activity broadcasts → the gervaz table. We wrap the merged entry
  # as a synthetic `ActivityEntry` notification so the table's `on_realtime` hook
  # (which halts the default `Ash.get`-based reload) can stream-insert it.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{} = msg, socket) do
    case shown_entry(msg, socket.assigns.resources) do
      nil ->
        {:noreply, socket}

      entry ->
        notification = %Ash.Notifier.Notification{
          resource: ActivityEntry,
          action: %{name: :create, type: :create},
          data: ActivityEntry.from_entry(entry)
        }

        send_update(MishkaGervaz.Table.Web.Live, id: @table_id, pubsub_notification: notification)
        {:noreply, load_counts(socket)}
    end
  end

  def handle_info({:row_action, "skip_job", %{"id" => id}}, socket),
    do: {:noreply, assign(socket, :skip_job, Oban.job_id(id))}

  def handle_info({:row_action, "bring_back_job", %{"id" => id}}, socket),
    do: {:noreply, bring_back(socket, Oban.job_id(id))}

  def handle_info({:toast_undo, {:bring_back_job, job_id}}, socket),
    do: {:noreply, bring_back(socket, job_id)}

  def handle_info({:skip_changed, %{source: "core:job", site_id: site_id}}, socket) do
    case TopbarNeeds.concerns?(socket.assigns.current_user, site_id) do
      true ->
        send_update(MishkaGervaz.Table.Web.Live, id: @table_id, gervaz_refresh: true)
        {:noreply, load_counts(socket)}

      false ->
        {:noreply, socket}
    end
  end

  def handle_info({:activity_changed, _site_id}, %{assigns: %{reread?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:activity_changed, _site_id}, socket) do
    send(self(), :reread_activity)
    {:noreply, assign(socket, :reread?, true)}
  end

  def handle_info(:reread_activity, socket) do
    send_update(MishkaGervaz.Table.Web.Live, id: @table_id, gervaz_refresh: true)

    new_socket =
      socket
      |> assign(:reread?, false)
      |> load_counts()

    {:noreply, new_socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("skip_cancel", _params, socket), do: {:noreply, assign(socket, :skip_job, nil)}

  def handle_event("skip_confirm", params, %{assigns: %{skip_job: job_id}} = socket)
      when is_integer(job_id) do
    socket = assign(socket, :skip_job, nil)

    new_socket =
      case Oban.skip(socket.assigns.current_user, job_id, params["reason"]) do
        {:ok, _job} ->
          Toast.push(socket, :info, gettext("Job skipped. It will not be tried again."),
            undo: {:bring_back_job, job_id}
          )

        {:error, reason} ->
          Toast.push(socket, :error, refusal(reason))
      end

    {:noreply, new_socket}
  end

  def handle_event("skip_confirm", _params, socket),
    do: {:noreply, assign(socket, :skip_job, nil)}

  defp bring_back(socket, job_id) do
    case Oban.bring_back(socket.assigns.current_user, job_id) do
      {:ok, _job} ->
        Toast.push(socket, :ok, gettext("Job brought back. It counts as failed again."))

      {:error, reason} ->
        Toast.push(socket, :error, refusal(reason))
    end
  end

  defp refusal(:forbidden), do: gettext("You may not change this job.")
  defp refusal(:not_found), do: gettext("This job is no longer there.")
  defp refusal(:not_failed), do: gettext("Only a failed job can be skipped.")
  defp refusal(:not_skipped), do: gettext("This job is not skipped.")

  # A live entry of an area the viewer does not hold is not shown, and one whose resource the
  # broadcast does not name is shown to a full dashboard admin alone.
  defp shown_entry(msg, resources) do
    case Helpers.shows?(resources, broadcast_resource(msg)) do
      true -> ActivityFeed.first_source_entry(msg, @sources)
      false -> nil
    end
  end

  defp broadcast_resource(%{payload: %Ash.Notifier.Notification{resource: resource}}),
    do: resource

  defp broadcast_resource(_msg), do: nil

  @doc "The KPI row: `{label, counts key, label classes, dot classes}`; the total carries no dot."
  def kpi_cards do
    [
      {gettext("Total events"), :total, "text-[#a8a5a0]", nil},
      {gettext("Info"), :info, "text-[#177a53]", "bg-[#1f9d6b]"},
      {gettext("Warning"), :warn, "text-[#a5691a]", "bg-[#cf8a24]"},
      {gettext("Error"), :error, "text-[#b3433a]", "bg-[#d5544b]"},
      {gettext("Skipped"), :skipped, "text-[#8a877f]", "bg-[#a8a5a0]"}
    ]
  end

  @doc """
  A count with thousands separators — `1284` reads as `1,284`. A count that reached the query's scan
  cap is only a floor, so it reads `10,000+` rather than claiming an exact total.
  """
  def delimited(number) when is_integer(number) do
    suffix = if number >= Query.max_cap(), do: "+", else: ""
    MishkaCmsCore.Localized.number(number) <> suffix
  end

  def delimited(_number), do: "0"
end
