# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteIconTest.DrawnListener do
  @moduledoc false
  use MishkaInstaller.Event.Hook, event: "runtime:site:after_icons"

  @impl true
  def call(data) do
    if pid = Process.whereis(:__site_icon_probe__), do: send(pid, {:icons_drawn, data})
    {:reply, data}
  end
end

defmodule MishkaCmsCore.Runtime.SiteIconTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.SiteIcon`: which picture a site's icons are drawn from, the links a page's
  head names them by, and what is kept of them — dropped when either setting is saved or the media
  file it names is. What the routes send is pinned in `MishkaCmsCoreWeb.SeoControllerTest`.

  `:media_static_dir` points the files at the test's own folder; `async: false` — `AssetsState`,
  the settings cache, the plugin registry and that folder are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.{MediaSiteIcons, Seo, SiteIcon}
  alias MishkaCmsCore.Runtime.SiteIconTest.DrawnListener
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState}
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  @base "https://icons.test"

  setup do
    dir = Path.join(System.tmp_dir!(), "site_icon_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)
    snapshot = SettingsState.snapshot()
    site = create_site!(active: true)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      SettingsState.restore(snapshot)
      SiteIcon.forget(site.id)
      File.rm_rf(dir)
    end)

    %{site: site, dir: dir}
  end

  describe "source/1" do
    test "is the App icon, else the favicon, when it is a picture of the site's own", %{
      site: site,
      dir: dir
    } do
      assert SiteIcon.source(site.id) == nil

      favicon = media!(dir, site, "icon.png", png(16, 16))
      {:ok, _} = Settings.put("site.favicon", favicon, site_id: site.id)

      assert %{path: path, type: "image/png", hash: hash, failed?: false} =
               SiteIcon.source(site.id)

      assert path == disk(dir, favicon)
      assert hash =~ ~r/\A[0-9a-f]{16}\z/

      app = media!(dir, site, "app.svg", ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))
      {:ok, _} = Settings.put("site.app_icon", app, site_id: site.id)
      assert %{path: path, type: "image/svg+xml"} = SiteIcon.source(site.id)
      assert path == disk(dir, app)
      assert SiteIcon.favicon(site.id) == %{path: disk(dir, favicon), type: "image/png"}

      # An address elsewhere is never fetched, and a file no picture is no source.
      for app <- [
            "https://cdn.example.com/app.png",
            media!(dir, site, "notes.txt", "not a picture")
          ] do
        {:ok, _} = Settings.put("site.app_icon", app, site_id: site.id)
        assert %{path: path} = SiteIcon.source(site.id)
        assert path == disk(dir, favicon), app
      end
    end

    test "is named by the picture's bytes: the same file is the same hash, another one another",
         %{
           site: site,
           dir: dir
         } do
      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "a.png", png(16, 16)), site_id: site.id)

      %{hash: first} = SiteIcon.source(site.id)

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "b.png", png(16, 16)), site_id: site.id)

      assert %{hash: ^first} = SiteIcon.source(site.id)

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "c.png", png(16, 16, :red)),
          site_id: site.id
        )

      refute SiteIcon.source(site.id).hash == first
    end
  end

  describe "a page's head" do
    test "links the home-screen icon and the manifest for a site with a picture of its own", %{
      site: site,
      dir: dir
    } do
      head = Seo.head(seo(site), base: @base)
      assert link(head, "apple-touch-icon") == nil
      assert link(head, "manifest") == nil

      {:ok, _} =
        Settings.put("site.favicon", "https://cdn.example.com/icon.png", site_id: site.id)

      head = Seo.head(seo(site), base: @base)
      assert link(head, "icon") == "https://cdn.example.com/icon.png"
      assert link(head, "apple-touch-icon") == nil
      assert link(head, "manifest") == nil

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", png(512, 512)),
          site_id: site.id
        )

      %{hash: hash} = SiteIcon.source(site.id)
      head = Seo.head(seo(site), base: @base)

      assert {"link", attrs} =
               Enum.find(
                 head.tags,
                 &(match?({"link", _attrs}, &1) and rel(&1) == "apple-touch-icon")
               )

      assert Map.new(attrs) == %{
               "rel" => "apple-touch-icon",
               "sizes" => "180x180",
               "href" => "/apple-touch-icon.png?v=" <> hash
             }

      assert link(head, "manifest") == "/site.webmanifest"
      assert link(head, "icon") == "https://cdn.example.com/icon.png"
    end

    test "names each link it emits in the catalog, as a default", %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(32, 32)), site_id: site.id)

      defaults = for entry <- Seo.catalog(), entry.default?, into: MapSet.new(), do: entry.id

      for {"link", _attrs} = tag <- Seo.head(seo(site), base: @base).tags,
          do: assert(rel(tag) in defaults, rel(tag))

      assert %{attrs: %{"rel" => "apple-touch-icon", "sizes" => "180x180"}} =
               Enum.find(Seo.catalog(), &(&1.id == "apple-touch-icon"))
    end

    test "a page's own link of the same name replaces the default", %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(32, 32)), site_id: site.id)

      own = [
        Seo.stored_tag(
          "link",
          %{"rel" => "apple-touch-icon", "sizes" => "180x180"},
          "/own-icon.png"
        )
      ]

      head = Seo.head(seo(site), base: @base, layers: [own])
      assert link(head, "apple-touch-icon") == "/own-icon.png"
    end
  end

  describe "the app settings" do
    test "short_name/1, theme_color/1 and background_color/1 read the site's own, else nil", %{
      site: site
    } do
      other = create_site!(active: true)
      on_exit(fn -> SiteIcon.forget(other.id) end)

      for read <- [&SiteIcon.short_name/1, &SiteIcon.theme_color/1, &SiteIcon.background_color/1],
          do: assert(read.(site.id) == nil)

      {:ok, _} = Settings.put("site.app_short_name", "  Acme ", site_id: site.id)
      {:ok, _} = Settings.put("site.theme_color", "#0b0a14", site_id: site.id)
      {:ok, _} = Settings.put("site.background_color", "#abc", site_id: site.id)

      assert SiteIcon.short_name(site.id) == "Acme"
      assert SiteIcon.theme_color(site.id) == "#0b0a14"
      assert SiteIcon.background_color(site.id) == "#abc"

      assert SiteIcon.short_name(other.id) == nil
      assert SiteIcon.theme_color(other.id) == nil
      assert SiteIcon.background_color(other.id) == nil
    end

    test "an empty or blank value is none, and a color that is not a hex color is none", %{
      site: site
    } do
      for blank <- ["", "   "] do
        {:ok, _} = Settings.put("site.app_short_name", blank, site_id: site.id)
        assert SiteIcon.short_name(site.id) == nil
      end

      for refused <- ["", "red", "#12", "#1234567", " #abc", "#abc\"><b>"] do
        {:ok, _} = Settings.put("site.theme_color", refused, site_id: site.id)
        {:ok, _} = Settings.put("site.background_color", refused, site_id: site.id)
        assert SiteIcon.theme_color(site.id) == nil, inspect(refused)
        assert SiteIcon.background_color(site.id) == nil, inspect(refused)
      end
    end

    test "color?/1 takes #rgb and #rrggbb in either case, and nothing else" do
      for color <- ["#abc", "#ABC", "#0b0a14", "#0B0A14", "#000", "#fFf"],
          do: assert(SiteIcon.color?(color), color)

      for refused <- ["", "#", "red", "#12", "#1234", "#12345", "#1234567", "#ggg", "abc", nil, 5],
          do: refute(SiteIcon.color?(refused), inspect(refused))

      assert SiteIcon.color_or_empty?("")
      assert SiteIcon.color_or_empty?("#abc")
      refute SiteIcon.color_or_empty?("red")
    end

    test "short_name?/1 counts characters up to the most a name may have" do
      assert SiteIcon.short_name_max() == 30
      assert SiteIcon.short_name?(String.duplicate("م", 30))
      refute SiteIcon.short_name?(String.duplicate("م", 31))
      refute SiteIcon.short_name?(nil)
    end
  end

  describe "a page's theme color" do
    test "is in the head only while the site has one, icons or not, and follows the setting", %{
      site: site,
      dir: dir
    } do
      assert meta(Seo.head(seo(site), base: @base), "theme-color") == nil

      {:ok, _} = Settings.put("site.theme_color", "#0b0a14", site_id: site.id)
      head = Seo.head(seo(site), base: @base)
      assert meta(head, "theme-color") == "#0b0a14"
      assert link(head, "manifest") == nil

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", png(512, 512)),
          site_id: site.id
        )

      head = Seo.head(seo(site), base: @base)
      assert meta(head, "theme-color") == "#0b0a14"
      assert link(head, "manifest") == "/site.webmanifest"

      # Saved again, it reads as saved on the next page: nothing is restarted or forgotten.
      {:ok, _} = Settings.put("site.theme_color", "#fff", site_id: site.id)
      assert meta(Seo.head(seo(site), base: @base), "theme-color") == "#fff"

      {:ok, _} = Settings.put("site.theme_color", "", site_id: site.id)
      assert meta(Seo.head(seo(site), base: @base), "theme-color") == nil
      assert link(Seo.head(seo(site), base: @base), "manifest") == "/site.webmanifest"
    end

    test "is left out when what is saved is no hex color", %{site: site} do
      for refused <- ["red", "#12", "#abc\"><script>"] do
        {:ok, _} = Settings.put("site.theme_color", refused, site_id: site.id)
        assert meta(Seo.head(seo(site), base: @base), "theme-color") == nil, refused
      end
    end

    test "is each site's own", %{site: site} do
      other = create_site!(active: true)

      {:ok, _} = Settings.put("site.theme_color", "#111111", site_id: site.id)
      {:ok, _} = Settings.put("site.theme_color", "#222222", site_id: other.id)

      assert meta(Seo.head(seo(site), base: @base), "theme-color") == "#111111"
      assert meta(Seo.head(seo(other), base: @base), "theme-color") == "#222222"
      assert meta(Seo.head(seo(create_site!(active: true)), base: @base), "theme-color") == nil
    end

    test "is named in the catalog as a default, and a page's own tag replaces it", %{site: site} do
      assert %{attrs: %{"name" => "theme-color"}, tag: "meta", default?: true} =
               Enum.find(Seo.catalog(), &(&1.id == "theme-color"))

      {:ok, _} = Settings.put("site.theme_color", "#0b0a14", site_id: site.id)
      own = [Seo.stored_tag("meta", %{"name" => "theme-color"}, "#ff0000")]

      head = Seo.head(seo(site), base: @base, layers: [own])
      assert meta(head, "theme-color") == "#ff0000"
      assert Enum.count(head.tags, &(meta_name(&1) == "theme-color")) == 1
    end
  end

  describe "file/2" do
    test "draws every size at once, the first time one is asked for, and announces it", %{
      site: site,
      dir: dir
    } do
      Process.register(self(), :__site_icon_probe__)
      register!(DrawnListener, SiteIcon.drawn_event())

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(40, 40)), site_id: site.id)

      %{hash: hash} = SiteIcon.source(site.id)

      assert {:ok, %{path: path, hash: ^hash}} = SiteIcon.file(site.id, 192)
      assert path == Path.join(SiteIcon.dir(site.id), "#{hash}-192.png")
      assert_receive {:icons_drawn, %{site_id: site_id, hash: ^hash, files: files}}
      assert site_id == site.id
      assert files |> Map.keys() |> Enum.sort() == [180, 192, 512]

      for size <- [180, 192, 512] do
        assert {:ok, %{path: path}} = SiteIcon.file(site.id, size)
        image = Image.open!(path)
        assert {Image.width(image), Image.height(image)} == {size, size}
      end

      refute_receive {:icons_drawn, _data}, 100
      assert SiteIcon.file(nil, 180) == :error
    end

    test "requests that come while the icons are drawn wait for them: they are drawn once", %{
      site: site,
      dir: dir
    } do
      Process.register(self(), :__site_icon_probe__)
      register!(DrawnListener, SiteIcon.drawn_event())

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", png(64, 64)), site_id: site.id)

      answers =
        [180, 192, 512, 180, 192, 512]
        |> Task.async_stream(&SiteIcon.file(site.id, &1), timeout: :infinity)
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.all?(answers, &match?({:ok, %{path: _path}}, &1))
      assert_receive {:icons_drawn, _data}
      refute_receive {:icons_drawn, _data}, 200
    end
  end

  describe "forgetting" do
    test "saving either setting drops what is kept of the site's icons; another setting does not",
         %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(16, 16)), site_id: site.id)

      assert %{hash: hash} = SiteIcon.source(site.id)
      assert %{source: %{hash: ^hash}} = AssetsState.get_value(site.id, "site_icon")

      {:ok, _} = Settings.put("site.title", "Acme", site_id: site.id)
      assert %{source: %{hash: ^hash}} = AssetsState.get_value(site.id, "site_icon")

      for key <- SiteIcon.settings() do
        SiteIcon.source(site.id)
        assert %{settings: [_app_icon, _favicon]} = AssetsState.get_value(site.id, "site_icon")

        {:ok, _} = Settings.put(key, "https://cdn.example.com/#{key}.png", site_id: site.id)
        assert AssetsState.get_value(site.id, "site_icon") == nil, key
      end
    end

    test "a global value drops it for every site", %{site: site} do
      assert SiteIcon.source(site.id) == nil
      assert %{source: nil} = AssetsState.get_value(site.id, "site_icon")

      {:ok, _} = Settings.put("site.app_icon", "")
      assert AssetsState.get_value(site.id, "site_icon") == nil
    end

    test "a media file saved drops it only when it is the favicon or the picture", %{
      site: site,
      dir: dir
    } do
      icon = media!(dir, site, "icon.png", png(16, 16))
      {:ok, _} = Settings.put("site.favicon", icon, site_id: site.id)
      %{hash: hash} = SiteIcon.source(site.id)

      other = media!(dir, site, "cover.png", png(16, 16))

      for path <- [other, "/uploads/#{site.id}/media/../../etc/passwd"] do
        assert {:reply, _media} =
                 MediaSiteIcons.call(%{relative_path: path, site_id: site.id}, %{})

        assert %{source: %{hash: ^hash}} = AssetsState.get_value(site.id, "site_icon"), path
      end

      assert {:reply, _media} = MediaSiteIcons.call(%{relative_path: icon, site_id: site.id}, %{})
      assert AssetsState.get_value(site.id, "site_icon") == nil
    end
  end

  defp media!(dir, site, name, contents) do
    path = Path.join([dir, "uploads", site.id, "media", "brand", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    "/uploads/#{site.id}/media/brand/#{name}"
  end

  defp disk(dir, address), do: Path.join(dir, address)

  defp png(width, height, color \\ :purple),
    do: width |> Image.new!(height, color: color) |> Image.write!(:memory, suffix: ".png")

  defp register!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  defp seo(site) do
    %{
      title: "About the studio",
      description: nil,
      image: nil,
      type: "website",
      url: "#{@base}/about",
      language: "en",
      tags: [],
      schema: [],
      vars: %{},
      site_id: site.id
    }
  end

  defp rel({"link", attrs}), do: attrs |> List.keyfind("rel", 0) |> elem(1)

  defp meta_name({"meta", attrs}),
    do: List.keyfind(attrs, "name", 0) |> then(&(&1 && elem(&1, 1)))

  defp meta_name(_other), do: nil

  defp meta(head, name) do
    Enum.find_value(head.tags, fn
      {"meta", attrs} -> {"name", name} in attrs && List.keyfind(attrs, "content", 0) |> elem(1)
      _other -> nil
    end)
  end

  defp link(head, rel) do
    Enum.find_value(head.tags, fn
      {"link", attrs} -> {"rel", rel} in attrs && List.keyfind(attrs, "href", 0) |> elem(1)
      _other -> nil
    end)
  end
end
