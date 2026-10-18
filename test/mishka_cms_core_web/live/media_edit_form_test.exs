# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Test.MediaEditFormTest do
  @moduledoc """
  The media library's edit form, as a site's own admin uses it.

  Where a file lives is the server's to say: the form shows the path read-only and never sends it,
  and the update action does not accept one — so a save carrying a path typed in, or put into the
  request by hand, leaves the row pointing at its own file. Nor does a save take the file an upload
  entry put into the request by hand names: only a file the form's own upload staged is stored. See
  `MishkaCmsCore.Runtime.MediaStorageTest` for what the file operations themselves may touch.

  `:media_static_dir` points the files at the test's own folder; this case is not async.

  Its own file rather than `MediaCategoriesTest`, which is about the category rail of the same page.
  """
  use MishkaCmsCore.ConnCase

  import Phoenix.LiveViewTest
  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Files

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/runtime/medias"

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "media_edit_form_#{System.unique_integer([:positive])}")
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
      |> log_in(create_admin("tenant@example.com", site.id))

    row =
      create_media!(
        site_id: site.id,
        relative_path: "/uploads/#{site.id}/media/uncategorized/#{Ecto.UUID.generate()}.png",
        type: :images,
        format: "png"
      )

    {:ok,
     conn: conn, site: site, row: row, dir: dir, own: on_disk!(dir, row.relative_path, "own")}
  end

  defp on_disk!(dir, "/" <> relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp star_permission do
    Permission
    |> Ash.Query.filter(name == "*")
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_permission!(name: "*")
      permission -> permission
    end
  end

  defp create_admin(email, site_id) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.Changeset.set_tenant(site_id)
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

  # The row's Edit button, which loads the row into the form beside the library.
  defp edit(conn, row) do
    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    view |> element("button[title='Edit'][phx-click*='#{row.id}']") |> render_click()
    render_async(view)
    view
  end

  defp stored(row), do: Ash.get!(Media, row.id, tenant: row.site_id, authorize?: false)

  test "the form shows where the file is, read-only", %{conn: conn, row: row} do
    view = edit(conn, row)

    assert has_element?(
             view,
             "#media_form-form input[name='form[relative_path]'][readonly]" <>
               "[value='#{row.relative_path}']"
           )
  end

  # LiveView puts `phx-click-loading` on the clicked button until the server answers, so the
  # button dims and takes no second click while the file is on its way into the form.
  test "the Edit button shows its click is on its way", %{conn: conn, row: row} do
    {:ok, view, _html} = live(conn, @path)
    render_async(view)

    edit = "button[title='Edit'][phx-click*='#{row.id}']"

    assert has_element?(view, "#{edit}[class*='phx-click-loading:pointer-events-none']")
    assert has_element?(view, "#{edit}[class*='phx-click-loading:opacity-']")
  end

  test "a save with another site's path typed in keeps the row's own file", %{
    conn: conn,
    row: row
  } do
    theirs = "/uploads/#{create_site!().id}/media/uncategorized/theirs.png"

    conn
    |> edit(row)
    |> element("#media_form-form")
    |> render_submit(%{
      "form" => %{"name" => row.name, "description" => "Edited", "relative_path" => theirs}
    })

    saved = stored(row)
    assert saved.description == "Edited", "the save did not go through"
    assert saved.relative_path == row.relative_path
  end

  test "a save carrying an upload entry for another site's file stores nothing", %{
    conn: conn,
    dir: dir,
    row: row,
    own: own
  } do
    theirs =
      on_disk!(dir, "/uploads/#{create_site!().id}/media/uncategorized/theirs.png", "theirs")

    conn
    |> edit(row)
    |> element("#media_form-form")
    |> render_submit(%{
      "form" => %{
        "name" => row.name,
        "description" => "Edited",
        "media_files" => %{"0" => %{"path" => theirs, "client_name" => "x.png"}}
      }
    })

    assert File.read!(theirs) == "theirs"
    assert File.read!(own) == "own"

    saved = stored(row)
    assert saved.relative_path == row.relative_path
    assert saved.description == row.description
  end

  test "a file uploaded through the form replaces the row's own", %{
    conn: conn,
    row: row,
    own: own
  } do
    view = edit(conn, row)

    file =
      file_input(view, "#media_form-form", :media_files_media_form, [
        %{name: "new.png", content: Files.png() <> "new", type: "image/png"}
      ])

    render_upload(file, "new.png")

    view
    |> element("#media_form-form")
    |> render_submit(%{"form" => %{"name" => row.name, "description" => "Replaced"}})

    saved = stored(row)
    assert saved.description == "Replaced", "the save did not go through"
    assert saved.relative_path == row.relative_path
    assert File.read!(own) == Files.png() <> "new"
  end
end
