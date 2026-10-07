defmodule MishkaCmsCoreWeb.Live.Admin.Components.SiteHealthPanel do
  @moduledoc """
  Renders a site's runtime health from `MishkaCmsCore.Runtime.SiteHealth.compute/1`:
  a one-glance headline (Healthy / Recovered / Working / Needs attention / Offline / Inactive),
  the site's in-progress and failed compile tasks, a per-resource active/inactive/
  archived roll-up, CSS/JS bundle status + freshness, and a compact recent-activity list.

  Each failed task is a native `<details>` disclosure (no JS — the panel ships as a
  static HTML string) showing that job's error inline; for a master admin (`viewer_oban`)
  it also links to the job's full log in Oban Web (`/oban/jobs/<id>`). The error detail is
  always scoped to this site's jobs, so it is safe for a tenant viewer.

  Rendered to an HTML string on the parent LiveView and pushed into the gervaz
  expanded row of the admin Sites table.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext
  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.Runtime.Site

  attr :health, :map, required: true
  attr :viewer_oban, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <div class="rounded-[14px] border border-[#ecebe6] bg-white p-5">
      <div class="mb-4 flex items-start justify-between gap-4">
        <div>
          <div class="font-['Space_Grotesk'] text-[16px] font-semibold text-[#17161a]">
            {gettext("Site Runtime Health")}
          </div>
          <div class="mt-[3px] font-['Space_Grotesk'] text-[11.5px] font-medium text-[#a8a5a0]">
            {if @health.master?,
              do:
                gettext("%{host} · %{mode} · master",
                  host: @health.host,
                  mode: mode_label(@health.mode)
                ),
              else: gettext("%{host} · %{mode}", host: @health.host, mode: mode_label(@health.mode))}
          </div>
        </div>
        <span class={[
          "inline-flex items-center gap-[6px] whitespace-nowrap rounded-[20px] px-[11px] py-[4px] text-[10.5px] font-bold",
          pill_tone(@health.state)
        ]}>
          <span class={["size-[6px] rounded-full", dot_tone(@health.state)]}></span>
          {@health.label}
        </span>
      </div>

      <div class={[
        "mb-[14px] flex items-center gap-[12px] rounded-[12px] border px-[16px] py-[14px]",
        panel_tone(@health.state)
      ]}>
        <span class={[
          "grid size-[32px] shrink-0 place-items-center rounded-[9px]",
          serving_icon_box(@health.state)
        ]}>
          <.icon name={state_icon(@health.state)} class="size-[17px]" />
        </span>
        <div class="min-w-0">
          <div class={["text-[13px] font-bold", serving_title_tone(@health.state)]}>
            {serving_text(@health)}
          </div>
          <div class={["mt-px text-[11.5px] font-medium", serving_msg_tone(@health.state)]}>
            {@health.message}
          </div>
        </div>
        <button
          :if={@health.unrecovered != [] or @health.recovered != []}
          type="button"
          phx-click="dismiss_failures"
          data-confirm={gettext("Delete all failed jobs for this site and clear the alerts?")}
          class="ms-auto inline-flex shrink-0 items-center gap-1 rounded-lg border border-[#ecebe6] bg-white px-[10px] py-[5px] text-[11px] font-semibold text-[#5c5a54] hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-check-circle" class="size-3.5" /> {gettext("Clear failures")}
        </button>
      </div>

      <div class="mb-[14px] grid grid-cols-2 gap-[12px] max-[560px]:grid-cols-1!">
        <div class="rounded-[11px] border border-[#f0efea] px-[15px] py-[13px]">
          <div class="flex items-center justify-between gap-2">
            <div class="flex min-w-0 items-center gap-[9px]">
              <.icon name="hero-arrow-path" class="size-[15px] shrink-0 text-[#c0752a]" />
              <div class="min-w-0">
                <div class="text-[12px] font-bold text-[#c0752a]">{gettext("In progress")}</div>
                <div :if={@health.in_progress == []} class="text-[10.5px] font-medium text-[#a8a5a0]">
                  {gettext("Nothing compiling.")}
                </div>
              </div>
            </div>
            <span class="font-['Space_Grotesk'] text-[15px] font-bold text-[#3a382f]">
              {length(@health.in_progress)}
            </span>
          </div>
          <ul :if={@health.in_progress != []} class="mt-2 space-y-1">
            <li
              :for={job <- Enum.take(@health.in_progress, 6)}
              class="flex items-center gap-1.5 text-[11px] text-[#6d6a63]"
            >
              <span class="size-1.5 shrink-0 animate-pulse rounded-full bg-[#cf8a24]"></span>
              <span class="truncate">{job.label}</span>
            </li>
          </ul>
        </div>

        <div class={[
          "rounded-[11px] border px-[15px] py-[13px]",
          attention_tone(@health.unrecovered, @health.recovered)
        ]}>
          <div class="flex items-center justify-between gap-2">
            <div class="flex min-w-0 items-center gap-[9px]">
              <.icon name="hero-exclamation-triangle" class="size-[15px] shrink-0 text-[#c0473d]" />
              <div class="min-w-0">
                <div class="text-[12px] font-bold text-[#c0473d]">{gettext("Needs attention")}</div>
                <div
                  :if={@health.unrecovered == [] and @health.recovered == []}
                  class="text-[10.5px] font-medium text-[#a8a5a0]"
                >
                  {gettext("No failures. 🎉")}
                </div>
              </div>
            </div>
            <span class="font-['Space_Grotesk'] text-[15px] font-bold text-[#3a382f]">
              {length(@health.unrecovered) + length(@health.recovered)}
            </span>
          </div>
          <ul :if={@health.unrecovered != [] or @health.recovered != []} class="mt-2 space-y-1">
            <.failed_row
              :for={job <- Enum.take(@health.unrecovered, 6)}
              job={job}
              kind={:unrecovered}
              viewer_oban={@viewer_oban}
            />
            <.failed_row
              :for={job <- Enum.take(@health.recovered, 6)}
              job={job}
              kind={:recovered}
              viewer_oban={@viewer_oban}
            />
          </ul>
        </div>
      </div>

      <div class="mb-[14px] rounded-[11px] border border-[#f0efea] px-[15px] py-[13px]">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-[12.5px] font-bold text-[#1b1a18]">{gettext("Runtime parts")}</span>
          <span class="text-[10px] font-medium text-[#a8a5a0]">
            {gettext("active · inactive · archived")}
          </span>
        </div>
        <div class="grid grid-cols-3 gap-x-[24px] gap-y-[10px] max-[560px]:grid-cols-2!">
          <div
            :for={part <- @health.parts}
            class="flex items-center justify-between text-[11.5px] font-semibold text-[#6d6a63]"
          >
            <span>{part.kind}</span>
            <span>
              <b class={if(part.active > 0, do: "text-[#177a53]", else: "")}>{part.active}</b>
              · {part.inactive} · {part.archived}
            </span>
          </div>
        </div>
      </div>

      <div class="mb-[14px] flex flex-wrap items-center justify-between gap-3 rounded-[11px] border border-[#f0efea] px-[15px] py-[13px]">
        <span class="text-[12.5px] font-bold text-[#1b1a18]">{gettext("Bundles")}</span>
        <div class="flex flex-wrap gap-x-[20px] gap-y-1 text-[11.5px] font-semibold text-[#6d6a63]">
          <.bundle_row label={gettext("CSS")} asset={@health.assets.css} />
          <.bundle_row label={gettext("JS")} asset={@health.assets.js} />
        </div>
      </div>

      <div
        :if={!@health.lifeline?}
        id="site-health-lifeline"
        class="mb-[14px] rounded-[11px] border border-[#f0e3c9] bg-[#fdf7ea] px-[15px] py-[13px] text-[11.5px] font-medium text-[#a5691a]"
      >
        {gettext(
          "Background jobs are not rescued after a restart: an email or a notification interrupted by one stays unsent. Add lifeline: [rescue_after: {30, :minutes}] to the app's Oban config."
        )}
      </div>

      <div class="rounded-[11px] border border-[#f0efea] px-[15px] py-[13px]">
        <div class="mb-2 text-[12.5px] font-bold text-[#1b1a18]">{gettext("Recent activity")}</div>
        <div :if={@health.recent == []} class="text-[11px] font-medium text-[#a8a5a0]">
          {gettext("No activity yet.")}
        </div>
        <ul class="divide-y divide-[#f4f3ee]">
          <li
            :for={entry <- Enum.take(@health.recent, 8)}
            class="flex items-center gap-1.5 py-1.5 text-[11px] leading-tight"
          >
            <span class={["size-1.5 shrink-0 rounded-full", severity_dot(entry[:severity])]}></span>
            <span class={[
              "shrink-0 rounded px-1.5 py-px text-[9px] font-bold uppercase tracking-wide",
              severity_badge(entry[:severity])
            ]}>
              {severity_label(entry[:severity])}
            </span>
            <span
              :if={entry[:badge_label]}
              class={[
                "shrink-0 rounded px-1.5 py-px text-[9px] font-medium uppercase tracking-wide",
                Helpers.tone_class(entry[:badge_tone])
              ]}
            >
              {entry[:badge_label]}
            </span>
            <span
              :if={entry[:resource_label]}
              class="hidden shrink-0 rounded bg-[#f4f3ef] px-1.5 py-px text-[10px] font-medium text-[#6d6a63] sm:inline"
            >
              {entry[:resource_label]}
            </span>
            <span class="min-w-0 flex-1 truncate text-[#3a382f]">{entry[:message]}</span>
            <span class="hidden shrink-0 items-center gap-0.5 text-[#a8a5a0] md:inline-flex">
              <.icon name="hero-globe-alt" class="size-3" />{site_text(entry[:site_id], @health.name)}
            </span>
            <span class="shrink-0 whitespace-nowrap tabular-nums text-[#a8a5a0]">
              {ago(entry[:inserted_at])}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :asset, :map, required: true

  defp bundle_row(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-[6px]">
      <span class={[
        "size-[7px] rounded-full",
        if(@asset.present?, do: "bg-[#1f9d6b]", else: "bg-[#c3c0b8]")
      ]}></span>
      {if @asset.present?,
        do: gettext("%{label} ready", label: @label),
        else: gettext("%{label} not built", label: @label)}<span :if={
        @asset.present? && @asset.updated_at
      }>· {ago(@asset.updated_at)}</span>
    </span>
    """
  end

  attr :job, :map, required: true
  attr :kind, :atom, required: true
  attr :viewer_oban, :boolean, required: true

  # Error in a native <details> disclosure (no JS), plus Oban actions wired with plain
  # phx-click (no phx-target) so they reach the page LiveView, not the gervaz component.
  defp failed_row(assigns) do
    ~H"""
    <li class="flex items-start gap-2">
      <details class="group flex-1 min-w-0">
        <summary class="flex items-center gap-1.5 text-xs cursor-pointer list-none marker:hidden [&::-webkit-details-marker]:hidden">
          <span class={["w-1.5 h-1.5 rounded-full shrink-0", row_dot(@kind)]}></span>
          <span class={["truncate", row_text(@kind)]}>{@job.label}</span>
          <span class="text-gray-400 text-[11px] shrink-0">{row_when(@kind, @job)}</span>
          <.icon
            name="hero-chevron-down"
            class="w-3 h-3 text-gray-400 shrink-0 ms-auto transition-transform group-open:rotate-180"
          />
        </summary>
        <div class="mt-1.5 ms-3 ps-2 border-s border-gray-200 space-y-1.5">
          <pre
            :if={@job.error}
            dir="ltr"
            class="text-[11px] text-rose-800 whitespace-pre-wrap break-words max-h-32 overflow-auto bg-white/70 rounded p-1.5"
          >{@job.error}</pre>
          <div :if={!@job.error} class="text-[11px] text-gray-400">
            {gettext("No error detail recorded.")}
          </div>
          <a
            :if={@viewer_oban}
            href={"/oban/jobs/#{@job.id}"}
            target="_blank"
            rel="noopener"
            class="inline-flex items-center gap-1 text-[11px] font-medium text-sky-600 hover:text-sky-700"
          >
            {gettext("View full log")} <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
          </a>
        </div>
      </details>
      <div class="shrink-0 flex items-center gap-0.5">
        <button
          :if={@kind == :unrecovered}
          type="button"
          phx-click="retry_job"
          phx-value-id={@job.id}
          title={gettext("Retry")}
          class="p-1 rounded hover:bg-sky-50 text-gray-400 hover:text-sky-600"
        >
          <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
        </button>
        <button
          :if={@kind == :unrecovered}
          type="button"
          phx-click="cancel_job"
          phx-value-id={@job.id}
          title={gettext("Cancel")}
          class="p-1 rounded hover:bg-gray-100 text-gray-400 hover:text-gray-600"
        >
          <.icon name="hero-no-symbol" class="w-3.5 h-3.5" />
        </button>
        <button
          type="button"
          phx-click="delete_job"
          phx-value-id={@job.id}
          data-confirm={gettext("Delete this job?")}
          title={gettext("Delete")}
          class="p-1 rounded hover:bg-rose-50 text-gray-400 hover:text-rose-600"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" />
        </button>
      </div>
    </li>
    """
  end

  defp row_dot(:unrecovered), do: "bg-[#e5484d]"
  defp row_dot(_), do: "bg-[#cf8a24]"

  defp row_text(:unrecovered), do: "text-[#c0473d]"
  defp row_text(_), do: "text-[#a5691a]"

  defp row_when(:unrecovered, job), do: gettext("failed %{time}", time: ago(job.at))

  defp row_when(_recovered, job),
    do: gettext("recovered %{time}", time: ago(job[:recovered_at]))

  defp mode_label(mode) do
    Map.get(Site.mode_badge_config().labels, to_string(mode), to_string(mode))
  end

  defp attention_tone([_ | _], _recovered), do: "border-[#f0dcd8] bg-[#fdf3f1]"
  defp attention_tone([], [_ | _]), do: "border-[#f0e2c4] bg-[#fdf7ec]"
  defp attention_tone(_, _), do: "border-[#f0efea] bg-white"

  defp serving_text(%{serving?: false}), do: gettext("Not serving (deactivated)")
  defp serving_text(%{offline_by: [_ | _]}), do: gettext("Offline (maintenance)")
  defp serving_text(_health), do: gettext("Serving requests")

  # All recent entries are scoped to this site's feed (own rows + global rows), so a
  # nil site_id means a global resource; anything else is this site.
  defp site_text(nil, _site_name), do: gettext("Global")
  defp site_text(_site_id, site_name), do: site_name

  defp severity_label(:error), do: gettext("ERROR")
  defp severity_label(:warn), do: gettext("WARN")
  defp severity_label(_), do: gettext("INFO")

  defp severity_badge(:error), do: "bg-[#fdf3f1] text-[#c0473d]"
  defp severity_badge(:warn), do: "bg-[#fbf1df] text-[#a5691a]"
  defp severity_badge(_), do: "bg-[#eef1fc] text-[#4f4bcc]"

  defp ago(%DateTime{} = dt), do: relative(DateTime.diff(DateTime.utc_now(), dt))
  defp ago(%NaiveDateTime{} = dt), do: relative(NaiveDateTime.diff(NaiveDateTime.utc_now(), dt))
  defp ago(_other), do: "—"

  defp relative(seconds) when seconds < 60, do: gettext("just now")

  defp relative(seconds) when seconds < 3600,
    do: gettext("%{minutes}m ago", minutes: div(seconds, 60))

  defp relative(seconds) when seconds < 86_400,
    do: gettext("%{hours}h ago", hours: div(seconds, 3600))

  defp relative(seconds), do: gettext("%{days}d ago", days: div(seconds, 86_400))

  defp severity_dot(:error), do: "bg-[#e5484d]"
  defp severity_dot(:warn), do: "bg-[#cf8a24]"
  defp severity_dot(_), do: "bg-[#5b57d6]"

  @doc """
  The classes of the pill that names a `MishkaCmsCore.Runtime.SiteHealth` headline state, here and in
  `MishkaCmsCoreWeb.Live.Admin.Components.SiteDetailsModal`.
  """
  @spec pill_tone(atom()) :: String.t()
  def pill_tone(:healthy), do: "bg-[#e6f6ee] text-[#177a53]"
  def pill_tone(:working), do: "bg-[#fbf1df] text-[#a5691a]"
  def pill_tone(:offline), do: "bg-[#fbf1df] text-[#a5691a]"
  def pill_tone(:recovered), do: "bg-[#fbf1df] text-[#a5691a]"
  def pill_tone(:attention), do: "bg-[#fdf3f1] text-[#c0473d]"
  def pill_tone(_), do: "bg-[#f2f1ec] text-[#8a877f]"

  @doc "The dot inside that pill."
  @spec dot_tone(atom()) :: String.t()
  def dot_tone(:healthy), do: "bg-[#1f9d6b]"
  def dot_tone(:working), do: "bg-[#cf8a24]"
  def dot_tone(:offline), do: "bg-[#cf8a24]"
  def dot_tone(:recovered), do: "bg-[#cf8a24]"
  def dot_tone(:attention), do: "bg-[#e5484d]"
  def dot_tone(_), do: "bg-[#a8a5a0]"

  defp panel_tone(:healthy), do: "bg-[#eefaf2] border-[#d7eddf]"
  defp panel_tone(:working), do: "bg-[#fdf7ec] border-[#f0e2c4]"
  defp panel_tone(:offline), do: "bg-[#fdf7ec] border-[#f0e2c4]"
  defp panel_tone(:recovered), do: "bg-[#fdf7ec] border-[#f0e2c4]"
  defp panel_tone(:attention), do: "bg-[#fdf3f1] border-[#f0dcd8]"
  defp panel_tone(_), do: "bg-[#faf9f6] border-[#ecebe6]"

  defp serving_icon_box(:healthy), do: "bg-[#d7eddf] text-[#177a53]"
  defp serving_icon_box(:working), do: "bg-[#f4e6c8] text-[#a5691a]"
  defp serving_icon_box(:offline), do: "bg-[#f4e6c8] text-[#a5691a]"
  defp serving_icon_box(:recovered), do: "bg-[#f4e6c8] text-[#a5691a]"
  defp serving_icon_box(:attention), do: "bg-[#f4dcd8] text-[#c0473d]"
  defp serving_icon_box(_), do: "bg-[#ecebe6] text-[#8a877f]"

  defp serving_title_tone(:healthy), do: "text-[#136c47]"
  defp serving_title_tone(:working), do: "text-[#a5691a]"
  defp serving_title_tone(:offline), do: "text-[#a5691a]"
  defp serving_title_tone(:recovered), do: "text-[#a5691a]"
  defp serving_title_tone(:attention), do: "text-[#c0473d]"
  defp serving_title_tone(_), do: "text-[#5c5a54]"

  defp serving_msg_tone(:healthy), do: "text-[#3f8b64]"
  defp serving_msg_tone(:attention), do: "text-[#b06258]"
  defp serving_msg_tone(_), do: "text-[#8a877f]"

  defp state_icon(:healthy), do: "hero-check-circle"
  defp state_icon(:working), do: "hero-arrow-path"
  defp state_icon(:offline), do: "hero-wrench-screwdriver"
  defp state_icon(:recovered), do: "hero-arrow-uturn-up"
  defp state_icon(:attention), do: "hero-exclamation-triangle"
  defp state_icon(_), do: "hero-minus-circle"
end
