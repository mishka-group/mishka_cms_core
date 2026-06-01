defmodule MishkaCmsCoreWeb.Live.Admin.Components.RuntimeStatusTimeline do
  @moduledoc """
  Renders a record's runtime status from a
  `MishkaCmsCore.Runtime.RuntimeStatus.compute/2` map: a four-step pipeline
  (Saved → Active → Compiled/Bundled/Lazy → Live) where each step is `:done`
  (solid green), `:current` (light green), or `:future` (gray, not yet reached),
  plus a single "Currently:" box that carries the live state + message and is the
  only element that changes color by state (green/amber/red/blue/gray).

  The node glyphs and the banner glyph are inlined SVGs that match the 33-tir
  design exactly (database cylinder, bolt, sun, check-circle; info/success/warn/
  error banner marks) rather than approximating them with Heroicons.

  Used by `MishkaCmsCore.Runtime.RuntimeStatusLive` for the expanded row of every
  runtime admin table, and by the runtime preview modal's Pipeline tab.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  attr :status, :map, required: true
  attr :record, :map, required: true

  def timeline(assigns) do
    assigns = assign(assigns, :steps, steps(assigns.status))

    ~H"""
    <div class="space-y-[22px] rounded-[14px] border border-[#ecebe6] bg-white p-[22px]">
      <div>
        <div class="flex items-center gap-2.5">
          <span class="font-['Space_Grotesk'] text-[16px] font-semibold text-[#17161a]">
            {gettext("Runtime Pipeline")}
          </span>
          <span class={[
            "inline-flex items-center gap-1.5 rounded-[20px] px-[9px] py-[3px] text-[9.5px] font-bold",
            pill_tone(@status.state)
          ]}>
            <span class={["size-[5px] rounded-full", dot_tone(@status.state)]}></span>
            {badge_label(@status.state)}
          </span>
        </div>
        <div class="mt-1 font-['Space_Grotesk'] text-[11.5px] text-[#a8a5a0]">
          {gettext("Current status for %{name}", name: @record.name)}
        </div>
      </div>

      <div class="relative flex items-start justify-between">
        <div class="absolute left-[12%] right-[12%] top-[26px] h-0.5 bg-[#e6e4de]"></div>
        <div :for={step <- @steps} class="relative z-10 flex flex-1 flex-col items-center gap-[9px]">
          <div class={[
            "flex size-[52px] items-center justify-center rounded-full border-2",
            circle_tone(step.phase)
          ]}>
            <.node_glyph glyph={step.glyph} />
          </div>
          <div class="text-center text-[12.5px] font-semibold text-[#1b1a18]">{step.title}</div>
          <span class={[
            "rounded-[20px] px-[10px] py-[3px] text-[9.5px] font-bold",
            badge_tone(step.phase)
          ]}>
            {badge_text(step.phase)}
          </span>
        </div>
      </div>

      <div class={["flex items-start gap-3 rounded-[12px] border p-[14px]", panel_tone(@status.state)]}>
        <.banner_glyph state={@status.state} />
        <div>
          <div class="text-[12.5px] font-bold">
            {gettext("Currently: %{label}", label: @status.label)}
          </div>
          <div class="mt-0.5 text-[11.5px] font-medium opacity-90">{@status.message}</div>
        </div>
      </div>
    </div>
    """
  end

  # Pipeline node glyphs — inline SVGs matching the mockup, stroke follows the circle's text colour.
  attr :glyph, :atom, required: true

  defp node_glyph(%{glyph: :saved} = assigns) do
    ~H"""
    <svg
      class="size-[22px]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <ellipse cx="12" cy="6" rx="8" ry="3" />
      <path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6" />
    </svg>
    """
  end

  defp node_glyph(%{glyph: :active} = assigns) do
    ~H"""
    <svg
      class="size-[22px]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M13 2 4 14h7l-1 8 9-12h-7z" />
    </svg>
    """
  end

  defp node_glyph(%{glyph: :asset} = assigns) do
    ~H"""
    <svg
      class="size-[22px]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M4 20h4L18.5 9.5a2 2 0 0 0-3-3L5 17z" />
      <path d="M13.5 6.5l3 3" />
    </svg>
    """
  end

  defp node_glyph(%{glyph: :sun} = assigns) do
    ~H"""
    <svg
      class="size-[22px]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="3.2" />
      <path d="M12 3v2.5M12 18.5V21M4.2 7l1.8 1M18 16l1.8 1M4.2 17l1.8-1M18 8l1.8-1" />
    </svg>
    """
  end

  defp node_glyph(%{glyph: :live} = assigns) do
    ~H"""
    <svg
      class="size-[22px]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="9" />
      <path d="m8 12 3 3 5-6" />
    </svg>
    """
  end

  # "Currently:" banner glyph — the mark inherits the banner's text colour via currentColor.
  attr :state, :atom, required: true

  defp banner_glyph(%{state: :live} = assigns) do
    ~H"""
    <svg
      class="mt-0.5 size-[17px] shrink-0"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="9" />
      <path d="m8 12 3 3 5-6" />
    </svg>
    """
  end

  defp banner_glyph(%{state: s} = assigns) when s in [:compiling, :pending] do
    ~H"""
    <svg
      class="mt-0.5 size-[17px] shrink-0"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M10.3 3.3 2.6 17a2 2 0 0 0 1.7 3h15.4a2 2 0 0 0 1.7-3L13.7 3.3a2 2 0 0 0-3.4 0z" />
      <path d="M12 9v4M12 17h.01" />
    </svg>
    """
  end

  defp banner_glyph(%{state: :failed} = assigns) do
    ~H"""
    <svg
      class="mt-0.5 size-[17px] shrink-0"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="9" />
      <path d="M15 9l-6 6M9 9l6 6" />
    </svg>
    """
  end

  defp banner_glyph(assigns) do
    ~H"""
    <svg
      class="mt-0.5 size-[17px] shrink-0"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="9" />
      <path d="M12 8v4l3 2" />
    </svg>
    """
  end

  defp steps(status) do
    phases = phases(status)

    [
      %{title: gettext("Saved"), glyph: :saved, phase: phases.saved},
      %{title: gettext("Active"), glyph: :active, phase: phases.active},
      %{
        title: artifact_title(status.mode),
        glyph: artifact_glyph(status.mode),
        phase: phases.artifact
      },
      %{title: gettext("Live"), glyph: :live, phase: phases.live}
    ]
  end

  defp phases(%{state: :live}), do: %{saved: :done, active: :done, artifact: :done, live: :done}

  defp phases(%{state: :archived}),
    do: %{saved: :done, active: :future, artifact: :future, live: :future}

  defp phases(%{state: :inactive}),
    do: %{saved: :done, active: :off, artifact: :future, live: :future}

  defp phases(_status), do: %{saved: :done, active: :done, artifact: :current, live: :future}

  defp artifact_title(:asset), do: gettext("Bundled")
  defp artifact_title(:lazy), do: gettext("Lazy")
  defp artifact_title(_), do: gettext("Compiled")
  defp artifact_glyph(:asset), do: :asset
  defp artifact_glyph(_), do: :sun

  defp circle_tone(:done), do: "bg-[#1f9d6b] border-[#1f9d6b] text-white"
  defp circle_tone(:current), do: "bg-white border-[#1f9d6b] text-[#1f9d6b]"
  defp circle_tone(:off), do: "bg-[#f6f5f2] border-[#c3c0b8] text-[#8a877f]"
  defp circle_tone(:future), do: "bg-white border-[#e6e4de] text-[#c3c0b8]"

  defp badge_tone(:done), do: "bg-[#e6f6ee] text-[#177a53]"
  defp badge_tone(:current), do: "bg-[#e6f6ee] text-[#177a53]"
  defp badge_tone(:off), do: "bg-[#f2f1ec] text-[#8a877f]"
  defp badge_tone(:future), do: "bg-[#f6f5f2] text-[#a8a5a0]"

  defp badge_text(:done), do: gettext("Done")
  defp badge_text(:current), do: gettext("Current")
  defp badge_text(:off), do: gettext("Inactive")
  defp badge_text(:future), do: "—"

  defp panel_tone(:live), do: "bg-[#eefaf2] border-[#cfe6d8] text-[#177a53]"

  defp panel_tone(s) when s in [:compiling, :pending],
    do: "bg-[#fdf7ea] border-[#f0e3c9] text-[#a5691a]"

  defp panel_tone(:failed), do: "bg-[#fdf3f1] border-[#f0dcd8] text-[#c0473d]"
  defp panel_tone(:lazy_ready), do: "bg-[#eef4fc] border-[#d6e3f5] text-[#3a6cb5]"
  defp panel_tone(_), do: "bg-[#f6f5f2] border-[#ecebe6] text-[#5c5a54]"

  defp badge_label(:live), do: gettext("Loaded")
  defp badge_label(:compiling), do: gettext("Compiling")
  defp badge_label(:pending), do: gettext("Not loaded")
  defp badge_label(:failed), do: gettext("Failed")
  defp badge_label(:lazy_ready), do: gettext("On demand")
  defp badge_label(:inactive), do: gettext("Inactive")
  defp badge_label(:archived), do: gettext("Archived")

  defp pill_tone(:live), do: "bg-[#e6f6ee] text-[#177a53]"
  defp pill_tone(s) when s in [:compiling, :pending], do: "bg-[#fbf1df] text-[#a5691a]"
  defp pill_tone(:failed), do: "bg-[#fbe9e7] text-[#c0473d]"
  defp pill_tone(:lazy_ready), do: "bg-[#eef4fc] text-[#3a6cb5]"
  defp pill_tone(_), do: "bg-[#f4f3ef] text-[#8a877f]"

  defp dot_tone(:live), do: "bg-[#1f9d6b]"
  defp dot_tone(s) when s in [:compiling, :pending], do: "bg-[#cf8a24]"
  defp dot_tone(:failed), do: "bg-[#e5484d]"
  defp dot_tone(:lazy_ready), do: "bg-[#3a6cb5]"
  defp dot_tone(_), do: "bg-[#a8a5a0]"
end
