# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Layouts.SiteSwitcher do
  @moduledoc """
  The master's site switcher in the admin top bar, on every admin page: a button with a globe, the
  picked site's name (or "All sites") and a chevron, and under it a panel with a search over the
  active sites, an **All sites** row and one row for each site (its name and its host).

  `MishkaCmsCore.Layouts.topbar/1` draws it for a master (`MishkaCmsCore.Accounts.AdminSite.master?/1`)
  and never for a site user; with fewer than two active sites it draws nothing, since there is
  nothing to pick. The sites come from `MishkaCmsCore.Runtime.States.SiteState` and the pick from
  `AdminSite.chosen/1` (or the page's `@admin_site`), so it runs no query.

  A row closes the panel (`Phoenix.LiveView.JS`, as a press elsewhere and Escape do) and sends
  `"pick"` here, which keeps the pick (`AdminSite.keep/2`). A page that follows the pick (it
  mounted `AdminSite`, or a hook of its own that assigns `:admin_site`) is handed the pick as the
  message its other pages hear, `{:admin_site_chosen, chosen}`, and its hook decides where it goes;
  any other page mounts again where it is (`push_navigate/2`, `replace: true`). Either way it is a
  live navigation, never a reload of the browser's page.

  On a phone it is a 44 px globe whose name the screen reader says, and its panel hangs under the
  whole top bar, 12 px from each edge of the screen.

  ## What an extension adds to the rows

  The rows are asked on the `"topbar:sites"` mishka_installer event (`event/0`), as the top bar's
  items are on `"topbar:items"`. A plugin is handed

      %{
        sites: [%{id: id, name: name, host: host, sub: host, count: nil}],
        current_user: user,
        current_path: "/admin/dashboard/..."
      }

  and answers `{:reply, %{data | sites: sites}}` with any site's `sub` (the line under its name,
  which the search reads too) or `count` (a number at the end of its row; the All sites row then
  shows their sum) changed. It is asked each time the switcher is updated, so a plugin reads what it
  needs from memory or from the user it is handed, never with a query. A plugin that raises is
  logged by mishka_installer and the rows are drawn as the core has them.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Accounts.AdminSite
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.Hook
  alias Phoenix.LiveView.JS

  @event "topbar:sites"

  @typedoc "A row of the switcher: an active site, with what extensions added on `event/0`."
  @type site :: %{
          id: String.t(),
          name: String.t(),
          host: String.t() | nil,
          sub: String.t() | nil,
          count: non_neg_integer() | nil
        }

  @doc "The mishka_installer event extensions add to the switcher's rows on."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The rows for `user` on `path`: the active sites by name, each as `t:site/0`, with what the
  plugins of `event/0` added.
  """
  @spec sites(map() | nil, String.t() | nil) :: [site()]
  def sites(user, path) do
    sites =
      SiteState.get_active_sites()
      |> Enum.sort_by(&String.downcase(to_string(&1.name)))
      |> Enum.map(&%{id: &1.id, name: &1.name, host: &1.host, sub: &1.host, count: nil})

    case Hook.call(@event, %{sites: sites, current_user: user, current_path: path}) do
      %{sites: answered} when is_list(answered) -> Enum.filter(answered, &row?/1)
      _nothing -> sites
    end
  end

  defp row?(%{id: id, name: name}) when is_binary(id) and is_binary(name), do: true
  defp row?(_other), do: false

  @doc "The sites whose name, host or line holds `query`, ignoring case; every site for an empty query."
  @spec matching([site()], String.t()) :: [site()]
  def matching(sites, query) do
    case query |> String.trim() |> String.downcase() do
      "" ->
        sites

      needle ->
        Enum.filter(
          sites,
          &String.contains?(String.downcase("#{&1.name} #{&1.host} #{&1[:sub]}"), needle)
        )
    end
  end

  @impl true
  def update(%{current_user: user} = assigns, socket) do
    sites = sites(user, assigns[:current_path])

    new_socket =
      socket
      |> assign(assigns)
      |> assign(:sites, sites)
      |> assign(:chosen, assigns[:admin_site] || AdminSite.chosen(user))
      |> assign_new(:query, fn -> "" end)

    {:ok, new_socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :query, query)}

  def handle_event("pick", %{"site" => chosen}, %{assigns: %{chosen: chosen}} = socket),
    do: {:noreply, socket}

  def handle_event("pick", %{"site" => chosen}, socket) do
    new_socket =
      case AdminSite.keep(socket.assigns.current_user, chosen) do
        :ok -> go(socket, chosen)
        {:error, :refused} -> socket
      end

    {:noreply, new_socket}
  end

  defp go(%{assigns: %{admin_site: following}} = socket, chosen) when is_binary(following) do
    send(self(), {:admin_site_chosen, chosen})
    socket
  end

  defp go(socket, _chosen) do
    to = socket.assigns[:current_path] || "/admin/dashboard"
    push_navigate(socket, to: to, replace: true)
  end

  defp name("all", _sites), do: gettext("All sites")
  defp name(id, sites), do: Enum.find_value(sites, "", &(&1.id == id && &1.name))

  defp total(sites) do
    case for(%{count: count} when is_integer(count) <- sites, do: count) do
      [] -> nil
      counts -> Enum.sum(counts)
    end
  end

  @impl true
  def render(%{sites: [_one, _another | _more]} = assigns) do
    assigns = assign(assigns, panel: "#{assigns.id}-panel", all: AdminSite.all())

    ~H"""
    <div
      id={@id}
      data-testid="site-switcher"
      class="relative"
      phx-click-away={JS.hide(to: "#" <> @panel)}
      phx-window-keydown={JS.hide(to: "#" <> @panel)}
      phx-key="escape"
    >
      <button
        type="button"
        data-testid="site-switcher-button"
        aria-haspopup="listbox"
        phx-click={JS.toggle(to: "#" <> @panel)}
        aria-label={gettext("Site: %{name}", name: name(@chosen, @sites))}
        class="flex h-[39px] items-center gap-[9px] rounded-[11px] border border-[#ecebe6] bg-white px-3 text-[12.5px] font-bold text-[#17161a] pointer-coarse:h-11 max-[640px]:size-11 max-[640px]:justify-center max-[640px]:gap-1 max-[640px]:px-0"
      >
        <svg
          width="15"
          height="15"
          viewBox="0 0 24 24"
          aria-hidden="true"
          class="flex-none fill-none stroke-[#5b57d6] stroke-[1.7] [stroke-linecap:round] [stroke-linejoin:round]"
        >
          <path d="M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18">
          </path>
        </svg>
        <span data-testid="site-switcher-name" class="max-[640px]:hidden">
          {name(@chosen, @sites)}
        </span>
        <.icon name="hero-chevron-down" class="size-3 flex-none text-[#5c5a54] max-[640px]:hidden" />
      </button>

      <div
        id={@panel}
        data-testid="site-switcher-panel"
        class="hidden absolute end-0 top-[46px] min-[641px]:pointer-coarse:top-[50px] z-50 w-[290px] max-w-[calc(100vw-24px)] rounded-[14px] border border-[#ecebe6] bg-white p-2 shadow-[0_14px_34px_rgba(30,28,24,0.14)] max-[640px]:fixed max-[640px]:inset-x-3 max-[640px]:top-[62px] max-[640px]:w-auto max-[640px]:max-w-none"
      >
        <div class="px-2 pb-2 pt-1.5 text-[12px] font-semibold leading-normal text-[#6f6d68]">
          {gettext(
            "A master sees every site and picks one or all of them. A site admin sees only their own site and has no switcher."
          )}
        </div>

        <form
          id={@id <> "-search"}
          phx-change="search"
          phx-submit="search"
          phx-target={@myself}
          class="mb-1.5 px-1"
        >
          <input
            type="search"
            name="query"
            value={@query}
            dir="auto"
            autocomplete="off"
            data-testid="site-switcher-search"
            placeholder={gettext("Search sites")}
            phx-debounce="150"
            class="h-9 w-full rounded-[10px] border border-[#ecebe6] bg-[#f7f6f3] px-3 text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0] pointer-coarse:h-11 max-[640px]:h-11 max-[640px]:text-[16px]"
          />
        </form>

        <div data-testid="site-switcher-list" role="listbox" class="max-h-[320px] overflow-y-auto">
          <.row
            :if={String.trim(@query) == ""}
            testid="site-switcher-all"
            pick={pick(@all, @myself, @panel)}
            chosen={@chosen == @all}
            name={gettext("All sites")}
            sub={
              ngettext(
                "%{count} site, seen as master",
                "%{count} sites, seen as master",
                length(@sites)
              )
            }
            count={total(@sites)}
          />
          <.row
            :for={site <- matching(@sites, @query)}
            testid={"site-switcher-site-#{site.id}"}
            pick={pick(site.id, @myself, @panel)}
            chosen={@chosen == site.id}
            name={site.name}
            sub={site[:sub]}
            count={site[:count]}
          />
          <p
            :if={matching(@sites, @query) == []}
            data-testid="site-switcher-empty"
            class="px-3 py-4 text-center text-[12.5px] font-semibold text-[#6f6d68]"
          >
            {gettext("No site matches")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns), do: ~H"<div id={@id} hidden></div>"

  defp pick(chosen, target, panel),
    do: "pick" |> JS.push(value: %{site: chosen}, target: target) |> JS.hide(to: "#" <> panel)

  attr :testid, :string, required: true
  attr :pick, JS, required: true
  attr :chosen, :boolean, required: true
  attr :name, :string, required: true
  attr :sub, :string, default: nil
  attr :count, :integer, default: nil

  defp row(assigns) do
    ~H"""
    <button
      type="button"
      role="option"
      phx-click={@pick}
      data-testid={@testid}
      aria-selected={to_string(@chosen)}
      class={[
        "flex w-full items-center gap-2.5 rounded-[10px] border-0 px-2.5 py-2 text-start pointer-coarse:min-h-11 max-[640px]:min-h-11",
        (@chosen && "bg-[#f2f1fc]") || "bg-transparent hover:bg-[#f7f6f3]"
      ]}
    >
      <span class={[
        "size-2 flex-none rounded-full",
        (@chosen && "bg-[#5b57d6]") || "bg-[#cfcdc6]"
      ]}></span>
      <span class="min-w-0 flex-1">
        <span class="block text-[12.5px] font-bold text-[#17161a]">{@name}</span>
        <span :if={@sub} class="block truncate text-[13px] font-medium text-[#6f6d68]">{@sub}</span>
      </span>
      <span
        :if={@count}
        data-testid={@testid <> "-count"}
        class="font-mono text-[12.5px] text-[#5c5a54]"
      >
        {@count}
      </span>
    </button>
    """
  end
end
