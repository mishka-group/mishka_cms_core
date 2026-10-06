defmodule MishkaCmsCore.Dashboard.Widgets.CmsStatus do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the operational pulse of the CMS. Reports the
  public site's online state (`cms.offline`, read by `Settings.offline_by/1`: a tenant sees whether
  its site is offline by its own switch or by the Global one, a master sees the Global switch and how
  many sites are offline by their own), the week's compile throughput as a weekday
  mini bar chart with a week-over-week trend (`Oban.Job` insert history), how many compile jobs are
  pending, how many active sites are missing a CSS/JS bundle (`AssetsState`), and the runtime-job
  health split (running/retrying/failed) — subsuming the standalone runtime-health widget. A master
  watches every site; a tenant admin only their own site's jobs and bundle. Ships `default_hidden` —
  opt-in via the widget library.

  A bar's height is a percentage of the week's busiest day, computed per render, so it cannot be a
  Tailwind utility — rules are generated from SOURCE TEXT, and a class assembled around a value that
  exists only at render time gets no rule at all, leaving the bar with no height. The height rides an
  inline `style` attribute, which is why the policy in
  `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` keeps `style-src-attr` permitted. A bar's COLOUR is a
  different matter: it is one of three whole literals in `bar_color/1` — see
  `MishkaCmsWeb.InterpolatedClassTest`.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 20}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  import Ecto.Query

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Settings

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "cms-status",
        priority: 20,
        title: gettext_noop("CMS status"),
        component: {__MODULE__, :render},
        size: 2,
        permission: {:under, "admin:dashboard"},
        icon: "hero-server-stack",
        link: "/admin/dashboard/runtime/sites"
      })

    widget
  end

  @doc "Loads this widget's data off the dashboard render (in a Task), scoped to the viewer."
  def load(user) do
    scope = Widget.scope(user)

    offline_by = Settings.offline_by(scope)

    %{
      offline?: offline_by != [],
      offline_by: offline_by,
      sites_offline: sites_offline(scope),
      pending: count_jobs(["available", "scheduled"], scope),
      missing: missing_bundles(scope),
      running: count_jobs(["executing", "available", "scheduled"], scope),
      retrying: count_jobs(["retryable"], scope),
      failed: count_jobs(["retryable", "discarded"], scope),
      compiles: compile_stats(scope)
    }
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header icon="hero-server-stack" tone={:green} title={gettext("CMS status")}>
      <:right>
        <Widget.pill
          label={if @data.offline?, do: gettext("Offline"), else: gettext("Operational")}
          tone={if @data.offline?, do: :red, else: :green}
          dot
        />
      </:right>
    </Widget.card_header>

    <div class="mb-3.5 rounded-[14px] border border-[#f0efea] bg-[#faf9f6] px-[15px] pb-[13px] pt-[15px]">
      <div class="flex items-baseline justify-between">
        <div>
          <span class="font-['Space_Grotesk'] text-[26px] font-semibold tracking-[-0.03em] text-[#17161a]">
            {@data.compiles.total}
          </span>
          <span class="ms-1.5 text-[11.5px] font-medium text-[#8a877f]">
            {gettext("compiles this week")}
          </span>
        </div>
        <span class={[
          "inline-flex items-center gap-[3px] text-[11px] font-semibold",
          if(@data.compiles.delta >= 0, do: "text-[#1f9d6b]", else: "text-[#b3433a]")
        ]}>
          <span class={[
            if(@data.compiles.delta >= 0,
              do: "hero-arrow-trending-up",
              else: "hero-arrow-trending-down"
            ),
            "size-3"
          ]} />
          {abs(@data.compiles.delta)}%
        </span>
      </div>
      <div class="mt-3.5 flex h-[60px] items-end gap-[7px]">
        <div
          :for={bar <- @data.compiles.bars}
          class={["flex-1 rounded-b-[2px] rounded-t-[5px]", bar_color(bar)]}
          style={"height:#{bar.height}%"}
        >
        </div>
      </div>
      <div class="mt-2 flex gap-[7px]">
        <span
          :for={bar <- @data.compiles.bars}
          class={[
            "flex-1 text-center text-[9px] font-semibold",
            if(bar.today?, do: "text-[#5b57d6]", else: "text-[#bcb9b2]")
          ]}
        >
          {bar.label}
        </span>
      </div>
    </div>

    <div class="flex items-center justify-between border-b border-[#f4f3ef] py-[9px]">
      <span class="flex items-center gap-[9px] text-[12.5px] font-medium text-[#5c5a54]">
        <span class={[
          "size-[7px] rounded-full",
          if(@data.offline?,
            do: "bg-[#d5544b] shadow-[0_0_0_3px_#fbe9e7]",
            else: "bg-[#1f9d6b] shadow-[0_0_0_3px_#e6f6ee]"
          )
        ]} /> {gettext("Public site")}
        <span
          :if={@data.offline?}
          id="cms-status-offline-by"
          class="text-[11px] font-medium text-[#a8a5a0]"
        >
          {offline_by_text(@data.offline_by)}
        </span>
      </span>
      <Widget.badge
        label={if @data.offline?, do: gettext("OFFLINE"), else: gettext("ONLINE")}
        tone={if @data.offline?, do: :rose, else: :emerald}
      />
    </div>

    <div
      :if={is_integer(@data.sites_offline)}
      id="cms-status-sites-offline"
      class="flex items-center justify-between border-b border-[#f4f3ef] py-[9px]"
    >
      <span class="text-[12.5px] font-medium text-[#5c5a54]">
        {gettext("Sites offline on their own")}
      </span>
      <span class={[
        "font-['Space_Grotesk'] text-[14px] font-semibold",
        if(@data.sites_offline > 0, do: "text-[#b3433a]", else: "text-[#1b1a18]")
      ]}>
        {@data.sites_offline}
      </span>
    </div>

    <div class="flex items-center justify-between border-b border-[#f4f3ef] py-[9px]">
      <span class="text-[12.5px] font-medium text-[#5c5a54]">{gettext("Pending compiles")}</span>
      <span class="font-['Space_Grotesk'] text-[14px] font-semibold text-[#1b1a18]">
        {@data.pending}
      </span>
    </div>

    <div class="flex items-center justify-between py-[9px]">
      <span class="text-[12.5px] font-medium text-[#5c5a54]">{gettext("Missing bundles")}</span>
      <span class={[
        "font-['Space_Grotesk'] text-[14px] font-semibold",
        if(@data.missing > 0, do: "text-[#a5691a]", else: "text-[#1b1a18]")
      ]}>
        {@data.missing}
      </span>
    </div>

    <div class="mb-2.5 mt-4 text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#a8a5a0]">
      {gettext("Runtime health")}
    </div>
    <div class="grid grid-cols-3 gap-2">
      <div class="rounded-xl bg-[#e6f6ee] px-3 py-[11px]">
        <div class="flex items-center gap-[5px] text-[10px] font-semibold text-[#177a53]">
          <span class="size-1.5 rounded-full bg-[#1f9d6b]" />{gettext("Running")}
        </div>
        <div class="mt-1 font-['Space_Grotesk'] text-[20px] font-semibold text-[#177a53]">
          {@data.running}
        </div>
      </div>
      <div class="rounded-xl bg-[#fbf1df] px-3 py-[11px]">
        <div class="flex items-center gap-[5px] text-[10px] font-semibold text-[#a5691a]">
          <span class="size-1.5 rounded-full bg-[#cf8a24]" />{gettext("Retrying")}
        </div>
        <div class="mt-1 font-['Space_Grotesk'] text-[20px] font-semibold text-[#a5691a]">
          {@data.retrying}
        </div>
      </div>
      <div class="rounded-xl bg-[#fbe9e7] px-3 py-[11px]">
        <div class="flex items-center gap-[5px] text-[10px] font-semibold text-[#b3433a]">
          <span class="size-1.5 rounded-full bg-[#d5544b]" />{gettext("Failed")}
        </div>
        <div class="mt-1 font-['Space_Grotesk'] text-[20px] font-semibold text-[#b3433a]">
          {@data.failed}
        </div>
      </div>
    </div>

    <Widget.card_footer link={@widget.link} label={gettext("View more info")} border={true} />
    """
  end

  defp offline_by_text([:global | _site]), do: gettext("every site, by Global")
  defp offline_by_text(_site), do: gettext("by this site's own switch")

  # A master sees how many serving sites switched themselves offline; a tenant sees its own site.
  defp sites_offline(nil) do
    %{active: true}
    |> SiteState.stream()
    |> Enum.count(&(:site in Settings.offline_by(&1.id)))
  end

  defp sites_offline(_site_id), do: nil

  defp bar_color(%{today?: true}), do: "bg-[linear-gradient(180deg,#6d69e6,#4f4bcc)]"
  defp bar_color(%{penultimate?: true}), do: "bg-[#bcb8ee]"
  defp bar_color(_bar), do: "bg-[#d7d5f4]"

  defp compile_stats(scope) do
    today = Date.utc_today()
    counts = jobs_by_day(scope, Date.add(today, -13))
    week = for i <- -6..0, do: Map.get(counts, Date.add(today, i), 0)
    prev = for i <- -13..-7, do: Map.get(counts, Date.add(today, i), 0)

    this_week = Enum.sum(week)
    last_week = Enum.sum(prev)
    max = Enum.max([1 | week])

    delta =
      cond do
        last_week > 0 -> round((this_week - last_week) / last_week * 100)
        this_week > 0 -> 100
        true -> 0
      end

    bars =
      Enum.with_index(week, fn count, i ->
        %{
          label: Date.add(today, i - 6) |> weekday_initial(),
          height: max(round(count / max * 100), 8),
          today?: i == 6,
          penultimate?: i == 5
        }
      end)

    %{total: this_week, delta: delta, bars: bars}
  end

  defp weekday_initial(date),
    do:
      date
      |> Calendar.strftime("%a", MishkaCmsCore.Activity.Helpers.strftime_names())
      |> String.first()

  defp jobs_by_day(nil, start) do
    from(j in Oban.Job,
      where: fragment("?::date", j.inserted_at) >= ^start,
      group_by: fragment("?::date", j.inserted_at),
      select: {fragment("?::date", j.inserted_at), count()}
    )
    |> run_all()
  end

  defp jobs_by_day(site_id, start) do
    from(j in Oban.Job,
      where: fragment("?::date", j.inserted_at) >= ^start,
      where: fragment("?->'data'->>'site_id' = ?", j.args, ^site_id),
      group_by: fragment("?::date", j.inserted_at),
      select: {fragment("?::date", j.inserted_at), count()}
    )
    |> run_all()
  end

  defp run_all(query), do: Oban.config() |> Oban.Repo.all(query) |> Map.new()

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

  defp missing_bundles(scope) do
    %{active: true}
    |> SiteState.stream()
    |> Enum.filter(&(is_nil(scope) or &1.id == scope))
    |> Enum.count(&(!AssetsState.exists?(&1.name, "css") or !AssetsState.exists?(&1.name, "js")))
  end
end
