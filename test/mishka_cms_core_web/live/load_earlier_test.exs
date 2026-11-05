# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.LoadEarlierTest do
  @moduledoc """
  A Load more list opened past its first page (`?notifs_page=3`) offers Load earlier above its rows,
  and a page past the last (`?notifs_page=999`) says so and offers a way back to page 1, as the
  notification inbox and the activity page draw them.

  Both need the Load earlier of a mishka_gervaz after 0.0.4, so they are tagged `:gervaz_load_earlier`
  and `test_helper.exs` leaves them out against a gervaz without it.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :gervaz_load_earlier
  @password "Password123!"
  @inbox "/admin/dashboard/notifications"

  setup %{conn: conn} do
    SiteState.clear()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    admin = create_admin("earlier@example.com")
    for n <- 1..45, do: Notify.deliver({:user, admin.id}, %{type: "test:x", title: "Ping #{n}"})

    {:ok, conn: log_in(conn, admin), admin: admin, site: site}
  end

  describe "the notification inbox" do
    test "opened at page 3 offers Load earlier, which brings the page before it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @inbox <> "?notifs_page=3")
      render_async(view)

      assert has_element?(view, "button[phx-click='load_earlier']", "Load earlier")
      assert count_rows(view) == 5
      assert label(view) =~ "Showing 41–45 of 45"

      view |> element("button[phx-click='load_earlier']") |> render_click()
      render_async(view)

      assert count_rows(view) == 25
      assert label(view) =~ "Showing 21–45 of 45"
    end

    test "the first page offers no Load earlier", %{conn: conn} do
      {:ok, view, _html} = live(conn, @inbox)
      render_async(view)

      refute has_element?(view, "button[phx-click='load_earlier']")
      assert has_element?(view, "button[phx-click='load_more']", "Load More")
    end

    test "a page past the last says so and Go to page 1 brings the rows back", %{conn: conn} do
      {:ok, view, _html} = live(conn, @inbox <> "?notifs_page=999")
      render_async(view)

      assert count_rows(view) == 0
      assert render(view) =~ "No rows on this page"
      refute render(view) =~ "You have no notifications"
      assert label(view) =~ "Showing 0 of 45"

      view |> element("button", "Go to page 1") |> render_click()
      render_async(view)

      assert count_rows(view) == 20
      refute render(view) =~ "No rows on this page"
    end
  end

  describe "the activity page" do
    @activity "/admin/dashboard/runtime/activity"

    setup %{site: site} do
      for _n <- 1..25, do: create_media!(site_id: site.id)
      :ok
    end

    test "opened at page 2 offers Load earlier, which brings the page before it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @activity <> "?activity_page=2")
      render_async(view)

      assert has_element?(view, "button[phx-click='load_earlier']", "Load earlier")
      assert label(view) =~ ~r/\b\d+ of \d+ shown/
      shown = shown(view)

      view |> element("button[phx-click='load_earlier']") |> render_click()
      render_async(view)

      assert shown(view) > shown
      refute has_element?(view, "button[phx-click='load_earlier']")
    end

    test "a page past the last says so and Go to page 1 brings the rows back", %{conn: conn} do
      {:ok, view, _html} = live(conn, @activity <> "?activity_page=999")
      render_async(view)

      assert render(view) =~ "No rows on this page"
      refute render(view) =~ "No matching events"
      assert shown(view) == 0

      view |> element("button", "Go to page 1") |> render_click()
      render_async(view)

      refute render(view) =~ "No rows on this page"
      assert shown(view) > 0
    end

    defp shown(view) do
      [_, shown] = Regex.run(~r/\b(\d+) of [\d,]+\+? shown/, label(view))
      String.to_integer(shown)
    end
  end

  defp count_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='nrow']")
    |> Enum.count()
  end

  defp label(view), do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp create_admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
