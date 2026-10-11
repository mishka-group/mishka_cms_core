defmodule MishkaCmsCore.Dashboard.Widgets.OverviewMetrics do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the full-width dark KPI band at the top of the
  board — Sites, Users, Drafts, Open issues, Bloggers, Versions. Anyone holding anything on the
  dashboard sees the band; a tile shows its count only to whoever may see the card it comes from,
  and `—` to anyone else.

  It's a `:panel` widget (renders its own edge-to-edge dark surface, no white card), registered and
  ordered like every other widget so an admin can reorder or hide it. Counts are aggregated from the
  sibling widgets' `load/1`, resolved at *runtime* (`Module.concat` + `Code.ensure_loaded?`) so core
  keeps no compile-time dependency on the blog/document extensions — a KPI whose source extension
  isn't installed simply falls back to `—`.

  A tile's accent is a colour on the row, but it reaches the markup as a whole class through
  `ink_class/1` and `dot_class/1` rather than as a `style` attribute: CSP has no nonce for an
  attribute, so `style-src-attr` can only be closed by there being none. Written out one clause per
  colour because Tailwind reads source text — an interpolated class name has no rule at all, which
  is what `MishkaCmsWeb.InterpolatedClassTest` guards.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 5}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "overview-metrics",
        priority: 5,
        title: gettext_noop("Overview"),
        component: {__MODULE__, :render},
        size: 6,
        variant: :panel,
        permission: {:under, "admin:dashboard"},
        icon: "hero-squares-2x2",
        description:
          gettext_noop("Sites, users, drafts, issues, bloggers and versions at a glance.")
      })

    widget
  end

  # Metric → {module path parts, candidate count keys}. Core widgets are same-extension; blog/document
  # resolve at runtime, guarded, so a missing extension never breaks the band.
  @sources %{
    sites: {~w(MishkaCmsCore Dashboard Widgets SiteOverview), [:total, :count, :sites]},
    users: {~w(MishkaCmsCore Dashboard Widgets UsersSummary), [:total, :count, :users]},
    drafts: {~w(MishkaBlog Dashboard Widgets DraftsScheduled), [:drafts, :total, :count]},
    issues: {~w(MishkaDocument Dashboard Widgets OpenIssues), [:count, :total, :open]},
    bloggers: {~w(MishkaBlog Dashboard Widgets Bloggers), [:active_this_month, :total, :count]},
    versions: {~w(MishkaDocument Dashboard Widgets VersionActivity), [:total, :count]}
  }

  @doc "Loads the six KPI tiles, each count resolved from its source widget (runtime-guarded)."
  def load(user) do
    c = fn key -> count(key, user) end

    %{
      kpis: [
        kpi(gettext("Sites"), c.(:sites), gettext("All live"), "#8ee0b8"),
        kpi(gettext("Users"), c.(:users), gettext("Registered"), "#e6c477"),
        kpi(gettext("Drafts"), c.(:drafts), gettext("Awaiting review"), "#e6c477"),
        kpi(gettext("Open issues"), c.(:issues), gettext("Needs triage"), "#f0938a"),
        kpi(gettext("Bloggers"), c.(:bloggers), gettext("Active"), "#8ee0b8"),
        kpi(gettext("Versions"), c.(:versions), gettext("Across docs"), "#a6a2f5")
      ]
    }
  end

  def render(assigns) do
    ~H"""
    <div
      data-accent-panel
      class="grid grid-cols-6 overflow-hidden rounded-[20px] bg-[#17161a] [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)] max-[980px]:grid-cols-3! max-[560px]:grid-cols-2!"
    >
      <div
        :for={k <- @data.kpis}
        class="border-e border-white/[0.07] px-[22px] py-5 transition hover:bg-white/[0.03]"
      >
        <div class="text-[10.5px] font-semibold uppercase tracking-[0.1em] text-[#8f8d97]">
          {k.label}
        </div>
        <div class="mt-2.5 font-['Space_Grotesk'] text-[34px] font-semibold tracking-[-0.03em] text-white">
          {k.value}
        </div>
        <div class={[
          "mt-2 inline-flex items-center gap-1.5 text-[11px] font-semibold",
          ink_class(k.color)
        ]}>
          <span class={["size-1.5 rounded-full", dot_class(k.color)]} />{k.tag}
        </div>
      </div>
    </div>
    """
  end

  defp kpi(label, value, tag, color),
    do: %{label: label, value: display(value), tag: tag, color: color}

  defp ink_class("#e6c477"), do: "[color:#e6c477]"
  defp ink_class("#f0938a"), do: "[color:#f0938a]"
  defp ink_class("#a6a2f5"), do: "[color:#a6a2f5]"
  defp ink_class(_green), do: "[color:#8ee0b8]"

  defp dot_class("#e6c477"), do: "[background:#e6c477]"
  defp dot_class("#f0938a"), do: "[background:#f0938a]"
  defp dot_class("#a6a2f5"), do: "[background:#a6a2f5]"
  defp dot_class(_green), do: "[background:#8ee0b8]"

  # A tile shows its count only to whoever may see the card it comes from.
  defp count(key, user) do
    {parts, keys} = Map.fetch!(@sources, key)
    module = Module.concat(parts)

    if Code.ensure_loaded?(module) and function_exported?(module, :load, 1) and
         shown?(module, user) do
      pick(module.load(user), keys)
    end
  rescue
    _ -> nil
  end

  defp shown?(module, user),
    do: not function_exported?(module, :widget, 0) or Widget.permitted?(module.widget(), user)

  defp pick(data, keys) when is_map(data) do
    Enum.find_value(keys, fn k ->
      case Map.get(data, k) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp pick(_data, _keys), do: nil

  defp display(nil), do: "—"
  defp display(n) when is_integer(n), do: Localized.number(n)
  defp display(other), do: to_string(other)
end
