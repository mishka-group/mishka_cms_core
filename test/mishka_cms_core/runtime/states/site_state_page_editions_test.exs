# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.SiteStatePageEditionsTest do
  @moduledoc """
  The editions of each page group, kept in `SiteState` so a compiled page names its other languages
  without a query (`MishkaCmsCore.Runtime.PageEditions.editions/2`).

  Filled at boot from the active, unarchived pages, then kept by every write of a page: on the node
  that wrote it, from the writing process once the row is committed
  (`MishkaCmsCore.Runtime.Resources.Notifiers.PageEditions`), and on every other node from the
  write's broadcast. A write moves its own page's row and nothing else, so a sibling added, moved
  or removed is read by the other editions on their next render, with no module compiled again.

  `async: false` — `SiteState` and the `env_test?` switch are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  @moduletag :integration

  alias MishkaCmsCore.Runtime.{Page, PageEditions}
  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.{BootHandler, ModuleCompilerHandler}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  setup do
    site = create_site!()
    master = create_page!(site_id: site.id, name: "about", path: "/about")

    fa =
      create_page!(
        site_id: site.id,
        name: "about-fa",
        path: "/fa/about",
        language: "fa",
        language_group_id: master.id
      )

    %{site: site, master: master, fa: fa}
  end

  describe "the boot" do
    test "fills the index from the active, unarchived pages", %{
      site: site,
      master: master,
      fa: fa
    } do
      create_page!(edition(site, master, "ar", active: false))
      site |> edition(master, "de") |> create_page!() |> archive!(site)

      SiteState.clear()
      assert SiteState.page_editions(site.id, master.id) == []

      assert :ok = BootHandler.load_sites()

      assert editions(site, master.id) == [
               %{path: "/about", language: "en", extra: master.extra},
               %{path: "/fa/about", language: "fa", extra: fa.extra}
             ]
    end
  end

  describe "a write on this node" do
    test "is read at once: a new edition joins its group, an edit is read as it is now", %{
      site: site,
      master: master,
      fa: fa
    } do
      assert languages(site, master.id) == ["en", "fa"]

      create_page!(edition(site, master, "ar"))
      assert languages(site, master.id) == ["ar", "en", "fa"]

      update!(fa, site, %{path: "/fa/darbare", extra: %{"note" => "kept"}})

      assert %{path: "/fa/darbare", extra: %{"note" => "kept"}} =
               Enum.find(editions(site, master.id), &(&1.language == "fa"))
    end

    test "moves an edition given another group out of its old one", %{
      site: site,
      master: master,
      fa: fa
    } do
      contact = create_page!(site_id: site.id, name: "contact", path: "/contact")

      update!(fa, site, %{language_group_id: contact.id})

      assert languages(site, master.id) == ["en"]
      assert languages(site, contact.id) == ["en", "fa"]
    end

    test "stops offering an edition switched off, archived or deleted, and offers one switched on",
         %{site: site, master: master, fa: fa} do
      fa = update!(fa, site, %{active: false})
      assert languages(site, master.id) == ["en"]

      fa = update!(fa, site, %{active: true})
      assert languages(site, master.id) == ["en", "fa"]

      archive!(fa, site)
      assert languages(site, master.id) == ["en"]

      # A restored page comes back switched off, and is offered once it is switched on.
      restored =
        Page
        |> Ash.get!(fa.id, action: :master_get_archived, authorize?: false)
        |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      assert languages(site, master.id) == ["en"]

      restored = update!(restored, site, %{active: true})
      assert languages(site, master.id) == ["en", "fa"]

      restored
      |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id)
      |> Ash.destroy!(authorize?: false)

      assert languages(site, master.id) == ["en"]
    end
  end

  describe "a write on another node" do
    test "is applied from its broadcast, and this node's own is not applied twice", %{
      site: site,
      master: master
    } do
      remote = %{
        id: Ecto.UUID.generate(),
        site_id: site.id,
        language_group_id: master.id,
        path: "/ar/about",
        language: "ar",
        extra: %{},
        active: true,
        archived_at: nil
      }

      page_broadcast("updated", remote)
      assert languages(site, master.id) == ["ar", "en", "fa"]

      # `from: self()` is what a broadcast this node sent looks like: its notifier already put it.
      page_broadcast("updated", %{remote | path: "/ar/never"}, self())
      assert Enum.find(editions(site, master.id), &(&1.language == "ar")).path == "/ar/about"

      page_broadcast("updated", %{remote | active: false})
      assert languages(site, master.id) == ["en", "fa"]

      page_broadcast("created", remote)
      page_broadcast("destroyed", remote)
      assert languages(site, master.id) == ["en", "fa"]
    end
  end

  describe "a page's editions" do
    test "are read from the index, with no query", %{site: site, master: master} do
      {editions, ran} = queries(fn -> PageEditions.editions(info(master), site.id) end)

      assert ran == []
      assert Enum.map(editions, & &1.language) |> Enum.sort() == ["en", "en", "fa"]
    end

    test "are its own alone for a group the index does not hold, still with no query", %{
      site: site,
      master: master
    } do
      unknown = %{info(master) | language_group_id: Ecto.UUID.generate()}

      assert {[%{language: "en"}], []} =
               queries(fn -> PageEditions.editions(unknown, site.id) end)
    end

    # SendToOban runs for real here: under `env_test?` it enqueues nothing.
    test "change with a sibling's write, which compiles no other page", %{
      site: site,
      master: master,
      fa: fa
    } do
      module = Helpers.module_name(master.id, site.name, "Page")

      {:ok, ^module} =
        ModuleCompilerHandler.compile_or_return_module(module, master.path, site.name, site.id)

      md5 = module.module_info(:md5)
      compiled = info(module)

      assert PageEditions.alternates(PageEditions.editions(compiled, site.id), %{}, site.id) == [
               %{language: "en", path: "/about"},
               %{language: "fa", path: "/fa/about"}
             ]

      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)
      compiles = count_compiles()

      archive!(fa, site)

      assert [job] = page_jobs()

      assert job.args["data"]["id"] == fa.id,
             "the sibling's write enqueued a job for another page"

      assert :ok = perform_job(RuntimeCompilerWorker, job.args)

      assert compiles.() == 0
      assert module.module_info(:md5) == md5
      assert PageEditions.alternates(PageEditions.editions(compiled, site.id), %{}, site.id) == []
    end
  end

  defp edition(site, master, language, overrides \\ []) do
    [
      site_id: site.id,
      name: "about-#{language}",
      path: "/#{language}/about",
      language: language,
      language_group_id: master.id
    ] ++ overrides
  end

  defp update!(page, site, attrs) do
    page
    |> Ash.Changeset.for_update(:update, attrs, tenant: site.id)
    |> Ash.update!(authorize?: false)
  end

  defp archive!(page, site) do
    page
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
    |> Ash.destroy!(authorize?: false)
  end

  defp editions(site, group),
    do: site.id |> SiteState.page_editions(group) |> Enum.sort_by(& &1.language)

  defp languages(site, group), do: site |> editions(group) |> Enum.map(& &1.language)

  # What `MishkaCmsWeb.RuntimeLive` hands `PageEditions.editions/2`: the compiled page's `:page`
  # section with its `extra` beside it, or a row standing in for it.
  defp info(module) when is_atom(module),
    do: Map.put(module.__page_information__(:page), :extra, module.__page_information__(:extra))

  defp info(page), do: Map.take(page, [:path, :language, :language_group_id, :extra])

  defp page_broadcast(event, page, from \\ nil) do
    topic = "page:#{event}"

    Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, topic, %Phoenix.Socket.Broadcast{
      topic: topic,
      event: event,
      payload: %Ash.Notifier.Notification{resource: Page, data: page, from: from}
    })

    # Handled in the cache's own process; sync on a call so the assertion is not a race.
    :sys.get_state(SiteState)
  end

  defp page_jobs do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(&(&1.args["resource"] == inspect(Page)))
  end

  # Every query the repo runs while `fun` runs, from any process.
  defp queries(fun) do
    handler = "edition-queries-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:mishka_cms_core, :repo, :query],
      fn _event, _measurements, meta, _config -> send(test, {handler, meta[:query]}) end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, drain(handler, [])}
  end

  defp drain(handler, acc) do
    receive do
      {^handler, query} -> drain(handler, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Counts, from here on, every runtime module compiled, wherever it runs.
  defp count_compiles do
    test = self()
    handler = "edition-compiles-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:mishka_cms, :runtime, :compilers, :module, :start],
      fn _event, _measurements, _meta, _config -> send(test, {handler, :compiled}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    fn -> length(drain(handler, [])) end
  end
end
