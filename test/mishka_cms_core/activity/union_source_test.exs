# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.UnionSourceTest do
  @moduledoc """
  A table of an extension's own joining the activity log, on `activity:sources`.

  The core's branches are the ones every installation has; any other record reaches the log only
  because its owner registered a `MishkaCmsCore.Activity.Behaviours.UnionSource`. With none, the
  query is the core's alone and names no extension's table. With one, its rows come back through
  the same filters as every other row, with its own values bound as parameters, and a source whose
  branch breaks costs its own rows and nobody else's.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Activity.Behaviours.UnionSource
  alias MishkaCmsCore.Activity.Query
  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCore.Test.Plugins.{ActivityUnionBroken, ActivityUnionProbe}
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :capture_log

  @event "activity:sources"

  defp register!(plugin) do
    {:ok, _} =
      Event.write(%{name: plugin, event: @event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(@event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  # Only this process's queries: a telemetry handler hears every process's.
  defp sql_of(fun) do
    handler = "activity-sql-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:mishka_cms_core, :repo, :query],
      fn _event, _measurements, %{query: sql}, _config ->
        if self() == test, do: send(test, {:sql, handler, sql})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)

    {result, collect(handler, [])}
  end

  defp collect(handler, sqls) do
    receive do
      {:sql, ^handler, sql} -> collect(handler, [sql | sqls])
    after
      0 -> Enum.reverse(sqls)
    end
  end

  defp probe_rows(opts \\ %{}),
    do: Enum.filter(Query.page(opts), &(&1.badge_label == "PROBE"))

  describe "with no union source" do
    test "the log reads, and its query names no extension's table" do
      :ok = EventCannotRun.stub!(@event)

      assert UnionSource.all() == []

      {_entries, sqls} = sql_of(fn -> Query.page(%{}) end)

      assert Enum.any?(sqls, &(&1 =~ "UNION ALL"))
      refute Enum.any?(sqls, &(&1 =~ "page_builder_events"))
    end

    test "and every count reads too" do
      :ok = EventCannotRun.stub!(@event)

      total = Query.total(%{})

      assert %{total: ^total} = Query.counts(%{})
      assert Query.day_counts(%{}) |> Map.values() |> Enum.sum() == total
    end
  end

  describe "a registered union source" do
    setup do
      register!(ActivityUnionProbe)
      :ok
    end

    test "is one of the installed sources" do
      assert ActivityUnionProbe in UnionSource.all()
    end

    test "its rows join the log, read back by its own entry_from_row/1" do
      assert [entry] = probe_rows()
      assert entry.id == "probe-probe-row"
      assert entry.message == ActivityUnionProbe.said()
    end

    test "its own value arrives as a parameter, not as text in the query" do
      {_entries, sqls} = sql_of(fn -> Query.page(%{}) end)

      assert Enum.any?(sqls, &(&1 =~ "'probe' AS source"))
      refute Enum.any?(sqls, &(&1 =~ ActivityUnionProbe.said()))
    end

    test "after the tenant's site, when a site is read" do
      site = create_site!()

      assert [_entry] = probe_rows(%{site_id: site.id})
    end

    test "the core's filters narrow it like every other branch" do
      assert [_entry] = probe_rows(%{resource: "Elixir.MishkaCmsCore.Runtime.Page"})
      assert probe_rows(%{resource: "Elixir.MishkaCmsCore.Runtime.Media"}) == []
      assert [_entry] = probe_rows(%{search: "parameter"})
      assert probe_rows(%{search: "nothing like it"}) == []
      assert probe_rows(%{severity: "warn"}) == []
      assert probe_rows(%{kind: "job"}) == []
      assert probe_rows(%{resources: ["Elixir.MishkaCmsCore.Runtime.Media"]}) == []
    end
  end

  describe "a union source's rows" do
    test "are counted with the rest, in every count" do
      before = Query.total(%{})
      register!(ActivityUnionProbe)

      assert Query.total(%{}) == before + 1
      assert %{total: total, info: info} = Query.counts(%{})
      assert total == before + 1
      assert info >= 1
      assert Query.day_counts(%{}) |> Map.values() |> Enum.sum() == before + 1
    end
  end

  describe "a union source whose branch raises" do
    test "is left out, and the other sources still read" do
      register!(ActivityUnionProbe)
      register!(ActivityUnionBroken)

      assert [_entry] = probe_rows()
    end
  end
end
