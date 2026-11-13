# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.ReceiptStoreTest do
  @moduledoc """
  The store stays within its bounds whoever writes to it: the oldest go first, one site cannot push
  out another's, old ones age out, every drop is counted, concurrent writers end within the bound,
  and with no store an operation still returns what it returned.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Agent.{Operation, Receipts, ReceiptStore}

  @operation Operation.new!(%{
               name: "test:store:write",
               stages: [:dispatched, :action_committed],
               required: [:action_committed]
             })

  setup do
    Receipts.switch(true)
    previous = Application.get_env(:mishka_cms_core, Receipts)

    on_exit(fn ->
      Receipts.switch(false)

      if previous,
        do: Application.put_env(:mishka_cms_core, Receipts, previous),
        else: Application.delete_env(:mishka_cms_core, Receipts)
    end)

    :ok
  end

  defp bounds(bounds), do: Application.put_env(:mishka_cms_core, Receipts, bounds)

  defp write(site_id \\ nil) do
    {{:ok, :done}, receipt} =
      Receipts.track(@operation, [site_id: site_id], fn _id -> {:ok, :done} end)

    receipt
  end

  test "keeps the newest and counts what it dropped" do
    bounds(max_receipts: 3, per_site_max: 1_000)
    dropped = ReceiptStore.dropped()

    [first, second | rest] = for _ <- 1..5, do: write()

    assert ReceiptStore.count() <= 3
    assert Receipts.get_unchecked(first.id) == nil
    assert Receipts.get_unchecked(second.id) == nil
    for receipt <- rest, do: assert(%{id: _} = Receipts.get_unchecked(receipt.id))
    assert ReceiptStore.dropped() - dropped >= 2
  end

  test "one site's receipts never push out another site's" do
    bounds(max_receipts: 1_000, per_site_max: 2)
    quiet = write("site-quiet")
    [busy_first | busy_rest] = for _ <- 1..3, do: write("site-busy")

    assert Receipts.get_unchecked(quiet.id)
    assert Receipts.get_unchecked(busy_first.id) == nil
    for receipt <- busy_rest, do: assert(Receipts.get_unchecked(receipt.id))
  end

  test "receipts older than the age bound are dropped" do
    bounds(max_age_seconds: 3_600)
    receipt = write()
    assert Receipts.get_unchecked(receipt.id)

    bounds(max_age_seconds: -1)
    ReceiptStore.sweep()

    assert Receipts.get_unchecked(receipt.id) == nil
  end

  test "concurrent writers end within the bound and every receipt is kept or counted" do
    bounds(max_receipts: 10, per_site_max: 1_000)
    write()
    before = ReceiptStore.count() + ReceiptStore.dropped()

    1..60
    |> Task.async_stream(fn _ -> write() end, max_concurrency: 12)
    |> Stream.run()

    assert ReceiptStore.count() <= 10
    assert ReceiptStore.count() + ReceiptStore.dropped() == before + 60
  end

  test "with no store the operation runs and returns its own result" do
    :ok = Supervisor.terminate_child(MishkaCmsCore.Supervisor, ReceiptStore)
    on_exit(fn -> Supervisor.restart_child(MishkaCmsCore.Supervisor, ReceiptStore) end)

    assert {{:ok, :done}, nil} = Receipts.track(@operation, [], fn _id -> {:ok, :done} end)
    assert ReceiptStore.count() == 0
    assert Receipts.recent(%{id: "x", site_id: nil}) == []
  end

  test "with receipts off nothing is kept and the function still runs" do
    Receipts.switch(false)
    count = ReceiptStore.count()

    assert {:ran, nil} = Receipts.track(@operation, [], fn id -> if(id == nil, do: :ran) end)
    assert ReceiptStore.count() == count
  end
end
