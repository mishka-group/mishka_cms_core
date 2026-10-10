defmodule MishkaCmsCoreWeb.Test.AccountFormCancelTest do
  @moduledoc """
  Cancel on the Users and Permissions pages' edit form closes the modal, as on every other page —
  it used to empty the form and leave the modal open, the forms having no `on_cancel` hook to tell
  the page.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaGervaz.Resource.Info.Form

  @password "Password123!"

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

    master =
      create_user_with_permissions!(["admin:dashboard:*"],
        password: @password,
        password_confirmation: @password
      )

    {:ok, conn: conn, site: site, master: master}
  end

  test "Cancel on a user's edit form closes the modal", ctx do
    writer = create_user!(site_id: ctx.site.id)
    view = open(ctx.conn, ctx.master, "/admin/dashboard/account/users")

    send(view.pid, {:row_action, "edit_user_modal", %{"id" => writer.id}})
    render_async(view)
    assert_push_event(view, "gervaz:exec-js", %{target: "user-details-modal"})

    cancel(view, User)

    assert_push_event(view, "gervaz:exec-js", %{target: "user-details-modal", js: js})
    assert js =~ "remove_class"
  end

  test "Cancel on a permission's edit form closes the modal", ctx do
    [permission] = ctx.master.permissions

    view = open(ctx.conn, ctx.master, "/admin/dashboard/account/permissions")

    send(view.pid, {:row_action, "edit_permission_modal", %{"id" => permission.id}})
    render_async(view)
    assert_push_event(view, "gervaz:exec-js", %{target: "permission-details-modal"})

    cancel(view, Permission)

    assert_push_event(view, "gervaz:exec-js", %{target: "permission-details-modal", js: js})
    assert js =~ "remove_class"
  end

  defp cancel(view, resource) do
    view
    |> element("##{Form.component_id(resource)}-form-wrapper button", "Cancel")
    |> render_click()
  end

  defp open(conn, user, path) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(path)

    view
  end
end
