# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.HistoryTimeline do
  @moduledoc """
  The visual editor's history, drawn as a MishkaGervaz custom table template: a vertical rail with a
  bucket-tinted node per change, the assistant's own words where it has them, and a Revert on every
  row whose document was kept.

  Backed by `MishkaCmsCore.Runtime.PageBuilderEvent` and opened from the builder's Record-history
  sheet. It replaced a hand-rolled `<ol>` over the in-memory undo stack, which meant the sheet showed
  one session's ops, called every author "You", and lost everything on reload.

  ## Why a second timeline template

  `MishkaCmsCoreWeb.Templates.ActivityTimeline` draws a vertical timeline too, and is deliberately NOT
  extended: it binds row content by column POSITION, and its `dot_class` / `node_class` helpers are
  public API for `MishkaCmsCore.Activity.ActivityEntry` and `MishkaDocument.EventLog`. Reusing it
  would couple three unrelated tables through a shared private vocabulary. This follows
  `MishkaCmsCoreWeb.Templates.ReviewComments` instead — filter pills, per-row buttons, one static
  column the template unpacks itself.

  A template owns the whole table, so the filter bar and the footer are here. No UI adapter is
  involved: everything this draws is either the template's own markup or a column's `render`.

  ## Two rules that are easy to get wrong

  **`filter_values` is keyed by the filter's ATOM name** — gervaz builds it with
  `Map.put(acc, filter.name, value)`. Reading it with a string key answers `nil` silently, and the
  table then renders unfiltered with every pill unchecked, which looks like the pills are unwired.

  **Author branches on `author_type` BEFORE the masking ladder.** Every row carries a human
  `author_id`, including an assistant's — it is whoever's editor ran the prompt — so a ladder that
  matches an email-bearing author first would print the operator's address under the assistant's
  work. See `MishkaCmsCore.Runtime.PageBuilderEvent`.
  """
  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Runtime.PageBuilder.History
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @impl true
  def name, do: :history_timeline

  @impl true
  def label, do: dgettext("mishka_gervaz", "History timeline")

  @impl true
  def icon, do: "hero-clock"

  @impl true
  def description,
    do: dgettext("mishka_gervaz", "The visual editor's recorded changes, newest first")

  @impl true
  def features, do: [:filter, :paginate]

  @impl true
  def default_options, do: []

  # Rows are drawn by `render/1`, which owns the whole list; the behaviour requires this to exist.
  @impl true
  def render_item(assigns), do: ~H""

  @doc """
  The timeline, before it knows what happened.

  Three rows the shape of a real one — dot, connector, a title and a line of detail — so the sheet
  settles into its content instead of replacing a centred spinner with a list.
  """
  @impl true
  def render_loading(assigns) do
    ~H"""
    <div data-role="pb-history-skeleton" aria-hidden="true">
      <div :for={_row <- 1..3//1} class="flex gap-[11px] pb-[15px]">
        <span class="flex w-6 flex-none flex-col items-center">
          <span class="size-6 flex-none animate-pulse rounded-full bg-[#f2f1ec]"></span>
          <span class="mt-1 min-h-[14px] w-0.5 flex-1 bg-[#f0efea]"></span>
        </span>

        <div class="min-w-0 flex-1 pt-1">
          <span class="block h-[9px] w-2/5 animate-pulse rounded-full bg-[#f2f1ec]"></span>
          <span class="mt-2 block h-[7px] w-4/5 animate-pulse rounded-full bg-[#f6f5f2]"></span>
          <span class="mt-2.5 block h-[6px] w-1/4 animate-pulse rounded-full bg-[#f6f5f2]"></span>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    static = assigns.static

    assigns =
      assigns
      |> assign(:show_filters, static.filters != [] and :filter in static.features)
      |> assign(:show_pagination, :paginate in static.features)
      |> assign(:reader, reader(assigns.state))

    ~H"""
    <div class="mishka-gervaz-history-timeline">
      <div :if={@state.has_initial_data? or @state.loading == :loaded}>
        <.render_filters :if={@show_filters} static={@static} state={@state} myself={@myself} />

        <%!-- A timeline, not a list of cards: the connector is what says these are consecutive
              states of one document rather than unrelated events. --%>
        <ol id={"#{@static.stream_name}"} phx-update="stream">
          <li
            id={"#{@static.stream_name}-empty-state"}
            class="hidden only:block py-6 text-[12.5px] font-medium text-[#6d6a63]"
          >
            {empty_message(@static)}
          </li>

          <li
            :for={{dom_id, record} <- @stream}
            id={dom_id}
            class="flex gap-[11px] pb-[15px]"
          >
            <span class="flex w-6 flex-none flex-col items-center">
              <span class={[
                "grid size-6 flex-none place-items-center rounded-full",
                dot_class(record.kind)
              ]}>
                <.icon name={kind_icon(record.kind)} class="size-3" />
              </span>
              <span class="mt-1 min-h-[14px] w-0.5 flex-1 bg-[#f0efea]"></span>
            </span>

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-[7px]">
                <span class="text-[11.5px] font-bold text-[#1b1a18]">{row_label(record)}</span>
                <span class={[
                  "flex-none rounded-[5px] px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-[0.04em]",
                  dot_class(record.kind)
                ]}>
                  {badge(record)}
                </span>
              </div>

              <div
                :if={detail(record) != ""}
                class="mt-1 text-[11px] font-medium leading-[1.5] text-[#6d6a63]"
              >
                {detail(record)}
              </div>

              <%!-- Violet for something the assistant is telling you, amber for something the editor
                    is warning you about. Reading identically would be the lie. Clamped to three
                    lines; `<details>` is the spoiler, so no JS and no hook. --%>
              <details
                :if={record.note}
                class={["group mt-2 rounded-[10px] border px-2.5 py-2.5", note_class(record)]}
              >
                <summary class="flex list-none cursor-pointer items-start gap-2 [&::-webkit-details-marker]:hidden">
                  <.icon name={note_icon(record)} class={note_icon_class(record)} />
                  <span class="min-w-0 flex-1 text-[11px] font-medium leading-[1.55] text-[#3a382f] line-clamp-3 group-open:line-clamp-none">
                    {record.note}
                  </span>
                </summary>

                <div
                  :if={record.prompt}
                  class="mt-2 border-t border-[#ece9fa] pt-2 text-[10.5px] font-medium leading-[1.5] text-[#6d6a63]"
                >
                  <span class="font-bold text-[#4f4bcc]">{dgettext("mishka_gervaz", "Asked")}:</span>
                  “{record.prompt}”
                  <span :if={record.backend} class="ms-1 text-[#a8a5a0]">· {record.backend}</span>
                </div>
              </details>

              <div class="mt-1.5 flex items-center gap-2">
                <span
                  id={"pb-history-author-#{record.id}"}
                  dir="auto"
                  class="text-[10px] font-semibold text-[#6d6a63]"
                >
                  {author(record, @reader)}
                </span>
                <span class="size-[3px] flex-none rounded-full bg-[#d5d3cc]"></span>
                <span class="font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63]">
                  {Panels.ago(record.inserted_at)}
                </span>
                <span class="flex-1"></span>

                <%!-- A row whose document was not kept says WHY, rather than offering a button that
                      fails. That is what makes dropping old payloads a safe answer to the cap. --%>
                <span
                  :if={is_nil(record.snapshot_id)}
                  title={unrevertible_title(record)}
                  class="h-[22px] flex-none rounded-[6px] bg-[#f4f3ef] px-2.5 text-[9.5px] font-bold leading-[22px] text-[#a8a5a0]"
                >
                  {unrevertible_label(record)}
                </span>
                <button
                  :if={record.snapshot_id}
                  type="button"
                  phx-click="history_revert"
                  phx-value-id={record.id}
                  title={
                    dgettext(
                      "mishka_gervaz",
                      "Restores the document in the editor. The live page does not change until you publish."
                    )
                  }
                  class="h-[22px] flex-none rounded-[6px] border border-[#ecebe6] bg-white px-2.5 text-[9.5px] font-bold text-[#5c5a54] hover:border-[#c3c1f0] hover:text-[#4f4bcc]"
                >
                  {dgettext("mishka_gervaz", "Revert")}
                </button>
              </div>
            </div>
          </li>
        </ol>

        <.render_pagination :if={@show_pagination} static={@static} state={@state} myself={@myself} />
      </div>
    </div>
    """
  end

  @doc """
  The four pills — All / Content / Style / Publish — as radios rather than a dropdown.

  "All" is the empty value of the one `:select` filter, so switching to it clears rather than
  filtering on a fourth thing.
  """
  @impl true
  def render_filters(assigns) do
    kind = Enum.find(assigns.static.filters, &(&1.name == :kind))

    assigns =
      assigns
      |> assign(:options, [{dgettext("mishka_gervaz", "All"), ""} | options(kind)])
      |> assign(:active, to_string(Map.get(assigns.state.filter_values || %{}, :kind) || ""))

    ~H"""
    <form
      id={"#{@static.stream_name}-filter"}
      phx-change="filter"
      phx-target={@myself}
      class="mb-3.5 flex gap-1.5"
    >
      <label :for={{label, value} <- @options} class="flex-none">
        <input type="radio" name="kind" value={value} checked={@active == value} class="peer sr-only" />
        <span class="block h-[27px] cursor-pointer rounded-full border border-[#ecebe6] bg-[#f6f5f2] px-[11px] text-[10.5px] font-semibold leading-[25px] text-[#6d6a63] peer-checked:border-[#17161a] peer-checked:bg-[#17161a] peer-checked:text-white">
          {label}
        </span>
      </label>
    </form>
    """
  end

  @impl true
  def render_pagination(assigns) do
    assigns =
      assign(
        assigns,
        :load_more?,
        get_in(assigns.static.config, [:pagination, :type]) == :load_more and
          assigns.state.has_more? and assigns.state.loading != :loading
      )

    ~H"""
    <div :if={@load_more?} class="mt-1 flex justify-center">
      <button
        type="button"
        phx-click="load_more"
        phx-target={@myself}
        class="inline-flex h-[32px] items-center gap-1.5 rounded-[9px] border border-[#ecebe6] bg-white px-3.5 text-[11px] font-semibold text-[#4f4bcc] hover:bg-[#f2f1fc]"
      >
        {dgettext("mishka_gervaz", "Load more")}
      </button>
    </div>
    """
  end

  defp options(nil), do: []

  defp options(%{options: options}) when is_list(options),
    do:
      options |> MishkaGervaz.Helpers.translate_options() |> Enum.map(&{elem(&1, 0), elem(&1, 1)})

  defp options(_filter), do: []

  defp empty_message(static) do
    case get_in(static.config, [:empty_state, :message]) do
      message when is_binary(message) ->
        Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", message)

      _none ->
        dgettext("mishka_gervaz", "Nothing yet")
    end
  end

  # The three buckets, in the colours the editor has always drawn them.
  defp dot_class(:content), do: "[background:#f2f1fc] [color:#4f4bcc]"
  defp dot_class(:style), do: "[background:#fbf1df] [color:#8a5514]"
  defp dot_class(_publish), do: "[background:#e6f6ee] [color:#177a53]"

  defp kind_icon(:content), do: "hero-document"
  defp kind_icon(:style), do: "hero-pencil"
  defp kind_icon(_publish), do: "hero-arrow-up-circle"

  # The badge says what HAPPENED; the bucket is what the pills filter on. Deliberately different for
  # a rollback: "PUBLISH" over a restore is not what happened.
  # ASKED, NOT LISTED. This kept its own idea of which ops read as a step rather than a change, and
  # it disagreed with the one the bucket rule uses.
  defp badge(%{op: op, kind: kind}), do: badge_word((History.publish_op?(op) && op) || kind)

  defp badge_word(:restore), do: dgettext("mishka_gervaz", "restore")
  defp badge_word(:undo), do: dgettext("mishka_gervaz", "undo")
  defp badge_word(:publish), do: dgettext("mishka_gervaz", "publish")
  defp badge_word(:content), do: dgettext("mishka_gervaz", "content")
  defp badge_word(:style), do: dgettext("mishka_gervaz", "style")
  defp badge_word(other), do: other

  defp row_label(%{label: label}) when is_binary(label),
    do: Gettext.gettext(MishkaCmsCore.Gettext, label)

  defp row_label(%{label: label}), do: label

  defp detail(record) do
    [record.target, record.detail]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # A warning and an explanation must not look the same.
  defp note_class(%{snapshot_id: nil}), do: "border-[#f0e2c8] bg-[#fdfaf3]"
  defp note_class(_record), do: "border-[#e8e6f8] bg-[#faf9ff]"

  defp note_icon(%{snapshot_id: nil}), do: "hero-exclamation-triangle"
  defp note_icon(_record), do: "hero-bolt"

  # `icon/1` takes a string, and Tailwind reads source text — whole literals, one clause each.
  defp note_icon_class(%{snapshot_id: nil}), do: "mt-0.5 size-3 flex-none text-[#a5691a]"
  defp note_icon_class(_record), do: "mt-0.5 size-3 flex-none text-[#7a5bd0]"

  defp unrevertible_label(%{refused: true}), do: dgettext("mishka_gervaz", "Too large to restore")
  defp unrevertible_label(_record), do: dgettext("mishka_gervaz", "Snapshot dropped")

  defp unrevertible_title(%{refused: true}),
    do:
      dgettext(
        "mishka_gervaz",
        "The document was past the size this keeps, so no snapshot was taken."
      )

  defp unrevertible_title(_record),
    do:
      dgettext(
        "mishka_gervaz",
        "Older than this page keeps documents for. The change is recorded; it can no longer be restored."
      )

  defp reader(%{current_user: %{site_id: site_id}}), do: %{site_id: site_id}
  defp reader(_state), do: %{site_id: :nobody}

  # Branch on `author_type` first: an assistant's row carries the human who ran the prompt.
  defp author(%{author_type: :ai} = record, reader), do: assistant_label(record, reader)
  defp author(%{author_type: :system}, _reader), do: dgettext("mishka_gervaz", "System")

  defp author(record, reader),
    do: person(record.author, record.author_id, Map.get(record, :author_master?), reader)

  defp assistant_label(%{note_author_id: nil}, _reader),
    do: dgettext("mishka_gervaz", "Assistant")

  defp assistant_label(record, reader) do
    who =
      person(
        record.note_author,
        record.note_author_id,
        Map.get(record, :note_author_master?),
        reader
      )

    dgettext("mishka_gervaz", "Assistant · annotated by %{who}", who: who)
  end

  # The email when the reader may see it, "Master" for a master, "Unknown" for anyone else.
  defp person(_user, nil, _master?, _reader), do: dgettext("mishka_gervaz", "System")

  defp person(user, _id, master?, reader),
    do:
      Helper.who(
        Helper.visible_to(user, reader),
        master? == true or Helper.master_user?(user),
        :unknown
      )
end
