defmodule MishkaCmsCore.Runtime.Compilers.SitemapCompilerTest do
  @moduledoc """
  A site's sitemap, built ahead of the request: stored under `{site.name, "sitemap"}` and heard once
  it is, kept as it is by a build that changed nothing, enqueued as the site's own `"sitemap"` job,
  built by that job and by the boot, and enqueued for every open site when the `seo:sitemap:urls`
  chain changes.

  What goes in it is pinned through the controller in `MishkaCmsCoreWeb.SeoControllerTest`, and what
  enqueues it in `MishkaCmsCore.Runtime.SitemapTriggersTest`.

  `async: false` — `SiteState`, `AssetsState`, the plugin registry, the `BootHandler` name and the
  `:env_test?` flag are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Test.Plugins.{SitemapBuilt, SitemapSiteRemoved}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @compile_event [:mishka_installer, :event, :compile]

  # A site in the cache alone — all a job or a build looks it up in.
  defp cached_site(active?) do
    n = System.unique_integer([:positive])
    site = %{id: Ecto.UUID.generate(), name: "sitemap-#{n}", host: "sitemap-#{n}.test"}
    cache!(Map.merge(site, %{priority: 0, active: active?}))
  end

  # A site in the database too, so it can hold pages.
  defp stored_site do
    host = "sitemap-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)
    cache!(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})
  end

  defp cache!(site) do
    :ok = SiteState.save(site)

    on_exit(fn ->
      SiteState.delete(site.id)
      AssetsState.delete(site.name, "sitemap")
    end)

    site
  end

  # `build_sitemaps/0` builds every open site `SiteState` holds, and ETS outlives the sandbox: only
  # the test's own sites are in it while it runs, and whatever was there before is put back.
  defp only_these_sites! do
    held = Enum.to_list(SiteState.stream())
    SiteState.clear()
    on_exit(fn -> SiteState.save_batch(held) end)
  end

  defp jobs_off do
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)
  end

  defp sitemap_jobs(site) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "type"]) == "sitemap" and
        get_in(job.args, ["data", "site_id"]) == site.id
    end)
  end

  defp sitemap_job(site) do
    %Oban.Job{
      args: %{
        "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
        "action" => "boot_handler",
        "data" => %{"site_name" => site.name, "site_id" => site.id, "type" => "sitemap"}
      }
    }
  end

  defp register!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  # The jobs a changed chain enqueues are inserted by a task, so it is waited for: the tasks the
  # supervisor gained while `fun` ran, never one something else started. `fun`'s result is returned.
  defp await_handed_off!(fun) do
    before = MapSet.new(Task.Supervisor.children(MishkaCmsCore.Runtime.TaskSupervisor))
    result = fun.()

    for pid <- Task.Supervisor.children(MishkaCmsCore.Runtime.TaskSupervisor),
        not MapSet.member?(before, pid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    result
  end

  # Holds the name `BootHandler` runs under, as the running one does outside the tests.
  defp boot_handler_up! do
    stand_in = spawn(fn -> receive do: (:stop -> :ok) end)
    true = Process.register(stand_in, BootHandler)

    on_exit(fn ->
      if Process.whereis(BootHandler) == stand_in, do: Process.unregister(BootHandler)
      send(stand_in, :stop)
    end)
  end

  describe "compile_and_store/1" do
    test "stores the site's sitemap under its name, and returns it" do
      site = stored_site()
      create_page!(site_id: site.id, path: "/about")
      origin = ~s{https?://#{Regex.escape(site.host)}(:\\d+)?}

      assert {:ok, %{index: index, files: %{"sitemap-00001.xml.gz" => file} = files} = sitemap} =
               SitemapCompiler.compile_and_store(site.name)

      assert map_size(files) == 1
      assert index =~ "<sitemapindex "
      assert index =~ ~r{<loc>#{origin}/sitemap-00001\.xml\.gz</loc>}
      assert :zlib.gunzip(file) =~ ~r{<loc>#{origin}/about</loc>}
      assert AssetsState.get_value(site.name, "sitemap") == sitemap
    end

    test "stores an index of no file for a site with nothing to list" do
      site = stored_site()

      assert {:ok, %{index: index, files: files}} = SitemapCompiler.compile_and_store(site.name)

      assert files == %{}
      assert index =~ ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      refute index =~ "<sitemap>"
    end

    test "builds nothing for a name no site has" do
      name = "sitemap-nobody-#{System.unique_integer([:positive])}"

      assert SitemapCompiler.compile_and_store(name) == {:error, :no_site}
      refute AssetsState.exists?(name, "sitemap")
    end

    test "stores nothing for a site removed while it was built" do
      register!(SitemapSiteRemoved, "seo:sitemap:urls")
      site = cached_site(true)

      assert SitemapCompiler.compile_and_store(site.name) == {:error, :no_site}
      refute AssetsState.exists?(site.name, "sitemap")
    end

    # THE LASTMOD OF A FILE IS WHEN ITS BYTES CHANGED, so a rebuild that changed nothing keeps the
    # index stored — here one no build could make — and a change stores a new one.
    test "keeps what is stored while the files it builds are the ones stored" do
      site = stored_site()
      create_page!(site_id: site.id, path: "/about")
      {:ok, built} = SitemapCompiler.compile_and_store(site.name)
      kept = %{built | index: "the index stored with these files"}

      :ok =
        AssetsState.save(%{
          id: site.name,
          type: "sitemap",
          value: kept,
          hash: nil,
          updated_at: DateTime.utc_now()
        })

      assert SitemapCompiler.compile_and_store(site.name) == {:ok, kept}
      assert AssetsState.get_value(site.name, "sitemap") == kept

      create_page!(site_id: site.id, path: "/contact")

      assert {:ok, %{index: index, files: files} = changed} =
               SitemapCompiler.compile_and_store(site.name)

      assert index =~ "<sitemapindex "
      refute files == built.files
      assert AssetsState.get_value(site.name, "sitemap") == changed
    end

    test "is heard once stored, with the site and what it holds" do
      Process.register(self(), :__plugin_hook_probe__)
      register!(SitemapBuilt, "runtime:compile:after_sitemap")
      site = stored_site()
      create_page!(site_id: site.id, path: "/about")
      create_page!(site_id: site.id, path: "/contact")

      {:ok, _sitemap} = SitemapCompiler.compile_and_store(site.name)

      name = site.name
      assert_receive {:sitemap_built, %{site: ^name, urls: 2, files: 1}}
    end
  end

  describe "schedule/1" do
    test "enqueues nothing under the test flag" do
      site = cached_site(true)

      assert SitemapCompiler.schedule(site.id) == :ok
      assert sitemap_jobs(site) == []
    end

    test "enqueues one sitemap job for an open site, however often it is asked" do
      site = cached_site(true)
      jobs_off()

      assert {:ok, %Oban.Job{} = first} = SitemapCompiler.schedule(site.id)
      for _ <- 1..4, do: {:ok, _} = SitemapCompiler.schedule(site.id)

      assert [job] = sitemap_jobs(site)
      assert {job.queue, job.max_attempts} == {"sitemaps", 3}
      assert job.args["data"]["site_name"] == site.name
      assert DateTime.after?(job.scheduled_at, first.scheduled_at)
    end

    # A BUILD THAT FAILED IS STILL THE SITE'S ONE JOB: a change brings its retry forward rather than
    # adding a second build of the same site, however long ago it was first enqueued.
    test "brings a build waiting to retry forward instead of adding one" do
      site = cached_site(true)
      jobs_off()

      {:ok, first} = SitemapCompiler.schedule(site.id)
      later = DateTime.add(DateTime.utc_now(), 3600)
      long_ago = DateTime.add(DateTime.utc_now(), -86_400)

      first
      |> Ecto.Changeset.change(state: "retryable", scheduled_at: later, inserted_at: long_ago)
      |> @repo.update!()

      {:ok, _} = SitemapCompiler.schedule(site.id)

      # `all_enqueued/1` lists the available and scheduled alone.
      assert [%{id: id, state: "retryable", scheduled_at: scheduled_at}] =
               Enum.filter(
                 @repo.all(Oban.Job),
                 &(get_in(&1.args, ["data", "type"]) == "sitemap" and
                     get_in(&1.args, ["data", "site_id"]) == site.id)
               )

      assert id == first.id
      assert DateTime.before?(scheduled_at, later)
    end

    test "leaves a pending job where it is when asked to replace nothing" do
      site = cached_site(true)
      jobs_off()

      {:ok, first} = SitemapCompiler.schedule(site.id)
      for _ <- 1..4, do: {:ok, _} = SitemapCompiler.schedule(site.id, replace: [])

      assert [%{id: id, scheduled_at: scheduled_at}] = sitemap_jobs(site)
      assert {id, scheduled_at} == {first.id, first.scheduled_at}
    end

    test "enqueues nothing for a switched-off or an unknown site" do
      site = cached_site(false)
      jobs_off()

      assert SitemapCompiler.schedule(site.id) == :ok
      assert SitemapCompiler.schedule(Ecto.UUID.generate()) == :ok
      assert sitemap_jobs(site) == []
    end

    test "enqueues every open site's for a global row" do
      [one, two] = [cached_site(true), cached_site(true)]
      off = cached_site(false)
      jobs_off()

      assert SitemapCompiler.schedule(nil) == :ok

      assert length(sitemap_jobs(one)) == 1
      assert length(sitemap_jobs(two)) == 1
      assert sitemap_jobs(off) == []
    end
  end

  describe "the site's sitemap job" do
    test "has ten minutes, and every other job as long as it needs" do
      site = cached_site(true)

      assert RuntimeCompilerWorker.timeout(sitemap_job(site)) == :timer.minutes(10)

      for type <- ["asset", "css", "js"] do
        job = put_in(sitemap_job(site).args["data"]["type"], type)
        assert RuntimeCompilerWorker.timeout(job) == :infinity
      end
    end

    test "builds and stores the site's sitemap" do
      site = cached_site(true)

      assert {:ok, %{index: _index} = sitemap} = RuntimeCompilerWorker.perform(sitemap_job(site))
      assert AssetsState.get_value(site.name, "sitemap") == sitemap
    end

    test "builds nothing for a switched-off site" do
      site = cached_site(false)

      assert :ok = RuntimeCompilerWorker.perform(sitemap_job(site))
      refute AssetsState.exists?(site.name, "sitemap")
    end

    test "is done, with nothing built, for a site no longer cached" do
      n = System.unique_integer([:positive])
      site = %{id: Ecto.UUID.generate(), name: "sitemap-gone-#{n}"}

      assert :ok = RuntimeCompilerWorker.perform(sitemap_job(site))
      refute AssetsState.exists?(site.name, "sitemap")
    end
  end

  describe "BootHandler.build_sitemaps/0" do
    setup do
      only_these_sites!()
    end

    test "stores every open site's sitemap on this node, and no switched-off one's" do
      [one, two] = [cached_site(true), cached_site(true)]
      off = cached_site(false)

      assert BootHandler.build_sitemaps() == :ok

      assert %{index: _index} = AssetsState.get_value(one.name, "sitemap")
      assert %{index: _index} = AssetsState.get_value(two.name, "sitemap")
      refute AssetsState.exists?(off.name, "sitemap")
    end

    test "counts a site whose build raises as not built, and builds the rest" do
      built = cached_site(true)
      n = System.unique_integer([:positive])
      # Not an id the pages' tenant can be, so reading its pages raises.
      name = "sitemap-#{n}"
      cache!(%{id: "not-a-uuid", name: name, host: "#{name}.test", priority: 0, active: true})

      {result, _log} = with_log(&BootHandler.build_sitemaps/0)

      assert {:error, {:sitemaps_failed, [{:exit, {^name, _reason}}]}} = result
      assert %{index: _index} = AssetsState.get_value(built.name, "sitemap")
      refute AssetsState.exists?(name, "sitemap")
    end
  end

  describe "a changed seo:sitemap:urls chain" do
    # The chain this node last rebuilt every sitemap for is forgotten, so the next compile is a change;
    # and only the test's own sites are open, so the task enqueues for them and nothing else.
    setup do
      only_these_sites!()
      :persistent_term.erase({SitemapCompiler, :chain})
      :ok
    end

    test "enqueues every open site's sitemap job once mishka_installer rebuilds it" do
      [one, two] = [cached_site(true), cached_site(true)]
      off = cached_site(false)
      jobs_off()
      boot_handler_up!()

      assert "mishka-cms-core-sitemap-plugins" in Enum.map(
               :telemetry.list_handlers(@compile_event),
               & &1.id
             )

      :ok =
        await_handed_off!(fn -> EventHandler.do_compile("seo:sitemap:urls", :start, false) end)

      assert length(sitemap_jobs(one)) == 1
      assert length(sitemap_jobs(two)) == 1
      assert sitemap_jobs(off) == []
    end

    # MISHKA_INSTALLER REPORTS EVERY EVENT COMPILED whenever a node joins, rebuilt or not, and that
    # must not rebuild every site's sitemap.
    test "enqueues nothing for a compile that left the chain as it was" do
      site = cached_site(true)
      jobs_off()
      boot_handler_up!()

      :ok =
        await_handed_off!(fn -> EventHandler.do_compile("seo:sitemap:urls", :start, false) end)

      assert [%{id: id, scheduled_at: scheduled_at}] = sitemap_jobs(site)

      :ok =
        await_handed_off!(fn -> EventHandler.do_compile("seo:sitemap:urls", :start, false) end)

      assert [%{id: ^id, scheduled_at: ^scheduled_at}] = sitemap_jobs(site)
    end

    test "enqueues every open site's sitemap job while BootHandler is up" do
      [one, two] = [cached_site(true), cached_site(true)]
      off = cached_site(false)
      jobs_off()
      boot_handler_up!()

      meta = %{event: "seo:sitemap:urls", result: :ok}

      assert await_handed_off!(fn ->
               SitemapCompiler.handle_telemetry(@compile_event, %{}, meta, nil)
             end) == :ok

      assert length(sitemap_jobs(one)) == 1
      assert length(sitemap_jobs(two)) == 1
      assert sitemap_jobs(off) == []
    end

    test "enqueues nothing for another event, or with no BootHandler" do
      site = cached_site(true)
      jobs_off()

      assert SitemapCompiler.handle_telemetry(
               @compile_event,
               %{},
               %{event: "seo:sitemap:urls", result: :ok},
               nil
             ) == :ok

      boot_handler_up!()
      :persistent_term.erase({SitemapCompiler, :chain})

      for meta <- [
            %{event: "seo:robots:lines", result: :ok},
            %{event: "seo:sitemap:urls", result: :error}
          ] do
        assert await_handed_off!(fn ->
                 SitemapCompiler.handle_telemetry(@compile_event, %{}, meta, nil)
               end) == :ok
      end

      assert sitemap_jobs(site) == []
    end
  end
end
