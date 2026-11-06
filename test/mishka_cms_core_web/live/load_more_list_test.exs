# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.LoadMoreListTest do
  @moduledoc """
  The Load more lists of the notification inbox and the activity page, driven as a reader drives
  them.

  Each ends with the one footer of every Load more list in the admin: the page-size picker first,
  Load More in the middle and the rows shown last; on the activity page, the events shown first and
  the last page shown last, which the footer reads from the table's state alone.

  A list opened past its first page (`?notifs_page=3`) offers Load earlier above its rows, and a
  page past the last (`?notifs_page=999`) says so and offers a way back to page 1. Both need the Load
  earlier of a mishka_gervaz after 0.0.4, so those tests are tagged `:gervaz_load_earlier` and
  `test_helper.exs` leaves them out against a gervaz without it.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Notify
  alias MishkaCmsCore.Runtime.States.SiteState

  @password "Password123!"
  @inbox "/admin/dashboard/notifications"
  @activity "/admin/dashboard/runtime/activity"

  # The reads one Load more on the activity page makes: the count capped at
  # `MishkaCmsCore.Activity.Query.max_cap/0`, the page of events, the sites its rows name and the
  # events of each day shown.
  @load_more_reads 4

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
    @describetag :gervaz_load_earlier

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
    @describetag :gervaz_load_earlier

    setup :create_events

    test "opened at page 2 offers Load earlier, which brings the page before it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @activity <> "?activity_page=2")
      render_async(view)

      assert has_element?(view, "button[phx-click='load_earlier']", "Load earlier")
      assert {21, _last} = shown(view)

      view |> element("button[phx-click='load_earlier']") |> render_click()
      render_async(view)

      assert {1, _last} = shown(view)
      refute has_element?(view, "button[phx-click='load_earlier']")
    end

    test "a page past the last says so and Go to page 1 brings the rows back", %{conn: conn} do
      {:ok, view, _html} = live(conn, @activity <> "?activity_page=999")
      render_async(view)

      assert render(view) =~ "No rows on this page"
      refute render(view) =~ "No matching events"
      assert shown(view) == nil

      view |> element("button", "Go to page 1") |> render_click()
      render_async(view)

      refute render(view) =~ "No rows on this page"
      assert {1, _last} = shown(view)
    end
  end

  describe "the inbox footer" do
    test "puts the page-size picker, Load More and the rows shown in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, @inbox)
      render_async(view)

      assert [{"leading", leading}, {"center", center}, {"trailing", trailing}] = footer(view)
      assert has?(leading, "select[name='size']")
      assert has?(center, "button[phx-click='load_more']")
      assert text(center) == "Load More"
      assert text(trailing) == "Showing 1–20 of 45"

      view |> element("button[phx-click='load_more']") |> render_click()
      render_async(view)

      assert [_leading, _center, {"trailing", trailing}] = footer(view)
      assert text(trailing) == "Showing 1–40 of 45"
    end

    test "draws no Load More once every row is shown", %{conn: conn} do
      {:ok, view, _html} = live(conn, @inbox)
      render_async(view)

      for _page <- 1..2 do
        view |> element("button[phx-click='load_more']") |> render_click()
        render_async(view)
      end

      assert [_leading, {"center", center}, {"trailing", trailing}] = footer(view)
      refute has?(center, "button")
      assert text(trailing) == "Showing 1–45 of 45"
    end
  end

  describe "the activity footer" do
    setup :create_events

    test "counts the events shown, offers Load more events and names the last page shown", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @activity)
      render_async(view)

      assert [{"leading", leading}, {"center", center}, {"trailing", trailing}] = footer(view)
      assert text(leading) =~ ~r/^Showing 1–20 of [\d,]+\+?$/
      assert has?(center, "button[phx-click='load_more']")
      assert text(center) == "Load more events"
      assert text(trailing) == "Page 1"

      view |> element("button[phx-click='load_more']") |> render_click()
      render_async(view)

      assert [{"leading", leading}, _center, {"trailing", trailing}] = footer(view)
      assert text(leading) =~ ~r/^Showing 1–\d+ of [\d,]+\+?$/
      refute text(leading) =~ "Showing 1–20 "
      assert text(trailing) == "Page 2"
    end

    test "names the page from the state, so Load more makes the reads it made without it", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @activity)
      render_async(view)

      {_html, more} =
        queries(view, fn ->
          view |> element("button[phx-click='load_more']") |> render_click()
          render_async(view)
        end)

      assert [_leading, _center, {"trailing", trailing}] = footer(view)
      assert text(trailing) == "Page 2"
      assert length(more) == @load_more_reads
    end
  end

  defp create_events(%{site: site}) do
    for _n <- 1..25, do: create_media!(site_id: site.id)
    :ok
  end

  # `{first, last}` of `Showing first–last of total` over the activity filter row, `nil` for
  # `Showing 0 of total`.
  defp shown(view) do
    case Regex.run(~r/Showing (\d+)–(\d+) of/, label(view)) do
      [_, first, last] -> {String.to_integer(first), String.to_integer(last)}
      nil -> nil
    end
  end

  defp footer(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='gervaz-pagination'] > [data-role]")
    |> Enum.map(fn part ->
      "gervaz-pagination-" <> name = part |> LazyHTML.attribute("data-role") |> hd()
      {name, part}
    end)
  end

  defp text(part), do: part |> LazyHTML.text() |> String.trim()

  defp has?(part, selector), do: part |> LazyHTML.query(selector) |> Enum.count() > 0

  # The queries the page's LiveView, and the tasks it starts, run while `fun` runs.
  defp queries(view, fun) do
    handler = "load-more-list-#{System.unique_integer([:positive])}"
    test = self()
    page = view.pid

    :telemetry.attach(
      handler,
      [:mishka_cms_core, :repo, :query],
      fn _event, _measurements, %{query: sql}, _config ->
        if self() == page or page in (Process.get(:"$callers") || []),
          do: send(test, {:sql, handler, sql})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)

    {result, collect(handler, [])}
  end

  defp collect(handler, sqls) do
    receive do
      {:sql, ^handler, sql} -> collect(handler, [sql | sqls])
    after
      0 -> Enum.reverse(sqls)
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
