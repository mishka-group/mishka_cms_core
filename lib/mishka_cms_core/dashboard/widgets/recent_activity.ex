defmodule MishkaCmsCore.Dashboard.Widgets.RecentActivity do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the latest entries from the unified activity log
  (`MishkaCmsCore.Activity.Query` — AshPaperTrail + AshEvents + Oban + runtime drafts), scoped to the
  viewer's sites and to the areas it holds (`MishkaCmsCore.Activity.Helpers.resources_for/1`),
  rendered as a left-rail timeline with each entry's site name resolved.

  How many entries the timeline holds is the viewer's own setting — the card's gear in customize
  mode, or Settings → General → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`); the "events today" count in the header counts
  only what is shown.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 10}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.Activity.Query, as: Activity
  alias MishkaCmsCore.Activity.Sources.{EventLog, Oban, PaperTrail, RuntimeDraft}

  # The same sources `Activity.Query` unions — each knows its own topics (and scopes them by the
  # viewer), so archiving a post anywhere lands here without a refresh.
  @sources [PaperTrail, EventLog, Oban, RuntimeDraft]

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Entries to show"),
    default: 6,
    min: 3,
    max: 20
  }

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "recent-activity",
        priority: 10,
        pubsub: @sources,
        title: gettext_noop("Recent activity"),
        component: {__MODULE__, :render},
        size: 4,
        permission: "admin:dashboard:runtime:activity",
        icon: "hero-arrow-trending-up",
        link: "/admin/dashboard/runtime/activity",
        settings_category: "general",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), scoped to the viewer and sized by
  their own "Entries to show" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    entries =
      recent_entries(
        Widget.scope(user),
        Helpers.resources_for(user),
        Map.get(config, @count.key, @count.default)
      )

    %{entries: entries, today: today_count(entries)}
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header
      icon="hero-arrow-trending-up"
      tone={:violet}
      title={gettext("Recent activity")}
      subtitle={ngettext("%{count} event today", "%{count} events today", @data.today)}
    >
      <:right>
        <Widget.pill label={gettext("Live")} tone={:green} dot />
      </:right>
    </Widget.card_header>

    <div class="relative flex-1">
      <div
        :if={@data.entries != []}
        class="absolute bottom-2 start-[7px] top-[7px] w-0.5 bg-[#f0efea]"
      >
      </div>
      <div
        :for={e <- @data.entries}
        class="relative flex items-start gap-[14px] pb-[18px] ps-[27px]"
      >
        <span class={[
          "absolute start-[3px] top-1 size-2.5 rounded-full border-2 border-white shadow-[0_0_0_3px_#f4f3ef]",
          dot_class(e.badge_tone)
        ]}></span>
        <div class="min-w-0 flex-1">
          <div class="mb-[5px] flex items-center gap-1.5">
            <Widget.badge label={e.badge_label} tone={e.badge_tone} />
            <span
              dir="ltr"
              class="rounded-[5px] bg-[#f2f1ec] px-[7px] py-0.5 text-[9.5px] font-semibold tracking-[0.03em] text-[#6d6a63]"
            >
              {e.host}
            </span>
          </div>
          <div class="truncate text-[13px] font-semibold text-[#1b1a18]">{e.resource_label}</div>
          <div class="mt-0.5 line-clamp-1 text-[12px] font-medium text-[#8a877f]">{e.message}</div>
        </div>
        <span class="mt-px shrink-0 text-[11.5px] font-medium text-[#a8a5a0]">
          {Widget.relative_time(e.inserted_at)}
        </span>
      </div>
      <Widget.empty
        :if={@data.entries == []}
        icon="hero-clock"
        message={gettext("No recent activity.")}
      />
    </div>

    <Widget.card_footer link={@widget.link} label={gettext("View all logs")} border={true} />
    """
  end

  defp recent_entries(site_id, resources, limit) do
    entries = Activity.page(%{site_id: site_id, resources: resources, limit: limit, offset: 0})
    site_ids = entries |> Enum.map(& &1.site_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    sites = Activity.site_names(site_ids)
    Enum.map(entries, &Map.put(&1, :host, host_label(sites, &1.site_id)))
  end

  defp today_count(entries) do
    today = Date.utc_today()

    Enum.count(entries, fn e ->
      match?(%DateTime{}, e.inserted_at) and DateTime.to_date(e.inserted_at) == today
    end)
  end

  defp host_label(_sites, nil), do: gettext("global")
  defp host_label(sites, site_id), do: Map.get(sites, site_id) || gettext("site")

  defp dot_class(t) when t in [:emerald, :green], do: "bg-[#1f9d6b]"
  defp dot_class(t) when t in [:indigo, :violet], do: "bg-[#5b57d6]"
  defp dot_class(:amber), do: "bg-[#cf8a24]"
  defp dot_class(t) when t in [:rose, :red], do: "bg-[#d5544b]"
  defp dot_class(t) when t in [:sky, :blue], do: "bg-[#3b6fd4]"
  defp dot_class(_), do: "bg-[#8a877f]"
end
