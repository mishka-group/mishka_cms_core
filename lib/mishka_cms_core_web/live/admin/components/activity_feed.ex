# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed do
  @moduledoc """
  Real-time activity feed driven by a pluggable list of sources, rendered as a
  collapsed "Logs" toggle over a System Logs panel.

  Source adapters implement `MishkaCmsCore.Activity.Behaviours.Source`. Each adapter
  knows its own topics, broadcasts, entry shape, and initial fetch — this
  component just composes them.

  ## Usage

  Wire a page with `setup/2` and render it with `feed/1`; see `setup/2` for the
  options and the ordering rule. A page with a collapsible panel of its own pairs
  the two with `close_panel/2`, so only one of them is open at a time.

  ## Behaviour

    * The panel is collapsed on load. The toggle shows/hides it client-side with
      `Phoenix.LiveView.JS` (a fade/slide transition), and pushes to the server so
      the first open can fetch.
    * History is fetched on the FIRST open, not on mount — a page carrying a feed
      pays nothing for it until asked. Skeleton rows stand in while the fetch runs.
    * The panel does not page. It shows one window of `:limit` rows and links out
      to the full activity page, which pages properly — asking a reader to manage
      a growing preview and a full list at once was the worse of the two.
    * Live broadcasts arriving before the first open are buffered and merged into
      that first fetch — sources with no history (`RuntimeCompile`) only ever
      appear live, so dropping them on the opening fetch would lose them.

  ## Parent responsibilities

  The component runs in the parent LiveView's process, so PubSub messages
  arrive at the parent's mailbox. `setup/2` handles this; a parent driving the
  component directly must:

    1. On `mount`, subscribe to `topics_for/2,3`.
    2. Forward incoming `%Phoenix.Socket.Broadcast{}` messages to this
       component via `send_update/3`, under `:broadcast`. Use
       `handles?/2` to filter.

  See also: `MishkaCmsCore.Activity.Sources.PaperTrail`,
  `MishkaCmsCore.Activity.Sources.Oban`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Activity.Helpers
  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.JS

  @default_limit 5
  @default_sources [MishkaCmsCore.Activity.Sources.PaperTrail]

  # The transition `close_panel/2` leaves on when a page's own panel takes the feed's place. The
  # feed's own toggle needs none: its panel's `hidden` class follows the `@open?` assign.
  @panel_out {"transition-[opacity,transform] ease-in duration-150", "opacity-100 translate-y-0",
              "opacity-0 -translate-y-1"}

  # `setup/2` (the one-call parent wiring) defaults to every built-in source so
  # a resource page sees content changes AND background-job activity.
  @setup_sources [
    MishkaCmsCore.Activity.Sources.PaperTrail,
    MishkaCmsCore.Activity.Sources.EventLog,
    MishkaCmsCore.Activity.Sources.Oban,
    MishkaCmsCore.Activity.Sources.RuntimeCompile,
    MishkaCmsCore.Activity.Sources.RuntimeDraft
  ]

  @doc """
  PubSub topics the parent should subscribe to so the feed receives live
  updates. Pass the same `current_user`, `sources`, and `resources` you
  pass to the component itself.
  """
  def topics_for(current_user, sources \\ @default_sources, resources \\ nil) do
    scope = build_scope(current_user, resources)
    Enum.flat_map(sources, & &1.topics(scope))
  end

  @doc """
  True when at least one source claims ownership of the broadcast. Use in
  the parent's `handle_info/2` to decide whether to forward.
  """
  def handles?(%Phoenix.Socket.Broadcast{} = msg, sources \\ @default_sources) do
    Enum.any?(sources, & &1.handles?(msg))
  end

  @doc """
  One-call wiring for a parent LiveView. Subscribes to the activity topics for
  `opts[:resources]` and attaches a `handle_info` hook that forwards matching
  broadcasts to this component — the page's own `handle_info` clauses are left
  untouched (resource notifications pass through so the table still updates;
  Oban broadcasts are consumed here so they never reach an unmatched clause).

  Because that hook halts the Oban and runtime-compile broadcasts, any hook of
  the page's own that needs them (`RuntimeStatusLive.setup/2`,
  `PreviewHelpers.setup/1`, a site-health hook) must be attached BEFORE this one.

  Call it in `mount/3` after `current_user` is assigned, then render the feed
  with `feed/1`, passing the single `@activity_feed` assign it sets:

      socket =
        ActivityFeed.setup(socket,
          resources: [MishkaCmsCore.Runtime.Component],
          feed_id: "components-activity"
        )

      # in the template:
      <ActivityFeed.feed setup={@activity_feed} />

  ## Options

    * `:resources` — modules to scope to; omit for a site-wide feed.
    * `:feed_id` — this component's id (default `"activity-feed"`).
    * `:sources` — source adapters (default: all built-in — PaperTrail, EventLog,
      Oban, RuntimeCompile, RuntimeDraft).
    * `:limit` — how many rows the panel shows (default `#{@default_limit}`). A
      template may override it per call via
      `<ActivityFeed.feed setup={...} limit={10} />`.
  """
  def setup(socket, opts \\ []) do
    config = %{
      id: Keyword.get(opts, :feed_id, "activity-feed"),
      current_user: socket.assigns[:current_user],
      sources: Keyword.get(opts, :sources, @setup_sources),
      resources: Keyword.get(opts, :resources),
      limit: Keyword.get(opts, :limit, @default_limit)
    }

    if Phoenix.LiveView.connected?(socket) do
      for topic <- topics_for(config.current_user, config.sources, config.resources) do
        Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
      end
    end

    socket
    |> assign(:activity_feed, config)
    |> Phoenix.LiveView.attach_hook(:activity_feed_forward, :handle_info, &forward/2)
  end

  @doc """
  Renders the feed from the `@activity_feed` map produced by `setup/2`. The
  scope (`resources`/`sources`) is fixed by `setup/2` so the subscription and
  the display always agree; only `:limit` may be overridden per call.

      <ActivityFeed.feed setup={@activity_feed} />
      <ActivityFeed.feed setup={@activity_feed} limit={10} />
  """
  attr :setup, :map, required: true
  attr :limit, :integer, default: nil

  attr :on_toggle, JS,
    default: %JS{},
    doc: """
    JS to run when the feed's toggle is clicked, ahead of the panel's own transition. A page with a
    panel of its own passes the JS closing that panel, so only one is ever open; `close_panel/2` is
    the mirror image, for that panel's toggle to close the feed.
    """

  slot :toggles,
    doc: """
    Buttons that sit beside the feed's own toggle, on its row. A page with its own panel puts its
    toggle here rather than beside the feed: the feed is full width so its panel is, and wrapping it
    in a column to make room would narrow the panel too.
    """

  def feed(assigns) do
    ~H"""
    <.live_component
      module={__MODULE__}
      id={@setup.id}
      current_user={@setup.current_user}
      sources={@setup.sources}
      resources={@setup.resources}
      limit={@limit || @setup.limit}
      on_toggle={@on_toggle}
      toggles={@toggles}
    />
    """
  end

  @doc """
  JS that closes the feed's panel: the client-side hide, plus the push that tells the feed its panel
  is shut so its toggle stops reading open.

  A page with a panel of its own chains this onto that panel's toggle, and passes the reverse to
  `feed/1`'s `:on_toggle`, so opening either panel closes the other. Both halves are unconditional:
  hiding an already-hidden panel does nothing, so neither toggle has to know which panel is open.

      <ActivityFeed.feed setup={@activity_feed} on_toggle={close_issues()} />

      defp toggle_issues(setup) do
        %JS{}
        |> ActivityFeed.close_panel(setup)
        |> JS.toggle(to: "#issues-panel")
        |> JS.push("toggle_issues")
      end

  Takes the `@activity_feed` map from `setup/2`, whose `:id` names both the panel and the feed's own
  root element — the push is aimed at that root, so it reaches the component rather than the page.
  """
  def close_panel(js \\ %JS{}, setup) do
    js
    |> JS.hide(to: "##{setup.id}-panel", transition: @panel_out, time: 150)
    |> JS.push("close_logs", target: "##{setup.id}-feed")
  end

  defp forward(%Phoenix.Socket.Broadcast{payload: %{__oban__: true}} = msg, socket) do
    forward_to_feed(msg, socket)
    {:halt, socket}
  end

  defp forward(%Phoenix.Socket.Broadcast{payload: %{__runtime_compiled__: true}} = msg, socket) do
    forward_to_feed(msg, socket)
    {:halt, socket}
  end

  defp forward(%Phoenix.Socket.Broadcast{} = msg, socket) do
    forward_to_feed(msg, socket)
    {:cont, socket}
  end

  defp forward(_msg, socket), do: {:cont, socket}

  defp forward_to_feed(msg, socket) do
    config = socket.assigns.activity_feed

    if handles?(msg, config.sources) do
      Phoenix.LiveView.send_update(__MODULE__, id: config.id, broadcast: msg)
    end
  end

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:activity_count, 0)
     |> assign(:activity_last_updated_at, nil)
     |> assign(:site_names, %{})
     |> assign(:actor_names, %{})
     |> assign(:recent_logs, AsyncResult.ok(%AsyncResult{}, []))
     |> assign(:limit, @default_limit)
     |> assign(:sources, @default_sources)
     |> assign(:resources, nil)
     |> assign(:open?, false)
     |> assign(:loaded?, false)
     |> assign(:on_toggle, %JS{})
     |> assign(:toggles, [])
     |> assign(:page, 1)
     |> assign(:pending, [])
     |> stream_configure(:logs_stream, dom_id: &"activity-#{&1.id}")
     |> stream(:logs_stream, [])}
  end

  @impl true
  def update(%{broadcast: %Phoenix.Socket.Broadcast{} = msg}, socket) do
    {:ok, route_broadcast(socket, msg)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign(:limit, Map.get(socket.assigns, :limit, @default_limit))
     |> assign(:sources, Map.get(socket.assigns, :sources, @default_sources))
     |> assign(:resources, Map.get(socket.assigns, :resources, nil))}
  end

  @impl true
  def handle_event("toggle_logs", _params, socket) do
    {:noreply, socket |> assign(:open?, !socket.assigns.open?) |> maybe_load()}
  end

  @doc """
  Closes the panel without regard to what it was doing, so a page that closed it client-side to make
  room for its own panel can say so. Unlike `"toggle_logs"` this is not a flip: a page fires it on
  every one of its own opens, whether the feed was open or not.
  """
  def handle_event("close_logs", _params, socket) do
    {:noreply, assign(socket, :open?, false)}
  end

  @impl true
  def handle_async(:load_recent_activity, {:ok, result}, socket) do
    %{page: page, window: window, entries: fetched} = result
    entries = merge_pending(socket.assigns.pending, fetched, window)

    {:noreply,
     socket
     |> assign(:loaded?, true)
     |> assign(:pending, [])
     |> assign(:page, page)
     |> assign(:site_names, result.site_names)
     |> assign(:actor_names, Map.merge(socket.assigns.actor_names, result.actor_names))
     |> assign(:recent_logs, AsyncResult.ok(socket.assigns.recent_logs, entries))
     |> stream(:logs_stream, entries, reset: true, limit: window)
     |> assign(:activity_count, length(entries))
     |> assign(:activity_last_updated_at, last_updated_at(entries))}
  end

  @doc """
  A failed fetch still opens the feed to whatever arrives live.

  The history could not be read, but broadcasts keep coming, and they are the only entries this feed
  will ever have. Leaving `loaded?` false would buffer every one of them into `:pending` while the
  header went on counting them — a list that says "3 entries" and shows none.
  """
  def handle_async(:load_recent_activity, {:exit, reason}, socket) do
    window = window(socket)
    pending = Enum.take(socket.assigns.pending, window)

    {:noreply,
     socket
     |> assign(:loaded?, true)
     |> assign(:pending, [])
     |> assign(:recent_logs, AsyncResult.failed(socket.assigns.recent_logs, {:exit, reason}))
     |> stream(:logs_stream, pending, reset: true, limit: window)
     |> assign(:activity_count, length(pending))
     |> assign(:activity_last_updated_at, last_updated_at(pending))}
  end

  defp maybe_load(%{assigns: %{open?: true, loaded?: false}} = socket) do
    if loading?(socket), do: socket, else: load_page(socket, 1)
  end

  defp maybe_load(socket), do: socket

  defp load_page(socket, page) do
    %{current_user: user, sources: sources, resources: resources, limit: limit} = socket.assigns
    window = page * limit
    scope = build_scope(user, resources)

    socket
    |> assign(:recent_logs, AsyncResult.loading(socket.assigns.recent_logs))
    |> MishkaGervaz.Messages.start_async(:load_recent_activity, fn ->
      entries = fetch_recent_activity(sources, scope, window)

      %{
        page: page,
        window: window,
        entries: entries,
        site_names: load_site_names(user),
        actor_names: entries |> Enum.map(& &1.user_id) |> Helpers.actor_labels(user)
      }
    end)
  end

  defp loading?(socket), do: !!socket.assigns.recent_logs.loading

  defp merge_pending([], fetched, _window), do: fetched

  defp merge_pending(pending, fetched, window) do
    (pending ++ fetched)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(window)
  end

  defp window(%{assigns: %{page: page, limit: limit}}), do: page * limit

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"#{@id}-feed"} class="contents">
      <div class="flex flex-wrap justify-end gap-2.5">
        <button
          type="button"
          id={"#{@id}-toggle"}
          phx-click={toggle_logs(@id, @myself, @on_toggle)}
          aria-expanded={to_string(@open?)}
          aria-controls={"#{@id}-panel"}
          class={[
            "inline-flex h-9 items-center gap-2 rounded-[11px] border bg-white px-3.5 text-[12.5px] font-semibold text-[#3a382f] shadow-[0_1px_2px_rgba(30,28,24,0.04)] transition-colors hover:bg-[#f7f6f3]",
            (@open? && "border-[#dcdbf5]") || "border-[#ecebe6]"
          ]}
        >
          <span class="font-['Space_Grotesk'] text-[12.5px] font-bold text-[#8a877f]">&gt;_</span>
          {gettext("Logs")}
          <span
            :if={@activity_count > 0}
            class="rounded-[20px] bg-[#f4f3ef] px-2 py-0.5 font-['Space_Grotesk'] text-[10px] font-bold text-[#8a877f]"
          >
            {@activity_count}
          </span>
          <.icon
            name="hero-chevron-down"
            class={"size-3.5 text-[#a8a5a0] transition-transform #{if @open?, do: "rotate-180"}"}
          />
        </button>
        {render_slot(@toggles)}
      </div>

      <section
        id={"#{@id}-panel"}
        class={[
          "mt-3 basis-full overflow-hidden rounded-2xl border border-[#ecebe6] bg-white shadow-[0_1px_2px_rgba(30,28,24,0.04)]",
          !@open? && "hidden"
        ]}
      >
        <div class="flex items-center gap-2 border-b border-[#f0efea] px-[18px] py-3.5">
          <span class="font-['Space_Grotesk'] text-[13px] font-bold text-[#8a877f]">&gt;_</span>
          <span class="font-['Space_Grotesk'] text-[13px] font-bold text-[#17161a]">
            {gettext("System Logs")}
          </span>
          <span class="text-[12px] font-medium text-[#a8a5a0]">
            {ngettext("%{count} entry", "%{count} entries", @activity_count)}
          </span>
        </div>

        <div id={"#{@id}-list"} phx-update="stream">
          <div
            :for={{dom_id, entry} <- @streams.logs_stream}
            id={dom_id}
            class="flex items-start gap-3 border-b border-[#f4f3ef] px-[18px] py-[13px] transition-colors hover:bg-[#faf9f6]"
          >
            <span class={["mt-[5px] size-2 flex-none rounded-full", dot_class(entry.severity)]} />

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <time
                  datetime={Calendar.strftime(entry.inserted_at, "%Y-%m-%dT%H:%M:%S")}
                  class="font-['Space_Grotesk'] text-[11px] font-medium text-[#8a877f]"
                >
                  {Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S")}
                </time>

                <span class={[
                  "rounded-[5px] px-[7px] py-0.5 text-[8.5px] font-bold uppercase tracking-[0.05em]",
                  tone_class(entry.badge_tone)
                ]}>
                  {entry.badge_label}
                </span>

                <span
                  :if={entry.severity != :info}
                  class={[
                    "rounded-[5px] px-[7px] py-0.5 text-[8.5px] font-bold uppercase tracking-[0.05em]",
                    severity_class(entry.severity)
                  ]}
                >
                  {severity_label(entry.severity)}
                </span>

                <span class="text-[11px] font-medium text-[#8a877f]">{gettext("on")}</span>
                <span class="text-[11px] font-bold text-[#3a382f]">{entry.resource_label}</span>

                <span class="inline-flex items-center gap-1 rounded-[20px] bg-[#eeedfb] px-[9px] py-[3px] text-[10.5px] font-semibold text-[#4f4bcc]">
                  <.icon name="hero-globe-alt" class="size-[11px]" />
                  {site_name(@site_names, entry.site_id)}
                </span>
              </div>

              <div class="mt-[5px] truncate text-[12.5px] font-semibold text-[#1b1a18]">
                {entry.message}
              </div>

              <div class="mt-1 flex flex-wrap items-center gap-2.5">
                <span
                  id={"#{dom_id}-actor"}
                  class="inline-flex items-center gap-[5px] text-[11px] font-medium text-[#8a877f]"
                >
                  <.icon name="hero-user-circle" class="size-3 text-[#a8a5a0]" />
                  <span dir="auto">{Helpers.actor_label(@actor_names, entry.user_id)}</span>
                </span>
                <span
                  :if={entry.source_id}
                  dir="ltr"
                  class="font-['Space_Grotesk'] text-[10.5px] font-medium text-[#a8a5a0]"
                  title={entry.source_id}
                >
                  #{String.slice(entry.source_id, 0, 8)}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- `@loaded?` gates this, not `loading`: the panel opens client-side a round trip before the
              fetch is even asked for, so a skeleton waiting on `loading` paints nothing on the way in.
              Rendering it until the first result lands means it is already there when the panel opens. --%>
        <div :if={!@loaded?} id={"#{@id}-skeleton"} class="animate-pulse">
          <div
            :for={row <- 1..5}
            id={"#{@id}-skeleton-#{row}"}
            class="flex items-start gap-3 border-b border-[#f4f3ef] px-[18px] py-[13px]"
          >
            <span class="mt-[5px] size-2 flex-none rounded-full bg-[#e8e7e2]" />
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class="h-3 w-[118px] rounded bg-[#eeedea]" />
                <span class="h-3 w-[52px] rounded bg-[#f0efeb]" />
                <span class="h-3 w-[74px] rounded bg-[#f0efeb]" />
              </div>
              <div class="mt-[7px] h-3.5 w-[62%] rounded bg-[#eeedea]" />
              <div class="mt-[7px] h-3 w-[38%] rounded bg-[#f2f1ee]" />
            </div>
          </div>
        </div>

        <div
          :if={@recent_logs.failed}
          class="flex flex-col items-center justify-center gap-3 py-11 text-center"
        >
          <span class="grid size-[52px] place-items-center rounded-[14px] bg-[#fbe9e7] text-[#b3433a]">
            <.icon name="hero-exclamation-triangle" class="size-6" />
          </span>
          <div>
            <div class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
              {gettext("Could not load activity")}
            </div>
            <div class="mt-[3px] text-[12px] font-medium text-[#8a877f]">
              {gettext("Reopen the panel to try again.")}
            </div>
          </div>
        </div>

        <%!-- `@loaded?` gates this, not just `loading`: the panel opens client-side a round trip
              before the fetch is even asked for, so an ungated empty state announces "nothing here"
              about a list it has not looked at yet. --%>
        <div
          :if={@loaded? && !@recent_logs.loading && !@recent_logs.failed && @activity_count == 0}
          class="flex flex-col items-center justify-center gap-3 py-11 text-center"
        >
          <span class="grid size-[52px] place-items-center rounded-[14px] bg-[#f2f1ec] text-[#a8a5a0]">
            <.icon name="hero-clipboard-document-check" class="size-6" />
          </span>
          <div>
            <div class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
              {gettext("No activity yet")}
            </div>
            <div class="mt-[3px] text-[12px] font-medium text-[#8a877f]">
              {gettext("Changes across your resources will appear here.")}
            </div>
          </div>
        </div>

        <div class="flex items-center justify-between gap-3 bg-[#faf9f6] px-[18px] py-3">
          <span class="text-[11.5px] font-medium text-[#a8a5a0]">
            <%= if @activity_last_updated_at do %>
              {gettext("Last updated: %{time}",
                time: Calendar.strftime(@activity_last_updated_at, "%H:%M:%S")
              )}
            <% else %>
              {gettext("Track changes across your resources")}
            <% end %>
          </span>
          <%!-- One way out of the panel: the full activity page. Paging a preview in place asks the
                reader to manage two lists at once, and the page it links to already does it better. --%>
          <.link
            navigate="/admin/dashboard/runtime/activity"
            class="text-[12px] font-semibold text-[#5b57d6] transition-opacity hover:opacity-70"
          >
            {gettext("View all logs →")}
          </.link>
        </div>
      </section>
    </div>
    """
  end

  # Pushes the toggle to the component, which flips `@open?`; the panel's own `hidden` class is driven
  # by that assign, so visibility survives the parent table's re-renders. `on_toggle` runs first so a
  # host page can close its sibling panel. Takes `@myself`, so only its own render can call it.
  defp toggle_logs(_id, target, on_toggle) do
    JS.push(on_toggle, "toggle_logs", target: target)
  end

  defp site_name(_site_names, nil), do: gettext("Global")

  defp site_name(site_names, site_id),
    do: Map.get(site_names, site_id, gettext("unknown site"))

  defp severity_label(:error), do: gettext("error")
  defp severity_label(:warn), do: gettext("warn")
  defp severity_label(other), do: to_string(other)

  defp dot_class(:warn), do: "bg-[#cf8a24]"
  defp dot_class(:error), do: "bg-[#d5544b]"
  defp dot_class(_), do: "bg-[#1f9d6b]"

  defp severity_class(:error), do: "bg-[#fbe9e7] text-[#b3433a]"
  defp severity_class(_), do: "bg-[#fbf1df] text-[#a5691a]"

  defp tone_class(:emerald), do: "bg-[#e6f6ee] text-[#177a53]"
  defp tone_class(:sky), do: "bg-[#e6f1fa] text-[#276fa3]"
  defp tone_class(:amber), do: "bg-[#fbf1df] text-[#a5691a]"
  defp tone_class(:rose), do: "bg-[#fbe9e7] text-[#b3433a]"
  defp tone_class(:indigo), do: "bg-[#eeedfb] text-[#4f4bcc]"
  defp tone_class(:violet), do: "bg-[#eeedfb] text-[#4f4bcc]"
  defp tone_class(:teal), do: "bg-[#e6f6ee] text-[#177a53]"
  defp tone_class(:fuchsia), do: "bg-[#fbe8f0] text-[#a83f6d]"
  defp tone_class(_), do: "bg-[#f2f1ec] text-[#6d6a63]"

  defp route_broadcast(socket, %Phoenix.Socket.Broadcast{} = msg) do
    scope = build_scope(socket.assigns.current_user, socket.assigns[:resources])
    entry = scoped_entry(socket.assigns.sources, msg, scope)

    cond do
      entry &&
          MishkaCmsCore.Activity.Helpers.visible_to?(entry.site_id, socket.assigns.current_user) ->
        add_entry(socket, entry)

      site_broadcast?(msg) ->
        refresh_site_names(socket, msg)

      true ->
        socket
    end
  end

  # Before the first fetch there is no stream to insert into that the fetch would
  # not immediately reset, so hold the entry and merge it into that fetch.
  defp add_entry(%{assigns: %{loaded?: false}} = socket, entry) do
    socket
    |> label_actor(entry)
    |> assign(:pending, Enum.take([entry | socket.assigns.pending], window(socket)))
    |> bump_count(entry)
  end

  defp add_entry(socket, entry) do
    socket
    |> label_actor(entry)
    |> stream_insert(:logs_stream, entry, at: 0, limit: window(socket))
    |> bump_count(entry)
  end

  # Label an actor the feed has not named yet.
  defp label_actor(socket, %{user_id: nil}), do: socket

  defp label_actor(%{assigns: %{actor_names: names}} = socket, %{user_id: id})
       when is_map_key(names, id),
       do: socket

  defp label_actor(socket, %{user_id: id}) do
    labels = Helpers.actor_labels([id], socket.assigns.current_user)
    assign(socket, :actor_names, Map.merge(socket.assigns.actor_names, labels))
  end

  defp bump_count(socket, entry) do
    socket
    |> assign(:activity_count, min(socket.assigns.activity_count + 1, window(socket)))
    |> assign(:activity_last_updated_at, entry.inserted_at)
  end

  @doc false
  def first_source_entry(msg, sources), do: scoped_entry(sources, msg, %{})

  defp scoped_entry(sources, msg, scope) do
    Enum.find_value(sources, fn source ->
      if source.handles?(msg) and source_in_scope?(source, msg, scope) do
        Helpers.complete_entry(source.to_entry(msg))
      end
    end)
  end

  defp source_in_scope?(source, msg, scope) do
    !function_exported?(source, :in_scope?, 2) or source.in_scope?(msg, scope)
  end

  defp site_broadcast?(%Phoenix.Socket.Broadcast{
         payload: %Ash.Notifier.Notification{resource: MishkaCmsCore.Runtime.Site}
       }),
       do: true

  defp site_broadcast?(_), do: false

  defp refresh_site_names(socket, %Phoenix.Socket.Broadcast{
         payload: %Ash.Notifier.Notification{action: %{name: action}, data: site}
       }) do
    case action do
      a
      when a in [
             :create,
             :master_create,
             :update,
             :master_update,
             :unarchive,
             :master_unarchive,
             :activate,
             :deactivate
           ] ->
        assign(socket, :site_names, Map.put(socket.assigns.site_names, site.id, site.name))

      a
      when a in [
             :destroy,
             :master_destroy,
             :permanent_destroy,
             :master_permanent_destroy
           ] ->
        assign(socket, :site_names, Map.delete(socket.assigns.site_names, site.id))

      _ ->
        socket
    end
  end

  @doc false
  def fetch_recent_activity(sources, scope, limit) do
    sources
    |> Task.async_stream(
      MishkaGervaz.Messages.in_caller_locale(fn source -> source.initial_fetch(scope, limit) end),
      max_concurrency: max(length(sources), 1),
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, entries} when is_list(entries) -> entries
      _ -> []
    end)
    |> Enum.map(&Helpers.complete_entry/1)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp build_scope(current_user, resources) do
    %{current_user: current_user, resources: resources}
  end

  defp last_updated_at([]), do: nil
  defp last_updated_at([entry | _]), do: entry.inserted_at

  @doc false
  def load_site_names(%{site_id: nil} = actor) do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.for_read(:read_any, %{}, actor: actor)
    |> Ash.read!(actor: actor)
    |> Map.new(fn site -> {site.id, site.name} end)
  end

  def load_site_names(%{site_id: site_id} = actor) when is_binary(site_id) do
    case Ash.get(MishkaCmsCore.Runtime.Site, site_id, action: :get_any, actor: actor) do
      {:ok, site} -> %{site.id => site.name}
      _ -> %{}
    end
  end

  def load_site_names(_), do: %{}
end
