# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.VisualEditorLinkTest do
  @moduledoc """
  Who the inspector offers the Visual Editor link to, with an editor answering
  `runtime:document:editor_url` and no editor installed.

  The address is the editor's to spell; whether a reader is offered it is the core's
  (`PreviewHelpers`): a **global** layout or component, one with no `site_id` that every site
  renders, is a master's to edit, so a tenant is offered no link that the editor would only turn
  away, while a master is, and a tenant's own record links with its site on the address. The probe
  `MishkaCmsCore.Test.Plugins.EditorUrlProbe` stands in for the editor.

  `async: false` — the registered plugin, the install flag and `SiteState` are process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Installer
  alias MishkaCmsCore.Test.Plugins.EditorUrlProbe

  @layout_body ~s(<body class="page"><main>{@inner_content}</main></body>)

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
    tenant = create_user_with_permissions!(["*"], site_id: site.id)

    {:ok,
     master_conn: log_in(conn, master),
     tenant_conn: log_in(Phoenix.ConnTest.build_conn(), tenant),
     site: site}
  end

  defp log_in(conn, user) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp record!(:layout, site_id),
    do: create_layout!(site_id: site_id, template: @layout_body)

  defp record!(:component, site_id),
    do:
      create_component!(
        site_id: site_id,
        name: "editor-link-#{System.unique_integer([:positive])}",
        template: ~s(<div>probe</div>)
      )

  defp list_path(:layout), do: "/admin/dashboard/runtime/layouts"
  defp list_path(:component), do: "/admin/dashboard/runtime/components"

  # The inspector opens off the list's row action and loads its record in an async task.
  defp inspector(conn, section, record) do
    {:ok, view, _html} = live(conn, list_path(section))
    send(view.pid, {:row_action, "show_preview_modal", %{"id" => record.id}})
    html = render_async(view, 5_000)

    assert html =~ record.name, "the inspector did not finish opening"
    html
  end

  for section <- [:layout, :component] do
    describe "a global #{section}" do
      test "offers a tenant no editor link", %{tenant_conn: conn} do
        record = record!(unquote(section), nil)
        html = inspector(conn, unquote(section), record)

        refute html =~ "Visual Editor"
        # The list's own "+ Add" may still lead to the editor; the shared row may not.
        refute html =~ "/probe-editor/#{unquote(section)}/#{record.id}",
               "the shared row still linked into the editor"
      end

      test "offers a master the editor's address, with no site on it", %{master_conn: conn} do
        record = record!(unquote(section), nil)
        html = inspector(conn, unquote(section), record)

        assert html =~ ~s(href="/probe-editor/#{unquote(section)}/#{record.id}")
      end
    end
  end

  test "a tenant's own layout links to the editor with its site on the address",
       %{tenant_conn: conn, site: site} do
    record = record!(:layout, site.id)
    html = inspector(conn, :layout, record)

    assert html =~ ~s(href="/probe-editor/layout/#{record.id}?site_id=#{site.id}")
  end
end
