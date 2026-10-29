# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.RuntimeWithoutEditorTest do
  @moduledoc """
  The page, layout, component and error-page lists on a host with no visual editor installed.

  The core spells none of the editor's addresses. It asks `runtime:document:editor_url`
  (`MishkaCmsCore.Runtime.Authoring.Section.editor_url/3`) and the editor's own plugin answers.
  Here the event answers as one whose plugins cannot run, which is what a host without the editor
  gets, and every way into an editor has to be gone rather than lead to a page nothing serves: the
  "+ Add" button opens the full form, "Fill in the form, then open the editor" is not offered, a save
  that asked for the editor anyway stays on its list, and the inspector offers no Visual Editor.

  `async: false` — the stubbed event, the install flag and `SiteState` are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Authoring.Section
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.EventCannotRun

  @lists [
    {"/admin/dashboard/runtime/pages", "page"},
    {"/admin/dashboard/runtime/layouts", "layout"},
    {"/admin/dashboard/runtime/components", "component"},
    {"/admin/dashboard/runtime/error-pages", "error_page"}
  ]

  # The editor's own addresses all live under this; no page of the core may name one.
  @editor "runtime/builder"

  setup %{conn: conn} do
    :ok = EventCannotRun.stub!("runtime:document:editor_url")

    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    :ok =
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

    master = create_user_with_permissions!(["*"], site_id: nil)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(master)

    {:ok, conn: conn, site: site}
  end

  test "no section has an editor's address, new or saved" do
    for section <- Section.names() do
      assert Section.editor_url(section) == nil
      assert Section.editor_url(section, Ecto.UUID.generate()) == nil
    end

    assert Section.editor_url(:error_page, Ecto.UUID.generate(), 500) == nil
  end

  test "every list's + Add is the full form, and nothing on it leads to an editor", %{conn: conn} do
    for {path, slug} <- @lists do
      {:ok, view, html} = live(conn, path)

      refute html =~ @editor, "#{path} links to an editor that is not installed"
      assert has_element?(view, "button#add-#{slug}-main"), "#{path}'s main half is not the form"
      refute has_element?(view, "a#add-#{slug}-main"), "#{path}'s main half still leaves"
      assert has_element?(view, "#pb-create-form-#{slug}"), "#{path} lost the full form"

      refute has_element?(view, "#pb-create-open-#{slug}"),
             "#{path} offers to open an editor that is not installed"
    end
  end

  test "the main half opens the create form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

    view |> element("#add-page-main") |> render_click()

    assert has_element?(view, "#page_form-form")
  end

  # The way is not drawn, but its event is still the page's: a save that asked for the editor lands
  # where any save lands rather than navigating to an address nobody answered.
  test "a save that asked for the editor stays on the list", %{conn: conn} do
    for {path, label} <- [
          {"/admin/dashboard/runtime/pages", "Page created successfully"},
          {"/admin/dashboard/runtime/layouts", "Layout created successfully"},
          {"/admin/dashboard/runtime/components", "Component created successfully"},
          {"/admin/dashboard/runtime/error-pages", "Error page created successfully"}
        ] do
      {:ok, view, _html} = live(conn, path)

      render_click(view, "create_and_open", %{})
      send(view.pid, {:form_saved, :create, %{id: Ecto.UUID.generate()}})

      assert render(view) =~ label, "#{path} did not stay on its list"
    end
  end

  test "the inspector offers no Visual Editor", %{conn: conn, site: site} do
    n = System.unique_integer([:positive])
    page = create_page!(site_id: site.id, name: "no-editor-#{n}", path: "/no-editor-#{n}")

    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")
    send(view.pid, {:row_action, "show_preview_modal", %{"id" => page.id}})
    html = render_async(view, 5_000)

    assert html =~ page.name, "the modal did not finish opening"
    refute html =~ "Visual Editor"
    refute html =~ @editor
  end
end
