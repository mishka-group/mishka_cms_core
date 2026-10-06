defmodule MishkaCmsCoreWeb.Templates.AssetsChrome do
  @moduledoc """
  Everything the builder's Assets sheet draws around its files, shared by both of its views.

  `MishkaCmsCoreWeb.Templates.AssetsGrid` and `MishkaCmsCoreWeb.Templates.AssetsList` differ in one
  thing — whether a file is a card or a row. The toolbar, the select-all, the bulk bar, the empty
  state and the load-more are the same on both, and were the same in two copies until the second
  view existed to prove it.

  ## Why the sheet does not use Gervaz's own `Table` for its list

  It did, and the reader could not see half of it. `MishkaGervaz.Table.Templates.Table` draws a
  PAGE: a filter bar with Search, Type, Site, Featured and the archive switch laid out across the
  width, then a multi-column table with its own header. The sheet is 620px of overlay with a folder
  rail down one side, so all of that ran off the right edge — the filters, the Type column, the
  actions. Nothing was broken; it was simply drawn for a surface four times as wide.

  So the sheet has two templates of its own, and both wear this chrome: one control (search), the
  switcher, and the folders answering in the rail what Type and Site would have answered in a bar.

  See `MishkaGervaz.Table.Web.State.apply_presentation/2` for how a mount chooses them.
  """

  use Phoenix.Component
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaGervaz.Table.Templates.Shared
  alias Phoenix.LiveView.JS

  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  @doc """
  Search and the view switch, the sheet's whole filter bar.

  Both are the library's own controls — the adapter's `text_input` in its filter variant and
  `Shared.render_template_switcher/1` — so the two surfaces read as one product.
  """
  def toolbar(assigns) do
    assigns =
      assigns
      |> assign(:query, search_value(assigns.state))
      |> assign(:switchable, assigns.static.switchable_templates || [])

    ~H"""
    <div class="flex items-center gap-2">
      <form id="pb-assets-search" phx-change="filter" phx-target={@myself} class="min-w-0 flex-1">
        <.dynamic_component
          module={@static.ui_adapter}
          function={:text_input}
          name="search"
          value={@query}
          placeholder={gettext("Search assets…")}
          search={true}
          autocomplete="off"
          phx-debounce="300"
        />
      </form>

      <Shared.render_template_switcher
        :if={length(@switchable) > 1}
        switchable_templates={@switchable}
        current_template={@state.template}
        ui_adapter={@static.ui_adapter}
        myself={@myself}
      />
    </div>
    """
  end

  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true
  attr :show_checkboxes, :boolean, required: true
  attr :show_bulk_actions, :boolean, required: true

  @doc """
  Select-all and the bulk bar, compacted for the sheet.

  `Shared.render_bulk_actions/1` forwards no class, so the bar arrives at the page's size; the
  wrapper's descendant utilities bring it down. They win on specificity without `!` — `[&>div]:mb-0`
  is `.…>div`, one class more than the `.mb-[14px]` it overrides.
  """
  def selection(assigns) do
    ~H"""
    <div
      :if={@show_checkboxes}
      class="flex items-center px-0.5 [&_label]:cursor-pointer [&_label]:gap-2 [&_span]:text-[11px]! [&_span]:font-bold [&_span]:text-[#5c5a54]"
    >
      <.dynamic_component
        module={@static.ui_adapter}
        function={:checkbox}
        id={@static.id <> "-select-all"}
        name="select_all_assets"
        value="all"
        checked={@state.select_all?}
        class="gervaz-select-all-checkbox size-[15px] cursor-pointer rounded accent-[#5b57d6]"
        label={dgettext("mishka_gervaz", "Select all")}
        phx-click={toggle_all_js(@state.select_all?, @static.id)}
        phx-target={@myself}
      />
    </div>

    <div
      :if={@show_bulk_actions}
      class="[&>div]:mb-0 [&>div]:gap-2 [&>div]:rounded-[11px] [&>div]:px-3 [&>div]:py-2 [&>div>span]:text-[11px] [&_button]:h-[28px] [&_button]:gap-1 [&_button]:px-2.5 [&_button]:text-[11px]"
    >
      <Shared.render_bulk_actions static={@static} state={@state} myself={@myself} />
    </div>
    """
  end

  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true
  attr :empty?, :boolean, required: true

  @doc "Nothing here, and the way to ask for the next page."
  def empty(assigns) do
    ~H"""
    <.dynamic_component
      :if={@empty?}
      module={@static.ui_adapter}
      function={:empty_state}
      message={gettext("No files in this folder yet")}
    />
    """
  end

  attr :static, :map, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  @doc """
  The next page, drawn by Gervaz exactly as the Media library draws it.

  This was a hand-rolled "Show more files" button, which meant the sheet had its own idea of paging
  — no count, no loading state, and nothing if the resource ever switched from `:load_more` to
  numbered pages. `Shared.render_pagination/1` reads the resource's `pagination do … end` and answers
  whatever it says, so the two surfaces page the same way for the same reason.

  Only the size is ours: the wrapper's descendant utilities bring the page's control down to the
  sheet's.
  """
  def pagination(assigns) do
    ~H"""
    <div class="[&_button]:h-[30px] [&_button]:text-[11px] [&_div]:gap-2 [&_select]:h-[30px] [&_select]:text-[11px] [&_span]:text-[11px]">
      <Shared.render_pagination static={@static} state={@state} myself={@myself} />
    </div>
    """
  end

  # SCOPED TO THIS TABLE, deliberately. `check_all_gallery/2` is a DOM write over
  # `.gervaz-media-checkbox`, and the builder can have a second Gervaz table mounted at the same
  # time — an unscoped select-all would tick the rows of a sheet the reader cannot even see.
  defp toggle_all_js(true, scope),
    do: Shared.uncheck_all(JS.push("toggle_select_all"), scope)

  defp toggle_all_js(_off, scope),
    do: Shared.check_all_gallery(JS.push("toggle_select_all"), scope)

  @doc false
  @spec search_value(map()) :: String.t()
  def search_value(%{filter_values: values}) when is_map(values),
    do: Map.get(values, :search) || ""

  def search_value(_state), do: ""
end
