# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.TopbarNeedsTest do
  @moduledoc """
  The bell's "What needs you" (`MishkaCmsCore.Layouts.TopbarNeeds`): the core's failed jobs for
  whoever may open the activity log, what extensions add on `topbar:needs` for whoever may see it,
  listed under one folding header per group, a badge that adds their counts to the unread
  notifications, a plugin that raises leaving the
  core's item and the page, and open pages that ask again when an extension says the numbers moved.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Layouts
  alias MishkaCmsCore.Layouts.TopbarNeeds
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Plugins.{TopbarNeedsBroken, TopbarNeedsProbe}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @settings "/admin/dashboard/settings"
  @refreshed [:mishka_cms, :topbar_needs, :refreshed]

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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      TopbarNeedsProbe.reset()
    end)

    admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    {:ok, conn: conn, admin: admin, site: site}
  end

  describe "the core's own item" do
    test "counts the failed jobs of the viewer's site for whoever may open the activity log", %{
      admin: admin,
      site: site
    } do
      assert TopbarNeeds.collect(context(admin)) == []

      failed_job!(site.id)
      failed_job!(create_site!(name: "other", host: "other.test").id)

      assert [
               %{
                 id: "runtime-jobs",
                 count: 1,
                 tone: :error,
                 link: "/admin/dashboard/runtime/activity"
               }
             ] =
               TopbarNeeds.collect(context(admin))

      master = create_user_with_permissions!(["admin:dashboard:*"])
      assert [%{id: "runtime-jobs", count: 2}] = TopbarNeeds.collect(context(master))

      pages_only =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert TopbarNeeds.collect(context(pages_only)) == []
    end
  end

  describe "with a plugin answering" do
    setup do
      register(TopbarNeedsProbe)
      :ok
    end

    test "lists the items the viewer may see with a count, low priority first", %{admin: admin} do
      assert [refunds, away] = TopbarNeeds.collect(context(admin))

      assert %{id: "probe-refunds", count: 3, tone: :warn, link: @settings} = refunds
      assert refunds.detail =~ "MS-4806"
      assert %{id: "probe-away", count: 1, tone: :info, link: nil, priority: 50} = away
    end

    test "puts each item under its group, one with none under the core's, the core's item too", %{
      admin: admin,
      site: site
    } do
      failed_job!(site.id)
      needs = TopbarNeeds.collect(context(admin))

      assert %{group: "Probe shop", group_id: "probe"} =
               Enum.find(needs, &(&1.id == "probe-refunds"))

      assert %{group: "CMS", group_id: "cms"} = Enum.find(needs, &(&1.id == "probe-away"))
      assert %{group: "CMS", group_id: "cms"} = Enum.find(needs, &(&1.id == "runtime-jobs"))

      assert [
               %{id: "probe", label: "Probe shop", count: 3, needs: [%{id: "probe-refunds"}]},
               %{id: "cms", label: "CMS", count: 2, needs: cms}
             ] = TopbarNeeds.groups(needs)

      assert Enum.map(cms, & &1.id) == ["probe-away", "runtime-jobs"]
    end

    test "the bell lists each group under a header with its total, open, folding its own list", %{
      conn: conn,
      admin: admin,
      site: site
    } do
      failed_job!(site.id)
      view = open(conn, admin, @settings)

      assert has_element?(view, "#topbar-needs[phx-hook='RememberFolds']")

      assert has_element?(
               view,
               "#topbar-needs [aria-controls='topbar-needs-probe'][aria-expanded='true']",
               "Probe shop"
             )

      assert has_element?(view, "[aria-controls='topbar-needs-probe'] [data-group-count='3']")
      assert has_element?(view, "[aria-controls='topbar-needs-cms'] [data-group-count='2']")
      assert has_element?(view, "#topbar-needs-probe #topbar-need-probe-refunds")
      assert has_element?(view, "#topbar-needs-cms #topbar-need-probe-away")
      assert has_element?(view, "#topbar-needs-cms #topbar-need-runtime-jobs")
      refute has_element?(view, "#topbar-needs-probe.hidden")
    end

    test "the bell lists them and its badge adds their counts", %{
      conn: conn,
      admin: admin,
      site: site
    } do
      failed_job!(site.id)
      view = open(conn, admin, @settings)

      assert has_element?(view, "#topbar-bell [data-bell-count='5']")

      assert has_element?(
               view,
               "#topbar-needs #topbar-need-probe-refunds",
               "A buyer asks for a refund"
             )

      assert has_element?(view, "#topbar-need-probe-refunds[href='#{@settings}']", "3")
      assert has_element?(view, "#topbar-needs #topbar-need-runtime-jobs", "1 job failed")
      refute has_element?(view, "#topbar-need-probe-gated")
      refute has_element?(view, "#topbar-need-probe-zero")

      # The row of another site's address opens nothing.
      assert has_element?(view, "div#topbar-need-probe-away")
      refute has_element?(view, "[href*='evil.com']")
    end

    test "an extension's change makes the open page ask again", %{
      conn: conn,
      admin: admin,
      site: site
    } do
      _ref = :telemetry_test.attach_event_handlers(self(), [@refreshed])
      view = open(conn, admin, @settings)
      assert has_element?(view, "#topbar-bell [data-bell-count='4']")

      TopbarNeedsProbe.put_count(7)
      :ok = TopbarNeeds.changed(site.id)
      :ok = TopbarNeeds.changed(site.id)

      assert_receive {@refreshed, _ref, %{total: 8}, %{view: _view}}
      assert has_element?(view, "#topbar-need-probe-refunds", "7")
      assert has_element?(view, "#topbar-bell [data-bell-count='8']")

      # The two changes of one moment were collected once.
      refute_received {@refreshed, _ref, _measurements, _metadata}
    end
  end

  describe "a change of one site" do
    test "concerns that site's admins and every master, a change of every site concerns all" do
      assert TopbarNeeds.concerns?(%{site_id: "a"}, "a")
      refute TopbarNeeds.concerns?(%{site_id: "a"}, "b")
      assert TopbarNeeds.concerns?(%{site_id: nil}, "b")
      assert TopbarNeeds.concerns?(%{site_id: "a"}, nil)
    end
  end

  describe "with a plugin that raises" do
    setup do
      register(TopbarNeedsBroken)
      :ok
    end

    test "the page opens and the bell keeps the core's item", %{
      conn: conn,
      admin: admin,
      site: site
    } do
      failed_job!(site.id)

      log =
        capture_log(fn ->
          assert [%{id: "runtime-jobs"}] = TopbarNeeds.collect(context(admin))

          view = open(conn, admin, @settings)
          assert has_element?(view, "#settings-form")
          assert has_element?(view, "#topbar-need-runtime-jobs")
          assert has_element?(view, "#topbar-bell [data-bell-count='1']")
        end)

      assert log =~ "needs plugin is broken"
    end
  end

  describe "the bell" do
    test "adds the items' counts to the unread notifications, and lists nothing with no item" do
      need = %{
        id: "n",
        title: "Needs",
        detail: nil,
        count: 3,
        tone: :info,
        link: nil,
        priority: 1,
        group: "CMS",
        group_id: "cms"
      }

      html =
        (&Layouts.topbar/1)
        |> render_component(notification_count: 2, needs: [need])
        |> LazyHTML.from_fragment()

      assert html |> LazyHTML.query("#topbar-bell [data-bell-count]") |> LazyHTML.text() =~ "5"
      assert html |> LazyHTML.query("#topbar-needs #topbar-need-n") |> Enum.count() == 1

      # With one group its header is still drawn, so the reader sees whose items these are.
      assert html |> LazyHTML.query("[aria-controls='topbar-needs-cms']") |> LazyHTML.text() =~
               "CMS"

      empty = render_component(&Layouts.topbar/1, notification_count: 0, needs: [])
      refute empty =~ "data-bell-count"
      refute empty =~ ~s(id="topbar-needs")
    end
  end

  defp failed_job!(site_id) do
    job =
      MishkaCmsCore.Repo.insert!(
        Oban.Job.new(%{"site_id" => site_id}, worker: "Probe.Failed", queue: "default")
      )

    MishkaCmsCore.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "discarded"]
    )
  end

  defp register(plugin) do
    {:ok, _} =
      Event.write(%{
        name: plugin,
        event: "topbar:needs",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("topbar:needs", :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp context(user),
    do: %{current_user: user, current_site: nil, current_path: @settings, view: nil}

  defp open(conn, user, path) do
    {:ok, view, _html} =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:master_mode, is_nil(user.site_id))
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(path)

    render_async(view)
    view
  end
end
