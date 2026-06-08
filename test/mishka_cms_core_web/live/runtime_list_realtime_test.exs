defmodule MishkaCmsCoreWeb.Test.RuntimeListRealtimeTest do
  @moduledoc """
  A runtime list open on a search while components are written elsewhere, driven through the real
  Components page — a table that takes Gervaz's own realtime path, with no `on_realtime` hook.

  A component the search does not match is neither shown nor counted, one that matches comes first
  and counts, and one renamed out of the search leaves the list. See
  `MishkaGervaz.Table.Web.DataLoader.in_view?/2` and `refresh_total/1`.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/runtime/components"
  @await 5_000

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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(create_admin!())

    {:ok, conn: conn, site: site, tag: "probe#{System.unique_integer([:positive])}"}
  end

  test "a component the search does not match is neither shown nor counted", %{
    conn: conn,
    site: site,
    tag: tag
  } do
    create_component!(site_id: site.id, name: "#{tag}-button-a")
    view = open(conn, "#{tag}-button")
    assert shown_total(view) == 1

    other = create_component!(site_id: site.id, name: "#{tag}-menu")
    settle(view)

    refute has_element?(view, row(other)), "a component the search excludes was shown"
    assert shown_total(view) == 1
  end

  test "a component the search matches comes first and counts", %{
    conn: conn,
    site: site,
    tag: tag
  } do
    create_component!(site_id: site.id, name: "#{tag}-button-a")
    view = open(conn, "#{tag}-button")

    matching = create_component!(site_id: site.id, name: "#{tag}-button-b")
    settle(view)

    assert first_row_id(view) == "components-table_components-#{matching.id}"
    assert shown_total(view) == 2
  end

  test "a component renamed out of the search leaves the list", %{
    conn: conn,
    site: site,
    tag: tag
  } do
    component = create_component!(site_id: site.id, name: "#{tag}-button-a")
    staying = create_component!(site_id: site.id, name: "#{tag}-button-b")
    view = open(conn, "#{tag}-button")
    assert has_element?(view, row(component))

    component
    |> Ash.Changeset.for_update(:master_update, %{name: "#{tag}-menu"}, authorize?: false)
    |> Ash.update!(authorize?: false)

    settle(view)

    refute has_element?(view, row(component)), "the renamed component stayed in the list"
    assert has_element?(view, row(staying))
    assert shown_total(view) == 1
  end

  defp open(conn, search) do
    {:ok, view, _html} = live(conn, @path <> "?components_search=" <> URI.encode(search))
    render_async(view, @await)
    view
  end

  defp settle(view) do
    _handled = :sys.get_state(view.pid)
    render_async(view, @await)
    view
  end

  defp row(component), do: "#components-table_components-#{component.id}"

  defp shown_total(view) do
    [_all, count] =
      Regex.run(~r/Showing (\d+)/, render(element(view, "#components-table-total")))

    String.to_integer(count)
  end

  defp first_row_id(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id^="components-table_components-"]))
    |> LazyHTML.attribute("id")
    |> Enum.find(&Regex.match?(~r/^components-table_components-[0-9a-f-]{36}$/, &1))
  end

  defp create_admin! do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "realtime-#{System.unique_integer([:positive])}@example.com",
          password: @password,
          password_confirmation: @password
        },
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!("*").id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
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
