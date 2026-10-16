# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.ActivityIndexAreasTest do
  @moduledoc """
  The Activity page shows a holder of the activity area only the areas it holds: a live broadcast of
  an area the viewer does not hold never reaches the table, and the KPI totals count the entries of
  its areas alone. The broadcasts are asked of the socket the page's own mount builds for the
  viewer; the totals of the page itself, opened through the admin session.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.ActivityEntry
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Activity.Index

  @path "/admin/dashboard/runtime/activity"

  defp mounted(user) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, current_user: user}
    }

    {:ok, socket} = Index.mount(%{}, %{}, socket)
    socket
  end

  defp broadcast(record) do
    %Phoenix.Socket.Broadcast{
      topic: "media:created",
      event: "create",
      payload: %Ash.Notifier.Notification{
        resource: record.__struct__,
        action: %{name: :create, type: :create},
        data: record
      }
    }
  end

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

    media = create_media!(site_id: site.id)
    page = create_page!(site_id: site.id)

    reader =
      create_user_with_permissions!(
        ["admin:dashboard:runtime:activity", "admin:dashboard:runtime:media"],
        site_id: site.id
      )

    {:ok, conn: conn, site: site, media: media, page: page, reader: reader}
  end

  test "a change of an area the viewer holds reaches the table", ctx do
    Index.handle_info(broadcast(ctx.media), mounted(ctx.reader))

    assert_received {:phoenix, :send_update, _update}
  end

  test "a change of an area the viewer does not hold does not", ctx do
    Index.handle_info(broadcast(ctx.page), mounted(ctx.reader))

    refute_received {:phoenix, :send_update, _update}
  end

  test "the KPI totals count only the entries of the areas the viewer holds", ctx do
    everything = create_user_with_permissions!(["admin:dashboard:*"], site_id: ctx.site.id)
    counts = ActivityEntry.counts(ctx.reader)

    assert counts.total > 0
    assert counts.total < ActivityEntry.counts(everything).total

    {:ok, view, _html} = ctx.conn |> log_in(ctx.reader) |> live(@path)
    render_async(view)

    assert kpi(view, :total) == Index.delimited(counts.total)
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp kpi(view, key) do
    view
    |> element("#activity-kpi-#{key}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
