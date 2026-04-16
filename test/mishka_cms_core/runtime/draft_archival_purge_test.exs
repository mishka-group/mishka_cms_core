defmodule MishkaCmsCore.Runtime.DraftArchivalPurgeTest do
  @moduledoc """
  The one-off cleanup for drafts discarded while discarding was a soft delete.

  Nothing in the app can produce a legacy row any more — `archived_at` is neither an attribute nor a
  column — so these tests rebuild the pre-removal shape by hand: add the column back inside the
  sandboxed transaction, stamp a row with it, and check the purge takes exactly that row and no
  other. The interesting cases are the ones it must NOT take, and the three shapes of no-op that
  make it safe to run on a database that has already moved on.
  """
  use MishkaCmsCore.DataCase, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.DraftArchivalPurge
  alias MishkaCmsCore.Runtime.PageDraft

  require Ash.Query

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  @tables ~w(page_drafts layout_drafts error_page_drafts)

  setup do
    %{site: create_site!()}
  end

  defp restore_column! do
    for table <- @tables do
      Ecto.Adapters.SQL.query!(@repo, "ALTER TABLE #{table} ADD COLUMN archived_at timestamp", [])
    end

    :ok
  end

  defp draft!(site, name) do
    PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, title: name, path: "/#{name}", template: "<h1>#{name}</h1>"},
      tenant: site.id
    )
    |> Ash.create!(authorize?: false)
  end

  defp archive!(draft) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE page_drafts SET archived_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(draft.id)]
    )

    draft
  end

  defp publish_marker!(draft) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE page_drafts SET applied_at = now(), status = 'published' WHERE id = $1",
      [Ecto.UUID.dump!(draft.id)]
    )

    draft
  end

  defp exists?(id) do
    PageDraft
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(page: [limit: 2])
    |> Map.fetch!(:results)
    |> Enum.any?()
  end

  describe "with the legacy column present" do
    setup %{site: site} do
      restore_column!()
      %{site: site}
    end

    test "deletes a draft that was discarded under the old soft delete", %{site: site} do
      ghost = site |> draft!("ghost") |> archive!()

      assert {:ok, report} = DraftArchivalPurge.run()

      assert report["page_drafts"].deleted == 1
      refute exists?(ghost.id)
    end

    test "leaves a draft nobody discarded", %{site: site} do
      live = draft!(site, "live")

      assert {:ok, report} = DraftArchivalPurge.run()

      assert report["page_drafts"].deleted == 0
      assert exists?(live.id)
    end

    # The `applied_at IS NULL` half of the predicate. A published draft already wrote its content to
    # the live page, and the publish is recorded there — but the purge must be provably unable to
    # touch it, not merely unlikely to.
    test "never deletes a draft that was published, even if it also carries archived_at", %{
      site: site
    } do
      published = site |> draft!("shipped") |> publish_marker!() |> archive!()

      assert {:ok, report} = DraftArchivalPurge.run()

      assert report["page_drafts"].deleted == 0
      assert exists?(published.id)
    end

    test "a dry run reports what it found and deletes nothing", %{site: site} do
      ghost = site |> draft!("ghost") |> archive!()

      assert {:ok, report} = DraftArchivalPurge.run(dry_run: true)

      assert report["page_drafts"].found == 1
      assert report["page_drafts"].deleted == 0
      assert exists?(ghost.id)
    end

    test "running it twice is not an error and deletes nothing the second time", %{site: site} do
      site |> draft!("ghost") |> archive!()

      assert {:ok, first} = DraftArchivalPurge.run()
      assert {:ok, second} = DraftArchivalPurge.run()

      assert first["page_drafts"].deleted == 1
      assert second["page_drafts"].deleted == 0
    end

    test "reports the column as still present, which is what makes the task worth running" do
      assert DraftArchivalPurge.pending?()
    end
  end

  describe "on a database that has already migrated" do
    # The state of every machine that has run `remove_draft_archival`, including the one this suite
    # runs on. The task has to be a clean no-op here, not a crash: an unguarded
    # `WHERE archived_at IS NOT NULL` raises `UndefinedColumn`.
    test "is a no-op and says which tables it skipped", %{site: site} do
      live = draft!(site, "live")

      assert {:ok, report} = DraftArchivalPurge.run()

      for table <- @tables do
        assert report[table] == %{skipped: :no_column}
      end

      assert exists?(live.id)
      refute DraftArchivalPurge.pending?()
    end

    test "a dry run is equally harmless" do
      assert {:ok, report} = DraftArchivalPurge.run(dry_run: true)

      assert report["page_drafts"] == %{skipped: :no_column}
    end
  end
end
