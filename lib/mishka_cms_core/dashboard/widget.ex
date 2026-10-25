# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dashboard.Widget do
  @moduledoc """
  Admin dashboard widgets — the whole concern in one module: the validated descriptor every widget
  declares, collecting widgets (core + plugins), filtering them by the viewer's permission, arranging
  them by a per-user layout, and rendering one as a card.

  A widget is a plugin. An extension ships a `MishkaInstaller.Event.Hook` on the `"dashboard:widgets"`
  event whose `call/1` appends a descriptor built with `builder/1`; enabling/disabling and default
  ordering reuse the plugin lifecycle (`priority`, `Event.start`/`Event.stop`). This is the sibling of
  `MishkaCmsCore.Settings`' "register via hook" pattern — except widgets aren't cached, the hook is
  called at mount so an enabled/disabled plugin shows up immediately.

  `component` is a `{module, function}` tuple (a function component, the default) or a LiveComponent
  module with `type: :live_component` — never a closure, so the descriptor passes safely through the
  hook payload (which is plain-map only).

  Two audiences: developers *register* widgets (priority = default order, `size` = default grid
  width, `default_hidden: true` = available-but-off, `config` = the settings the widget lets a user
  change); an admin *arranges and tunes* their own.

  A widget declares its priority twice and they are NOT the same number. The descriptor's `priority`
  is the board order and may be any integer — `collect/1` sorts by it. The plugin's
  `initial: %{priority: n}` is mishka_installer's registration priority, which it validates as
  **1..100**; a plugin declaring more than 100 is rejected outright and its widget never appears.
  Keep them mirrored where the range allows, and clamp the plugin one when it does not.

  Arrangement lives in a `layout` map the page persists per user — drag order (`"order"`),
  hidden/added ids and per-widget width overrides (`"spans"`, read through `span/2`). **Settings do
  not.** Each declared setting is its own per-user row in `MishkaCmsCore.Settings`, keyed by
  `setting_key/2`, written by `set_config/4` and read by `config/3`. That is what lets the owning
  extension register its widgets' settings in ITS OWN settings tab
  (`settings_definitions/1` + a `settings:register` plugin such as
  `MishkaBlog.Dashboard.WidgetSettings`) — a blog widget's "Posts to show" is documented under
  **Blog**, not buried in the dashboard's blob. See
  MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index.

  A `config` entry is a plain map — the descriptor travels through the hook payload, which is
  plain-map only — declaring ONE setting, in one of exactly three types:

      config: [
        %{key: "count", type: :integer, label: "Posts to show", default: 6, min: 1, max: 12},
        %{key: "show_avatars", type: :boolean, label: "Show avatars", default: true},
        %{key: "sort", type: :select, label: "Sort by", default: "recent",
          options: [{"Most recent", "recent"}, {"Most viewed", "viewed"}]}
      ]

  Anything else is skipped rather than raised on, so a descriptor from an extension can never take
  the board down. A widget declaring `config` should also name the settings tab those settings
  belong in — `settings_category: "blog"` — which is a DIFFERENT field from the descriptor's
  `category` (the widget's own grouping label) and falls back to it when unset.

  Widgets share one visual language: `card/1` renders the header (descriptor icon + title + an
  optional "View all" `link`), and widget bodies compose `badge/1`, `stat/1`, `empty/1` and
  `relative_time/1` so every extension's widgets look native. Data follows the tenant contract:
  `load/1` receives the viewing user and derives its scope from `scope/1` — a master (no
  `site_id`) sees every site's data, a tenant admin only its own site's. A widget with settings
  exports `load/2` instead, the same user plus its effective `config/2` map; the dashboard prefers
  `load/2` when it is exported, so a widget without settings keeps `load/1` untouched.
  """
  use GuardedStruct
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext
  require Logger

  import MishkaCmsCore.CoreComponents, only: [select_chevron: 1]

  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Settings
  alias Phoenix.LiveView.JS

  guardedstruct do
    field(:id, String.t(), enforce: true, derives: "sanitize(trim) validate(string, not_empty)")

    field(:title, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty)"
    )

    field(:component, tuple(), enforce: true)
    field(:type, atom(), default: :function)
    field(:size, integer(), default: 1)
    field(:permission, any())
    field(:default_hidden, boolean(), default: false)
    field(:icon, String.t(), default: "hero-squares-2x2")
    field(:description, String.t())
    field(:category, String.t(), default: "general")
    field(:settings_category, String.t())
    field(:link, String.t())
    field(:variant, atom(), default: :card)
    field(:priority, integer(), default: 100)
    field(:pubsub, list(), default: [])
    field(:config, list(), default: [])
  end

  # Ash's `pub_sub` events. A resource publishes "<prefix>:<event>" and, when the record carries a
  # site, also "<prefix>:<site_id>:<event>".
  @events ~w(created updated destroyed)

  # The setting types `config` understands. A declaration of any other type still reports its default
  # through `config/3` (so a widget always sees every key it declared) but is never editable and is
  # never written back — an extension can't smuggle an unvalidated value into a `load/2`.
  @setting_types [:integer, :boolean, :select]

  # The heading every widget setting sits under inside its extension's settings tab.
  @settings_group gettext_noop("Dashboard widgets")

  @doc """
  The viewing user's data scope: `nil` = master (sees every site), a uuid = that tenant's own site
  only. Every widget's `load` derives its queries from this.

  The viewing user is REQUIRED. It used to be optional, and a missing one returned `nil` — the exact
  value a master returns — so every widget's `scope_filter(query, nil)` applied no filter and a
  caller that had lost track of its user quietly read every site's data instead of failing. A master
  is a user whose `site_id` is `nil`, never the absence of a user, and the two must not collapse
  into one value on the way into a query. Anything else raises: on a boundary like this a crash is
  the safe outcome and a silent full-fleet read is not.
  """
  @spec scope(map()) :: String.t() | nil
  def scope(%{site_id: site_id}), do: site_id

  def scope(other) do
    raise ArgumentError,
          "a dashboard widget needs the viewing user to scope its data, got: #{inspect(other)}. " <>
            "A master is a user with site_id: nil, not a missing user."
  end

  @doc """
  The PubSub topics whose broadcasts make this widget's `load/1` stale — the dashboard subscribes to
  them and re-loads just that widget, so a board is live without polling.

  Each `pubsub` entry is an Ash resource (its topics come from its own `pub_sub` prefix), a module
  exposing `topics/1` (an activity `Source`), or a literal topic string. Scoped exactly like `load/1`:
  a master watches the global topics, a tenant admin also watches its own site's. A resource that
  doesn't publish contributes nothing.
  """
  @spec topics(t(), map() | nil) :: [String.t()]
  def topics(%{pubsub: pubsub}, user),
    do: pubsub |> Enum.flat_map(&entry_topics(&1, user)) |> Enum.uniq()

  defp entry_topics(topic, _user) when is_binary(topic), do: [topic]

  defp entry_topics(module, user) when is_atom(module) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :topics, 1) -> module.topics(%{current_user: user})
      publisher?(module) -> resource_topics(Ash.Notifier.PubSub.Info.prefix(module), scope(user))
      true -> []
    end
  end

  defp publisher?(module),
    do:
      Ash.Resource.Info.resource?(module) and
        Ash.Notifier.PubSub in Ash.Resource.Info.notifiers(module)

  # A global row (`site_id` nil) publishes ONLY the bare topic — Ash skips nil topic segments — so a
  # tenant admin has to watch both its site's topics and the global ones to see either.
  defp resource_topics(prefix, nil), do: Enum.map(@events, &"#{prefix}:#{&1}")

  defp resource_topics(prefix, site_id),
    do: for(e <- @events, t <- ["#{prefix}:#{e}", "#{prefix}:#{site_id}:#{e}"], do: t)

  @doc """
  Whether `user` may see this widget — its descriptor's `permission`, which is one name or a list of
  them where holding ANY is enough, checked the same way a setting definition's is
  (`MishkaCmsCore.Settings.permitted?/2`). This is the filter `collect/1` applies, exposed because
  it is also the question the dashboard's own templates ask about a single card.
  """
  @spec permitted?(t(), map() | nil) :: boolean()
  defdelegate permitted?(widget, user), to: Settings

  @doc """
  Widgets the user may see — every plugin registered on the `"dashboard:widgets"` event, sorted by
  each descriptor's `priority` (low → high, `id` as tiebreaker), filtered by permission. A widget
  whose `link` leads to a page the user may not open (`MishkaCmsCore.Sidebar.opens?/2`) comes back
  with no `link`, so its card draws no footer. Returns `[]` when no plugin has registered yet.

  Order is taken from the descriptor's own `priority`, not the plugin's registration order: the
  compiled hook chain is fixed at registration time from the priorities persisted in the event
  registry, so a source-level priority change would not re-order an already-registered plugin. Sorting
  the returned descriptors here keeps the default board order fully deterministic and source-driven.
  """
  @spec collect(map() | nil) :: [t()]
  def collect(user) do
    case MishkaInstaller.Event.Hook.call("dashboard:widgets", %{widgets: []}) do
      %{widgets: widgets} when is_list(widgets) ->
        widgets
        |> Enum.filter(&permitted?(&1, user))
        |> Enum.map(&reachable_link(&1, user))
        |> Enum.sort_by(&{&1.priority, &1.id})

      _ ->
        []
    end
  end

  defp reachable_link(%{link: link} = widget, user) when is_binary(link) do
    if MishkaCmsCore.Sidebar.opens?(user, link), do: widget, else: %{widget | link: nil}
  end

  defp reachable_link(widget, _user), do: widget

  @doc """
  Orders and filters widgets for display. With no layout, widgets keep their registered order and
  `default_hidden` ones are dropped. A `layout` of `%{"order" => [id], "hidden" => [id], "added" =>
  [id]}` (the per-user preference) overrides: `hidden` ids are removed, `added` reveals a
  default-hidden widget, and what remains is sorted by `order` (unknown ids keep their position).
  The layout's `"spans"` key does not affect arrangement — `span/2` reads it for widget width.
  """
  @spec arrange([t()], map()) :: [t()]
  def arrange(widgets, layout \\ %{}) do
    layout = as_map(layout)
    hidden = hidden_ids(widgets, layout)
    order = as_list(Map.get(layout, "order"))

    widgets
    |> Enum.reject(&MapSet.member?(hidden, &1.id))
    |> Enum.sort_by(fn w -> Enum.find_index(order, &(&1 == w.id)) || length(order) end)
  end

  @doc "Permitted widgets the user has NOT placed on the dashboard — the \"add a widget\" choices."
  @spec available([t()], map()) :: [t()]
  def available(widgets, layout \\ %{}) do
    shown = MapSet.new(arrange(widgets, layout), & &1.id)
    Enum.reject(widgets, &MapSet.member?(shown, &1.id))
  end

  @doc "The user's saved dashboard layout (`%{}` when they've never customized)."
  @spec layout(map()) :: map()
  def layout(user), do: Settings.get(layout_key(user), %{})

  @doc "Persists the user's dashboard layout."
  @spec save_layout(map(), map()) :: {:ok, map()} | {:error, term()}
  def save_layout(user, layout), do: Settings.put(layout_key(user), layout)

  @doc "Removes a widget from the dashboard."
  @spec hide(map(), String.t()) :: map()
  def hide(layout, id) do
    layout
    |> Map.update("hidden", [id], &Enum.uniq([id | &1]))
    |> Map.update("added", [], &List.delete(&1, id))
  end

  @doc "Puts a widget back on the dashboard (un-hides it or reveals a default-hidden one)."
  @spec add(map(), String.t()) :: map()
  def add(layout, id) do
    layout
    |> Map.update("hidden", [], &List.delete(&1, id))
    |> Map.update("added", [id], &Enum.uniq([id | &1]))
    |> Map.update("order", [id], &Enum.uniq(&1 ++ [id]))
  end

  @doc "Adds a widget and places it at `index` among the shown widgets (a drop from the library)."
  @spec add_at(map(), [t()], String.t(), non_neg_integer()) :: map()
  def add_at(layout, widgets, id, index) do
    layout = add(layout, id)

    order =
      widgets
      |> arrange(layout)
      |> Enum.map(& &1.id)
      |> List.delete(id)
      |> List.insert_at(index, id)

    Map.put(layout, "order", order)
  end

  @doc "Reorders the dashboard to the dragged id list (the client's DOM order)."
  @spec reorder(map(), [String.t()]) :: map()
  def reorder(layout, ids) when is_list(ids),
    do: Map.put(layout, "order", Enum.filter(ids, &is_binary/1))

  @doc "Sets the user's width override for a widget, in grid columns (of 6): 2=⅓, 3=½, 4=⅔, 6=full."
  @spec set_span(map(), String.t(), pos_integer()) :: map()
  def set_span(layout, id, cols) when cols in 1..6,
    do: Map.update(layout, "spans", %{id => cols}, &Map.put(&1, id, cols))

  @doc "A widget's effective width in grid columns — the user's override or the registered `size`."
  @spec span(t(), map()) :: pos_integer()
  def span(widget, layout) do
    layout
    |> as_map()
    |> Map.get("spans")
    |> as_map()
    |> Map.get(widget.id, widget.size)
    |> as_span(widget.size)
  end

  @doc """
  The `MishkaCmsCore.Settings` key one of a widget's settings is stored under —
  `"dashboard.widget.<widget id>.<setting key>"`. This is the single source of that shape: the
  extension plugin that REGISTERS the definition (`settings_definitions/1`) and the code that reads
  it (`config/3`) both derive the key here, so the two can never drift apart. The key carries no
  user — `MishkaCmsCore.Settings.put_user/3` namespaces it per user on the way in.
  """
  @spec setting_key(t() | String.t(), String.t()) :: String.t()
  def setting_key(%{id: id}, key), do: setting_key(id, key)

  def setting_key(id, key) when is_binary(id) and is_binary(key),
    do: "dashboard.widget.#{id}.#{key}"

  @doc """
  This widget's declared settings as `MishkaCmsCore.Settings` definitions — what an extension's
  `settings:register` plugin appends so each widget's settings are documented in ITS OWN tab
  (`settings_category`, falling back to the descriptor's `category`) under one **Dashboard widgets**
  group, instead of living nowhere near the extension that owns them.

  Every definition is `scope: :user` and `source: :plugin`, and inherits the widget's `permission`,
  so an admin who cannot see the widget never sees its settings either. `:user` settings ARE
  editable on the settings page (it reads and writes them through `Settings.get_user/3` /
  `Settings.put_user/3`) — the very rows the card's gear writes — so the two editors agree. The
  declared `min`/`max` travel with the definition, so a number typed on the settings page is bounded
  by `MishkaCmsCore.Settings.cast/2` exactly as one picked in the card's gear is; `config/3` still
  re-validates on the way out, which is what catches a row left behind by an older declaration.

  A declaration of an unsupported type is skipped, like everywhere else.
  """
  @spec settings_definitions(t()) :: [Settings.definition()]
  def settings_definitions(%{config: settings} = widget) when is_list(settings) do
    settings
    |> Enum.filter(&editable?/1)
    |> Enum.map(&definition(widget, &1))
  end

  def settings_definitions(_widget), do: []

  @doc """
  A widget's effective settings for one viewer, `%{"key" => value}` — every declared setting read
  from its own per-user row (`setting_key/2` through `MishkaCmsCore.Settings.get_user/3`), falling
  back to the value the widget declared. EVERY declared key is present, so a `load/2` never has to
  guess a default, and every value is re-validated on the way out: a row hand-edited from the
  settings page, or one left behind by an older declaration, can't feed a widget something its own
  `config` doesn't allow. A widget that declares nothing — or a caller with no user — gets `%{}`.

  `layout` is the LEGACY per-user dashboard blob (`layout["config"][widget id]`), where these values
  lived before they moved into Settings. It is read-only here and consulted only when the per-user
  row is unset, so an admin who tuned a card before this change keeps seeing their number; the first
  save through the gear (or the settings page) writes the real row and the blob stops mattering.
  Nothing is written back to it, and nothing new is ever written into it.
  """
  @spec config(t(), map() | nil, map()) :: map()
  def config(widget, user, layout \\ %{})

  def config(%{config: settings} = widget, user, layout) when is_list(settings) do
    legacy = legacy_config(widget, layout)

    settings
    |> Enum.filter(&keyed?/1)
    |> Map.new(&{&1.key, resolve(&1, saved(widget, &1, user, legacy))})
  end

  def config(_widget, _user, _layout), do: %{}

  @doc """
  Saves one of a widget's settings FOR THIS USER, validated against the widget's own declaration:
  the posted value is coerced to the declared type — an integer parsed and clamped to `min`/`max`, a
  boolean, one of a select's declared options — and only then written to that setting's own per-user
  row (`setting_key/2` through `MishkaCmsCore.Settings.put_user/3`, which namespaces the key with
  the user's id, so two admins can never see each other's value). A key the widget never declared, a
  type outside the supported three, or a value that can't be coerced writes nothing at all. This is
  the boundary: nothing reaches a widget's `load/2` that its own declaration didn't describe.

  Returns `{:ok, stored_value}`, or `:error` for anything refused and for a write that failed.
  """
  @spec set_config(map(), t(), String.t(), term()) :: {:ok, term()} | :error
  def set_config(%{id: user_id}, widget, key, value) when not is_nil(user_id) do
    with %{} = setting <- declared(widget, key),
         {:ok, coerced} <- cast(setting, value),
         {:ok, _stored} <- Settings.put_user(setting_key(widget, key), coerced, user_id) do
      {:ok, coerced}
    else
      _refused -> :error
    end
  end

  def set_config(_user, _widget, _key, _value), do: :error

  @doc """
  Puts every one of a widget's settings back to the value it declared, for this user — what the
  dashboard's "Reset" does to settings now that they outlive the layout blob it clears. Writes each
  default through `set_config/4`, so a default is coerced and bounded like any other value.
  """
  @spec reset_config(map(), t()) :: :ok
  def reset_config(user, %{config: settings} = widget) when is_list(settings) do
    settings
    |> Enum.filter(&editable?/1)
    |> Enum.each(&set_config(user, widget, &1.key, Map.get(&1, :default)))
  end

  def reset_config(_user, _widget), do: :ok

  @doc """
  Tailwind `col-span-*` for the 6-column dashboard grid; collapses to full width under 980px.

  WHOLE CLASS NAMES, one clause per width. Written as `"col-span-\#{n} …"` the span was invisible to
  Tailwind's scanner, and every rule it happened to have came from some unrelated file that spells
  the same class out — so the dashboard's column widths were held up by coincidence. `mix admin_css`
  compiles the admin from source text now; a class assembled at render time has nothing to find.
  """
  @spec col_span_class(pos_integer()) :: String.t()
  def col_span_class(3), do: "col-span-3 max-[980px]:col-span-1!"
  def col_span_class(4), do: "col-span-4 max-[980px]:col-span-1!"
  def col_span_class(5), do: "col-span-5 max-[980px]:col-span-1!"
  def col_span_class(6), do: "col-span-6 max-[980px]:col-span-1!"
  def col_span_class(_n), do: "col-span-2 max-[980px]:col-span-1!"

  @doc """
  Renders one widget as a card from its async `state` — `:loading` (a skeleton), `{:error, _}` (a
  placeholder), or `{:ok, data}` (the widget's `render/1` fed the loaded `data`). The dashboard loads
  each widget's data off the render (a Task per widget), so no widget blocks first paint; a widget
  whose LOAD fails degrades to the placeholder instead of taking the board with it.

  A widget whose RENDER raises is not contained here, and `render_loaded/2` says why.
  """
  def card(%{widget: %{variant: :panel}} = assigns) do
    ~H"""
    <div class="relative h-full">
      <div
        :if={assigns[:customize?]}
        class="absolute end-3 top-3 z-10 flex items-center gap-2 rounded-[10px] bg-black/40 px-2 py-1 backdrop-blur"
      >
        <span
          data-drag-handle
          title={gettext("Drag to move")}
          class="grid cursor-grab touch-none select-none grid-cols-2 gap-0.5 active:cursor-grabbing"
        >
          <span :for={_ <- 1..4} class="size-[3px] rounded-full bg-[#6b6971]" />
        </span>
        <.span_control id={@widget.id} span={assigns[:span]} />
        <.config_control
          id={@widget.id}
          settings={@widget.config}
          values={assigns[:config] || %{}}
        />
        <button
          type="button"
          phx-click="hide"
          phx-value-id={@widget.id}
          class="shrink-0 text-xs font-semibold text-[#ff8f86]"
        >
          {gettext("Hide")}
        </button>
      </div>
      <%= case @state do %>
        <% {:ok, data} -> %>
          {render_loaded(@widget, assign(assigns, :data, data))}
        <% {:error, _} -> %>
          <div class="rounded-[18px] bg-[#17161a] p-6 text-sm text-[#ff8f86]">
            {gettext("This widget could not load.")}
          </div>
        <% _ -> %>
          <div class="h-28 animate-pulse rounded-[18px] bg-[#1f1e22]"></div>
      <% end %>
    </div>
    """
  end

  def card(assigns) do
    ~H"""
    <section class="flex h-full flex-col rounded-[18px] border border-[#ecebe6] bg-white p-5 shadow-[0_1px_2px_rgba(30,28,24,0.04)]">
      <div
        :if={assigns[:customize?]}
        class="mb-3.5 flex items-center justify-between gap-2 rounded-[10px] border border-[#ecebe6] bg-[#f6f5f2] px-[9px] py-1.5"
      >
        <span
          data-drag-handle
          title={gettext("Drag to move")}
          class="grid cursor-grab touch-none select-none grid-cols-2 gap-0.5 active:cursor-grabbing"
        >
          <span :for={_ <- 1..4} class="size-[3px] rounded-full bg-[#bcb9b2]" />
        </span>
        <.span_control id={@widget.id} span={assigns[:span]} />
        <.config_control
          id={@widget.id}
          settings={@widget.config}
          values={assigns[:config] || %{}}
        />
        <button
          type="button"
          phx-click="hide"
          phx-value-id={@widget.id}
          class="shrink-0 text-xs font-semibold text-[#d5544b] hover:text-[#b3433a]"
        >
          {gettext("Hide")}
        </button>
      </div>
      <div class="flex min-h-0 flex-1 flex-col">
        <%= case @state do %>
          <% {:ok, data} -> %>
            {render_loaded(@widget, assign(assigns, :data, data))}
          <% {:error, _} -> %>
            <p class="text-sm text-[#d5544b]">{gettext("This widget could not load.")}</p>
          <% _ -> %>
            <div class="mb-4 flex items-center gap-2.5">
              <span class="size-8 shrink-0 animate-pulse rounded-[9px] bg-[#f2f1ec]" />
              <span class="h-4 w-28 animate-pulse rounded bg-[#f2f1ec]" />
            </div>
            <div class="h-24 animate-pulse rounded-xl bg-[#faf9f6]"></div>
        <% end %>
      </div>
    </section>
    """
  end

  @doc """
  The per-widget width picker shown in customize mode — sets the card's grid width to a third, two
  thirds, or the full row (2/4/6 of the 6-column grid) via `set_span`. The active width is highlighted
  from the widget's current `span`.
  """
  attr(:id, :string, required: true)
  attr(:span, :integer, default: nil)

  def span_control(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-0.5 rounded-[7px] bg-[#e6e4de] p-0.5">
      <button
        :for={{label, cols} <- [{"1/3", 2}, {"2/3", 4}, {"3/3", 6}]}
        type="button"
        phx-click="set_span"
        phx-value-id={@id}
        phx-value-span={cols}
        title={gettext("Set width to %{width}", width: label)}
        class={[
          "min-w-[19px] rounded-[5px] px-1 py-[3px] text-center text-[10px] font-bold leading-none transition",
          (@span == cols && "bg-white text-[#4f4bcc] shadow-[0_1px_2px_rgba(30,28,24,0.12)]") ||
            "text-[#8a877f] hover:text-[#4f4bcc]"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  @doc """
  The per-widget settings dropdown shown in customize mode beside `span_control/1` — a gear that
  opens a panel of the widget's declared `config`, one input per setting. Nothing renders for a
  widget that declares none, or for a declaration of an unsupported type.

  Opening is pure client state (`JS.toggle`, dismissed by a click away): whether a dropdown is open
  is not worth a round trip. The panel carries `phx-update="ignore"` so it belongs to the client
  once rendered — re-rendering the card (which every change does, the widget re-loads) would
  otherwise strip the toggled `display` back off and shut the panel mid-edit.

  Each change posts `save_widget_config` with the widget id, which the page re-validates through
  `set_config/4` before re-running just that widget's load.

  A number field is bounded on the client by `NumberBounds` as well as on the server, because an
  ignored element is never patched: a value the server clamps would otherwise stay on screen for the
  rest of the session while the card showed the clamped one.
  """
  attr(:id, :string, required: true)
  attr(:settings, :list, required: true)
  attr(:values, :map, default: %{})

  def config_control(assigns) do
    assigns =
      assigns
      |> assign(:panel_id, "#{assigns.id}-config")
      |> assign(:settings, assigns.settings |> List.wrap() |> Enum.filter(&editable?/1))

    ~H"""
    <div
      :if={@settings != []}
      id={"#{@id}-config-menu"}
      class="relative shrink-0"
      phx-click-away={JS.hide(to: "##{@panel_id}")}
    >
      <button
        type="button"
        phx-click={JS.toggle(to: "##{@panel_id}")}
        aria-controls={@panel_id}
        title={gettext("Widget settings")}
        class="grid size-[22px] place-items-center rounded-[7px] bg-[#e6e4de] text-[#6d6a63] transition hover:text-[#4f4bcc]"
      >
        <span class="hero-cog-6-tooth size-[13px]" />
      </button>
      <%!-- `phx-submit` is not a second way to save — every change already saves. It is here because
            a form without one lets Enter fall through to a native submit, which navigates the whole
            dashboard away; binding it keeps the keystroke on the panel. --%>
      <form
        id={@panel_id}
        phx-update="ignore"
        phx-change="save_widget_config"
        phx-submit="save_widget_config"
        phx-value-id={@id}
        class="absolute end-0 top-[calc(100%+7px)] z-[60] hidden w-[214px] space-y-3 rounded-[14px] border border-[#e4e2f7] bg-white p-4 text-start shadow-[0_18px_44px_rgba(30,28,24,0.16)]"
      >
        <.config_field
          :for={setting <- @settings}
          setting={setting}
          value={Map.get(@values, setting.key)}
          panel_id={@panel_id}
        />
      </form>
    </div>
    """
  end

  defp config_field(%{setting: %{type: :boolean}} = assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center justify-between gap-3">
      <span class="text-[10px] font-bold uppercase tracking-[0.07em] text-[#8a877f]">
        {Settings.text(setting_label(@setting))}
      </span>
      <input type="hidden" name={@setting.key} value="false" />
      <input
        type="checkbox"
        name={@setting.key}
        value="true"
        checked={@value == true}
        class="size-[15px] shrink-0 rounded-[5px] border border-[#ecebe6] accent-[#4f4bcc]"
      />
    </label>
    """
  end

  defp config_field(%{setting: %{type: :select}} = assigns) do
    assigns = assign(assigns, :options, options(assigns.setting))

    ~H"""
    <label class="block">
      <span class="mb-1.5 block text-[10px] font-bold uppercase tracking-[0.07em] text-[#8a877f]">
        {Settings.text(setting_label(@setting))}
      </span>
      <span class="relative block">
        <select
          name={@setting.key}
          class="h-9 w-full cursor-pointer appearance-none rounded-[9px] border border-[#ecebe6] bg-white ps-2.5 pe-8 text-[12.5px] font-semibold text-[#3a382f]"
        >
          <option
            :for={{label, value} <- @options}
            value={value}
            selected={to_string(value) == to_string(@value)}
          >
            {option_label(label)}
          </option>
        </select>
        <.select_chevron />
      </span>
    </label>
    """
  end

  defp config_field(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1.5 block text-[10px] font-bold uppercase tracking-[0.07em] text-[#8a877f]">
        {Settings.text(setting_label(@setting))}
      </span>
      <input
        type="number"
        dir="ltr"
        id={"#{@panel_id}-#{@setting.key}"}
        name={@setting.key}
        value={@value}
        min={Map.get(@setting, :min)}
        max={Map.get(@setting, :max)}
        phx-debounce="200"
        phx-hook="NumberBounds"
        class="h-9 w-full rounded-[9px] border border-[#ecebe6] bg-white px-2.5 text-[12.5px] font-semibold text-[#3a382f]"
      />
    </label>
    """
  end

  @doc """
  A widget card header — the tinted icon chip + title (+ optional subtitle) on the left, and an
  optional `:right` slot (a status pill/badge). `tone` colours the chip: `:violet`, `:green`,
  `:gray`, `:amber`, `:red`, `:blue`.
  """
  attr(:icon, :string, required: true)
  attr(:tone, :atom, default: :gray)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  slot(:right)

  def card_header(assigns) do
    ~H"""
    <div class="mb-[18px] flex items-center justify-between gap-3">
      <div class="flex min-w-0 items-center gap-[11px]">
        <span class={["grid size-8 shrink-0 place-items-center rounded-[9px]", chip_tone(@tone)]}>
          <span class={[@icon, "size-4"]} />
        </span>
        <div class="min-w-0">
          <div class="truncate text-[14.5px] font-semibold text-[#1b1a18]">{@title}</div>
          <div :if={@subtitle} class="mt-px text-[11.5px] font-medium text-[#a8a5a0]">
            {@subtitle}
          </div>
        </div>
      </div>
      <div :if={@right != []} class="shrink-0">{render_slot(@right)}</div>
    </div>
    """
  end

  @doc """
  The card footer — a bottom-right "{label} →" link, drawn only when there is a `link` to follow
  (`collect/1` clears one the viewer may not open). `border: true` adds the rule above it, set off
  from the body by a 16px margin (React's spacing); without it the link just clears the body by 14px.
  Spacing is explicit, not `mt-auto`: the board grid is `items-start`, so a card is only ever as tall
  as its content and there is no free space for `auto` to push against.
  """
  attr(:link, :string, default: nil)
  attr(:label, :string, default: nil)
  attr(:border, :boolean, default: false)

  def card_footer(assigns) do
    ~H"""
    <div
      :if={@link}
      class={[
        "flex justify-end",
        (@border && "mt-4 border-t border-[#f4f3ef] pt-3") || "pt-3.5"
      ]}
    >
      <.link
        navigate={@link}
        class="text-xs font-semibold text-[#a8a5a0] transition hover:text-[#5c5a54]"
      >
        {@label || gettext("View all")} →
      </.link>
    </div>
    """
  end

  @doc "A status pill for card headers — tinted bg + colour, optional pulsing live dot."
  attr(:label, :string, required: true)
  attr(:tone, :atom, default: :gray)
  attr(:dot, :boolean, default: false)

  def pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-[5px] text-[11px] font-semibold",
      pill_tone(@tone)
    ]}>
      <span
        :if={@dot}
        class={["size-[7px] shrink-0 animate-pulse rounded-full", dot_tone(@tone)]}
      />
      {@label}
    </span>
    """
  end

  @doc """
  A small tonal badge for statuses and actions. Tones are the activity feed's `badge_tone` atoms
  (`:emerald`, `:sky`, `:amber`, `:rose`, `:indigo`, `:violet`, anything else = slate).
  """
  attr(:label, :string, required: true)
  attr(:tone, :atom, default: :slate)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center rounded-[5px] px-[7px] py-0.5 text-[9.5px] font-bold uppercase tracking-[0.04em]",
      pill_tone(@tone)
    ]}>
      {@label}
    </span>
    """
  end

  @doc "A stat tile — icon + label over a large tabular number."
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:icon, :string, default: nil)
  attr(:tone, :atom, default: :slate)

  def stat(assigns) do
    ~H"""
    <div class="rounded-xl border border-[#f0efea] bg-[#faf9f6] p-3">
      <div class="flex items-center gap-1.5 text-[11px] font-semibold text-[#5c5a54]">
        <span :if={@icon} class={[@icon, "size-3.5 shrink-0", stat_tone(@tone)]} />
        <p class="truncate">{@label}</p>
      </div>
      <p class="mt-1 font-['Space_Grotesk'] text-[22px] font-semibold text-[#17161a]">
        {shown(@value)}
      </p>
    </div>
    """
  end

  defp shown(value) when is_number(value), do: Localized.number(value)
  defp shown(value), do: value

  @doc "A consistent empty state for list widgets."
  attr(:icon, :string, default: "hero-inbox")
  attr(:message, :string, required: true)

  def empty(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-1.5 py-6 text-center">
      <span class={[@icon, "size-6 text-[#d5d2c9]"]} />
      <p class="text-sm text-[#a8a5a0]">{@message}</p>
    </div>
    """
  end

  @doc ~S(Compact "how long ago" label for feed rows, in the reader's language — "now", "12m ago", "3h ago", then the day, "Jul 3".)
  @spec relative_time(DateTime.t() | term()) :: String.t()
  def relative_time(%DateTime{} = at) do
    if DateTime.diff(DateTime.utc_now(), at, :second) < 86_400,
      do: Localized.ago(at, format: :narrow),
      else: Localized.date(at, :MMMd)
  end

  def relative_time(_at), do: ""

  # This catches only what a widget's `render/1` raises EAGERLY — a bad match in its head, work above
  # the `~H`. It is not an error boundary. `~H` returns a `%Phoenix.LiveView.Rendered{}` whose `:for`
  # bodies and `{...}` interpolations are closures `Phoenix.LiveView.Diff` runs later, long after this
  # `rescue` has gone out of scope, in the LiveView process — where a raise kills the page and the
  # client reconnects straight back into it. LiveView offers nothing that would contain that, so what
  # keeps a widget safe is the shape of the data it is handed, not this.
  defp render_loaded(widget, assigns) do
    {module, function} = widget.component
    apply(module, function, [assigns])
  rescue
    error ->
      Logger.error("dashboard widget #{widget.id} failed: #{Exception.message(error)}")

      Phoenix.HTML.raw([
        ~s(<p class="text-sm text-red-500">),
        gettext("This widget could not load.")
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string(),
        "</p>"
      ])
  end

  # React light-theme tones. Both the old activity-feed names (:emerald/:sky/:rose/:indigo/:slate)
  # and the redesign names (:green/:blue/:red/:violet/:gray) resolve, so widgets need no churn.
  defp chip_tone(t) when t in [:green, :emerald], do: "bg-[#e6f6ee] text-[#1f9d6b]"
  defp chip_tone(t) when t in [:violet, :indigo], do: "bg-[#eeedfb] text-[#5b57d6]"
  defp chip_tone(:amber), do: "bg-[#fbf1df] text-[#cf8a24]"
  defp chip_tone(t) when t in [:red, :rose], do: "bg-[#fbe9e7] text-[#d5544b]"
  defp chip_tone(t) when t in [:blue, :sky], do: "bg-[#e9effb] text-[#3b6fd4]"
  defp chip_tone(_), do: "bg-[#f2f1ec] text-[#6d6a63]"

  defp pill_tone(t) when t in [:green, :emerald], do: "bg-[#e6f6ee] text-[#1f9d6b]"
  defp pill_tone(t) when t in [:violet, :indigo], do: "bg-[#eeedfb] text-[#5b57d6]"
  defp pill_tone(:amber), do: "bg-[#fbf1df] text-[#a5691a]"
  defp pill_tone(t) when t in [:red, :rose], do: "bg-[#fbe9e7] text-[#b3433a]"
  defp pill_tone(t) when t in [:blue, :sky], do: "bg-[#e9effb] text-[#3b6fd4]"
  defp pill_tone(_), do: "bg-[#f2f1ec] text-[#8a877f]"

  defp dot_tone(t) when t in [:green, :emerald], do: "bg-[#1f9d6b]"
  defp dot_tone(t) when t in [:violet, :indigo], do: "bg-[#5b57d6]"
  defp dot_tone(:amber), do: "bg-[#cf8a24]"
  defp dot_tone(t) when t in [:red, :rose], do: "bg-[#d5544b]"
  defp dot_tone(t) when t in [:blue, :sky], do: "bg-[#3b6fd4]"
  defp dot_tone(_), do: "bg-[#8a877f]"

  defp stat_tone(t) when t in [:green, :emerald], do: "text-[#1f9d6b]"
  defp stat_tone(t) when t in [:violet, :indigo], do: "text-[#5b57d6]"
  defp stat_tone(:amber), do: "text-[#cf8a24]"
  defp stat_tone(t) when t in [:red, :rose], do: "text-[#d5544b]"
  defp stat_tone(t) when t in [:blue, :sky], do: "text-[#3b6fd4]"
  defp stat_tone(_), do: "text-[#a8a5a0]"

  defp declared(%{config: settings}, key) when is_list(settings),
    do: Enum.find(settings, &(keyed?(&1) and &1.key == key))

  defp declared(_widget, _key), do: nil

  defp keyed?(%{key: key}) when is_binary(key), do: true
  defp keyed?(_setting), do: false

  defp editable?(%{type: type} = setting), do: keyed?(setting) and type in @setting_types
  defp editable?(_setting), do: false

  defp definition(widget, setting) do
    Settings.define(setting_key(widget, setting.key), setting.type,
      default: Map.get(setting, :default),
      category: settings_category(widget),
      group: @settings_group,
      scope: :user,
      source: :plugin,
      permission: Map.get(widget, :permission),
      options: Enum.map(options(setting), fn {_label, value} -> value end),
      min: Map.get(setting, :min),
      max: Map.get(setting, :max),
      label:
        {gettext_noop("%{widget} — %{setting}"),
         widget: widget.title, setting: setting_label(setting)},
      description: setting_description(widget, setting)
    )
  end

  defp settings_category(%{settings_category: category}) when is_binary(category), do: category
  defp settings_category(%{category: category}) when is_binary(category), do: category
  defp settings_category(_widget), do: "general"

  defp setting_description(widget, setting) do
    Map.get(setting, :description) ||
      {gettext_noop(
         "Only you see this. Also editable from the %{widget} card's gear on the dashboard."
       ), widget: widget.title}
  end

  # The per-user row first; the pre-Settings layout blob only as its fallback (see `config/3`).
  defp saved(widget, setting, user, legacy) do
    with :error <- stored(widget, setting, user), do: Map.fetch(legacy, setting.key)
  end

  defp stored(widget, setting, %{id: user_id}) when not is_nil(user_id) do
    widget
    |> setting_key(setting.key)
    |> Settings.get_user(user_id, :__unset__)
    |> fetched()
  end

  defp stored(_widget, _setting, _user), do: :error

  defp fetched(:__unset__), do: :error
  defp fetched(value), do: {:ok, value}

  defp legacy_config(%{id: id}, layout),
    do: layout |> as_map() |> Map.get("config") |> as_map() |> Map.get(id) |> as_map()

  defp resolve(setting, {:ok, value}) do
    case cast(setting, value) do
      {:ok, coerced} -> coerced
      :error -> declared_default(setting)
    end
  end

  defp resolve(setting, :error), do: declared_default(setting)

  # The declared default goes through the same coercion, so a `default: "8"` or a default outside its
  # own min/max still hands the widget a usable value; an unsupported type falls back to the literal.
  defp declared_default(setting) do
    case cast(setting, Map.get(setting, :default)) do
      {:ok, coerced} -> coerced
      :error -> Map.get(setting, :default)
    end
  end

  defp cast(setting, value), do: Settings.cast(setting, value)

  defp options(%{options: options}) when is_list(options),
    do: Enum.filter(options, &match?({_label, _value}, &1))

  defp options(_setting), do: []

  defp setting_label(setting), do: Map.get(setting, :label) || setting.key

  defp option_label(label) when is_binary(label), do: Settings.text(label)
  defp option_label(label), do: label

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  # The layout blob is a per-user preference row, not a validated document: an extension writing it
  # wrong, or a half-finished migration, leaves whatever it leaves. Every read of it goes through one
  # of these, because the readers below are `++`, `in` and `Enum.find_index/2` — all of which raise on
  # a non-list, and all of which run inside `Home.Index.mount/3`, where a raise is not a broken widget
  # but a 500 on the whole dashboard with nothing rendered at all.
  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []

  # `min/2` and `max/2` compare ANY two terms, so a non-number span did not raise — it quietly won.
  # Every number sorts below every binary, so `min("banana", 6)` is 6 and the card silently took the
  # full row. A width that is not a number is not a width; the widget's declared size stands.
  defp as_span(value, _default) when is_integer(value), do: value |> min(6) |> max(1)
  defp as_span(_value, default), do: default |> min(6) |> max(1)

  defp hidden_ids(widgets, layout) do
    added = as_list(Map.get(layout, "added"))
    defaults_off = for w <- widgets, w.default_hidden, w.id not in added, do: w.id
    MapSet.new(as_list(Map.get(layout, "hidden")) ++ defaults_off)
  end

  defp layout_key(user), do: "dashboard.layout.#{user.id}"
end
