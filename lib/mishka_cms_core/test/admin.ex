# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Admin do
  @moduledoc """
  Admins, signed-in connections and the master `localhost` site, for a test that drives the admin
  through its LiveViews — the core's or an extension's.

      setup :serve_localhost!

  `serve_localhost!/1` caches a master `localhost` site, marks the CMS installed, saves one page on
  the site and signs `boss@example.com` in as a `*` admin of it, then hands the test
  `%{conn: conn, site: site, page: page}`. The rest build what a test needs beside that: an admin
  with other permissions (`create_admin/3`, `narrow_conn/2`), a user with none, a connection on
  another host, and the flashes a LiveView shows.

  The site cache (`MishkaCmsCore.Runtime.States.SiteState`) and the installed mark are the node's,
  not the test's sandbox, so a test using `serve_localhost!/1` is `async: false`.
  """

  import Phoenix.LiveViewTest, only: [element: 2, has_element?: 2, render: 1, render_click: 3]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Factory

  require Ash.Query

  @password "Password123!"

  @template ~s(<section id="hero"><h1>Contact Us</h1><p>Reach out any time.</p></section>)

  @doc """
  A setup callback: the master `localhost` site, created and cached, the CMS marked installed, one
  page on the site drawing the context's `:template` (a hero section when it has none), and the
  context's `conn` (a new one when it has none) on `localhost`, signed in as a `*` admin. Both
  marks are cleared when the test exits.
  """
  @spec serve_localhost!(map()) :: %{conn: Plug.Conn.t(), site: struct(), page: struct()}
  def serve_localhost!(context) do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

    site = Factory.create_site!(name: "localhost", host: "localhost", active: true, master: true)
    cache_site(site)
    :persistent_term.put(:mishka_installed, true)

    page =
      Factory.create_page!(site_id: site.id, template: Map.get(context, :template, @template))

    # `SiteState` is process-global ETS, not sandboxed, so a cached site outlives this test's
    # transaction. Leaving "localhost" behind breaks any sibling that asserts a host does NOT
    # resolve — which is exactly how it broke ApiTenantLookupPlugTest.
    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      context
      |> Map.get_lazy(:conn, &Phoenix.ConnTest.build_conn/0)
      |> on_host("localhost")

    %{conn: log_in(conn, create_admin("boss@example.com")), site: site, page: page}
  end

  @doc "Puts `site` in the site cache, as the runtime does when it loads it."
  @spec cache_site(struct()) :: term()
  def cache_site(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })
  end

  @doc "The permission named `name`, created when it does not exist yet."
  @spec permission!(String.t()) :: struct()
  def permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  @doc """
  A user registered with a password, on `site_id` (`nil` for a master user), holding
  `permissions` — every one by default.
  """
  @spec create_admin(String.t(), String.t() | nil, [String.t()]) :: struct()
  def create_admin(email, site_id \\ nil, permissions \\ ["*"]) do
    user = register!(email, site_id)

    for permission <- permissions do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
      |> Ash.create!(authorize?: false)
    end

    user
  end

  # A REAL USER WITH NOTHING GRANTED. `create_admin/3` assigns `*`, which passes every policy in
  # the CMS; what is wanted here is an actor the resource has no reason to allow.
  @doc "A registered master user holding no permission."
  @spec create_user_without_permissions(String.t()) :: struct()
  def create_user_without_permissions(email), do: register!(email, nil)

  @doc """
  A fresh connection on a site's own address, `localhost` unless told — `serve_localhost!/1`'s is
  already signed in.
  """
  @spec build_conn_for_host(String.t()) :: Plug.Conn.t()
  def build_conn_for_host(host \\ "localhost"), do: on_host(Phoenix.ConnTest.build_conn(), host)

  @doc "Signs `user` in on `conn`, in master mode."
  @spec log_in(Plug.Conn.t(), struct()) :: Plug.Conn.t()
  def log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @doc "A connection on `localhost` signed in as a new admin of `site` holding only `permissions`."
  @spec narrow_conn(struct(), [String.t()]) :: Plug.Conn.t()
  def narrow_conn(site, permissions) do
    admin =
      create_admin("n#{System.unique_integer([:positive])}@example.com", site.id, permissions)

    log_in(build_conn_for_host(), admin)
  end

  # WHATEVER IS ON SCREEN, both notices at once: a flash is the only place a refused command speaks
  # to the author, and which of the two it picks is not the point of the assertions that read it.
  # The tags come off first — Tailwind writes `hover:bg-white` into the class list, which reads
  # exactly like an inspected atom to anything looking for one.
  @doc "The text of the info and error flashes `view` shows, tags removed."
  @spec flashes(struct()) :: String.t()
  def flashes(view) do
    ["#flash-info", "#flash-error"]
    |> Enum.filter(&has_element?(view, &1))
    |> Enum.map_join(" ", &(view |> element(&1) |> render() |> String.replace(~r/<[^>]*>/, "")))
    |> String.trim()
  end

  # A flash is set, never unset: nothing on the server clears one, and the hook that pushes
  # `lv:clear-flash` after the fade does not run in a test — so a stale sentence would answer for
  # the next command and hide a handler that went silent.
  @doc "Clears both flashes of `view`, and answers `view`."
  @spec clear_flashes(struct()) :: struct()
  def clear_flashes(view) do
    for key <- ~w(info error), do: render_click(view, "lv:clear-flash", %{"key" => key})
    view
  end

  defp register!(email, site_id) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    user
  end

  defp on_host(conn, host) do
    conn
    |> Map.put(:host, host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
  end
end
