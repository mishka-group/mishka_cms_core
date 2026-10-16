# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.RuntimeCompilerInactiveSiteTest do
  @moduledoc """
  The compiler worker builds nothing for a switched-off site.

  Deactivating a site purges its routes, modules and assets; switching it back on runs
  `BootHandler.compile_site/2`, which rebuilds all of it from the database, edits made in between
  included. So a save, a restore or an asset build for a switched-off site is skipped rather than
  putting back what the purge took away — while a removal still runs, so what it cleans up is not
  left behind.

  `async: false` — `SiteState`, the routing table and the asset cache are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker, as: Worker

  defp cached_site(active?) do
    n = System.unique_integer([:positive])
    site = %{id: Ecto.UUID.generate(), name: "rcw-#{n}", host: "rcw-#{n}.test"}
    :ok = SiteState.save(Map.merge(site, %{priority: 0, active: active?}))
    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp page_job(action, site, page_id) do
    %Oban.Job{
      args: %{
        "resource" => "MishkaCmsCore.Runtime.Page",
        "action" => action,
        "data" => %{
          "id" => page_id,
          "name" => "x",
          "path" => "/rcw-#{page_id}",
          "active" => true,
          "precompile" => false,
          "site_id" => site.id,
          "priority" => 0,
          "updated_at" => "2026-09-25T00:00:00Z"
        }
      }
    }
  end

  defp routed!(site, page_id) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: page_id,
        site: site.name,
        path: "/rcw-#{page_id}",
        title: "x",
        created_at: ~U[2026-09-25 00:00:00Z],
        section: "Page",
        priority: 0
      })

    on_exit(fn -> WebRunTimeMetaDataState.delete(page_id) end)
  end

  test "a save for a switched-off site puts nothing back" do
    site = cached_site(false)
    page_id = Ecto.UUID.generate()
    on_exit(fn -> WebRunTimeMetaDataState.delete(page_id) end)

    for action <- ["create", "update", "unarchive"] do
      assert :ok = Worker.perform(page_job(action, site, page_id))

      refute WebRunTimeMetaDataState.exists?(page_id),
             "#{action} routed a switched-off site's page"
    end
  end

  test "the same save for a site that is up is routed" do
    site = cached_site(true)
    page_id = Ecto.UUID.generate()
    on_exit(fn -> WebRunTimeMetaDataState.delete(page_id) end)

    Worker.perform(page_job("update", site, page_id))

    assert WebRunTimeMetaDataState.exists?(page_id)
  end

  test "a removal for a switched-off site still runs" do
    site = cached_site(false)
    page_id = Ecto.UUID.generate()
    routed!(site, page_id)

    Worker.perform(page_job("destroy", site, page_id))

    refute WebRunTimeMetaDataState.exists?(page_id)
  end

  test "an asset build for a switched-off site is skipped" do
    site = cached_site(false)

    job = %Oban.Job{
      args: %{
        "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
        "data" => %{"site_name" => site.name, "type" => "css"}
      }
    }

    assert :ok = Worker.perform(job)
    refute AssetsState.exists?(site.name, "css")
  end
end
