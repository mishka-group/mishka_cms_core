# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SystemStatusTest do
  @moduledoc """
  The sidebar footer's line about the system (`MishkaCmsCore.Layouts.SystemStatus`): it says what
  the jobs table holds, through the real chrome, and never a number nothing measures.
  """
  use MishkaCmsCore.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.SystemStatus
  alias MishkaCmsCore.Runtime.States.SiteState
  alias Phoenix.LiveView.AsyncResult

  @home "/admin/dashboard"

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
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, true)
      |> AshAuthentication.Plug.Helpers.store_in_session(create_user_with_permissions!(["*"]))

    {:ok, conn: conn, site: site}
  end

  defp footer(conn) do
    {:ok, view, html} = live(conn, @home)
    dead = html |> LazyHTML.from_document() |> LazyHTML.query("#admin-system-status")
    render_async(view, 5_000)
    live = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#admin-system-status")

    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    %{
      dead: dead |> LazyHTML.attribute("data-tone") |> List.first(),
      tone: live |> LazyHTML.attribute("data-tone") |> List.first(),
      text: LazyHTML.text(live)
    }
  end

  defp failed_job!(site_id, discarded_at) do
    job =
      MishkaCmsCore.Repo.insert!(
        Oban.Job.new(%{"site_id" => site_id}, worker: "Probe.Failed", queue: "default")
      )

    MishkaCmsCore.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "discarded", discarded_at: discarded_at]
    )
  end

  test "with no failed job the footer says all systems are operational and shows no uptime", %{
    conn: conn
  } do
    footer = footer(conn)

    assert footer.dead == "checking"
    assert footer.tone == "ok"
    assert footer.text =~ "All systems operational"
    refute footer.text =~ "uptime"
    refute footer.text =~ "%"
  end

  test "a job that failed in the last hour turns the line into how many failed", %{
    conn: conn,
    site: site
  } do
    failed_job!(site.id, DateTime.add(DateTime.utc_now(), -10, :minute))

    footer = footer(conn)

    assert footer.tone == "warn"
    assert footer.text =~ "1 background job failed in the last hour"
    refute footer.text =~ "All systems operational"
  end

  test "a job that failed more than an hour ago is not counted", %{conn: conn, site: site} do
    failed_job!(site.id, DateTime.add(DateTime.utc_now(), -2, :hour))

    assert footer(conn).tone == "ok"
  end

  test "a site's admin counts only the jobs of their own site", %{site: site} do
    other = create_site!(name: "other", host: "other.test", active: true)
    failed_job!(other.id, DateTime.utc_now())

    assert SystemStatus.read(%{site_id: site.id}) == %{failed: 0}
    assert SystemStatus.read(%{site_id: other.id}) == %{failed: 1}
    assert SystemStatus.read(%{site_id: nil}) == %{failed: 1}
  end

  test "a read that failed says the database does not answer" do
    line = SystemStatus.line(AsyncResult.failed(AsyncResult.loading(), {:exit, :timeout}))

    assert line.tone == :bad
    assert line.title == "The database does not answer"
  end
end
