# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Workers.SiteRuntimeWorkerTest do
  @moduledoc """
  The site runtime worker purges a site's dependent parts (deactivate/archive) and
  recompiles them (activate/unarchive), and rebuilds them for a new host — keyed by site name,
  streaming the rows.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker, as: Worker
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState, WebRunTimeMetaDataState}

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

  describe "a site's host" do
    test "changed, rebuilds the site's pages for it" do
      host = "rehost-#{System.unique_integer([:positive])}.test"
      site = create_site!(name: host, host: host, active: true)
      page = create_page!(site_id: site.id, precompile: true)
      module = Helpers.module_name(page.id, site.name, "Page")

      on_exit(fn ->
        SiteState.delete(site.id)
        :code.purge(module)
        :code.delete(module)
      end)

      assert :ok = Worker.perform(job("recompile", site))
      assert module.__page_information__(:private).host == host

      jobs_on()

      moved =
        site
        |> Ash.Changeset.for_update(:update, %{host: "moved-" <> host}, authorize?: false)
        |> Ash.update!()

      assert [rehost] = all_enqueued(worker: Worker)
      assert rehost.args == job("rehost", site).args

      assert :ok = perform_job(Worker, rehost.args)
      assert module.__page_information__(:private).host == moved.host
    end

    test "left alone, rebuilds nothing" do
      host = "rehost-#{System.unique_integer([:positive])}.test"
      site = create_site!(name: host, host: host, active: true)
      on_exit(fn -> SiteState.delete(site.id) end)
      jobs_on()

      site
      |> Ash.Changeset.for_update(:update, %{priority: site.priority + 1}, authorize?: false)
      |> Ash.update!()

      assert all_enqueued(worker: Worker) == []
    end
  end

  defp jobs_on do
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)
  end
end
