defmodule MishkaCmsCore.Runtime.ShareCardRedrawAllTest.RedrawSeo do
  @moduledoc false
  def call(%{record: "test:thing"} = seo) do
    send(self(), {:redraw, seo.redraw})
    {:reply, :halt, seo}
  end

  def call(seo), do: {:reply, seo}
end

defmodule MishkaCmsCore.Runtime.ShareCardRedrawAllTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.ShareCard.redraw_all/2`: every share card of a site looked at again in the
  background. One planner job a site on `:share_cards`, which collects the cards through
  `runtime:share_card:targets` — the core's pages and a test producer's targets
  (`MishkaCmsCore.Test.Plugins.ShareCardProducer`) — and queues a look at each, in batches; and the
  saves that change what every card of a site shows queue it by themselves.

  `async: false` — the plugin registry, the site cache and the settings cache are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.{
    PageShareCardTargets,
    ShareCard,
    SettingShareCards,
    SiteShareCards,
    TranslationShareCards
  }

  alias MishkaCmsCore.Runtime.ShareCardRedrawAllTest.RedrawSeo
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Translation

  alias MishkaCmsCore.Runtime.Workers.{
    ShareCardPlanWorker,
    ShareCardRefreshWorker,
    ShareCardSweepWorker
  }

  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.{EventCannotRun, ShareCardLookWorker}
  alias MishkaCmsCore.Test.Plugins.ShareCardProducer
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :capture_log

  setup do
    snapshot = SettingsState.snapshot()
    :persistent_term.put({ShareCardProducer, :reads}, 0)

    on_exit(fn ->
      SettingsState.restore(snapshot)
      :persistent_term.erase({ShareCardProducer, :count})
      :persistent_term.erase({ShareCardProducer, :reads})
    end)

    site = cached!(create_site!(active: true))
    %{site: site}
  end

  defp cached!(site) do
    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: "cards-#{System.unique_integer([:positive])}.test",
        priority: site.priority,
        active: true,
        master: site.master
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp register!(plugins) do
    for plugin <- plugins do
      {:ok, _} =
        Event.write(%{
          name: plugin,
          event: plugin.config(:__event__),
          extension: :mishka_installer,
          status: :started
        })
    end

    events = plugins |> Enum.map(& &1.config(:__event__)) |> Enum.uniq()
    for event <- events, do: :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      for plugin <- plugins, do: Event.unregister(:name, plugin, false)
      for event <- events, do: EventHandler.do_compile(event, :start, false)
    end)
  end

  defp producers!, do: register!([PageShareCardTargets, ShareCardProducer])

  defp planned(site_id), do: all_enqueued(worker: ShareCardPlanWorker, args: %{site_id: site_id})

  describe "targets/2" do
    setup do: producers!()

    test "collects each producer's targets under its name: the core's pages, and the others'", %{
      site: site
    } do
      page = create_page!(site_id: site.id, path: "/about")
      _records = create_page!(site_id: site.id, path: "/things/:slug", extra: %{"record" => "x"})
      _off = create_page!(site_id: site.id, path: "/draft", active: false)
      _elsewhere = create_page!(site_id: create_site!().id, path: "/about")

      assert {:ok, %{"mishka_cms_core" => core, "test_producer" => mine}} =
               ShareCard.targets(site.id)

      assert core == [{:page, page.id}]
      assert {:record, "test:thing", %{"slug" => "thing-1"}} in mine
      assert length(mine) == 6
    end

    test "with a producer, asks that one alone: the others read nothing", %{site: site} do
      create_page!(site_id: site.id, path: "/about")

      assert {:ok, targets} = ShareCard.targets(site.id, producer: "test_producer")
      assert Map.keys(targets) == ["test_producer"]

      assert {:ok, targets} = ShareCard.targets(site.id, producer: "mishka_cms_core")
      assert Map.keys(targets) == ["mishka_cms_core"]
      assert :persistent_term.get({ShareCardProducer, :reads}) == 1

      assert ShareCard.targets(site.id, producer: "nobody") == {:ok, %{}}
    end

    test "producers/1 names whoever answers, reading nothing", %{site: site} do
      assert ShareCard.producers(site.id) == ["mishka_cms_core", "test_producer"]
      assert ShareCard.producers(nil) == ["mishka_cms_core", "test_producer"]
      assert :persistent_term.get({ShareCardProducer, :reads}) == 0
    end

    test "says so while the event cannot run", %{site: site} do
      EventCannotRun.stub!(ShareCard.targets_event())
      assert ShareCard.targets(site.id) == {:error, :cannot_run}
    end
  end

  describe "redraw_all/2" do
    test "queues one planner on :share_cards, and a burst is that one", %{site: site} do
      for _click <- 1..3, do: assert({:ok, [_]} = ShareCard.redraw_all(site.id))

      assert [job] = planned(site.id)
      assert job.queue == "share_cards"
      assert job.args == %{"site_id" => site.id, "force" => false, "producer" => nil}
    end

    test "a forced one, or one for a single producer, is a planner of its own", %{site: site} do
      {:ok, _} = ShareCard.redraw_all(site.id)
      {:ok, _} = ShareCard.redraw_all(site.id, force: true)
      {:ok, _} = ShareCard.redraw_all(site.id, force: true, producer: "test_producer")
      {:ok, _} = ShareCard.redraw_all(site.id, force: true, producer: "test_producer")

      assert planned(site.id) |> Enum.map(&{&1.args["force"], &1.args["producer"]}) |> Enum.sort() ==
               [{false, nil}, {true, nil}, {true, "test_producer"}]
    end

    test "for nil, queues one for every active site", %{site: site} do
      other = cached!(create_site!(active: true))
      ids = Enum.map(SiteState.get_active_sites(), & &1.id)

      assert {:ok, queued} = ShareCard.redraw_all(nil)
      assert Enum.sort(queued) == Enum.sort(ids)
      assert [_] = planned(site.id)
      assert [_] = planned(other.id)
    end

    test "waits as long as it is asked", %{site: site} do
      {:ok, _} = ShareCard.redraw_all(site.id, schedule_in: 10)

      assert [job] = planned(site.id)
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) in 8..10
    end
  end

  describe "the planner" do
    setup do: producers!()

    test "queues a look at each target with its force, each producer's job as it is, once each",
         %{site: site} do
      page = create_page!(site_id: site.id, path: "/about")
      MishkaCmsCore.Repo.delete_all(Oban.Job)
      :ok = Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, ShareCardPlanWorker.planned_topic())

      assert :ok =
               perform_job(ShareCardPlanWorker, %{site_id: site.id, force: true, producer: nil})

      looks = all_enqueued(worker: ShareCardRefreshWorker)
      targets = Enum.map(looks, &ShareCard.decode(&1.args["target"]))

      assert length(looks) == 4
      assert {:page, page.id} in targets
      assert Enum.all?(looks, &(&1.args["force"] and &1.queue == "share_cards"))

      assert [own] = all_enqueued(worker: ShareCardLookWorker)
      assert own.args == %{"site_id" => site.id, "theme" => "home", "force" => true}

      assert_received {:share_cards_planned,
                       %{
                         site_id: site_id,
                         force: true,
                         producer: nil,
                         counts: %{"mishka_cms_core" => 1, "test_producer" => 4}
                       }}

      assert site_id == site.id
    end

    test "asked for every producer, queues the sweep after the looks; for one, none", %{
      site: site
    } do
      before = System.os_time(:second)
      :ok = perform_job(ShareCardPlanWorker, %{site_id: site.id, force: false, producer: nil})

      assert [sweep] = all_enqueued(worker: ShareCardSweepWorker)
      assert sweep.args["site_id"] == site.id
      assert sweep.args["since"] >= before and sweep.priority == 9

      MishkaCmsCore.Repo.delete_all(Oban.Job)

      :ok =
        perform_job(ShareCardPlanWorker, %{
          site_id: site.id,
          force: true,
          producer: "test_producer"
        })

      assert all_enqueued(worker: ShareCardSweepWorker) == []
    end

    test "asks only the producer it names", %{site: site} do
      create_page!(site_id: site.id, path: "/about")
      MishkaCmsCore.Repo.delete_all(Oban.Job)

      :ok =
        perform_job(ShareCardPlanWorker, %{
          site_id: site.id,
          force: true,
          producer: "test_producer"
        })

      targets = Enum.map(all_enqueued(worker: ShareCardRefreshWorker), & &1.args["target"])
      assert length(targets) == 3
      refute Enum.any?(targets, &Map.has_key?(&1, "page"))
    end

    test "inserts a large site's looks in batches, every one of them", %{site: site} do
      :persistent_term.put({ShareCardProducer, :count}, 1_201)

      :ok = perform_job(ShareCardPlanWorker, %{site_id: site.id, force: false, producer: nil})

      assert length(all_enqueued(worker: ShareCardRefreshWorker)) == 1_201
    end

    test "waits while the targets event cannot run", %{site: site} do
      EventCannotRun.stub!(ShareCard.targets_event())

      assert {:snooze, 30} =
               perform_job(ShareCardPlanWorker, %{site_id: site.id, force: false, producer: nil})

      assert all_enqueued(worker: ShareCardRefreshWorker) == []
    end
  end

  describe "a forced look" do
    test "tells the page plugins the card is to be drawn again", %{site: site} do
      register!([])
      answers_seo!()
      create_page!(site_id: site.id, path: "/things/:slug", extra: %{"record" => "test:thing"})
      target = %{"record" => "test:thing", "params" => %{"slug" => "one"}}

      :ok = perform_job(ShareCardRefreshWorker, %{site_id: site.id, target: target, force: true})
      assert_received {:redraw, true}

      :ok = perform_job(ShareCardRefreshWorker, %{site_id: site.id, target: target, force: false})
      assert_received {:redraw, false}
    end
  end

  defp answers_seo! do
    event = MishkaCmsCore.Runtime.Seo.event()

    {:ok, _} =
      Event.write(%{
        name: RedrawSeo,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      Event.unregister(:name, RedrawSeo, false)
      EventHandler.do_compile(event, :start, false)
    end)
  end

  describe "what every card of a site shows, changed" do
    setup do: register!([SiteShareCards, SettingShareCards, TranslationShareCards])

    test "a site's new address looks at all its cards, a moment later", %{site: site} do
      site
      |> Ash.Changeset.for_update(:update, %{host: "new-address.example.com"}, authorize?: false)
      |> Ash.update!()

      assert [job] = planned(site.id)
      assert job.args["force"] == false
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "its name or logo does; another setting does not", %{site: site} do
      {:ok, _} = Settings.put("seo.robots", "index", site_id: site.id)
      assert planned(site.id) == []

      {:ok, _} = Settings.put("site.logo", "/uploads/logo.png", site_id: site.id)
      {:ok, _} = Settings.put("site.title", "Acme", site_id: site.id)
      assert [_one] = planned(site.id)
    end

    test "a global name or logo looks at every active site", %{site: site} do
      other = cached!(create_site!(active: true))
      {:ok, _} = Settings.put("site.logo", "/logo.png")

      assert [_] = planned(site.id)
      assert [_] = planned(other.id)
    end

    test "a translation of the site's name does; another word does not", %{site: site} do
      {:ok, _} = Settings.put("site.title", "Acme", site_id: site.id)
      MishkaCmsCore.Repo.delete_all(Oban.Job)

      translate!(site.id, "Welcome")
      assert planned(site.id) == []

      translate!(site.id, "Acme")
      assert [_] = planned(site.id)
    end
  end

  defp translate!(site_id, key) do
    Translation
    |> Ash.Changeset.for_create(:register, %{key: key, language: "fa", site_id: site_id},
      authorize?: false
    )
    |> Ash.create!()
  end
end
