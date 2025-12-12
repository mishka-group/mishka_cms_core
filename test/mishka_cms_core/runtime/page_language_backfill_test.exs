defmodule MishkaCmsCore.Runtime.PageLanguageBackfillTest do
  @moduledoc """
  A database from before language editions: pages with no language group, several to a site, some of
  them archived.

  Its migration creates the one-edition-per-language index while those pages still have no group,
  so the index has to take them; and the boot then gives each live page its own id as its group,
  leaving every page that already had one as it was.

  An archived page refuses every write but the one that restores it — the
  `prevent_archived_page_updates` trigger, which the test database carries too. So the boot passes
  it over rather than failing on it and grouping nothing, and the restore gives it its group. A live
  page the boot did not group gets its group from its first translation.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.LanguageEditions
  alias MishkaCmsCore.Runtime.{Page, PageEditions, PageLanguageBackfill}

  require Ash.Query

  @moduletag :integration

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  setup do
    site = create_site!()
    old = for n <- 1..2, do: create_page!(site_id: site.id, name: "old-#{n}", path: "/old-#{n}")

    %{site: site, old: old}
  end

  # How a page stored before the column existed reads.
  defp ungroup!(pages) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE pages SET language_group_id = NULL WHERE id = ANY($1)",
      [Enum.map(pages, &Ecto.UUID.dump!(&1.id))]
    )
  end

  defp group_of(page),
    do: Ash.get!(Page, page.id, action: :master_get, authorize?: false).language_group_id

  # AFTER `ungroup!/1`, which the trigger refuses on a row that is already archived.
  defp archive!(page, site) do
    page
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id)
    |> Ash.destroy!(authorize?: false)

    Ash.get!(Page, page.id, action: :master_get_archived, authorize?: false)
  end

  # A page archived before it had a group.
  defp shelved!(site) do
    page = create_page!(site_id: site.id, name: "old-shelved", path: "/old-shelved")
    ungroup!([page])
    archive!(page, site)
  end

  test "a site holds several pages with no group", %{old: old} do
    assert %{num_rows: 2} = ungroup!(old)
  end

  test "gives each page with no group its own id as one", %{old: old} do
    ungroup!(old)

    assert {:ok, changed} = PageLanguageBackfill.run()
    assert changed >= 2

    for page <- old, do: assert(group_of(page) == page.id)
  end

  test "leaves a group a page already has", %{site: site, old: [master | _] = old} do
    fa =
      create_page!(
        site_id: site.id,
        name: "old-fa",
        path: "/fa/old",
        language: "fa",
        language_group_id: master.id
      )

    ungroup!(old)
    {:ok, _changed} = PageLanguageBackfill.run()

    assert group_of(fa) == master.id
  end

  test "changes nothing once every page has one", %{old: old} do
    ungroup!(old)
    {:ok, _changed} = PageLanguageBackfill.run()

    assert PageLanguageBackfill.run() == {:ok, 0}
  end

  describe "an archived page with no group" do
    test "does not keep the live pages from theirs, and is left without one", %{
      site: site,
      old: old
    } do
      ungroup!(old)
      shelved = shelved!(site)

      assert {:ok, changed} = PageLanguageBackfill.run()
      assert changed >= 2

      for page <- old, do: assert(group_of(page) == page.id)
      assert group_of(shelved) == nil
      assert PageLanguageBackfill.run() == {:ok, 0}
    end

    test "gets its own when a tenant restores it", %{site: site} do
      shelved = shelved!(site)

      restored =
        shelved
        |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id)
        |> Ash.update!(authorize?: false)

      assert restored.language_group_id == shelved.id
      assert group_of(shelved) == shelved.id
    end

    test "and when a master restores it", %{site: site} do
      shelved = shelved!(site)

      shelved
      |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      assert group_of(shelved) == shelved.id
    end

    # THE TABLE'S BULK RESTORE TRIES THE ATOMIC STRATEGY FIRST, so the restore has to give the group
    # on whichever strategy runs, not only on a restore of one row.
    test "and when the table restores it with others", %{site: site, old: [grouped | _]} do
      shelved = shelved!(site)
      grouped = archive!(grouped, site)

      result =
        Page
        |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
        |> Ash.Query.filter(id in ^[shelved.id, grouped.id])
        |> Ash.bulk_update(:master_unarchive, %{},
          authorize?: false,
          strategy: [:atomic, :atomic_batches, :stream],
          allow_stream_with: :full_read,
          return_errors?: true
        )

      assert result.status == :success
      assert group_of(shelved) == shelved.id
      assert group_of(grouped) == grouped.id
    end

    test "can be deleted for good", %{site: site} do
      shelved = shelved!(site)

      assert :ok =
               shelved
               |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
               |> Ash.destroy(authorize?: false)

      assert {:error, _gone} = Ash.get(Page, shelved.id, action: :master_get, authorize?: false)
    end
  end

  test "an archived translation keeps its master's group when restored", %{
    site: site,
    old: [master | _]
  } do
    fa =
      create_page!(
        site_id: site.id,
        name: "old-fa",
        path: "/fa/old",
        language: "fa",
        language_group_id: master.id
      )

    fa
    |> archive!(site)
    |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id)
    |> Ash.update!(authorize?: false)

    assert group_of(fa) == master.id
  end

  # A TRANSLATION JOINS ITS MASTER'S ID, and the master's row, chips and hreflang links find it by
  # the master's own group — which a page restored with none would not have.
  test "a page restored that way is translated into its own group", %{site: site} do
    master_user = create_user_with_permissions!(["*"])

    restored =
      site
      |> shelved!()
      |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    assert {:ok, fa} = PageEditions.translate(restored, "fa", "/fa/old-shelved", master_user)
    assert fa.language_group_id == restored.id

    editions =
      restored
      |> Ash.load!(:language_variants, tenant: site.id, authorize?: false)
      |> LanguageEditions.editions()

    assert editions == [%{id: fa.id, language: "fa"}]
  end

  # A LIVE PAGE THE BOOT DID NOT GROUP — its backfill failed, or the row was written outside Ash.
  describe "a live page with no group" do
    setup %{old: [page | _] = old} do
      ungroup!(old)

      %{
        page: Ash.get!(Page, page.id, action: :master_get, authorize?: false),
        master_user: create_user_with_permissions!(["*"])
      }
    end

    test "joins the group its first translation is given, and no other page does", %{
      site: site,
      page: page,
      old: [_page, other],
      master_user: master_user
    } do
      assert {:ok, fa} = PageEditions.translate(page, "fa", "/fa/old-1", master_user)

      assert fa.language_group_id == page.id
      assert group_of(page) == page.id
      assert group_of(other) == nil

      editions =
        Page
        |> Ash.get!(page.id, tenant: site.id, authorize?: false)
        |> Ash.load!(:language_variants, tenant: site.id, authorize?: false)
        |> LanguageEditions.editions()

      assert editions == [%{id: fa.id, language: "fa"}]
    end

    test "is left without one when its translation is refused", %{
      page: page,
      old: [_page, other],
      master_user: master_user
    } do
      assert {:error, _taken} = PageEditions.translate(page, "fa", other.path, master_user)

      assert group_of(page) == nil
    end
  end
end
