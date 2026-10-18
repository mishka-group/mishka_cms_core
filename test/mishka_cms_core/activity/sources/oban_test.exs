# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.ObanTest do
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Sources.Oban, as: ObanSource

  @master_user %{site_id: nil}
  @tenant_user %{site_id: "a103bede-3c79-4f7b-9ece-ad9b391668d2"}
  @site_id "a103bede-3c79-4f7b-9ece-ad9b391668d2"

  @resource MishkaCmsCore.Runtime.Component
  @resource_str "MishkaCmsCore.Runtime.Component"

  describe "topics/1" do
    test "master, no resources → the global topic" do
      assert ObanSource.topics(%{current_user: @master_user}) == ["oban_activity"]
    end

    test "tenant, no resources → their site-scoped topic" do
      assert ObanSource.topics(%{current_user: @tenant_user}) == [
               "oban_activity:site:#{@site_id}"
             ]
    end

    # A MASTER IS A USER WHOSE `site_id` IS NIL; no viewer subscribes to nothing.
    test "no current_user → no topic" do
      assert ObanSource.topics(%{}) == []
      assert ObanSource.topics(%{current_user: nil}) == []
      assert ObanSource.topics(%{current_user: %{}, resources: [@resource]}) == []
    end

    test "master, scoped to a resource → resource topic (any site)" do
      assert ObanSource.topics(%{current_user: @master_user, resources: [@resource]}) == [
               "oban_activity:res:#{@resource_str}"
             ]
    end

    test "tenant, scoped to a resource → site+resource topic" do
      assert ObanSource.topics(%{current_user: @tenant_user, resources: [@resource]}) == [
               "oban_activity:site:#{@site_id}:res:#{@resource_str}"
             ]
    end
  end

  describe "handles?/1" do
    test "true for Oban-tagged payloads" do
      msg = broadcast(%{__oban__: true, job: stub_job(), event: :stop})
      assert ObanSource.handles?(msg)
    end

    test "false for Ash notifications" do
      msg = broadcast(%Ash.Notifier.Notification{resource: MishkaCmsCore.Runtime.Page})
      refute ObanSource.handles?(msg)
    end

    test "false for arbitrary payloads" do
      refute ObanSource.handles?(broadcast(%{something: :else}))
    end
  end

  describe "to_entry/1 — entry shape" do
    test "builds entry with resource_label \"Job\" and short worker name" do
      msg = broadcast(%{__oban__: true, job: stub_job(), event: :stop})
      entry = ObanSource.to_entry(msg)

      assert entry.resource_label == "Job"
      assert entry.action == :stop
      assert entry.badge_label == "WORKER"
      assert entry.badge_tone == :violet
      assert entry.message == "RuntimeCompilerWorker stop"
      assert entry.source_id == "42"
      assert is_binary(entry.id)
      assert %DateTime{} = entry.inserted_at
    end

    test "returns nil for non-Oban broadcasts" do
      assert ObanSource.to_entry(broadcast(%{nope: true})) == nil
    end
  end

  describe "to_entry/1 — message detail from args" do
    test "appends resource short name + record title + action when present" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{"id" => "page-1", "site_id" => @site_id, "title" => "Home"}
        })

      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop}))
      assert entry.message == "RuntimeCompilerWorker stop — Page \"Home\" update"
    end

    test "BootHandler-style args (uses site_name as title)" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
          "action" => "boot_handler",
          "data" => %{"site_name" => "api-mishka-tools", "type" => "asset"}
        })

      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :start}))

      assert entry.message ==
               "RuntimeCompilerWorker start — BootHandler \"api-mishka-tools\" boot_handler"
    end

    test "falls back to data.name when title is missing" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Component",
          "action" => "create",
          "data" => %{"id" => "c-1", "name" => "header"}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Component \"header\" create"
    end

    test "exception event preserves detail" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{"title" => "Home"}
        })

      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :exception}))
      assert entry.severity == :error
      assert entry.message == "RuntimeCompilerWorker exception — Page \"Home\" update"
    end

    test "missing data → resource + action only" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update"
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Page update"
    end

    test "deactivate (update into inactive) reads as purged" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{"id" => "page-1", "title" => "Home", "active" => false}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Page \"Home\" purged"
    end

    test "destroy reads as purged" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "destroy",
          "data" => %{"id" => "page-1", "title" => "Home"}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Page \"Home\" purged"
    end

    test "SiteTeardownWorker reads as a site teardown" do
      job = %Oban.Job{
        id: 99,
        worker: "MishkaCmsCore.Runtime.Workers.SiteTeardownWorker",
        queue: "maintenance",
        state: "executing",
        args: %{
          "site_id" => "site-1",
          "site_name" => "teardown-test",
          "modules" => [%{"type" => "Page", "key" => "p-1"}]
        },
        inserted_at: ~U[2026-05-30 00:00:00Z],
        scheduled_at: ~U[2026-05-30 00:00:00Z]
      }

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "SiteTeardownWorker stop — Site \"teardown-test\" torn down"

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :start})).message ==
               "SiteTeardownWorker start — Site \"teardown-test\" tearing down"
    end

    test "SiteRuntimeWorker's provision reads as a site getting its sign-in pages" do
      job = %Oban.Job{
        id: 100,
        worker: "MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker",
        queue: "maintenance",
        state: "executing",
        args: %{
          "site_id" => "site-1",
          "site_name" => "new-site",
          "old_name" => "new-site",
          "transition" => "provision"
        },
        inserted_at: ~U[2026-05-30 00:00:00Z],
        scheduled_at: ~U[2026-05-30 00:00:00Z]
      }

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "SiteRuntimeWorker stop — Site \"new-site\" given its sign-in pages"

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :start})).message ==
               "SiteRuntimeWorker start — Site \"new-site\" getting its sign-in pages"
    end

    test "active precompiled update reads as compiled" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{"id" => "page-1", "title" => "Home", "active" => true, "precompile" => true}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Page \"Home\" compiled"
    end

    test "active non-precompiled update keeps its raw action (compiles on demand)" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{
            "id" => "page-1",
            "title" => "Home",
            "active" => true,
            "precompile" => false
          }
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Page \"Home\" update"
    end

    test "active component (no precompile flag) reads as compiled" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Component",
          "action" => "update",
          "data" => %{"id" => "c-1", "name" => "header", "active" => true}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop — Component \"header\" compiled"
    end

    test "start event uses present tense (compiling / purging)" do
      compile =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Component",
          "action" => "update",
          "data" => %{"id" => "c-1", "name" => "header", "active" => true}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: compile, event: :start})).message ==
               "RuntimeCompilerWorker start — Component \"header\" compiling"

      purge =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{"id" => "p-1", "title" => "Home", "active" => false}
        })

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: purge, event: :start})).message ==
               "RuntimeCompilerWorker start — Page \"Home\" purging"
    end

    test "empty args → no detail appended" do
      job = stub_job(%{})

      assert ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop})).message ==
               "RuntimeCompilerWorker stop"
    end
  end

  describe "to_entry/1 — severity mapping" do
    for {event, expected} <- [
          {:start, :info},
          {:stop, :info},
          {:exception, :error},
          {:discarded, :error},
          {:retryable, :warn}
        ] do
      test "event #{inspect(event)} → severity #{inspect(expected)}" do
        msg = broadcast(%{__oban__: true, job: stub_job(), event: unquote(event)})
        assert ObanSource.to_entry(msg).severity == unquote(expected)
      end
    end
  end

  describe "to_entry/1 — site_id extraction" do
    test "top-level args[\"site_id\"]" do
      job = stub_job(%{"site_id" => @site_id})
      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop}))
      assert entry.site_id == @site_id
    end

    test "nested args[\"data\"][\"site_id\"] (RuntimeCompilerWorker shape)" do
      job =
        stub_job(%{
          "resource" => "MishkaCmsCore.Runtime.Page",
          "action" => "update",
          "data" => %{"id" => "page-1", "site_id" => @site_id, "title" => "Home"}
        })

      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop}))
      assert entry.site_id == @site_id
    end

    test "no site_id anywhere → nil (treated as global)" do
      job = stub_job(%{"action" => "boot_handler", "data" => %{"type" => "asset"}})
      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :start}))
      assert entry.site_id == nil
    end

    test "non-binary site_id is ignored" do
      job = stub_job(%{"site_id" => 123})
      entry = ObanSource.to_entry(broadcast(%{__oban__: true, job: job, event: :stop}))
      assert entry.site_id == nil
    end
  end

  describe "handle_telemetry/4" do
    test "broadcasts wrapped %Phoenix.Socket.Broadcast{} to global topic for jobs without site_id" do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "oban_activity")

      job = stub_job()
      ObanSource.handle_telemetry([:oban, :job, :stop], %{}, %{job: job}, nil)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "oban_activity",
        payload: %{__oban__: true, event: :stop}
      }
    end

    test "fans out to global, site, resource and site+resource topics" do
      res = "MishkaCmsCore.Runtime.Page"

      for topic <- [
            "oban_activity",
            "oban_activity:site:#{@site_id}",
            "oban_activity:res:#{res}",
            "oban_activity:site:#{@site_id}:res:#{res}"
          ] do
        Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
      end

      job =
        stub_job(%{
          "resource" => res,
          "action" => "update",
          "data" => %{"id" => "page-1", "site_id" => @site_id, "title" => "Home"}
        })

      ObanSource.handle_telemetry([:oban, :job, :stop], %{}, %{job: job}, nil)

      assert_receive %Phoenix.Socket.Broadcast{topic: "oban_activity"}
      assert_receive %Phoenix.Socket.Broadcast{topic: "oban_activity:site:" <> _}
      assert_receive %Phoenix.Socket.Broadcast{topic: "oban_activity:res:" <> _}
      assert_receive %Phoenix.Socket.Broadcast{topic: "oban_activity:site:" <> rest}
      assert rest == "#{@site_id}:res:#{res}" or rest == @site_id
    end

    test "a job without a resource is not broadcast on any resource topic" do
      Phoenix.PubSub.subscribe(
        MishkaCmsCore.PubSub,
        "oban_activity:res:MishkaCmsCore.Runtime.Page"
      )

      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "oban_activity")

      ObanSource.handle_telemetry([:oban, :job, :stop], %{}, %{job: stub_job()}, nil)

      assert_receive %Phoenix.Socket.Broadcast{topic: "oban_activity"}
      refute_receive %Phoenix.Socket.Broadcast{topic: "oban_activity:res:" <> _}, 200
    end
  end

  defp stub_job(args \\ %{}) do
    %Oban.Job{
      id: 42,
      worker: "MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker",
      queue: "default",
      state: "executing",
      args: args,
      inserted_at: ~U[2026-05-23 19:00:00Z],
      scheduled_at: ~U[2026-05-23 19:00:00Z]
    }
  end

  defp broadcast(payload) do
    %Phoenix.Socket.Broadcast{topic: "test", event: "test", payload: payload}
  end

  # WHO CAUSED THE JOB. `SendToOban.build_job_args/2` stamps the acting user into the args and Oban
  # stores them as JSON, so the feed only ever sees the STRING key. Without this the log answers
  # "System" for every job and a failed compile cannot be tied to the save that caused it.
  describe "the acting user" do
    test "entry_from_row reads the actor the SQL branch selected" do
      row = %{
        "source_id" => "7",
        "resource" => "MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker",
        "action" => "completed",
        "inserted_at" => ~U[2026-01-01 00:00:00Z],
        "site_id" => "s1",
        "user_id" => "u-1",
        "payload" => %{}
      }

      assert ObanSource.entry_from_row(row).user_id == "u-1"
    end

    test "a job nobody triggered stays System" do
      row = %{
        "source_id" => "7",
        "resource" => "MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker",
        "action" => "completed",
        "inserted_at" => ~U[2026-01-01 00:00:00Z],
        "site_id" => "s1",
        "user_id" => nil,
        "payload" => %{}
      }

      assert ObanSource.entry_from_row(row).user_id == nil
    end
  end
end
