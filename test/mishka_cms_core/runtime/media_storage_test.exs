# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.MediaStorageTest do
  @moduledoc """
  What a media row's file operations may touch on disk.

  A media file lives in its site's own folder, `uploads/<site_id>/media/`, and moves to
  `uploads_archived/<site_id>/media/` while its row is archived. `relative_path` is the server's to
  set: no update action accepts it, and every storage function — save, replace, archive, restore,
  delete for good, and the archived preview — refuses a path that is not a file of the row's own
  folder, so a row pointed at another site's file, or out of the folder with `..`, touches nothing
  outside it. A create takes the path only from the code that stored the file, never as input. The
  file an upload is copied from must be one a form's upload was staged as, so an upload entry
  naming any other file copies and deletes nothing. A refusal is announced on
  `cms_core:media:path_refused`.

  `async: false` — the static folder is application config, and the plugin probe is a named process.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Test.Plugins.MediaPathRefused
  alias MishkaInstaller.Event.{Event, EventHandler}

  setup do
    dir = Path.join(System.tmp_dir!(), "media_storage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    site = create_site!()

    %{
      dir: dir,
      site: site,
      other: create_site!(),
      admin: create_user_with_permissions!(["*"], site_id: site.id),
      master: create_user_with_permissions!(["*"])
    }
  end

  defp on_disk!(dir, tree, relative, content \\ "bytes") do
    path = Path.join([dir, tree, relative])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp own_path(site, name \\ "#{Ecto.UUID.generate()}.png"),
    do: "/uploads/#{site.id}/media/uncategorized/#{name}"

  defp row!(site, relative_path) do
    create_media!(
      site_id: site.id,
      relative_path: relative_path,
      type: :images,
      format: "png"
    )
  end

  defp archive!(row, admin) do
    {:ok, archived} =
      Ash.destroy(row, actor: admin, tenant: row.site_id, return_destroyed?: true)

    archived
  end

  defp restore!(archived, admin) do
    archived
    |> Ash.Changeset.for_update(:unarchive, %{}, actor: admin, tenant: archived.site_id)
    |> Ash.update!()
  end

  defp delete_for_good!(row, admin) do
    row
    |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, actor: admin, tenant: row.site_id)
    |> Ash.destroy!()
  end

  # A consumed upload's temporary file, staged where and as MishkaGervaz stages a submitted form's
  # upload; one a refusal leaves behind is removed after the test.
  defp upload(name, content) do
    path = Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_#{name}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %{path: path, client_name: name}
  end

  # An upload as `validate_and_process_file/1` hands it to storage.
  defp file_info(content), do: %{source_path: upload("new.png", content).path, extension: ".png"}

  defp replace!(row, admin, file) do
    row
    |> Ash.Changeset.for_update(:update, %{media_files: [file]},
      actor: admin,
      tenant: row.site_id
    )
    |> Ash.update!()
  end

  # The part of a file's URL under `/uploads/`, to find the file on disk in either tree.
  defp under_uploads("/uploads/" <> relative), do: relative

  # What the gallery hands a column's `render`: only the fields it `requires`, as `MediaGallery` does.
  defp rendered(column_name, row) do
    column = MishkaGervaz.Resource.Info.Table.column(Media, column_name)
    column.render.(Map.new(column.requires, &{&1, Map.get(row, &1)}))
  end

  defp names(site),
    do: Media |> Ash.read!(tenant: site.id, authorize?: false) |> Enum.map(& &1.name)

  # An upload entry as a request carries it: string keys, a path of the sender's choosing.
  defp entry(source), do: %{"path" => source, "client_name" => "x.png"}

  # `relative_path` is no input of a create; `stored_path` is private, so a value handed in as input
  # is not taken, and the create still lacks one.
  defp refused_as_input?(%Ash.Error.Invalid.NoSuchInput{input: :relative_path}, :relative_path),
    do: true

  defp refused_as_input?(%Ash.Error.Changes.Required{field: :stored_path}, :stored_path),
    do: true

  defp refused_as_input?(_error, _input), do: false

  defp untouched!(%{theirs: theirs, sources: sources}) do
    assert File.read!(theirs) == "their bytes"

    for source <- sources do
      assert File.exists?(source), "#{source} was removed"
    end
  end

  describe "an edit never says where the file is" do
    test "a site admin's update is refused a new path, and the row keeps its own", %{
      site: site,
      other: other,
      admin: admin
    } do
      row = row!(site, own_path(site))

      assert {:error, %Ash.Error.Invalid{} = error} =
               row
               |> Ash.Changeset.for_update(
                 :update,
                 %{relative_path: own_path(other, "theirs.png")},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.update()

      assert Enum.any?(
               error.errors,
               &match?(%Ash.Error.Invalid.NoSuchInput{input: :relative_path}, &1)
             )

      assert Ash.get!(Media, row.id, tenant: site.id, authorize?: false).relative_path ==
               row.relative_path
    end

    test "and so is a master's", %{site: site, other: other, master: master} do
      row = row!(site, own_path(site))

      assert {:error, %Ash.Error.Invalid{} = error} =
               row
               |> Ash.Changeset.for_update(
                 :master_update,
                 %{relative_path: own_path(other, "theirs.png")},
                 actor: master
               )
               |> Ash.update()

      assert Enum.any?(
               error.errors,
               &match?(%Ash.Error.Invalid.NoSuchInput{input: :relative_path}, &1)
             )
    end

    test "the rest of the row is still edited", %{site: site, admin: admin} do
      row = row!(site, own_path(site))

      updated =
        row
        |> Ash.Changeset.for_update(:update, %{description: "Kept path"},
          actor: admin,
          tenant: site.id
        )
        |> Ash.update!()

      assert updated.description == "Kept path"
      assert updated.relative_path == row.relative_path
    end
  end

  describe "a create never says where the file is" do
    # Another site's file, and the site's own under a second spelling that the `unique_path_per_site`
    # identity does not see as the same path — a row on it would archive or delete the other's file.
    setup %{site: site, other: other} do
      own = own_path(site, "own.png")
      row!(site, own)

      %{
        named: [
          own_path(other, "theirs.png"),
          String.replace(own, "/uncategorized/", "/uncategorized/../uncategorized/")
        ]
      }
    end

    # Under the attribute's own name, or the private argument's the server passes it as.
    test "a site admin's create is refused a path", %{site: site, admin: admin, named: named} do
      for path <- named, input <- [:relative_path, :stored_path] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 Media
                 |> Ash.Changeset.for_create(
                   :create,
                   Map.put(%{name: "Alias", type: :images, size: 5, format: "png"}, input, path),
                   actor: admin,
                   tenant: site.id
                 )
                 |> Ash.create()

        assert Enum.any?(error.errors, &refused_as_input?(&1, input)),
               "#{path} was not refused as #{input}"
      end

      refute "alias" in names(site)
    end

    test "and so is a master's", %{site: site, master: master, named: named} do
      for path <- named, input <- [:relative_path, :stored_path] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 Media
                 |> Ash.Changeset.for_create(
                   :master_create,
                   Map.put(
                     %{name: "Alias", type: :images, size: 5, format: "png", site_id: site.id},
                     input,
                     path
                   ),
                   actor: master
                 )
                 |> Ash.create()

        assert Enum.any?(error.errors, &refused_as_input?(&1, input)),
               "#{path} was not refused as #{input}"
      end

      refute "alias" in names(site)
    end

    test "an upload creates its row at the path it stored the file under", %{
      dir: dir,
      site: site,
      admin: admin,
      master: master
    } do
      uploads = [
        {Ash.ActionInput.for_action(
           Media,
           :upload,
           %{
             file: Ash.Type.File.from_path(upload("site.png", "site bytes").path),
             original_filename: "site.png"
           },
           actor: admin,
           tenant: site.id
         ), "site bytes"},
        {Ash.ActionInput.for_action(
           Media,
           :master_upload,
           %{
             file: Ash.Type.File.from_path(upload("master.png", "master bytes").path),
             original_filename: "master.png",
             site_id: site.id
           },
           actor: master
         ), "master bytes"}
      ]

      for {input, content} <- uploads do
        assert {:ok, %Media{relative_path: path, site_id: site_id}} = Ash.run_action(input)
        assert site_id == site.id
        assert String.starts_with?(path, "/uploads/#{site.id}/media/uncategorized/")
        assert File.read!(Path.join([dir, "uploads", under_uploads(path)])) == content
      end
    end
  end

  describe "storage_paths/2" do
    test "names a file of the site's own folder, live and archived", %{dir: dir, site: site} do
      path = own_path(site, "a.png")

      assert {:ok, paths} = Media.storage_paths(path, site.id)
      assert paths.relative == path
      assert paths.active == Path.join([dir, "uploads", site.id, "media/uncategorized/a.png"])

      assert paths.archived ==
               Path.join([dir, "uploads_archived", site.id, "media/uncategorized/a.png"])
    end

    test "works out a `..` that stays inside the folder", %{site: site} do
      assert {:ok, %{relative: relative}} =
               Media.storage_paths("/uploads/#{site.id}/media/a/../b/./c.png", site.id)

      assert relative == "/uploads/#{site.id}/media/b/c.png"
    end

    test "refuses every path that is not a file of the site's own media folder", %{
      site: site,
      other: other
    } do
      for path <- [
            own_path(other, "theirs.png"),
            "/uploads/#{site.id}/forms/visitor.png",
            "/uploads/#{site.id}/attachments/collections/cover.png",
            "/uploads/#{site.id}/media/../../#{other.id}/media/uncategorized/theirs.png",
            "/uploads/#{site.id}/media/uncategorized/../../../../victim.txt",
            "/uploads/#{site.id}/media/..",
            "/uploads/#{site.id}/media/",
            "/uploads/elsewhere/../#{site.id}/media/uncategorized/a.png",
            "/uploads_archived/#{site.id}/media/uncategorized/a.png",
            "uploads/#{site.id}/media/uncategorized/a.png",
            "/etc/passwd",
            nil
          ] do
        assert Media.storage_paths(path, site.id) == :error, "#{inspect(path)} was allowed"
      end
    end

    test "refuses a folder, live or archived, where a file should be", %{dir: dir, site: site} do
      File.mkdir_p!(Path.join([dir, "uploads", site.id, "media", "uncategorized"]))
      File.mkdir_p!(Path.join([dir, "uploads_archived", site.id, "media", "banners"]))

      for path <- ["/uploads/#{site.id}/media/uncategorized", "/uploads/#{site.id}/media/banners"] do
        assert Media.storage_paths(path, site.id) == :error, "#{inspect(path)} was allowed"
      end
    end

    test "refuses a site that is not a site id", %{site: site} do
      for site_id <- [nil, "..", String.upcase(site.id), "#{site.id}/media"] do
        assert Media.storage_paths(own_path(site), site_id) == :error,
               "#{inspect(site_id)} was allowed"
      end
    end

    test "refuses a path through a symbolic link that leads out of the folder", %{
      dir: dir,
      site: site,
      other: other
    } do
      theirs = Path.join([dir, "uploads", other.id, "media"])
      File.mkdir_p!(theirs)
      own = Path.join([dir, "uploads", site.id, "media"])
      File.mkdir_p!(own)
      :ok = File.ln_s(theirs, Path.join(own, "link"))

      assert Media.storage_paths("/uploads/#{site.id}/media/link/theirs.png", site.id) == :error
    end
  end

  describe "a new upload" do
    test "is stored in the site's own folder", %{dir: dir, site: site} do
      assert {:ok, path} = Media.save_file_to_storage(file_info("new"), site.id, nil)
      assert String.starts_with?(path, "/uploads/#{site.id}/media/uncategorized/")
      assert File.read!(Path.join([dir, "uploads", under_uploads(path)])) == "new"
    end

    test "is refused a folder that climbs out of the site's own", %{
      dir: dir,
      site: site,
      other: other
    } do
      theirs = Path.join([dir, "uploads", other.id, "media"])

      assert {:error, %Ash.Error.Invalid{}} =
               Media.save_file_to_storage(file_info("new"), site.id, "../../#{other.id}/media")

      refute File.exists?(theirs)
    end

    test "is refused when there is no site to store it for", %{dir: dir} do
      assert {:error, %Ash.Error.Invalid{}} =
               Media.save_file_to_storage(file_info("new"), nil, nil)

      assert File.ls!(dir) == []
    end

    test "whose row is refused leaves no file behind", %{
      dir: dir,
      site: site,
      other: other,
      admin: admin,
      master: master
    } do
      theirs = create_media_category!(site_id: other.id)

      uploads = [
        Ash.ActionInput.for_action(
          Media,
          :upload,
          %{
            file: Ash.Type.File.from_path(upload("site.png", "site bytes").path),
            original_filename: "site.png",
            media_category_id: theirs.id
          },
          actor: admin,
          tenant: site.id
        ),
        Ash.ActionInput.for_action(
          Media,
          :master_upload,
          %{
            file: Ash.Type.File.from_path(upload("master.png", "master bytes").path),
            original_filename: "master.png",
            site_id: site.id,
            media_category_id: theirs.id
          },
          actor: master
        )
      ]

      for input <- uploads do
        assert {:error, error} = Ash.run_action(input)
        assert Exception.message(error) =~ "folder is not one this site can use"
      end

      stored = Path.wildcard(Path.join([dir, "uploads", "**", "*.png"]))
      assert stored == []
    end
  end

  describe "a row's own file" do
    test "is archived out of the served folder, restored, and deleted for good", %{
      dir: dir,
      site: site,
      admin: admin
    } do
      path = own_path(site)
      live = on_disk!(dir, "uploads", under_uploads(path))
      archived_copy = Path.join([dir, "uploads_archived", under_uploads(path)])

      archived = site |> row!(path) |> archive!(admin)
      refute File.exists?(live)
      assert File.read!(archived_copy) == "bytes"

      restored = restore!(archived, admin)
      assert File.read!(live) == "bytes"
      refute File.exists?(archived_copy)

      :ok = delete_for_good!(restored, admin)
      refute File.exists?(live)
    end

    test "is shown while archived as a data URL", %{dir: dir, site: site, admin: admin} do
      path = own_path(site)
      on_disk!(dir, "uploads", under_uploads(path), "png bytes")

      archived = site |> row!(path) |> archive!(admin)

      assert Media.get_archived_image_data_uri(path, site.id, "png") ==
               "data:image/png;base64," <> Base.encode64("png bytes")

      assert %{archived_data_url: "data:image/png;base64," <> _} =
               Ash.load!(archived, :archived_data_url, authorize?: false)
    end

    test "is replaced in place by a new upload", %{dir: dir, site: site, admin: admin} do
      path = own_path(site)
      live = on_disk!(dir, "uploads", under_uploads(path), "old")

      updated = site |> row!(path) |> replace!(admin, upload("new.png", "new"))

      assert updated.relative_path == path
      assert File.read!(live) == "new"
    end

    test "leaves the site's media folder in place when its last file goes", %{
      dir: dir,
      site: site,
      admin: admin
    } do
      path = own_path(site)
      on_disk!(dir, "uploads", under_uploads(path))

      site |> row!(path) |> archive!(admin)

      refute File.exists?(Path.join([dir, "uploads", site.id, "media", "uncategorized"]))
      assert File.dir?(Path.join([dir, "uploads", site.id, "media"]))
    end
  end

  describe "a row pointing at another site's file" do
    setup %{dir: dir, other: other} do
      theirs = own_path(other, "theirs.png")

      %{
        theirs: theirs,
        live: on_disk!(dir, "uploads", under_uploads(theirs), "their bytes"),
        archived_copy: Path.join([dir, "uploads_archived", under_uploads(theirs)])
      }
    end

    test "archives the row and leaves their file where it is", %{
      site: site,
      admin: admin,
      theirs: theirs,
      live: live,
      archived_copy: archived_copy
    } do
      site |> row!(theirs) |> archive!(admin)

      assert File.read!(live) == "their bytes"
      refute File.exists?(archived_copy)
    end

    test "restores the row and leaves their archived file archived", %{
      dir: dir,
      site: site,
      admin: admin,
      theirs: theirs,
      live: live
    } do
      File.rm!(live)
      their_archived = on_disk!(dir, "uploads_archived", under_uploads(theirs), "their bytes")

      site |> row!(theirs) |> archive!(admin) |> restore!(admin)

      assert File.read!(their_archived) == "their bytes"
      refute File.exists?(live)
    end

    test "deletes the row for good and leaves their file", %{
      site: site,
      admin: admin,
      theirs: theirs,
      live: live
    } do
      :ok = site |> row!(theirs) |> delete_for_good!(admin)

      assert File.read!(live) == "their bytes"
    end

    test "deletes the row for good and leaves their archived file", %{
      dir: dir,
      site: site,
      admin: admin,
      theirs: theirs,
      live: live
    } do
      File.rm!(live)
      their_archived = on_disk!(dir, "uploads_archived", under_uploads(theirs), "their bytes")

      :ok = site |> row!(theirs) |> delete_for_good!(admin)

      assert File.read!(their_archived) == "their bytes"
    end

    test "never shows their archived file", %{
      dir: dir,
      site: site,
      admin: admin,
      theirs: theirs,
      live: live
    } do
      File.rm!(live)
      on_disk!(dir, "uploads_archived", under_uploads(theirs), "their bytes")

      archived = site |> row!(theirs) |> archive!(admin)

      assert Media.get_archived_image_data_uri(theirs, site.id, "png") == nil

      assert %{archived_data_url: nil} =
               Ash.load!(archived, :archived_data_url, authorize?: false)
    end

    test "stores a new upload in the row's own folder and leaves their file", %{
      dir: dir,
      site: site,
      admin: admin,
      theirs: theirs,
      live: live
    } do
      updated = site |> row!(theirs) |> replace!(admin, upload("new.jpg", "new"))

      assert File.read!(live) == "their bytes"

      assert String.starts_with?(
               updated.relative_path,
               "/uploads/#{site.id}/media/uncategorized/"
             )

      assert File.read!(Path.join([dir, "uploads", under_uploads(updated.relative_path)])) ==
               "new"
    end
  end

  describe "the media library's archived preview" do
    test "shows the row's own archived image, in the gallery and the table", %{
      dir: dir,
      site: site,
      admin: admin
    } do
      path = own_path(site)
      on_disk!(dir, "uploads", under_uploads(path), "png bytes")
      archived = site |> row!(path) |> archive!(admin)
      data_url = "data:image/png;base64," <> Base.encode64("png bytes")

      assert rendered(:relative_path, archived) == data_url

      assert :thumbnail
             |> rendered(archived)
             |> Phoenix.LiveViewTest.rendered_to_string() =~ ~s(src="#{data_url}")
    end

    test "never reads another site's archived file off the disk", %{
      dir: dir,
      site: site,
      other: other,
      admin: admin
    } do
      theirs = own_path(other, "theirs.png")
      on_disk!(dir, "uploads_archived", under_uploads(theirs), "their bytes")
      archived = site |> row!(theirs) |> archive!(admin)

      assert rendered(:relative_path, archived) == theirs

      refute :thumbnail
             |> rendered(archived)
             |> Phoenix.LiveViewTest.rendered_to_string() =~ "data:"
    end
  end

  describe "a row pointing out of its folder with `..`" do
    # One climbs to a file straight under `uploads/`, the other out of the static folder altogether.
    setup %{dir: dir, site: site} do
      File.mkdir_p!(Path.join([dir, "uploads", site.id, "media", "uncategorized"]))

      climbs =
        for {ups, victim} <- [{"../../..", "uploads/victim.txt"}, {"../../../..", "victim.txt"}] do
          {"/uploads/#{site.id}/media/uncategorized/#{ups}/#{Path.basename(victim)}",
           on_disk!(dir, Path.dirname(victim), Path.basename(victim), "victim")}
        end

      %{climbs: climbs}
    end

    test "archives and restores the row, and touches no file there", %{
      site: site,
      admin: admin,
      climbs: climbs
    } do
      for {climbing, victim} <- climbs do
        archived = site |> row!(climbing) |> archive!(admin)
        assert File.read!(victim) == "victim", "archiving #{climbing} moved it"

        restore!(archived, admin)
        assert File.read!(victim) == "victim", "restoring #{climbing} moved it"
      end
    end

    test "deletes the row for good, and touches no file there", %{
      site: site,
      admin: admin,
      climbs: climbs
    } do
      for {climbing, victim} <- climbs do
        :ok = site |> row!(climbing) |> delete_for_good!(admin)
        assert File.read!(victim) == "victim", "deleting #{climbing} removed it"
      end
    end

    test "stores a new upload in the row's own folder, and touches no file there", %{
      site: site,
      admin: admin,
      climbs: climbs
    } do
      for {climbing, victim} <- climbs do
        updated = site |> row!(climbing) |> replace!(admin, upload("new.txt", "new"))

        assert File.read!(victim) == "victim", "replacing #{climbing} overwrote it"
        assert String.starts_with?(updated.relative_path, "/uploads/#{site.id}/media/")
      end
    end
  end

  describe "a row naming a folder rather than a file" do
    # The folder other rows' files sit in: carried off whole, every one of them would go with it.
    setup %{dir: dir, site: site} do
      folder = "/uploads/#{site.id}/media/uncategorized"
      sibling = own_path(site, "sibling.png")

      %{
        folder: folder,
        sibling: on_disk!(dir, "uploads", under_uploads(sibling), "sibling bytes"),
        archived_sibling: Path.join([dir, "uploads_archived", under_uploads(sibling)])
      }
    end

    test "archives and restores the row, and leaves the folder's files in place", %{
      site: site,
      admin: admin,
      folder: folder,
      sibling: sibling,
      archived_sibling: archived_sibling
    } do
      archived = site |> row!(folder) |> archive!(admin)
      assert File.read!(sibling) == "sibling bytes"
      refute File.exists?(archived_sibling)

      restore!(archived, admin)
      assert File.read!(sibling) == "sibling bytes"
    end

    test "stores a new upload as a file of its own, and leaves the folder's files in place", %{
      dir: dir,
      site: site,
      admin: admin,
      folder: folder,
      sibling: sibling
    } do
      updated = site |> row!(folder) |> replace!(admin, upload("new.png", "new"))

      assert File.read!(sibling) == "sibling bytes"
      assert Path.dirname(updated.relative_path) == folder

      assert File.read!(Path.join([dir, "uploads", under_uploads(updated.relative_path)])) ==
               "new"
    end

    test "deletes the row for good, and leaves the folder's files in place", %{
      site: site,
      admin: admin,
      folder: folder,
      sibling: sibling
    } do
      :ok = site |> row!(folder) |> delete_for_good!(admin)
      assert File.read!(sibling) == "sibling bytes"
    end
  end

  describe "an upload entry naming a file that was not staged" do
    # `media_files` can come from the request — a form field, a JSON:API attribute — and the file its
    # `path` names is copied into the site's folder and then deleted. Only a file a form's upload was
    # staged as may be: another site's file, a staged-looking link to it, a file of the temporary
    # folder the form did not stage, and one in a folder below it are all refused.
    setup %{dir: dir, other: other} do
      theirs =
        on_disk!(dir, "uploads", under_uploads(own_path(other, "theirs.png")), "their bytes")

      tmp = System.tmp_dir!()
      n = System.unique_integer([:positive])
      link = Path.join(tmp, "gervaz_#{n}_link.png")
      :ok = File.ln_s(theirs, link)
      unstaged = Path.join(tmp, "upload_#{n}.png")
      File.write!(unstaged, "stray bytes")
      below = Path.join([tmp, "gervaz_#{n}", "gervaz_#{n}_below.png"])
      File.mkdir_p!(Path.dirname(below))
      File.write!(below, "stray bytes")

      on_exit(fn ->
        Enum.each([link, unstaged], &File.rm/1)
        File.rm_rf(Path.dirname(below))
      end)

      %{theirs: theirs, sources: [theirs, link, unstaged, below]}
    end

    test "an edit is refused, and the row keeps its own file",
         %{dir: dir, site: site} = context do
      path = own_path(site)
      live = on_disk!(dir, "uploads", under_uploads(path), "own bytes")
      row = row!(site, path)

      for source <- context.sources do
        assert {:error, %Ash.Error.Invalid{}} =
                 row
                 |> Ash.Changeset.for_update(:update, %{media_files: [entry(source)]},
                   actor: context.admin,
                   tenant: site.id
                 )
                 |> Ash.update(),
               "#{source} was taken"
      end

      untouched!(context)
      assert Ash.get!(Media, row.id, tenant: site.id, authorize?: false).relative_path == path
      assert File.read!(live) == "own bytes"
    end

    test "a create from the form is refused, and makes no row",
         %{dir: dir, site: site} = context do
      for source <- context.sources do
        assert {:error, %Ash.Error.Invalid{}} =
                 Media
                 |> Ash.Changeset.for_create(:form_upload, %{media_files: [entry(source)]},
                   actor: context.admin,
                   tenant: site.id
                 )
                 |> Ash.create(),
               "#{source} was taken"

        assert {:error, %Ash.Error.Invalid{}} =
                 Media
                 |> Ash.Changeset.for_create(
                   :master_form_upload,
                   %{media_files: [entry(source)], site_id: site.id},
                   actor: context.master
                 )
                 |> Ash.create(),
               "#{source} was taken by a master"
      end

      untouched!(context)
      assert Ash.read!(Media, tenant: site.id, authorize?: false) == []
      refute File.exists?(Path.join([dir, "uploads", site.id]))
    end

    test "a staged upload is still stored, as a row of the site's own",
         %{dir: dir, site: site} = c do
      assert {:ok, row} =
               Media
               |> Ash.Changeset.for_create(
                 :form_upload,
                 %{media_files: [upload("staged.png", "staged bytes")]},
                 actor: c.admin,
                 tenant: site.id
               )
               |> Ash.create()

      assert String.starts_with?(row.relative_path, "/uploads/#{site.id}/media/uncategorized/")

      assert File.read!(Path.join([dir, "uploads", under_uploads(row.relative_path)])) ==
               "staged bytes"
    end
  end

  describe "cms_core:media:path_refused" do
    setup do
      Process.register(self(), :__plugin_hook_probe__)
      event = "cms_core:media:path_refused"

      {:ok, _} =
        Event.write(%{
          name: MediaPathRefused,
          event: event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(event, :start, false)
      on_exit(fn -> Event.unregister(:name, MediaPathRefused, false) end)
      :ok
    end

    test "hears every refused operation, with the row's site and the path it named", %{
      site: site,
      other: other,
      admin: admin
    } do
      site_id = site.id
      theirs = own_path(other, "theirs.png")

      archived = site |> row!(theirs) |> archive!(admin)
      assert_receive {:media_path_refused, :archive, ^site_id, ^theirs}

      Media.get_archived_image_data_uri(theirs, site.id, "png")
      assert_receive {:media_path_refused, :read, ^site_id, ^theirs}

      restored = restore!(archived, admin)
      assert_receive {:media_path_refused, :unarchive, ^site_id, ^theirs}

      replace!(restored, admin, upload("new.png", "new"))
      assert_receive {:media_path_refused, :replace, ^site_id, ^theirs}

      :ok = site |> row!(theirs) |> delete_for_good!(admin)
      assert_receive {:media_path_refused, :delete, ^site_id, ^theirs}

      Media.save_file_to_storage(file_info("new"), site.id, "../../#{other.id}/media")
      assert_receive {:media_path_refused, :save, ^site_id, "/uploads/" <> _}
    end

    test "hears an upload entry naming a file that was not staged", %{
      site: site,
      other: other,
      admin: admin
    } do
      site_id = site.id
      theirs = own_path(other, "theirs.png")

      site
      |> row!(own_path(site))
      |> Ash.Changeset.for_update(
        :update,
        %{media_files: [%{"path" => theirs, "client_name" => "x.png"}]},
        actor: admin,
        tenant: site.id
      )
      |> Ash.update()

      assert_receive {:media_path_refused, :source, ^site_id, ^theirs}
    end

    test "hears a row naming a folder", %{dir: dir, site: site, admin: admin} do
      site_id = site.id
      folder = "/uploads/#{site.id}/media/uncategorized"
      on_disk!(dir, "uploads", under_uploads(own_path(site, "sibling.png")))

      site |> row!(folder) |> archive!(admin)
      assert_receive {:media_path_refused, :archive, ^site_id, ^folder}
    end

    test "stays quiet for the row's own file", %{dir: dir, site: site, admin: admin} do
      path = own_path(site)
      on_disk!(dir, "uploads", under_uploads(path))

      site |> row!(path) |> archive!(admin) |> restore!(admin) |> delete_for_good!(admin)

      refute_receive {:media_path_refused, _op, _site_id, _path}
    end
  end
end
