# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.ReceiptsTest do
  @moduledoc """
  Receipts for real Ash actions on a core resource (`MishkaCmsCore.Runtime.MediaCategory`), and the
  rule the whole subsystem stands on: a stage is verified only when its own evidence says so.

  Most tests here are sabotage: the action claims what the table does not hold, the row is gone
  after a success, the broadcast never comes, nobody watches, a check raises. Each must leave the
  stage unverified or failed, never verified, and leave the operation's own result untouched.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Agent.{Operation, Receipts}
  alias MishkaCmsCore.Agent.Notifiers.ReceiptHook
  alias MishkaCmsCore.Agent.Stages.{JobDone, JobEnqueued}
  alias MishkaCmsCore.Runtime.MediaCategory

  @endpoint MishkaCmsCore.TestEndpoint

  @create Operation.new!(%{
            name: "cms_core:media_category:create",
            resource: MediaCategory,
            action: :create,
            master_action: :master_create,
            visibility: ["admin:dashboard:runtime:media", "admin:api:runtime:media"],
            stages: [
              :dispatched,
              :validated,
              :action_committed,
              {:db_read_back, expect: [name: :claimed, archived_at: :absent]},
              :broadcast_published,
              :ui_observed
            ],
            required: [:action_committed, :db_read_back]
          })

  @update Operation.new!(%{
            name: "cms_core:media_category:update",
            resource: MediaCategory,
            action: :update,
            visibility: ["admin:dashboard:runtime:media"],
            stages: [
              :dispatched,
              :validated,
              :action_committed,
              {:db_read_back, expect: [name: :claimed]}
            ],
            required: [:action_committed, :db_read_back]
          })

  setup do
    Receipts.switch(true)
    on_exit(fn -> Receipts.switch(false) end)

    site = create_site!(name: "rcpt#{System.unique_integer([:positive])}")
    master = create_user_with_permissions!(["admin:dashboard:*"])
    {:ok, site: site, master: master}
  end

  defp create(site, master, name \\ "Covers") do
    MediaCategory
    |> Ash.Changeset.for_create(:create, %{name: name},
      tenant: site.id,
      actor: master,
      authorize?: false
    )
  end

  defp stage(receipt, name), do: Enum.find(receipt.stages, &(&1.name == name))

  describe "run/3 on a real action" do
    test "a create that did what it said is verified, each stage by its own evidence", %{
      site: site,
      master: master
    } do
      assert {:ok, category, receipt} =
               Receipts.run(@create, create(site, master), source: :agent)

      assert receipt.status == :verified
      assert receipt.subject_id == category.id
      assert receipt.site_id == site.id
      assert receipt.actor == %{id: master.id, kind: :master}
      assert receipt.source == :agent

      assert %{status: :verified, layer: :app} = stage(receipt, :dispatched)
      assert %{status: :verified, observed: %{valid?: true}} = stage(receipt, :validated)

      assert %{status: :verified, observed: %{source: :return_value}} =
               stage(receipt, :action_committed)

      assert %{status: :verified, layer: :db, observed: %{name: :matches, archived_at: :absent}} =
               stage(receipt, :db_read_back)

      assert %{status: :verified, observed: %{correlated: :receipt, event: "create"}} =
               stage(receipt, :broadcast_published)

      assert %{status: :unverified, reason: :no_observer, layer: :ui} =
               stage(receipt, :ui_observed)

      assert {:ok, ^receipt} = Receipts.get(receipt.id, master)
    end

    test "the read-back is one query, and nothing else is added to the action", %{
      site: site,
      master: master
    } do
      plain = count_queries(fn -> Ash.create!(create(site, master, "Plain")) end)
      tracked = count_queries(fn -> Receipts.run(@create, create(site, master, "Tracked")) end)

      assert tracked - plain == 1
    end

    test "with receipts off it is the action alone: no receipt, no extra query", %{
      site: site,
      master: master
    } do
      Receipts.switch(false)

      plain = count_queries(fn -> Ash.create!(create(site, master, "Plain")) end)

      tracked =
        count_queries(fn ->
          assert {:ok, %MediaCategory{}, nil} = Receipts.run(@create, create(site, master, "Off"))
        end)

      assert tracked == plain
    end

    test "a refused changeset fails validation, and nothing after it is verified", %{
      site: site,
      master: master
    } do
      changeset = create(site, master, "")
      assert {:error, %Ash.Error.Invalid{}, receipt} = Receipts.run(@create, changeset)

      assert receipt.status == :failed

      assert %{status: :failed, reason: :invalid, observed: %{fields: [:name]}} =
               stage(receipt, :validated)

      assert %{status: :failed, reason: :refused} = stage(receipt, :action_committed)

      for name <- [:db_read_back, :broadcast_published, :ui_observed],
          do: assert(%{status: :unverified, reason: :not_reached} = stage(receipt, name))

      assert :name in receipt.error.fields
    end

    test "an action that claims what the table does not hold fails the read-back", %{
      site: site,
      master: master
    } do
      category = create_media_category!(site_id: site.id, name: "Original")

      changeset =
        category
        |> Ash.Changeset.for_update(:update, %{description: "touched"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.Changeset.after_action(fn _changeset, record ->
          {:ok, %{record | name: "Claimed"}}
        end)

      assert {:ok, %{name: "Claimed"}, receipt} = Receipts.run(@update, changeset)

      assert %{status: :verified} = stage(receipt, :action_committed)

      assert %{
               status: :failed,
               reason: :mismatch,
               expected: %{name: :claimed},
               observed: %{name: :differs}
             } =
               stage(receipt, :db_read_back)

      assert receipt.status == :failed
    end

    test "a success whose row is gone is not verified: the read-back can fail", %{
      site: site,
      master: master
    } do
      changeset =
        site
        |> create(master, "Vanishing")
        |> Ash.Changeset.after_action(fn _changeset, record ->
          {:ok, id} = Ecto.UUID.dump(record.id)
          MishkaCmsCore.Repo.query!("DELETE FROM media_categories WHERE id = $1", [id])
          {:ok, record}
        end)

      assert {:ok, %MediaCategory{}, receipt} = Receipts.run(@create, changeset)

      assert %{status: :verified} = stage(receipt, :action_committed)
      assert %{status: :failed, reason: :not_found} = stage(receipt, :db_read_back)
      assert receipt.status == :failed
    end

    test "an action that is not the declared one fails the dispatch", %{
      site: site,
      master: master
    } do
      category = create_media_category!(site_id: site.id)

      changeset =
        Ash.Changeset.for_update(category, :update, %{name: "Renamed"},
          tenant: site.id,
          authorize?: false
        )

      assert {:ok, _category, receipt} = Receipts.run(@create, changeset, actor: master)
      assert %{status: :failed, reason: :wrong_action} = stage(receipt, :dispatched)
      assert receipt.status == :failed
    end

    test "an undeclared operation is kept, and never verified", %{site: site, master: master} do
      assert {:ok, _category, receipt} =
               Receipts.run("nobody:declared:this", create(site, master))

      assert %{status: :unverified, reason: :undeclared} = stage(receipt, :dispatched)
      assert receipt.status == :partial
      assert receipt.required == []
    end
  end

  describe "the broadcast" do
    test "with no broadcast on the topic the stage is unverified, never verified", %{
      site: site,
      master: master
    } do
      operation =
        Operation.new!(%{
          name: "cms_core:media_category:create",
          resource: MediaCategory,
          action: :create,
          stages: [:action_committed, {:broadcast_published, topics: ["media_category:silent"]}],
          required: [:action_committed, :broadcast_published]
        })

      assert {:ok, _category, receipt} = Receipts.run(operation, create(site, master))
      assert %{status: :unverified, reason: :timeout} = stage(receipt, :broadcast_published)
      assert receipt.status == :partial
    end

    test "another operation's broadcast on the same topic is not this one's", %{
      site: site,
      master: master
    } do
      operation =
        Operation.new!(%{
          name: "cms_core:media_category:create",
          resource: MediaCategory,
          action: :create,
          stages: [
            :action_committed,
            {:broadcast_published, topics: ["media_category:#{site.id}:created"]}
          ],
          required: [:broadcast_published]
        })

      {_result, receipt} =
        Receipts.track(
          operation,
          [resource: MediaCategory, action: :create, actor: master],
          fn _id ->
            # Created outside the receipt: its notification carries no receipt id and another record.
            {:ok, create_media_category!(site_id: site.id)}
          end
        )

      assert %{status: :unverified, reason: :timeout} = stage(receipt, :broadcast_published)
      assert receipt.actor == %{id: master.id, kind: :master}
    end

    test "the caller's own mailbox is left alone", %{site: site, master: master} do
      MishkaCmsCore.TestEndpoint.subscribe("media_category:#{site.id}:created")

      assert {:ok, category, %{status: :verified}} = Receipts.run(@create, create(site, master))

      assert_received %Phoenix.Socket.Broadcast{event: "create", payload: %{data: %{id: id}}}
      assert id == category.id
    end
  end

  describe "the LiveView" do
    test "a mounted observer verifies :ui_observed with its module, and nothing of its assigns",
         %{
           site: site,
           master: master
         } do
      {:ok, view, _html} =
        live_isolated(Phoenix.ConnTest.build_conn(), MishkaCmsCore.Test.ReceiptObserverHostLive,
          session: %{"topic" => "media_category:#{site.id}:created"}
        )

      assert {:ok, _category, receipt} = Receipts.run(@create, create(site, master, "Watched"))
      assert render(view) =~ "1"

      assert {:ok, read} = Receipts.get(receipt.id, master)

      assert %{status: :verified, layer: :ui, observed: observed} = stage(read, :ui_observed)
      assert observed.view == MishkaCmsCore.Test.ReceiptObserverHostLive
      assert Map.keys(observed) |> Enum.sort() == [:event, :topic, :view]
    end
  end

  describe "track/3" do
    test "the id is the process's current receipt and the Logger's while it runs, and nests" do
      operation =
        Operation.new!(%{
          name: "test:nest",
          stages: [:action_committed],
          required: [:action_committed]
        })

      {{outer, inner, during}, receipt} =
        Receipts.track(operation, [], fn outer_id ->
          {inner, _inner_receipt} =
            Receipts.track(operation, [], fn inner_id -> Receipts.current() == inner_id end)

          {Receipts.current() == outer_id, inner, Logger.metadata()[:receipt_id]}
        end)

      assert outer == true
      assert inner == true
      assert during == receipt.id
      assert Receipts.current() == nil
      assert Logger.metadata()[:receipt_id] == nil
    end

    test "a check that raises fails its stage, keeps no message, and leaves the result alone" do
      operation =
        Operation.new!(%{
          name: "test:raises",
          stages: [:action_committed, {:side_effect, :boom, check: &__MODULE__.boom/1}],
          required: [:action_committed, :boom]
        })

      assert {{:ok, :kept}, receipt} = Receipts.track(operation, [], fn _id -> {:ok, :kept} end)

      assert %{status: :failed, reason: :raised, observed: %{error: RuntimeError}} =
               stage(receipt, :boom)

      assert receipt.status == :failed
      refute inspect(receipt) =~ "secret"
    end

    test "work that raises is re-raised as it was, and the receipt says it failed" do
      operation =
        Operation.new!(%{
          name: "test:work-raises",
          stages: [:action_committed],
          required: [:action_committed]
        })

      assert_raise RuntimeError, "a secret in the message", fn ->
        Receipts.track(operation, [], fn _id -> raise "a secret in the message" end)
      end

      master = create_user_with_permissions!(["admin:dashboard:*"])
      [receipt] = Receipts.recent(master, operation: "test:work-raises", limit: 1)
      assert receipt.status == :failed
      assert receipt.error.module == RuntimeError
      refute inspect(receipt) =~ "secret"
    end

    test "nothing of the record or the error text is kept", %{site: site, master: master} do
      {:error, _error, receipt} =
        MediaCategory
        |> Ash.Changeset.for_create(:create, %{name: "", description: "Top secret plan"},
          tenant: site.id,
          authorize?: false
        )
        |> then(&Receipts.run(@create, &1))

      {:ok, _category, ok_receipt} =
        Receipts.run(@create, create(site, master, "Top secret plan"))

      for receipt <- [receipt, ok_receipt], do: refute(inspect(receipt) =~ "Top secret")
    end

    test "a column's text is compared and never stored, however short", %{
      site: site,
      master: master
    } do
      operation =
        Operation.new!(%{
          name: "cms_core:media_category:create",
          resource: MediaCategory,
          action: :create,
          stages: [
            :action_committed,
            {:db_read_back, expect: [name: "Hushhush", description: "Other"]}
          ],
          required: [:db_read_back]
        })

      {:ok, _category, receipt} = Receipts.run(operation, create(site, master, "Hushhush"))

      assert %{
               status: :failed,
               reason: :mismatch,
               observed: %{name: :present, description: :absent}
             } =
               stage(receipt, :db_read_back)

      refute inspect(receipt) =~ "Hushhush"
    end

    test "stage/2 adds evidence only the caller has, and a declared stage takes it" do
      operation =
        Operation.new!(%{
          name: "test:manual",
          stages: [:action_committed, {:side_effect, :mailed, check: &__MODULE__.boom/1}],
          required: [:action_committed, :mailed]
        })

      {:ok, receipt} =
        Receipts.track(operation, [], fn _id ->
          Receipts.stage(:mailed, fn -> {:ok, %{delivered: 1}} end)
          Receipts.stage(:extra, fn -> {:unverified, :later} end)
          :ok
        end)

      assert %{status: :verified, observed: %{delivered: 1}} = stage(receipt, :mailed)
      assert %{status: :unverified, kind: :side_effect} = stage(receipt, :extra)
      assert receipt.status == :verified
    end

    test "the notifier marks the commit as heard after the transaction" do
      operation =
        Operation.new!(%{
          name: "test:notified",
          stages: [:action_committed],
          required: [:action_committed]
        })

      {:ok, receipt} =
        Receipts.track(operation, [], fn id ->
          ReceiptHook.notify(%Ash.Notifier.Notification{
            changeset: %{context: %{shared: %{receipt_id: id}}}
          })

          :ok
        end)

      assert %{observed: %{source: :notifier}} = stage(receipt, :action_committed)
    end
  end

  describe "jobs" do
    @job Operation.new!(%{
           name: "test:job",
           stages: [
             :action_committed,
             {:job_enqueued, worker: MishkaCmsCore.Test.ReceiptWorker},
             {:job_done, worker: MishkaCmsCore.Test.ReceiptWorker},
             JobEnqueued.sitemap(),
             JobDone.sitemap()
           ],
           required: [:action_committed, :job_enqueued, :job_done]
         })

    test "an enqueued job is read back, and its result arrives later", %{master: master} do
      {{:ok, job}, receipt} =
        Receipts.track(@job, [], fn _id ->
          %{} |> MishkaCmsCore.Test.ReceiptWorker.new(meta: Receipts.job_meta()) |> Oban.insert()
        end)

      assert job.meta["receipt_id"] == receipt.id

      assert %{status: :verified, observed: %{correlated: :receipt}} =
               stage(receipt, :job_enqueued)

      assert %{status: :unverified, reason: :pending} = stage(receipt, :job_done)
      assert %{status: :skipped, reason: :off} = stage(receipt, :sitemap_job)
      assert %{status: :skipped, reason: :off} = stage(receipt, :sitemap_built)
      assert receipt.status == :partial

      :ok =
        Oban.Testing.perform_job(MishkaCmsCore.Test.ReceiptWorker, %{},
          meta: %{"receipt_id" => receipt.id}
        )

      assert {:ok, %{status: :verified} = read} = Receipts.get(receipt.id, master)
      assert %{status: :verified, observed: %{state: :success}} = stage(read, :job_done)
    end

    test "a job that raised fails the receipt when it is heard", %{master: master} do
      {_result, receipt} =
        Receipts.track(@job, [], fn _id ->
          %{"fail" => true}
          |> MishkaCmsCore.Test.ReceiptWorker.new(meta: Receipts.job_meta())
          |> Oban.insert()
        end)

      assert_raise RuntimeError, fn ->
        Oban.Testing.perform_job(MishkaCmsCore.Test.ReceiptWorker, %{"fail" => true},
          meta: %{"receipt_id" => receipt.id}
        )
      end

      assert {:ok, %{status: :failed} = read} = Receipts.get(receipt.id, master)
      assert %{status: :failed} = stage(read, :job_done)
    end

    test "no job is not a verified job" do
      {:ok, receipt} = Receipts.track(@job, [], fn _id -> :ok end)

      assert %{status: :failed, reason: :not_found} = stage(receipt, :job_enqueued)
      assert receipt.status == :failed
    end
  end

  describe "reading" do
    setup %{site: site} do
      other = create_site!(name: "rcptother#{System.unique_integer([:positive])}")

      {:ok, category, receipt} =
        Receipts.run(@create, create(site, nil, "Shared"))

      {:ok, other: other, receipt: receipt, category: category}
    end

    test "a master full admin reads it, on either surface it holds", %{
      master: master,
      receipt: receipt
    } do
      assert {:ok, _} = Receipts.get(receipt.id, master)
      assert {:error, :not_found} = Receipts.get(receipt.id, master, surface: :api)

      api_master = create_user_with_permissions!(["admin:api:*"])
      assert {:ok, _} = Receipts.get(receipt.id, api_master, surface: :api)
    end

    test "a site admin reads its own site's receipts in its own area", %{
      site: site,
      receipt: receipt
    } do
      reader =
        create_user_with_permissions!(
          ["admin:dashboard:runtime:media", "admin:dashboard:agent:receipts"],
          site_id: site.id
        )

      assert {:ok, _} = Receipts.get(receipt.id, reader)
      assert [%{id: id}] = Receipts.recent(reader, operation: @create.name)
      assert id == receipt.id
    end

    test "another site, another area, no receipts permission, or nobody: not found", %{
      site: site,
      other: other,
      receipt: receipt
    } do
      outsiders = [
        create_user_with_permissions!(
          ["admin:dashboard:runtime:media", "admin:dashboard:agent:receipts"],
          site_id: other.id
        ),
        create_user_with_permissions!(
          ["admin:dashboard:runtime:page", "admin:dashboard:agent:receipts"],
          site_id: site.id
        ),
        create_user_with_permissions!(["admin:dashboard:runtime:media"], site_id: site.id),
        nil
      ]

      for viewer <- outsiders do
        assert {:error, :not_found} = Receipts.get(receipt.id, viewer)
        assert Receipts.recent(viewer) |> Enum.map(& &1.id) |> Enum.member?(receipt.id) == false
      end
    end

    test "a filter narrows and never widens", %{site: site, other: other, receipt: receipt} do
      reader =
        create_user_with_permissions!(
          ["admin:dashboard:runtime:media", "admin:dashboard:agent:receipts"],
          site_id: site.id
        )

      assert Receipts.recent(reader, site_id: other.id) == []
      assert [_ | _] = Receipts.recent(reader, site_id: site.id, status: :verified)
      assert Receipts.recent(reader, status: :failed) |> Enum.all?(&(&1.status == :failed))
      assert Receipts.recent(reader, subject_id: receipt.subject_id) |> length() == 1
    end

    test "an unknown id and a known one the viewer may not read answer the same", %{
      other: other,
      receipt: receipt
    } do
      stranger = create_user_with_permissions!(["*"], site_id: other.id)

      assert Receipts.get(receipt.id, stranger) == Receipts.get("rcpt_doesnotexist", stranger)
    end
  end

  @doc false
  def boom(_ctx), do: raise("a secret in the check")

  defp count_queries(fun) do
    handler = "receipt-query-count-#{System.unique_integer([:positive])}"
    parent = self()
    counter = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:mishka_cms_core, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == parent, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
      :counters.get(counter, 1)
    after
      :telemetry.detach(handler)
    end
  end
end
