# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.HeadCodeModalTest do
  @moduledoc """
  The Pages screen's "Head code" modal, driven through the real page: a master holding the section
  opens it, writes an entry through its Gervaz form and sees it served, reads what extensions add,
  and finds the entries that reach a page on that page's Configuration tab. A site admin is not
  offered it.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{HeadCode, HeadCodes}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.HeadCodeItems
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @moduletag :capture_log

  @password "Password123!"
  @path "/admin/dashboard/runtime/pages"
  @await 5_000
  @plausible ~s(<script defer src="https://plausible.io/js/script.js"></script>)

  setup %{conn: conn} do
    snapshot = SiteState.snapshot()
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
      SiteState.restore(snapshot)
    end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
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
          email: "head-code-#{n}@example.com",
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

  defp settle(view) do
    _handled = :sys.get_state(view.pid)
    render_async(view, @await)
    view
  end

  defp entry!(site, attrs \\ %{}) do
    Ash.create!(
      HeadCode,
      Map.merge(%{site_id: site.id, name: "Plausible", code: @plausible, published: true}, attrs),
      action: :master_create,
      authorize?: false
    )
  end

  defp open_head_code(view) do
    view |> element("#head-code-open") |> render_click()
    settle(view)
  end

  test "a master of the section adds an entry through the form, and it is served", %{
    conn: conn,
    site: site
  } do
    view = conn |> log_in(admin!(["*"])) |> open() |> open_head_code()

    assert has_element?(view, "#head-codes-table")

    view |> element("#head-code-add") |> render_click()
    settle(view)

    view
    |> element("#head_code_form-form")
    |> render_submit(%{
      "form" => %{
        "site_id" => site.id,
        "name" => "Plausible",
        "code" => @plausible <> ~s|<div onclick="x()">no</div>|,
        "scope" => "all",
        "origins" => ["https://plausible.io"],
        "published" => "true"
      }
    })

    settle(view)

    assert [%{tag: "script"} = script] = HeadCodes.head(site.id, "/", %{path: "/"}, "n")
    assert {"src", "https://plausible.io/js/script.js"} in script.attrs
    assert HeadCodes.origins(site.id) == ["https://plausible.io"]
    refute has_element?(view, "#head-code-form")
  end

  test "lists what extensions add, apart from the site's own", %{conn: conn, site: site} do
    {:ok, _} =
      Event.write(%{
        name: HeadCodeItems,
        event: "runtime:page:head",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("runtime:page:head", :start, false)
    on_exit(fn -> Event.unregister(:name, HeadCodeItems, false) end)

    entry!(site)

    view = conn |> log_in(admin!(["*"])) |> open() |> open_head_code()

    assert has_element?(view, "#head-code-extensions", "extension-verify")
    refute has_element?(view, "#head-code-extensions", "plausible.io/js/script.js")
  end

  test "a page's Configuration tab names the entries that reach it, each opening its form", %{
    conn: conn,
    site: site
  } do
    page = create_page!(site_id: site.id, name: "pricing", path: "/pricing")
    entry = entry!(site, %{name: "Pricing pixel", scope: :only, paths: ["/pricing"]})
    _elsewhere = entry!(site, %{name: "About pixel", scope: :only, paths: ["/about"]})

    view = conn |> log_in(admin!(["*"])) |> open()

    send(view.pid, {:row_action, "edit_preview_modal", %{"id" => page.id}})
    settle(view)

    assert has_element?(view, "#runtime-preview-head-code", "Pricing pixel")
    refute has_element?(view, "#runtime-preview-head-code", "About pixel")

    view |> element("#runtime-preview-head-code-#{entry.id}") |> render_click()
    settle(view)

    assert has_element?(view, "#head-code-form")
  end

  test "a site admin is not offered head code", %{conn: conn, site: site} do
    view = conn |> log_in(admin!(["admin:dashboard:*"], site.id)) |> open()

    refute has_element?(view, "#head-code-open")
  end
end
