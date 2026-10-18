# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.MediaUploadContentTest do
  @moduledoc """
  What a file must be to enter the media library.

  The library is served from the site's own origin, so a page or an SVG with a script that is saved
  as a picture runs for whoever opens its address. Two things keep it out: `.svg` is not a media
  type, and the first bytes of every file are read (`MishkaCmsCore.Runtime.FileSignature`) and must
  be the kind the extension names — a name is only what the uploader typed.

  Driven through the actions an editor reaches: `upload` (the JSON:API and the builder's sheet) and
  `form_upload` (the Media Manager form).

  `async: false` — the static folder is application config.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Test.Files

  @moduletag :integration

  setup do
    dir = Path.join(System.tmp_dir!(), "media_content_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    site = create_site!()

    %{dir: dir, site: site, admin: create_user_with_permissions!(["*"], site_id: site.id)}
  end

  defp staged(name, content) do
    path = Path.join(System.tmp_dir!(), "gervaz_#{System.unique_integer([:positive])}_#{name}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp upload(site, admin, name, content) do
    Media
    |> Ash.ActionInput.for_action(
      :upload,
      %{file: Ash.Type.File.from_path(staged(name, content)), original_filename: name},
      actor: admin,
      tenant: site.id
    )
    |> Ash.run_action()
  end

  defp form_upload(site, admin, name, content) do
    Media
    |> Ash.Changeset.for_create(
      :form_upload,
      %{media_files: [%{path: staged(name, content), client_name: name}]},
      actor: admin,
      tenant: site.id
    )
    |> Ash.create()
  end

  defp on_disk(dir), do: Path.wildcard(Path.join([dir, "**", "*"])) |> Enum.reject(&File.dir?/1)

  describe "validate_and_process_file/1" do
    defp check(name, content) do
      Media.validate_and_process_file(%{
        file: Ash.Type.File.from_path(staged(name, content)),
        original_filename: name
      })
    end

    test "takes each kind of file with the bytes of its own kind" do
      for {name, content} <- [
            {"cover.png", Files.png()},
            {"photo.jpg", Files.jpeg()},
            {"photo.JPEG", Files.jpeg()},
            {"anim.gif", Files.gif()},
            {"hero.webp", Files.webp()},
            {"clip.mp4", Files.mp4()},
            {"guide.pdf", Files.pdf()},
            {"notes.txt", "notes\n"},
            {"data.csv", "a,b\n1,2\n"}
          ] do
        assert {:ok, %{extension: extension}} = check(name, content), name
        assert extension == name |> Path.extname() |> String.downcase()
      end
    end

    test "has no SVG among the types it takes" do
      assert {:error, error} = check("logo.svg", Files.svg())
      assert Exception.message(error) =~ ~s(File type ".svg" is not allowed)
      refute Exception.message(error) =~ "Allowed: \".svg"
      refute Exception.message(error) =~ ", .svg"
    end

    test "turns away a page, a script and an SVG saved under a picture's name" do
      for name <- ~w(cover.png photo.jpg anim.gif hero.webp),
          content <- [Files.html(), Files.svg(), Files.script()] do
        assert {:error, error} = check(name, content), "#{name} was taken"
        assert Exception.message(error) =~ "is not a", name
      end
    end

    test "turns away a real picture saved under another kind's name" do
      assert {:error, _error} = check("clip.mp4", Files.png())
      assert {:error, _error} = check("guide.pdf", Files.png())
      assert {:error, _error} = check("cover.png", Files.pdf())
      assert {:error, _error} = check("photo.jpg", Files.png())
    end

    test "turns away a file whose extension is not a media type, whatever it holds" do
      for name <- ~w(page.html page.htm logo.svg data.xml run.js) do
        assert {:error, error} = check(name, Files.png())
        assert Exception.message(error) =~ "is not allowed", name
      end
    end
  end

  describe "an editor's upload" do
    test "stores a real picture", %{dir: dir, site: site, admin: admin} do
      assert {:ok, %Media{format: "png", type: :images}} =
               upload(site, admin, "cover.png", Files.png())

      assert [stored] = on_disk(dir)
      assert File.read!(stored) == Files.png()
    end

    test "refuses a script named as a picture, and stores nothing", %{
      dir: dir,
      site: site,
      admin: admin
    } do
      for {name, content} <- [
            {"cover.png", Files.svg()},
            {"cover.jpg", Files.html()},
            {"cover.gif", Files.script()}
          ] do
        assert {:error, error} = upload(site, admin, name, content)
        assert Exception.message(error) =~ "is not a", name
      end

      assert on_disk(dir) == []
      assert Ash.read!(Media, tenant: site.id, authorize?: false) == []
    end

    test "refuses an SVG, and stores nothing", %{dir: dir, site: site, admin: admin} do
      assert {:error, error} = upload(site, admin, "logo.svg", Files.svg())
      assert Exception.message(error) =~ "is not allowed"

      assert on_disk(dir) == []
      assert Ash.read!(Media, tenant: site.id, authorize?: false) == []
    end
  end

  describe "the Media Manager form's upload" do
    test "stores a real picture", %{dir: dir, site: site, admin: admin} do
      assert {:ok, %Media{format: "png"}} = form_upload(site, admin, "cover.png", Files.png())
      assert [_stored] = on_disk(dir)
    end

    test "refuses a script named as a picture, and an SVG, and stores nothing", %{
      dir: dir,
      site: site,
      admin: admin
    } do
      assert {:error, error} = form_upload(site, admin, "cover.png", Files.html())
      assert Exception.message(error) =~ "is not a"

      assert {:error, error} = form_upload(site, admin, "logo.svg", Files.svg())
      assert Exception.message(error) =~ "is not allowed"

      assert on_disk(dir) == []
      assert Ash.read!(Media, tenant: site.id, authorize?: false) == []
    end
  end
end
