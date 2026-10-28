# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.DetailModal do
  @moduledoc """
  Shared chrome + display helpers for the admin record modals (the runtime preview modal and the
  site details modal). Keeps ONE source of truth for the modal shell, segmented tabs, and the small
  card helpers — each consumer supplies only its own header bits (`:subtitle`/`:actions` slots), tab
  list, and tab content (`:inner_block`).

  - `shell/1` — the modal wrapper (`<id>` / `-bg` / `-container` family driven by
    `CoreComponents.show_modal/hide_modal`), header (gradient icon box + title + slots), and the
    segmented tab bar. Closing pushes `close_event` after hiding, and Escape / click-away do the same.
  - `detail/1`, `status_row/1`, `metric/1`, `datetime/1` — the card primitives shared by every tab.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Phoenix.LiveView.JS

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :icon_class, :string, default: "bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)]"
  attr :title, :string, required: true
  attr :max_width, :string, default: "max-w-[980px]"
  attr :active_tab, :string, required: true
  attr :tabs, :list, default: []
  attr :tab_event, :string, required: true
  attr :tab_style, :atom, default: :segmented
  attr :close_event, :string, required: true
  slot :title_prefix
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div id={@id} class="relative z-50 hidden">
      <div
        id={"#{@id}-bg"}
        class="fixed inset-0 bg-[rgba(20,18,26,0.42)] transition-opacity"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        role="dialog"
        aria-modal="true"
        tabindex="0"
        phx-window-keydown={close(@id, @close_event)}
        phx-key="escape"
      >
        <div class="flex min-h-full items-start justify-center px-5 py-[5vh]">
          <.focus_wrap
            id={"#{@id}-container"}
            phx-click-away={close(@id, @close_event)}
            class={[
              "relative hidden w-full rounded-[20px] bg-white shadow-[0_30px_80px_rgba(20,18,26,0.4)] transition",
              @max_width
            ]}
          >
            <%!-- THE ACTIONS WRAP, THE TITLE DOES NOT GIVE WAY. The title block asks for its whole
                  width first, so on a narrow screen the buttons drop to their own row under it
                  instead of being laid over it; the close button sits outside that row and stays
                  top-right. --%>
            <div
              data-role="modal-head"
              class="flex items-start gap-2 border-b border-[#f0efea] px-6 py-5"
            >
              <div class="flex min-w-0 flex-1 flex-wrap items-start justify-between gap-x-4 gap-y-3">
                <div
                  data-role="modal-head-title"
                  class="flex min-w-0 flex-auto items-center gap-[13px]"
                >
                  <div class={[
                    "flex size-11 shrink-0 items-center justify-center rounded-[13px] text-white",
                    @icon_class
                  ]}>
                    <.icon name={@icon} class="size-5" />
                  </div>
                  <div class="min-w-0">
                    <div class="flex items-center gap-[9px]">
                      {render_slot(@title_prefix)}
                      <h2 class="truncate font-['Space_Grotesk'] text-[19px] font-semibold text-[#17161a]">
                        {@title}
                      </h2>
                    </div>
                    <div :if={@subtitle != []} class="mt-1.5 flex items-center gap-1.5">
                      {render_slot(@subtitle)}
                    </div>
                  </div>
                </div>
                <div
                  :if={@actions != []}
                  data-role="modal-head-actions"
                  class="flex flex-wrap items-center gap-2"
                >
                  {render_slot(@actions)}
                </div>
              </div>
              <button
                type="button"
                phx-click={close(@id, @close_event)}
                aria-label={gettext("close")}
                class="grid size-9 shrink-0 place-items-center rounded-[10px] border border-[#ecebe6] bg-white text-[#8a877f] transition-colors hover:bg-[#f7f6f3] hover:text-[#1b1a18]"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div
              :if={@tabs != [] and @tab_style == :folder}
              class="flex gap-[2px] overflow-x-auto border-b border-[#ecebe6] bg-[#f6f5f2] px-4 pt-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
            >
              <button
                :for={{key, label, tab_icon} <- @tabs}
                type="button"
                phx-click={@tab_event}
                phx-value-tab={key}
                class={folder_tab_class(@active_tab == key)}
              >
                <.tab_glyph icon={tab_icon} /> {Gettext.gettext(MishkaCmsCore.Gettext, label)}
              </button>
            </div>

            <div :if={@tabs != [] and @tab_style != :folder} class="px-6 pt-5">
              <div class="flex rounded-[12px] border border-[#ecebe6] bg-[#f6f5f2] p-1">
                <button
                  :for={{key, label, tab_icon} <- @tabs}
                  type="button"
                  phx-click={@tab_event}
                  phx-value-tab={key}
                  class={tab_class(@active_tab == key)}
                >
                  <.tab_glyph icon={tab_icon} /> {Gettext.gettext(MishkaCmsCore.Gettext, label)}
                </button>
              </div>
            </div>

            {render_slot(@inner_block)}
          </.focus_wrap>
        </div>
      </div>
    </div>
    """
  end

  defp tab_class(active?) do
    [
      "flex h-10 flex-1 items-center justify-center gap-2 rounded-[9px] text-[13px] font-semibold transition-colors",
      if(active?,
        do: "bg-white text-[#1b1a18] shadow-[0_1px_2px_rgba(30,28,24,0.06)]",
        else: "text-[#8a877f] hover:text-[#3a382f]"
      )
    ]
  end

  # Browser-tab style (rounded top corners, sitting on the tab bar) for modals with many tabs.
  defp folder_tab_class(active?) do
    [
      "inline-flex h-10 items-center gap-[7px] whitespace-nowrap rounded-t-[9px] px-4 text-[12.5px] font-semibold transition-colors",
      if(active?,
        do: "bg-white text-[#1b1a18]",
        else: "bg-transparent text-[#8a877f] hover:text-[#3a382f]"
      )
    ]
  end

  # A tab's glyph is either a Heroicon name (`hero-…`) or a raw SVG path string, so a consumer can
  # pass the exact mockup icon without a Heroicon that only approximates it.
  attr :icon, :string, required: true

  defp tab_glyph(%{icon: "hero-" <> _} = assigns) do
    ~H"""
    <.icon name={@icon} class="size-[15px]" />
    """
  end

  defp tab_glyph(assigns) do
    ~H"""
    <svg
      class="size-[15px]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d={@icon} />
    </svg>
    """
  end

  @doc """
  The shell's own close transition (hide the modal, then push `event`) as a public `JS` command, so a
  consumer's own buttons (e.g. a footer "Close") dismiss the modal exactly like the header X.
  """
  def dismiss(id, event), do: close(id, event)

  defp close(id, event),
    do: MishkaCmsCore.CoreComponents.hide_modal(id) |> JS.push(event)

  attr :label, :string, required: true
  slot :inner_block, required: true

  def detail(assigns) do
    ~H"""
    <div>
      <dt class="text-[10px] font-bold uppercase tracking-[0.05em] text-[#a8a5a0]">{@label}</dt>
      <dd class="mt-[7px] text-[13px] font-semibold text-[#3a382f]">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  def status_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between border-t border-[#f4f3ee] py-3">
      <dt class="text-[12.5px] font-medium text-[#6d6a63]">{@label}</dt>
      <dd class="flex items-center gap-1.5 text-[12.5px] font-semibold text-[#3a382f]">
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :real, :boolean, default: false
  attr :hint, :string, default: nil, doc: "a smaller line under the value, saying what it is"
  attr :hint_navigate, :string, default: nil, doc: "draws the hint as a link to this address"

  def metric(assigns) do
    ~H"""
    <div class="rounded-[11px] bg-[#faf9f6] p-[13px]">
      <div class="flex items-center justify-between">
        <span class="text-[10.5px] font-semibold text-[#8a877f]">{@label}</span>
        <.icon name={@icon} class="size-[13px] text-[#a8a5a0]" />
      </div>
      <div class="mt-[5px] flex items-center gap-1.5 font-['Space_Grotesk'] text-[20px] font-semibold text-[#17161a]">
        {@value}
        <span
          :if={@real}
          class="rounded-[4px] bg-[#e6f6ee] px-1 py-0.5 text-[8px] font-bold text-[#177a53]"
        >
          {gettext("live")}
        </span>
      </div>
      <p :if={@hint && !@hint_navigate} class="mt-1 text-[10.5px] leading-snug text-[#8a877f]">
        {@hint}
      </p>
      <.link
        :if={@hint && @hint_navigate}
        navigate={@hint_navigate}
        class="mt-1 block text-[10.5px] font-medium leading-snug text-indigo-600 hover:underline"
      >
        {@hint}
      </.link>
    </div>
    """
  end

  def datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def datetime(_), do: "—"
end
