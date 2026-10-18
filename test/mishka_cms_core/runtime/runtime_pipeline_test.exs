# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.RuntimePipelineTest do
  @moduledoc """
  Real-world checks for the runtime pipeline anti-storm work. These exercise
  ACTUAL Oban behavior (manual mode + sandbox), not static config:

    * asset jobs for the same {site, type} truly coalesce to one
    * `defer_runtime` truly suppresses the per-row compile job
    * rapid edits to the same resource truly coalesce (meta.slug uniqueness)
    * only a node that serves the site takes the compile jobs over at boot and queues its bundles

  The defer / per-row tests flip `env_test?` off so `SendToOban` runs for real
  (it is a no-op under `env_test?: true`).
  """
  use MishkaCmsCore.DataCase, async: false

  import Ecto.Query

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Runtime.JsHook
  alias MishkaCmsCore.Runtime.States.SiteState

  @oban __MODULE__.Oban

  describe "asset job dedup (anti-storm)" do
    test "repeated {site, type} asset jobs coalesce to a single enqueued job" do
      for _ <- 1..5, do: {:ok, _} = Oban.insert(BootHandler.asset_job("site_x", "x-id", "css"))

      assert length(enqueued_asset_jobs("site_x", "css")) == 1,
             "five identical asset triggers must collapse into one job"
    end

    test "different site or type are kept as separate jobs" do
      {:ok, _} = Oban.insert(BootHandler.asset_job("a", "a-id", "css"))
      {:ok, _} = Oban.insert(BootHandler.asset_job("a", "a-id", "css"))
      {:ok, _} = Oban.insert(BootHandler.asset_job("b", "b-id", "css"))
      {:ok, _} = Oban.insert(BootHandler.asset_job("a", "a-id", "js"))

      assert length(enqueued_asset_jobs("a", "css")) == 1
      assert length(enqueued_asset_jobs("b", "css")) == 1
      assert length(enqueued_asset_jobs("a", "js")) == 1
    end
  end

  describe "a bundle job names the instance that queued it" do
    setup :serve_the_site

    test "the boot's per-site jobs carry this instance's boot id" do
      site = cached_site!(active: true)

      for type <- ["asset", "css", "js", "sitemap"] do
        :ok = BootHandler.create_assets_compilation_jobs(type)

        assert [job] = enqueued_asset_jobs(site.name, type)
        assert job.args["boot_id"] == BootHandler.boot_id()
      end
    end

    test "a single job carries it too" do
      args =
        "site_a" |> BootHandler.asset_job("site-a-id", "css") |> Ecto.Changeset.get_change(:args)

      assert is_binary(BootHandler.boot_id())
      assert args.boot_id == BootHandler.boot_id()
    end

    test "another instance's job for the same site and type is kept beside this one's" do
      {:ok, _} = Oban.insert(BootHandler.asset_job("site_y", "y-id", "css"))

      {:ok, _} =
        "site_y"
        |> BootHandler.asset_job("y-id", "css")
        |> Ecto.Changeset.update_change(:args, &Map.put(&1, :boot_id, Ecto.UUID.generate()))
        |> Oban.insert()

      boot_ids = Enum.map(enqueued_asset_jobs("site_y", "css"), & &1.args["boot_id"])

      assert length(boot_ids) == 2
      assert BootHandler.boot_id() in boot_ids
    end
  end

  describe "whether this node serves the site" do
    test "it does once the host's endpoint is set to serve" do
      refute BootHandler.serving?()

      :ok = serve_the_site(%{})
      assert BootHandler.serving?()
    end
  end

  describe "the boot of a node that serves the site" do
    setup :serve_the_site

    test "supersedes an older boot's queued and executing jobs" do
      older = boot_jobs_of(Ecto.UUID.generate())

      assert {:ok, 2} = BootHandler.take_over_compile_jobs()
      assert states(older) == ["cancelled", "cancelled"]
    end

    test "queues every open site's bundle, named for itself" do
      site = cached_site!(active: true)

      :ok = BootHandler.queue_boot_jobs()

      assert [job] = enqueued_asset_jobs(site.name, "asset")
      assert job.args["boot_id"] == BootHandler.boot_id()
    end

    test "leaves its bundle queues running" do
      start_oban!(assets: [limit: 2], sitemaps: [limit: 1])

      assert {:ok, 0} = BootHandler.take_over_compile_jobs(oban: @oban)
      refute paused?(:assets)
      refute paused?(:sitemaps)
    end
  end

  describe "the boot of a node that does not serve the site" do
    test "leaves a serving node's queued and executing boot jobs where they are, and queues none" do
      refute BootHandler.serving?()
      cached_site!(active: true)
      serving = boot_jobs_of(Ecto.UUID.generate())

      assert {:ok, 0} = BootHandler.take_over_compile_jobs()
      assert :ok = BootHandler.queue_boot_jobs()

      assert states(serving) == ["scheduled", "executing"]
      assert compile_job_ids() == Enum.map(serving, & &1.id)
    end

    test "pauses its own bundle queues, and no other" do
      start_oban!(assets: [limit: 2], sitemaps: [limit: 1], default: [limit: 5])

      assert {:ok, 0} = BootHandler.take_over_compile_jobs(oban: @oban)
      assert paused?(:assets)
      assert paused?(:sitemaps)
      refute paused?(:default)
    end

    test "leaves a node that runs neither bundle queue as it is" do
      start_oban!(default: [limit: 5])

      assert {:ok, 0} = BootHandler.take_over_compile_jobs(oban: @oban)
      refute paused?(:default)
    end

    test "names no instance in a bundle job it queues, so a serving node builds it" do
      site = cached_site!(active: false)

      args =
        site.name |> BootHandler.asset_job(site.id, "css") |> Ecto.Changeset.get_change(:args)

      assert Map.fetch(args, :boot_id) == {:ok, nil}

      # A switched-off site's job ends in `:ok` without building anything, so `:ok` says the job
      # went past the instance rule, and `{:snooze, _}` that it stopped there.
      :ok = serve_the_site(%{})
      assert :ok = perform_job(RuntimeCompilerWorker, args)
    end
  end

  describe "the boot's cleanup" do
    # The page and component compile jobs run in the `modules` queue, which the cleanup's own list
    # of queues left out — every one a restart interrupted stayed `executing` for good.
    test "cancels the compile jobs a previous run left, in every queue, and nothing else" do
      compile =
        for queue <- [:modules, :default, :assets, :sitemaps] do
          {:ok, job} =
            %{
              "resource" => "MishkaCmsCore.Runtime.Page",
              "data" => %{"id" => Ecto.UUID.generate()}
            }
            |> RuntimeCompilerWorker.new(queue: queue)
            |> Oban.insert()

          job
        end

      {:ok, mail} =
        %{"delivery_id" => Ecto.UUID.generate()}
        |> MishkaCmsCore.Mail.Workers.DeliverWorker.new()
        |> Oban.insert()

      ids = Enum.map(compile, & &1.id)

      Oban.Repo.update_all(
        Oban.config(),
        from(j in Oban.Job, where: j.id in ^[hd(ids), mail.id]),
        set: [state: "executing"]
      )

      assert {:ok, 4} = BootHandler.cancel_leftover_jobs()

      states =
        Oban.Repo.all(
          Oban.config(),
          from(j in Oban.Job, where: j.id in ^[mail.id | ids], select: {j.id, j.state})
        )
        |> Map.new()

      assert Enum.all?(ids, &(states[&1] == "cancelled"))
      assert states[mail.id] == "executing"
    end
  end

  describe "per-row compile jobs (env_test? off)" do
    setup do
      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)
      :ok
    end

    test "a normal global write enqueues a module compile job" do
      {:ok, _hook} = create_hook("Normal Hook One")

      assert length(jobs_for_resource(JsHook)) == 1
    end

    test "defer_runtime: true suppresses the per-row job entirely" do
      {:ok, _hook} = create_hook("Deferred Hook One", defer: true)

      assert jobs_for_resource(JsHook) == [],
             "defer_runtime must prevent any per-row compile job (bulk callers rebuild once)"
    end

    test "many deferred writes enqueue zero jobs (bulk install shape)" do
      for n <- 1..6, do: {:ok, _} = create_hook("Bulk Hook #{n}", defer: true)

      assert jobs_for_resource(JsHook) == []
    end

    test "create then update the same record coalesces to one pending job" do
      {:ok, hook} = create_hook("Coalesce Hook")

      {:ok, _} =
        hook
        |> Ash.Changeset.for_update(:master_update, %{content: "console.log('v2')"},
          authorize?: false
        )
        |> Ash.update(authorize?: false)

      assert length(jobs_for_id(hook.id)) == 1,
             "a create + update on the same record share a meta.slug and coalesce"
    end
  end

  ## helpers

  # A node serves the site when the host's endpoint is set to serve: what `mix phx.server` and a
  # release's `PHX_SERVER` do. The suite's own endpoint is not, so a test without this runs as a node
  # that does not.
  defp serve_the_site(_context) do
    app = Application.fetch_env!(:mishka_cms_core, :host_app)
    endpoint = Application.fetch_env!(:mishka_cms_core, :endpoint)
    conf = Application.get_env(app, endpoint, [])

    Application.put_env(app, endpoint, Keyword.put(conf, :server, true))
    on_exit(fn -> Application.put_env(app, endpoint, conf) end)
    :ok
  end

  defp cached_site!(attrs) do
    n = System.unique_integer([:positive])
    site = %{id: Ecto.UUID.generate(), name: "boot-#{n}", host: "boot-#{n}.test", priority: 0}

    :ok = SiteState.save(Map.merge(site, Map.new(attrs)))
    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  # One instance's boot bundles as it left them: one still waiting its turn, one being built.
  defp boot_jobs_of(boot_id) do
    for {site, state} <- [{"waiting", "scheduled"}, {"building", "executing"}] do
      {:ok, job} =
        site
        |> BootHandler.asset_job("#{site}-id", "asset")
        |> Ecto.Changeset.update_change(:args, &Map.put(&1, :boot_id, boot_id))
        |> Oban.insert()

      {:ok, job} = Oban.Repo.update(Oban.config(), Ecto.Changeset.change(job, state: state))
      job
    end
  end

  defp states(jobs), do: Enum.map(jobs, &Oban.Repo.reload(Oban.config(), &1).state)

  defp compile_job_ids do
    Oban.Repo.all(
      Oban.config(),
      from(j in Oban.Job,
        where: j.worker == ^inspect(RuntimeCompilerWorker),
        order_by: j.id,
        select: j.id
      )
    )
  end

  # An Oban of the test's own, whose queues are real ones: the Inline engine fetches no job, and the
  # Isolated notifier hands a pause straight to the queue, so its state is read back right after.
  defp start_oban!(queues) do
    start_supervised!(
      {Oban,
       name: @oban,
       repo: @repo,
       engine: Oban.Engines.Inline,
       notifier: Oban.Notifiers.Isolated,
       peer: false,
       stager: false,
       plugins: false,
       queues: Enum.map(queues, fn {queue, opts} -> {queue, running(opts)} end)},
      id: @oban
    )
  end

  # The Inline engine keeps no defaults of its own, so a queue names its `refresh_interval`, and says
  # it is running for `paused?/1` to read it back.
  defp running(opts), do: Keyword.merge([refresh_interval: 60_000, paused: false], opts)

  defp paused?(queue), do: Oban.check_queue(@oban, queue: queue).paused

  defp create_hook(name, opts \\ []) do
    ctx = if opts[:defer], do: %{defer_runtime: true}, else: %{}

    Ash.create(JsHook, %{name: name, content: "console.log('#{name}')"},
      action: :master_create,
      authorize?: false,
      context: ctx
    )
  end

  defp enqueued_asset_jobs(site, type) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "site_name"]) == site and
        get_in(job.args, ["data", "type"]) == type
    end)
  end

  defp jobs_for_resource(resource) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(&(&1.args["resource"] == inspect(resource)))
  end

  defp jobs_for_id(id) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(&(get_in(&1.args, ["data", "id"]) == id))
  end
end
