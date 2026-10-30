# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Notify.LiveHooks do
  @moduledoc """
  `on_mount` hook that makes the topbar bell live for the current user — with zero per-page wiring.

  It never blocks the page: mount assigns an empty bell (`notification_count: 0`, `notification_recent:
  []`) and defers the query to a post-mount message (loaded async, off the render path). It subscribes
  to the user's own `notification:<user_id>:*` PubSub topics and attaches two hooks: a `:handle_info`
  hook that re-counts on any of those broadcasts, and a `:handle_event` hook so the dropdown's actions
  — open a notification, mark one read, mark all read — work on every admin page.

  The badge counts **unread** notifications (`read_at IS NULL`); reading (per row, all, or by opening)
  decrements it live. Attached right after `MishkaCmsCore.Layouts.Nav` in
  `MishkaCmsCore.ExtensionLiveView`, so it overrides Nav's placeholder count. Subscribes on
  `MishkaCmsCore.PubSub`, matching the resource's `Ash.Notifier.PubSub` topics.
  """

  import Phoenix.LiveView,
    only: [connected?: 1, attach_hook: 4, navigation_type: 2, push_navigate: 2, redirect: 2]

  import Phoenix.Component, only: [assign: 2]

  require Ash.Query

  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Notify.Notification

  @recent_limit 6

  def on_mount(:default, _params, _session, socket) do
    socket = assign(socket, notification_count: 0, notification_recent: [])

    socket =
      if connected?(socket) && socket.assigns[:current_user] do
        user = socket.assigns.current_user
        Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "notification:#{user.id}:created")
        Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "notification:#{user.id}:updated")
        send(self(), :notify_refresh_count)
        socket
      else
        socket
      end

    {:cont,
     socket
     |> attach_hook(:notify_bell, :handle_info, &handle_message/2)
     |> attach_hook(:notify_bell_actions, :handle_event, &handle_action/3)}
  end

  # The bell owns the user's notification topics; halt so a page without a matching handle_info
  # clause never sees them.
  defp handle_message(:notify_refresh_count, socket), do: {:halt, refresh(socket)}

  defp handle_message(%Phoenix.Socket.Broadcast{topic: "notification:" <> _}, socket),
    do: {:halt, refresh(socket)}

  defp handle_message(_msg, socket), do: {:cont, socket}

  # Bell-dropdown actions, available on every admin page. Opening a notification reads it then
  # navigates to its link; the per-row check reads it in place (no redirect); "mark all read" clears
  # every unread row. Non-bell events fall through untouched.
  defp handle_action("notify_open", %{"id" => id} = params, socket) do
    read_one(socket.assigns[:current_user], id)
    {:halt, socket |> refresh() |> open_link(params["link"])}
  end

  defp handle_action("notify_read", %{"id" => id}, socket) do
    read_one(socket.assigns[:current_user], id)
    {:halt, refresh(socket)}
  end

  defp handle_action("notify_read_all", _params, socket) do
    Notify.mark_all_read(socket.assigns[:current_user])
    {:halt, refresh(socket)}
  end

  defp handle_action(_event, _params, socket), do: {:cont, socket}

  # A NOTIFICATION LINKS WHEREVER ITS PRODUCER POINTED IT, and the bell is on every admin page.
  # LiveView navigates live only inside the page's own live_session: the visual editor, for one,
  # is in a session of its own, and a live navigation into it from the bell was refused by the
  # server and retried by the browser as a page load, logging "unauthorized live_redirect" on the
  # way. The router answers which kind of link it is, so a page outside the session gets a plain
  # redirect and one inside keeps the live navigation. A link that is not a path of this app goes
  # nowhere: it arrives from the browser, and `link` is documented as an internal path.
  defp open_link(socket, "/" <> _path = link) do
    cond do
      String.starts_with?(link, "//") or String.contains?(link, "\\") -> socket
      navigation_type(socket, link) == :href -> redirect(socket, to: link)
      true -> push_navigate(socket, to: link)
    end
  end

  defp open_link(socket, _link), do: socket

  defp refresh(socket) do
    user = socket.assigns[:current_user]
    assign(socket, notification_count: unread_count(user), notification_recent: recent(user))
  end

  # Read only if still unread, so re-clicking never rewrites an existing read timestamp.
  defp read_one(nil, _id), do: :ok

  defp read_one(user, id) do
    case Ash.get(Notification, id, actor: user, tenant: user.site_id) do
      {:ok, %{read_at: nil} = record} ->
        record
        |> Ash.Changeset.for_update(:mark_read, %{}, actor: user, tenant: user.site_id)
        |> Ash.update!()

      _ ->
        :ok
    end
  end

  @doc "The current user's unread-notification count (0 when signed out)."
  def unread_count(nil), do: 0

  def unread_count(user) do
    Notification
    |> Ash.Query.for_read(:unread_count)
    |> Ash.count!(actor: user, tenant: user.site_id)
  end

  @doc """
  The current user's notifications for the bell dropdown (empty when signed out). Unread rows take
  priority — the newest unread first, then recent already-read rows only fill the remaining slots.
  """
  def recent(nil), do: []

  def recent(user) do
    unread = recent_feed(user, :unread, @recent_limit)
    unread ++ recent_feed(user, :read, @recent_limit - length(unread))
  end

  defp recent_feed(_user, _which, limit) when limit <= 0, do: []

  defp recent_feed(user, which, limit) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> read_filter(which)
    |> Ash.read!(actor: user, tenant: user.site_id, page: [limit: limit])
    |> Map.get(:results)
  end

  defp read_filter(query, :unread), do: Ash.Query.filter(query, is_nil(read_at))
  defp read_filter(query, :read), do: Ash.Query.filter(query, not is_nil(read_at))
end
