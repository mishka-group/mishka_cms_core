# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Components.SkipQuestion do
  @moduledoc """
  The question a Skip button asks before it skips a failure (`MishkaCmsCore.Skip`): "Skip this
  …?", what a skip does, and a field for an optional short reason (at most
  `MishkaCmsCore.Skip.reason_max/0` characters), in the look and the places of gervaz's question
  window (a dialog in the middle, a bottom sheet on a phone, over a backdrop).

  gervaz's own question (`MishkaGervaz.Question`, a row action's `confirm`) has no free-text field:
  its field holds a word that must be typed as written before the button answers. So the page that
  skips draws this window itself, while it holds the item being skipped, and answers its two
  events: `on_confirm` (the form's submit, with `%{"reason" => text}`) and `on_cancel` (Cancel, the
  backdrop and Escape). Nothing in it is JavaScript but `Phoenix.LiveView.JS.focus/1` on the field.

      <SkipQuestion.window
        :if={@skip_job}
        id="activity-skip"
        title={gettext("Skip this job?")}
        body={gettext("It will not be tried again. You can bring it back later.")}
        on_confirm="skip_confirm"
        on_cancel="skip_cancel"
      />
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  alias Phoenix.LiveView.JS

  @doc "The window; draw it only while an item waits to be skipped."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :confirm_label, :string, default: nil
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :target, :any, default: nil

  @spec window(map()) :: Phoenix.LiveView.Rendered.t()
  def window(assigns) do
    assigns =
      assigns
      |> assign(:confirm_label, assigns.confirm_label || gettext("Skip"))
      |> assign(:reason_max, MishkaCmsCore.Skip.reason_max())

    ~H"""
    <div
      id={@id}
      data-role="skip-question"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
      phx-target={@target}
      class="fixed inset-0 z-[60] flex items-center justify-center px-6 py-8 max-[640px]:items-end max-[640px]:p-0"
    >
      <div
        aria-hidden="true"
        phx-click={@on_cancel}
        phx-target={@target}
        class="absolute inset-0 bg-[#17161a]/40"
      />
      <form
        id={@id <> "-dialog"}
        role="dialog"
        aria-modal="true"
        aria-labelledby={@id <> "-title"}
        aria-describedby={@body && @id <> "-body"}
        phx-submit={@on_confirm}
        phx-target={@target}
        class="relative w-[440px] max-w-full rounded-[18px] bg-white px-[22px] pt-[22px] pb-[18px] shadow-[0_30px_80px_rgba(23,22,26,0.32)] max-[640px]:w-full max-[640px]:rounded-b-none"
      >
        <h2 id={@id <> "-title"} class="text-[17px] font-semibold text-[#17161a]">{@title}</h2>
        <p
          :if={@body}
          id={@id <> "-body"}
          class="mt-[7px] text-[12.5px] font-medium leading-[1.6] text-[#5c5a54]"
        >
          {@body}
        </p>
        <div class="mt-[13px]">
          <label for={@id <> "-reason"} class="mb-[5px] block text-[12px] font-bold text-[#3a382f]">
            {gettext("Reason (optional)")}
          </label>
          <input
            id={@id <> "-reason"}
            type="text"
            name="reason"
            maxlength={@reason_max}
            autocomplete="off"
            dir="auto"
            placeholder={gettext("Why it is not tried again")}
            phx-mounted={JS.focus()}
            class="box-border h-[42px] w-full rounded-[11px] border border-[#e2e0d9] px-3 text-[13px] font-semibold text-[#17161a] outline-none focus:border-[#8b87ea] focus:shadow-[0_0_0_3px_rgba(109,105,230,0.16)]"
          />
        </div>
        <div class="mt-[18px] flex justify-end gap-2 max-[640px]:flex-col-reverse">
          <button
            type="button"
            data-role="skip-question-cancel"
            phx-click={@on_cancel}
            phx-target={@target}
            class="h-10 cursor-pointer rounded-[11px] border border-[#ecebe6] bg-white px-[15px] text-[12.5px] font-semibold text-[#3a382f] transition-colors hover:bg-[#f7f6f3] max-[640px]:min-h-[48px]"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            data-role="skip-question-confirm"
            class="h-10 cursor-pointer rounded-[11px] bg-[#a5691a] px-[17px] text-[13px] font-bold text-white transition-colors hover:bg-[#8a5a00] max-[640px]:min-h-[48px]"
          >
            {@confirm_label}
          </button>
        </div>
      </form>
    </div>
    """
  end
end
