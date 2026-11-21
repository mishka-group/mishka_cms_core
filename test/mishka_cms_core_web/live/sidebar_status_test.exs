# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SidebarStatusTest do
  @moduledoc """
  The problems row at the bottom of the admin sidebar on the `sidebar:status` event
  (`MishkaCmsCore.Layouts.SidebarStatus`): nothing at all while no line comes back (no card, no
  "All systems operational"), one line as a link row to its page, several as "N problems" with a
  list of links, the lines the viewer may not see dropped (a permission, another site for a site
  admin), a master's line of another site named with that site, the row switched off by config,
  and the core's own line, the background jobs given up on in the window.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.SidebarStatus
  alias MishkaCmsCore.Layouts.SidebarStatus.FailedJobs
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.SidebarStatusProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @event "sidebar:status"
  @refreshed [:mishka_cms, :sidebar_status, :refreshed]

  setup %{conn: conn} do
    SiteState.clear()

    site =
      save_site!(create_site!(name: "localhost", host: "localhost", active: true, master: true))

    other = save_site!(create_site!(name: "Shop", host: "shop.test", active: true))

    :persistent_term.put(:mishka_installed, true)
    SidebarStatus.changed(nil)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Application.delete_env(:mishka_cms_core, :sidebar_status_probe)
      Application.delete_env(:mishka_cms_core, :sidebar_status_probe_checked)
      Application.delete_env(:mishka_cms_core, :sidebar_status_probe_data)
      Application.delete_env(:mishka_cms_core, :sidebar_status)
    end)

    register(SidebarStatusProbe)
    admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    {:ok, conn: conn, admin: admin, site: site, other: other}
  end

  defp save_site!(site) do
    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    site
  end

  defp register(plugin) do
    {:ok, _} =
      Event.write(%{name: plugin, event: @event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(@event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp answer(lines), do: Application.put_env(:mishka_cms_core, :sidebar_status_probe, lines)

  describe "the event" do
    test "keeps the lines the viewer may see, worst first, and drops the bad ones", %{
      admin: admin
    } do
      answer([
        %{
          id: "warn",
          level: :warn,
          label: "2 drafts stuck",
          count: 2,
          link: "/admin/dashboard/pages"
        },
        %{id: "error", level: :error, label: "8 failed jobs", count: 8, link: @settings},
        %{id: "gated", level: :error, label: "Secret", permission: "admin:api:probe"},
        %{id: "odd", level: :ok, label: "Fine"},
        %{id: "bare", level: :warn},
        %{id: "count", level: :warn, label: "Bad count", count: -1},
        %{id: "away", level: :warn, label: "Away", link: "https://evil.example/x"},
        %{id: "warn", level: :error, label: "Taken id"}
      ])

      lines = SidebarStatus.collect(context(admin))

      assert Enum.map(lines, & &1.id) == ["error", "away", "warn"]
      assert Enum.find(lines, &(&1.id == "away")).link == nil
      assert Enum.find(lines, &(&1.id == "warn")).label == "2 drafts stuck"
      assert SidebarStatus.level(lines) == :error
    end

    test "hands plugins the window and the time it starts", %{admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status, window: 600)
      SidebarStatus.collect(context(admin))

      data = Application.get_env(:mishka_cms_core, :sidebar_status_probe_data)
      assert data.window == 600
      assert DateTime.diff(DateTime.utc_now(), data.since) in 599..601
    end

    test "a site admin gets their own site's lines, a master every site's named with its site", %{
      admin: admin,
      site: site,
      other: other
    } do
      answer([
        %{id: "own", level: :warn, label: "1 own problem", site_id: site.id},
        %{id: "theirs", level: :error, label: "1 shop problem", site_id: other.id},
        %{id: "all", level: :warn, label: "1 problem of all"}
      ])

      assert admin |> context() |> SidebarStatus.collect() |> Enum.map(& &1.id) |> Enum.sort() ==
               ["all", "own"]

      master = create_user_with_permissions!(["*"], site_id: nil)
      lines = master |> context(site) |> SidebarStatus.collect()

      assert Enum.map(lines, & &1.label) |> Enum.sort() ==
               ["1 own problem", "1 problem of all", "1 shop problem · " <> other.name]
    end

    test "is off when the config says so", %{conn: conn, admin: admin} do
      answer([%{id: "error", level: :error, label: "8 failed jobs", link: @settings}])
      Application.put_env(:mishka_cms_core, :sidebar_status, enabled: false)

      assert SidebarStatus.collect(context(admin)) == []
      refute has_element?(open(conn, admin), "#admin-sidebar-status")
      refute has_element?(open(conn, admin), "#admin-sidebar-status-toggle")
    end
  end

  describe "the row" do
    test "draws nothing at all when no plugin checked and no line comes back", %{
      conn: conn,
      site: site
    } do
      view = open(conn, no_checks(site))

      refute has_element?(view, "#admin-sidebar-status")
      sidebar = view |> element("#admin-sidebar") |> render()
      refute sidebar =~ "All systems operational"
      refute sidebar =~ "uptime"
    end

    test "a plugin that checked and found nothing puts a green dot and OK on the Settings row",
         %{conn: conn, admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)

      assert [%{id: "all-clear", level: :ok}] = SidebarStatus.collect(context(admin))

      view = open(conn, admin)

      assert has_element?(
               view,
               "#admin-sidebar-settings-row #admin-sidebar-status[data-state=ok]",
               "OK"
             )

      refute has_element?(view, "#admin-sidebar-status-toggle")
    end

    test "a problem line wins over a check that found nothing", %{admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      answer([%{id: "error", level: :error, label: "8 failed jobs", link: @settings}])

      assert [%{id: "error"}] = SidebarStatus.collect(context(admin))
    end

    test "OK names no link for a viewer who may not open the activity log", %{site: site} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      editor = create_user_with_permissions!(["admin:dashboard:page"], site_id: site.id)

      assert [%{id: "all-clear", link: nil}] = SidebarStatus.collect(context(editor))
    end

    test "problems are a pill of N issues in the worst tone, beside the Settings link, opening a list of links",
         %{conn: conn, admin: admin} do
      answer([
        %{id: "jobs", level: :error, label: "8 failed jobs", link: @settings},
        %{
          id: "events",
          level: :warn,
          label: "3 unhandled events",
          link: "/admin/dashboard/pages"
        },
        %{id: "keys", level: :warn, label: "Keys refused", link: "/admin/dashboard/sites"}
      ])

      view = open(conn, admin)

      assert has_element?(
               view,
               "#admin-sidebar-settings-row button#admin-sidebar-status-toggle[data-level=error][aria-controls=admin-sidebar-status-list][aria-expanded=false]",
               "3 issues"
             )

      refute has_element?(view, "a #admin-sidebar-status-toggle")

      for {id, link} <- [
            {"jobs", @settings},
            {"events", "/admin/dashboard/pages"},
            {"keys", "/admin/dashboard/sites"}
          ] do
        assert has_element?(
                 view,
                 "#admin-sidebar-status-list a#admin-sidebar-status-line-#{id}[href='#{link}']"
               )
      end
    end

    test "one warning line is a pill of 1 issue in the warning tone", %{conn: conn, admin: admin} do
      answer([%{id: "warn", level: :warn, label: "2 drafts stuck", link: @settings}])
      view = open(conn, admin)

      assert has_element?(view, "#admin-sidebar-status-toggle[data-level=warn]", "1 issue")
      assert has_element?(view, "#admin-sidebar-status-list a#admin-sidebar-status-line-warn")
    end

    test "pressing Settings still opens Settings", %{conn: conn, admin: admin} do
      answer([
        %{id: "error", level: :error, label: "8 failed jobs", link: "/admin/dashboard/pages"}
      ])

      {:ok, view, _html} = live(session(conn, admin), "/admin/dashboard/runtime/activity")

      assert {:error, {:live_redirect, %{to: "/admin/dashboard/settings"}}} =
               view
               |> element("#admin-sidebar-settings-row > a[href='/admin/dashboard/settings']")
               |> render_click()
    end

    test "follows a change of the viewer's site without a reload", %{conn: conn, site: site} do
      view = open(conn, no_checks(site))
      refute has_element?(view, "#admin-sidebar-status")

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "sidebar-status-#{inspect(ref)}",
        @refreshed,
        fn _event, measurements, _meta, _config -> send(test_pid, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("sidebar-status-#{inspect(ref)}") end)

      answer([%{id: "error", level: :error, label: "1 failed job", link: @settings}])
      SidebarStatus.changed(site.id)

      assert_receive {^ref, %{lines: 1}}
      assert has_element?(view, "#admin-sidebar-status-line-error", "1 failed job")
    end
  end

  describe "the core's own line" do
    setup do
      register(FailedJobs)
      :ok
    end

    test "counts the jobs given up on in the window, not one outside it, and links to them", %{
      conn: conn,
      admin: admin,
      site: site,
      other: other
    } do
      now = DateTime.utc_now()
      discarded!(site.id, DateTime.add(now, -600))
      discarded!(site.id, DateTime.add(now, -2 * 3_600))
      discarded!(other.id, DateTime.add(now, -600))
      SidebarStatus.changed(nil)

      assert [line] = SidebarStatus.collect(context(admin))
      assert line.id == "core-failed-jobs"
      assert line.label == "1 failed job"
      assert line.count == 1
      assert line.link == FailedJobs.link()

      master = create_user_with_permissions!(["*"], site_id: nil)
      assert [%{count: 2}] = SidebarStatus.collect(context(master))

      view = open(conn, admin)

      assert has_element?(
               view,
               "#admin-sidebar-status a#admin-sidebar-status-line-core-failed-jobs[href='#{FailedJobs.link()}']",
               "1 failed job"
             )
    end

    test "checked with nothing failed, it says All clear", %{admin: admin} do
      assert [%{id: "all-clear"}] = SidebarStatus.collect(context(admin))
    end

    test "is not read for an admin who may not open the activity log", %{site: site} do
      discarded!(site.id, DateTime.add(DateTime.utc_now(), -60))
      SidebarStatus.changed(nil)
      editor = create_user_with_permissions!(["admin:dashboard:page"], site_id: site.id)

      assert SidebarStatus.collect(context(editor)) == []
    end

    test "its link opens the activity log filtered to failed background jobs", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(session(conn, admin), FailedJobs.link())
      render_async(view)

      assert has_element?(view, "input[type=radio][name=kind][value=job][checked]")
      assert has_element?(view, "input[type=radio][name=severity][value=error][checked]")
    end
  end

  # A viewer the core's own check (the activity log's) is not for, so no plugin checks for them.
  defp no_checks(site),
    do: create_user_with_permissions!(["admin:dashboard:setting"], site_id: site.id)

  defp discarded!(site_id, at) do
    job =
      MishkaCmsCore.Repo.insert!(
        Oban.Job.new(%{"site_id" => site_id}, worker: "Probe.Failed", queue: "default")
      )

    MishkaCmsCore.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "discarded", discarded_at: at, attempted_at: at]
    )
  end

  defp context(user, site \\ nil),
    do: %{current_user: user, current_site: site, current_path: @settings, view: nil}

  defp session(conn, user) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open(conn, user) do
    {:ok, view, _html} = live(session(conn, user), @settings)
    render_async(view)
    view
  end
end
