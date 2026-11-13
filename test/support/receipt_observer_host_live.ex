# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.ReceiptObserverHostLive do
  @moduledoc """
  A LiveView that listens on the topic its session names and mounts
  `MishkaCmsCore.Agent.UiObserver`, as an admin list page would, so a receipt's `:ui_observed`
  stage can be driven through `Phoenix.LiveViewTest.live_isolated/3`. It counts the broadcasts it
  handled, which is all it shows.
  """
  use Phoenix.LiveView

  on_mount MishkaCmsCore.Agent.UiObserver

  @impl true
  def mount(_params, %{"topic" => topic}, socket) do
    if connected?(socket), do: MishkaCmsCore.TestEndpoint.subscribe(topic)
    {:ok, assign(socket, :seen, 0)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, socket),
    do: {:noreply, update(socket, :seen, &(&1 + 1))}

  @impl true
  def render(assigns), do: ~H|<p id="seen">{@seen}</p>|
end
