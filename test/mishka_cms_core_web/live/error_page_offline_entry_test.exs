defmodule MishkaCmsCoreWeb.Test.ErrorPageOfflineEntryTest do
  @moduledoc """
  The offline page in the Error Pages admin, as a site's own admin uses it: the form offers it next to
  404 and 500 and saves it, the builder adds it, and the preview's error-code picker shows it.

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

  test "each entry's status offers the offline page next to 404 and 500", %{conn: conn, row: row} do
    view = edit(conn, row)

    for status <- ["offline", "404", "500"] do
      assert has_element?(view, "select[name*='[status]'] option[value='#{status}']"),
             "the status select does not offer #{status}"
    end

    assert has_element?(view, "select[name*='[status]'] option[value='404'][selected]")
  end

  test "an entry saved as the offline page is stored as :offline", %{conn: conn, row: row} do
    view = edit(conn, row)
    form = form_id(view)

    view
    |> element("##{form}")
    |> render_submit(%{
      "form" => %{
        "error_pages" => %{
          "0" => %{"status" => "404", "template" => "<p>Not here</p>"},
          "1" => %{"status" => "offline", "template" => "<p>Soon</p>"}
        }
      }
    })

    assert Enum.map(stored(row).error_pages, &{&1.status, &1.template}) == [
             {404, "<p>Not here</p>"},
             {:offline, "<p>Soon</p>"}
           ]
  end

  # The builder opens a status the row lacks empty, and saving what is built there writes the entry
  # beside the others.
  test "the builder adds the offline page beside the row's entries", %{conn: conn, row: row} do
    {:ok, builder, _html} = live(conn, "/admin/dashboard/runtime/builder/error-page/#{row.id}")
    refute has_element?(builder, "#pb-status-offline")

    assert {:error, {:live_redirect, %{to: to}}} =
             builder |> element("#pb-status-add-offline") |> render_click()

    {:ok, builder, _html} = live(conn, to)
    assert has_element?(builder, "#pb-status-offline")

    render_click(builder, "drop", %{
      "template" => "<h1>Back soon</h1>",
      "parent_id" => "root",
      "index" => "0"
    })

    render_click(builder, "publish", %{})

    assert Map.new(stored(row).error_pages, &{&1.status, &1.template}) |> Map.take([404, 500]) ==
             %{404 => "<p>Not here</p>", 500 => "<p>Broke</p>"}

    assert Enum.find(stored(row).error_pages, &(&1.status == :offline)).template =~ "Back soon"
  end

  # The picker used to read its status with `String.to_integer/1`, so choosing `offline` took the
  # whole page down.
  test "the preview's error-code picker shows the offline page", %{conn: conn, row: row} do
    row
    |> Ash.Changeset.for_update(
      :update,
      %{
        error_pages: [
          %{status: 404, template: "<p>Not here</p>"},
          %{status: :offline, template: "<p>Soon</p>"}
        ]
      },
      tenant: row.site_id,
      authorize?: false
    )
    |> Ash.update!()

    {:ok, view, _html} = live(conn, @path)
    send(view.pid, {:row_action, "show_preview_modal", %{"id" => row.id}})
    render_async(view, 5_000)
    render_click(view, "preview_set_tab", %{"tab" => "preview"})
    render_async(view, 5_000)

    assert has_element?(view, "button[phx-click='preview_set_error'][phx-value-status='offline']")

    render_click(view, "preview_set_error", %{"status" => "offline"})

    assert has_element?(view, "[id^='runtime-preview-live-#{row.id}-'][id*='-offline-']")
  end

  defp form_id(_view), do: MishkaGervaz.Resource.Info.Form.component_id(ErrorPage) <> "-form"
end
