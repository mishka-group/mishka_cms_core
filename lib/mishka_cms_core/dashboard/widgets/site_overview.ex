defmodule MishkaCmsCore.Dashboard.Widgets.SiteOverview do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): a master sees the fleet — the site total with an
  active/inactive split, a per-mode breakdown (API Only / Phoenix Only / Hybrid) and the average
  compiled bundle size (gzip CSS + JS); a tenant admin sees the same identity card scoped to their own
  site. Site counts come from `MishkaCmsCore.Runtime.States.SiteState` (ETS) and bundle sizes from
  `MishkaCmsCore.Runtime.States.AssetsState` (ETS).

  See `MishkaCmsCore.Dashboard.Widget` for the shared card primitives this composes.

  A mode dot's colour is one of three, so `dot_class/1` writes each out whole and it can be a class.
  A bundle bar's width cannot: `pct/2` derives it from the measured bundle, and Tailwind generates
  rules from SOURCE TEXT, so a class assembled around a value that only exists at render time gets no
  rule at all and the bar draws with no width. That width rides an inline `style` attribute, which is
  why the policy in `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` keeps `style-src-attr` permitted —
  see `MishkaCmsWeb.InterpolatedClassTest`.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 30}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.States.SiteState

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "site-overview",
        priority: 30,
        title: gettext_noop("Site overview"),
        component: {__MODULE__, :render},
        size: 3,
        permission: "admin:dashboard:runtime:site",
        icon: "hero-globe-alt",
        link: "/admin/dashboard/runtime/sites"
      })

    widget
  end

  @doc "Loads this widget's data off the dashboard render (in a Task), scoped to the viewer."
  def load(user) do
    case Widget.scope(user) do
      nil -> master_data()
      site_id -> tenant_data(site_id)
    end
  end

  def render(%{data: %{view: :tenant}} = assigns) do
    ~H"""
    <Widget.card_header
      icon="hero-globe-alt"
      tone={:violet}
      title={gettext("Site overview")}
      subtitle={@data.site && @data.site.host}
    >
      <:right :if={@data.site}>
        <Widget.pill
          label={if @data.site.active, do: gettext("Active"), else: gettext("Inactive")}
          tone={if @data.site.active, do: :green, else: :red}
          dot={@data.site.active}
        />
      </:right>
    </Widget.card_header>

    <div :if={@data.site}>
      <div class="flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate font-['Space_Grotesk'] text-[26px] font-semibold leading-none tracking-[-0.03em] text-[#17161a]">
            {@data.site.name}
          </div>
          <div class="mt-1 text-[12px] font-medium text-[#8a877f]">{gettext("Active site")}</div>
        </div>
        <Widget.badge label={mode_label(@data.site.mode)} tone={:violet} />
      </div>

      <div class="mt-[18px] mb-[10px] text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#a8a5a0]">
        {gettext("Bundle size")}
      </div>
      {bundle_tiles(assigns)}
    </div>

    <Widget.empty :if={is_nil(@data.site)} icon="hero-globe-alt" message={gettext("Site not found.")} />
    <Widget.card_footer link={@widget.link} label={gettext("View all sites")} border={true} />
    """
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header icon="hero-globe-alt" tone={:violet} title={gettext("Site overview")}>
      <:right>
        <Widget.pill label={gettext("%{count} active", count: @data.active)} tone={:green} dot />
      </:right>
    </Widget.card_header>

    <div class="flex gap-[22px]">
      <div class="flex-none border-e border-[#f0efea] pe-[22px]">
        <div class="flex items-baseline gap-1.5">
          <span class="font-['Space_Grotesk'] text-[44px] font-semibold leading-none tracking-[-0.03em] text-[#17161a]">
            {Localized.number(@data.total)}
          </span>
        </div>
        <div class="mt-1 text-[12px] font-medium text-[#8a877f]">{gettext("sites total")}</div>
        <div class="mt-4 flex flex-col gap-[7px]">
          <span class="flex items-center gap-[7px] text-[12px] font-semibold text-[#5c5a54]">
            <span class="size-2 rounded-[3px] bg-[#1f9d6b]" />{gettext("%{count} Active",
              count: @data.active
            )}
          </span>
          <span class="flex items-center gap-[7px] text-[12px] font-semibold text-[#a8a5a0]">
            <span class="size-2 rounded-[3px] bg-[#dcdad3]" />{gettext("%{count} Inactive",
              count: @data.inactive
            )}
          </span>
        </div>
      </div>

      <div class="min-w-0 flex-1">
        <div class="mb-[10px] text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#a8a5a0]">
          {gettext("Sites by mode")}
        </div>
        <div class="mb-[14px] flex h-[9px] gap-[2px] overflow-hidden rounded-[6px]">
          <div class="flex-1 bg-[#5b57d6]" />
          <div class="flex-1 bg-[#1f9d6b]" />
          <div class="flex-1 bg-[#cf8a24]" />
        </div>
        <.mode_row color="#5b57d6" label={gettext("API Only")} count={@data.api_only} />
        <.mode_row color="#1f9d6b" label={gettext("Phoenix Only")} count={@data.phoenix_only} />
        <.mode_row color="#cf8a24" label={gettext("Hybrid")} count={@data.hybrid} />
      </div>
    </div>

    <div class="mt-[18px] mb-[10px] text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#a8a5a0]">
      {gettext("Average bundle size")}
    </div>
    {bundle_tiles(assigns)}

    <Widget.card_footer link={@widget.link} label={gettext("View all sites")} border={true} />
    """
  end

  defp mode_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-1">
      <span class="flex items-center gap-[7px] text-[12.5px] font-medium text-[#3a382f]">
        <span class={["size-2 rounded-[3px]", dot_class(@color)]} />{@label}
      </span>
      <span class="font-['Space_Grotesk'] text-[12.5px] font-semibold text-[#17161a]">
        {Localized.number(@count)}
      </span>
    </div>
    """
  end

  defp bundle_tiles(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2.5">
      <div class="rounded-xl border border-[#f0efea] bg-[#faf9f6] px-3.5 py-3">
        <div class="flex items-center justify-between">
          <span class="flex items-center gap-1.5 text-[11px] font-semibold text-[#5c5a54]">
            <span class="grid size-3.5 place-items-center rounded-[4px] bg-[#e7edfb] font-['Space_Grotesk'] text-[7px] font-bold text-[#3b6fd4]">
              C
            </span>CSS
          </span>
          <span class="text-[9px] font-semibold text-[#a8a5a0]">gzip</span>
        </div>
        <div class="mt-[5px]">
          <span class="font-['Space_Grotesk'] text-[22px] font-semibold text-[#17161a]">
            {@data.bundle.css}
          </span>
          <span class="ms-[3px] text-[12px] font-medium text-[#8a877f]">{gettext("KB")}</span>
        </div>
        <div class="mt-[9px] h-1 overflow-hidden rounded-[3px] bg-[#f0efea]">
          <div class="h-full bg-[#3b6fd4]" style={"width:#{pct(@data.bundle.css, 150)}%"} />
        </div>
      </div>

      <div class="rounded-xl border border-[#f0efea] bg-[#faf9f6] px-3.5 py-3">
        <div class="flex items-center justify-between">
          <span class="flex items-center gap-1.5 text-[11px] font-semibold text-[#5c5a54]">
            <span class="grid size-3.5 place-items-center rounded-[4px] bg-[#eeedfb] font-['Space_Grotesk'] text-[7px] font-bold text-[#5b57d6]">
              J
            </span>JS
          </span>
          <span class="text-[9px] font-semibold text-[#a8a5a0]">gzip</span>
        </div>
        <div class="mt-[5px]">
          <span class="font-['Space_Grotesk'] text-[22px] font-semibold text-[#17161a]">
            {@data.bundle.js}
          </span>
          <span class="ms-[3px] text-[12px] font-medium text-[#8a877f]">{gettext("KB")}</span>
        </div>
        <div class="mt-[9px] h-1 overflow-hidden rounded-[3px] bg-[#f0efea]">
          <div class="h-full bg-[#5b57d6]" style={"width:#{pct(@data.bundle.js, 300)}%"} />
        </div>
      </div>
    </div>
    """
  end

  defp master_data do
    sites = Enum.to_list(SiteState.stream())
    total = length(sites)
    active = Enum.count(sites, & &1.active)
    modes = Enum.frequencies_by(sites, &to_string(&1.mode))

    %{
      view: :master,
      total: total,
      active: active,
      inactive: max(total - active, 0),
      api_only: Map.get(modes, "api_only", 0),
      phoenix_only: Map.get(modes, "phoenix_only", 0),
      hybrid: Map.get(modes, "hybrid", 0),
      bundle: %{css: average_kb("gzip_css"), js: average_kb("gzip_js")}
    }
  end

  defp tenant_data(site_id) do
    case SiteState.get(site_id) do
      {:ok, site} ->
        %{
          view: :tenant,
          site: site,
          bundle: %{css: site_kb(site.name, "gzip_css"), js: site_kb(site.name, "gzip_js")}
        }

      _ ->
        %{view: :tenant, site: nil, bundle: %{css: 0, js: 0}}
    end
  end

  defp average_kb(type) do
    case AssetsState.get_by_type(type) do
      [] -> 0
      assets -> assets |> Enum.map(&asset_kb/1) |> Enum.sum() |> div(length(assets))
    end
  end

  defp site_kb(site_name, type), do: to_kb(AssetsState.get_value(site_name, type))

  defp asset_kb(%{value: value}), do: to_kb(value)

  defp to_kb(value) when is_binary(value), do: round(byte_size(value) / 1024)
  defp to_kb(_value), do: 0

  defp mode_label(mode) do
    case to_string(mode) do
      "api_only" -> gettext("API Only")
      "phoenix_only" -> gettext("Phoenix Only")
      _ -> gettext("Hybrid")
    end
  end

  defp pct(kb, cap) when is_integer(kb) and kb > 0,
    do: kb |> Kernel./(cap) |> Kernel.*(100) |> round() |> min(100) |> max(2)

  defp pct(_kb, _cap), do: 0

  defp dot_class("#1f9d6b"), do: "[background:#1f9d6b]"
  defp dot_class("#cf8a24"), do: "[background:#cf8a24]"
  defp dot_class(_indigo), do: "[background:#5b57d6]"
end
