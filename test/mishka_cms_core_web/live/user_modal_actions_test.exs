defmodule MishkaCmsCoreWeb.Test.UserModalActionsTest do
  @moduledoc """
  The Users page's account actions beside the user modal's close button and in the table's rows:
  Confirm account, for an account whose confirmation email never came, and Turn off two-step, for
  one that lost its authenticator app — which asks a current code from the admin's own authenticator,
  and sends an admin without one to set theirs up. Each is shown only when the policies let the
  admin run it on that account, and never Turn off two-step on the admin's own account, which takes
  a code on the Preferences tab.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.States.SiteState

  @users "/admin/dashboard/account/users"
  @password "Password123!"
  @confirm "#user-modal-confirm"

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

    {:ok, conn: conn, site: site}
  end

  describe "the user modal" do
    test "confirms an account whose email is not confirmed yet", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      writer = create_user!(site_id: ctx.site.id)
      view = open(ctx.conn, master)

      show(view, writer)
      view |> element(@confirm) |> render_click()
      render_async(view)

      refute has_element?(view, @confirm)
      assert reload(writer).confirmed_at
      assert render(view) =~ "The account is confirmed."
    end
  end

  describe "the Users table" do
    test "confirms an account from its row", ctx do
      master = admin!(nil, ["admin:dashboard:*"])
      writer = create_user!(site_id: ctx.site.id)
      view = open(ctx.conn, master)
      confirm = "button[phx-value-event=confirm_account][phx-value-id='#{writer.id}']"

      view |> element(confirm) |> render_click()

      refute has_element?(view, confirm)
      assert reload(writer).confirmed_at
    end
  end

  # ---------------------------------------------------------------------------------------------

  defp admin!(site, permissions) do
    create_user_with_permissions!(permissions,
      site_id: site && site.id,
      password: @password,
      password_confirmation: @password
    )
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

  defp show(view, user) do
    send(view.pid, {:row_action, "show_user_modal", %{"id" => user.id}})
    render_async(view)
  end

  defp reload(user), do: Ash.get!(User, user.id, tenant: user.site_id, authorize?: false)
end
