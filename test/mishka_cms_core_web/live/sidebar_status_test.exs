# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.SidebarStatusTest do
  @moduledoc """
  The status card at the bottom of the admin sidebar, drawn from the `sidebar:status` event
  (`MishkaCmsCore.Layouts.SidebarStatus`): nothing at all while no line comes back, no badge on the
  Settings row, a card per level (green all clear that says when it checked, blue notes, amber and
  red issues) whose dot has a soft halo, one line's page or the list of several, the lines the
  viewer may not see dropped (a permission, another site for a site admin, a level the config
  hides), a master's line of another site named with that site, the card changed or hidden on
  `sidebar:status:card`, switched off by config, and the core's own line, the background jobs
  given up on in the window.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts.SidebarStatus
  alias MishkaCmsCore.Layouts.SidebarStatus.FailedJobs
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.{SidebarStatusCardProbe, SidebarStatusProbe}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @event "sidebar:status"
  @card_event "sidebar:status:card"
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
      Application.delete_env(:mishka_cms_core, :sidebar_status_probe_calls)
      Application.delete_env(:mishka_cms_core, :sidebar_status)
      Application.delete_env(:mishka_cms_core, :sidebar_status_card_title)
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

  defp register(plugin, event \\ @event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
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
        %{id: "note", level: :info, label: "Shop 2.1 is out"},
        %{id: "bare", level: :warn},
        %{id: "count", level: :warn, label: "Bad count", count: -1},
        %{id: "away", level: :warn, label: "Away", link: "https://evil.example/x"},
        %{id: "warn", level: :error, label: "Taken id"}
      ])

      lines = SidebarStatus.collect(context(admin))

      assert Enum.map(lines, & &1.id) == ["error", "away", "warn", "note"]
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
      assert SidebarStatus.card([], context(admin)) == nil
      refute has_element?(open(conn, admin), "#admin-sidebar-status-card")
    end

    test "leaves out the levels the config does not show", %{conn: conn, admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      Application.put_env(:mishka_cms_core, :sidebar_status, levels: [:warn, :error])
      answer([%{id: "note", level: :info, label: "Shop 2.1 is out"}])

      assert [%{id: "all-clear", level: :ok}] = SidebarStatus.collect(context(admin))

      view = open(conn, admin)

      assert has_element?(
               view,
               "#admin-sidebar-status-card[data-state=ok]",
               "All systems operational"
             )

      refute has_element?(view, "#admin-sidebar-status-card", "Shop 2.1 is out")
    end
  end

  describe "the Settings row" do
    test "carries no status badge: the card alone says it", %{conn: conn, admin: admin} do
      answer([
        %{id: "jobs", level: :error, label: "8 failed jobs", link: @settings},
        %{id: "events", level: :warn, label: "3 unhandled events", link: nil}
      ])

      view = open(conn, admin)

      refute has_element?(view, "#admin-sidebar-settings-row")
      refute has_element?(view, "#admin-sidebar-status")
      refute has_element?(view, "#admin-sidebar-status-toggle")
      assert has_element?(view, "#admin-sidebar-footer a[href='#{@settings}']")
      assert has_element?(view, "#admin-sidebar-status-card", "2 issues")
    end

    test "a check that found nothing adds nothing to it", %{conn: conn, admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)

      assert [%{id: "all-clear", level: :ok}] = SidebarStatus.collect(context(admin))

      view = open(conn, admin)
      refute has_element?(view, "#admin-sidebar-status")
      refute view |> element("#admin-sidebar-footer a[href='#{@settings}']") |> render() =~ "OK"
    end

    test "a problem line wins over a check that found nothing", %{admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      answer([%{id: "error", level: :error, label: "8 failed jobs", link: @settings}])

      assert [%{id: "error"}] = SidebarStatus.collect(context(admin))
    end

    test "the all-clear line names no link for a viewer who may not open the activity log", %{
      site: site
    } do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      editor = create_user_with_permissions!(["admin:dashboard:page"], site_id: site.id)

      assert [%{id: "all-clear", link: nil}] = SidebarStatus.collect(context(editor))
    end

    test "pressing Settings still opens Settings", %{conn: conn, admin: admin} do
      answer([
        %{id: "error", level: :error, label: "8 failed jobs", link: "/admin/dashboard/pages"}
      ])

      {:ok, view, _html} = live(session(conn, admin), "/admin/dashboard/runtime/activity")

      assert {:error, {:live_redirect, %{to: "/admin/dashboard/settings"}}} =
               view
               |> element("#admin-sidebar-footer a[href='/admin/dashboard/settings']")
               |> render_click()
    end
  end

  describe "the card" do
    test "draws nothing at all when no plugin checked and no line comes back", %{
      conn: conn,
      site: site
    } do
      view = open(conn, no_checks(site))

      refute has_element?(view, "#admin-sidebar-status-card")
      refute view |> element("#admin-sidebar") |> render() =~ "All systems operational"
    end

    test "a check that found nothing is a green card saying when it checked", %{
      conn: conn,
      admin: admin
    } do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      view = open(conn, admin)

      assert has_element?(
               view,
               "#admin-sidebar-footer div#admin-sidebar-status-card[data-state=ok][data-level=ok]",
               "All systems operational"
             )

      assert has_element?(view, "#admin-sidebar-status-card", "Checked just now")

      send(view.pid, :sidebar_status_tick)
      assert has_element?(view, "#admin-sidebar-status-card", "Checked just now")
    end

    test "says how long ago the check ran" do
      at = ~U[2026-11-21 10:00:00Z]
      line = %{level: :ok, checked_at: at}

      assert SidebarStatus.checked_label(line, DateTime.add(at, 59)) == "Checked just now"
      assert SidebarStatus.checked_label(line, DateTime.add(at, 60)) == "Checked 1 min ago"
      assert SidebarStatus.checked_label(line, DateTime.add(at, 27 * 60)) == "Checked 27 min ago"
      assert SidebarStatus.checked_label(line, DateTime.add(at, 2 * 3_600)) == "Checked 2 h ago"
      assert SidebarStatus.checked_label(%{level: :ok}, at) == nil
    end

    test "is titled by the worst level: all clear, notes, or the warnings and errors as issues" do
      info = %{id: "note", level: :info, label: "Shop 2.1 is out"}
      warn = %{id: "warn", level: :warn, label: "2 drafts stuck"}
      error = %{id: "error", level: :error, label: "8 failed jobs"}

      assert SidebarStatus.title([]) == "All systems operational"
      assert SidebarStatus.title([info]) == "1 note"
      assert SidebarStatus.title([info, %{info | id: "other"}]) == "2 notes"
      assert SidebarStatus.title([warn]) == "1 issue"
      assert SidebarStatus.title([error, warn, info]) == "2 issues"
    end

    for {level, box, dot, title, line, words} <- [
          {:info, "bg-[#f2f6fd]", "bg-[#4a7fd4]", "text-[#2f5fa8]", "text-[#5378b5]", "1 note"},
          {:warn, "bg-[#fefaf1]", "bg-[#c8931f]", "text-[#9a6a07]", "text-[#a57a24]", "1 issue"},
          {:error, "bg-[#fdf4f3]", "bg-[#c0392b]", "text-[#b3382d]", "text-[#bd5a50]", "1 issue"}
        ] do
      test "one #{level} line is a card in its tone naming it, opening its page", %{
        conn: conn,
        admin: admin
      } do
        answer([
          %{
            id: "one",
            level: unquote(level),
            label: "The one line",
            link: "/admin/dashboard/pages"
          }
        ])

        view = open(conn, admin)
        card = "a#admin-sidebar-status-card[data-level=#{unquote(level)}]"

        assert has_element?(view, card, unquote(words))
        assert has_element?(view, card, "The one line")

        html = view |> element("#admin-sidebar-status-card") |> render()

        for class <- [unquote(box), unquote(dot), unquote(title), unquote(line)],
            do: assert(html =~ class)

        assert {:error, {:live_redirect, %{to: "/admin/dashboard/pages"}}} =
                 view |> element("#admin-sidebar-status-card") |> render_click()
      end
    end

    test "the all-clear card is in the green tone and takes no press", %{admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      html = render_card(admin)

      assert html =~ ~s(data-level="ok")
      refute html =~ "<a"
      refute html =~ "<button"

      for class <- ["bg-[#f3f8f4]", "bg-[#1f9d6b]", "text-[#177a53]", "text-[#3f8a69]"],
          do: assert(html =~ class)
    end

    test "every level's dot has a soft halo, still under reduced motion", %{admin: admin} do
      Application.put_env(:mishka_cms_core, :sidebar_status_probe_checked, true)
      ok = render_card(admin)

      lines =
        for level <- [:info, :warn, :error] do
          answer([%{id: "x", level: level, label: "Line"}])
          render_card(admin)
        end

      for html <- [ok | lines] do
        [halo] = Regex.run(~r/<span[^>]*data-halo[^>]*>/, html)
        assert halo =~ "animate-ping"
        assert halo =~ "opacity-40"
        assert halo =~ "motion-reduce:animate-none"
        assert halo =~ "motion-reduce:hidden"
      end
    end

    test "several lines are a card in the worst tone naming the worst, opening the list of them",
         %{conn: conn, admin: admin} do
      answer([
        %{id: "events", level: :warn, label: "3 unhandled events", link: @settings},
        %{id: "jobs", level: :error, label: "27 failed jobs", link: "/admin/dashboard/pages"},
        %{id: "note", level: :info, label: "Shop 2.1 is out", link: nil}
      ])

      view = open(conn, admin)

      assert has_element?(
               view,
               "button#admin-sidebar-status-card[data-level=error][aria-controls=admin-sidebar-status-list][aria-expanded=false]",
               "2 issues"
             )

      assert has_element?(view, "#admin-sidebar-status-card", "27 failed jobs")
      refute has_element?(view, "#admin-sidebar-status-card", "3 unhandled events")

      assert has_element?(
               view,
               "#admin-sidebar-status-list a#admin-sidebar-status-line-jobs[href='/admin/dashboard/pages']"
             )

      assert has_element?(
               view,
               "#admin-sidebar-status-list a#admin-sidebar-status-line-events[href='#{@settings}']"
             )

      assert has_element?(view, "#admin-sidebar-status-list div#admin-sidebar-status-line-note")

      assert view |> render() |> :binary.matches(~s(id="admin-sidebar-status-list")) |> length() ==
               1
    end

    test "several notes are a blue card of notes", %{admin: admin} do
      answer([
        %{id: "a", level: :info, label: "Shop 2.1 is out"},
        %{id: "b", level: :info, label: "Blog 1.4 is out"}
      ])

      assert %{level: :info, title: "2 notes", detail: "Shop 2.1 is out"} =
               SidebarStatus.card(SidebarStatus.collect(context(admin)), context(admin))
    end

    test "a plugin on sidebar:status:card changes the title or hides the card", %{
      conn: conn,
      admin: admin
    } do
      register(SidebarStatusCardProbe, @card_event)
      answer([%{id: "jobs", level: :error, label: "27 failed jobs", link: @settings}])

      Application.put_env(:mishka_cms_core, :sidebar_status_card_title, "Look at this")
      view = open(conn, admin)
      assert has_element?(view, "#admin-sidebar-status-card", "Look at this")
      assert has_element?(view, "#admin-sidebar-status-card", "27 failed jobs")
      refute has_element?(view, "#admin-sidebar-status-card", "1 issue")

      Application.put_env(:mishka_cms_core, :sidebar_status_card_title, :hide)
      refute has_element?(open(conn, admin), "#admin-sidebar-status-card")
    end

    test "a card a plugin broke is drawn as it came", %{admin: admin} do
      register(SidebarStatusCardProbe, @card_event)
      Application.put_env(:mishka_cms_core, :sidebar_status_card_title, "")
      answer([%{id: "jobs", level: :error, label: "27 failed jobs"}])

      assert %{title: "1 issue"} =
               SidebarStatus.card(SidebarStatus.collect(context(admin)), context(admin))
    end

    test "the card and its list share one read of the plugins per mount", %{
      conn: conn,
      admin: admin
    } do
      answer([%{id: "jobs", level: :error, label: "27 failed jobs", link: @settings}])
      view = open(conn, admin)

      assert has_element?(view, "#admin-sidebar-status-card")
      assert Application.get_env(:mishka_cms_core, :sidebar_status_probe_calls) == 2
    end

    test "follows a change of the viewer's site without a reload", %{conn: conn, site: site} do
      view = open(conn, no_checks(site))
      refute has_element?(view, "#admin-sidebar-status-card")

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
      assert has_element?(view, "a#admin-sidebar-status-card[data-level=error]", "1 failed job")
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
               "a#admin-sidebar-status-card[href='#{FailedJobs.link()}']",
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

  defp render_card(user) do
    lines = SidebarStatus.collect(context(user))

    render_component(&MishkaCmsCore.Layouts.status_card/1,
      card: SidebarStatus.card(lines, context(user)),
      lines: lines
    )
  end

  defp open(conn, user) do
    {:ok, view, _html} = live(session(conn, user), @settings)
    render_async(view)
    view
  end
end
