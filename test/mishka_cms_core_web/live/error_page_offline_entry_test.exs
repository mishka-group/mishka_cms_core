# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.ErrorPageOfflineEntryTest do
  @moduledoc """
  The offline page and the default page in the Error Pages admin, as a site's own admin uses them: the
  form offers them next to 404 and 500 and saves them, and the preview's error-code picker shows them.

  Its own file: nothing else drives the Error Pages index as a LiveView.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{ErrorAddress, ErrorPage}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/runtime/error-pages"

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
      |> log_in(create_admin("tenant@example.com", site.id))

    row =
      ErrorPage
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "localhost errors",
          path: ErrorAddress.path(site.name),
          error_pages: [
            %{status: 404, template: "<p>Not here</p>"},
            %{status: 500, template: "<p>Broke</p>"}
          ]
        },
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

    {:ok, conn: conn, site: site, row: row}
  end

  defp star_permission do
    Permission
    |> Ash.Query.filter(name == "*")
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_permission!(name: "*")
      permission -> permission
    end
  end

  defp create_admin(email, site_id) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.Changeset.set_tenant(site_id)
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The row's pencil, which opens the inspector on its Configuration form.
  defp edit(conn, row) do
    {:ok, view, _html} = live(conn, @path)
    send(view.pid, {:row_action, "edit_preview_modal", %{"id" => row.id}})
    render_async(view, 5_000)
    view
  end

  defp stored(row), do: Ash.get!(ErrorPage, row.id, tenant: row.site_id, authorize?: false)

  test "each entry's status offers the offline and default pages next to 404 and 500", %{
    conn: conn,
    row: row
  } do
    view = edit(conn, row)

    for status <- ["offline", "default", "404", "500"] do
      assert has_element?(view, "select[name*='[status]'] option[value='#{status}']"),
             "the status select does not offer #{status}"
    end

    assert has_element?(view, "select[name*='[status]'] option[value='404'][selected]")
  end

  test "entries saved as the offline and default pages are stored as :offline and :default", %{
    conn: conn,
    row: row
  } do
    view = edit(conn, row)
    form = form_id(view)

    view
    |> element("##{form}")
    |> render_submit(%{
      "form" => %{
        "error_pages" => %{
          "0" => %{"status" => "404", "template" => "<p>Not here</p>"},
          "1" => %{"status" => "offline", "template" => "<p>Soon</p>"},
          "2" => %{"status" => "default", "template" => "<p>Went wrong</p>"}
        }
      }
    })

    assert Enum.map(stored(row).error_pages, &{&1.status, &1.template}) == [
             {404, "<p>Not here</p>"},
             {:offline, "<p>Soon</p>"},
             {:default, "<p>Went wrong</p>"}
           ]
  end

  test "the list shows the default entry among the row's codes", %{conn: conn, row: row} do
    update!(row, [
      %{status: :default, template: "<p>Went wrong</p>"},
      %{status: 404, template: "<p>Not here</p>"}
    ])

    {:ok, view, _html} = live(conn, @path)
    assert render_async(view, 5_000) =~ "404, default"
  end

  # The picker used to read its status with `String.to_integer/1`, so choosing `offline` took the
  # whole page down.
  test "the preview's error-code picker shows the offline and default pages", %{
    conn: conn,
    row: row
  } do
    update!(row, [
      %{status: 404, template: "<p>Not here</p>"},
      %{status: :offline, template: "<p>Soon</p>"},
      %{status: :default, template: "<p>Went wrong</p>"}
    ])

    {:ok, view, _html} = live(conn, @path)
    send(view.pid, {:row_action, "show_preview_modal", %{"id" => row.id}})
    render_async(view, 5_000)
    render_click(view, "preview_set_tab", %{"tab" => "preview"})
    render_async(view, 5_000)

    for status <- ["offline", "default"] do
      assert has_element?(
               view,
               "button[phx-click='preview_set_error'][phx-value-status='#{status}']"
             )

      render_click(view, "preview_set_error", %{"status" => status})

      assert has_element?(view, "[id^='runtime-preview-live-#{row.id}-'][id*='-#{status}-']")
    end
  end

  defp update!(row, entries) do
    row
    |> Ash.Changeset.for_update(:update, %{error_pages: entries},
      tenant: row.site_id,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp form_id(_view), do: MishkaGervaz.Resource.Info.Form.component_id(ErrorPage) <> "-form"
end
