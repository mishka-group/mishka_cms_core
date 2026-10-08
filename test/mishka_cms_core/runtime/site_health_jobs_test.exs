defmodule MishkaCmsCore.Runtime.SiteHealthJobsTest do
  @moduledoc """
  Which compile jobs a site's health panel counts: the ones since this node booted. The boot cancels
  every compile job a previous run left and compiles from the database without a job, so a job from
  before it — `executing` because the node stopped, `cancelled` because the boot cancelled it, or
  failed — says nothing about the site now, and nothing later would ever mark it recovered.
  """
  use MishkaCmsCore.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.SiteHealth
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCoreWeb.Live.Admin.Components.SiteHealthPanel

  @before_boot ~U[2020-01-01 00:00:00.000000Z]

  setup do
    {:ok, site: create_site!(active: true)}
  end

  defp job!(site, state, inserted_at) do
    {:ok, job} =
      %{
        "site_id" => site.id,
        "resource" => "MishkaCmsCore.Runtime.Page",
        "action" => "update",
        "data" => %{"id" => Ecto.UUID.generate(), "site_id" => site.id, "name" => "about"}
      }
      |> RuntimeCompilerWorker.new(queue: :modules)
      |> Oban.insert()

    {1, _} =
      Oban.Repo.update_all(
        Oban.config(),
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: state, inserted_at: inserted_at, attempted_at: inserted_at]
      )
  end

  test "a job from before the boot is not counted, however it ended", %{site: site} do
    for state <- ["executing", "cancelled", "discarded"], do: job!(site, state, @before_boot)

    health = SiteHealth.compute(site)

    assert health.in_progress == []
    assert health.unrecovered == []
    refute health.state == :attention
  end

  test "a job since the boot is", %{site: site} do
    job!(site, "discarded", DateTime.utc_now())

    health = SiteHealth.compute(site)

    assert [_failed] = health.unrecovered
    assert health.state == :attention
  end

  # The test environment runs Oban in manual mode, with no plugins at all.
  test "the panel says so when Oban does not rescue interrupted jobs", %{site: site} do
    health = SiteHealth.compute(site)

    refute health.lifeline?

    html = render_component(&SiteHealthPanel.panel/1, health: health)

    assert html =~ ~s(id="site-health-lifeline")
    assert html =~ "lifeline: [rescue_after"
  end
end
