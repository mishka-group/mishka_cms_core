# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.TopbarSearch do
  @moduledoc """
  The search box of the admin top bar. What it finds comes from extensions, on the `"topbar:search"`
  mishka_installer event, as their items come on `"topbar:items"`
  (`MishkaCmsCore.Layouts.TopbarItems`): a shop answers with its products, customers and orders, a
  blog with its posts. The core answers nothing itself.

  ## What a plugin is handed

      %{
        query: "aurora",         # trimmed, never empty, at most 100 characters
        groups: [group],
        current_user: user,      # with :permissions loaded; a master has no site_id
        current_site: site,      # the site the request resolved to, or nil
        current_path: "/admin/dashboard/...",
        view: module()
      }

  It answers `{:reply, %{data | groups: groups ++ mine}}`, finding only what `current_user` may read
  on their own site (a master reads every site). A group is a map:

    * `id` — a string, unique and stable;
    * `label` — the group's heading, already translated: "Products";
    * `rows` — what was found, each `%{title: String.t(), link: String.t()}` with an optional
      `detail`, the line under the title, and `icon`, a `hero-*` name. `link` is a path of this app
      (`MishkaCmsCore.Layouts.TopbarNeeds.local_path/1`); a row without one is dropped. The first
      eight rows are shown;
    * `permission` — optional, one name or a list where holding ANY is enough
      (`MishkaCmsCore.Settings.permitted?/2`); a group the viewer may not see is dropped;
    * `priority` — optional, an integer, 50 by default: low comes first, `id` breaks a tie.

  A group with no row, no `id` or no `label`, or an `id` already taken, is dropped.

  ## The box's placeholder

  The box says what it searches. When a page opens, and when its path changes, the plugins are
  handed the same map with an empty `query` and `placeholder: nil`, and a plugin that is at home on
  the page answers `%{data | placeholder: "Search products, orders, customers…"}`; the first
  placeholder given is shown, and the core's own is shown when none is. A plugin that searches
  skips an empty query, and a plugin that has no placeholder answers `data` as it was.

      defmodule MyShop.Search do
        use MishkaInstaller.Event.Hook, event: "topbar:search"

        @impl true
        def call(%{query: query, groups: groups, current_user: user} = data) do
          rows =
            for product <- MyShop.Products.search(query, actor: user) do
              %{title: product.name, detail: product.tagline, icon: "hero-cube",
                link: "/admin/dashboard/shop/products/" <> product.id}
            end

          group = %{id: "shop-products", label: "Products", rows: rows,
                    permission: "admin:dashboard:shop"}

          {:reply, %{data | groups: groups ++ [group]}}
        end
      end

  ## When it is called

  `MishkaCmsCore.Layouts.TopbarSearch.Combo`, the box, asks after the admin stops typing for a
  quarter of a second, off the page's process, and a newer query wins over one still running. A
  plugin that raises is logged by mishka_installer and the box shows what the others found.

  ## Telemetry

    * `[:mishka_cms, :topbar_search, :start | :stop | :exception]` — a `:telemetry.span/3` around
      the plugins' answer. Metadata: `%{view: module}`, and on `:stop` also `%{groups: integer}`, the
      groups shown.
  """

  alias MishkaCmsCore.Layouts.TopbarNeeds
  alias MishkaCmsCore.Settings

  @type row :: %{
          required(:title) => String.t(),
          required(:link) => String.t(),
          required(:detail) => String.t() | nil,
          required(:icon) => String.t()
        }

  @type group :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:rows) => [row()],
          required(:priority) => integer(),
          optional(:permission) => String.t() | [String.t()]
        }

  @type context :: %{
          current_user: map() | nil,
          current_site: map() | nil,
          current_path: String.t() | nil,
          view: module() | nil
        }

  @event "topbar:search"
  @span [:mishka_cms, :topbar_search]
  @max_query 100
  @max_rows 8
  @priority 50
  @icon "hero-document-text"

  @doc "The mishka_installer event extensions answer the top bar's search on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The groups that answer `query` for `context`, low priority first, each one the context's
  `current_user` may see and with a row at least. An empty query asks no plugin and returns `[]`.
  """
  @spec collect(String.t(), context()) :: [group()]
  def collect(query, %{current_user: user} = context) when is_binary(query) do
    case query |> String.trim() |> String.slice(0, @max_query) do
      "" ->
        []

      query ->
        :telemetry.span(@span, %{view: context[:view]}, fn ->
          groups = ask(Map.merge(context, %{query: query, groups: []}), user)
          {groups, %{view: context[:view], groups: length(groups)}}
        end)
    end
  end

  @doc """
  What the search box says it searches on the page of `context`, as the first plugin that has a
  placeholder answers it. `nil` when none does, and the box keeps the core's words.
  """
  @spec placeholder(context()) :: String.t() | nil
  def placeholder(%{current_user: _user} = context) do
    payload = Map.merge(context, %{query: "", groups: [], placeholder: nil})

    case MishkaInstaller.Event.Hook.call(@event, payload) do
      %{placeholder: text} when is_binary(text) and text != "" -> text
      _nothing -> nil
    end
  end

  defp ask(payload, user) do
    case MishkaInstaller.Event.Hook.call(@event, payload) do
      %{groups: groups} when is_list(groups) ->
        groups
        |> Enum.flat_map(&group/1)
        |> Enum.filter(&Settings.permitted?(&1, user))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{&1.priority, &1.id})

      _nothing ->
        []
    end
  end

  defp group(%{id: id, label: label, rows: rows} = group)
       when is_binary(id) and id != "" and is_binary(label) and label != "" and is_list(rows) do
    case rows |> Enum.flat_map(&row/1) |> Enum.take(@max_rows) do
      [] -> []
      rows -> [Map.merge(group, %{rows: rows, priority: priority(group[:priority])})]
    end
  end

  defp group(_other), do: []

  defp row(%{title: title, link: link} = row) when is_binary(title) and title != "" do
    case TopbarNeeds.local_path(link) do
      nil -> []
      link -> [%{title: title, link: link, detail: detail(row[:detail]), icon: icon(row[:icon])}]
    end
  end

  defp row(_other), do: []

  defp detail(detail) when is_binary(detail) and detail != "", do: detail
  defp detail(_none), do: nil

  defp icon("hero-" <> _name = icon), do: icon
  defp icon(_other), do: @icon

  defp priority(priority) when is_integer(priority), do: priority
  defp priority(_none), do: @priority

  defmodule Combo do
    @moduledoc """
    The search box of the admin top bar, a LiveComponent `MishkaCmsCore.Layouts.topbar/1` draws with
    `current_user`, `current_site`, `current_path` and `view`.

    Typing asks `MishkaCmsCore.Layouts.TopbarSearch.collect/2` after a pause of 250 ms
    (`phx-debounce`), in a task of the page (`start_async/3`), and lists the groups under the box.
    While the list is open, ArrowDown and ArrowUp move the highlighted row, Enter opens it, Escape
    and a click outside close the list, and a click on a row opens it. Everything is
    `Phoenix.LiveView.JS` and LiveView bindings: the arrow keys are window key bindings drawn only
    while the list is open, so a key pressed while it is closed sends nothing.

    Below 640 px the box is a 44 px search icon (`<id>-phone`) that opens a sheet over the whole
    screen (`<id>-sheet`) with its own input focused and the same groups listed under it, each row at
    least 44 px tall; its back arrow and Escape close it.
    """
    use Phoenix.LiveComponent
    use Gettext, backend: MishkaCmsCore.Gettext

    import MishkaCmsCore.CoreComponents, only: [icon: 1]

    alias MishkaCmsCore.Layouts.TopbarSearch
    alias Phoenix.LiveView.JS

    @impl true
    def mount(socket) do
      new_socket =
        assign(socket,
          query: "",
          groups: [],
          rows: [],
          active: nil,
          open: false,
          placeholder: nil
        )

      {:ok, new_socket}
    end

    @impl true
    def handle_event("search", %{"q" => query}, socket) when is_binary(query) do
      context =
        Map.take(socket.assigns, [:current_user, :current_site, :current_path, :view])

      locale = Gettext.get_locale()

      new_socket =
        socket
        |> assign(query: query)
        |> start_async(:search, fn ->
          Gettext.put_locale(locale)
          {query, TopbarSearch.collect(query, context)}
        end)

      {:noreply, new_socket}
    end

    def handle_event("move", %{"by" => by}, %{assigns: %{rows: [_ | _] = rows}} = socket)
        when by in [-1, 1] do
      active = Integer.mod((socket.assigns.active || 0) + by, length(rows))
      {:noreply, assign(socket, :active, active)}
    end

    def handle_event("open", _params, %{assigns: %{rows: [_ | _] = rows}} = socket) do
      %{link: link} = Enum.at(rows, socket.assigns.active || 0)

      new_socket =
        case navigation_type(socket, link) do
          :href -> redirect(socket, to: link)
          _live -> push_navigate(socket, to: link)
        end

      {:noreply, new_socket}
    end

    def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    @impl true
    def handle_async(:search, {:ok, {query, groups}}, %{assigns: %{query: query}} = socket) do
      rows = Enum.flat_map(groups, & &1.rows)

      new_socket =
        assign(socket,
          groups: groups,
          rows: rows,
          active: if(rows != [], do: 0),
          open: String.trim(query) != ""
        )

      {:noreply, new_socket}
    end

    def handle_async(:search, _stale_or_failed, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      assigns = assign(assigns, :numbered, numbered(assigns.groups))

      ~H"""
      <div
        id={@id}
        phx-click-away={@open && JS.push("close", target: @myself)}
        class="relative min-w-0 flex-1 max-w-[440px] max-[640px]:max-w-none max-[640px]:flex-none"
      >
        <div id={@id <> "-box"} class="relative max-[640px]:hidden!">
          <.icon
            name="hero-magnifying-glass"
            class="absolute start-[13px] top-1/2 size-4 -translate-y-1/2 text-[#a8a5a0]"
          />
          <form
            id={@id <> "-form"}
            role="search"
            autocomplete="off"
            phx-change="search"
            phx-submit="open"
            phx-target={@myself}
          >
            <input
              type="text"
              name="q"
              value={@query}
              phx-debounce="250"
              role="combobox"
              aria-label={gettext("Search")}
              aria-autocomplete="list"
              aria-expanded={to_string(@open)}
              aria-controls={@id <> "-results"}
              aria-activedescendant={@open && is_integer(@active) && row_id(@id, @active)}
              placeholder={@placeholder || gettext("Search pages, posts, people…")}
              class="h-[39px] w-full rounded-[11px] border border-[#ecebe6] bg-[#f7f6f3] ps-[38px] pe-[14px] text-[13px] font-medium text-[#1b1a18] outline-none focus:border-[#8b87ea] focus:shadow-[0_0_0_3px_rgba(109,105,230,.16)]"
            />
          </form>

          <div
            :if={@open}
            id={@id <> "-results"}
            role="listbox"
            class="absolute start-0 top-[46px] z-[60] max-h-[70vh] w-[420px] max-w-[calc(100vw-2rem)] overflow-y-auto rounded-[14px] border border-[#ecebe6] bg-white p-2 shadow-[0_14px_34px_rgba(30,28,24,0.14)]"
          >
            <.results id={@id} numbered={@numbered} groups={@groups} query={@query} active={@active} />
          </div>
        </div>

        <button
          type="button"
          id={@id <> "-phone"}
          aria-label={gettext("Search")}
          aria-controls={@id <> "-sheet"}
          phx-click={open_sheet(@id)}
          class="hidden size-11 items-center justify-center rounded-[11px] border border-[#ecebe6] bg-white text-[#5c5a54] max-[640px]:flex!"
        >
          <.icon name="hero-magnifying-glass" class="size-[18px]" />
        </button>

        <div
          id={@id <> "-sheet"}
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Search")}
          phx-window-keydown={close_sheet(@id, @myself)}
          phx-key="Escape"
          class="fixed inset-0 z-[95] hidden flex-col bg-white"
        >
          <div class="flex items-center gap-2 border-b border-[#ecebe6] px-3 py-2.5">
            <button
              type="button"
              id={@id <> "-sheet-close"}
              aria-label={gettext("Close the search")}
              phx-click={close_sheet(@id, @myself)}
              class="flex size-11 shrink-0 items-center justify-center rounded-[11px] text-[#5c5a54]"
            >
              <.icon name="hero-arrow-left" class="size-5" />
            </button>
            <form
              id={@id <> "-sheet-form"}
              role="search"
              autocomplete="off"
              phx-change="search"
              phx-submit="open"
              phx-target={@myself}
              class="min-w-0 flex-1"
            >
              <input
                type="search"
                id={@id <> "-sheet-input"}
                name="q"
                value={@query}
                phx-debounce="250"
                aria-label={gettext("Search")}
                placeholder={@placeholder || gettext("Search pages, posts, people…")}
                class="h-11 w-full rounded-[11px] border border-[#ecebe6] bg-[#f7f6f3] px-[14px] text-base font-medium text-[#1b1a18] outline-none focus:border-[#8b87ea]"
              />
            </form>
          </div>
          <div id={@id <> "-sheet-results"} role="listbox" class="flex-1 overflow-y-auto p-2">
            <.results
              :if={String.trim(@query) != ""}
              id={@id <> "-sheet"}
              numbered={@numbered}
              groups={@groups}
              query={@query}
              active={nil}
              tall
            />
          </div>
        </div>

        <span
          :if={@open and @rows != []}
          id={@id <> "-down"}
          class="hidden"
          phx-window-keydown={JS.push("move", value: %{by: 1}, target: @myself)}
          phx-key="ArrowDown"
        ></span>
        <span
          :if={@open and @rows != []}
          id={@id <> "-up"}
          class="hidden"
          phx-window-keydown={JS.push("move", value: %{by: -1}, target: @myself)}
          phx-key="ArrowUp"
        ></span>
        <span
          :if={@open}
          id={@id <> "-escape"}
          class="hidden"
          phx-window-keydown={JS.push("close", target: @myself)}
          phx-key="Escape"
        ></span>
      </div>
      """
    end

    # The phone's search: a sheet over the whole screen with its input focused, closed by its back
    # arrow or Escape. `Phoenix.LiveView.JS` only.
    defp open_sheet(id) do
      JS.show(to: "#" <> id <> "-sheet", display: "flex")
      |> JS.focus(to: "#" <> id <> "-sheet-input")
    end

    defp close_sheet(id, myself) do
      JS.hide(to: "#" <> id <> "-sheet")
      |> JS.push("close", target: myself)
    end

    attr :id, :string, required: true
    attr :numbered, :list, required: true
    attr :groups, :list, required: true
    attr :query, :string, required: true
    attr :active, :any, default: nil
    attr :tall, :boolean, default: false

    # The found groups and their rows (the box's list and the phone's sheet draw the same), or the
    # sentence that nothing matched. `tall` makes each row at least 44 px, for a finger.
    defp results(assigns) do
      ~H"""
      <div
        :for={{group, rows} <- @numbered}
        id={@id <> "-group-" <> group.id}
        role="group"
        aria-label={group.label}
      >
        <div class="px-2.5 pb-1 pt-2 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#a8a5a0]">
          {group.label}
        </div>
        <.link
          :for={{row, index} <- rows}
          id={row_id(@id, index)}
          navigate={row.link}
          role="option"
          aria-selected={to_string(index == @active)}
          class={[
            "flex items-center gap-[11px] rounded-[10px] px-2.5 py-2 hover:bg-[#faf9f6]",
            @tall && "min-h-11",
            index == @active && "bg-[#f6f5f2]"
          ]}
        >
          <span class="flex size-[30px] shrink-0 items-center justify-center rounded-[9px] bg-[#f2f1fc] text-[#4f4bcc]">
            <.icon name={row.icon} class="size-[15px]" />
          </span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-[12.5px] font-bold text-[#17161a]">{row.title}</span>
            <span :if={row.detail} class="block truncate text-[11px] font-medium text-[#6f6d68]">
              {row.detail}
            </span>
          </span>
        </.link>
      </div>

      <div :if={@groups == []} id={@id <> "-empty"} class="px-3 py-4 text-center">
        <div class="text-[12.5px] font-bold text-[#17161a]">
          {gettext("Nothing matches “%{query}”", query: String.trim(@query))}
        </div>
        <div class="mt-[3px] text-[11.5px] font-medium text-[#6f6d68]">
          {gettext("Try another word.")}
        </div>
      </div>
      """
    end

    # Each group with its rows numbered across the whole list, the order the arrow keys walk.
    defp numbered(groups) do
      {numbered, _next} =
        Enum.map_reduce(groups, 0, fn group, first ->
          {{group, Enum.with_index(group.rows, first)}, first + length(group.rows)}
        end)

      numbered
    end

    defp row_id(id, index), do: "#{id}-row-#{index}"
  end
end
