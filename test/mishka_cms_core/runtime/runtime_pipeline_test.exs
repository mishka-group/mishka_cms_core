defmodule MishkaCmsCore.Runtime.RuntimePipelineTest do
  @moduledoc """
  Real-world checks for the runtime pipeline anti-storm work. These exercise
  ACTUAL Oban behavior (manual mode + sandbox), not static config:

    * asset jobs for the same {site, type} truly coalesce to one
    * `defer_runtime` truly suppresses the per-row compile job
    * rapid edits to the same resource truly coalesce (meta.slug uniqueness)

  The defer / per-row tests flip `env_test?` off so `SendToOban` runs for real
  (it is a no-op under `env_test?: true`).
  """
  use MishkaCmsCore.DataCase, async: false

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo
  @moduletag :integration

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Runtime.JsHook

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
