defmodule MishkaCmsCore.Runtime.ShareCardQueueTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.ShareCardQueue`: every share-card job runs on `:share_cards`, and the
  Share-card workers setting scales or pauses that queue — on every node when it is saved, on this
  node's own queue at boot.

  The queue is a real one, in an Oban of the test's own: the Inline engine fetches no job, so it
  draws nothing (and keeps no defaults of its own, so the queue names its `refresh_interval`), and
  the Isolated notifier hands a signal straight to the queue, so its state is read back right after
  it changes. `async: false` — the settings cache, the plugin registry and the
  telemetry handler are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.{ShareCard, ShareCardQueue}
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :capture_log

  @oban __MODULE__.Oban
  @key "share_cards.workers"

  setup do
    snapshot = SettingsState.snapshot()
    on_exit(fn -> SettingsState.restore(snapshot) end)
    Settings.load_definitions()

    start_supervised!(
      {Oban, oban(@oban, share_cards: [limit: 1, paused: true, refresh_interval: 60_000])},
      id: @oban
    )

    :ok
  end

  defp oban(name, queues) do
    [
      name: name,
      repo: @repo,
      engine: Oban.Engines.Inline,
      notifier: Oban.Notifiers.Isolated,
      peer: false,
      stager: false,
      plugins: false,
      queues: queues
    ]
  end

  defp queue, do: Map.take(Oban.check_queue(@oban, queue: :share_cards), [:limit, :paused])

  describe "every share-card job" do
    test "runs on :share_cards" do
      site = create_site!(active: true)

      assert ShareCard.__opts__()[:queue] == :share_cards
      assert ShareCardRefreshWorker.__opts__()[:queue] == :share_cards

      assert ShareCard.image(site.id, %{title: "Launch week"}) == nil
      assert_enqueued(worker: ShareCard, queue: :share_cards)

      :ok = ShareCard.refresh(site.id, {:page, "p1"})
      assert_enqueued(worker: ShareCardRefreshWorker, queue: :share_cards)

      assert all_enqueued(queue: :assets) == []
    end
  end

  describe "scale/2" do
    test "above 0, resumes the queue with that many at once" do
      assert queue() == %{limit: 1, paused: true}

      assert :ok = ShareCardQueue.scale(3, oban: @oban)
      assert queue() == %{limit: 3, paused: false}
    end

    test "0 pauses it, and a later number resumes it" do
      :ok = ShareCardQueue.scale(2, oban: @oban)

      assert :ok = ShareCardQueue.scale(0, oban: @oban)
      assert queue() == %{limit: 2, paused: true}

      assert :ok = ShareCardQueue.scale(1, oban: @oban)
      assert queue() == %{limit: 1, paused: false}
    end

    test "a number outside 0..4 is held to it" do
      :ok = ShareCardQueue.scale(9, oban: @oban)
      assert queue() == %{limit: 4, paused: false}

      :ok = ShareCardQueue.scale(-1, oban: @oban)
      assert queue() == %{limit: 4, paused: true}
    end

    test "says so when the queue is not on this node, or Oban is not running" do
      start_supervised!({Oban, oban(__MODULE__.Bare, [])}, id: __MODULE__.Bare)

      assert ShareCardQueue.scale(1, oban: __MODULE__.Bare, local_only: true) ==
               {:error, :no_queue}

      assert ShareCardQueue.scale(1, oban: __MODULE__.Nowhere) == {:error, :not_running}
    end
  end

  describe "boot/1" do
    test "starts the queue with the stored number" do
      {:ok, 3} = Settings.put(@key, 3)

      assert :ok = ShareCardQueue.boot(oban: @oban)
      assert queue() == %{limit: 3, paused: false}
    end

    test "leaves it paused when the stored number is 0" do
      {:ok, 0} = Settings.put(@key, 0)

      assert :ok = ShareCardQueue.boot(oban: @oban)
      assert queue() == %{limit: 1, paused: true}
    end

    test "starts it with 1 when nothing is stored" do
      SettingsState.delete(nil, @key)

      assert ShareCardQueue.workers() == 1
      assert :ok = ShareCardQueue.boot(oban: @oban)
      assert queue() == %{limit: 1, paused: false}
    end

    test "a node with no :share_cards queue says how to add one" do
      start_supervised!({Oban, oban(__MODULE__.Bare, [])}, id: __MODULE__.Bare)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ShareCardQueue.boot(oban: __MODULE__.Bare) == {:error, :no_queue}
        end)

      assert log =~ "share_cards: [limit: 1, paused: true]"
    end
  end

  describe "the setting" do
    test "is a master's number from 0 to 4 on the SEO tab, 1 by default" do
      assert %{
               type: :integer,
               default: 1,
               min: 0,
               max: 4,
               scope: :master,
               category: "seo"
             } = Settings.definition(@key)

      assert Settings.cast(Settings.definition(@key), "7") == {:ok, 4}
      assert Settings.cast(Settings.definition(@key), "-2") == {:ok, 0}
      assert Settings.cast(Settings.definition(@key), "two") == :error
    end
  end

  describe "a save of the setting" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: ShareCardQueue,
          event: ShareCardQueue.config(:__event__),
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(ShareCardQueue.config(:__event__), :start, false)
      on_exit(fn -> Event.unregister(:name, ShareCardQueue, false) end)

      test = self()
      handler = "share-card-queue-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:oban, :notifier, :notify, :start],
        fn _event, _measure, %{channel: :signal, payload: payload}, _config ->
          if payload[:queue] == :share_cards, do: send(test, {:signal, payload})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "scales the queue on every node of the cluster" do
      {:ok, 2} = Settings.put(@key, 2)

      assert_received {:signal, %{action: :scale, limit: 2, ident: :any}}
      assert_received {:signal, %{action: :resume, ident: :any}}
    end

    test "to 0 pauses it on every node" do
      {:ok, 0} = Settings.put(@key, 0)

      assert_received {:signal, %{action: :pause, ident: :any}}
      refute_received {:signal, %{action: :resume}}
    end

    test "of another setting, or of a site's own row, leaves the queue alone" do
      site = create_site!(active: true)

      {:ok, _} = Settings.put("site.title", "Acme")
      {:ok, _} = Settings.put(@key, 3, site_id: site.id)

      refute_received {:signal, _payload}
    end
  end
end
