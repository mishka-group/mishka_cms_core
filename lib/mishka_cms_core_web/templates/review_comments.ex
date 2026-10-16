# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.ReviewComments do
  @moduledoc """
  A MishkaGervaz custom table template: the thread in the builder's Review sheet.

  It owns the list and nothing above it — the composer is a Gervaz FORM,
  `MishkaCmsCoreWeb.Templates.ReviewCommentForm`.

  ## What it draws and what it borrows

  Structure only. Every chip, button and empty state goes through `dynamic_component/1` at
  `@static.ui_adapter`, which is `MishkaCmsCoreWeb.UIAdapters.Review` — so the look is the adapter's
  and swapping the adapter reskins the thread without touching this file. Hardcoding
  `MishkaGervaz.UIAdapters.Tailwind.badge(…)` here would defeat exactly that.

  `features/0` returns `[:filter, :paginate]` and not `[:select, :bulk_actions]`: a review thread is
  read one note at a time, and a checkbox column in a 360px sidebar costs more than it gives.
  Dropping a feature drops its EVENTS too, so the two that stay are the two whose controls this
  template draws — the Open/All chips push `filter`, and "Show older" pushes `load_more`, both with
  `phx-target={@myself}`.

  ## Which clicks go where

  Deliberately both ways, the way `MishkaCmsCoreWeb.Templates.StudioSnippets` does it:

    * `filter` and `load_more` are Gervaz's own events and carry `phx-target={@myself}`.
    * Going to a note's element, resolving it, reopening it and deleting it are the EDITOR's
      business, so they carry no target and land in `BuilderLive`, which owns the selection and the
      Ash calls.

  Getting that backwards produces a silent no-op, which is why it is written down.

  ## Why the avatar disc is a class

  `Panels.avatar_tint/1` still decides WHICH of the five colours a name gets, but `avatar_class/1`
  turns that answer into a whole class rather than a `style` attribute — CSP has no nonce for an
  attribute, so `style-src-attr` can only be closed by there being none. The five are written out one
  clause per colour because Tailwind reads source text: an interpolated class name gets no rule at
  all, which is what `MishkaCmsWeb.InterpolatedClassTest` guards.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.PageBuilder.Comment
  alias MishkaCmsCore.Runtime.PageBuilder.Mentions
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @impl true
  def name, do: :review_comments

  @impl true
  def label, do: dgettext("mishka_gervaz", "Review")

  @impl true
  def icon, do: "hero-chat-bubble-left-right"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Notes left on this document")

  # Selection and bulk actions are omitted on purpose; see the moduledoc.
  @impl true
  def features, do: [:filter, :paginate]

  @impl true
  def default_options, do: []

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div data-role="pb-review-skeleton" class="flex flex-col gap-2">
      <div
        :for={_row <- 1..3//1}
        class="h-[86px] animate-pulse rounded-[10px] border border-[#f0efea] bg-[#faf9f6]"
      >
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:records, records(assigns))
      |> assign(:filter, selected_filter(assigns.state))
      |> assign(:open_count, Enum.count(records(assigns), &(&1.status == :open)))

    ~H"""
    <div data-role="pb-review-thread" class="flex flex-col">
      <%!-- The strip names what is below it and says how much of it needs attention, then offers the
            one filter that matters. The count is OPEN notes of every type — the top bar's red badge
            is the narrower question, unresolved BUGS — so the two are different numbers on purpose
            and each says which it is. --%>
      <div class="sticky top-0 z-[1] flex items-center gap-2 border-b border-[#f0efea] bg-white pb-2 pt-3.5">
        <span class="text-[10.5px] font-bold uppercase tracking-[0.12em] text-[#6d6a63]">
          {gettext("Comments")}
        </span>
        <span
          :if={@open_count > 0}
          id="pb-review-open-count"
          class="flex-none rounded-full bg-[#f2f1fc] px-2 py-[3px] text-[10.5px] font-bold text-[#4f4bcc]"
        >
          {gettext("%{count} open", count: @open_count)}
        </span>
        <span class="flex-1"></span>
        <div class="flex flex-none items-center gap-1">
          <%!-- "ALL" SENDS AN EMPTY VALUE, not the word "all". Gervaz rebuilds `filter_values` from
                the submitted params on every change and DROPS any key that arrives empty, so an
                empty status IS "no filter" — sending "all" filters for a status nothing has, which
                is an empty thread. One key is enough because this table declares exactly one
                filter; a table with more must send every key on every chip or the others clear. --%>
          <button
            :for={{value, label} <- [{"open", gettext("Open")}, {"", gettext("All")}]}
            type="button"
            id={"pb-review-#{(value == "" && "all") || value}"}
            phx-click="filter"
            phx-value-status={value}
            phx-target={@myself}
            class={[
              "h-[24px] rounded-[7px] border px-2.5 text-[10.5px] font-bold",
              (@filter == value && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
                "border-transparent bg-transparent text-[#6d6a63] hover:bg-[#f6f5f2]"
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-2.5 pt-2.5">
        <.dynamic_component
          :if={@records == []}
          module={@static.ui_adapter}
          function={:empty_state}
          message={empty_message(@filter)}
        />

        <.render_item :for={record <- @records} record={record} static={@static} state={@state} />

        <button
          :if={@state.has_more?}
          type="button"
          id="pb-review-more"
          phx-click="load_more"
          phx-target={@myself}
          disabled={@state.loading == :loading}
          class="rounded-[10px] border border-[#ecebe6] bg-white py-2 text-[11px] font-bold text-[#5c5a54] disabled:opacity-60"
        >
          {gettext("Show older notes")}
        </button>
      </div>
    </div>
    """
  end

  # THE ONE SHAPE BOTH ACTIONS WEAR. A small bordered white square with a grey glyph — the treatment
  # the admin's row actions already use — written once so Reply and Delete cannot drift apart. Only
  # the hover colour differs, and it is appended by the caller: violet for the one that continues the
  # thread, warm for the one that ends it.
  @action_square "grid size-[22px] flex-none place-items-center rounded-[7px] border " <>
                   "border-[#e6e4de] bg-white text-[#a8a5a0]"

  @impl true
  def render_item(assigns) do
    comment = assigns.record

    assigns =
      assigns
      |> assign(:action_square, @action_square)
      |> assign(:me, me(assigns.state))
      |> assign(:reader, reader(assigns.state))
      |> assign(:resolved?, comment.status == :resolved)
      |> assign(:scope, scope_label(comment))
      |> assign(:author, author_label(comment, reader(assigns.state)))
      |> assign(:initials, initials(author_label(comment, reader(assigns.state))))
      |> assign(:tint, avatar_class(author_label(comment, reader(assigns.state))))
      |> assign(:ago, Comment.ago(%{at: comment.inserted_at}, DateTime.utc_now()))
      |> assign(:closable?, closable?(comment, assigns.state))
      |> assign(:tone, type_tone(comment.type))

    ~H"""
    <article
      id={"pb-comment-#{@record.id}"}
      class={[
        "rounded-[10px] border p-3",
        (@resolved? && "border-[#f0efea] bg-[#faf9f6]") || "border-[#e6e4de] bg-white"
      ]}
    >
      <div class="flex items-center gap-2">
        <span class={[
          "grid size-7 flex-none place-items-center rounded-full text-[10px] font-bold text-white",
          @tint
        ]}>
          {@initials}
        </span>
        <span dir="auto" class="min-w-0 truncate text-[12.5px] font-bold text-[#17161a]">{@author}</span>
        <span class="flex-none text-[10.5px] font-medium text-[#8a877f]">{@ago}</span>
      </div>

      <p class={[
        "mt-2 whitespace-pre-wrap text-[12px] font-medium leading-[1.5]",
        (@resolved? && "text-[#6d6a63] line-through decoration-[#d5d3cc]") || "text-[#3a382f]"
      ]}>
        <%!-- THE BODY, WITH THE PEOPLE IN IT PICKED OUT. --%>
        {body(@record.body, @me, master_mentions(@record))}
      </p>

      <%!-- ONE ROW OF PILLS, all the same shape. What kind of note it is, what it is about, and the
            one action — a bug reads as a bug because its pill is the only warm one, not because it
            is drawn differently from its neighbours. --%>
      <div class="mt-2.5 flex flex-wrap items-center gap-1.5">
        <span
          id={"pb-comment-type-#{@record.id}"}
          class={["flex-none rounded-[7px] border px-2 py-[3px] text-[10px] font-bold", @tone]}
        >
          {type_label(@record.type)}
        </span>

        <%!-- GOING TO THE ELEMENT IS THE POINT OF ANCHORING A NOTE. No `phx-target`: selection
              belongs to the editor, not to this component. A note on the whole page has nowhere to
              go, so it says where it is instead of offering a button that does nothing. --%>
        <button
          :if={@record.node_id}
          type="button"
          id={"pb-comment-goto-#{@record.id}"}
          phx-click="goto_comment"
          phx-value-id={@record.id}
          title={gettext("Select %{scope}", scope: @scope)}
          class="flex flex-none items-center gap-1 rounded-[7px] border border-[#e6e4de] bg-white px-2 py-[3px] font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc] hover:border-[#dcdbf5] hover:bg-[#f7f6fd]"
        >
          <Panels.icon name={:crop} size={10} class="flex-none text-[#a8a5a0]" />{@scope}
        </button>
        <span
          :if={is_nil(@record.node_id)}
          class="flex flex-none items-center gap-1 rounded-[7px] border border-[#ecebe6] bg-[#faf9f6] px-2 py-[3px] text-[10px] font-semibold text-[#8a877f]"
        >
          <Panels.icon name={:page} size={10} class="flex-none" />{@scope}
        </span>

        <span class="flex-1"></span>

        <span
          :if={!@closable?}
          id={"pb-comment-shared-#{@record.id}"}
          title={gettext("Shared with every site — only a master can close this")}
          class="flex-none text-[10px] font-semibold text-[#a8a5a0]"
        >
          {gettext("Master closes this")}
        </span>
        <%!-- REPLYING IS SEEDING THE COMPOSER, not opening a second one. No `phx-target`: the
              composer belongs to the sheet, and the sheet belongs to the editor.

              A GLYPH, IN THE SAME SQUARE AS DELETE. The two are a pair of actions on one note, so
              they wear one treatment — a bordered square beside a bare one reads as two unrelated
              controls. `title` is what an icon-only button has instead of a name. --%>
        <button
          type="button"
          id={"pb-comment-reply-#{@record.id}"}
          phx-click="reply_to_comment"
          phx-value-id={@record.id}
          title={gettext("Reply to this note")}
          class={@action_square <> " hover:border-[#dcdbf5] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"}
        >
          <Panels.icon name={:reply} size={12} />
        </button>
        <button
          :if={@closable?}
          type="button"
          id={"pb-comment-resolve-#{@record.id}"}
          phx-click={(@resolved? && "reopen_comment") || "resolve_comment"}
          phx-value-id={@record.id}
          class={[
            "flex-none rounded-[7px] border px-2.5 py-[3px] text-[10px] font-bold",
            (@resolved? && "border-[#ecebe6] bg-white text-[#6d6a63] hover:bg-[#f6f5f2]") ||
              "border-[#cfe6d8] bg-[#f2faf5] text-[#177a53] hover:bg-[#e6f6ee]"
          ]}
        >
          {(@resolved? && gettext("Reopen")) || gettext("Resolve")}
        </button>
        <button
          :if={@closable?}
          type="button"
          id={"pb-comment-delete-#{@record.id}"}
          phx-click="delete_comment"
          phx-value-id={@record.id}
          title={gettext("Delete this note")}
          class={@action_square <> " hover:border-[#f0dcd8] hover:bg-[#fdf3f1] hover:text-[#c0473d]"}
        >
          <Panels.icon name={:trash} size={12} />
        </button>
      </div>

      <%!-- THE ANSWERS, under the thing they answer. One level: a reply to a reply is a conversation
            that has outgrown a 420px panel, and the read only nests one deep. The left rule is what
            says "these belong to that" without an indent so deep the text runs out of room. --%>
      <div
        :if={replies(@record) != []}
        class="mt-3 flex flex-col gap-2 border-s-2 border-[#e4e2f7] ps-3"
      >
        <div :for={reply <- replies(@record)} id={"pb-comment-#{reply.id}"}>
          <div class="flex items-center gap-2">
            <span class={[
              "grid size-[18px] flex-none place-items-center rounded-full text-[8px] font-bold text-white",
              avatar_class(author_label(reply, @reader))
            ]}>
              {initials(author_label(reply, @reader))}
            </span>
            <span dir="auto" class="min-w-0 truncate text-[11.5px] font-bold text-[#17161a]">
              {author_label(reply, @reader)}
            </span>
            <span class="flex-none text-[10px] font-medium text-[#a8a5a0]">
              {Comment.ago(%{at: reply.inserted_at}, DateTime.utc_now())}
            </span>
            <span class="flex-1"></span>
            <button
              type="button"
              id={"pb-comment-delete-#{reply.id}"}
              phx-click="delete_comment"
              phx-value-id={reply.id}
              title={gettext("Delete this reply")}
              class="grid size-[20px] flex-none place-items-center rounded-[6px] border border-[#e6e4de] bg-white text-[#a8a5a0] hover:border-[#f0dcd8] hover:bg-[#fdf3f1] hover:text-[#c0473d]"
            >
              <Panels.icon name={:trash} size={11} />
            </button>
          </div>
          <p class="mt-1 whitespace-pre-wrap text-[11.5px] font-medium leading-[1.5] text-[#3a382f]">
            {body(reply.body, @me, master_mentions(reply))}
          </p>
        </div>
      </div>

      <%!-- WHO CLOSED IT, which is the thing a thread is asked a week later. `resolved_by` is a
            relationship, so an unloaded one is `%Ash.NotLoaded{}` — which is TRUTHY, and would
            render as a struct if this matched on presence instead of on shape. --%>
      <p
        :if={@resolved? and resolver(@record, @reader)}
        id={"pb-comment-resolver-#{@record.id}"}
        class="mt-2.5 flex items-center gap-1.5 border-t border-[#f0efea] pt-2 text-[10px] font-semibold text-[#177a53]"
      >
        <span class="grid size-[16px] place-items-center rounded-full bg-[#e6f6ee] text-[8px] font-bold text-[#177a53]">
          {initials(resolver(@record, @reader))}
        </span>
        {gettext("Resolved by %{name}", name: resolver(@record, @reader))}
      </p>
    </article>
    """
  end

  @chip ~s(<span data-role="pb-mention" class="rounded-[4px] bg-[#f2f1fc] px-1 font-bold text-[#4f4bcc]">@)

  # BEING NAMED IS THE ONE THING IN A THREAD THAT IS ADDRESSED TO YOU, so it is the one chip that is
  # filled rather than tinted — the same violet, the same geometry, read at a glance from across the
  # sheet. The title carries the whole address, because the handle is only the front of an email.
  @self_chip_open ~s(<span data-role="pb-mention-self" class="rounded-[4px] bg-[#4f4bcc] px-1 font-bold text-white" title=")
  @self_chip_close ~s(">@)

  # A NOTE'S BODY, WITH THE PEOPLE IN IT PICKED OUT.
  #
  # Built as iodata rather than as markup in the template because the paragraph is `pre-wrap`: every
  # newline HEEx puts between two tags is a newline the reader SEES, so a `:for` over the segments
  # renders a note one word per line. There is no whitespace to strip here — the chips are the only
  # thing between the runs.
  #
  # `Mentions.segments/1` does the reading; this only paints. Each text run is escaped on its way in,
  # so a body containing a tag is still text, and the only markup is the chip this module wrote.
  defp body(text, me, masked) do
    text
    |> Mentions.segments()
    |> Enum.map(&segment(&1, me, masked))
    |> then(&{:safe, &1})
  end

  defp segment({:text, text}, _me, _masked), do: escape(text)

  defp segment({:mention, handle}, me, masked) do
    case MapSet.member?(masked, String.downcase(handle)) do
      true -> [@chip, escape(Helper.label(:master)), "</span>"]
      false -> [chip(String.downcase(handle), me), escape(handle), "</span>"]
    end
  end

  # The handles a master wrote that this reader may not see; see `Mentions.master_mentions/2`.
  defp master_mentions(%{master_mentions: handles}) when is_list(handles), do: MapSet.new(handles)
  defp master_mentions(_note), do: MapSet.new()

  # TWO WAYS OF BEING NAMED. The picker writes the whole address, but a note typed by hand — or one
  # written before the picker did — may only say the local part, and both reach you.
  defp chip(handle, %{handles: handles, email: email}) do
    case handle in handles do
      true ->
        [
          @self_chip_open,
          escape(gettext("%{email} — this is you", email: email)),
          @self_chip_close
        ]

      false ->
        @chip
    end
  end

  defp chip(_handle, _me), do: @chip

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> elem(1)

  # WHO IS READING, as the handle a mention is written with — the email's local part, downcased,
  # which is exactly what `Mentions.handles/1` produces and `Mentions.notify/2` matches on. Anything
  # else here would highlight a different set of chips than the notification reaches.
  defp me(%{current_user: %{email: email}}) do
    address = email |> to_string() |> String.downcase()

    %{handles: [address, hd(String.split(address, "@"))], email: to_string(email)}
  end

  defp me(_state), do: nil

  # WHO IS LOOKING. `%{site_id: nil}` is a master and sees everything; a tenant sees only their own
  # site's people by name. Signed out — which cannot happen here, but the clause is what keeps the
  # masking side total — is treated as the least privileged reader there is.
  defp reader(%{current_user: %{site_id: site_id}}), do: %{site_id: site_id}
  defp reader(_state), do: %{site_id: :nobody}

  # A BUG IS THE ONLY WARM ONE. The top bar counts unresolved bugs, so a bug has to be findable in a
  # thread without reading it; everything else is quiet, because a review where every pill shouts is
  # a review nobody reads. Same geometry as the scope pill beside it — the colour is the difference,
  # not the shape.
  defp type_tone(:bug), do: "border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d]"
  defp type_tone(:task), do: "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]"
  defp type_tone(:question), do: "border-[#f0e3c9] bg-[#fdf7ea] text-[#8a5514]"
  defp type_tone(:suggestion), do: "border-[#d7eddf] bg-[#f2faf5] text-[#177a53]"
  defp type_tone(_type), do: "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63]"

  defp avatar_class(author), do: author |> Panels.avatar_tint() |> tint_class()

  defp tint_class("#1f9d6b"), do: "[background:#1f9d6b]"
  defp tint_class("#c07a2a"), do: "[background:#c07a2a]"
  defp tint_class("#b5495f"), do: "[background:#b5495f]"
  defp tint_class("#2f7fb5"), do: "[background:#2f7fb5]"
  defp tint_class(_indigo), do: "[background:#5b57d6]"

  # AN UNLOADED `has_many` IS `%Ash.NotLoaded{}` — truthy, and not a list. Matching on the loaded
  # shape rather than on presence is what keeps `Enum` from being handed a struct.
  defp replies(%{replies: replies}) when is_list(replies),
    do: Enum.sort_by(replies, & &1.inserted_at, DateTime)

  defp replies(_comment), do: []

  # Who may close a note. A row with no site belongs to every site, so only a master can change it —
  # the same rule `Validations.GlobalRowIsMasterOnly` enforces on the way in. One answer, drawn here
  # and enforced there, rather than a button that fails.
  defp closable?(%{site_id: nil}, %{master_user?: true}), do: true
  defp closable?(%{site_id: nil}, _state), do: false
  defp closable?(_comment, _state), do: true

  # `keep_loaded_records true` is on the resource, so this is every page loaded so far rather than
  # only the last one — which is what makes "Show older" accumulate instead of replace.
  defp records(%{state: %{loaded_records: loaded}}) when is_list(loaded), do: loaded
  defp records(_assigns), do: []

  # Filter values are keyed by ATOM and an empty value is DROPPED rather than stored as "", so an
  # absent key is the "no filter chosen" case, not a bug.
  defp selected_filter(%{filter_values: %{status: status}}) when not is_nil(status),
    do: to_string(status)

  defp selected_filter(_state), do: ""

  defp type_label(:bug), do: dgettext("mishka_gervaz", "bug")
  defp type_label(:information), do: dgettext("mishka_gervaz", "information")
  defp type_label(:suggestion), do: dgettext("mishka_gervaz", "suggestion")
  defp type_label(:question), do: dgettext("mishka_gervaz", "question")
  defp type_label(:task), do: dgettext("mishka_gervaz", "task")
  defp type_label(:other), do: dgettext("mishka_gervaz", "other")
  defp type_label(type), do: type

  defp empty_message("open"), do: gettext("Nothing open — every note here is resolved")
  defp empty_message("resolved"), do: gettext("Nothing resolved yet")
  defp empty_message(_all), do: gettext("No notes on this page yet")

  defp scope_label(%{node_id: nil}), do: gettext("whole page")

  defp scope_label(%{node_label: label}) when is_binary(label) and label != "",
    do: "<" <> label <> ">"

  defp scope_label(_comment), do: gettext("an element")

  defp author_label(comment, reader),
    do:
      person(
        comment.author,
        comment.author_id,
        Map.get(comment, :author_master?),
        comment.author_type,
        reader
      )

  # The email when the reader may see it, "Master" for a master, "Unknown" for anyone else; a note
  # with no author is the assistant's or the system's.
  defp person(user, id, master?, _type, reader) when is_binary(id),
    do:
      Helper.who(
        Helper.visible_to(user, reader),
        master? == true or Helper.master_user?(user),
        :unknown
      )

  defp person(_none, _id, _master?, :ai, _reader), do: dgettext("mishka_gervaz", "Assistant")
  defp person(_none, _id, _master?, _type, _reader), do: Helper.label(:system)

  defp resolver(comment, reader) do
    case comment.resolved_by_id do
      nil ->
        nil

      id ->
        person(comment.resolved_by, id, Map.get(comment, :resolved_by_master?), :human, reader)
    end
  end

  # THE DISC IS DRAWN FROM THE PERSON, NOT THE DOMAIN. `sara.lee@example.com` is SL, not SE — every
  # address at one domain would otherwise wear the same two letters.
  defp initials(name) when is_binary(name) do
    name
    |> String.split("@")
    |> hd()
    |> String.split(~r/[._\-+\s]/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1) || ""))
    |> case do
      "" -> "?"
      letters -> letters
    end
  end

  defp initials(_name), do: "?"
end
