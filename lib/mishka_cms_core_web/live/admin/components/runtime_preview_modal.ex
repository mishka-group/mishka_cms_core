# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal do
  @moduledoc """
  Tabbed inspector modal for a single module-backed runtime record (Page / Component /
  Layout / ErrorPage), opened from a table's "Preview" row action.

  Six tabs — **Overview** (stored details + a metrics card), **Preview** (the
  rendered output in a sandboxed `<iframe srcdoc>` with Desktop/Tablet/Mobile widths),
  **Code** (raw source, copy button), **Versions** (recent AshPaperTrail versions),
  **Pipeline** (the live `RuntimeStatusTimeline`), and **Configuration** (the resource's
  `MishkaGervaz.Form.Web.Live` form — this modal is where a record is edited, so there is no
  second form modal on the page).

  Two header actions carry the record's runtime cost, and both are deliberate clicks rather than
  anything the modal does by opening: **Visual Editor** leaves for the builder, and **Force compile**
  builds the record's module now even when it is marked lazy (see
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.force_compile/1`). A component also
  offers **Duplicate**, which writes a new component from this one and closes the modal on it (see
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.duplicate/1`).

  Driven entirely by the `:preview` map that
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers` maintains. The shell uses
  the `runtime-preview-modal` id family so `MishkaCmsCore.CoreComponents.show_modal/1` /
  `hide_modal/1` drive it, like the form modal.

  See `MishkaCmsCore.Runtime.RuntimePreview` (renders the iframe document + Overview rows).

  ## No `style` attribute

  This modal renders in the admin document, which is served the compiled `admin.css`, so every rule
  here is a Tailwind class and a Content-Security-Policy can drop `style-src-attr 'unsafe-inline'` —
  it has no nonce to offer an attribute. The two values that vary are written as whole literal
  classes, one function clause each, because Tailwind reads SOURCE TEXT and a class with an
  interpolation hole gets no rule at all: `device_class/1` sizes the preview frame (in step with
  `MishkaCmsCore.Runtime.RuntimePreview.device_width/1`) and `bar_height_class/1` draws the four
  priority bars.

  The document INSIDE the frame is a separate matter — see `RuntimePreview`, which styles its own
  chrome with a `<style>` element because a class of ours reaches nothing in there. That element is
  nonced: `srcdoc` inherits the ADMIN policy of the page framing it, so an unnonced one is refused
  and the preview renders bare. The nonce is not this component's to pass, though — the modal only
  hands the finished `@html` / `@edit_html` to the frame, and
  `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers`, which builds those strings, reads
  `socket.assigns[:csp_nonce]` off the LiveView that renders this modal.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.RuntimePreview
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, JsHook, Layout, Stylesheet}
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimeStatusTimeline

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCoreWeb.Live.Admin.Components.DetailModal
  alias MishkaCmsCoreWeb.Templates.VersionHistory
  import DetailModal, only: [detail: 1, status_row: 1, metric: 1, datetime: 1]

  @modal_id "runtime-preview-modal"
  # The bundle every site's CSS starts with, which a global stylesheet is built into.
  @shared_base MishkaCmsCore.Runtime.RuntimeStatus.asset_bundle_id("Global")
  @tabs [
    {"overview", gettext_noop("Overview"), "M4 5h16v14H4z M4 10h16"},
    {"preview", gettext_noop("Preview"), "M2 4h20v13H2z M8 21h8"},
    {"code", gettext_noop("Code"), "m9 9-3 3 3 3M15 9l3 3-3 3"},
    {"versions", gettext_noop("Versions"), "M12 8v4l3 2 M12 3a9 9 0 1 0 9 9"},
    {"pipeline", gettext_noop("Pipeline"), "M13 2 4 14h7l-1 8 9-12h-7z"}
  ]
  @devices [
    {"desktop", gettext_noop("Desktop"), "hero-computer-desktop"},
    {"tablet", gettext_noop("Tablet"), "hero-device-tablet"},
    {"mobile", gettext_noop("Mobile"), "hero-device-phone-mobile"}
  ]
  @config_tab {"configuration", gettext_noop("Configuration"),
               "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M19.4 13a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2V21a2 2 0 1 1-4 0v-.2a1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0-1.2-2.9H4a2 2 0 1 1 0-4h.2a1.7 1.7 0 0 0 1.2-2.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 2.9-1.2V4a2 2 0 1 1 4 0v.2a1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9v.1a1.7 1.7 0 0 0 1.6 1H21a2 2 0 1 1 0 4h-.2a1.7 1.7 0 0 0-1.6 1z"}

  attr :preview, :map, required: true

  def modal(assigns) do
    p = assigns.preview

    assigns =
      assigns
      |> assign(:modal_id, @modal_id)
      |> assign(:record, p.record)
      |> assign(:resource, p.resource)
      |> assign(:loading?, p.loading?)
      |> assign(:rendering?, p.rendering?)
      |> assign(:active_tab, p.active_tab)
      |> assign(:device, p.device)
      |> assign(:html, p.html)
      |> assign(:error, p.error)
      |> assign(:status, p.status)
      |> assign(:rows, p.details)
      |> assign(:file_size, p.file_size)
      |> assign(:versions, p.versions)
      |> assign(:versions_total, p.versions_total)
      |> assign(:versions_page, p.versions_page)
      |> assign(:versions_per_page, p.versions_per_page)
      |> assign(:version_masters, p.version_masters)
      |> assign(:expanded_version_id, p.expanded_version_id)
      |> assign(:modified_by, p.modified_by)
      |> assign(:visual_editor_url, p.visual_editor_url)
      |> assign(:drafts_enabled?, p.drafts_enabled?)
      |> assign(:direct_save?, p.direct_save?)
      |> assign(:code_visible?, p.code_visible?)
      |> assign(:editing?, p.editing?)
      |> assign(:edit_source, p.edit_source)
      |> assign(:edit_label, p.edit_label)
      |> assign(:render_nonce, p.render_nonce)
      |> assign(:edit_html, p.edit_html)
      |> assign(:draft, p.draft)
      |> assign(:drafts, p.drafts)
      |> assign(:drafts_total, p.drafts_total)
      |> assign(:drafts_page, p.drafts_page)
      |> assign(:drafts_per_page, p.drafts_per_page)
      |> assign(:live_url, p.live_url)
      |> assign(:preview_source, p.preview_source)
      |> assign(:preview_error_status, p.preview_error_status)
      |> assign(:error_statuses, preview_error_statuses(active_error_record(p)))
      |> assign(:has_config?, p.has_config?)
      |> assign(:config_mounted?, p.config_mounted?)
      |> assign(:versions_loading?, p.versions_loading?)
      |> assign(:compiling?, p.compiling?)
      |> assign(:force_compilable?, p.force_compilable?)
      |> assign(:restorable?, p.restorable?)
      |> assign(:duplicable?, p.duplicable?)
      |> assign(:duplicating?, p.duplicating?)
      |> assign(:writable?, p.writable?)
      |> assign(:metrics, p.metrics)
      |> assign(:current_user, p.current_user)
      |> assign(:form_record_id, p.form_record_id)
      |> assign(:form_id, p.resource && MishkaGervaz.Resource.Info.Form.component_id(p.resource))
      |> assign(:title, title_for(p))
      |> assign(:tabs, tabs_for(p.resource, p.code_visible?, p.has_config?))
      |> assign(:devices, @devices)
      |> assign(:device_class, device_class(p.device))

    ~H"""
    <DetailModal.shell
      id={@modal_id}
      icon="hero-document-text"
      icon_class="bg-gradient-to-br from-indigo-500 to-violet-600"
      title={@title}
      max_width="max-w-6xl"
      active_tab={@active_tab}
      tabs={@tabs}
      tab_event="preview_set_tab"
      tab_style={:folder}
      close_event="close_preview_modal"
    >
      <:subtitle :if={@record}>
        <p dir="ltr" class="truncate text-xs text-zinc-400 rtl:text-right">{subtitle(@record)}</p>
      </:subtitle>
      <:actions>
        <button
          :if={@has_config? and @record}
          type="button"
          phx-click="preview_set_tab"
          phx-value-tab="configuration"
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("Edit")}
        </button>
        <.link
          :if={@live_url}
          href={@live_url}
          target="_blank"
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> {gettext("Open page")}
        </.link>
        <%!-- IT TAKES THE CHOSEN DRAFT WITH IT. The strip above says which draft is selected, and
              leaving for the builder used to forget it — the editor read the drafts table for
              itself and offered whichever was newest, so picking the second badge and clicking
              through landed on an offer to carry on with the first. The id rides in the URL and the
              builder offers THAT one; see `MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive`. --%>
        <.link
          :if={@visual_editor_url}
          navigate={builder_url(@visual_editor_url, @draft)}
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
        >
          <.icon name="hero-paint-brush" class="size-4 text-[#5b57d6]" /> {gettext("Visual Editor")}
        </.link>
        <%!-- Components only, and only where the copy could be written; see
              `PreviewHelpers.duplicate/1`. The label is the state, as on Force compile. --%>
        <button
          :if={@duplicable?}
          type="button"
          id="runtime-preview-duplicate"
          phx-click="preview_duplicate"
          disabled={@duplicating?}
          title={gettext("Make a new component from this one, named after it")}
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3] disabled:cursor-not-allowed disabled:opacity-60"
        >
          <.icon name="hero-document-duplicate" class="size-4" />
          {if @duplicating?, do: gettext("Duplicating…"), else: gettext("Duplicate")}
        </button>
        <%!-- Builds the record's module now even when it is marked lazy. The label is the state,
              not a `phx-disable-with`: this button carries an icon, and the loading attribute
              replaces the whole label with text. --%>
        <button
          :if={@force_compilable?}
          type="button"
          id="runtime-preview-force-compile"
          phx-click="preview_force_compile"
          disabled={@compiling?}
          title={gettext("Build this record's runtime module now, whether or not it is precompiled")}
          class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#ded8f7] bg-[#f4f2fd] px-[13px] text-[12px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#eceafb] disabled:cursor-not-allowed disabled:opacity-60"
        >
          <span
            :if={@compiling?}
            class="size-[13px] animate-spin rounded-full border-2 border-[#c3c1f0] border-t-[#4f4bcc]"
          ></span>
          <.icon :if={!@compiling?} name="hero-bolt" class="size-4" />
          {if @compiling?, do: gettext("Compiling…"), else: gettext("Force compile")}
        </button>
      </:actions>

      <div
        :if={@drafts_enabled?}
        class="border-b border-[#f4ecd6] bg-[#fdfbf3] px-6 py-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#8a7a45]">
            <.icon name="hero-document-duplicate" class="size-4" /> {gettext("Drafts")}
            <span class="rounded-[20px] bg-[#faf0d9] px-2 py-[2px] text-[10px] font-bold tabular-nums text-[#a5691a]">
              {@drafts_total}
            </span>
          </span>

          <%!-- CHOOSE IT OR THROW IT AWAY, from the badge itself. The ✖ is a SIBLING of the badge
                rather than a child of it: a button inside a button is not something a browser will
                render, and the outer one swallows the inner one's clicks — so the delete would have
                selected the draft instead of deleting it. Both sit inside one bordered wrapper, so
                the pair still reads as a single chip. --%>
          <div
            :for={d <- @drafts}
            class={[
              "inline-flex max-w-[13rem] items-center rounded-[9px] border transition-colors",
              if(@draft && @draft.id == d.id,
                do: "border-[#e6d9ab] bg-white text-[#8a7a45] shadow-sm",
                else: "border-[#f0e6c8] bg-[#fbf6e8] text-[#a5691a] hover:bg-white"
              )
            ]}
          >
            <button
              type="button"
              id={"runtime-preview-draft-#{d.id}"}
              phx-click="preview_select_draft"
              phx-value-id={d.id}
              title={draft_title(d)}
              class="inline-flex min-w-0 items-center gap-1.5 py-1 ps-2.5 pe-1 text-[11.5px] font-semibold"
            >
              <span class="size-1.5 shrink-0 rounded-full bg-[#e0a52e]"></span>
              <span class="truncate">{draft_label(d)}</span>
            </button>
            <%!-- The same delete the builder's history sidebar offers, worded the same way, because
                  it is the same row of the same table — see the `delete_draft` row action on
                  `MishkaCmsCore.Runtime.PageDraft`. --%>
            <button
              :if={@writable?}
              type="button"
              id={"runtime-preview-draft-delete-#{d.id}"}
              phx-click="preview_discard_draft"
              phx-value-id={d.id}
              data-confirm={draft_delete_confirm(d)}
              aria-label={gettext("Delete %{label}", label: draft_label(d))}
              title={gettext("Delete %{label}", label: draft_label(d))}
              class="me-1 grid size-[18px] flex-none place-items-center rounded-[6px] text-[#c3ab74] transition-colors hover:bg-rose-50 hover:text-rose-600"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </div>

          <button
            :if={@writable?}
            type="button"
            id="runtime-preview-new-draft"
            phx-click="preview_new_draft"
            class="inline-flex items-center gap-1 rounded-[9px] border border-dashed border-[#c3c1f0] px-[11px] py-[5px] text-[12px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#f2f1fc]"
          >
            <.icon name="hero-plus" class="size-3.5" /> {gettext("New draft")}
          </button>

          <div
            :if={@drafts_total > @drafts_per_page}
            class="ms-auto flex items-center gap-1 text-xs text-amber-700"
          >
            <button
              :if={@drafts_page > 1}
              type="button"
              phx-click="preview_drafts_page"
              phx-value-page={@drafts_page - 1}
              class="rounded p-1 hover:bg-white"
              aria-label={gettext("Previous drafts")}
            >
              <.icon name="hero-chevron-left" class="size-4 rtl:rotate-180" />
            </button>
            <span class="tabular-nums">
              {@drafts_page} / {drafts_pages(@drafts_total, @drafts_per_page)}
            </span>
            <button
              :if={@drafts_page < drafts_pages(@drafts_total, @drafts_per_page)}
              type="button"
              phx-click="preview_drafts_page"
              phx-value-page={@drafts_page + 1}
              class="rounded p-1 hover:bg-white"
              aria-label={gettext("Next drafts")}
            >
              <.icon name="hero-chevron-right" class="size-4 rtl:rotate-180" />
            </button>
          </div>
        </div>

        <div
          :if={@draft}
          class="mt-2 flex flex-wrap items-center gap-2 border-t border-amber-200/70 pt-2 text-xs text-amber-700"
        >
          <span>
            <.marked text={gettext("Selected: %{label} — not live until you publish", label: mark())}>
              <span class="font-medium text-amber-900">{draft_label(@draft)}</span>
            </.marked>
          </span>
          <div class="ms-auto flex items-center gap-2">
            <button
              type="button"
              id="runtime-preview-copy-link"
              phx-hook="CopyToClipboard"
              data-copy={share_link(assigns)}
              title={share_link(assigns)}
              class="inline-flex items-center gap-1.5 rounded-lg border border-amber-300 bg-white px-2.5 py-1 text-xs font-medium text-amber-700 hover:bg-amber-100"
            >
              <.icon name="hero-link" class="size-4" />
              {if draft_context?(assigns),
                do: gettext("Copy draft link"),
                else: gettext("Copy original link")}
            </button>
            <button
              :if={@writable?}
              type="button"
              id="runtime-preview-discard"
              phx-click="preview_discard_draft"
              data-confirm={gettext("Discard this draft? This cannot be undone.")}
              class="inline-flex items-center gap-1.5 rounded-lg border border-rose-200 bg-white px-2.5 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50"
            >
              <.icon name="hero-trash" class="size-4" /> {gettext("Discard")}
            </button>
            <button
              :if={@writable?}
              type="button"
              id="runtime-preview-publish"
              phx-click="preview_publish_draft"
              data-confirm={gettext("Publish this draft to the live page?")}
              class="inline-flex items-center gap-1.5 rounded-lg bg-emerald-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-emerald-700"
            >
              <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Publish")}
            </button>
          </div>
        </div>
      </div>

      <div class="max-h-[70vh] overflow-y-auto p-6">
        <div :if={@active_tab != "configuration"}>
          <%= cond do %>
            <% @loading? -> %>
              <div class="flex items-center justify-center gap-3 py-20 text-zinc-400">
                <div class="size-6 animate-spin rounded-full border-b-2 border-indigo-500"></div>
                {gettext("Loading…")}
              </div>
            <% is_nil(@record) -> %>
              <div class="py-20 text-center text-zinc-400">{gettext("Nothing selected.")}</div>
            <% @active_tab == "overview" and @resource == Component -> %>
              {component_overview_tab(assigns)}
            <% @active_tab == "overview" -> %>
              {overview_tab(assigns)}
            <% @active_tab == "preview" -> %>
              {preview_tab(assigns)}
            <% @active_tab == "code" and @code_visible? -> %>
              {code_tab(assigns)}
            <% @active_tab == "versions" -> %>
              {versions_tab(assigns)}
            <% true -> %>
              {pipeline_tab(assigns)}
          <% end %>
        </div>

        <%!-- Mounted on the FIRST visit to the Configuration tab and kept mounted afterwards
              (toggled by `hidden`), so a click on the eye costs no form load, while a half-typed
              field survives a trip to the Code tab. The form draws its own loading skeleton until
              its async record read lands. --%>
        <div
          :if={@has_config? and @config_mounted?}
          class={[@active_tab != "configuration" && "hidden"]}
        >
          <.live_component
            module={MishkaGervaz.Form.Web.Live}
            id={@form_id}
            resource={@resource}
            current_user={@current_user}
            record_id={@form_record_id}
          />
        </div>
      </div>
    </DetailModal.shell>
    """
  end

  # Component-specific Overview (matches the mockup): a "Component Details" card with the kit metadata
  # and a "Performance Metrics" card. Real data where we have it (Format, Bundle Size, Render Time,
  # Cache, dates, Modified By — the runtime ones from `MishkaCmsCore.Runtime.RenderMetrics`, loaded
  # after the modal opens); sampled where the runtime doesn't track it yet (Usage Count).
  defp component_overview_tab(assigns) do
    pct = assigns.record.priority || 0

    {number_tone, bar_tone} =
      cond do
        pct >= 80 -> {"text-emerald-600", "bg-emerald-500"}
        pct >= 50 -> {"text-amber-500", "bg-amber-500"}
        true -> {"text-zinc-400", "bg-zinc-400"}
      end

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:number_tone, number_tone)
      |> assign(:bar_tone, bar_tone)
      |> assign(:filled, max(1, ceil(pct / 25)))
      |> assign(:deps, List.wrap(assigns.record.dependencies))

    ~H"""
    <div class="grid gap-5 md:grid-cols-2">
      <section class="rounded-xl border border-zinc-200 p-5">
        <h3 class="mb-4 flex items-center gap-2 text-sm font-semibold text-zinc-800">
          <.icon name="hero-cog-6-tooth" class="size-4 text-zinc-400" /> {gettext("Component Details")}
        </h3>
        <dl class="space-y-3 text-sm">
          <div class="grid grid-cols-2 gap-3">
            <.detail label={gettext("Type")}>
              <span
                :if={@record.type && @record.type != ""}
                class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium capitalize text-indigo-700"
              >
                {@record.type}
              </span>
              <span :if={is_nil(@record.type) or @record.type == ""} class="text-zinc-400">—</span>
            </.detail>
            <.detail label={gettext("Format")}>
              <span class="inline-flex items-center rounded-md bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700">
                {@record.format |> to_string() |> String.upcase()}
              </span>
            </.detail>
            <.detail label={gettext("Priority")}>
              <div class="flex items-center gap-2">
                <div class="flex h-4 items-end gap-0.5">
                  <span
                    :for={i <- 1..4}
                    class={[
                      "w-1 rounded-sm",
                      bar_height_class(i),
                      if(i <= @filled, do: @bar_tone, else: "bg-zinc-200")
                    ]}
                  ></span>
                </div>
                <span class={["text-sm font-semibold", @number_tone]}>{@pct}</span>
              </div>
            </.detail>
            <.detail label={gettext("Usage Count")}>
              <span class="text-zinc-400">
                156 <span class="text-[10px]">{gettext("(sample)")}</span>
              </span>
            </.detail>
          </div>

          <div class="space-y-2 border-t border-zinc-100 pt-3">
            <.status_row label={gettext("Status")}>
              <span class={[
                "size-2 rounded-full",
                if(@record.active, do: "bg-emerald-500", else: "bg-zinc-300")
              ]}></span>
              {if(@record.active, do: gettext("Active"), else: gettext("Inactive"))}
            </.status_row>
            <.status_row label={gettext("Compilation")}>
              <span class={[
                "size-2 rounded-full",
                if(precompile(@record), do: "bg-blue-500", else: "bg-amber-500")
              ]}></span>
              {if(precompile(@record), do: gettext("Precompiled"), else: gettext("Dynamic"))}
            </.status_row>
            <.status_row label={gettext("Site")}>
              <.icon name="hero-globe-alt" class="size-4 text-zinc-400" /> {site_name(@record)}
            </.status_row>
          </div>

          <div class="border-t border-zinc-100 pt-3">
            <dt class="mb-2 text-xs font-medium text-zinc-500">{gettext("Dependencies")}</dt>
            <dd class="flex flex-wrap gap-1">
              <span
                :for={dep <- @deps}
                dir="ltr"
                class="inline-flex items-center rounded-md bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700"
              >
                {dep}
              </span>
              <span :if={@deps == []} class="text-xs text-zinc-400">{gettext("None")}</span>
            </dd>
          </div>
        </dl>
      </section>

      <section class="rounded-xl border border-zinc-200 p-5">
        <h3 class="mb-4 flex items-center gap-2 text-sm font-semibold text-zinc-800">
          <.icon name="hero-presentation-chart-line" class="size-4 text-zinc-400" />
          {gettext("Performance Metrics")}
          <span class="ms-auto text-[10px] font-medium text-zinc-400">
            {gettext("this server, since its last build")}
          </span>
        </h3>
        <.metric_grid resource={@resource} metrics={@metrics} file_size={@file_size} />
        <dl class="mt-4 space-y-1 text-sm">
          <.status_row :if={is_map(@metrics) and @metrics[:build]} label={gettext("Last Built")}>
            {datetime(@metrics.build.at)}
          </.status_row>
          <.status_row label={gettext("Last Updated")}>{datetime(@record.updated_at)}</.status_row>
          <.status_row label={gettext("Created")}>{datetime(@record.inserted_at)}</.status_row>
          <.status_row label={gettext("Modified By")}>
            <span id="runtime-preview-modified-by" dir="auto">{@modified_by}</span>
          </.status_row>
        </dl>
      </section>
    </div>
    """
  end

  defp overview_tab(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2">
      <section class="rounded-[16px] border border-[#ecebe6] p-5">
        <h3 class="mb-4 flex items-center gap-2 text-[13.5px] font-bold text-[#1b1a18]">
          <svg
            class="size-[15px]"
            viewBox="0 0 24 24"
            fill="none"
            stroke="#5b57d6"
            stroke-width="1.9"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <circle cx="12" cy="12" r="3.2" />
            <path d="M12 3v2.5M12 18.5V21M4.2 7l1.8 1M18 16l1.8 1M4.2 17l1.8-1M18 8l1.8-1" />
          </svg>
          {gettext("Details")}
        </h3>
        <dl class="space-y-3 text-sm">
          <div class="grid grid-cols-2 gap-3">
            <.detail :for={{label, value} <- @rows} label={label}>{value}</.detail>
          </div>
          <.detail
            :if={is_binary(Map.get(@record, :description)) and @record.description != ""}
            label={gettext("Description")}
          >
            <span id="preview-description" class="font-medium" dir="auto">{@record.description}</span>
          </.detail>
          <div class="space-y-1">
            <.status_row label={gettext("Status")}>
              <span class={[
                "inline-flex items-center gap-1.5",
                if(@record.active, do: "text-[#177a53]", else: "text-[#8a877f]")
              ]}>
                <span class={[
                  "size-[6px] rounded-full",
                  if(@record.active, do: "bg-[#1f9d6b]", else: "bg-[#a8a5a0]")
                ]}></span>
                {if(@record.active, do: gettext("Active"), else: gettext("Inactive"))}
              </span>
            </.status_row>
            <.status_row :if={is_boolean(precompile(@record))} label={gettext("Compilation")}>
              <span class={[
                "inline-flex items-center gap-1.5",
                if(precompile(@record), do: "text-[#3a5bc4]", else: "text-[#c0752a]")
              ]}>
                <span class={[
                  "size-[6px] rounded-full",
                  if(precompile(@record), do: "bg-[#3a5bc4]", else: "bg-[#e0a52e]")
                ]}></span>
                {if(precompile(@record),
                  do: gettext("Precompiled"),
                  else: gettext("Lazy (on first request)")
                )}
              </span>
            </.status_row>
            <.status_row label={gettext("Site")}>
              <.icon name="hero-globe-alt" class="size-4 text-[#a8a5a0]" />
              {site_name(@record)}
            </.status_row>
          </div>
        </dl>
      </section>

      <section class="rounded-[16px] border border-[#ecebe6] p-5">
        <h3 class="mb-4 flex items-center gap-2 text-[13.5px] font-bold text-[#1b1a18]">
          <.icon name="hero-presentation-chart-line" class="size-4 text-[#177a53]" />
          {gettext("Performance Metrics")}
          <span class="ms-auto text-[10px] font-medium text-[#a8a5a0]">
            {metrics_scope(@resource)}
          </span>
        </h3>
        <.metric_grid resource={@resource} metrics={@metrics} file_size={@file_size} />
        <dl class="mt-4 space-y-1 text-sm">
          <.status_row :if={is_map(@metrics) and @metrics[:build]} label={gettext("Last Built")}>
            {datetime(@metrics.build.at)}
          </.status_row>
          <.status_row label={gettext("Last Updated")}>{datetime(@record.updated_at)}</.status_row>
          <.status_row label={gettext("Created")}>{datetime(@record.inserted_at)}</.status_row>
          <.status_row label={gettext("Modified By")}>
            <span id="runtime-preview-modified-by" dir="auto">{@modified_by}</span>
          </.status_row>
        </dl>
      </section>
    </div>
    """
  end

  # A bundle lives in this node's memory and is not rebuilt per render, so its numbers are this
  # server's now; a rendered record's restart with its module.
  defp metrics_scope(resource) when resource in [Stylesheet, JsHook], do: gettext("this server")
  defp metrics_scope(_rendered), do: gettext("this server, since its last build")

  # THE FOUR BOXES OF A RECORD'S RUNTIME NUMBERS, as `PreviewHelpers` read them: one grid for the
  # records `MishkaCmsCore.Runtime.RenderMetrics` times, one for those built into a bundle.
  attr :resource, :atom, required: true
  attr :metrics, :any, required: true
  attr :file_size, :any, required: true

  # A STYLESHEET OR A JS HOOK IS BUILT INTO ITS SITE'S BUNDLE, not rendered: its boxes are that
  # bundle — its size as visitors download it, whether it is built and how long the last rebuild
  # took — and a fourth of its own: when the CSS was built, or how many templates attach the hook.
  # EVERY BOX ONE HEIGHT. `auto-rows-fr` makes each row as tall as the tallest box in the grid, so a
  # box with a hint under its value does not leave its neighbours, or the other row, shorter.
  defp metric_grid(%{resource: resource} = assigns) when resource in [Stylesheet, JsHook] do
    ~H"""
    <div class="grid auto-rows-fr grid-cols-2 gap-3">
      <div id="runtime-preview-bundle">
        <.metric
          icon="hero-archive-box"
          label={bundle_label(@resource, @metrics)}
          value={bundle_size(@metrics)}
          hint={bundle_hint(@metrics)}
          real={is_map(@metrics)}
        />
      </div>
      <.metric icon="hero-document" label={file_label(@resource)} value={@file_size} real />
      <div id="runtime-preview-build">
        <.metric
          icon="hero-wrench-screwdriver"
          label={gettext("Build")}
          value={build(@metrics)}
          hint={build_hint(@metrics)}
          real={is_map(@metrics)}
        />
      </div>
      <div :if={@resource == Stylesheet} id="runtime-preview-last-built">
        <.metric
          icon="hero-calendar"
          label={gettext("Last Built")}
          value={built_at(@metrics)}
          hint={version(@metrics)}
          real={is_map(@metrics)}
        />
      </div>
      <div :if={@resource == JsHook} id="runtime-preview-named-in">
        <.metric
          icon="hero-code-bracket"
          label={gettext("Named In")}
          value={named_in(@metrics)}
          hint={named_in_hint(@metrics)}
          real={is_map(@metrics)}
        />
      </div>
    </div>
    """
  end

  defp metric_grid(assigns) do
    ~H"""
    <div class="grid auto-rows-fr grid-cols-2 gap-3">
      <div id="runtime-preview-render-time">
        <.metric
          icon="hero-clock"
          label={gettext("Render Time")}
          value={render_time(@metrics)}
          hint={render_time_hint(@metrics)}
          hint_navigate={settings_link(@metrics)}
          real={is_map(@metrics) and @metrics.on?}
        />
      </div>
      <.metric icon="hero-document" label={file_label(@resource)} value={@file_size} real />
      <div id="runtime-preview-cache">
        <.metric
          icon="hero-circle-stack"
          label={gettext("Cache")}
          value={cache(@metrics)}
          hint={cache_hint(@metrics)}
          real={is_map(@metrics)}
        />
      </div>
      <div id="runtime-preview-rerenders">
        <.metric
          icon="hero-arrow-path"
          label={rerenders_label(@resource)}
          value={rerenders(@resource, @metrics)}
          hint={rerenders_hint(@resource, @metrics)}
          hint_navigate={settings_link(@metrics)}
          real={is_map(@metrics) and @metrics.on?}
        />
      </div>
    </div>
    """
  end

  # THE BUNDLE A STYLESHEET IS IN, as `PreviewHelpers` read it from `AssetsState`.
  defp bundle_label(Stylesheet, %{bundle: @shared_base}), do: gettext("Shared CSS")
  defp bundle_label(Stylesheet, _site_or_loading), do: gettext("Site CSS")
  defp bundle_label(JsHook, _site_or_loading), do: gettext("Site JS")

  defp bundle_size(metrics) when not is_map(metrics), do: gettext("Loading…")

  defp bundle_size(%{site_bundles: n}) when is_integer(n),
    do: ngettext("In %{count} site bundle", "In %{count} site bundles", n)

  defp bundle_size(%{sizes: nil}), do: "—"
  defp bundle_size(%{sizes: %{brotli: n}}) when is_integer(n), do: RuntimePreview.format_bytes(n)
  defp bundle_size(%{sizes: %{raw: n}}), do: RuntimePreview.format_bytes(n)

  defp bundle_hint(metrics) when not is_map(metrics), do: nil

  defp bundle_hint(%{lazy?: true, site_bundles: n}) when is_integer(n),
    do: gettext("Built on its own beside each site's JS, loaded when a page first uses it")

  defp bundle_hint(%{lazy?: true}), do: gettext("Not in it: loaded when a page first uses it")

  defp bundle_hint(%{site_bundles: n}) when is_integer(n),
    do: gettext("Built into each site's JS")

  defp bundle_hint(%{sizes: nil}), do: gettext("Not built on this server")

  defp bundle_hint(%{sizes: %{brotli: brotli} = sizes} = metrics) when is_integer(brotli),
    do:
      with_shared(
        metrics,
        gettext("Brotli; raw %{raw} · gzip %{gzip}",
          raw: RuntimePreview.format_bytes(sizes.raw),
          gzip: RuntimePreview.format_bytes(sizes.gzip || sizes.raw)
        )
      )

  defp bundle_hint(%{sizes: _uncompressed} = metrics),
    do: with_shared(metrics, gettext("Not compressed"))

  defp with_shared(%{bundle: @shared_base}, hint),
    do: hint <> " · " <> gettext("the start of every site's CSS")

  defp with_shared(_site, hint), do: hint

  defp build(metrics) when not is_map(metrics), do: gettext("Loading…")
  defp build(%{state: :compiling}), do: gettext("Building…")
  defp build(%{left_out?: true}), do: gettext("Left out")
  defp build(%{state: :failed}), do: gettext("Failed")
  defp build(%{state: state}) when state in [:inactive, :archived], do: gettext("Not in a bundle")
  defp build(%{site_bundles: n}) when is_integer(n) and n > 0, do: gettext("Built")
  defp build(%{site_bundles: 0}), do: gettext("Not built")
  defp build(%{sizes: nil}), do: gettext("Not built")
  defp build(_built), do: gettext("Built")

  defp build_hint(%{left_out?: true}),
    do: gettext("It did not build, and the rest of the bundle does; see the Pipeline tab")

  defp build_hint(%{state: :failed}), do: gettext("See the Pipeline tab")

  defp build_hint(%{took_ms: ms}) when is_integer(ms),
    do: gettext("Last rebuild took %{time}", time: duration(ms * 1000))

  defp build_hint(_no_rebuild_since_boot), do: nil

  defp built_at(metrics) when not is_map(metrics), do: gettext("Loading…")
  defp built_at(%{updated_at: %DateTime{} = at}), do: datetime(at)
  defp built_at(_never), do: "—"

  defp version(%{hash: hash}) when is_binary(hash),
    do: gettext("Version %{hash}", hash: String.slice(hash, 0, 8))

  defp version(_none), do: nil

  # HOW MANY TEMPLATES ATTACH THE HOOK (`PageBuilder.Hooks.named_in/3`): one component that does is
  # one, however many pages draw it.
  defp named_in(metrics) when not is_map(metrics), do: gettext("Loading…")
  defp named_in(%{named_in: n}), do: ngettext("%{count} template", "%{count} templates", n)

  defp named_in_hint(%{named_in: 0}), do: gettext("No page, layout or component attaches it")
  defp named_in_hint(%{named_in: _n}), do: gettext("Pages, layouts and components that attach it")
  defp named_in_hint(_loading), do: nil

  # A component's file is its template, which the kit calls its bundle.
  defp file_label(Component), do: gettext("Bundle Size")
  defp file_label(_resource), do: gettext("File Size")

  defp preview_tab(assigns) do
    draft_view? = assigns.preview_source == "draft"
    show_edit? = draft_view? and assigns.edit_html != nil

    # `live_src` is the full-LiveView URL for the current view (`<iframe src>`, no sandbox — JS hooks
    # and `<.component>` run). Page, Layout and ErrorPage all reach BOTH their original and their
    # draft this way, each by its own `preview_token`. nil => fall back to the unsaved-edit doc or
    # the static `@html`, which is how a Component (no token, no route) is previewed.
    #
    # ALWAYS THE ADMIN'S OWN ORIGIN, never the record's site host — see
    # `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.frame_url/1`. A site's domain can
    # resolve to a different machine entirely, and the admin's `frame-src 'self'` refuses it anyway.
    framed =
      cond do
        show_edit? -> nil
        draft_view? -> assigns.draft
        true -> assigns.record
      end

    live_src = framed && with_status(frame_url(framed), assigns)

    # The address bar names the frame's full address: the same preview on the admin's own domain.
    url_text =
      cond do
        show_edit? ->
          gettext("Unsaved edit · %{label}", label: draft_label(assigns.draft || %{}))

        live_src ->
          with_status(draft_url(framed, assigns.current_user), assigns)

        true ->
          "#{site_name(assigns.record)}#{subtitle(assigns.record)}"
      end

    assigns =
      assigns
      |> assign(:draft_view?, draft_view?)
      |> assign(:show_edit?, show_edit?)
      |> assign(:live_src, live_src)
      |> assign(:draft_live?, draft_view? and live_src != nil)
      |> assign(:original_live?, !draft_view? and live_src != nil)
      |> assign(:has_draft_toggle?, assigns.draft != nil or assigns.edit_html != nil)
      |> assign(:url_text, url_text)

    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <div :if={@has_draft_toggle?} class="flex items-center gap-1 rounded-lg bg-zinc-100 p-1">
            <button
              :for={{key, label} <- [{"original", gettext("Original")}, {"draft", gettext("Draft")}]}
              type="button"
              phx-click="preview_set_source"
              phx-value-source={key}
              class={[
                "rounded-md px-3 py-1 text-xs font-medium transition-colors",
                if(@preview_source == key,
                  do: "bg-white text-zinc-900 shadow ring-1 ring-zinc-200",
                  else: "text-zinc-500 hover:text-zinc-800"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <h3
            :if={not @has_draft_toggle?}
            class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]"
          >
            {gettext("Preview")}
          </h3>
        </div>
        <div class="flex items-center gap-1 rounded-[10px] border border-[#ecebe6] bg-[#f6f5f2] p-[3px]">
          <button
            :for={{key, label, dev_icon} <- @devices}
            type="button"
            phx-click="preview_set_device"
            phx-value-device={key}
            class={[
              "flex h-8 items-center gap-1.5 rounded-[8px] px-3 text-[11.5px] font-semibold transition-colors",
              if(@device == key,
                do: "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,0.1)]",
                else: "text-[#8a877f] hover:text-[#3a382f]"
              )
            ]}
          >
            <.icon name={dev_icon} class="size-[13px]" /> {Gettext.gettext(
              MishkaCmsCore.Gettext,
              label
            )}
          </button>
        </div>
      </div>

      <%!-- ErrorPage holds many error templates (404/500/…). This SKY-toned "Error code" picker
            (deliberately distinct from the amber Drafts picker above) chooses which one to render. --%>
      <div
        :if={@error_statuses != []}
        class="flex flex-wrap items-center gap-1.5 rounded-lg border border-sky-200 bg-sky-50 px-3 py-2"
      >
        <span class="inline-flex items-center gap-1 text-xs font-semibold text-sky-800">
          <.icon name="hero-exclamation-triangle" class="size-4" /> {gettext("Error code")}
        </span>
        <button
          :for={status <- @error_statuses}
          type="button"
          phx-click="preview_set_error"
          phx-value-status={status}
          class={[
            "rounded-md px-2.5 py-0.5 text-xs font-semibold tabular-nums transition-colors",
            if(@preview_error_status == status,
              do: "bg-sky-600 text-white shadow",
              else: "bg-white text-sky-700 ring-1 ring-sky-200 hover:bg-sky-100"
            )
          ]}
        >
          {status}
        </button>
      </div>

      <div
        :if={@show_edit?}
        class="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
      >
        <.icon name="hero-eye" class="size-4 shrink-0" />
        <span>
          {gettext(
            "Unsaved edit — a static preview of your changes. Save it as a draft for the full live-lifecycle preview."
          )}
        </span>
      </div>

      <div
        :if={@draft_live?}
        class="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
      >
        <.icon name="hero-eye" class="size-4 shrink-0" />
        <span>
          <.marked text={
            gettext(
              "Previewing the %{draft} — full page lifecycle (JS hooks & components run), styled with temporary CSS. Switch to “Original” to compare with the current page.",
              draft: mark()
            )
          }>
            <b>{gettext("draft")}</b>
          </.marked>
        </span>
      </div>

      <div
        :if={@original_live?}
        class="flex items-center gap-[10px] rounded-[11px] border border-[#d7eddf] bg-[#eefaf2] px-[14px] py-3 text-[12px] font-semibold text-[#177a53]"
      >
        <.icon name="hero-bolt" class="size-4 shrink-0" />
        <span>
          {gettext("Full page lifecycle — components and JS hooks run exactly as visitors see them.")}
        </span>
      </div>

      <div
        :if={not @draft_view? and is_nil(@live_src) and !is_nil(@error)}
        class="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
        <span>
          {gettext(
            "This output couldn't render fully standalone — showing a fallback. Source is on the Code tab."
          )}
        </span>
      </div>

      <div class="overflow-hidden rounded-[14px] border border-[#ecebe6]">
        <div class="flex items-center gap-2 border-b border-[#ecebe6] bg-[#faf9f6] px-[14px] py-[10px]">
          <span class="size-[10px] rounded-full bg-[#f0655a]"></span>
          <span class="size-[10px] rounded-full bg-[#f2bd42]"></span>
          <span class="size-[10px] rounded-full bg-[#5fc466]"></span>
          <div
            dir="ltr"
            class="ms-1 flex-1 truncate rounded-[7px] bg-white px-3 py-1.5 font-['Space_Grotesk'] text-[11px] font-medium text-[#8a877f] rtl:text-right"
          >
            {@url_text}
          </div>
        </div>
        <div class="flex max-h-[60vh] justify-center overflow-auto bg-[#f4f3ef] p-4">
          <div class={["relative max-w-full", @device_class]}>
            <%!-- `live_src`: the real `/_preview/:resource/:token` (draft or original) or a Page's live
                  URL — full lifecycle, JS hooks + components, no sandbox. Its id is keyed by source +
                  error status + nonce so switching view/code/draft actually reloads it. Edit: a
                  sandboxed static doc of unsaved changes. Static `@html`: a sandboxed fallback for an
                  inactive Page. The spinner sits BEHIND the (transparent-until-loaded) iframe. --%>
            <div
              :if={@live_src}
              class="pointer-events-none absolute inset-0 flex items-center justify-center gap-2 text-sm text-zinc-400"
            >
              <div class="size-5 animate-spin rounded-full border-b-2 border-indigo-500"></div>
              {if @draft_view?,
                do: gettext("Loading the draft…"),
                else: gettext("Loading the preview…")}
            </div>
            <iframe
              :if={@live_src}
              id={"runtime-preview-live-#{@record.id}-#{@preview_source}-#{@preview_error_status}-#{@render_nonce}"}
              src={@live_src}
              referrerpolicy="no-referrer"
              loading="lazy"
              phx-update="ignore"
              class="relative h-[52vh] w-full border-0"
            ></iframe>
            <iframe
              :if={@show_edit?}
              id={"runtime-preview-edit-#{@record.id}-#{@render_nonce}"}
              srcdoc={@edit_html}
              sandbox={sandbox(@resource)}
              referrerpolicy="no-referrer"
              loading="lazy"
              phx-update="ignore"
              class="h-[52vh] w-full border-0 bg-white"
            ></iframe>
            <div
              :if={@draft_view? and is_nil(@live_src) and not @show_edit?}
              class="flex h-[52vh] w-full items-center justify-center bg-white px-6 text-center text-sm text-zinc-400"
            >
              {gettext("Pick a draft above, or edit the Code tab and “Re-render preview”.")}
            </div>
            <div
              :if={@rendering?}
              class="flex h-[52vh] w-full items-center justify-center gap-3 bg-white text-sm text-zinc-400"
            >
              <div class="size-6 animate-spin rounded-full border-b-2 border-indigo-500"></div>
              {gettext("Rendering the component…")}
            </div>
            <iframe
              :if={not @draft_view? and is_nil(@live_src) and @html}
              id={"runtime-preview-iframe-#{@record.id}-#{@render_nonce}"}
              srcdoc={@html}
              sandbox={sandbox(@resource)}
              referrerpolicy="no-referrer"
              loading="lazy"
              phx-update="ignore"
              class="h-[52vh] w-full border-0 bg-white"
            ></iframe>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp code_tab(assigns) do
    assigns = assign(assigns, :source, RuntimePreview.source(assigns.draft || assigns.record))

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="flex items-center gap-2 font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
          {gettext("Source")}
          <span
            :if={@draft}
            class="rounded-[5px] bg-[#fbf1df] px-1.5 py-0.5 text-[10px] font-bold text-[#a5691a]"
          >
            {gettext("Draft")}
          </span>
        </h3>
        <div class="flex items-center gap-2">
          <button
            :if={(@drafts_enabled? or @direct_save?) and @writable? and not @editing?}
            type="button"
            id="runtime-preview-edit-code"
            phx-click="preview_edit_code"
            class="inline-flex h-[34px] items-center gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
          >
            <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
          </button>
          <button
            :if={not @editing?}
            type="button"
            id="runtime-preview-copy"
            phx-hook="CopyToClipboard"
            data-copy={@source}
            class="inline-flex h-[34px] items-center gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white px-3 text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> {gettext("Copy")}
          </button>
        </div>
      </div>

      <%= cond do %>
        <% @editing? and @direct_save? -> %>
          <%!-- NO DRAFT TO SAVE INTO: the edit is the record's, saved by the same update the
              Configuration tab runs. --%>
          <form
            id="preview-code-save-form"
            phx-change="preview_code_change"
            phx-submit="preview_code_save"
            class="space-y-3"
          >
            <textarea
              name="source"
              phx-debounce="500"
              dir="ltr"
              rows="18"
              spellcheck="false"
              class="block w-full rounded-xl border border-zinc-300 bg-zinc-950 p-4 font-mono text-xs leading-relaxed text-zinc-100 focus:border-indigo-500 focus:ring-indigo-500"
            ><%= @edit_source %></textarea>
            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                phx-click="preview_cancel_edit"
                class="rounded-lg border border-zinc-200 px-3 py-1.5 text-xs font-medium text-zinc-600 hover:bg-zinc-50"
              >
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                id="preview-code-save"
                phx-disable-with={gettext("Saving…")}
                class="inline-flex items-center gap-1.5 rounded-lg bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-700"
              >
                <.icon name="hero-check" class="size-4" /> {gettext("Save")}
              </button>
            </div>
          </form>
        <% @editing? -> %>
          <form
            id="preview-code-form"
            phx-change="preview_code_change"
            phx-submit="preview_code_submit"
            class="space-y-3"
          >
            <input
              type="text"
              name="label"
              phx-debounce="500"
              value={@edit_label || (@draft && @draft.label)}
              dir="auto"
              maxlength="120"
              placeholder={
                if @draft,
                  do: gettext("Label this draft"),
                  else: gettext("Label this new draft (e.g. Hero redesign)")
              }
              class="block w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm text-zinc-800 focus:border-indigo-500 focus:ring-indigo-500"
            />
            <textarea
              name="source"
              phx-debounce="500"
              dir="ltr"
              rows="18"
              spellcheck="false"
              class="block w-full rounded-xl border border-zinc-300 bg-zinc-950 p-4 font-mono text-xs leading-relaxed text-zinc-100 focus:border-indigo-500 focus:ring-indigo-500"
            ><%= @edit_source %></textarea>
            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                phx-click="preview_cancel_edit"
                class="rounded-lg border border-zinc-200 px-3 py-1.5 text-xs font-medium text-zinc-600 hover:bg-zinc-50"
              >
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                name="op"
                value="rerender"
                class="inline-flex items-center gap-1.5 rounded-lg border border-zinc-200 px-3 py-1.5 text-xs font-medium text-zinc-700 hover:bg-zinc-50"
              >
                <.icon name="hero-arrow-path" class="size-4" /> {gettext("Re-render preview")}
              </button>
              <button
                type="submit"
                name="op"
                value="save"
                class="inline-flex items-center gap-1.5 rounded-lg bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-700"
              >
                <.icon name="hero-bookmark" class="size-4" /> {gettext("Save as draft")}
              </button>
            </div>
          </form>
        <% true -> %>
          <pre
            id="runtime-preview-source"
            dir="ltr"
            class="max-h-[55vh] overflow-auto rounded-[12px] bg-[#1c1b22] p-[18px] font-['Space_Grotesk'] text-[12px] leading-[1.6] text-[#c9c6d6] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
          ><code phx-no-curly-interpolation><%= @source %></code></pre>
      <% end %>
    </div>
    """
  end

  # The Versions tab reuses the SAME shared component as the blog admin pages
  # (`MishkaCmsCoreWeb.Templates.VersionHistory.panel/1`) — every place with AshPaperTrail history
  # shows it the same way. The panel's events are parameterised so the modal keeps its own handlers
  # (`preview_version_toggle` / `preview_version_restore` / `preview_versions_page`). `-mx-6` cancels
  # the tab wrapper's horizontal padding so the panel's own `px-[22px]` sets the inset.
  defp versions_tab(assigns) do
    ~H"""
    <div class="-mx-6">
      <div class="flex items-center justify-between px-[22px] pb-1">
        <h3 class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
          {gettext("Version History")}
        </h3>
        <span class="inline-flex items-center gap-1.5 text-[11.5px] font-semibold text-[#a8a5a0]">
          <svg
            class="size-[13px]"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.9"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M7 4v16M7 4l-3 3M7 4l3 3M17 20V4M17 20l-3-3M17 20l3-3" />
          </svg>
          {gettext("%{count} version(s)", count: @versions_total)}
        </span>
      </div>

      <%!-- `loading` is the panel's own skeleton: a page of versions is a read plus a count and a
            restore is a write before both, so the tab says so instead of freezing the modal. --%>
      <VersionHistory.panel
        id="runtime-preview-versions"
        versions={@versions}
        loading={@versions_loading?}
        page={@versions_page}
        per_page={@versions_per_page}
        total={@versions_total}
        preview_id={@expanded_version_id}
        master_ids={@version_masters}
        toggle_event="preview_version_toggle"
        restore_event="preview_version_restore"
        prev_event="preview_versions_page"
        next_event="preview_versions_page"
        empty_hint={gettext("Edits to this record will be recorded here.")}
      />
    </div>
    """
  end

  defp mark, do: "\u0000"

  attr :text, :string, required: true
  slot :inner_block, required: true

  defp marked(assigns) do
    {head, tail} =
      case String.split(assigns.text, mark(), parts: 2) do
        [head, tail] -> {head, tail}
        [whole] -> {whole, nil}
      end

    assigns = assign(assigns, head: head, tail: tail)

    ~H"""
    {@head}{if @tail, do: render_slot(@inner_block)}{@tail}
    """
  end

  defp pipeline_tab(assigns) do
    ~H"""
    <div class="rounded-xl border border-zinc-200">
      <RuntimeStatusTimeline.timeline :if={@status} status={@status} record={@record} />
    </div>
    """
  end

  # A record is titled by its name; the "+ Add" modal has no record and used to be titled "Preview",
  # which is the one thing it is not. The label comes from `RuntimeStatus.config/1` so the modal and
  # the Pipeline timeline call a record the same thing.
  defp title_for(%{record: record}) when not is_nil(record), do: record.name
  defp title_for(%{loading?: true}), do: gettext("Loading…")
  defp title_for(%{resource: nil}), do: gettext("Preview")

  defp title_for(%{resource: resource}),
    do:
      gettext("New %{kind}",
        kind:
          Gettext.gettext(
            MishkaCmsCore.Gettext,
            MishkaCmsCore.Runtime.RuntimeStatus.config(resource).label
          )
      )

  # Code-asset resources are JS and CSS — there is no page to render, so they drop the Preview tab
  # and keep everything else, the compile pipeline (their Oban jobs → the per-site bundle) included.
  # The Code tab is hidden for users who can't edit (a tenant on a global Layout) — preview-only.
  # Configuration is last, because it is where you leave the record changed.
  @asset_resources [MishkaCmsCore.Runtime.JsHook, MishkaCmsCore.Runtime.Stylesheet]

  defp tabs_for(resource, code_visible?, has_config?) do
    @tabs
    |> drop_tab("preview", resource in @asset_resources)
    |> drop_tab("code", !code_visible?)
    |> append_config(has_config?)
  end

  defp drop_tab(tabs, key, true), do: Enum.reject(tabs, fn {k, _, _} -> k == key end)
  defp drop_tab(tabs, _key, false), do: tabs

  defp append_config(tabs, true), do: tabs ++ [@config_tab]
  defp append_config(tabs, false), do: tabs

  # A COMPONENT'S DOCUMENT GENERATES ITS OWN CSS, so its frame has to run a script; every other
  # preview links a compiled bundle and stays fully sandboxed.
  #
  # `allow-scripts` WITHOUT `allow-same-origin` is the safe half of the pair: the frame gets an
  # opaque origin, so the generator runs while an author's template can reach neither this document
  # nor its cookies nor its storage. Granting both together would let the frame remove its own
  # sandbox, which is the whole reason they are separate flags — and it is also why the engine is
  # inlined rather than linked, since an opaque origin cannot fetch a subresource.
  defp sandbox(Component), do: "allow-scripts"
  defp sandbox(_resource), do: ""

  defp device_class("tablet"), do: "w-[768px]"
  defp device_class("mobile"), do: "w-[375px]"
  defp device_class(_desktop), do: "w-[1280px]"

  defp bar_height_class(1), do: "h-[25%]"
  defp bar_height_class(2), do: "h-[50%]"
  defp bar_height_class(3), do: "h-[75%]"
  defp bar_height_class(_full), do: "h-[100%]"

  defp preview_error_statuses(nil), do: []
  defp preview_error_statuses(record), do: RuntimePreview.error_statuses(record)

  # The Error-code badges follow the active source: the selected draft on the Draft view (its codes
  # may differ from the live record), the live record on Original.
  defp active_error_record(%{preview_source: "draft", draft: draft}) when not is_nil(draft),
    do: draft

  defp active_error_record(%{record: record}), do: record

  defp draft_url(draft, viewer),
    do: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.preview_url(draft, viewer)

  # What the modal FRAMES: the same preview, on this admin's origin. A record with no token — a
  # Component — has no such route, and `nil` sends the tab to its static document instead.
  defp frame_url(record),
    do: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers.frame_url(record)

  # ErrorPage holds many status codes; carry the selected one on the preview URL so the LiveView
  # renders it. Other resources ignore it. A missing URL stays missing rather than becoming a bare
  # query string — `preview_url/1` answers `""` for a record with no token, `frame_url/1` answers nil.
  defp with_status(blank, _assigns) when blank in [nil, ""], do: blank

  defp with_status(url, %{resource: ErrorPage, preview_error_status: status})
       when not is_nil(status),
       do: url <> "?status=#{status}"

  defp with_status(url, _assigns), do: url

  # The shareable link for whatever is currently in focus: the selected draft's preview when a draft
  # context is active (Code tab, or the Preview tab's Draft view), else the original page's live URL.
  #
  # A preview link names the sharing admin's domain, the master site's or their own site's
  # (`PreviewHelpers.preview_url/2`); a page's live URL stays the page's own address.
  defp share_link(assigns) do
    cond do
      assigns.draft && draft_context?(assigns) ->
        with_status(draft_url(assigns.draft, assigns.current_user), assigns)

      assigns.live_url ->
        assigns.live_url

      assigns.draft ->
        with_status(draft_url(assigns.draft, assigns.current_user), assigns)

      true ->
        with_status(draft_url(assigns.record, assigns.current_user), assigns) || ""
    end
  end

  defp draft_context?(assigns),
    do: assigns.active_tab == "code" or assigns.preview_source == "draft"

  defp draft_label(%{label: label}) when is_binary(label) and label != "",
    do: MishkaCmsCore.Runtime.PageBuilder.Drafts.display_label(label)

  defp draft_label(_draft), do: gettext("Untitled draft")

  # `site_id` may already be on the URL, so the separator is asked for rather than assumed.
  defp builder_url(url, %{id: id}) when is_binary(id),
    do: url <> if(String.contains?(url, "?"), do: "&", else: "?") <> "draft_id=" <> id

  defp builder_url(url, _no_draft), do: url

  # Word for word what the builder's own draft list asks, because they delete the same row.
  defp draft_delete_confirm(draft),
    do: gettext("Delete the draft “%{label}”? This cannot be undone.", label: draft_label(draft))

  defp draft_title(draft) do
    updated = Map.get(draft, :updated_at) || Map.get(draft, :inserted_at)
    stamp = if updated, do: " · " <> Calendar.strftime(updated, "%Y-%m-%d %H:%M"), else: ""
    "#{draft_label(draft)}#{stamp}"
  end

  defp drafts_pages(total, per_page) when per_page > 0,
    do: max(1, div(total + per_page - 1, per_page))

  defp drafts_pages(_total, _per_page), do: 1

  defp subtitle(record), do: Map.get(record, :path) || ""

  defp precompile(record), do: Map.get(record, :precompile)

  # A TIMED RECORD'S RUNTIME NUMBERS, as `PreviewHelpers` read them: `:loading` until the read lands,
  # then whether the module is in memory, its render times and its last build.
  defp render_time(metrics) when not is_map(metrics), do: gettext("Loading…")
  defp render_time(%{on?: false}), do: gettext("Not active")
  defp render_time(%{loaded?: false}), do: gettext("Not loaded")
  defp render_time(%{stats: :hidden}), do: "—"
  defp render_time(%{stats: %{full: %{count: n, avg_us: us}}}) when n > 0, do: duration(us)
  defp render_time(_no_renders), do: gettext("No renders")

  defp render_time_hint(metrics) when not is_map(metrics), do: nil
  defp render_time_hint(%{on?: false}), do: gettext("Turn it on in Settings → Performance")
  defp render_time_hint(%{loaded?: false}), do: nil

  defp render_time_hint(%{stats: :hidden}),
    do: gettext("Counted on every site; shown to master admins")

  defp render_time_hint(%{stats: %{full: %{count: n}}}) when n > 0,
    do: ngettext("Average of %{count} full render", "Average of %{count} full renders", n)

  defp render_time_hint(_no_renders), do: gettext("None since it was last built")

  # RE-RENDERS ARE LIVEVIEW'S UPDATES: a component drawn again after the page was, because something
  # it reads changed. The same counters as Render Time; nothing more is measured for them.
  #
  # AN ERROR PAGE HAS NONE — a controller draws it whole on every request — so its fourth box is how
  # many times it was SHOWN, per status: for a 404 page, the 404s visitors hit.
  defp rerenders_label(ErrorPage), do: gettext("Shown")
  defp rerenders_label(_resource), do: gettext("Re-renders")

  defp rerenders(_resource, metrics) when not is_map(metrics), do: gettext("Loading…")
  defp rerenders(_resource, %{on?: false}), do: gettext("Not active")
  defp rerenders(_resource, %{loaded?: false}), do: gettext("Not loaded")
  defp rerenders(_resource, %{stats: :hidden}), do: "—"
  defp rerenders(ErrorPage, %{stats: %{full: %{count: n}}}), do: Integer.to_string(n)
  defp rerenders(_resource, %{stats: %{update: %{count: n}}}), do: Integer.to_string(n)
  defp rerenders(_resource, _no_renders), do: "0"

  defp rerenders_hint(_resource, metrics) when not is_map(metrics), do: nil

  defp rerenders_hint(_resource, %{on?: false}),
    do: gettext("Turn it on in Settings → Performance")

  defp rerenders_hint(_resource, %{loaded?: false}), do: nil

  defp rerenders_hint(_resource, %{stats: :hidden}),
    do: gettext("Counted on every site; shown to master admins")

  defp rerenders_hint(ErrorPage, %{stats: %{statuses: [_ | _] = statuses}}) do
    Enum.map_join(statuses, " · ", fn {status, %{count: n, avg_us: us}} ->
      "#{status_name(status)} #{duration(us)} ×#{n}"
    end)
  end

  defp rerenders_hint(ErrorPage, _never_shown),
    do: gettext("Counted per status, each time it is shown")

  # A LAYOUT IS DRAWN AGAIN WITH EVERY UPDATE OF THE PAGE INSIDE IT: LiveView marks `@inner_content`
  # changed on every render, so its updates are the page's.
  defp rerenders_hint(Layout, %{stats: %{update: %{count: n, avg_us: us}}}) when n > 0,
    do: gettext("With every update of the page inside it, %{time} each", time: duration(us))

  defp rerenders_hint(_resource, %{stats: %{update: %{count: n, avg_us: us}}}) when n > 0,
    do: gettext("Average %{time} each", time: duration(us))

  defp rerenders_hint(_resource, _no_updates),
    do: gettext("Redrawn when something it reads changes")

  defp status_name(:offline), do: gettext("Offline")
  defp status_name(status), do: to_string(status)

  # The setting that turns the render clock on (`MishkaCmsCore.Runtime.RenderMetrics.on?/0`).
  defp settings_link(%{on?: false}), do: "/admin/dashboard/settings?tab=general"
  defp settings_link(_on_or_loading), do: nil

  defp cache(metrics) when not is_map(metrics), do: gettext("Loading…")
  defp cache(%{loaded?: true}), do: gettext("Loaded")
  defp cache(%{loaded?: false}), do: gettext("Not loaded")

  defp cache_hint(%{loaded?: true, build: %{cache: :hit, us: us}}),
    do: gettext("From the disk cache in %{time}", time: duration(us))

  defp cache_hint(%{loaded?: true, build: %{cache: :miss, us: us}}),
    do: gettext("Compiled in %{time}, saved to the disk cache", time: duration(us))

  defp cache_hint(%{loaded?: true, build: %{us: us}}),
    do: gettext("Compiled in %{time}", time: duration(us))

  defp cache_hint(%{loaded?: false}), do: gettext("Not in memory on this server")
  defp cache_hint(_unknown), do: nil

  defp duration(us) when us < 1000, do: "#{us} µs"

  defp duration(us) when us >= 1_000_000,
    do: "#{:erlang.float_to_binary(us / 1_000_000, decimals: 1)} s"

  defp duration(us), do: "#{:erlang.float_to_binary(us / 1000, decimals: 1)} ms"

  defp site_name(%{site: %{name: name}}) when is_binary(name), do: name
  defp site_name(_record), do: gettext("Global")
end
