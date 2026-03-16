defmodule MishkaCmsCore.Runtime.Workers.SiteRuntimeWorkerTest do
  @moduledoc """
  The site runtime worker purges a site's dependent parts (deactivate/archive) and
  recompiles them (activate/unarchive) — keyed by site name, streaming the rows.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker, as: Worker
  alias MishkaCmsCore.Runtime.States.{AssetsState, WebRunTimeMetaDataState}

  defp job(transition, site) do
    %Oban.Job{
      args: %{
        "transition" => transition,
        "site_id" => site.id,
        "site_name" => site.name,
        "old_name" => site.name
      }
    }
  end

  test "purge clears the site's cached assets and routing" do
    site = create_site!()
    page = create_page!(site_id: site.id)

    AssetsState.save(%{
      id: site.name,
      type: "css",
      value: "body{}",
      hash: "h",
      updated_at: ~U[2026-05-30 00:00:00Z]
    })

    WebRunTimeMetaDataState.save(%{
      id: page.id,
      site: site.name,
      path: page.path,
      title: page.name,
      created_at: ~U[2026-05-30 00:00:00Z],
      section: "Page",
      priority: 0
    })

    assert AssetsState.exists?(site.name, "css")
    assert WebRunTimeMetaDataState.count_by_site(site.name) == 1

    assert :ok = Worker.perform(job("purge", site))

    refute AssetsState.exists?(site.name, "css")
    assert WebRunTimeMetaDataState.count_by_site(site.name) == 0
  end

  test "recompile restores the site's routing" do
    site = create_site!()
    create_page!(site_id: site.id)

    WebRunTimeMetaDataState.delete_by_site(site.name)
    assert WebRunTimeMetaDataState.count_by_site(site.name) == 0

    assert :ok = Worker.perform(job("recompile", site))

    assert WebRunTimeMetaDataState.count_by_site(site.name) == 1
  end
end
