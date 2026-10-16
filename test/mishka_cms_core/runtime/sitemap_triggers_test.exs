# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SitemapTriggersTest do
  @moduledoc """
  What enqueues a site's `"sitemap"` job in core: the compiler worker after a page or a layout, the
  per-site recompile, a change of the site's host, and a setting a sitemap reads. What the job then
  builds is pinned in `MishkaCmsCore.Runtime.Compilers.SitemapCompilerTest`.

  The worker's own enqueue is not behind the `:env_test?` flag, as a CSS rebuild's is not; a write
  goes through `SitemapCompiler.schedule/1`, which is, so those tests switch the flag off once their
  rows exist.

  `async: false` — `SiteState`, the settings cache and the `:env_test?` flag are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Settings

  defp cached_site(active? \\ true) do
    n = System.unique_integer([:positive])
    site = %{id: Ecto.UUID.generate(), name: "sitemap-trig-#{n}", host: "sitemap-trig-#{n}.test"}
    cache!(Map.merge(site, %{priority: 0, active: active?}))
  end

  defp stored_site do
    host = "sitemap-trig-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)
    cache!(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})
    site
  end

  defp cache!(site) do
    :ok = SiteState.save(site)
    on_exit(fn -> SiteState.delete(site.id) end)
    site
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

  defp perform(resource, action, data) do
    RuntimeCompilerWorker.perform(%Oban.Job{
      args: %{"resource" => resource, "action" => action, "data" => data}
    })
  end

  describe "the compiler worker" do
    test "enqueues a page's site's sitemap job after the page" do
      site = cached_site()
      page_id = Ecto.UUID.generate()
      name = "sitemap-trig-page-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        WebRunTimeMetaDataState.delete(page_id)
        BootHandler.delete_template_file(site.name, "page", name)
      end)

      perform("MishkaCmsCore.Runtime.Page", "update", %{
        "id" => page_id,
        "name" => name,
        "path" => "/#{name}",
        "active" => true,
        "precompile" => false,
        "site_id" => site.id,
        "priority" => 0,
        "updated_at" => "2026-09-30T00:00:00Z"
      })

      assert [%{queue: "sitemaps"}] = sitemap_jobs(site)
    end

    test "enqueues a site's layout's site's sitemap job, and no other site's" do
      [site, other] = [cached_site(), cached_site()]
      layout = %{"id" => Ecto.UUID.generate(), "name" => "sitemap-trig-layout"}

      perform("MishkaCmsCore.Runtime.Layout", "destroy", Map.put(layout, "site_id", site.id))

      assert length(sitemap_jobs(site)) == 1
      assert sitemap_jobs(other) == []
    end

    test "enqueues every open site's sitemap job after a global layout" do
      [one, two] = [cached_site(), cached_site()]
      off = cached_site(false)
      layout = %{"id" => Ecto.UUID.generate(), "name" => "sitemap-trig-layout"}

      perform("MishkaCmsCore.Runtime.Layout", "destroy", Map.put(layout, "site_id", nil))

      assert length(sitemap_jobs(one)) == 1
      assert length(sitemap_jobs(two)) == 1
      assert sitemap_jobs(off) == []
    end
  end

  test "a site recompiled whole enqueues its sitemap job" do
    site = cached_site()

    assert :ok = BootHandler.compile_site(site.id, site.name)

    assert length(sitemap_jobs(site)) == 1
  end

  describe "a site's host" do
    test "changed, enqueues the site's sitemap job" do
      site = stored_site()
      jobs_off()

      site
      |> Ash.Changeset.for_update(:update, %{host: "moved-#{site.host}"}, authorize?: false)
      |> Ash.update!()

      assert length(sitemap_jobs(site)) == 1
    end

    test "left alone, enqueues nothing" do
      site = stored_site()
      jobs_off()

      site
      |> Ash.Changeset.for_update(:update, %{priority: site.priority + 1}, authorize?: false)
      |> Ash.update!()

      assert sitemap_jobs(site) == []
    end
  end

  describe "a setting" do
    setup do
      snapshot = SettingsState.snapshot()
      on_exit(fn -> SettingsState.restore(snapshot) end)
    end

    test "a sitemap reads, set for a site, enqueues that site's sitemap job" do
      [site, other] = [stored_site(), stored_site()]
      jobs_off()

      {:ok, _} = Settings.put("seo.sitemap.paths", ["/x"], site_id: site.id)

      assert length(sitemap_jobs(site)) == 1
      assert sitemap_jobs(other) == []
    end

    # Every address in a sitemap is built in the site's URL mode.
    test "how a site's addresses name a language enqueues that site's sitemap job" do
      [site, other] = [stored_site(), stored_site()]
      jobs_off()

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert length(sitemap_jobs(site)) == 1
      assert sitemap_jobs(other) == []
    end

    test "a sitemap reads, set globally, enqueues every open site's" do
      [one, two] = [stored_site(), stored_site()]
      jobs_off()

      {:ok, _} = Settings.put("site.allowed_languages", ["en", "fa"])

      assert length(sitemap_jobs(one)) == 1
      assert length(sitemap_jobs(two)) == 1
    end

    test "no sitemap reads enqueues nothing" do
      site = stored_site()
      jobs_off()

      {:ok, _} = Settings.put("seo.robots.extra", "x", site_id: site.id)

      assert sitemap_jobs(site) == []
    end
  end
end
