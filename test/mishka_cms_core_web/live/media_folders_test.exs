# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.MediaFoldersTest do
  @moduledoc """
  The media library's folders, through the controls a site's admin and a master press: opening a
  folder from the rail and the breadcrumb, making a folder inside the one open, uploading into it,
  moving a file or a folder with the move dialog, and archiving one that is not empty.

  `:media_static_dir` points the files at the test's own folder; this case is not async.

  Its own file rather than `MediaCategoriesTest`, which is about how the rail takes the broadcasts
  of somebody else's writes.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.{Media, MediaCategory}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/runtime/medias"

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "media_folders_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    SiteState.clear()
    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    photos = folder!(site, "Photos")
    year = folder!(site, "2024", photos)

    {:ok,
     conn: conn,
     site: site,
     dir: dir,
     photos: photos,
     year: year,
     covers: folder!(site, "Covers", year),
     videos: folder!(site, "Videos")}
  end

  defp folder!(site, name, parent \\ nil),
    do: create_media_category!(site_id: site.id, name: name, parent_id: parent && parent.id)

  defp star_permission do
    Permission
    |> Ash.Query.filter(name == "*")
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_permission!(name: "*")
      permission -> permission
    end
  end

  defp create_admin(email, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp tenant_conn(conn, site), do: log_in(conn, create_admin("tenant@example.com", site.id))

  defp open(conn, folder \\ nil) do
    path = if folder, do: "#{@path}?filter_media_category_id=#{folder.id}", else: @path
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp stored(folder),
    do: Ash.get!(MediaCategory, folder.id, action: :master_get, authorize?: false)

  defp stored_media(media), do: Ash.get!(Media, media.id, action: :master_get, authorize?: false)

  defp in_rail?(view, folder), do: has_element?(view, "#category-name-#{folder.id}")

  defp move_button(media), do: "button[title='Move'][phx-value-values*='#{media.id}']"

  defp button(view, event, id),
    do: element(view, "button[phx-click='#{event}'][phx-value-id='#{id}']")

  describe "opening a folder" do
    test "the rail lists the top level, and a folder opens to its own folders", %{
      conn: conn,
      site: site,
      photos: photos,
      year: year,
      videos: videos
    } do
      view = conn |> tenant_conn(site) |> open()

      assert in_rail?(view, photos)
      assert in_rail?(view, videos)
      refute in_rail?(view, year), "a folder inside another is not at the top level"
      assert has_element?(view, "#media-crumb-root[aria-current='page']")
      refute has_element?(view, "#media-folder-up")

      view |> element("#category-open-#{photos.id}") |> render_click()
      assert_patch(view, "#{@path}?filter_media_category_id=#{photos.id}")
      render_async(view)

      assert in_rail?(view, year)
      refute in_rail?(view, photos)
      refute in_rail?(view, videos)
      assert has_element?(view, "#media-crumb-#{photos.id}[aria-current='page']")
    end

    test "the breadcrumb names the way down, and takes the reader back up", %{
      conn: conn,
      site: site,
      photos: photos,
      year: year,
      covers: covers
    } do
      view = conn |> tenant_conn(site) |> open(year)

      assert in_rail?(view, covers)
      assert has_element?(view, "a#media-crumb-root")
      assert has_element?(view, "a#media-crumb-#{photos.id}")
      assert has_element?(view, "#media-crumb-#{year.id}[aria-current='page']")

      view |> element("a#media-crumb-#{photos.id}") |> render_click()
      assert_patch(view, "#{@path}?filter_media_category_id=#{photos.id}")
      render_async(view)
      assert in_rail?(view, year)

      view |> element("#media-folder-up") |> render_click()
      assert_patch(view, @path)
      render_async(view)
      assert in_rail?(view, photos)
      refute has_element?(view, "#media-crumb-#{photos.id}")
    end

    test "the gallery shows the folder's own files", %{conn: conn, site: site, year: year} do
      here = create_media!(site_id: site.id, media_category_id: year.id, name: "here")
      elsewhere = create_media!(site_id: site.id, name: "elsewhere")

      view = conn |> tenant_conn(site) |> open(year)

      assert has_element?(view, "button[title='Move'][phx-value-values*='#{here.id}']")
      refute has_element?(view, "button[title='Move'][phx-value-values*='#{elsewhere.id}']")
    end

    # ALL MEDIA IS ALL OF IT: the newest file first, wherever it is filed, and each card says where its
    # file is by the whole path to it.
    test "the top level shows every file, the ones in folders too, newest first", %{
      conn: conn,
      site: site,
      year: year
    } do
      loose = create_media!(site_id: site.id, name: "loose")
      filed = create_media!(site_id: site.id, media_category_id: year.id, name: "filed")

      view = conn |> tenant_conn(site) |> open()

      assert has_element?(view, move_button(loose))
      assert has_element?(view, move_button(filed)), "a file in a folder is left out of All media"
      assert has_element?(view, "#media-table_media-#{filed.id}", "photos / 2024")

      html = render(view)
      {newest, _} = :binary.match(html, "media-table_media-#{filed.id}")
      {older, _} = :binary.match(html, "media-table_media-#{loose.id}")
      assert newest < older
    end

    test "Up one level shows the files of the level above, for a site's admin and a master", %{
      conn: conn,
      site: site,
      photos: photos
    } do
      loose = create_media!(site_id: site.id, name: "loose")
      filed = create_media!(site_id: site.id, media_category_id: photos.id, name: "filed")
      master = log_in(conn, create_admin("master@example.com"))

      for conn <- [tenant_conn(conn, site), master] do
        {:ok, view, _html} = live(conn, "#{@path}?sort=inserted_at%3Adesc")
        render_async(view)

        view |> element("#category-open-#{photos.id}") |> render_click()
        render_async(view)
        assert has_element?(view, move_button(filed))
        refute has_element?(view, move_button(loose)), "the folder shows a file filed elsewhere"

        view |> element("#media-folder-up") |> render_click()
        render_async(view)
        assert has_element?(view, move_button(loose)), "Up one level kept the folder's files"
        assert has_element?(view, move_button(filed))
        refute has_element?(view, "#media-folder-up")
      end
    end

    test "a search or a filter at the top level finds a file in any folder, with its path", %{
      conn: conn,
      site: site,
      year: year
    } do
      filed =
        create_media!(site_id: site.id, media_category_id: year.id, name: "filed", type: :images)

      conn = tenant_conn(conn, site)

      for narrowed <- ["filter_search=filed", "filter_type=images"] do
        {:ok, view, _html} = live(conn, "#{@path}?#{narrowed}")
        render_async(view)

        assert has_element?(view, move_button(filed)), "#{narrowed} did not look in the folder"
        assert has_element?(view, "#media-table_media-#{filed.id}", "photos / 2024")
      end
    end

    test "a folder that is not there is said to be gone, beside the way back", %{
      conn: conn,
      site: site,
      photos: photos
    } do
      view = conn |> tenant_conn(site) |> open(%{id: Ecto.UUID.generate()})

      assert has_element?(view, "#media-crumb-missing")
      refute has_element?(view, "#media-folder-up")

      view |> element("a#media-crumb-root") |> render_click()
      assert_patch(view, @path)
      render_async(view)

      refute has_element?(view, "#media-crumb-missing")
      assert in_rail?(view, photos)
    end
  end

  describe "a new folder" do
    test "is made inside the folder open", %{conn: conn, site: site, year: year} do
      view = conn |> tenant_conn(site) |> open(year)

      view |> element("#media-add-category") |> render_click()

      view
      |> element("#media_category_form-form")
      |> render_submit(%{"form" => %{"name" => "Spring"}})

      made =
        MediaCategory
        |> Ash.Query.filter(name == "spring")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      assert made.parent_id == year.id
      assert in_rail?(view, made), "the new folder joined the rail of the folder it was made in"
    end

    test "is made by a master inside the folder open, on the folder's site", %{
      conn: conn,
      site: site,
      photos: photos
    } do
      view = conn |> log_in(create_admin("boss@example.com")) |> open(photos)

      view
      |> element("#media_category_form-form")
      |> render_submit(%{"form" => %{"name" => "Summer"}})

      made =
        MediaCategory
        |> Ash.Query.filter(name == "summer")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      assert made.parent_id == photos.id
      assert made.site_id == site.id
    end
  end

  test "a file uploaded with a folder open lands in it", %{
    conn: conn,
    site: site,
    covers: covers,
    dir: dir
  } do
    view = conn |> tenant_conn(site) |> open(covers)

    file =
      file_input(view, "#media_form-form", :media_files_media_form, [
        %{name: "cover.png", content: "cover bytes", type: "image/png"}
      ])

    render_upload(file, "cover.png")
    view |> element("#media_form-form") |> render_submit(%{"form" => %{}})

    [media] = Ash.read!(Media, tenant: site.id, authorize?: false)

    assert media.media_category_id == covers.id
    assert String.starts_with?(media.relative_path, "/uploads/#{site.id}/media/#{covers.id}/")
    assert File.read!(Path.join(dir, media.relative_path)) == "cover bytes"
  end

  describe "moving" do
    test "a file goes to the folder browsed to", %{
      conn: conn,
      site: site,
      year: year,
      videos: videos
    } do
      media = create_media!(site_id: site.id, media_category_id: year.id)
      view = conn |> tenant_conn(site) |> open(year)

      view |> element("button[title='Move'][phx-value-values*='#{media.id}']") |> render_click()
      render_async(view)

      assert has_element?(view, "#media-move-modal")
      assert has_element?(view, "#media-move-already-here")
      assert has_element?(view, "#media-move-confirm[disabled]")

      view |> element("#media-move-crumb-top") |> render_click()
      render_async(view)
      view |> element("#media-move-folder-#{videos.id}") |> render_click()
      render_async(view)

      view |> element("#media-move-confirm") |> render_click()

      assert stored_media(media).media_category_id == videos.id
      assert stored_media(media).relative_path == media.relative_path
      assert render(view) =~ "Moved “#{media.name}” to videos."
      refute has_element?(view, "#media-move-modal")
    end

    test "a file goes to the top level", %{conn: conn, site: site, year: year} do
      media = create_media!(site_id: site.id, media_category_id: year.id)
      view = conn |> tenant_conn(site) |> open(year)

      view |> element("button[title='Move'][phx-value-values*='#{media.id}']") |> render_click()
      render_async(view)
      view |> element("#media-move-crumb-top") |> render_click()
      render_async(view)
      view |> element("#media-move-confirm") |> render_click()

      assert stored_media(media).media_category_id == nil
    end

    test "a folder goes with everything under it, and leaves the rail it was in", %{
      conn: conn,
      site: site,
      photos: photos,
      year: year,
      covers: covers,
      videos: videos
    } do
      view = conn |> tenant_conn(site) |> open(photos)

      render_click(button(view, "move_category", year.id))
      render_async(view)

      view |> element("#media-move-crumb-top") |> render_click()
      render_async(view)

      assert has_element?(view, "#media-move-folder-#{photos.id}"),
             "the top level lists the folder the moved one is in"

      view |> element("#media-move-folder-#{videos.id}") |> render_click()
      render_async(view)
      view |> element("#media-move-confirm") |> render_click()

      assert stored(year).parent_id == videos.id
      assert stored(covers).parent_id == year.id
      refute in_rail?(view, year), "the moved folder is no longer inside the one open"
    end

    test "a folder is never offered itself to go into", %{
      conn: conn,
      site: site,
      photos: photos
    } do
      view = conn |> tenant_conn(site) |> open()

      render_click(button(view, "move_category", photos.id))
      render_async(view)

      assert has_element?(view, "#media-move-already-here")
      refute has_element?(view, "#media-move-folder-#{photos.id}")
    end
  end

  test "a folder that still holds a file is not archived, and the rail says why", %{
    conn: conn,
    site: site,
    photos: photos,
    videos: videos
  } do
    create_media!(site_id: site.id, media_category_id: videos.id)
    view = conn |> tenant_conn(site) |> open()

    render_click(button(view, "delete_category", videos.id))
    assert render(view) =~ "This folder still holds files"
    assert is_nil(stored(videos).archived_at)
    assert in_rail?(view, videos)

    render_click(button(view, "delete_category", photos.id))
    assert render(view) =~ "This folder still holds other folders"
    assert is_nil(stored(photos).archived_at)
  end

  describe "folders written elsewhere" do
    test "one made inside another folder stays out of the top-level rail", %{
      conn: conn,
      site: site,
      photos: photos
    } do
      view = conn |> tenant_conn(site) |> open()

      inside = folder!(site, "Inside", photos)
      render(view)

      refute in_rail?(view, inside)
    end

    test "one moved into the folder open joins its rail", %{
      conn: conn,
      site: site,
      photos: photos,
      videos: videos
    } do
      view = conn |> tenant_conn(site) |> open(photos)
      refute in_rail?(view, videos)

      {:ok, _moved} =
        Ash.update(videos, %{parent_id: photos.id},
          action: :update,
          tenant: site.id,
          authorize?: false
        )

      render(view)
      assert in_rail?(view, videos)
    end
  end
end
