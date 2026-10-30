# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.ActivityAreasTest do
  @moduledoc """
  The Activity log is the activity area's, and it shows a holder the entries of the areas it holds:
  a resource's area is the one its own policies ask for. A full dashboard admin sees every entry;
  an entry of a resource that names no area is a full admin's alone.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Activity.{ActivityEntry, Discovery, Helpers, Query}
  alias MishkaCmsCore.Dashboard.Widgets.RecentActivity

  setup do
    site = create_site!()
    create_media!(site_id: site.id)
    create_page!(site_id: site.id)
    {:ok, site: site}
  end

  defp holder(names, site), do: create_user_with_permissions!(names, site_id: site.id)

  defp read(actor) do
    ActivityEntry
    |> Ash.Query.for_read(:read, %{gervaz_filters: %{}})
    |> Ash.read(actor: actor, page: [offset: 0, limit: 100])
  end

  defp labels({:ok, %{results: results}}),
    do: results |> Enum.map(& &1.resource_label) |> Enum.uniq()

  test "the log is read with the activity area, and not with another", %{site: site} do
    assert {:error, %Ash.Error.Forbidden{}} =
             read(holder(["admin:dashboard:runtime:media"], site))

    assert {:ok, _page} = read(holder(["admin:dashboard:runtime:activity"], site))
  end

  test "a holder of the activity area sees the entries of the areas it holds", %{site: site} do
    seen =
      labels(
        read(holder(["admin:dashboard:runtime:activity", "admin:dashboard:runtime:media"], site))
      )

    assert "Media" in seen
    refute "Page" in seen
  end

  test "a holder of the activity area alone sees no area's entries", %{site: site} do
    assert labels(read(holder(["admin:dashboard:runtime:activity"], site))) == []
  end

  test "a full dashboard admin sees every entry", %{site: site} do
    seen = labels(read(holder(["admin:dashboard:*"], site)))

    assert "Media" in seen
    assert "Page" in seen
  end

  test "the log's total counts what the holder sees", %{site: site} do
    reader = holder(["admin:dashboard:runtime:activity", "admin:dashboard:runtime:media"], site)
    {:ok, %{results: results}} = read(reader)

    assert ActivityEntry.total(%{current_user: reader, filter_values: %{}}) == length(results)

    assert ActivityEntry.counts(reader).total == length(results)
    assert ActivityEntry.counts(nil) == %{total: 0, info: 0, warn: 0, error: 0}
  end

  test "the recent activity card shows the areas the viewer holds", %{site: site} do
    %{entries: entries} =
      RecentActivity.load(
        holder(["admin:dashboard:runtime:activity", "admin:dashboard:runtime:media"], site),
        %{
          "count" => 20
        }
      )

    labels = entries |> Enum.map(& &1.resource_label) |> Enum.uniq()
    assert "Media" in labels
    refute "Page" in labels
  end

  describe "every kind of entry" do
    @repo Application.compile_env!(:mishka_cms_core, :repo)

    defp job!(resource, site) do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          @repo,
          "INSERT INTO oban_jobs (state, queue, worker, args, completed_at, inserted_at, scheduled_at) " <>
            "VALUES ('completed', 'modules', $1, $2, now(), now(), now())",
          [
            "Elixir.MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker",
            %{"resource" => resource, "site_id" => site.id}
          ]
        )
    end

    defp entries(actor, site, kind) do
      Query.page(%{
        site_id: site.id,
        kind: kind,
        resources: Helpers.resources_for(actor),
        limit: 100,
        offset: 0
      })
    end

    test "a job of an area the holder holds is shown, and of another area is not", %{site: site} do
      job!("MishkaCmsCore.Runtime.Media", site)
      job!("MishkaCmsCore.Runtime.Page", site)

      reader = holder(["admin:dashboard:runtime:activity", "admin:dashboard:runtime:media"], site)
      full = holder(["admin:dashboard:*"], site)

      assert length(entries(reader, site, "job")) == 1
      assert length(entries(full, site, "job")) == 2
    end
  end

  test "a resource's area is the one its own policies ask for" do
    assert Discovery.areas(MishkaCmsCore.Runtime.Media) == ["admin:dashboard:runtime:media"]
    assert Discovery.areas(MishkaCmsCore.Runtime.Site) == ["admin:dashboard:runtime:site"]

    assert Discovery.areas(MishkaCmsCore.Accounts.User) |> Enum.sort() ==
             ["admin:dashboard:permission", "admin:dashboard:user"]
  end

  test "which resources a viewer's log shows", %{site: site} do
    assert Helpers.resources_for(holder(["admin:dashboard:*"], site)) == :all

    shown =
      Helpers.resources_for(
        holder(["admin:dashboard:runtime:activity", "admin:dashboard:runtime:media"], site)
      )

    assert "Elixir.MishkaCmsCore.Runtime.Media" in shown
    assert "Elixir.MishkaCmsCore.Runtime.MediaCategory" in shown
    refute "Elixir.MishkaCmsCore.Runtime.Page" in shown

    assert Helpers.shows?(shown, MishkaCmsCore.Runtime.Media)
    refute Helpers.shows?(shown, MishkaCmsCore.Runtime.Page)
    refute Helpers.shows?(shown, nil)
    assert Helpers.shows?(:all, nil)
  end
end
