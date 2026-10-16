# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index do
  @moduledoc """
  The signed-in user's notification inbox at `/admin/dashboard/notifications`.

  A thin shell over a MishkaGervaz table: the table (columns, filters, row/bulk actions, pagination,
  the card template) is declared on the `MishkaCmsCore.Notify.Notification` resource, so the inbox
  gets Ash-backed filtering/sorting/pagination for free and the per-user policy keeps a user to their
  own rows. Mark-read/unread and delete run as the resource's Ash actions through Gervaz — no
  per-action wiring here; reading a row decrements the topbar bell's unread badge.

  See `MishkaCmsCore.Notify.Notification` (the `mishka_gervaz` block) and
  `MishkaCmsCoreWeb.Templates.NotificationCard` (the card layout).
  """

  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Notify.Notification
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Notifications")) |> assign(:url_state, nil)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, assign(socket, :url_state, UrlSync.decode(params, uri, Notification))}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div>
        <div class="mb-6 flex flex-wrap items-start justify-between gap-5">
          <div>
            <div class="mb-2 text-[11.5px] font-semibold uppercase tracking-[0.14em] text-[#5b57d6]">
              {gettext("Inbox")}
            </div>
            <h1 class="m-0 font-['Newsreader'] text-[32px] font-medium leading-[1.05] tracking-[-0.01em] text-[#17161a]">
              {gettext("Notifications")}
            </h1>
            <div class="mt-2 text-[13.5px] font-medium text-[#7c7a75]">
              {gettext("Everything addressed to you.")}
            </div>
          </div>

          <button
            id="notifs-mark-all-read"
            type="button"
            phx-click="notify_read_all"
            class="flex h-10 items-center gap-2 rounded-[11px] border border-[#ecebe6] bg-white px-4 text-[12.5px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
          >
            <.icon name="hero-check" class="size-[15px]" /> {gettext("Mark all read")}
          </button>
        </div>

        <.live_component
          module={MishkaGervaz.Table.Web.Live}
          id="notifications-table"
          resource={MishkaCmsCore.Notify.Notification}
          current_user={@current_user}
          url_state={@url_state}
        />
      </div>
    </div>
    """
  end
end
