defmodule MishkaCmsCore.Test.ActivityFeedHostLive do
  @moduledoc """
  A minimal stand-in for the admin pages that host the activity feed, so the
  component can be driven through `Phoenix.LiveViewTest.live_isolated/3` with a
  real socket, a real `setup/2` and a real forwarding hook — no database.

  The session carries the `setup/2` options to use (`"opts"`, a keyword list),
  letting one host cover both the default wiring and an overridden one, and the
  `:on_toggle` JS to hand `feed/1` (`"on_toggle"`), standing in for a page that
  pairs a panel of its own with the feed's. The config `setup/2` produced is
  mirrored onto `#feed-config` as data attributes so a test can assert the
  parent-side contract from the rendered page rather than from private socket
  state.
  """

  use Phoenix.LiveView

  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:current_user, session["current_user"])
     |> assign(:on_toggle, session["on_toggle"] || %JS{})
     |> ActivityFeed.setup(session["opts"] || [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div
        id="feed-config"
        data-feed-id={@activity_feed.id}
        data-limit={@activity_feed.limit}
        data-sources={inspect(@activity_feed.sources)}
        data-resources={inspect(@activity_feed.resources)}
      />
      <ActivityFeed.feed setup={@activity_feed} on_toggle={@on_toggle} />
    </div>
    """
  end
end
