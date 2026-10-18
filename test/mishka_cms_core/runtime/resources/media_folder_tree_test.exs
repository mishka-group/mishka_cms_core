# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.MediaFolderTreeTest do
  @moduledoc """
  Media folders inside media folders: where one may go, what its name has to differ from, what a
  move carries along, and when one may be archived or deleted.

  The writes run as a site's own admin and as a master, the way the library writes them; only the
  setup and the reads that check what landed run as the system.

  `async: false` — the upload case points the static folder, which is application config, at its own.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias MishkaCmsCore.Runtime.Resources.Changes.RestoreVersion
  alias MishkaCmsCore.Test.Files

  require Ash.Query

  setup do
    site = create_site!()

    %{
      site: site,
      other: create_site!(),
      admin: create_user_with_permissions!(["*"], site_id: site.id),
      master: create_user_with_permissions!(["*"])
    }
  end

  defp folder!(site, name, parent \\ nil) do
    MediaCategory
    |> Ash.Changeset.for_create(:create, %{name: name, parent_id: parent && parent.id},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp create(admin, site, name, parent) do
    MediaCategory
    |> Ash.Changeset.for_create(:create, %{name: name, parent_id: parent && parent.id},
      actor: admin,
      tenant: site.id
    )
    |> Ash.create()
  end

  defp move(folder, parent, admin) do
    folder
    |> Ash.Changeset.for_update(:update, %{parent_id: parent && parent.id},
      actor: admin,
      tenant: folder.site_id
    )
    |> Ash.update()
  end

  defp master_move(folder, parent, master) do
    folder
    |> Ash.Changeset.for_update(:master_update, %{parent_id: parent && parent.id}, actor: master)
    |> Ash.update()
  end

  defp archive(folder, admin) do
    folder
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: admin, tenant: folder.site_id)
    |> Ash.destroy(authorize?: true)
  end

  defp stored(folder),
    do: Ash.get!(MediaCategory, folder.id, action: :master_get, authorize?: false)

  defp trail_names(folder) do
    {:ok, trail} = MediaCategory.trail(folder.id, authorize?: false)
    Enum.map(trail, & &1.name)
  end

  defp file!(site, folder),
    do: create_media!(site_id: site.id, media_category_id: folder && folder.id)

  defp refused_on?(result, field) do
    match?({:error, %Ash.Error.Invalid{}}, result) and
      Enum.any?(elem(result, 1).errors, &(Map.get(&1, :field) == field))
  end

  defp message(result), do: result |> elem(1) |> MishkaGervaz.Errors.extract_error_message()

  describe "a folder inside another" do
    test "is made inside a folder of its own site, and its trail reads down to it", %{
      site: site,
      admin: admin
    } do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024", photos)

      assert {:ok, covers} = create(admin, site, "Covers", year)
      assert covers.parent_id == year.id
      assert trail_names(covers) == ["photos", "2024", "covers"]
    end

    test "is named by the folders above it, every folder of one read labelled together", %{
      site: site
    } do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024", photos)
      covers = folder!(site, "Covers", year)

      labels =
        MediaCategory
        |> Ash.Query.filter(id in ^[photos.id, year.id, covers.id])
        |> Ash.Query.sort(inserted_at: :asc)
        |> Ash.Query.load(:path_label)
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Enum.map(& &1.path_label)

      assert labels == ["photos", "photos / 2024", "photos / 2024 / covers"]
    end

    test "has a trail only for a reader of its own site", %{site: site, other: other} do
      covers = folder!(site, "Covers", folder!(site, "Photos"))
      outsider = create_user_with_permissions!(["*"], site_id: other.id)

      assert {:ok, []} = MediaCategory.trail(covers.id, actor: outsider)

      assert {:ok, [_, _]} =
               MediaCategory.trail(covers.id,
                 actor: create_user_with_permissions!(["*"], site_id: site.id)
               )
    end
  end

  # The Folder pickers — the upload form's, the folder form's "Inside folder" and the gallery's
  # filter — load through `offer/2` and draw `picker_label/1`, so two "covers" read apart.
  test "a folder picker offers its form's site's folders, each named by its path", %{
    site: site,
    other: other,
    admin: admin
  } do
    photos = folder!(site, "Photos")
    folder!(site, "Covers", photos)
    folder!(site, "Covers", folder!(site, "Videos"))
    folder!(other, "Theirs")

    offered = fn state ->
      MediaCategory
      |> Ash.Query.new()
      |> MediaCategory.offer(state)
      |> Ash.read!(actor: admin, tenant: site.id)
      |> Enum.map(&MediaCategory.picker_label/1)
      |> Enum.sort()
    end

    assert offered.(%{field_values: %{site_id: site.id}}) ==
             ["photos", "photos / covers", "videos", "videos / covers"]

    assert offered.(%{current_user: admin}) == offered.(%{field_values: %{site_id: site.id}})
    assert offered.(%{field_values: %{}}) == [], "a form with no site yet is offered no folder"
  end

  describe "where a folder may go" do
    test "not inside a folder of another site", %{site: site, other: other, admin: admin} do
      theirs = folder!(other, "Theirs")

      assert refused_on?(create(admin, site, "Mine", theirs), :parent_id)

      mine = folder!(site, "Mine")
      assert refused_on?(move(mine, theirs, admin), :parent_id)
      assert stored(mine).parent_id == nil
    end

    test "not inside a folder of another site when a master moves it", %{
      site: site,
      other: other,
      master: master
    } do
      mine = folder!(site, "Mine")

      assert refused_on?(master_move(mine, folder!(other, "Theirs"), master), :parent_id)
      assert stored(mine).parent_id == nil
    end

    test "not inside itself", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")

      result = move(photos, photos, admin)
      assert refused_on?(result, :parent_id)
      assert message(result) == "A folder cannot go inside itself."
    end

    test "not inside one of its own folders, however deep", %{
      site: site,
      admin: admin,
      master: master
    } do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024", photos)
      covers = folder!(site, "Covers", year)

      for below <- [year, covers] do
        result = move(photos, below, admin)
        assert refused_on?(result, :parent_id), "#{below.name} took its own ancestor"
        assert message(result) == "A folder cannot go inside one of its own folders."
        assert refused_on?(master_move(photos, below, master), :parent_id)
      end

      assert stored(photos).parent_id == nil
    end

    test "not inside an archived folder", %{site: site, admin: admin} do
      old = folder!(site, "Old")
      :ok = archive(old, admin)

      result = create(admin, site, "New", old)
      assert refused_on?(result, :parent_id)
      assert message(result) == "That folder is archived. Restore it first."
    end

    test "nor back inside its own folder through an old version", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024")

      {:ok, photos} = move(photos, year, admin)
      {:ok, photos} = move(photos, nil, admin)
      {:ok, _year} = move(year, photos, admin)

      inside_year =
        MediaCategory.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^photos.id)
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(RestoreVersion.decode(&1.changes)["parent_id"] == year.id))

      result =
        photos
        |> Ash.Changeset.for_update(:restore_version, %{version_id: inside_year.id},
          actor: admin,
          tenant: site.id
        )
        |> Ash.update()

      assert refused_on?(result, :parent_id)
      assert stored(photos).parent_id == nil
    end
  end

  describe "a folder's name" do
    test "is its own among the folders beside it, and free beside others", %{
      site: site,
      admin: admin
    } do
      photos = folder!(site, "Photos")
      videos = folder!(site, "Videos")
      folder!(site, "Covers", photos)

      assert refused_on?(create(admin, site, "Covers", photos), :name)
      assert {:ok, _} = create(admin, site, "Covers", videos)
      assert {:ok, _} = create(admin, site, "Covers", nil)
      assert refused_on?(create(admin, site, "Covers", nil), :name)
    end

    test "keeps a folder from moving in beside its namesake", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")
      folder!(site, "Covers", photos)
      covers = folder!(site, "Covers")

      assert refused_on?(move(covers, photos, admin), :name)
      assert stored(covers).parent_id == nil
    end
  end

  describe "moving a folder" do
    test "takes everything under it along, and moves no file", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024", photos)
      covers = folder!(site, "Covers", year)
      archive_folder = folder!(site, "Archive")
      in_year = file!(site, year)
      in_covers = file!(site, covers)

      assert {:ok, moved} = move(year, archive_folder, admin)
      assert moved.parent_id == archive_folder.id

      assert trail_names(covers) == ["archive", "2024", "covers"]
      assert stored(covers).parent_id == year.id

      for file <- [in_year, in_covers] do
        after_move = Ash.get!(Media, file.id, tenant: site.id, authorize?: false)
        assert after_move.media_category_id == file.media_category_id
        assert after_move.relative_path == file.relative_path
      end
    end

    test "to the top level", %{site: site, admin: admin} do
      covers = folder!(site, "Covers", folder!(site, "Photos"))

      assert {:ok, %{parent_id: nil}} = move(covers, nil, admin)
      assert trail_names(covers) == ["covers"]
    end
  end

  describe "archiving or deleting a folder" do
    test "is refused while it holds a file, archived or not", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")
      file = file!(site, photos)

      result = archive(photos, admin)
      assert refused_on?(result, :id)

      assert message(result) ==
               "This folder still holds files, archived ones included. Move them out or delete them for good first."

      {:ok, _} = Ash.destroy(file, tenant: site.id, authorize?: false, return_destroyed?: true)
      assert refused_on?(archive(photos, admin), :id), "an archived file still names the folder"

      assert is_nil(stored(photos).archived_at)
    end

    test "is refused while it holds a folder, archived or not", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024", photos)

      result = archive(photos, admin)
      assert refused_on?(result, :id)

      assert message(result) ==
               "This folder still holds other folders, archived ones included. Move them out or delete them for good first."

      :ok = archive(year, admin)
      assert refused_on?(archive(photos, admin), :id), "an archived folder still names its parent"
    end

    test "goes once it is empty, and is then deleted for good", %{site: site, admin: admin} do
      photos = folder!(site, "Photos")
      year = folder!(site, "2024", photos)
      file = file!(site, year)

      {:ok, _} = move(year, nil, admin)
      :ok = archive(photos, admin)

      archived = Ash.get!(MediaCategory, photos.id, action: :master_get, authorize?: false)
      refute is_nil(archived.archived_at)

      assert :ok =
               archived
               |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.destroy(authorize?: true)

      assert Ash.get!(Media, file.id, tenant: site.id, authorize?: false).media_category_id ==
               year.id
    end

    test "for good is refused while it holds anything, rather than failing in the database", %{
      site: site,
      admin: admin,
      master: master
    } do
      photos = folder!(site, "Photos")
      file!(site, photos)

      assert refused_on?(
               photos
               |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.destroy(authorize?: true),
               :id
             )

      assert refused_on?(
               photos
               |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, actor: master)
               |> Ash.destroy(authorize?: true),
               :id
             )

      assert refused_on?(
               photos
               |> Ash.Changeset.for_destroy(:master_destroy, %{}, actor: master)
               |> Ash.destroy(authorize?: true),
               :id
             )

      assert {:ok, _} = Ash.get(MediaCategory, photos.id, action: :master_get, authorize?: false)
    end
  end

  test "media_count counts each folder's own live files", %{site: site} do
    photos = folder!(site, "Photos")
    year = folder!(site, "2024", photos)
    empty = folder!(site, "Empty")

    file!(site, photos)
    file!(site, year)
    archived = file!(site, year)
    file!(site, year)
    {:ok, _} = Ash.destroy(archived, tenant: site.id, authorize?: false, return_destroyed?: true)

    counts =
      MediaCategory
      |> Ash.Query.filter(id in ^[photos.id, year.id, empty.id])
      |> Ash.Query.load(:media_count)
      |> Ash.read!(tenant: site.id, authorize?: false)
      |> Map.new(&{&1.id, &1.media_count})

    assert counts == %{photos.id => 1, year.id => 2, empty.id => 0}
  end

  # NO QUERY PER FOLDER. The rail reads a page of folders with their counts, a picker its options
  # with their paths: the queries a read makes grow with how deep the folders sit, never with how
  # many there are.
  test "folders read with their counts and paths cost the same, however many are read", %{
    site: site
  } do
    deep =
      site |> folder!("Aa") |> then(&folder!(site, "Bb", &1)) |> then(&folder!(site, "Cc", &1))

    few = for n <- 1..2, do: folder!(site, "Few #{n}", deep)
    many = for n <- 1..12, do: folder!(site, "Many #{n}", deep)

    Enum.each(few ++ many, &file!(site, &1))

    assert queries_reading(site, few) == queries_reading(site, many)
  end

  # Only this process's queries: a telemetry handler hears every process's.
  defp queries_reading(site, folders) do
    ids = Enum.map(folders, & &1.id)
    handler = "folder-reads-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:mishka_cms_core, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test, do: send(test, {:query, handler})
      end,
      nil
    )

    loaded =
      MediaCategory
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load([:media_count, :path_label])
      |> Ash.read!(tenant: site.id, authorize?: false)

    :telemetry.detach(handler)

    assert Enum.all?(loaded, &(&1.media_count == 1 and &1.path_label =~ "aa / bb / cc / "))
    count_messages({:query, handler}, 0)
  end

  defp count_messages(message, count) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end

  describe "an upload into a folder" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "media_folder_tree_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf(dir)
      end)

      %{dir: dir}
    end

    test "is filed in that folder, its file stored under it", %{
      site: site,
      admin: admin,
      dir: dir
    } do
      covers = folder!(site, "Covers", folder!(site, "Photos"))
      staged = Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_c.png")
      File.write!(staged, Files.png() <> "cover bytes")

      assert {:ok, media} =
               Media
               |> Ash.Changeset.for_create(
                 :form_upload,
                 %{
                   media_files: [%{path: staged, client_name: "c.png"}],
                   media_category_id: covers.id
                 },
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.create()

      assert media.media_category_id == covers.id
      assert String.starts_with?(media.relative_path, "/uploads/#{site.id}/media/#{covers.id}/")
      assert File.read!(Path.join(dir, media.relative_path)) == Files.png() <> "cover bytes"
    end
  end
end
