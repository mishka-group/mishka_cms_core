defmodule MishkaCmsCoreWeb.Test.RuntimeInspectorModalTest do
  @moduledoc """
  The one modal every runtime table opens, driven through the real page.

  Two things are being pinned here, and both are about what a click costs.

  **A look is not an edit.** Clicking the eye used to be the only way into the inspector, and editing
  meant a second, separate `<resource>-form-modal` sitting on the same page. That is one form
  component too many: `MishkaGervaz.Form.Web.Live` reads the row and every relation's options the
  moment it mounts, so the page paid for an edit nobody had asked for — and the two mounts of the
  same component collided on their DOM id. The form now lives on the modal's Configuration tab and
  mounts on the FIRST visit to it, which is why every test below checks the form's absence before it
  checks its presence.

  **The pencil has to reach it.** For Component/Layout/Page/ErrorPage the pencil was a
  `type :edit` row action, which sends `{:edit_modal, id}` to the parent LiveView — a message none of
  those four pages had a clause for. The clicks below go through the rendered button rather than a
  hand-sent message, so the resource's own DSL is part of what is under test.

  See `MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers` and
  `MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal`.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Component, ErrorPage, Layout, Page, Site}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

  # The modal's open load is a record read plus its drafts and a page of versions; the 100ms default
  # is a statement about nothing.
  @await 5_000

  setup %{conn: conn} do
    SiteState.clear()
    Application.put_env(:ash_json_api, MishkaCmsCore.Accounts, router: MishkaCmsWeb.Router)

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

    admin = create_admin("inspector-#{unique()}@example.com")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(admin)

    {:ok, conn: conn, site: site, admin: admin}
  end

  # The form component's own root element, which only exists once it has been mounted. Its loading
  # skeleton lives inside this same wrapper, so the wrapper is present the moment the component is —
  # exactly the question these tests ask.
  defp form_wrapper(resource),
    do: "#" <> MishkaGervaz.Resource.Info.Form.component_id(resource) <> "-form-wrapper"

  # The pencil, as the table actually renders it: an `:event` row action is a button carrying its
  # event name, so clicking this drives resource DSL → table component → parent LiveView.
  defp pencil(table, event), do: ~s(##{table} button[phx-value-event="#{event}"])

  describe "the sites table's details modal" do
    test "the eye opens it without mounting the form, and the tab mounts it", %{
      conn: conn,
      site: site
    } do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/sites")

      send(view.pid, {:row_action, "show_site_modal", %{"id" => site.id}})
      render_async(view, @await)

      refute has_element?(view, form_wrapper(Site)),
             "a look at a site mounted its edit form"

      render_click(view, "site_modal_set_tab", %{"tab" => "configuration"})

      assert has_element?(view, form_wrapper(Site)),
             "the Configuration tab did not mount the site form"
    end

    test "the pencil opens it straight on Configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/sites")
      render_async(view, @await)

      view |> element(pencil("sites-table", "edit_site_modal")) |> render_click()
      render_async(view, @await)

      assert has_element?(view, form_wrapper(Site)),
             "the pencil did not reach the site's Configuration tab"
    end
  end

  defp unique, do: System.unique_integer([:positive])

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

  defp create_admin(email, site_id \\ nil, permissions \\ ["*"]) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    for permission <- permissions do
      UserPermission
      |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
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
end
