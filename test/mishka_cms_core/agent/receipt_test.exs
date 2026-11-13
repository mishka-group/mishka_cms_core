# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.ReceiptTest do
  @moduledoc """
  How stages add up to a verdict: a failure wins, a receipt is verified only by its required stages,
  a skipped stage is never a pass, and late evidence only fills a stage that was still waiting.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Agent.Receipt
  alias MishkaCmsCore.Agent.Receipt.Stage

  defp stage(name, status, kind \\ :side_effect),
    do: %Stage{kind: kind, name: name, status: status, layer: :app}

  describe "status/2" do
    test "a failed stage fails the receipt, whatever else was verified" do
      stages = [stage(:a, :verified), stage(:b, :failed), stage(:c, :verified)]
      assert Receipt.status(stages, [:a, :c]) == :failed
    end

    test "verified needs every required stage verified, and only those" do
      stages = [stage(:a, :verified), stage(:b, :verified), stage(:c, :unverified)]

      assert Receipt.status(stages, [:a, :b]) == :verified
      assert Receipt.status(stages, [:a, :c]) == :partial
    end

    test "a skipped required stage is not a pass" do
      stages = [stage(:a, :verified), stage(:b, :skipped)]
      assert Receipt.status(stages, [:a, :b]) == :partial
    end

    test "the dispatch alone is not progress, and nothing required is never verified" do
      dispatched = stage(:dispatched, :verified, :dispatched)

      assert Receipt.status([dispatched, stage(:a, :unverified)], [:a]) == :unverified
      assert Receipt.status([dispatched, stage(:a, :verified)], []) == :partial
    end
  end

  describe "Stage.new/3" do
    test "the answer is the only way to a status" do
      spec = %{kind: :side_effect, name: :x, layer: :db}

      assert %{status: :verified, observed: %{n: 1}} = Stage.new(spec, {:ok, %{n: 1}})

      assert %{status: :failed, reason: :mismatch, expected: %{n: 1}, observed: %{n: 2}} =
               Stage.new(spec, {:mismatch, %{n: 1}, %{n: 2}})

      assert %{status: :skipped, reason: :off} = Stage.new(spec, {:skip, :off})
      assert %{status: :unverified, reason: :pending} = Stage.new(spec, {:unverified, :pending})
      assert %{status: :failed, reason: :bad_answer} = Stage.new(spec, :verified)
      assert %{status: :failed, reason: :bad_answer} = Stage.new(spec, true)
    end
  end

  describe "with_late/2" do
    test "late evidence fills a waiting stage and the verdict follows" do
      receipt = %Receipt{
        stages: [stage(:a, :verified), %{stage(:job, :unverified, :job_done) | key: "W"}],
        required: [:a, :job]
      }

      late = %{stage(:job_done, :verified, :job_done) | key: "W"}
      assert %{status: :verified} = Receipt.with_late([late], receipt)

      failed = %{stage(:job_done, :failed, :job_done) | key: "W"}
      assert %{status: :failed} = Receipt.with_late([failed], receipt)
    end

    test "late evidence never overwrites a stage that was checked" do
      receipt = %Receipt{
        stages: [%{stage(:ui, :failed, :ui_observed) | key: nil}],
        required: [:ui]
      }

      late = stage(:ui_observed, :verified, :ui_observed)

      assert %{status: :failed} = Receipt.with_late([late], receipt)
    end

    test "late evidence for another worker is not this stage's" do
      receipt = %Receipt{
        stages: [%{stage(:job, :unverified, :job_done) | key: "W"}],
        required: [:job]
      }

      late = %{stage(:job_done, :verified, :job_done) | key: "Other"}

      assert %{status: :unverified} = Receipt.with_late([late], receipt)
    end
  end

  test "to_public/1 is JSON-safe" do
    receipt = %Receipt{
      id: "rcpt_x",
      operation: "a:b:c",
      resource: MishkaCmsCore.Runtime.MediaCategory,
      started_at: DateTime.utc_now(),
      stages: [%{stage(:a, :verified) | at: DateTime.utc_now(), observed: %{status: :ok}}],
      node: node()
    }

    public = receipt |> Receipt.to_public() |> JSON.encode!() |> JSON.decode!()

    assert public["resource"] == "MishkaCmsCore.Runtime.MediaCategory"
    assert [%{"status" => "verified", "observed" => %{"status" => "ok"}}] = public["stages"]
  end

  test "to_public/1 keeps what a saved receipt is checked and merged by later" do
    at = DateTime.utc_now()

    receipt = %Receipt{
      id: "rcpt_x",
      operation: "a:b:c",
      required: [:a],
      visibility: ["admin:dashboard:runtime:media"],
      started_at: at,
      stages: [%{stage(:a, :unverified, :job_done) | at: at, key: "MyWorker"}],
      node: node()
    }

    public = receipt |> Receipt.to_public() |> JSON.encode!() |> JSON.decode!()

    assert public["required"] == ["a"]
    assert public["visibility"] == ["admin:dashboard:runtime:media"]
    assert [%{"key" => "MyWorker", "at" => stage_at}] = public["stages"]
    assert {:ok, ^at, 0} = DateTime.from_iso8601(stage_at)
  end

  describe "public_status/2" do
    defp public(stages, required) do
      %Receipt{stages: stages, required: required}
      |> Receipt.to_public()
      |> JSON.encode!()
      |> JSON.decode!()
      |> then(&Receipt.public_status(&1["stages"], &1["required"]))
    end

    test "answers what status/2 answers for the same stages" do
      dispatched = stage(:dispatched, :verified, :dispatched)

      cases = [
        {[stage(:a, :verified), stage(:b, :failed)], [:a]},
        {[stage(:a, :verified), stage(:b, :verified)], [:a, :b]},
        {[stage(:a, :verified), stage(:b, :skipped)], [:a, :b]},
        {[dispatched, stage(:a, :unverified)], [:a]},
        {[dispatched, stage(:a, :verified)], []}
      ]

      for {stages, required} <- cases do
        assert public(stages, required) == to_string(Receipt.status(stages, required))
      end
    end

    test "a late stage merged into a saved receipt changes the verdict the core's way" do
      saved =
        %Receipt{
          stages: [stage(:a, :verified), %{stage(:job, :unverified, :job_done) | key: "W"}],
          required: [:a, :job]
        }
        |> Receipt.to_public()

      assert Receipt.public_status(saved["stages"], saved["required"]) == "partial"

      merged =
        Enum.map(saved["stages"], fn
          %{"name" => "job"} = job -> %{job | "status" => "verified"}
          other -> other
        end)

      assert Receipt.public_status(merged, saved["required"]) == "verified"
    end
  end
end
