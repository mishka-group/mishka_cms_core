# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.ReviewCommentForm do
  @moduledoc """
  A MishkaGervaz custom form template: the composer at the FOOT of the builder's Review sheet.

  It owns the box and nothing above it — the thread is a Gervaz TABLE,
  `MishkaCmsCoreWeb.Templates.ReviewComments`, which scrolls above this.

  ## Why it is at the bottom

  It used to be the first thing in the sheet, which put the newest note below a form nobody was
  using yet and made reading the thread mean scrolling past the composer every time. A thread is
  read downwards and written at the end; the composer belongs where the writing happens.

  ## Two fields, because the editor knows the rest

  A note needs six things stored and asks for two. Which document, which element, who is writing and
  what kind of author they are all come from the editor through the form's `defaults`, and
  `MishkaCmsCore.Runtime.PageComment.apply_scope/2` puts them on the params in `before_save`. Asking
  would be a five-field form where two will do, and every one of those three answers would be a
  chance to get wrong what the editor already knows for certain.

  That is also what makes a PAGE-LEVEL note the same thing as an element one: nothing is selected,
  so `node_id` is nil, and the scope chip says "the whole page" instead of naming a tag. There is no
  second form and no second code path.

  ## The scope chip reports, and offers one way out

  What a note is anchored to is whatever the canvas has selected, which is the right answer nearly
  always — a dropdown of every element on the page would be a worse way to say "this one" than
  clicking it. The chip does not choose the element.

  It does carry a single ✕, because there is one thing the selection cannot say: that what you want
  to write is about the PAGE, while you happen to have a div selected. Deselecting in the canvas to
  say it means losing the place you were working in. The override lasts until the selection changes,
  and then the composer follows it again.

  ## Why the errors are a flash

  This box has no error slot, and Gervaz reports a rejected submit by assigning `errors` onto the
  form state for the TEMPLATE to draw. A template with nowhere to draw them swallows every failure
  silently — the author presses Save and nothing happens. `PageComment.refuse/1` catches the two
  cases that matter before the submit and sends the editor a flash, which is the same shape
  `MishkaCmsCore.Runtime.Snippet` uses and for the same reason.
  """

  use MishkaGervaz.Form.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  @impl true
  def name, do: :review_comment

  @impl true
  def label, do: dgettext("mishka_gervaz", "Add a note")

  @impl true
  def icon, do: "hero-chat-bubble-left-ellipsis"

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div
      data-role="pb-review-form-skeleton"
      class="h-[124px] animate-pulse rounded-[10px] bg-[#f7f6fd]"
    >
    </div>
    """
  end

  @impl true
  def render(assigns) do
    replying? = not is_nil(defaults(assigns.state)[:parent_comment_id])

    assigns =
      assigns
      |> assign(:replying?, replying?)
      |> assign(:anchored?, is_binary(defaults(assigns.state)[:node_label]))
      |> assign(:scope, (replying? && gettext("this note")) || scope(assigns.state))

    ~H"""
    <form id="pb-comment-form" phx-change="validate" phx-submit="save" phx-target={@myself}>
      <%!-- WHAT THIS NOTE WILL BE ABOUT, reported rather than chosen. It is whatever the canvas has
            selected, which is the only answer that can be right — a dropdown of every element on
            the page would be a worse way to say "this one" than clicking it. The type sits on the
            same line so the composer stays three rows tall. --%>
      <div class="flex items-center gap-2">
        <span class="flex-none text-[11px] font-medium text-[#6d6a63]">
          {(@replying? && gettext("Replying to")) || gettext("Commenting on")}
        </span>
        <span class="min-w-0 flex-none truncate rounded-[6px] bg-[#f2f1fc] px-2 py-[3px] font-['Space_Grotesk'] text-[10.5px] font-bold text-[#4f4bcc]">
          {@scope}
        </span>
        <%!-- A WAY TO SAY "NO, THE PAGE". The composer anchors to whatever the canvas has selected,
              which is right nearly always and wrong exactly when what you want to say is about the
              page rather than the div you happened to click. Deselecting to say it is a detour. No
              `phx-target`: what a note is about belongs to the editor. --%>
        <button
          :if={!@replying? && @anchored?}
          type="button"
          id="pb-comment-whole-page"
          phx-click="comment_on_page"
          title={gettext("Write about the whole page instead")}
          class="grid size-[18px] flex-none place-items-center rounded-[5px] text-[#a8a5a0] hover:bg-[#f4f3ee] hover:text-[#3a382f]"
        >
          <svg
            width="10"
            height="10"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.4"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
        <%!-- A way back out. Without it, arming a reply by mistake is a state with no exit but
              posting one. No `phx-target`: the composer's mode belongs to the sheet. --%>
        <button
          :if={@replying?}
          type="button"
          id="pb-comment-cancel-reply"
          phx-click="cancel_reply"
          title={gettext("Write a new note instead")}
          class="flex-none rounded-[6px] px-1.5 py-[3px] text-[10px] font-bold text-[#8a877f] hover:bg-[#f4f3ee]"
        >
          {gettext("Cancel")}
        </button>
        <span class="flex-1"></span>
        <%!-- A REPLY HAS NO TYPE OF ITS OWN. It answers a note that already has one, and letting a
              reply be its own "bug" would double-count it in the badge. Hidden rather than absent:
              the action still requires the field. --%>
        <input :if={@replying?} type="hidden" name="form[type]" value="information" />
        <.dynamic_component
          :if={!@replying?}
          module={@static.ui_adapter}
          function={:select}
          name="form[type]"
          id="pb-comment-type"
          class="h-[26px] w-[104px] text-[10.5px]"
          value={@state.field_values[:type] || :information}
          errors={field_errors(@state, :type)}
          options={MishkaCmsCore.Runtime.PageComment.type_options()}
        />
      </div>

      <%!-- `@` NAMES SOMEBODY, and the hook is what notices. It rides on the textarea rather than on
            a wrapper because the form rebuilds itself whenever `defaults` change — a new element
            every time — and a hook on the element that is replaced is remounted with it, while a
            hook on a wrapper that is not patched would keep a listener on a textarea that is gone.
            It pushes to the EDITOR, not to this component: who may be named is a tenancy question
            and Gervaz has no business answering it. --%>
      <.dynamic_component
        module={@static.ui_adapter}
        function={:textarea}
        name="form[body]"
        id="pb-comment-body"
        class="mt-2 h-[68px]"
        rows={3}
        value={typed(@state, :body)}
        phx-debounce="blur"
        errors={field_errors(@state, :body)}
        placeholder={gettext("Leave a note for the team… @ names somebody")}
        phx-hook="MentionBox"
      />

      <button
        type="submit"
        id="pb-comment-post"
        class="mt-2 h-[36px] w-full rounded-[10px] bg-gradient-to-br from-[#6d69e6] to-[#4f4bcc] text-[12.5px] font-bold text-white shadow-[0_2px_8px_rgba(79,75,204,.25)] hover:from-[#7b77ec] hover:to-[#5b57d6]"
      >
        {(@replying? && gettext("Post reply")) || gettext("Post comment")}
      </button>
    </form>
    """
  end

  defp typed(%{form: %Phoenix.HTML.Form{params: %{} = params}}, field),
    do: Map.get(params, to_string(field))

  defp typed(_state, _field), do: nil

  defp defaults(%{defaults: defaults}) when is_map(defaults), do: defaults
  defp defaults(_state), do: %{}

  # What the note will be anchored to, reported rather than chosen. The label is captured with the
  # note at write time, so this and the stored `node_label` are the same string.
  defp scope(%{defaults: %{node_label: label}}) when is_binary(label) and label != "",
    do: "<" <> label <> ">"

  defp scope(_state), do: gettext("the whole page")

  defp field_errors(%{errors: errors}, field) when is_map(errors),
    do: Map.get(errors, field, []) |> List.wrap()

  defp field_errors(_state, _field), do: []
end
