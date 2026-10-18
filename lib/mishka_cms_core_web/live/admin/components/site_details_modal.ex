# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.SiteDetailsModal do
  @moduledoc """
  Site record modal: **Overview** (read-only Site Details + real `MishkaCmsCore.Runtime.SiteHealth`
  metrics + Allowed Origins) and **Configuration** (the live `MishkaGervaz.Form.Web.Live` Site form).

  Shares ALL chrome (modal shell, segmented tabs, the `detail`/`status_row`/`metric` card helpers) with
  the runtime preview modal via `MishkaCmsCoreWeb.Live.Admin.Components.DetailModal` — this module only
  supplies Site's two tabs + content. Driven by the parent's `@site_modal` map (`record`, `active_tab`,
  `health`, `loading?`, `form_record_id`); the form's `record_id` flows through the template (NOT
  `send_update`) so a parent re-render can't reset it. See the parent
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Site.Index`.
  """
  use Phoenix.Component
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.Site
  alias MishkaCmsCoreWeb.Live.Admin.Components.{DetailModal, SiteHealthPanel}

  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  import DetailModal, only: [detail: 1, status_row: 1, metric: 1, datetime: 1]

  @modal_id "site-details-modal"

  # What a search engine reads of a site that serves pages, each opened on the site's own address.
  @seo_files [
    {"robots.txt", "/robots.txt", "site-details-robots"},
    {gettext_noop("Sitemap"), "/sitemap.xml", "site-details-sitemap"}
  ]

  @tabs [
    {"overview", gettext_noop("Overview"), "hero-presentation-chart-line"},
    {"configuration", gettext_noop("Configuration"), "hero-cog-6-tooth"}
  ]

  attr :site_modal, :map, required: true
  attr :current_user, :any, default: nil

  def modal(assigns) do
    sm = assigns.site_modal

    assigns =
      assigns
      |> assign(:modal_id, @modal_id)
      |> assign(:record, sm.record)
      |> assign(:active_tab, sm.active_tab)
      |> assign(:health, Map.get(sm, :health))
      |> assign(:loading?, Map.get(sm, :loading?) == true)
      |> assign(:form_record_id, Map.get(sm, :form_record_id))
      |> assign(:config_mounted?, Map.get(sm, :config_mounted?) == true)
      |> assign(:form_id, MishkaGervaz.Resource.Info.Form.component_id(Site))
      |> assign(:master?, master_user?(Map.get(assigns, :current_user)))
      |> assign(:tabs, visible_tabs(sm.record))

    ~H"""
    <DetailModal.shell
      id={@modal_id}
      icon="hero-map-pin"
      icon_class="bg-[linear-gradient(140deg,#22b07a,#159463)]"
      title={if(@record, do: @record.name, else: gettext("Add Site"))}
      active_tab={@active_tab}
      tabs={@tabs}
      tab_event="site_modal_set_tab"
      close_event="close_site_modal"
    >
      <:title_prefix :if={@record && @record.master}>
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="#e6b422"
          stroke="#e6b422"
          stroke-width="1.4"
          stroke-linejoin="round"
          class="shrink-0"
        >
          <path d="M12 3l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9 6.8 19.2l1-5.8L3.5 9.2l5.9-.9z" />
        </svg>
      </:title_prefix>

      <:subtitle :if={@record}>{mode_badge(@record.mode)}</:subtitle>

      <:actions :if={@record}>
        <button
          :if={@master? and not @record.active}
          type="button"
          phx-click="site_activate"
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#cfe8dd] bg-[#eaf6ee] px-[13px] text-[12px] font-semibold text-[#177a53] transition-colors hover:bg-[#dcefe4]"
        >
          <.icon name="hero-play-circle" class="size-[14px]" /> {gettext("Activate")}
        </button>
        <button
          :if={@master? and @record.active and not @record.master}
          type="button"
          phx-click="site_deactivate"
          data-confirm={gettext("Deactivate this site? It will stop serving requests.")}
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#f0dccb] bg-[#fdf6ee] px-[13px] text-[12px] font-semibold text-[#c0752a] transition-colors hover:bg-[#fbeedd]"
        >
          <.icon name="hero-pause-circle" class="size-[14px]" /> {gettext("Deactivate")}
        </button>
        <button
          :if={@master? and not @record.master}
          type="button"
          phx-click="site_set_master"
          data-confirm={
            dgettext(
              "mishka_gervaz",
              "Make %{host} the master site? From now on masters sign in only at %{host}, so you will be signed out here.",
              host: @record.host
            )
          }
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-star" class="size-[14px] text-[#c79a1e]" /> {gettext("Set Master")}
        </button>
        <button
          type="button"
          phx-click="site_modal_set_tab"
          phx-value-tab="configuration"
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-pencil-square" class="size-[14px]" /> {gettext("Edit")}
        </button>
      </:actions>

      <div class="max-h-[72vh] overflow-y-auto px-6 py-5">
        <div
          :if={@loading? and is_nil(@record)}
          class={["py-16 text-center text-sm text-zinc-400", @active_tab != "overview" && "hidden"]}
        >
          {gettext("Loading…")}
        </div>

        <div :if={@record} class={["space-y-5", @active_tab != "overview" && "hidden"]}>
          {overview(assigns)}
        </div>

        <%!-- Mounted on the FIRST visit to the Configuration tab and kept mounted afterwards, so a
              click on the eye costs no form load while a half-typed field survives a trip to
              Overview. The form draws its own loading skeleton until its async record read lands. --%>
        <div :if={@config_mounted?} class={[@active_tab != "configuration" && "hidden"]}>
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={@form_id}
            resource={Site}
            current_user={@current_user}
            record_id={@form_record_id}
          />
        </div>
      </div>
    </DetailModal.shell>
    """
  end

  defp overview(assigns) do
    origins = assigns.record.allowed_origins |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    assigns = assign(assigns, origins: origins, seo_files: @seo_files)

    ~H"""
    <div class="grid gap-4 md:grid-cols-2">
      <section class="rounded-[16px] border border-[#ecebe6] p-5">
        <div class="mb-4 flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="size-[15px] text-[#5b57d6]" />
          <span class="text-[13.5px] font-bold text-[#1b1a18]">{gettext("Site Details")}</span>
        </div>
        <dl>
          <div class="mb-[18px] flex gap-8">
            <.detail label={gettext("Mode")}>{mode_badge(@record.mode)}</.detail>
            <.detail label={gettext("Priority")}>{priority_bars(@record.priority)}</.detail>
          </div>

          <.status_row label={gettext("Status")}>
            <span class={[
              "size-1.5 rounded-full",
              if(@record.active, do: "bg-[#1f9d6b]", else: "bg-[#cf8a24]")
            ]}></span>
            <span class={if(@record.active, do: "text-[#177a53]", else: "text-[#a5691a]")}>
              {if(@record.active, do: gettext("Active"), else: gettext("Inactive"))}
            </span>
          </.status_row>
          <.status_row label={gettext("Master Site")}>
            {if(@record.master, do: gettext("Yes"), else: gettext("No"))}
          </.status_row>
          <.status_row label={gettext("Frontend Domain")}>
            <span dir="ltr">
              {if(@record.frontend_domain in [nil, ""],
                do: "—",
                else: domain_url(@record.frontend_domain)
              )}
            </span>
          </.status_row>
          <.status_row
            :for={{label, path, id} <- @seo_files}
            :if={@record.mode != :api_only}
            label={Gettext.gettext(MishkaCmsCore.Gettext, label)}
          >
            <a
              id={id}
              href={Helpers.site_url(@record.host, path)}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-1 text-[#5b57d6] hover:underline"
            >
              <span dir="ltr">{path}</span>
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </a>
          </.status_row>
        </dl>
      </section>

      <section class="rounded-[16px] border border-[#ecebe6] p-5">
        <div class="mb-4 flex items-center justify-between gap-2">
          <div class="flex items-center gap-2">
            <.icon name="hero-presentation-chart-line" class="size-[15px] text-[#177a53]" />
            <span class="text-[13.5px] font-bold text-[#1b1a18]">{gettext("Runtime Health")}</span>
          </div>
          <span class="rounded-[5px] bg-[#e6f6ee] px-[7px] py-[3px] text-[8.5px] font-bold uppercase tracking-[0.08em] text-[#177a53]">
            {gettext("live")}
          </span>
        </div>

        <div :if={@health}>
          <span
            id="site-details-health"
            class={[
              "mb-3.5 inline-flex items-center gap-1.5 rounded-[20px] px-3 py-1 text-[11px] font-bold",
              SiteHealthPanel.pill_tone(@health.state)
            ]}
          >
            <span class={["size-1.5 rounded-full", SiteHealthPanel.dot_tone(@health.state)]}></span> {@health.label}
          </span>
          <div class="mb-4 grid grid-cols-2 gap-2.5">
            <.metric
              icon="hero-arrow-path"
              label={gettext("In Progress")}
              value={length(@health.in_progress)}
            />
            <.metric
              icon="hero-exclamation-triangle"
              label={gettext("Failed")}
              value={length(@health.unrecovered)}
            />
            <.metric
              icon="hero-arrow-uturn-up"
              label={gettext("Recovered")}
              value={length(@health.recovered)}
            />
            <.metric
              icon="hero-squares-2x2"
              label={gettext("Runtime Parts")}
              value={parts_total(@health.parts)}
            />
          </div>
          <dl>
            <.status_row label={gettext("CSS Bundle")}>{bundle_text(@health.assets.css)}</.status_row>
            <.status_row label={gettext("JS Bundle")}>{bundle_text(@health.assets.js)}</.status_row>
            <.status_row label={gettext("Created")}>{datetime(@record.inserted_at)}</.status_row>
            <.status_row label={gettext("Last Updated")}>{datetime(@record.updated_at)}</.status_row>
          </dl>
        </div>
        <div :if={is_nil(@health)} class="py-8 text-center text-[13px] font-medium text-[#a8a5a0]">
          {gettext("Loading health…")}
        </div>
      </section>
    </div>

    <section class="mt-4 rounded-[16px] border border-[#ecebe6] p-5">
      <div class="mb-4 flex items-center gap-2">
        <.icon name="hero-globe-alt" class="size-[15px] text-[#5b57d6]" />
        <span class="text-[13.5px] font-bold text-[#1b1a18]">{gettext("Allowed Origins")}</span>
      </div>
      <div :if={@origins != []} class="flex flex-wrap gap-[6px]">
        <span
          :for={origin <- @origins}
          dir="ltr"
          class="inline-flex items-center whitespace-nowrap rounded-[7px] border border-[#d6e3f5] bg-[#eaf1fb] px-2 py-[3px] font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#3a6cb5]"
        >
          {origin}
        </span>
      </div>
      <p
        :if={@origins == []}
        class="font-['Space_Grotesk'] text-[13px] font-semibold text-[#a8a5a0]"
      >
        —
      </p>
    </section>
    """
  end

  # The mode badge and the priority gauge are drawn by the Gervaz column types the Sites table uses, so
  # the modal and the table share one definition of both the colours and the markup.
  defp mode_badge(mode) do
    MishkaGervaz.Table.Types.Column.Badge.render(
      mode,
      %{ui: %{extra: Site.mode_badge_config()}},
      nil,
      MishkaGervaz.UIAdapters.Tailwind
    )
  end

  defp priority_bars(priority) do
    MishkaGervaz.Table.Types.Column.Bars.render(
      priority || 0,
      %{ui: %{extra: %{max: 4, percent: true}}},
      nil,
      MishkaGervaz.UIAdapters.Tailwind
    )
  end

  defp visible_tabs(nil), do: Enum.reject(@tabs, fn {key, _, _} -> key == "overview" end)
  defp visible_tabs(_record), do: @tabs

  # Master users (no tenant scope) manage activate/deactivate/set-master — mirrors `restricted true`.
  defp master_user?(%{site_id: nil}), do: true
  defp master_user?(_), do: false

  defp domain_url(domain) do
    if MishkaCmsCore.Runtime.OriginValidator.web_url?(domain),
      do: domain,
      else: "https://" <> domain
  end

  defp parts_total(parts) when is_list(parts), do: Enum.sum(Enum.map(parts, &(&1.active || 0)))
  defp parts_total(_), do: 0

  defp bundle_text(%{present?: true, updated_at: %DateTime{} = at}),
    do: gettext("Ready · %{time}", time: datetime(at))

  defp bundle_text(%{present?: true}), do: gettext("Ready")
  defp bundle_text(_), do: gettext("Not built")
end
