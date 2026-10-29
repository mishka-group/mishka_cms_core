# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.CreateForEditorTest do
  @moduledoc """
  What the page list's "Fill in the form, then open the editor" saves, with an editor answering
  `runtime:document:editor_url` (`MishkaCmsCore.Test.Plugins.EditorUrlProbe` stands in for it).

  Both ways on the "+ Add" button that end in the visual editor make a document that goes live when
  it is published there. The editor's own first step has always saved one inactive; this way used
  the full form, whose Active box comes ticked from the resource's default, so it made a page that
  was live, and empty, while its author built it in drafts. The full form, which ends on the list,
  keeps the switch.

  `async: false` — the registered plugin, the install flag and `SiteState` are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Installer
  alias MishkaCmsCore.Test.Plugins.EditorUrlProbe

  require Ash.Query

  @form "#page_form-form"

  setup %{conn: conn} do
    :ok = Installer.register!(EditorUrlProbe, "runtime:document:editor_url")

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

  # A relation is picked, not typed: focus the search box, then choose from what it offers.
  defp pick_site(view, site) do
    view |> element("#{@form} input[name='_search_site_id']") |> render_focus()
    view |> element("#search-select-page_form-site_id button", site.name) |> render_click()
    view
  end

  defp created!(name) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!()
  end

  test "a page made for the editor arrives inactive, with no Active switch to tick", %{
    conn: conn,
    site: site
  } do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

    view |> element("#pb-create-open-page") |> render_click()
    refute has_element?(view, "#{@form} [name='form[active]']")

    view
    |> pick_site(site)
    |> form(@form, %{"form" => %{"title" => "Built Later", "path" => "/built-later"}})
    |> render_submit()

    page = created!("built-later")
    assert_redirect(view, "/probe-editor/page/#{page.id}")
    refute page.active, "the page was live before anyone published it"
  end

  test "the full form keeps its Active switch, and a page saved with it ticked is live", %{
    conn: conn,
    site: site
  } do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

    view |> element("#pb-create-form-page") |> render_click()
    assert has_element?(view, "#{@form} [name='form[active]']")

    view
    |> pick_site(site)
    |> form(@form, %{
      "form" => %{"title" => "Live Now", "path" => "/live-now", "active" => "true"}
    })
    |> render_submit()

    assert created!("live-now").active
  end

  # AND THE CHOICE IS FORGOTTEN WITH THE FORM. A cancelled editor-bound create must not leave the
  # next ordinary one without its switch.
  test "the next full form after a cancelled one offers the switch again", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/runtime/pages")

    view |> element("#pb-create-open-page") |> render_click()
    send(view.pid, {:form_cancelled, Page})
    _closed = render(view)

    view |> element("#pb-create-form-page") |> render_click()
    assert has_element?(view, "#{@form} [name='form[active]']")
  end
end
