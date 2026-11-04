# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.UserBulkConfirmTest do
  @moduledoc """
  The Users table's Confirm email bulk action: it confirms the users picked, for a master or a site
  admin within their own site, leaves an account that was confirmed already as it was, and tells
  the admin how many it changed. The action is `:confirm_pending`, so a user without the user
  area is refused by its policy.
  """
  use MishkaCmsCore.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.States.SiteState

  @users "/admin/dashboard/account/users"
  @password "Password123!"
  @bulk ~s(button[phx-click="bulk_action"][phx-value-action="confirm_email"])

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

    {:ok, conn: conn, site: site, other: create_site!(active: true)}
  end

  test "a site admin confirms the users picked and leaves the confirmed one as it was", ctx do
    admin = admin!(ctx.site, ["admin:dashboard:user"])
    first = create_user!(site_id: ctx.site.id)
    second = create_user!(site_id: ctx.site.id)
    confirmed = create_user!(site_id: ctx.site.id) |> confirm!()
    before = confirmed.confirmed_at

    view = open(ctx.conn, admin)
    for user <- [first, second, confirmed], do: pick(view, user)

    view |> element(@bulk) |> render_click()
    render_async(view)

    assert reload(first).confirmed_at
    assert reload(second).confirmed_at
    assert reload(confirmed).confirmed_at == before
    assert render(view) =~ "The email of 3 users is confirmed."
  end

  test "a master confirms the users of any site", ctx do
    master = admin!(nil, ["admin:dashboard:*"])
    here = create_user!(site_id: ctx.site.id)
    there = create_user!(site_id: ctx.other.id)

    view = open(ctx.conn, master)
    for user <- [here, there], do: pick(view, user)

    view |> element(@bulk) |> render_click()
    render_async(view)

    assert reload(here).confirmed_at
    assert reload(there).confirmed_at
  end

  test "a site admin does not see, and so cannot confirm, another site's users", ctx do
    admin = admin!(ctx.site, ["admin:dashboard:user"])
    stranger = create_user!(site_id: ctx.other.id)

    view = open(ctx.conn, admin)
    refute has_element?(view, "#users-table_users-#{stranger.id}")

    assert {:error, %Ash.Error.Forbidden{}} =
             stranger
             |> Ash.Changeset.for_update(:confirm_pending, %{},
               actor: admin,
               tenant: ctx.other.id
             )
             |> Ash.update()

    refute reload(stranger).confirmed_at
  end

  test "the action is refused to a user without the user area", ctx do
    nobody = admin!(ctx.site, ["admin:dashboard:blog:*"])
    target = create_user!(site_id: ctx.site.id)

    User
    |> Ash.Query.filter(id == ^target.id)
    |> Ash.bulk_update(:confirm_pending, %{},
      actor: nobody,
      tenant: ctx.site.id,
      strategy: :stream,
      return_errors?: true
    )

    refute reload(target).confirmed_at
  end

  defp pick(view, user),
    do:
      view
      |> element(~s(#users-table_users-#{user.id} input[phx-click="toggle_select"]))
      |> render_click()

  defp admin!(site, permissions) do
    create_user_with_permissions!(permissions,
      site_id: site && site.id,
      password: @password,
      password_confirmation: @password
    )
  end

  defp confirm!(user) do
    user
    |> Ash.Changeset.for_update(:confirm_by_admin, %{}, tenant: user.site_id, authorize?: false)
    |> Ash.update!()
  end

  defp open(conn, user) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(@users)

    render_async(view)
    view
  end

  defp reload(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)
end
