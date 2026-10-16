# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.RedirectIndexTest do
  @moduledoc """
  The admin's Redirects page, driven through the real page: the Gervaz table of a site's redirect
  rules and the Gervaz form that writes them.

  Every dashboard admin reads the list; only a holder of the redirect section is offered what
  writes, and whose rules the table draws is decided by the actor — a master reads every site's, a
  site admin their own. The resource's own rules and policies are covered beside
  `MishkaCmsCore.Runtime.Redirect`; this is what an admin standing on the page gets from them.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsCore.Runtime.States.{RedirectsState, SiteState}

  require Ash.Query

  @moduletag :capture_log

  @password "Password123!"
  @path "/admin/dashboard/runtime/redirects"
  @await 5_000

  setup %{conn: conn} do
    SiteState.clear()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)
    other = create_site!()

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

    {:ok, conn: conn, site: site, other: other}
  end

  defp permission!(name) do
    Permission
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_permission!(name: name)
      permission -> permission
    end
  end

  defp admin!(permissions, site_id \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "redirects-#{n}@example.com",
          password: @password,
          password_confirmation: @password
        },
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    for name <- permissions do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(name).id)
      |> Ash.create!(authorize?: false)
    end

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, @path)
    render_async(view, @await)
    view
  end

  # A message the page is sent is handled after the event that sent it; this waits for it, and for
  # the form's record read and the table's reload it started.
  defp settle(view) do
    _handled = :sys.get_state(view.pid)
    render_async(view, @await)
    view
  end

  defp rule!(site, attrs),
    do: Ash.create!(Redirect, attrs, action: :create, tenant: site.id, authorize?: false)

  defp row(redirect), do: "#redirects-table_redirects-#{redirect.id}"

  defp stored(site) do
    Redirect
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: false)
  end

  test "draws the Gervaz table of rules under Add redirect", %{conn: conn, site: site} do
    redirect = rule!(site, %{from_path: "/images/blog/a.jpg", to: "/uploads/a.jpg"})

    view = conn |> log_in(admin!(["*"])) |> open()

    assert has_element?(view, "#redirects-table")
    assert has_element?(view, "#redirect-add")
    assert has_element?(view, row(redirect), "/images/blog/a.jpg")
    assert has_element?(view, row(redirect), "/uploads/a.jpg")
  end

  test "a site admin is shown their own site's rules, never another site's", %{
    conn: conn,
    site: site,
    other: other
  } do
    own = rule!(site, %{from_path: "/own", to: "/x"})
    elsewhere = rule!(other, %{from_path: "/elsewhere", to: "/x"})

    view = conn |> log_in(admin!(["admin:dashboard:*"], site.id)) |> open()

    assert has_element?(view, row(own))
    refute has_element?(view, row(elsewhere))
  end

  test "an admin of another area reads the list, with nothing that writes", %{
    conn: conn,
    site: site
  } do
    redirect = rule!(site, %{from_path: "/own", to: "/x"})

    view = conn |> log_in(admin!(["admin:dashboard:runtime:page"], site.id)) |> open()

    assert has_element?(view, row(redirect))
    refute has_element?(view, "#redirect-add")
    refute has_element?(view, "#{row(redirect)} button[title='Edit']")
  end

  test "a holder of the section adds a rule through the form, and it is served", %{
    conn: conn,
    site: site
  } do
    view = conn |> log_in(admin!(["admin:dashboard:runtime:redirect"], site.id)) |> open()

    view |> element("#redirect-add") |> render_click()
    settle(view)

    view
    |> element("#redirect_form-form")
    |> render_submit(%{
      "form" => %{
        "from_path" => "https://mishka.tools/images/blog/old.jpg?w=2",
        "to" => "/uploads/localhost/media/old.jpg",
        "status" => "308",
        "active" => "true"
      }
    })

    settle(view)

    assert [saved] = stored(site)
    assert saved.from_path == "/images/blog/old.jpg"
    assert saved.status == 308

    _handled = :sys.get_state(RedirectsState)

    assert RedirectsState.lookup(site.id, "/images/blog/old.jpg") ==
             {"/uploads/localhost/media/old.jpg", 308}

    assert has_element?(view, row(saved))
  end

  test "Add redirect after a close that sent the form nothing opens it empty", %{
    conn: conn,
    site: site
  } do
    redirect = rule!(site, %{from_path: "/kept", to: "/there"})
    view = conn |> log_in(admin!(["admin:dashboard:runtime:redirect"], site.id)) |> open()

    view |> element("#redirect-add") |> render_click()
    settle(view)

    view
    |> element("#redirect_form-form")
    |> render_change(%{
      "form" => %{"from_path" => "/half-typed"},
      "_target" => ["form", "from_path"]
    })

    assert has_element?(view, ~s(#redirect_form-form_from_path[value="/half-typed"]))

    view |> element("#redirect-add") |> render_click()
    settle(view)

    assert has_element?(view, "#redirect_form-form[method=post]")
    refute has_element?(view, ~s(#redirect_form-form_from_path[value="/half-typed"]))

    view |> element("#{row(redirect)} button[title='Edit']") |> render_click()
    settle(view)

    view
    |> element("#redirect_form-form")
    |> render_change(%{"form" => %{"to" => "/unsaved"}, "_target" => ["form", "to"]})

    view |> element("#{row(redirect)} button[title='Edit']") |> render_click()
    settle(view)

    assert has_element?(view, ~s(#redirect_form-form_to[value="/there"]))

    view |> element("#redirect-add") |> render_click()
    settle(view)

    assert has_element?(view, "#redirect_form-form[method=post]")
    refute has_element?(view, ~s(#redirect_form-form_from_path[value="/kept"]))
  end

  test "Edit opens the rule in the form, and a save changes it", %{conn: conn, site: site} do
    redirect = rule!(site, %{from_path: "/old", to: "/new"})
    view = conn |> log_in(admin!(["admin:dashboard:runtime:redirect"], site.id)) |> open()

    view |> element("#{row(redirect)} button[title='Edit']") |> render_click()
    settle(view)

    view
    |> element("#redirect_form-form")
    |> render_submit(%{"form" => %{"to" => "/newer", "status" => "302"}})

    settle(view)

    assert [%{id: id, from_path: "/old", to: "/newer", status: 302}] = stored(site)
    assert id == redirect.id

    _handled = :sys.get_state(RedirectsState)
    assert RedirectsState.lookup(site.id, "/old") == {"/newer", 302}
  end

  test "a rule that would loop is refused on the form, and nothing is stored", %{
    conn: conn,
    site: site
  } do
    rule!(site, %{from_path: "/a", to: "/b"})
    view = conn |> log_in(admin!(["admin:dashboard:runtime:redirect"], site.id)) |> open()

    view |> element("#redirect-add") |> render_click()
    settle(view)

    html =
      view
      |> element("#redirect_form-form")
      |> render_submit(%{"form" => %{"from_path" => "/b", "to" => "/a", "status" => "301"}})

    settle(view)

    assert html =~ "loop"
    assert Enum.map(stored(site), & &1.from_path) == ["/a"]
  end
end
