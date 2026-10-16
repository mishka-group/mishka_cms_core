# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Templates.DraftList do
  @moduledoc """
  A MishkaGervaz custom table template: the list of drafts inside the page builder's Versions sheet.

  It is the third block of `MishkaCmsCoreWeb.Live.Admin.Builder.Panels.drafts_sheet/1` — the rows,
  their skeleton and their empty state. The "Save as" form and the name-collision banner above it are
  not a table and stay in `Panels`.

  The template owns the whole list and nothing else: no filter bar, no selection, no pagination
  footer (`features/0` is empty), because the sheet is 420px wide and the read is capped at one
  document's drafts. Its row buttons deliberately carry no `phx-target`, so `open_draft`,
  `fork_draft` and `delete_draft` reach `MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive`, which owns
  the editing session those events move.

  Which row reads as "Editing" is not a property of the row — it is the editor's save target — so it
  travels in `path_params[:editing_draft_id]`, the same channel the scoping `source_*_id` uses.

  See `MishkaCmsCore.Runtime.PageDraft`, `MishkaCmsCore.Runtime.LayoutDraft` and
  `MishkaCmsCore.Runtime.ErrorPageDraft`, which point their `presentation` here.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  alias MishkaCmsCore.Runtime.PageBuilder.Drafts
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @impl true
  def name, do: :draft_list

  @impl true
  def label, do: dgettext("mishka_gervaz", "Drafts")

  @impl true
  def icon, do: "hero-square-3-stack-3d"

  @impl true
  def description, do: dgettext("mishka_gervaz", "The page builder's draft picker")

  @impl true
  # The chrome this template draws. `features/0` is the switch: with `[]` the filter row, the
  # selection checkboxes and the load-more button are never rendered, however the resource declares
  # them — which is why a configured `pagination do type :load_more end` reached no page two.
  def features, do: [:filter, :select, :bulk_actions, :paginate]

  @impl true
  def default_options, do: []

  @doc """
  The skeleton drawn before the table has any state of its own.

  It takes none of the table's assigns, because at this point there are none — `@static` and
  `@state` do not exist until the first load.
  """
  @impl true
  def render_loading(assigns) do
    ~H"""
    <Panels.loading_rows rows={3} />
    """
  end

  @doc """
  The list: skeleton while the read is out, one row per draft, and the empty state when there are
  none.

  The stream container is `display: contents` so the rows stay flex children of the `gap-1.5`
  column, and the empty state is a sibling of it rather than a child, because it is driven by
  `@empty?` (loaded AND zero rows) — "no drafts" and "not yet known" are different answers and the
  sheet gives neither one's markup to the other.
  """
  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:editing_id, Map.get(assigns.state.path_params, :editing_draft_id))
      |> assign_new(:before_table, fn -> nil end)
      |> Gervaz.assign_card_flags()

    ~H"""
    <div class="mishka-gervaz-draft-list">
      <Shared.card_scaffold
        static={@static}
        state={@state}
        myself={@myself}
        container_class="flex flex-col gap-1.5"
        data_role="pb-draft-list"
        empty_label={gettext("No drafts yet. “Save as” keeps one you can come back to.")}
        empty_icon="hero-document-duplicate"
        show_checkboxes={@show_checkboxes}
        show_filters={@show_filters}
        show_pagination={@show_pagination}
        show_bulk_actions={@show_bulk_actions}
        show_switcher={@show_switcher}
        before_table={@before_table}
      >
        <:records>
          <.render_item
            :for={{id, draft} <- @stream}
            id={id}
            draft={draft}
            editing_id={@editing_id}
            static={@static}
            state={@state}
            show_checkboxes={@show_checkboxes}
            myself={@myself}
          />
        </:records>
      </Shared.card_scaffold>
    </div>
    """
  end

  @doc """
  One draft: open it, copy it, throw it away.

  The row the editor is pointed at is marked four times over — border, tile, title weight and the
  "Editing" pill — because a single background tint is not enough to answer "where does the next
  save go" at a glance.
  """
  @impl true
  def render_item(assigns) do
    %{draft: draft} = assigns

    assigns =
      assigns
      |> assign(:editing?, draft.id == assigns.editing_id)
      |> assign(
        :visible_row_actions,
        Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, draft, assigns.state))
      )
      |> assign(:saved, saved_label(draft))
      |> assign(:ago, Panels.ago(draft.updated_at))

    ~H"""
    <div
      id={@id}
      class={[
        "group flex w-full items-center gap-2.5 rounded-[10px] border px-3 py-2.5",
        (@editing? && "border-[#dcdbf5] bg-[#f2f1fc]") ||
          "border-[#ecebe6] bg-white hover:bg-[#f7f6f3]"
      ]}
    >
      <button
        type="button"
        id={"pb-draft-#{@draft.id}"}
        phx-click="open_draft"
        phx-value-id={@draft.id}
        class="flex min-w-0 flex-1 items-center gap-2.5 text-start"
      >
        <span class={[
          "grid size-[26px] flex-none place-items-center rounded-[8px]",
          (@editing? && "bg-[#e4e2f7] text-[#4f4bcc]") || "bg-[#f2f1ec] text-[#6d6a63]"
        ]}>
          <Panels.icon name={:layers} size={13} />
        </span>
        <span class="min-w-0 flex-1">
          <span class={[
            "block truncate font-['Space_Grotesk'] text-[12px]",
            (@editing? && "font-bold text-[#2e2b6b]") || "font-semibold text-[#1b1a18]"
          ]}>
            {draft_title(@draft)}
          </span>
          <span class="mt-0.5 block text-[10px] font-medium text-[#6d6a63]">
            {@saved} {@ago}
          </span>
        </span>
        <span
          :if={@editing?}
          class="flex-none text-[9.5px] font-bold uppercase tracking-[0.08em] text-[#4f4bcc]"
        >
          {gettext("Editing")}
        </span>
      </button>
      <%!-- Drawn by Gervaz from the resource's `row_actions`, so the label, icon, confirm text and
            visibility rule live with the resource like every other table's — not here. --%>
      <Gervaz.render_row_actions
        row_actions={@visible_row_actions}
        record={@draft}
        static={@static}
        state={@state}
        myself={@myself}
      />
    </div>
    """
  end

  defp saved_label(%{label: label}) do
    case Drafts.autosave_label() do
      ^label -> gettext("Saved automatically")
      _named -> gettext("Saved")
    end
  end

  defp draft_title(%{label: label}) when label in [nil, false], do: gettext("Untitled draft")

  defp draft_title(%{label: label}) do
    case Drafts.autosave_label() do
      ^label -> Gettext.gettext(MishkaCmsCore.Gettext, label)
      _named -> label
    end
  end
end
