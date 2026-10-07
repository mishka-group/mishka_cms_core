defmodule MishkaCmsCore.Layouts do
  @moduledoc """
  Layouts shared by extension LiveViews.

  Mirrors the host app's `MishkaCmsWeb.Layouts` module: one module holds the
  layout templates (auto-embedded from `layouts/*.html.heex`) and any helper
  components that belong to the chrome.

  ## Wiring

  Extension LiveViews opt in via `MishkaCmsCore.ExtensionLiveView`, which does
  `use Phoenix.LiveView, layout: {MishkaCmsCore.Layouts, :app}`. The result:
  every extension admin page is automatically wrapped by `app.html.heex` and
  gets the flash group without each template repeating it.

  ## Why not reuse `MishkaCmsWeb.Layouts`?

  Extensions compile before `MishkaCmsWeb`, so calling
  `MishkaCmsWeb.Layouts.flash_group/1` from an extension template raises an
  "undefined" warning at compile time. This module is the extension-side
  counterpart and owns the flash chrome for everything under
  `MishkaCmsCore.ExtensionLiveView`.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.Group
  alias Phoenix.LiveView.JS

  embed_templates "layouts/*"

  @doc """
  Renders both `:info` and `:error` flashes from the `@flash` map.

  Styled with classes rather than `style` attributes. Every surface that renders this — the admin
  chrome via `app.html.heex` and the page builder shell — sets `admin_css`, so the compiled admin
  stylesheet is always there to carry them; the canvas iframe, the one admin surface without it,
  mounts with `layout: false` and never draws a flash. Keeping the colours in classes is what lets
  the policy in `MishkaCmsCore.Runtime.Plugs.SecurityHeaders` close `style-src-attr`, which no nonce
  can ever reopen for an attribute.

      <.flash_group flash={@flash} />

  Whatever the inner block holds is stacked under the notices — the admin chrome puts
  `MishkaCmsCoreWeb.Live.Admin.Components.TranslationsRefusal` there.
  """
  attr :flash, :map, required: true
  slot :inner_block

  def flash_group(assigns) do
    ~H"""
    <%!-- ALWAYS RENDERED, EVEN WITH NOTHING IN IT. Each notice used to be a `:if` at the top level,
          so showing one INSERTED a sibling before the page — and the page builder's page begins
          with an `<iframe>`. Moving an iframe in the DOM reloads it: that is a browser rule, not a
          LiveView one, so every "Saved" and every "Note posted" threw the canvas away and loaded it
          again. A wrapper that is always there means the notices come and go INSIDE it and nothing
          around them ever moves.

          `pointer-events: none` on the wrapper because it now covers the corner of the screen at
          all times; each notice turns them back on for itself. --%>
    <div
      id="mishka-flash"
      class="pointer-events-none fixed end-4 top-4 z-[9999] flex flex-col items-end gap-2"
    >
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        id="flash-info"
        phx-hook="FlashAutoDismiss"
        data-kind="info"
        data-dismiss-after="4000"
        phx-click={JS.push("lv:clear-flash", value: %{key: :info}) |> JS.hide(to: "#flash-info")}
        role="alert"
        class="pointer-events-auto max-w-[32rem] cursor-pointer rounded-lg px-4 py-3 font-[system-ui,sans-serif] text-white [background:#16a34a] [box-shadow:0_4px_12px_rgba(0,0,0,0.15)]"
      >
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        id="flash-error"
        phx-hook="FlashAutoDismiss"
        data-kind="error"
        data-dismiss-after="7000"
        phx-click={JS.push("lv:clear-flash", value: %{key: :error}) |> JS.hide(to: "#flash-error")}
        role="alert"
        class="pointer-events-auto max-w-[32rem] cursor-pointer rounded-lg px-4 py-3 font-[system-ui,sans-serif] text-white [background:#dc2626] [box-shadow:0_4px_12px_rgba(0,0,0,0.15)]"
      >
        {msg}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The admin sidebar — logo, collapsible nav groups, and the active item highlighted from
  `@current_path` (set by `MishkaCmsCore.Layouts.Nav`). Groups collapse client-side via `JS.toggle`.

  The nav itself is data, not markup: `MishkaCmsCore.Sidebar.menu/1` collects it from every
  extension's `"sidebar:menus"` plugin, drops what `@current_user` may not see, and orders it from
  Settings. This component only paints what it is handed, so an empty section is one that was
  filtered away rather than one that has to be spelled out here.
  """
  attr :current_path, :string, default: nil
  attr :current_user, :any, default: nil

  def sidebar(assigns) do
    %{main: main, footer: footer} = Sidebar.menu(assigns.current_user)
    assigns = assign(assigns, main_entries: main, footer_entries: footer)

    ~H"""
    <%!-- ON A NARROW SCREEN THE MENU SLIDES IN FROM THE LEFT in either direction: its open state is
          one `translate-x-0!` added by the menu button, which a right-to-left closed state would
          have to be ordered against. Everything else here is start and end, and turns with
          `<html dir>`. --%>
    <aside
      id="admin-sidebar"
      class="flex h-full w-[266px] shrink-0 flex-col border-e border-[#ecebe6] bg-white p-[16px_14px] max-[980px]:fixed! max-[980px]:inset-y-0 max-[980px]:left-0 max-[980px]:z-[90] max-[980px]:-translate-x-[105%]! max-[980px]:shadow-[0_24px_70px_rgba(20,18,26,0.35)] max-[980px]:transition-transform"
    >
      <div class="mb-1.5 flex items-center gap-3 border-b border-[#e6e4de] px-1.5 pb-[18px] pt-1">
        <div class="flex size-[44px] items-center justify-center rounded-[14px] border border-[#e4e2f7] bg-[radial-gradient(120%_120%_at_30%_20%,#ffffff,#f4f3fd)] shadow-[0_6px_16px_rgba(79,75,204,0.14),inset_0_1px_0_#fff]">
          <%!-- The mark is painted by masking the tile rather than inlining the file's nine paths:
                one 10KB asset the browser caches, and the colour stays a class, so the dark theme
                repaints it without shipping a second copy of the artwork. --%>
          <span
            role="img"
            aria-label="MishkaCMS"
            class="size-[23px] bg-[#5b57d6] [mask:url(/images/mishka-logo.svg)_no-repeat_center/contain] [-webkit-mask:url(/images/mishka-logo.svg)_no-repeat_center/contain] [[data-theme=dark]_&]:bg-[#8b87f5]"
          ></span>
        </div>
        <div class="min-w-0">
          <div class="font-['Space_Grotesk'] text-[17px] font-extrabold leading-none tracking-[-0.02em] text-[#17161a]">
            MishkaCMS
          </div>
          <div class="mt-1.5 flex items-center gap-[5px]">
            <span class="size-1.5 rounded-full bg-[#1f9d6b] shadow-[0_0_0_2px_#e6f6ee]"></span>
            <span class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#a8a5a0]">
              {gettext("Admin console")}
            </span>
          </div>
        </div>
      </div>

      <nav
        id="admin-sidebar-nav"
        phx-hook="SidebarScroll"
        class="-mx-0.5 flex flex-1 flex-col gap-0.5 overflow-y-auto px-0.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        <%= for entry <- @main_entries do %>
          <div :if={group?(entry)}>
            <button
              type="button"
              phx-click={JS.toggle(to: "#sb-" <> entry.key)}
              class="mb-1 mt-4 flex w-full items-center gap-2.5 px-[10px] py-1.5"
            >
              <span class="text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#a8a5a0]">
                {label(entry.label)}
              </span>
              <span class="h-px flex-1 bg-[#e6e4de]"></span>
              <.icon name="hero-chevron-down" class="size-[13px] text-[#c2bfb6]" />
            </button>
            <div id={"sb-" <> entry.key} class="flex flex-col gap-0.5">
              <.nav_link :for={item <- entry.items} item={item} current_path={@current_path} child />
            </div>
          </div>
          <.nav_link :if={!group?(entry)} item={entry} current_path={@current_path} />
        <% end %>
      </nav>

      <div class="mt-2 shrink-0 border-t border-[#e6e4de] pt-3">
        <div class="mb-2 rounded-[13px] border border-[#e2ece5] bg-[#f3f8f4] px-[13px] py-3">
          <div class="flex items-center gap-2">
            <span class="size-2 shrink-0 animate-pulse rounded-full bg-[#1f9d6b]"></span>
            <span class="text-[11.5px] font-bold text-[#177a53]">
              {gettext("All systems operational")}
            </span>
          </div>
          <div class="mt-[5px] ps-4 text-[10.5px] font-medium text-[#8a938c]">
            {gettext("Runtime · %{uptime} uptime", uptime: "99.98%")}
          </div>
        </div>
        <.nav_link :for={item <- @footer_entries} item={item} current_path={@current_path} />
      </div>
    </aside>

    <div
      id="admin-nav-overlay"
      phx-click={
        JS.remove_class("max-[980px]:translate-x-0!", to: "#admin-sidebar")
        |> JS.hide(to: "#admin-nav-overlay")
      }
      class="fixed inset-0 z-[85] hidden bg-[rgba(20,18,26,0.42)]"
    >
    </div>
    """
  end

  attr :item, :map, required: true
  attr :current_path, :string, default: nil
  attr :child, :boolean, default: false

  defp nav_link(assigns) do
    assigns = assign(assigns, :active, active?(assigns.current_path, assigns.item.path))

    ~H"""
    <.link
      navigate={@item.path}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-3 rounded-[10px] px-[10px] py-[9px] text-[13px] transition-colors",
        (@active && "bg-[#f2f1fc] font-bold text-[#4f4bcc]") ||
          "font-semibold text-[#5c5a54] hover:bg-[#f6f5f2] hover:text-[#1b1a18]"
      ]}
    >
      <span class={[
        "flex size-[26px] shrink-0 items-center justify-center rounded-[8px]",
        @active && "bg-[#e4e2f7] text-[#5b57d6]"
      ]}>
        <.icon name={@item.icon} class="size-4" />
      </span>
      <span class="flex-1">{label(@item.label)}</span>
    </.link>
    """
  end

  @doc """
  The admin topbar — search, theme toggle, notifications, and the user's menu: Account settings, the
  language the dashboard is read in, and Sign out.

  `language` is the admin's language and `languages` the ones the menu offers
  (`MishkaCmsCore.Layouts.Nav` assigns both); picking one sends `PUT /admin/language` with
  `current_path` to come back to. Two are listed, the admin's own among them, and the rest behind
  "Show more".
  """
  attr :current_user, :any, default: nil
  attr :notification_count, :integer, default: 0
  attr :notification_recent, :list, default: []
  attr :current_path, :string, default: nil
  attr :language, :string, default: "en"
  attr :languages, :list, default: []
  attr :sign_out, :string, default: "/auth/sign-out"

  def topbar(assigns) do
    {shown, more} = split_languages(assigns.languages, assigns.language)
    assigns = assign(assigns, shown_languages: shown, more_languages: more)

    ~H"""
    <header class="relative z-40 flex h-[66px] flex-none items-center gap-4 border-b border-[#ecebe6] bg-white/80 px-7 backdrop-blur-[10px] max-[560px]:gap-2.5! max-[560px]:px-[14px]!">
      <button
        type="button"
        phx-click={
          JS.add_class("max-[980px]:translate-x-0!", to: "#admin-sidebar")
          |> JS.show(to: "#admin-nav-overlay")
        }
        title={gettext("Open menu")}
        class="hidden size-[39px] shrink-0 items-center justify-center rounded-[11px] border border-[#ecebe6] bg-white text-[#5c5a54] max-[980px]:flex!"
      >
        <.icon name="hero-bars-3" class="size-[18px]" />
      </button>

      <div class="relative min-w-0 flex-1 max-w-[440px]">
        <.icon
          name="hero-magnifying-glass"
          class="absolute start-[13px] top-1/2 size-4 -translate-y-1/2 text-[#a8a5a0]"
        />
        <input
          type="text"
          placeholder={gettext("Search pages, posts, people…")}
          class="h-[39px] w-full rounded-[11px] border border-[#ecebe6] bg-[#f7f6f3] ps-[38px] pe-[14px] text-[13px] font-medium text-[#1b1a18] outline-none"
        />
      </div>

      <div class="flex-1"></div>

      <div class="relative flex shrink-0 items-center gap-[11px]">
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="dark"
          title={gettext("Switch to dark")}
          class="flex size-[39px] items-center justify-center rounded-[11px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3] [[data-theme=dark]_&]:hidden"
        >
          <.icon name="hero-moon" class="size-[17px]" />
        </button>
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="light"
          title={gettext("Switch to light")}
          class="hidden size-[39px] items-center justify-center rounded-[11px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3] [[data-theme=dark]_&]:flex"
        >
          <.icon name="hero-sun" class="size-[17px] text-[#c8931f]" />
        </button>

        <div>
          <button
            type="button"
            phx-click={JS.toggle(to: "#topbar-notifs")}
            class="relative flex size-[39px] items-center justify-center rounded-[11px] border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"
          >
            <.icon name="hero-bell" class="size-[17px]" />
            <span
              :if={@notification_count > 0}
              class="absolute -end-[5px] -top-[5px] flex h-[17px] min-w-[17px] items-center justify-center rounded-full border-2 border-white bg-[#5b57d6] px-1 text-[9.5px] font-bold text-white"
            >
              {if @notification_count > 9, do: "9+", else: @notification_count}
            </span>
          </button>
          <div
            id="topbar-notifs"
            phx-click-away={JS.hide(to: "#topbar-notifs")}
            class="absolute end-0 top-[52px] z-[60] hidden w-[340px] max-w-[calc(100vw-2rem)] overflow-hidden rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_18px_44px_rgba(30,28,24,0.16)]"
          >
            <div class="flex items-center justify-between gap-2 border-b border-[#f0efea] px-4 py-[15px]">
              <span class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
                {gettext("Notifications")}
                <span :if={@notification_count > 0} class="text-xs text-[#5b57d6]">
                  · {ngettext("%{count} unread", "%{count} unread", @notification_count)}
                </span>
              </span>
              <button
                :if={@notification_count > 0}
                type="button"
                phx-click="notify_read_all"
                class="shrink-0 text-[11px] font-semibold text-[#5b57d6] hover:underline"
              >
                {gettext("Mark all read")}
              </button>
            </div>

            <p
              :if={@notification_recent == []}
              class="px-4 py-6 text-center text-[12.5px] text-[#a8a5a0]"
            >
              {gettext("You're all caught up.")}
            </p>

            <div class="max-h-96 overflow-y-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
              <div
                :for={n <- @notification_recent}
                id={"bell-notif-#{n.id}"}
                class="group flex items-start gap-[11px] border-b border-[#f4f3ef] px-4 py-[13px] hover:bg-[#faf9f6]"
              >
                <%!-- Click the body: mark read AND go to its link. --%>
                <button
                  type="button"
                  phx-click="notify_open"
                  phx-value-id={n.id}
                  phx-value-link={n.link || ""}
                  class="flex min-w-0 flex-1 items-start gap-[11px] text-start"
                >
                  <%!-- Inline SVG (not a hero-* mask): the browser-JIT admin only bundles the heroicon
                       masks the site's compiled CSS uses, so arbitrary notification icons render
                       blank. This waveform matches the React reference and always renders. --%>
                  <span class={[
                    "mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-[9px]",
                    notif_chip_class(Map.get(n, :severity))
                  ]}>
                    <svg
                      class="size-[15px]"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M3 12h4l2 6 4-14 2 8h6" />
                    </svg>
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class={[
                      "block truncate text-[12.5px]",
                      is_nil(n.read_at) && "font-semibold text-[#1b1a18]",
                      n.read_at && "text-[#5c5a54]"
                    ]}>
                      {Gettext.gettext(MishkaCmsCore.Gettext, n.title)}
                    </span>
                    <span
                      :if={n.body}
                      class="mt-px block truncate text-[11.5px] font-medium text-[#8a877f]"
                    >
                      {n.body}
                    </span>
                  </span>
                </button>

                <%!-- React shows the relative time top-right; our extra "mark read" button reveals
                     over it on hover (so the resting layout matches React). --%>
                <div class="relative mt-0.5 shrink-0">
                  <span class={[
                    "block whitespace-nowrap text-[11px] font-medium text-[#a8a5a0]",
                    is_nil(n.read_at) && "group-hover:invisible"
                  ]}>
                    {notif_time(n.inserted_at)}
                  </span>
                  <button
                    :if={is_nil(n.read_at)}
                    type="button"
                    phx-click="notify_read"
                    phx-value-id={n.id}
                    title={gettext("Mark read")}
                    class="absolute end-0 top-1/2 hidden -translate-y-1/2 rounded-md p-1 text-[#a8a5a0] hover:bg-[#f0efea] hover:text-[#5c5a54] group-hover:block"
                  >
                    <.icon name="hero-check" class="size-4" />
                  </button>
                </div>
              </div>
            </div>

            <.link
              navigate="/admin/dashboard/notifications"
              class="block px-4 py-3 text-center text-[12.5px] font-semibold text-[#5b57d6] hover:bg-[#faf9f6]"
            >
              {gettext("View all activity")}
            </.link>
          </div>
        </div>

        <div class="relative">
          <button
            type="button"
            phx-click={JS.toggle(to: "#topbar-user")}
            class="flex items-center gap-2.5 rounded-[30px] border border-[#ecebe6] bg-white py-1 ps-1 pe-3 hover:bg-[#f7f6f3]"
          >
            <span class="flex size-[31px] items-center justify-center rounded-full bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] font-['Space_Grotesk'] text-[12px] font-bold text-white">
              {avatar_initial(@current_user)}
            </span>
            <span
              data-role="user-email"
              class="text-[12.5px] font-medium text-[#3a382f] max-[560px]:hidden"
            >
              {user_email(@current_user)}
            </span>
            <.icon name="hero-chevron-down" class="size-[14px] text-[#a8a5a0]" />
          </button>
          <div
            id="topbar-user"
            phx-click-away={JS.hide(to: "#topbar-user")}
            class="absolute end-0 top-[52px] z-[60] hidden w-[250px] overflow-hidden rounded-[16px] border border-[#ecebe6] bg-white shadow-[0_18px_44px_rgba(30,28,24,0.16)]"
          >
            <div class="flex items-center gap-[11px] border-b border-[#f0efea] px-4 py-[15px]">
              <span class="flex size-[38px] items-center justify-center rounded-[11px] bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] font-['Space_Grotesk'] text-[14px] font-bold text-white">
                {avatar_initial(@current_user)}
              </span>
              <div class="min-w-0">
                <div class="truncate text-[11.5px] font-medium text-[#8a877f]">
                  {user_email(@current_user)}
                </div>
              </div>
            </div>
            <div class="p-1.5">
              <.link
                navigate="/admin/dashboard/settings?tab=preferences"
                id="topbar-account-settings"
                class="flex items-center gap-[11px] rounded-[9px] px-[11px] py-[9px] text-[13px] font-medium text-[#3a382f] hover:bg-[#f6f5f2]"
              >
                <.icon name="hero-cog-6-tooth" class="size-4 text-[#7c7a75]" /> {gettext(
                  "Account settings"
                )}
              </.link>
              <div class="mx-1 my-1.5 h-px bg-[#f0efea]"></div>
              <.form
                :if={@languages != []}
                for={%{}}
                id="admin-language-form"
                action="/admin/language"
                method="put"
              >
                <input type="hidden" name="return_to" value={@current_path || "/admin/dashboard"} />
                <div class="px-[11px] pb-1 pt-1 text-[10.5px] font-bold uppercase tracking-[0.1em] text-[#a8a5a0]">
                  {gettext("Language")}
                </div>
                <.language_choice :for={code <- @shown_languages} code={code} current={@language} />
                <div :if={@more_languages != []} id="admin-language-rest" class="hidden">
                  <.language_choice :for={code <- @more_languages} code={code} current={@language} />
                </div>
                <button
                  :if={@more_languages != []}
                  type="button"
                  id="admin-language-more"
                  phx-click={toggle_more_languages()}
                  class="flex w-full items-center gap-[11px] rounded-[9px] px-[11px] py-[7px] text-start text-[12px] font-semibold text-[#5b57d6] hover:bg-[#f6f5f2]"
                >
                  <.icon name="hero-chevron-down" class="size-4" />
                  {gettext("Show %{count} more", count: length(@more_languages))}
                </button>
                <button
                  :if={@more_languages != []}
                  type="button"
                  id="admin-language-less"
                  phx-click={toggle_more_languages()}
                  class="hidden w-full items-center gap-[11px] rounded-[9px] px-[11px] py-[7px] text-start text-[12px] font-semibold text-[#5b57d6] hover:bg-[#f6f5f2] [&:not(.hidden)]:flex"
                >
                  <.icon name="hero-chevron-up" class="size-4" />
                  {gettext("Show less")}
                </button>
              </.form>
              <div :if={@languages != []} class="mx-1 my-1.5 h-px bg-[#f0efea]"></div>
              <.link
                id="admin-sign-out"
                href={@sign_out}
                class="flex items-center gap-[11px] rounded-[9px] px-[11px] py-[9px] text-[13px] font-semibold text-[#d5544b] hover:bg-[#fbe9e7]"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> {gettext("Sign out")}
              </.link>
            </div>
          </div>
        </div>
      </div>
    </header>
    """
  end

  @first_year 2026
  @default_credit %{name: "Mishka CMS", url: "https://mishka.tools/cms"}

  attr :code, :string, required: true
  attr :current, :string, required: true

  defp language_choice(assigns) do
    ~H"""
    <button
      type="submit"
      name="language"
      value={@code}
      id={"admin-language-" <> @code}
      aria-current={@code == @current && "true"}
      class={[
        "flex w-full items-center gap-[11px] rounded-[9px] px-[11px] py-[8px] text-start text-[13px] hover:bg-[#f6f5f2]",
        (@code == @current && "font-bold text-[#4f4bcc]") || "font-medium text-[#3a382f]"
      ]}
    >
      <.icon name="hero-language" class="size-4 text-[#7c7a75]" />
      <span class="flex-1">{Languages.name(@code)}</span>
      <span class="text-[10.5px] font-semibold uppercase text-[#a8a5a0]">{@code}</span>
      <.icon :if={@code == @current} name="hero-check" class="size-4 text-[#5b57d6]" />
    </button>
    """
  end

  # TWO LANGUAGES ARE LISTED, THE ADMIN'S OWN AMONG THEM; the rest wait behind "Show more", in the
  # order the site gives them.
  @listed_languages 2

  defp split_languages(languages, current) do
    if length(languages) <= @listed_languages do
      {languages, []}
    else
      first = Enum.take(languages, @listed_languages)

      listed =
        if current in first or current not in languages,
          do: first,
          else: Enum.take(first, @listed_languages - 1) ++ [current]

      {Enum.filter(languages, &(&1 in listed)), Enum.reject(languages, &(&1 in listed))}
    end
  end

  defp toggle_more_languages do
    JS.toggle_class("hidden", to: "#admin-language-rest")
    |> JS.toggle_class("hidden", to: "#admin-language-more")
    |> JS.toggle_class("hidden", to: "#admin-language-less")
  end

  @doc """
  The line under every admin page: "© <years> · Powered by <name>", where the name links to the
  product's own page.

  `credit` is `%{name: name, url: url}` — what `MishkaCmsCore.Layouts.Nav` assigns as
  `@footer_credit` from the extension that owns the page — or `nil` on the core's own pages, which
  credit Mishka CMS. Only "Powered by" is translated; a product name is not.
  """
  attr :credit, :map, default: nil

  def footer_credit(assigns) do
    assigns = assign(assigns, :credit, assigns.credit || @default_credit)

    ~H"""
    <footer
      id="admin-footer"
      class="mx-auto mt-12 max-w-[1340px] border-t border-[#ecebe6] pt-5 text-center text-[11.5px] font-medium text-[#8a877f]"
    >
      © {copyright_years()} · {gettext("Powered by")}
      <a
        href={@credit.url}
        target="_blank"
        rel="noopener noreferrer"
        class="font-semibold text-[#5b57d6] hover:underline"
      >
        {@credit.name}
      </a>
    </footer>
    """
  end

  @doc """
  The years the footer's copyright line covers, from 2026 up to `today`'s year: `"2026"` during
  2026, `"2026-2027"` in 2027, and so on.
  """
  @spec copyright_years(Date.t()) :: String.t()
  def copyright_years(today \\ Date.utc_today())

  def copyright_years(%Date{year: year}) when year <= @first_year, do: "#{@first_year}"
  def copyright_years(%Date{year: year}), do: "#{@first_year}-#{year}"

  # A sidebar label is marked with `gettext_noop/1` where it is declared, at compile time.
  defp label(text), do: Gettext.gettext(MishkaCmsCore.Gettext, text)

  defp group?(%Group{}), do: true
  defp group?(_entry), do: false

  defp active?(nil, _path), do: false
  defp active?(current, "/admin/dashboard"), do: current == "/admin/dashboard"
  defp active?(current, path), do: current == path or String.starts_with?(current, path <> "/")

  defp user_email(%{email: email}) when not is_nil(email), do: to_string(email)
  defp user_email(_), do: gettext("Admin")

  defp avatar_initial(user) do
    user |> user_email() |> String.first() |> String.upcase()
  end

  # Compact relative time, matching the React reference ("just now", "5m", "11h", "3d", then "Jul 10").
  defp notif_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{count}m", count: div(diff, 60))
      diff < 86_400 -> gettext("%{count}h", count: div(diff, 3600))
      diff < 604_800 -> gettext("%{count}d", count: div(diff, 86_400))
      true -> Calendar.strftime(dt, "%b %d", MishkaCmsCore.Activity.Helpers.strftime_names())
    end
  end

  defp notif_time(%NaiveDateTime{} = dt), do: notif_time(DateTime.from_naive!(dt, "Etc/UTC"))
  defp notif_time(_), do: ""

  # Tinted icon-chip per notification severity, in the redesign palette (matches the KPI/widget tones).
  defp notif_chip_class(:success), do: "bg-[#e6f6ee] text-[#1f9d6b]"
  defp notif_chip_class(:warn), do: "bg-[#fbf1df] text-[#cf8a24]"
  defp notif_chip_class(:error), do: "bg-[#fbe9e7] text-[#d5544b]"
  defp notif_chip_class(_info), do: "bg-[#eeedfb] text-[#5b57d6]"
end
