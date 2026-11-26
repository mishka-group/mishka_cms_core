# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Accounts.AdminSite do
  @moduledoc """
  The site a master's admin pages show: one site, or every site at once.

  A site user (a user with a `site_id`) belongs to one site, and every admin page reads and writes
  that site. A master (`site_id` nil) belongs to none and picks in the admin top bar: one site, or
  **All sites**. The pick is the master's own preference (`setting/0`, through
  `MishkaCmsCore.Settings.put_user/3`), so it holds for every page, a reload and a new tab. It is
  the one place a site switcher writes (`keep/2`) and every page reads (`chosen/1`), so two pages
  never disagree on which site the master is looking at.

  An admin page follows the pick with one line, `on_mount MishkaCmsCore.Accounts.AdminSite`:

    * with one site picked, the page gets the master as the admin of that site: `current_user`
      has the site's `site_id` and its `site` loaded, so every read of the page and every
      mishka_gervaz table on it is that site's alone, and the page draws itself as for a site
      admin (no site picker, the site's own topics);
    * with All sites, or nothing picked yet, the master is left as they are (`site_id` nil): reads
      go across sites (`:master_read`) and gervaz labels each row with its site;
    * a site user is left as they are, whatever a master picked.

  The page also gets `:admin_site`: `"all"` (`all/0`) or the id of the site it shows.

  A pick made on one page reaches every other open admin page of the same master on `topic/1`,
  and those pages mount again where they are (`push_navigate/2`, `replace: true`), live and without
  reloading the browser's page.

  Reading the pick runs no query: the preference comes from the settings cache and the site from
  `MishkaCmsCore.Runtime.States.SiteState`. A page with one site picked loads that site once, for
  `current_user.site`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_navigate: 2]

  alias MishkaCmsCore.Runtime.Site
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  require Ash.Query

  @setting "admin.site"
  @all "all"
  @message :admin_site_chosen

  @doc "The key of the master's own preference that holds the site they picked."
  @spec setting() :: String.t()
  def setting, do: @setting

  @doc "The pick that means every site."
  @spec all() :: String.t()
  def all, do: @all

  @doc "The topic every open admin page of the master `user_id` hears their pick on."
  @spec topic(String.t()) :: String.t()
  def topic(user_id), do: "admin:site:#{user_id}"

  @doc """
  The site `user`'s admin pages show: a site user's own site; for a master, the active site they
  picked, else `"all"` (All sites, nothing picked, or a picked site that is gone or inactive);
  `nil` for nobody.
  """
  @spec chosen(map() | nil) :: String.t() | nil
  def chosen(%{site_id: nil, id: user_id}) do
    case Settings.get_user(@setting, user_id) do
      site_id when is_binary(site_id) and site_id != @all ->
        (active?(site_id) && site_id) || @all

      _all_or_nothing ->
        @all
    end
  end

  def chosen(%{site_id: site_id}) when is_binary(site_id), do: site_id
  def chosen(_nobody), do: nil

  @doc """
  Keeps `chosen` (`"all"` or an active site's id) as what master `user` looks at, and tells their
  other open admin pages (`topic/1`). Anybody else, or any other value, is `{:error, :refused}`
  and nothing is written. One write.
  """
  @spec keep(map() | nil, String.t()) :: :ok | {:error, :refused}
  def keep(%{site_id: nil, id: user_id}, chosen) when is_binary(chosen) do
    with true <- chosen == @all or active?(chosen),
         {:ok, _kept} <- Settings.put_user(@setting, chosen, user_id) do
      Phoenix.PubSub.broadcast_from(
        MishkaCmsCore.PubSub,
        self(),
        topic(user_id),
        {@message, chosen}
      )

      :ok
    else
      _refused -> {:error, :refused}
    end
  end

  def keep(_user, _chosen), do: {:error, :refused}

  @doc false
  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{site_id: nil} = master -> {:cont, follow(socket, master)}
      user -> {:cont, assign(socket, :admin_site, chosen(user))}
    end
  end

  defp follow(socket, master) do
    chosen = chosen(master)

    socket
    |> assign(:current_user, as_admin_of(master, chosen))
    |> assign(:admin_site, chosen)
    |> hear_picks(master)
  end

  defp as_admin_of(master, @all), do: master

  defp as_admin_of(master, site_id) do
    site =
      Site
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(id == ^site_id)
      |> Ash.read_one!(authorize?: false)

    %{master | site_id: site_id, site: site}
  end

  defp hear_picks(socket, master) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic(master.id))
      attach_hook(socket, :admin_site, :handle_info, &picked_elsewhere/2)
    else
      socket
    end
  end

  defp picked_elsewhere({@message, chosen}, %{assigns: %{admin_site: chosen}} = socket),
    do: {:halt, socket}

  defp picked_elsewhere({@message, _another}, socket) do
    to = socket.assigns[:current_path] || "/admin/dashboard"
    new_socket = push_navigate(socket, to: to, replace: true)
    {:halt, new_socket}
  end

  defp picked_elsewhere(_message, socket), do: {:cont, socket}

  defp active?(site_id) do
    match?({:ok, %{active: true}}, SiteState.get(site_id))
  end
end
