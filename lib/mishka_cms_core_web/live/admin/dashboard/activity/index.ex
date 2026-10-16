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
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Activity.{ActivityEntry, Helpers, Query}
  alias MishkaCmsCore.Activity.Sources.{EventLog, Oban, RuntimeDraft, PaperTrail}
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaGervaz.Table.Web.UrlSync

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
    end

    {:ok,
     socket
     |> assign(:resources, resources)
     |> assign(:page_title, gettext("Activity Logs"))
     |> assign(:url_state, nil)
     |> assign(:counts, nil)
     |> load_counts()}
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
    url_state = UrlSync.decode(params, uri, ActivityEntry)
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

  def handle_info(_msg, socket), do: {:noreply, socket}

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
      {gettext("Error"), :error, "text-[#b3433a]", "bg-[#d5544b]"}
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
