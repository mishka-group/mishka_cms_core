# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Sidebar do
  @moduledoc """
  The admin sidebar as data — collected from plugins at runtime, filtered by what the viewer may
  see, and ordered by what the admin arranged.

  The nav used to be a hardcoded literal in `MishkaCmsCore.Layouts`: every extension's links were
  spelled out in the core, and every admin who reached the console saw all of them, including
  `/admin/dashboard/account/permissions`. This module replaces both halves. An extension declares
  its own menu and who may see it; nothing in the core names the extension.

  ## The event

  `"sidebar:menus"`, a `MishkaInstaller.Event.Hook` — the sibling of `"dashboard:widgets"`. The
  payload is `%{groups: [Group.t()], items: [Item.t()]}` and every plugin appends to either list:

      defmodule MishkaBlogWeb.SidebarMenu do
        use MishkaInstaller.Event.Hook, event: "sidebar:menus", initial: %{priority: 40}

        use Gettext, backend: MishkaCmsCore.Gettext

        @items [
          MishkaCmsCore.Sidebar.Item.new!(%{
            key: "blog",
            label: gettext_noop("Blog"),
            icon: "hero-book-open",
            path: "/admin/dashboard/blog",
            module: MishkaBlogWeb.Live.Admin.Dashboard.Home.Index,
            group: "plugins",
            order: 10,
            permissions: [
              "admin:dashboard:blog:post",
              "admin:dashboard:blog:comment"
            ],
            credit_name: "Mishka Blog",
            credit_url: "https://mishka.tools/cms/extensions/blog"
          })
        ]

        @impl true
        def call(%{items: items} = data), do: {:reply, %{data | items: items ++ @items}}
      end

  A `label` is marked with `gettext_noop/1` and translated when the sidebar is drawn, in the language
  its admin reads the dashboard in: a descriptor is built at compile time, when nobody's language is
  known yet.

  Groups and items are two flat lists rather than a nested tree so that a group and its contents can
  come from different extensions — Blog and Documents each contribute one item to the **Plugins**
  group the core declares, without either knowing about the other.

  Unlike widgets, the payload is seeded with `core_menu/0` instead of an empty list. A widget board
  with no plugins registered is merely empty; a nav with no plugins registered is a console you
  cannot navigate — so Home, Runtime, Account and Settings are always present, whether or not
  mishka_installer has finished starting. `Enum.uniq_by/2` keeps the FIRST declaration of a key, so
  a plugin can add sections but never silently redefine a core one.

  ## Permissions

  `permissions` on an item is a list where holding ANY entry grants; `menu/1` compares it against
  the viewer and drops the link when nothing matches. Nothing here reads a URL: the question is
  "may this user see this link", and the answer needs the user and the item, nothing else.

  An entry names the area its data asks for, as a plain string:

    * a screen of one area — Sites, Users, Permissions, Activity, an extension's section — lists
      that area's name: `["admin:dashboard:runtime:site"]`;
    * a content list every dashboard admin may read — Pages, Layouts, Components, Error Pages,
      Stylesheets, JS Hooks, Media, Translations — lists its area and `{:under, "admin:dashboard"}`;
    * the builder lists every name that opens a builder — the page, layout, component and error
      page areas and `admin:dashboard:code` — and the builder asks for the type it opens on;
    * Home, Notifications, Settings and the Plugins section list `{:under, "admin:dashboard"}`.

  An API admin holds nothing under `admin:dashboard`, so it sees no entry and opens no page.

  **This hides links; it does not guard pages.** A hidden link is still reachable by typing its URL.
  Guarding the page is the page's own job — its LiveView declares who may open it — because that is
  a server-side check on a known module rather than a string the client controls.

  ## Arrangement

  Each group and item exposes two settings, registered by `MishkaCmsCore.Sidebar.MenuSettings`:

    * `sidebar.<key>.order` — an integer; overrides the declared `order`
    * `sidebar.<key>.visible` — a boolean; `false` hides the entry from everyone

  Both are `scope: :both`, so a global default can be overridden per site: one CMS can put Blog
  above Runtime for one tenant without touching another. Values are read through
  `MishkaCmsCore.Settings.get/3` (RAM cache), and a non-integer order or non-boolean visibility is
  ignored in favour of the declaration rather than crashing the chrome.

  ## Open pages

  `changed/1` tells this node's open admin LiveViews that the entries' settings changed, and
  `MishkaCmsCore.Layouts.Nav` redraws their sidebar. `MishkaCmsCore.Runtime.States.SettingsState`
  calls it after it holds a `sidebar.*` value or an extension's `<app>.active` switch
  (`MishkaCmsCore.Install.Extensions.active?/2`), so a view that reads the menu again reads the new
  value. A site's change reaches the viewers whose menu reads that site, and the global one reaches
  every viewer.

  Event: `runtime:state:sidebar:changed` — `%{key: site_id}`, `nil` for the global value.

  Like the widget board, nothing here is cached: the hook is called at each mount so enabling or
  disabling a plugin shows up immediately. Everything else is compile-time data and ETS reads, and
  the viewer's permissions are loaded once per mount rather than once per item.

  ## What is in this file

  The whole concern, in one place: `Group` and `Item`, the two descriptors a plugin declares. They
  are small, they are useless apart, and reading the contract next to the code that applies it is
  the point.

  The order is load-bearing: both come FIRST because `@core_groups`/`@core_items` call their
  `new!/1` at compile time — a descriptor is built once when this module is compiled, not on every
  admin mount. The settings registrar stays in its own file (`MishkaCmsCore.Sidebar.MenuSettings`)
  because it is a supervised plugin, like its widget twin.
  """

  defmodule Group do
    @moduledoc """
    A collapsible section of the admin sidebar — the heading a set of `MishkaCmsCore.Sidebar.Item`
    links sit under, and the unit an admin collapses, reorders or hides.

    A group carries no path of its own: it exists only to hold items, and
    `MishkaCmsCore.Sidebar.menu/1` drops it entirely once permission filtering leaves it with none.
    `items` is filled in by `menu/1`, not by the plugin that declares the group — an extension
    contributes items with `group: "<key>"` and never has to know which other extension owns the
    section, so several extensions can share one heading (that is how Blog and Documents both land
    under **Plugins**).

    `key` is the identity: the DOM id of the collapse target, the settings key prefix
    (`sidebar.<key>.order`), and what `Sidebar.collect/0` de-duplicates on. Keep it stable — renaming
    it orphans an admin's saved order.

    `permissions` is a list where holding ANY grants — a name, or `{:under, prefix}` for anyone
    holding anything under `prefix` (`MishkaCmsCore.Accounts.Checks.AccessPermissions`); `[]` means
    "any signed-in admin". `position` is
    `:main` (the scrolling nav) or `:footer` (pinned above the sidebar's bottom edge, where Settings
    lives).

    See `MishkaCmsCore.Sidebar` for the event contract and `MishkaCmsCore.Sidebar.Item`.
    """
    use GuardedStruct

    guardedstruct do
      field(:key, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
      field(:label, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
      field(:icon, :string, default: "hero-squares-2x2")
      field(:order, :integer, default: 100)
      field(:permissions, list(), default: [])
      field(:position, :atom, default: :main)
      field(:items, list(), default: [])
    end

    @doc """
    Builds a group, raising on an invalid declaration.

    Menus are declared in module attributes so a descriptor is built once at compile time rather than
    on every admin mount; that also means a malformed group fails the build instead of a page render.
    """
    @spec new!(map()) :: t()
    def new!(attrs) do
      case builder(attrs) do
        {:ok, group} -> group
        error -> raise ArgumentError, "invalid sidebar group #{inspect(attrs)}: #{inspect(error)}"
      end
    end
  end

  defmodule Item do
    @moduledoc """
    One link in the admin sidebar.

    `path` is absolute (`/admin/dashboard/blog`) because that is what the browser navigates to —
    extension route tuples are scope-relative, so a menu item spells the prefix out.

    `permissions` decides who SEES this link: holding ANY entry grants — a name, or
    `{:under, prefix}` for anyone holding anything under `prefix` — and `[]` means "any signed-in
    admin". It does not decide who may open the page — the LiveView behind the link declares that
    for itself.

    `group` names the `MishkaCmsCore.Sidebar.Group` this link belongs under, or `nil` for a top-level
    link such as Home. `position` is `:main` or `:footer`.

    `module` is the LiveView this entry gates — the module Phoenix mounted, which is how
    `MishkaCmsCore.Sidebar.PageGuard` finds an entry. It is deliberately not the `path`: a path is a
    string the client spells, a module is what the router already resolved.

    `nav: false` declares a PAGE that is not a link. An extension usually shows one entry but owns
    many pages — the blog shows "Blog" and owns nine — and those pages do not share one answer to
    "who may open this": Comments is `admin:dashboard:blog:comment`, Posts is
    `admin:dashboard:blog:post`. Declaring each page
    here, hidden from the nav, is what lets them be gated apart while the sidebar still renders the
    single link it renders today.

    See `MishkaCmsCore.Sidebar` for the event contract.
    """
    use GuardedStruct

    guardedstruct do
      field(:key, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
      field(:label, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
      field(:path, :string, enforce: true, derives: "sanitize(trim) validate(string, not_empty)")
      field(:icon, :string, default: "hero-squares-2x2")
      field(:group, :string)
      field(:order, :integer, default: 100)
      field(:permissions, list(), default: [])
      field(:position, :atom, default: :main)
      field(:nav, :boolean, default: true)
      field(:module, :atom)
      # WHICH EXTENSION OWNS THIS ENTRY, for the switch a site has over it — see
      # `MishkaCmsCore.Install.Extensions.active?/2`. Core's own items leave it blank and are never
      # switchable; an extension naming its OTP app here is asking to be hideable, and nothing in
      # this module ever names one back.
      field(:extension, :atom)

      # WHO THE EXTENSION IS AND WHERE ITS OWN PAGE IS, for the "Powered by" line under every page it
      # owns — see `MishkaCmsCore.Sidebar.credit/1`. Both declared once, on one of the extension's
      # entries; an entry that names only one of them credits nobody.
      field(:credit_name, :string)
      field(:credit_url, :string)
    end

    @doc """
    Builds an item, raising on an invalid declaration.

    Menus are declared in module attributes so a descriptor is built once at compile time rather than
    on every admin mount; that also means a malformed item fails the build instead of a page render.
    """
    @spec new!(map()) :: t()
    def new!(attrs) do
      case builder(attrs) do
        {:ok, item} -> item
        error -> raise ArgumentError, "invalid sidebar item #{inspect(attrs)}: #{inspect(error)}"
      end
    end
  end

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  use Gettext, backend: MishkaCmsCore.Gettext

  @event "sidebar:menus"
  @pubsub MishkaCmsCore.PubSub

  @core_groups Enum.map(
                 [
                   %{
                     key: "runtime",
                     label: gettext_noop("Runtime"),
                     icon: "hero-folder",
                     order: 20,
                     permissions: [{:under, "admin:dashboard"}]
                   },
                   %{
                     key: "account",
                     label: gettext_noop("Account"),
                     icon: "hero-users",
                     order: 30,
                     permissions: [
                       "admin:dashboard:user",
                       "admin:dashboard:permission"
                     ]
                   },
                   %{
                     key: "plugins",
                     label: gettext_noop("Plugins"),
                     icon: "hero-squares-2x2",
                     order: 40,
                     permissions: [{:under, "admin:dashboard"}]
                   }
                 ],
                 &Group.new!/1
               )

  @core_items Enum.map(
                [
                  %{
                    key: "home",
                    label: gettext_noop("Home"),
                    icon: "hero-home",
                    path: "/admin/dashboard",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index,
                    order: 10,
                    permissions: [{:under, "admin:dashboard"}]
                  },
                  %{
                    key: "runtime.sites",
                    label: gettext_noop("Sites"),
                    icon: "hero-map-pin",
                    path: "/admin/dashboard/runtime/sites",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Site.Index,
                    group: "runtime",
                    order: 10,
                    permissions: ["admin:dashboard:runtime:site"]
                  },
                  %{
                    key: "runtime.components",
                    label: gettext_noop("Components"),
                    icon: "hero-bolt",
                    path: "/admin/dashboard/runtime/components",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Component.Index,
                    group: "runtime",
                    order: 20,
                    permissions: [
                      "admin:dashboard:runtime:component",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.layouts",
                    label: gettext_noop("Layouts"),
                    icon: "hero-rectangle-group",
                    path: "/admin/dashboard/runtime/layouts",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Layout.Index,
                    group: "runtime",
                    order: 30,
                    permissions: [
                      "admin:dashboard:runtime:layout",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.error_pages",
                    label: gettext_noop("Error Pages"),
                    icon: "hero-exclamation-triangle",
                    path: "/admin/dashboard/runtime/error-pages",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.ErrorPage.Index,
                    group: "runtime",
                    order: 40,
                    permissions: [
                      "admin:dashboard:runtime:error_page",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.pages",
                    label: gettext_noop("Pages"),
                    icon: "hero-document-text",
                    path: "/admin/dashboard/runtime/pages",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Page.Index,
                    group: "runtime",
                    order: 50,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.medias",
                    label: gettext_noop("Media"),
                    icon: "hero-photo",
                    path: "/admin/dashboard/runtime/medias",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Media.Index,
                    group: "runtime",
                    order: 60,
                    permissions: [
                      "admin:dashboard:runtime:media",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.stylesheets",
                    label: gettext_noop("Stylesheets"),
                    icon: "hero-paint-brush",
                    path: "/admin/dashboard/runtime/stylesheets",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Stylesheet.Index,
                    group: "runtime",
                    order: 70,
                    permissions: [
                      "admin:dashboard:runtime:stylesheet",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.js_hooks",
                    label: gettext_noop("JS Hooks"),
                    icon: "hero-code-bracket",
                    path: "/admin/dashboard/runtime/js-hooks",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.JsHook.Index,
                    group: "runtime",
                    order: 80,
                    permissions: [
                      "admin:dashboard:runtime:js_hook",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.translations",
                    label: gettext_noop("Translations"),
                    icon: "hero-language",
                    path: "/admin/dashboard/runtime/translations",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Translation.Index,
                    group: "runtime",
                    order: 85,
                    permissions: [
                      "admin:dashboard:runtime:translation",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "runtime.redirects",
                    label: gettext_noop("Redirects"),
                    icon: "hero-link",
                    path: "/admin/dashboard/runtime/redirects",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.Redirect.Index,
                    group: "runtime",
                    order: 90,
                    permissions: [
                      "admin:dashboard:runtime:redirect",
                      {:under, "admin:dashboard"}
                    ]
                  },
                  %{
                    key: "account.users",
                    label: gettext_noop("Users"),
                    icon: "hero-user",
                    path: "/admin/dashboard/account/users",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.User.Index,
                    group: "account",
                    order: 10,
                    permissions: ["admin:dashboard:user"]
                  },
                  %{
                    key: "account.permissions",
                    label: gettext_noop("Permissions"),
                    icon: "hero-shield-check",
                    path: "/admin/dashboard/account/permissions",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Account.Permission.Index,
                    group: "account",
                    order: 20,
                    permissions: ["admin:dashboard:permission"]
                  },
                  # Two pages the console routes but the nav has never shown. They are declared so
                  # they have a gate of their own rather than inheriting the console-wide one; the
                  # bell in the topbar is how notifications are reached.
                  %{
                    key: "runtime.activity",
                    label: gettext_noop("Activity"),
                    icon: "hero-clock",
                    path: "/admin/dashboard/runtime/activity",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index,
                    nav: false,
                    permissions: ["admin:dashboard:runtime:activity"]
                  },
                  # The visual builder is reached from a page/layout/component row, never from the
                  # nav, so both of its LiveViews are declared as pages rather than links. The canvas
                  # is a separate declaration because it is a separate mount: it answers inside an
                  # iframe and would otherwise be an undeclared — and therefore refused — page.
                  %{
                    key: "runtime.builder",
                    label: gettext_noop("Page Builder"),
                    icon: "hero-squares-2x2",
                    path: "/admin/dashboard/runtime/builder",
                    module: MishkaCmsCoreWeb.Live.Admin.Builder.BuilderLive,
                    nav: false,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      "admin:dashboard:runtime:layout",
                      "admin:dashboard:runtime:component",
                      "admin:dashboard:runtime:error_page",
                      "admin:dashboard:code"
                    ]
                  },
                  %{
                    key: "runtime.builder_canvas",
                    label: gettext_noop("Page Builder canvas"),
                    icon: "hero-squares-2x2",
                    path: "/admin/dashboard/runtime/builder-canvas",
                    module: MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive,
                    nav: false,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      "admin:dashboard:runtime:layout",
                      "admin:dashboard:runtime:component",
                      "admin:dashboard:runtime:error_page",
                      "admin:dashboard:code"
                    ]
                  },
                  %{
                    key: "notifications",
                    label: gettext_noop("Notifications"),
                    icon: "hero-bell",
                    path: "/admin/dashboard/notifications",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Notification.Index,
                    nav: false,
                    permissions: [{:under, "admin:dashboard"}]
                  },
                  %{
                    key: "settings",
                    label: gettext_noop("Settings"),
                    icon: "hero-cog-6-tooth",
                    path: "/admin/dashboard/settings",
                    module: MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.SettingsLive,
                    order: 100,
                    position: :footer,
                    # Any dashboard admin: the settings page filters its own tabs and fields per
                    # definition (`Settings.permitted?/2`), and one of those tabs is Preferences — a
                    # user's personal settings.
                    permissions: [{:under, "admin:dashboard"}]
                  }
                ],
                &Item.new!/1
              )

  @doc "The mishka_installer event extensions register their menus on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The core's own menu — Home, the Runtime and Account sections, Plugins (the section extensions hang
  their entry point in), and Settings. This is the payload `collect/0` seeds the event with, so the
  console is navigable even with no plugin registered.
  """
  @spec core_menu() :: %{groups: [Group.t()], items: [Item.t()]}
  def core_menu, do: %{groups: @core_groups, items: @core_items}

  @doc """
  Every declared group and item — core plus every `"sidebar:menus"` plugin — with anything that is
  not a valid descriptor discarded and the first declaration of a key winning.

  Unfiltered: this is the registry, not what a given admin sees. Use `menu/1` to render.
  """
  @spec collect() :: %{groups: [Group.t()], items: [Item.t()]}
  def collect do
    case MishkaInstaller.Event.Hook.call(@event, core_menu()) do
      %{groups: groups, items: items} when is_list(groups) and is_list(items) ->
        %{groups: descriptors(groups, Group), items: descriptors(items, Item)}

      _ ->
        core_menu()
    end
  end

  @doc """
  What `user` may see, ready to render: `%{main: [...], footer: [...]}`, each a list of
  `Group.t()` (with `items` filled in) and top-level `Item.t()` interleaved in display order.

  Items the user may not see are dropped, then groups left with no items are dropped with them — a
  tenant admin holding only `admin:dashboard:blog:post` gets Home, the Runtime content lists,
  Plugins → Blog and Settings, and nothing else. Ordering and per-entry visibility come from
  Settings, resolved against the viewer's own site.
  """
  @spec menu(map() | nil) :: %{main: list(), footer: list()}
  def menu(user) do
    %{groups: groups, items: items} = collect()
    user = load_permissions(user)
    site_id = site_id(user)
    visible = items |> Enum.filter(& &1.nav) |> Enum.filter(&visible?(&1, user, site_id))

    groups
    |> Enum.filter(&visible?(&1, user, site_id))
    |> Enum.map(&fill(&1, visible, site_id))
    |> Enum.reject(&(&1.items == []))
    |> Enum.concat(Enum.filter(visible, &is_nil(&1.group)))
    |> arrange(site_id)
    |> Enum.split_with(&(&1.position == :main))
    |> then(fn {main, footer} -> %{main: main, footer: footer} end)
  end

  defp fill(group, items, site_id) do
    %{group | items: items |> Enum.filter(&(&1.group == group.key)) |> arrange(site_id)}
  end

  @doc """
  The `order`/`visible` setting definitions for every declared entry — what
  `MishkaCmsCore.Sidebar.MenuSettings` registers with the Settings page.

  Each definition inherits the entry's own `permissions`, so an admin is never offered a switch for
  a menu they cannot see, and items are grouped under their section's heading. An entry every
  dashboard admin sees (`{:under, "admin:dashboard"}`) is arranged by the holders of
  `admin:dashboard:setting` alone, even when it also names an area.
  """
  @spec settings_definitions() :: [Settings.definition()]
  def settings_definitions do
    %{groups: groups, items: items} = collect()
    labels = Map.new(groups, &{&1.key, &1.label})

    Enum.flat_map(groups, &definitions(&1, gettext_noop("Sections"))) ++
      (items
       |> Enum.filter(& &1.nav)
       |> Enum.flat_map(&definitions(&1, Map.get(labels, &1.group, gettext_noop("Top level")))))
  end

  @doc """
  The console's Home entry — where someone refused a page is sent back to.

  Read rather than hardcoded so the landing page and its gate cannot drift from the declaration
  everything else uses.
  """
  @spec home() :: Item.t()
  def home, do: Enum.find(@core_items, &(&1.key == "home"))

  @doc """
  Where `user` should be sent when a page will not have them — Home if they may see the console, the
  site root otherwise.

  Bouncing someone to a page they would also be refused is how a redirect loop starts, so the same
  Home declaration that gates the console decides whether the console is a valid destination. Read
  through `home/0` rather than hardcoded, so the landing and its gate cannot drift.

  Used by `MishkaCmsCore.Sidebar.PageGuard` for a refusal and by the sign-out page for its "stay
  signed in" way out — both are the same question.
  """
  @spec landing_path(map() | nil) :: String.t()
  def landing_path(user) do
    home = home()

    if AccessPermissions.match?(user, %{}, permissions: home.permissions),
      do: home.path,
      else: "/"
  end

  @doc """
  The permissions declared for the LiveView `module`, or `[]` when nothing declares it.

  `[]` means "no declaration", and `MishkaCmsCore.Sidebar.PageGuard` treats that as REFUSE, not as
  "no requirement" — an admin page nobody declared is a page nobody vouched for. Forgetting a
  declaration therefore locks a page rather than opening it, and the per-extension tests fail the
  build long before anyone meets that in a browser.

  Looked up by module rather than by path on purpose: a path is a string the client spells (and can
  spell several ways), a module is what the router already resolved.
  """
  @spec permissions_for_module(module() | nil) :: [AccessPermissions.requirement()]
  def permissions_for_module(nil), do: []

  def permissions_for_module(module) do
    case Enum.find(collect().items, &(&1.module == module)) do
      %Item{permissions: permissions} -> permissions
      nil -> []
    end
  end

  @doc """
  The name and address of the extension that owns the admin page `module` mounts, for the "Powered
  by" line under it: `%{name: name, url: url}` from the `credit_name` and `credit_url` one of that
  extension's entries declares. `nil` for a core page, a page no entry declares, and an extension
  that declares both of them on no entry.
  """
  @spec credit(module() | nil) :: %{name: String.t(), url: String.t()} | nil
  def credit(nil), do: nil

  def credit(module) do
    %{items: items} = collect()

    with %Item{extension: extension} when not is_nil(extension) <-
           Enum.find(items, &(&1.module == module)),
         %Item{credit_name: name, credit_url: url} <-
           Enum.find(
             items,
             &(&1.extension == extension and is_binary(&1.credit_name) and
                 is_binary(&1.credit_url))
           ) do
      %{name: name, url: url}
    else
      _none -> nil
    end
  end

  @doc """
  Whether `user` may open the admin page at `path`, as its sidebar entry declares: `true` for a path
  no entry declares, since a link to it is not the sidebar's to judge.
  """
  @spec opens?(map() | nil, String.t()) :: boolean()
  def opens?(user, path) do
    case Enum.find(collect().items, &(&1.path == path)) do
      nil -> true
      item -> permitted?(item, user)
    end
  end

  @doc """
  The permissions declared for `key`, raising when nothing declares it.

  This is the single place a page's gate is written down. A page reads its own:

      on_mount {MishkaCmsCore.LiveUserAuth,
                {:require_permission, MishkaBlogWeb.SidebarMenu.permissions("blog.posts")}}

  It raises rather than returning `[]` on a miss, and it takes a STATIC list rather than calling
  `collect/0`: both are about the same failure. A page reads this at COMPILE time, when no plugin
  has registered on the hook yet — so `collect/0` would answer `[]`, and a silent `[]` would mean
  a page that gates nothing. A typo has to break the build, not the gate.
  """
  @spec permissions([Item.t()], String.t()) :: [AccessPermissions.requirement()]
  def permissions(items, key) do
    case Enum.find(items, &(&1.key == key)) do
      %Item{permissions: permissions} ->
        permissions

      nil ->
        raise ArgumentError,
              "no sidebar item declares the key #{inspect(key)} — declared: " <>
                inspect(Enum.map(items, & &1.key))
    end
  end

  @doc "The permissions declared for one of the CORE's pages. See `permissions/2`."
  @spec permissions(String.t()) :: [AccessPermissions.requirement()]
  def permissions(key), do: permissions(@core_items, key)

  @doc """
  Tells this node's open admin LiveViews that the sidebar settings of `site_id` changed; `nil` for
  the global ones, which every viewer reads.

      Sidebar.changed(site.id)
  """
  @spec changed(String.t() | nil) :: :ok
  def changed(site_id) do
    Phoenix.PubSub.local_broadcast(@pubsub, topic(site_id), {:sidebar_changed, site_id})

    MishkaInstaller.Event.Hook.call("runtime:state:sidebar:changed", %{key: site_id},
      return: false
    )

    :ok
  end

  @doc """
  Subscribes the calling process to the changes `changed/1` announces for the menu `user` is shown:
  the global ones and those of the site the menu reads. It receives `{:sidebar_changed, site_id}`.
  """
  @spec subscribe(map() | nil) :: :ok
  def subscribe(nil), do: :ok

  def subscribe(user) do
    for topic <- Enum.uniq([topic(nil), topic(site_id(user))]),
        do: Phoenix.PubSub.subscribe(@pubsub, topic)

    :ok
  end

  defp topic(nil), do: "sidebar:all"
  defp topic(site_id), do: "sidebar:" <> site_id

  @doc "The settings key holding `key`'s position override."
  @spec order_key(String.t()) :: String.t()
  def order_key(key), do: "sidebar.#{key}.order"

  @doc "The settings key holding `key`'s on/off switch."
  @spec visible_key(String.t()) :: String.t()
  def visible_key(key), do: "sidebar.#{key}.visible"

  defp definitions(entry, group) do
    [
      Settings.define(order_key(entry.key), :integer,
        default: entry.order,
        min: 0,
        max: 1000,
        category: "sidebar",
        group: group,
        scope: :both,
        source: :plugin,
        permission: arrangers(entry.permissions),
        label: {gettext_noop("%{label} — position"), label: entry.label},
        description: gettext_noop("Lower numbers sit higher in the sidebar.")
      ),
      Settings.define(visible_key(entry.key), :boolean,
        default: true,
        category: "sidebar",
        group: group,
        scope: :both,
        source: :plugin,
        permission: arrangers(entry.permissions),
        label: {gettext_noop("%{label} — shown"), label: entry.label},
        description:
          gettext_noop(
            "Turn off to hide this entry from the sidebar for everyone who can see it."
          )
      )
    ]
  end

  # AN ENTRY EVERY DASHBOARD ADMIN SEES is the site's menu, not one area's: hiding it hides it from
  # all of them, so only the setting area arranges it, whatever area it also names.
  defp arrangers(permissions) do
    if Enum.any?(permissions, &match?({:under, _prefix}, &1)),
      do: ["admin:dashboard:setting"],
      else: permissions
  end

  defp descriptors(list, struct) do
    list
    |> Enum.filter(&is_struct(&1, struct))
    |> Enum.uniq_by(& &1.key)
  end

  defp arrange(entries, site_id), do: Enum.sort_by(entries, &{order(&1, site_id), &1.key})

  defp order(entry, site_id) do
    case Settings.get(order_key(entry.key), entry.order, site_id) do
      order when is_integer(order) -> order
      _other -> entry.order
    end
  end

  @doc """
  Whether `user` on `site_id` sees `entry` — the per-entry setting, the site's switch over the
  extension that owns it, and the permissions it declares.

  Public because it is the whole of "may this be drawn", and a caller asking about one entry should
  not have to rebuild the menu to find out.
  """
  @spec visible_to?(map(), map() | nil, String.t() | nil) :: boolean()
  def visible_to?(entry, user, site_id), do: visible?(entry, load_permissions(user), site_id)

  @doc """
  `visible_to?/3` against the site the USER is on — their own, or the master site for a master.

  This is what `menu/1` asks, so a caller checking one entry gets the same answer the menu would
  rather than the global one.
  """
  @spec visible_to?(map(), map() | nil) :: boolean()
  def visible_to?(entry, user) do
    user = load_permissions(user)
    visible?(entry, user, site_id(user))
  end

  defp visible?(entry, user, site_id) do
    Settings.get(visible_key(entry.key), true, site_id) != false and
      switched_on?(entry, site_id) and permitted?(entry, user)
  end

  # AN EXTENSION A SITE SWITCHED OFF DRAWS NOTHING. The event that collects menus knows no site —
  # it is fired once and answered by every plugin — so the question is asked here, where the site is,
  # beside the per-entry visibility it already answers. An entry naming no extension is core's, and
  # core cannot be switched off.
  defp switched_on?(%{extension: app}, site_id) when is_atom(app) and not is_nil(app),
    do: Extensions.active?(site_id, app)

  defp switched_on?(_core_entry, _site_id), do: true

  defp permitted?(%{permissions: []}, user), do: !is_nil(user)

  defp permitted?(%{permissions: required}, user),
    do: AccessPermissions.match?(user, %{}, permissions: required)

  defp site_id(%{site_id: site_id}) when is_binary(site_id), do: site_id

  # A MASTER HAS NO SITE OF THEIR OWN, AND IS STILL LOOKING AT ONE. Answering `nil` read the GLOBAL
  # settings, so a site that switched an extension off went on showing it to the master — including
  # the MASTER SITE itself, which is an ordinary site with an ordinary switch. A master who turns the
  # blog off on their own site means it, and now sees that they did.
  defp site_id(_master) do
    case SiteState.get_by_master() do
      {:ok, %{id: id}} -> id
      _no_master_site -> nil
    end
  end

  # The permission check reads `user.permissions`, and the sidebar asks it once per entry. Loading
  # them here means one query per mount instead of one per link.
  defp load_permissions(user), do: AccessPermissions.with_permissions(user)

  defmodule PageGuard do
    @moduledoc """
    `on_mount` hook that refuses an admin page to anyone whose permissions its declaration does not
    allow. Attached once, in `MishkaCmsCore.ExtensionLiveView`, so it covers every admin LiveView
    without a line in any of them.

    It reads `socket.view` — the module the router resolved — never the URL. That is the whole
    point: a URL is a string the client chooses and can spell more than one way
    (`/admin/dashboard//account/permissions` routes to the same page as the single-slash form), while
    the mounted module is a fact by the time this runs.

    `mount` is the right callback for "may this user open this page": a direct URL goes through the
    plug pipeline and mounts, and a `push_navigate` from another page skips the pipeline but still
    mounts. A `push_patch` within the same page re-runs only `handle_params`, which is fine — same
    page, same declaration, already decided here.

    **Undeclared means refused.** A page with no entry in `MishkaCmsCore.Sidebar` gets `[]` and is
    denied, so the failure mode of forgetting a declaration is a locked page, never an open one.
    """

    use Gettext, backend: MishkaCmsCore.Gettext

    import MishkaCmsCore.Helpers, only: [path: 2]

    def on_mount(:default, _params, _session, socket) do
      socket.view
      |> MishkaCmsCore.Sidebar.permissions_for_module()
      |> authorize(socket)
    end

    defp authorize(required, socket) do
      if required != [] and
           AccessPermissions.match?(socket.assigns[:current_user], %{}, permissions: required) do
        {:cont, socket}
      else
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           gettext("You don't have permission to access this page")
         )
         |> Phoenix.LiveView.redirect(to: path(socket, landing(socket)))}
      end
    end

    defp landing(socket) do
      MishkaCmsCore.Sidebar.landing_path(socket.assigns[:current_user])
    end
  end
end
