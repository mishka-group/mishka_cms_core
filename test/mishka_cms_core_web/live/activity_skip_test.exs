# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.ActivitySkipTest do
  @moduledoc """
  Skipping a failed background job (`MishkaCmsCore.Activity.Sources.Oban.skip/3`) and bringing it
  back (`bring_back/2`): the reason and who are kept on the job, a job waiting for its next try is
  cancelled and never runs, one given up on stays so, only a failed job of a site the viewer reaches
  is skipped, and the failed count, the sidebar's line, the bell, the job's notifications, the
  `failure:skip:changed` event and the open activity log follow; on the page, a failed row has a
  Failed badge and Skip, a skipped one a Skipped badge, its reason and Bring back, under the Skipped
  filter and not the Error one, and the toast's Undo brings it back.
  """
  use MishkaCmsCore.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.ActivityEntry
  alias MishkaCmsCore.Activity.Sources.Oban, as: ObanSource
  alias MishkaCmsCore.Layouts.{SidebarStatus, TopbarNeeds}
  alias MishkaCmsCore.Layouts.SidebarStatus.FailedJobs
  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Skip
  alias MishkaCmsCore.Test.Plugins.SkipChangedProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  defmodule ReportMailer do
    @moduledoc false
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  @path "/admin/dashboard/runtime/activity"
  @failed_view "#{@path}?activity_filter_kind=job&activity_filter_severity=error"
  @skipped_view "#{@path}?activity_filter_kind=job&activity_filter_severity=skipped"

  setup %{conn: conn} do
    SiteState.clear()

    site =
      save_site!(create_site!(name: "localhost", host: "localhost", active: true, master: true))

    other = save_site!(create_site!(name: "Shop", host: "shop.test", active: true))

    :persistent_term.put(:mishka_installed, true)
    SidebarStatus.changed(nil)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    register(FailedJobs, "sidebar:status")
    admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
    {:ok, conn: conn, site: site, other: other, admin: admin}
  end

  describe "skip/3 and bring_back/2" do
    test "a job waiting for its next try is cancelled with its reason and never runs", %{
      site: site,
      admin: admin
    } do
      job = job!(site.id, "retryable")
      control = job!(site.id, "retryable")

      assert {:ok, skipped} = ObanSource.skip(admin, job.id, "  the buyer paid by bank  ")

      assert skipped.state == "cancelled"

      assert %{"reason" => "the buyer paid by bank", "by" => by, "state" => "retryable"} =
               skipped.meta["skipped"]

      assert by == admin.id

      assert %{success: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
      assert state(control) == "completed"
      assert state(job) == "cancelled"
    end

    test "a job given up on stays so, drops out of every count and comes back failed", %{
      site: site,
      admin: admin
    } do
      job = job!(site.id, "discarded")

      assert ObanSource.failed_count(admin) == 1
      assert [%{id: "core-failed-jobs", count: 1}] = SidebarStatus.collect(context(admin))
      assert [%{id: "runtime-jobs", count: 1}] = TopbarNeeds.collect(context(admin))
      assert %{error: 1, skipped: 0} = ActivityEntry.counts(admin)

      assert {:ok, %{state: "discarded", meta: %{"skipped" => %{"reason" => nil}}}} =
               ObanSource.skip(admin, job.id, "   ")

      assert ObanSource.failed_count(admin) == 0
      assert [%{id: "all-clear"}] = SidebarStatus.collect(context(admin))
      assert TopbarNeeds.collect(context(admin)) == []
      assert %{error: 0, skipped: 1} = ActivityEntry.counts(admin)

      assert {:ok, back} = ObanSource.bring_back(admin, job.id)
      refute Map.has_key?(back.meta, "skipped")
      assert back.state == "discarded"

      assert ObanSource.failed_count(admin) == 1
      assert [%{id: "core-failed-jobs", count: 1}] = SidebarStatus.collect(context(admin))
      assert [%{id: "runtime-jobs", count: 1}] = TopbarNeeds.collect(context(admin))
    end

    test "a job the skip cancelled comes back given up on, not waiting to run", %{
      site: site,
      admin: admin
    } do
      job = job!(site.id, "retryable")
      {:ok, _skipped} = ObanSource.skip(admin, job.id, nil)

      assert {:ok, %{state: "discarded", discarded_at: %DateTime{}, cancelled_at: nil}} =
               ObanSource.bring_back(admin, job.id)

      assert ObanSource.failed_count(admin) == 1
      assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :default, with_scheduled: true)
    end

    test "only a failed job is skipped, and only a skipped one brought back", %{
      site: site,
      admin: admin
    } do
      done = job!(site.id, "completed")
      failed = job!(site.id, "discarded")

      assert ObanSource.skip(admin, done.id, nil) == {:error, :not_failed}
      assert ObanSource.bring_back(admin, failed.id) == {:error, :not_skipped}

      {:ok, _skipped} = ObanSource.skip(admin, failed.id, nil)
      assert ObanSource.skip(admin, failed.id, nil) == {:error, :not_failed}
      assert ObanSource.skip(admin, "not-a-job", nil) == {:error, :not_found}
    end

    test "a site admin reaches only their own site's jobs, a master every one", %{
      site: site,
      other: other,
      admin: admin
    } do
      theirs = job!(other.id, "discarded")

      assert ObanSource.skip(admin, theirs.id, nil) == {:error, :not_found}
      assert state(theirs) == "discarded"
      assert ObanSource.failed_count(create_user_with_permissions!(["*"])) == 1

      pages_only =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert ObanSource.skip(pages_only, job!(site.id, "discarded").id, nil) ==
               {:error, :forbidden}

      assert ObanSource.skip(nil, theirs.id, nil) == {:error, :forbidden}

      master = create_user_with_permissions!(["*"])
      assert {:ok, _skipped} = ObanSource.skip(master, theirs.id, "not ours to fix")
      assert ObanSource.bring_back(admin, theirs.id) == {:error, :not_found}
      assert {:ok, _back} = ObanSource.bring_back(master, theirs.id)
    end

    test "a skip marks its notifications read and tells plugins, telemetry and open pages", %{
      site: site,
      admin: admin
    } do
      register(SkipChangedProbe, Skip.event())
      Skip.subscribe()
      ref = attach_telemetry()

      job = job!(site.id, "discarded")
      id = to_string(job.id)
      about = notification!(admin, site, %{"failure" => Skip.key("core:job", id)})
      unrelated = notification!(admin, site, %{"failure" => Skip.key("core:job", "0")})

      {:ok, _skipped} = ObanSource.skip(admin, job.id, "known outage")

      assert %{read_at: %DateTime{}} = Ash.get!(Notification, about.id, authorize?: false)
      assert %{read_at: nil} = Ash.get!(Notification, unrelated.id, authorize?: false)

      change = %{source: "core:job", id: id, site_id: site.id, skipped?: true}

      assert_received {:skip_changed_probe, %{reason: "known outage", actor_id: actor} = plugin}
      assert actor == admin.id
      assert Map.take(plugin, Map.keys(change)) == change
      assert_received {:skip_changed, %{reason: "known outage"}}
      assert_received {^ref, metadata}
      assert metadata == change

      {:ok, _back} = ObanSource.bring_back(admin, job.id)
      assert_received {:skip_changed, %{id: ^id, skipped?: false}}
    end
  end

  describe "the activity log" do
    test "a failed job is listed with its Failed badge and skipped with a reason through its Skip",
         %{conn: conn, site: site, admin: admin} do
      job = job!(site.id, "discarded")
      view = open(conn, admin, @failed_view)

      assert has_element?(view, "[data-role=job-failed]")
      assert kpi(view, :error) == "1"

      view |> element("[data-role=row-actions] button", "Skip") |> render_click()
      render(view)
      assert has_element?(view, "#activity-skip")

      view |> form("#activity-skip-dialog", %{reason: "paid by bank"}) |> render_submit()
      settle(view)

      refute has_element?(view, "#activity-skip")
      assert has_element?(view, "[data-role=gervaz-toast]", "Job skipped")
      refute has_element?(view, "[data-role=job-failed]")
      assert kpi(view, :error) == "0"
      assert kpi(view, :skipped) == "1"
      assert %{"reason" => "paid by bank"} = meta(job)["skipped"]

      skipped = open(conn, admin, @skipped_view)
      assert has_element?(skipped, "[data-role=job-skipped]")
      assert has_element?(skipped, "[data-role=skip-reason]", "paid by bank")
      assert has_element?(skipped, "[data-role=row-actions] button", "Bring back")
      refute has_element?(skipped, "[data-role=row-actions] button", "Skip")

      view |> element("[data-role=gervaz-toast-undo]") |> render_click()
      settle(view)

      assert has_element?(view, "[data-role=job-failed]")
      assert kpi(view, :error) == "1"
      assert state(job) == "discarded"
      refute Map.has_key?(meta(job), "skipped")
    end

    test "Cancel skips nothing, and Bring back on a skipped row brings it back", %{
      conn: conn,
      site: site,
      admin: admin
    } do
      job = job!(site.id, "discarded")
      view = open(conn, admin, @failed_view)

      view |> element("[data-role=row-actions] button", "Skip") |> render_click()
      render(view)
      view |> element("[data-role=skip-question-cancel]") |> render_click()

      refute has_element?(view, "#activity-skip")
      refute Map.has_key?(meta(job), "skipped")

      {:ok, _skipped} = ObanSource.skip(admin, job.id, nil)
      skipped = open(conn, admin, @skipped_view)

      skipped |> element("[data-role=row-actions] button", "Bring back") |> render_click()
      settle(skipped)

      refute has_element?(skipped, "[data-role=job-skipped]")
      assert state(job) == "discarded"
      refute Map.has_key?(meta(job), "skipped")
    end
  end

  defp job!(site_id, state) do
    job =
      MishkaCmsCore.Repo.insert!(
        Oban.Job.new(%{"site_id" => site_id}, worker: ReportMailer, queue: "default")
      )

    now = DateTime.utc_now()

    set =
      case state do
        "discarded" -> [state: "discarded", discarded_at: now, attempted_at: now, attempt: 1]
        "retryable" -> [state: "retryable", attempted_at: now, attempt: 1]
        "completed" -> [state: "completed", completed_at: now, attempted_at: now, attempt: 1]
      end

    MishkaCmsCore.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: set)
    job
  end

  defp reload(job), do: MishkaCmsCore.Repo.get!(Oban.Job, job.id)
  defp state(job), do: reload(job).state
  defp meta(job), do: reload(job).meta

  defp notification!(user, site, metadata) do
    Ash.Seed.seed!(Notification, %{
      type: "core:job_failed",
      title: "A background job failed",
      user_id: user.id,
      site_id: site.id,
      metadata: metadata
    })
  end

  defp attach_telemetry do
    ref = make_ref()
    pid = self()

    :telemetry.attach(
      "activity-skip-#{inspect(ref)}",
      [:mishka_cms, :skip, :changed],
      fn _event, _measurements, metadata, _config -> send(pid, {ref, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("activity-skip-#{inspect(ref)}") end)
    ref
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

  defp register(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp context(user),
    do: %{current_user: user, current_site: nil, current_path: @path, view: nil}

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

  # A skip reaches the page as its own `{:skip_changed, _}` broadcast, which sends the table a
  # refresh: a round trip for each, then the load the table starts and the counts the page starts.
  defp settle(view) do
    render(view)
    render(view)
    render_async(view)
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
