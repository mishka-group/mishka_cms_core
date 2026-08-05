defmodule MishkaCmsCoreWeb.Templates.StudioSnippets do
  @moduledoc """
  A MishkaGervaz custom table template: the saved-snippet list inside the page builder's Studio.

  It owns the list and nothing around it. The "Save as snippet" box above it is a Gervaz FORM —
  `MishkaCmsCoreWeb.Templates.SnippetForm` — and both are mounted side by side from
  `MishkaCmsCoreWeb.Live.Admin.Builder.Panels`.

  `features/0` is empty on purpose: the Studio is a 520px sheet, and Gervaz's filter bar, selection
  checkboxes and pagination footer would each be a control the design does not have. The three
  scope chips ARE the table's `:scope` filter, drawn here in the sheet's idiom and pushed as the
  table's own `filter` event.

  Insert and Delete are hand-drawn rather than `row_actions`, for two reasons: their DOM ids
  (`pb-snippet-insert-<id>`, `pb-snippet-delete-<id>`) are a contract the tests hold, and Gervaz's
  row actions would need a `get` action on the resource that does not exist. Neither carries a
  `phx-target`, so both reach `BuilderLive`, which owns inserting into the tree and deleting the row.

  Every value a row shows beyond the name — the scope label, the block count, the byte size, the
  swatch tint, the relative time — is read off `source` by
  `MishkaCmsCore.Runtime.PageBuilder.Snippets.row/1` rather than stored, so a row can never claim
  three blocks while holding one.

  The swatch tint is one of the six `Snippets` picks from a name, and `tint_class/1` turns it into a
  whole class rather than a `style` attribute — CSP has no nonce for an attribute, so
  `style-src-attr` can only be closed by there being none. Written out one clause per colour because
  Tailwind reads source text and an interpolated class name gets no rule at all, which is what
  `MishkaCmsWeb.InterpolatedClassTest` guards.

  See `MishkaCmsCore.Runtime.Snippet`, which points its `presentation` here.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Snippets
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @chips [
    {"all", gettext_noop("All")},
    {"page", gettext_noop("This page")},
    {"global", gettext_noop("Shared")}
  ]

  @impl true
  def name, do: :studio_snippets

  @impl true
  def label, do: dgettext("mishka_gervaz", "Saved snippets")

  @impl true
  def description, do: dgettext("mishka_gervaz", "The Studio's saved snippet list")

  @impl true
  def icon, do: "hero-square-2-stack"

  @impl true
  # Nothing: this template draws its own chips, its own rows and its own load-more.
  def features, do: []

  @impl true
  def default_options, do: []

  @impl true
  def render_loading(assigns) do
    ~H"""
    <div data-role="pb-snippet-skeleton" class="flex flex-col gap-[9px]">
      <div
        :for={row <- 1..3}
        id={"pb-snippet-skel-#{row}"}
        class="h-[84px] animate-pulse rounded-[12px] border border-[#f0efea] bg-[#faf9f6]"
      >
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:chips, chips())
      |> assign(:selected_chip, selected_chip(assigns.state))
      |> assign(:records, records(assigns.state))
      |> assign(:more?, assigns.state.has_more? == true)
      # `state.loading` and NOT `records_result.loading`: the async result stays `ok?` across a
      # load-more, so the latter is nil exactly when the button most needs to be disabled.
      |> assign(:loading?, assigns.state.loading == :loading)

    ~H"""
    <div class="mishka-gervaz-studio-snippets">
      <div class="mb-3 flex gap-1.5">
        <button
          :for={{key, label} <- @chips}
          type="button"
          id={"pb-snip-#{key}"}
          phx-click="filter"
          phx-value-scope={chip_value(key)}
          phx-target={@myself}
          class={[
            "h-[27px] flex-none rounded-full border px-[11px] text-[10.5px] font-semibold",
            (@selected_chip == key && "border-[#17161a] bg-[#17161a] text-white") ||
              "border-[#ecebe6] bg-[#f6f5f2] text-[#6d6a63]"
          ]}
        >
          {label}
        </button>
      </div>

      <p
        :if={@records == [] and !@loading?}
        class="px-2.5 py-9 text-center text-[12px] font-medium text-[#6d6a63]"
      >
        {gettext("No snippets saved yet.")}
      </p>

      <%!-- Every page loaded so far, kept by Gervaz because the resource asked for it. A stream
            would append, and a reload after a save or a delete would then leave the stale row on
            screen and the new one off it. --%>
      <div id="pb-snippet-list" class="flex flex-col gap-[9px]">
        <.render_item
          :for={record <- @records}
          id={"pb-snippet-#{record.id}"}
          record={record}
          static={@static}
          state={@state}
          myself={@myself}
        />
      </div>

      <%!-- Gervaz's own `load_more` event, drawn in the sheet's idiom rather than through the
            pagination footer `features/0` suppresses. --%>
      <button
        :if={@more?}
        type="button"
        id="pb-snippet-more"
        phx-click="load_more"
        phx-target={@myself}
        disabled={@loading?}
        class="mb-2 mt-2.5 h-8 w-full rounded-[9px] border border-[#ecebe6] bg-[#faf9f6] text-[10.5px] font-bold text-[#6d6a63] hover:bg-[#f2f1ec] disabled:opacity-60"
      >
        {(@loading? && gettext("Loading…")) || gettext("Load more snippets")}
      </button>
    </div>
    """
  end

  @impl true
  def render_item(assigns) do
    assigns = assign(assigns, :row, Snippets.row(assigns.record))

    ~H"""
    <%!-- DRAGGABLE, like everything else you can place. A snippet is the fourth thing this editor
          puts on a page — after a kit component, a structural element and a finished section — and
          it was the only one you could not drag. Same hook, same `data-template`, so the canvas
          cannot tell them apart and neither can the reader. Insert still places it at the
          selection; dragging places it where you point. --%>
    <article
      id={@id}
      phx-hook="PbPaletteItem"
      draggable="true"
      data-template={@record.source}
      title={
        gettext("%{name} — Insert to place it at the selection, or drag it onto the canvas",
          name: @row.name
        )
      }
      class="cursor-grab rounded-[12px] border border-[#ecebe6] bg-white px-[13px] py-3"
    >
      <div class="flex items-center gap-2.5">
        <span class={[
          "grid h-[26px] w-[34px] flex-none place-items-center rounded-[7px] text-[#8580d8]",
          tint_class(@row.tint)
        ]}>
          <Panels.icon name={:card} size={14} />
        </span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-[12px] font-bold text-[#17161a]">
            {@row.name}
          </span>
          <span class="mt-0.5 block truncate font-['Space_Grotesk'] text-[10px] font-medium text-[#6d6a63]">
            {@row.scope} · {ngettext("%{count} block", "%{count} blocks", @row.blocks)} · {@row.size}
          </span>
        </span>
        <span class="flex-none rounded-[5px] bg-[#f4f3ee] px-[7px] py-0.5 text-[10px] font-bold uppercase tracking-[0.04em] text-[#6d6a63]">
          {@row.section}
        </span>
      </div>

      <div class="mt-[11px] flex items-center gap-2 border-t border-[#f4f3ee] pt-2.5">
        <span class="min-w-0 flex-1 truncate text-[10px] font-medium text-[#6d6a63]">
          {gettext("Saved %{time}", time: @row.when)}
        </span>
        <button
          :if={deletable?(@row, @state)}
          type="button"
          id={"pb-snippet-delete-#{@row.id}"}
          phx-click="delete_snippet"
          phx-value-id={@row.id}
          title={gettext("Delete snippet")}
          class="grid size-7 flex-none place-items-center rounded-[8px] border border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"
        >
          <Panels.icon name={:trash} size={13} />
        </button>
        <button
          type="button"
          id={"pb-snippet-insert-#{@row.id}"}
          phx-click="insert_snippet"
          phx-value-id={@row.id}
          class="inline-flex h-7 flex-none items-center gap-1.5 rounded-[8px] border border-[#dcdbf5] bg-[#f2f1fc] px-3 text-[10.5px] font-bold text-[#4f4bcc] hover:bg-[#e9e7fb]"
        >
          <Panels.icon name={:plus} size={12} /> {gettext("Insert")}
        </button>
      </div>
    </article>
    """
  end

  defp chips do
    Enum.map(@chips, fn {key, label} -> {key, Gettext.gettext(MishkaCmsCore.Gettext, label)} end)
  end

  # "All" is the filter unset. A chip that pushed a third value would need a third `scope` the
  # resource does not have.
  defp chip_value("all"), do: ""
  defp chip_value("page"), do: "page"
  defp chip_value("global"), do: "shared"

  # Gervaz keys `filter_values` by the filter's name as an ATOM, and drops a filter whose value is
  # empty rather than storing "" — so an absent `:scope` is the All chip.
  defp selected_chip(%{filter_values: %{scope: scope}}) when scope in [:page, "page"], do: "page"

  defp selected_chip(%{filter_values: %{scope: scope}}) when scope in [:shared, "shared"],
    do: "global"

  defp selected_chip(_state), do: "all"

  defp records(%{loaded_records: records}) when is_list(records), do: records
  defp records(_state), do: []

  # A tenant sees the global snippets and may not delete one — it belongs to every site, so removing
  # it would take it from all of them. Drawing the control anyway would promise an action that can
  # only ever be refused.
  defp deletable?(%{scope_type: "global"}, state), do: state.master_user? == true
  defp deletable?(_row, _state), do: true

  defp tint_class("#f3eefd"), do: "[background:#f3eefd]"
  defp tint_class("#eefaf4"), do: "[background:#eefaf4]"
  defp tint_class("#fdf4ee"), do: "[background:#fdf4ee]"
  defp tint_class("#fdeef4"), do: "[background:#fdeef4]"
  defp tint_class("#eef8fd"), do: "[background:#eef8fd]"
  defp tint_class(_blue), do: "[background:#eef1fd]"
end
