# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.SeoControllerTest do
  @moduledoc """
  A site's `/robots.txt`, `/sitemap.xml` and the `/sitemap-00001.xml.gz`… files beside it, as
  `MishkaCmsCoreWeb.SeoController` serves them: the rules every site has and what a plugin and the
  site add to them, and the addresses of the site's pages, its extra ones and a plugin's, with their
  images, on the site's own address, gzipped into files of 50,000 that the index lists. The sitemap
  is the one `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` stored, served from ETS, so a test
  arranges what it lists and builds it before it asks; one not built yet is a 503 no request
  builds, and enqueues its job.

  Through this library's test router, so the site is the one the request's host resolves to, and
  the router's `route_accepts` is the CMS's. What the CMS's own pipeline adds in front — the offline
  gate — is pinned in the CMS's `MishkaCmsWeb.SeoFilesTest`.

  `async: false` — `SiteState`, `AssetsState`, the settings cache and the plugin registry are
  process-global.
  """
  use MishkaCmsCore.ConnCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.{Seo, SiteIcon}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState, TranslationsState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Settings

  alias MishkaCmsCore.Test.Plugins.{
    SeoManyUrls,
    SeoRobotsLines,
    SeoSitemapSlashes,
    SeoSitemapUrls,
    SiteManifestTheme
  }

  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCore.Test.Plugins.{SitemapUnavailable, SitemapUnavailablePage}
  alias MishkaInstaller.Event.{Event, EventHandler}

  # The mark a page carries when its template answers every language its site has.
  @every_language %{"serves_all_languages" => true}

  @first_file "/sitemap-00001.xml.gz"

  # Twice as wide as it is tall, violet.
  @wide_svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100"><rect width="200" height="100" fill="#7c4dff"/></svg>)

  setup do
    Process.register(self(), :__plugin_hook_probe__)
    snapshot = SettingsState.snapshot()
    host = "seo-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.language_urls", "prefix_others", site_id: site.id)

    on_exit(fn ->
      SettingsState.restore(snapshot)
      SiteState.delete(site.id)
      AssetsState.delete(site.name, "sitemap")
      SiteIcon.forget(site.id)
    end)

    %{site: site}
  end

  defp fetch(site, path, opts \\ []) do
    host = opts[:host] || site.host

    build_conn()
    |> Map.put(:host, site.host)
    |> Map.update!(:req_headers, &[{"host", host} | List.keydelete(&1, "host", 0)])
    |> then(&if(opts[:accept], do: put_req_header(&1, "accept", opts[:accept]), else: &1))
    |> get(path)
  end

  defp build!(site) do
    {:ok, _sitemap} = SitemapCompiler.compile_and_store(site.name)
    :ok
  end

  # Every `<url>` the stored sitemap lists, file after file as its index names them, once it is
  # built from what the test arranged.
  defp built_entries(site) do
    build!(site)
    listed_entries(site)
  end

  defp listed_entries(site) do
    for {loc, _lastmod} <- sitemaps(fetch(site, "/sitemap.xml").resp_body),
        entry <- entries(file!(site, URI.parse(loc).path)),
        do: entry
  end

  defp built_locs(site), do: site |> built_entries() |> Enum.map(&elem(&1, 0))

  # A file as it is served, unzipped.
  defp file!(site, path) do
    conn = fetch(site, path)
    assert conn.status == 200, "#{path} was not served"
    :zlib.gunzip(conn.resp_body)
  end

  # The folder a site's media and icons are read from and written to: the test's own.
  defp media_dir(_context) do
    dir = Path.join(System.tmp_dir!(), "seo_icons_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mishka_cms_core, :media_static_dir, dir)

    on_exit(fn ->
      Application.delete_env(:mishka_cms_core, :media_static_dir)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # A picture in the site's media library, and the address a setting names it by.
  defp media!(dir, site, name, contents) do
    path = Path.join([dir, "uploads", site.id, "media", "brand", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    "/uploads/#{site.id}/media/brand/#{name}"
  end

  defp png(width, height, color \\ :purple),
    do: width |> Image.new!(height, color: color) |> Image.write!(:memory, suffix: ".png")

  defp alpha(image, x, y) do
    {:ok, pixel} = Image.get_pixel(image, x, y)
    List.last(pixel)
  end

  # A second site the runtime knows, on its own host.
  defp cached_site! do
    host = "seo-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp register!(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
  end

  # The site's own origin, from the endpoint's scheme and port — never the request's.
  defp origin(site) do
    uri = MishkaCmsCore.TestEndpoint.struct_url()
    "#{uri.scheme}://#{site.host}:#{uri.port}"
  end

  # Each `<sitemap>` of an index as `{loc, lastmod}`, in order.
  defp sitemaps(index) do
    ~r{<sitemap>\s*<loc>([^<]*)</loc>\s*<lastmod>([^<]*)</lastmod>\s*</sitemap>}
    |> Regex.scan(index, capture: :all_but_first)
    |> Enum.map(fn [loc, lastmod] -> {loc, lastmod} end)
  end

  # Each `<url>` of a sitemap file as `{loc, lastmod | nil}`, in order.
  defp entries(file) do
    ~r{<url>\s*<loc>([^<]*)</loc>(?:\s*<lastmod>([^<]*)</lastmod>)?}
    |> Regex.scan(file, capture: :all_but_first)
    |> Enum.map(fn
      [loc] -> {loc, nil}
      [loc, lastmod] -> {loc, lastmod}
    end)
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp disallowed(robots) do
    for "Disallow: " <> pattern <- String.split(robots, "\n"), do: pattern
  end

  # RFC 9309's matching for the patterns robots.txt holds here: a prefix, or a whole path when it
  # ends in `$`.
  defp kept_out?(patterns, path) do
    Enum.any?(patterns, fn pattern ->
      if String.ends_with?(pattern, "$"),
        do: path == String.trim_trailing(pattern, "$"),
        else: String.starts_with?(path, pattern)
    end)
  end

  defp refused?(conn) do
    conn.status == 404 and conn.resp_body == "" and
      get_resp_header(conn, "cache-control") == ["no-store"]
  end

  describe "robots.txt" do
    test "is the rules every site has, then the site's sitemap on its own address", %{site: site} do
      conn = fetch(site, "/robots.txt", host: "#{site.host}:9999")

      assert conn.status == 200

      assert conn.resp_body ==
               """
               User-agent: *
               Disallow: /admin/
               Disallow: /api/
               Disallow: /auth$
               Disallow: /auth?
               Disallow: /auth/
               Disallow: /fa/auth$
               Disallow: /fa/auth?
               Disallow: /fa/auth/
               Disallow: /_preview/

               Sitemap: #{origin(site)}/sitemap.xml
               """

      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "keeps out the sign-in pages in every language the site publishes in, and nothing that only starts like one",
         %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "de"], site_id: site.id)

      # `/auth` in either mode, and each language's own address of it.
      for {mode, prefixes} <- [{"prefix_others", ["", "/de"]}, {"prefix_all", ["", "/en", "/de"]}] do
        {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)
        rules = disallowed(fetch(site, "/robots.txt").resp_body)

        for prefix <- prefixes,
            path <- ["/auth", "/auth?return_to=abc", "/auth/register", "/auth/magic-link/tok"] do
          assert kept_out?(rules, prefix <> path), "#{prefix <> path} is crawlable in #{mode}"
        end

        for path <- [
              "/authors",
              "/en/authors",
              "/de/authentic",
              "/en/about/auth",
              "/fa/auth",
              "/en"
            ] do
          refute kept_out?(rules, path), "#{path} is kept out in #{mode}"
        end
      end
    end

    test "takes a plugin's rules, then the site's own extra ones, above the sitemap", %{
      site: site
    } do
      register!(SeoRobotsLines, "seo:robots:lines")
      {:ok, _} = Settings.put("seo.robots.extra", "Disallow: /everywhere/")

      assert fetch(site, "/robots.txt").resp_body =~
               "Disallow: /_preview/\nDisallow: /plugin/\nDisallow: /everywhere/\n\nSitemap: "

      {:ok, _} =
        Settings.put("seo.robots.extra", "  Disallow: /drafts/\r\nAllow: /admin/help  \n",
          site_id: site.id
        )

      assert fetch(site, "/robots.txt").resp_body =~
               "Disallow: /plugin/\nDisallow: /drafts/\nAllow: /admin/help\n\nSitemap: "
    end

    test "is kept by no cache while the site is offline, for the admin let through to it", %{
      site: site
    } do
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

      assert fetch(site, "/robots.txt") |> get_resp_header("cache-control") == [
               "private, no-store"
             ]
    end
  end

  describe "favicon.ico" do
    @browser_accept "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"

    setup :media_dir

    test "sends the site's own favicon file as it is, with the type its first bytes say", %{
      site: site,
      dir: dir
    } do
      bytes = png(32, 32)

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", bytes), site_id: site.id)

      conn = fetch(site, "/favicon.ico", accept: @browser_accept)

      assert conn.status == 200
      assert conn.resp_body == bytes
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      refute conn |> get_resp_header("content-security-policy") |> Enum.join() =~ "sandbox"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
      assert get_resp_header(conn, "location") == []
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "sandboxes an SVG favicon, and names an ICO one what it is", %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.svg", @wide_svg), site_id: site.id)

      conn = fetch(site, "/favicon.ico")
      assert conn.resp_body == @wide_svg
      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      # Sandboxed on top of the policy every response gets.
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "frame-ancestors 'self'"
      assert String.ends_with?(policy, "; sandbox")

      ico = <<0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0>> <> :binary.copy(<<0>>, 64)

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.ico", ico), site_id: site.id)

      conn = fetch(site, "/favicon.ico")
      assert conn.resp_body == ico
      assert get_resp_header(conn, "content-type") == ["image/x-icon"]
    end

    test "sends a browser to a favicon that is no file of the site's own, on the site", %{
      site: site
    } do
      {:ok, _} =
        Settings.put("site.favicon", "/uploads/#{site.id}/media/icon.png", site_id: site.id)

      conn = fetch(site, "/favicon.ico", accept: @browser_accept)

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/uploads/#{site.id}/media/icon.png"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "takes the global favicon, and an address as it is, for a site with none of its own", %{
      site: site
    } do
      {:ok, _} = Settings.put("site.favicon", " HTTPS://cdn.example.com/icon.png?v=2 ")

      conn = fetch(site, "/favicon.ico")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://cdn.example.com/icon.png?v=2"]
    end

    test "is a 404 no cache keeps for a site with no favicon, or one that is no address", %{
      site: site
    } do
      for value <- [
            "",
            "icon.png",
            "//evil.example/icon.png",
            "/\\evil.example/icon.png",
            "\\\\evil.example/icon.png",
            "javascript:alert(1)",
            "data:image/png;base64,AAAA",
            "ftp://cdn.example.com/icon.png",
            "https://user:secret@evil.example/icon.png",
            "https:///icon.png"
          ] do
        {:ok, _} = Settings.put("site.favicon", value, site_id: site.id)
        conn = fetch(site, "/favicon.ico")

        assert conn.status == 404, inspect(value)
        assert get_resp_header(conn, "location") == []
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end

    test "is kept by no cache while the site is offline", %{site: site, dir: dir} do
      {:ok, _} = Settings.put("site.favicon", "/icon.png", site_id: site.id)
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

      assert fetch(site, "/favicon.ico") |> get_resp_header("cache-control") == [
               "private, no-store"
             ]

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(8, 8)), site_id: site.id)

      assert fetch(site, "/favicon.ico") |> get_resp_header("cache-control") == [
               "private, no-store"
             ]
    end
  end

  describe "home-screen icons" do
    setup :media_dir

    test "the apple-touch icon is a 180×180 PNG of the App icon, an SVG fitted whole on transparency",
         %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.svg", @wide_svg), site_id: site.id)

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(16, 16, :red)),
          site_id: site.id
        )

      for path <- ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"] do
        conn = fetch(site, path, accept: @browser_accept)

        assert conn.status == 200
        assert get_resp_header(conn, "content-type") == ["image/png"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        assert get_resp_header(conn, "set-cookie") == []

        image = Image.from_binary!(conn.resp_body)
        assert {Image.width(image), Image.height(image)} == {180, 180}
        # The 2:1 picture spans the width, centered: clear above and below it, violet in it.
        assert alpha(image, 90, 20) == 0
        assert alpha(image, 90, 160) == 0
        assert {:ok, [r, g, b, 255]} = Image.get_pixel(image, 90, 90)
        assert_in_delta r, 124, 2
        assert_in_delta g, 77, 2
        assert_in_delta b, 255, 2
      end
    end

    test "are drawn from the favicon, a PNG, for a site with no App icon", %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.png", png(64, 32)), site_id: site.id)

      image = fetch(site, "/apple-touch-icon.png").resp_body |> Image.from_binary!()

      assert {Image.width(image), Image.height(image)} == {180, 180}
      assert alpha(image, 90, 20) == 0
      assert alpha(image, 90, 90) == 255
    end

    test "the manifest's icons are 192 and 512, kept a year at the address with their picture's hash",
         %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", png(600, 600)),
          site_id: site.id
        )

      %{hash: hash} = SiteIcon.source(site.id)

      for size <- [192, 512] do
        conn = fetch(site, "/site-icon-#{size}.png?v=#{hash}")
        image = Image.from_binary!(conn.resp_body)

        assert {Image.width(image), Image.height(image)} == {size, size}
        assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

        for path <- ["/site-icon-#{size}.png", "/site-icon-#{size}.png?v=0123456789abcdef"] do
          assert fetch(site, path) |> get_resp_header("cache-control") == [
                   "public, max-age=86400"
                 ]
        end
      end

      assert File.ls!(SiteIcon.dir(site.id)) |> Enum.sort() ==
               ["#{hash}-180.png", "#{hash}-192.png", "#{hash}-512.png"]
    end

    test "are a 404 no cache keeps for a site with no picture of its own to draw them from", %{
      site: site,
      dir: dir
    } do
      ico = <<0, 0, 1, 0, 1, 0>> <> :binary.copy(<<0>>, 64)

      for value <- [
            "",
            "https://cdn.example.com/icon.png",
            "/uploads/#{site.id}/media/brand/missing.png",
            media!(dir, site, "icon.ico", ico)
          ] do
        {:ok, _} = Settings.put("site.favicon", value, site_id: site.id)

        for path <-
              ~w(/apple-touch-icon.png /site-icon-192.png /site-icon-512.png /site.webmanifest) do
          conn = fetch(site, path)

          assert conn.status == 404, "#{path} for #{inspect(value)}"
          assert get_resp_header(conn, "cache-control") == ["no-store"]
        end
      end

      refute File.exists?(SiteIcon.dir(site.id))
    end

    @tag :capture_log
    test "are a 404 for a picture libvips cannot read, which is not tried again", %{
      site: site,
      dir: dir
    } do
      broken = <<0x89, "PNG\r\n", 0x1A, "\n">> <> "not the rest of a picture"

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", broken), site_id: site.id)

      assert fetch(site, "/apple-touch-icon.png").status == 404
      assert %{failed?: true} = SiteIcon.source(site.id)
      assert SiteIcon.file(site.id, 512) == :error
      refute File.exists?(SiteIcon.dir(site.id))
    end

    test "each site draws its own, from its own pictures", %{site: site, dir: dir} do
      other = cached_site!()

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", png(32, 32, :red)),
          site_id: site.id
        )

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, other, "app.png", png(32, 32, :blue)),
          site_id: other.id
        )

      red = fetch(site, "/apple-touch-icon.png").resp_body |> Image.from_binary!()
      blue = fetch(other, "/apple-touch-icon.png").resp_body |> Image.from_binary!()

      assert Image.get_pixel(red, 90, 90) == {:ok, [255, 0, 0, 255]}
      assert Image.get_pixel(blue, 90, 90) == {:ok, [0, 0, 255, 255]}
      assert [_, _, _] = File.ls!(SiteIcon.dir(site.id))
      assert [_, _, _] = File.ls!(SiteIcon.dir(other.id))

      # Another site's media is not the site's own: it draws nothing from it.
      {:ok, _} =
        Settings.put("site.app_icon", "/uploads/#{site.id}/media/brand/app.png",
          site_id: other.id
        )

      assert fetch(other, "/apple-touch-icon.png").status == 404
    end

    test "are drawn again from the new picture once the setting changes, and the old ones deleted",
         %{site: site, dir: dir} do
      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "red.png", png(32, 32, :red)),
          site_id: site.id
        )

      old = SiteIcon.url(site.id, 180)
      red = fetch(site, old).resp_body |> Image.from_binary!()
      assert Image.get_pixel(red, 90, 90) == {:ok, [255, 0, 0, 255]}

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "blue.png", png(32, 32, :blue)),
          site_id: site.id
        )

      new = SiteIcon.url(site.id, 180)
      refute new == old

      conn = fetch(site, new)
      blue = Image.from_binary!(conn.resp_body)
      assert Image.get_pixel(blue, 90, 90) == {:ok, [0, 0, 255, 255]}
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

      %{hash: hash} = SiteIcon.source(site.id)
      assert File.ls!(SiteIcon.dir(site.id)) |> Enum.all?(&String.starts_with?(&1, hash))
    end
  end

  describe "site.webmanifest" do
    setup :media_dir

    test "names the site, where it starts and its icons, as the JSON a browser installs it with",
         %{
           site: site,
           dir: dir
         } do
      {:ok, _} = Settings.put("site.title", "Acme Studio", site_id: site.id)

      {:ok, _} =
        Settings.put("site.app_icon", media!(dir, site, "app.png", png(512, 512)),
          site_id: site.id
        )

      %{hash: hash} = SiteIcon.source(site.id)
      conn = fetch(site, "/site.webmanifest", accept: "*/*")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/manifest+json; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
      assert get_resp_header(conn, "set-cookie") == []

      assert Jason.decode!(conn.resp_body) == %{
               "name" => "Acme Studio",
               "short_name" => "Acme Studio",
               "start_url" => "/",
               "display" => "browser",
               "icons" => [
                 %{
                   "src" => "/site-icon-192.png?v=#{hash}",
                   "sizes" => "192x192",
                   "type" => "image/png"
                 },
                 %{
                   "src" => "/site-icon-512.png?v=#{hash}",
                   "sizes" => "512x512",
                   "type" => "image/png"
                 }
               ]
             }

      # Each address it names is served.
      for %{"src" => src} <- Jason.decode!(conn.resp_body)["icons"],
          do: assert(fetch(site, src).status == 200)
    end

    test "names the site in its primary language, and holds what a plugin adds", %{
      site: site,
      dir: dir
    } do
      register!(SiteManifestTheme, SiteIcon.manifest_event())
      {:ok, _} = Settings.put("site.title", "Acme Studio", site_id: site.id)
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)
      TranslationsState.put(site.id, "fa", "Acme Studio", "استودیو آکمه")

      {:ok, _} =
        Settings.put("site.favicon", media!(dir, site, "icon.svg", @wide_svg), site_id: site.id)

      manifest = fetch(site, "/site.webmanifest").resp_body |> Jason.decode!()

      assert manifest["name"] == "استودیو آکمه"
      assert manifest["short_name"] == "استودیو آکمه"
      assert manifest["theme_color"] == "#07070d"
      assert manifest["background_color"] == "#07070d"
    end
  end

  describe "sitemap.xml" do
    test "is the index of the site's files beside it, on its own address, built when", %{
      site: site
    } do
      create_page!(site_id: site.id, path: "/about")
      before = DateTime.truncate(DateTime.utc_now(), :second)
      build!(site)

      conn = fetch(site, "/sitemap.xml", host: "#{site.host}:9999")

      assert conn.status == 200
      assert conn.resp_body =~ ~s(xmlns="http://www.sitemaps.org/schemas/sitemap/0.9")
      assert [{loc, lastmod}] = sitemaps(conn.resp_body)
      assert loc == origin(site) <> @first_file

      assert {:ok, built_at, 0} = DateTime.from_iso8601(lastmod)
      assert DateTime.compare(built_at, before) != :lt
      assert DateTime.compare(built_at, DateTime.utc_now()) != :gt

      assert get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "is an index of no file for a site with nothing to list", %{site: site} do
      build!(site)

      conn = fetch(site, "/sitemap.xml")

      assert conn.status == 200

      assert conn.resp_body == """
             <?xml version="1.0" encoding="UTF-8"?>
             <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
             </sitemapindex>
             """

      assert fetch(site, @first_file) |> refused?()
    end

    test "lists each literal page at its path on the site's address, with when it changed", %{
      site: site
    } do
      about = create_page!(site_id: site.id, path: "/about")
      contact = create_page!(site_id: site.id, path: "/contact")
      create_page!(site_id: site.id, path: "/draft", active: false)
      build!(site)

      conn = fetch(site, @first_file)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/gzip"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=60, no-transform"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert get_resp_header(conn, "set-cookie") == []

      file = :zlib.gunzip(conn.resp_body)

      assert file =~ ~r{<urlset [^>]*xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"}
      refute file =~ "xmlns:image"

      assert entries(file) == [
               {origin(site) <> "/about", iso(about.updated_at)},
               {origin(site) <> "/contact", iso(contact.updated_at)}
             ]

      # Kept by no cache while the site is offline, and still sent as it is stored.
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

      assert fetch(site, @first_file) |> get_resp_header("cache-control") == [
               "private, no-store, no-transform"
             ]
    end

    # A page marked as serving every language answers each of the site's; one that is not, its own
    # alone — and nothing at all when its site does not list it.
    test "lists a page whose only capture is the language once per language it answers", %{
      site: site
    } do
      create_page!(site_id: site.id, path: "/:lang/guide", extra: @every_language)
      create_page!(site_id: site.id, path: "/:lang/team", language: "fa")
      create_page!(site_id: site.id, path: "/:lang/careers", language: "de")

      assert site |> built_locs() |> Enum.sort() ==
               Enum.map(["/fa/guide", "/fa/team", "/guide"], &(origin(site) <> &1))

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert site |> built_locs() |> Enum.sort() ==
               Enum.map(["/en/guide", "/fa/guide", "/fa/team"], &(origin(site) <> &1))
    end

    test "hands a page with a capture only its owner fills to the plugins, and lists theirs", %{
      site: site
    } do
      register!(SeoSitemapUrls, "seo:sitemap:urls")
      about = create_page!(site_id: site.id, path: "/about")
      create_page!(site_id: site.id, path: "/:lang/blog/:slug", extra: @every_language)

      entries = built_entries(site)

      assert_receive {:sitemap_pages, ["/:lang/blog/:slug"]}

      # A page's address keeps its date, the plugin's own are listed, one percent-encoded where a URL
      # may not hold what it names, and a path off the site is not.
      assert entries == [
               {origin(site) <> "/about", iso(about.updated_at)},
               {origin(site) <> "/from-plugin", "2026-01-02T03:04:05Z"},
               {origin(site) <> "/%C3%BCber%20uns", nil}
             ]
    end

    test "lists each address once, with no slash at its end, whoever lists it", %{site: site} do
      register!(SeoSitemapSlashes, "seo:sitemap:urls")
      create_page!(site_id: site.id, path: "/")
      create_page!(site_id: site.id, path: "/about")

      assert built_locs(site) == [
               origin(site),
               origin(site) <> "/about",
               origin(site) <> "/guides"
             ]
    end

    test "lists a page at the address its canonical address and og:url name", %{site: site} do
      create_page!(site_id: site.id, path: "/")
      create_page!(site_id: site.id, path: "/about")

      base = Seo.base(site.host)
      page = %{title: "Page", language: "en", seo: %{description: nil, schema: []}}

      addresses =
        for path <- ["/", "/about"] do
          head = Seo.resolve(page, site_id: site.id, url: Seo.absolute(path, base), base: base)

          canonical =
            for {"link", a} <- head.tags, {"rel", "canonical"} in a, {"href", h} <- a, do: h

          og_url =
            for {"meta", a} <- head.tags, {"property", "og:url"} in a, {"content", c} <- a, do: c

          assert canonical == [head.url]
          assert og_url == [head.url]
          head.url
        end

      assert addresses == [origin(site), origin(site) <> "/about"]
      assert built_locs(site) == addresses
    end

    # THE ADDRESSES ARE COUNTED AS THEY ARE WRITTEN, so a plugin's rows are read from the database
    # once per build, never once to count and again to write.
    test "reads the addresses a plugin adds once a build", %{site: site} do
      register!(SeoSitemapUrls, "seo:sitemap:urls")

      build!(site)

      assert_received :sitemap_urls_read
      refute_received :sitemap_urls_read
    end

    test "lists an address's images, a path on the site's address and a URL as it is", %{
      site: site
    } do
      register!(SeoSitemapUrls, "seo:sitemap:urls")
      build!(site)

      file = file!(site, @first_file)

      assert file =~ ~s(xmlns:image="http://www.google.com/schemas/sitemap-image/1.1")

      # One with no scheme takes the site's; what a URL may not hold is percent-encoded, a control
      # character too, which would leave the file no longer XML; one with no host is left out.
      assert Regex.scan(~r{<image:loc>([^<]*)</image:loc>}, file, capture: :all_but_first) == [
               [origin(site) <> "/media/cover.png"],
               ["https://cdn.example.com/a.jpg"],
               [URI.parse(origin(site)).scheme <> "://cdn.example.com/b.jpg"],
               ["https://cdn.example.com/a%20b.jpg"],
               ["https://cdn.example.com/c%01.jpg"]
             ]
    end

    # AN ADDRESS A LOGIN-ONLY OR NOINDEX PAGE ANSWERS AT is that page's, whichever plugin would name
    # it too — compared as a visitor is served it, so `/en/from-plugin` is `/from-plugin` on a site
    # that leaves English unprefixed.
    test "leaves out an address a page it does not list is stored at", %{site: site} do
      register!(SeoSitemapUrls, "seo:sitemap:urls")
      create_page!(site_id: site.id, path: "/about")
      create_page!(site_id: site.id, path: "/:lang/guide", extra: @every_language)

      create_page!(
        site_id: site.id,
        path: "/fa/members",
        language: "fa",
        permissions: ["members:read"]
      )

      create_page!(
        site_id: site.id,
        path: "/en/from-plugin",
        seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}]
      )

      assert built_locs(site) == [
               origin(site) <> "/about",
               origin(site) <> "/guide",
               origin(site) <> "/fa/guide",
               origin(site) <> "/%C3%BCber%20uns"
             ]
    end

    # A ROUTE IN FRONT OF THE PAGES ANSWERS ITS PATHS, so a page stored at one is never served. Every
    # `:public` route of the configured extensions counts — the sitemap's own and the asset bundles'
    # here — and a path none of them answers is a page's again.
    test "leaves out a page at a path a route in front of the pages answers", %{site: site} do
      for path <- [
            "/about",
            "/robots.txt",
            "/sitemap.xml",
            "/sitemap-guide",
            "/assets/css/a/b",
            "/sitemaps/guide"
          ],
          do: create_page!(site_id: site.id, path: path)

      assert built_locs(site) == [origin(site) <> "/about", origin(site) <> "/sitemaps/guide"]
    end

    # NO ADDRESS IN A SITEMAP REDIRECTS: one under the primary language a site leaves unprefixed is
    # listed where a visitor lands, once, whoever named it.
    test "lists an address where a visitor is served it, whoever names it", %{site: site} do
      create_page!(site_id: site.id, path: "/en/pricing")
      create_page!(site_id: site.id, path: "/fa/pricing", language: "fa")

      {:ok, _} =
        Settings.put("seo.sitemap.paths", ["/en/pricing", "/en/search", "/fa/search"],
          site_id: site.id
        )

      assert built_locs(site) == [
               origin(site) <> "/pricing",
               origin(site) <> "/fa/pricing",
               origin(site) <> "/search",
               origin(site) <> "/fa/search"
             ]
    end

    test "lists the site's extra addresses, escaped", %{site: site} do
      create_page!(site_id: site.id, path: "/pricing")

      {:ok, _} =
        Settings.put("seo.sitemap.paths", ["/pricing", "/search?q=a&b=c"], site_id: site.id)

      assert built_locs(site) == [
               origin(site) <> "/pricing",
               origin(site) <> "/search?q=a&amp;b=c"
             ]
    end

    test "serves the stored copy; a page created since appears only after the next build", %{
      site: site
    } do
      create_page!(site_id: site.id, path: "/first")
      assert built_locs(site) == [origin(site) <> "/first"]

      create_page!(site_id: site.id, path: "/second")
      assert site |> listed_entries() |> Enum.map(&elem(&1, 0)) == [origin(site) <> "/first"]

      assert built_locs(site) == [origin(site) <> "/first", origin(site) <> "/second"]
    end
  end

  describe "a sitemap file" do
    setup %{site: site} do
      create_page!(site_id: site.id, path: "/about")
      build!(site)
    end

    test "answers the Accept a crawler sends for it", %{site: site} do
      browser = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

      for accept <- [
            "*/*",
            "application/gzip",
            "application/x-gzip",
            "application/xml",
            "text/xml",
            browser
          ] do
        conn = fetch(site, @first_file, accept: accept)

        assert conn.status == 200, "refused #{accept}"
        assert :zlib.gunzip(conn.resp_body) =~ "<urlset "
      end
    end

    # A PAGE IS STILL HTML ALONE: the file's route names what it answers, the rest of the router
    # keeps refusing what is not a page.
    test "leaves every other route refusing what is not html", %{site: site} do
      for accept <- ["application/gzip", "application/x-gzip"] do
        assert_error_sent 406, fn -> fetch(site, "/admin/dashboard", accept: accept) end
      end
    end

    test "answers a name that is no file with a 404 no cache keeps, heard first", %{site: site} do
      register!(SitemapUnavailable, "web:request:sitemap_unavailable")
      site_id = site.id

      for name <- [
            "sitemap-",
            "sitemap-other.xml",
            "sitemap-1.xml.gz",
            "sitemap-000001.xml.gz",
            "sitemap-00001.xml",
            "sitemap-00002.xml.gz",
            "sitemap-..%2Fx",
            "sitemap-..%2F..%2Fsitemap.xml"
          ] do
        assert fetch(site, "/" <> name) |> refused?(), "#{name} was served"
        assert_receive {:sitemap_unavailable, :unknown_file, ^site_id}
      end
    end

    # ONE SEGMENT IS A NAME, so `..` spelled out is a path of two the route never matches, and one
    # encoded into the name is a name no file has.
    test "is never reached by a path that climbs out of the name", %{site: site} do
      conn = fetch(site, "/sitemap-../x")

      assert conn.status == 404
      refute conn.private[:phoenix_controller] == MishkaCmsCoreWeb.SeoController
    end

    test "leaves a name that names no file to a plugin that answers it", %{site: site} do
      register!(SitemapUnavailablePage, "web:request:sitemap_unavailable")

      conn = fetch(site, "/sitemap-other.xml")

      assert conn.status == 410
      assert conn.resp_body == "A plugin's own answer"
      refute get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "a sitemap not built yet" do
    setup do
      register!(SitemapUnavailable, "web:request:sitemap_unavailable")
    end

    test "is a 503 a crawler comes back for, heard first, and no request builds it", %{site: site} do
      site_id = site.id
      create_page!(site_id: site.id, path: "/about")

      for path <- ["/sitemap.xml", @first_file] do
        conn = fetch(site, path)

        assert conn.status == 503
        assert conn.resp_body == ""
        assert get_resp_header(conn, "retry-after") == ["60"]
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert_receive {:sitemap_unavailable, :not_built, ^site_id}
      end

      refute AssetsState.exists?(site.name, "sitemap")
    end

    test "still answers a name that can be no file with a 404", %{site: site} do
      site_id = site.id

      assert fetch(site, "/sitemap-other.xml") |> refused?()
      assert_receive {:sitemap_unavailable, :unknown_file, ^site_id}
    end

    # EACH ROUTE ENQUEUES THE JOB ITSELF, from no job at all: a crawler that asks a node started
    # since for a file it knew gets a sitemap built, not a 503 forever.
    test "enqueues the site's sitemap job from either route, and a later request adds none", %{
      site: site
    } do
      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

      # Every state, where `all_enqueued/1` lists the available and scheduled alone.
      sitemap_jobs = fn ->
        Enum.filter(
          @repo.all(Oban.Job),
          &(&1.worker == inspect(RuntimeCompilerWorker) and
              get_in(&1.args, ["data", "type"]) == "sitemap" and
              get_in(&1.args, ["data", "site_id"]) == site.id)
        )
      end

      for path <- ["/sitemap.xml", @first_file] do
        @repo.delete_all(Oban.Job)

        assert fetch(site, path).status == 503
        assert [%{queue: "sitemaps"} = job] = sitemap_jobs.(), "#{path} enqueued no job"

        # Left where it is while it waits, while it runs and while it waits to retry.
        for state <- ["scheduled", "executing", "retryable"] do
          job = job |> Ecto.Changeset.change(state: state) |> @repo.update!()

          assert fetch(site, path).status == 503
          assert [%{id: id, scheduled_at: scheduled_at}] = sitemap_jobs.()
          assert {id, scheduled_at} == {job.id, job.scheduled_at}, "#{path} moved a #{state} job"
        end
      end
    end
  end

  describe "a sitemap not built yet while web:request:sitemap_unavailable cannot run" do
    test "is still a 503 a crawler comes back for", %{site: site} do
      EventCannotRun.stub!("web:request:sitemap_unavailable")
      create_page!(site_id: site.id, path: "/about")

      conn = fetch(site, "/sitemap.xml")

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["60"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "a sitemap past 50,000 addresses" do
    setup %{site: site} do
      register!(SeoManyUrls, "seo:sitemap:urls")
      build!(site)
    end

    test "is an index of its files, each file 50,000 addresses at most", %{site: site} do
      index = fetch(site, "/sitemap.xml")

      assert index.status == 200

      assert Enum.map(sitemaps(index.resp_body), &elem(&1, 0)) == [
               origin(site) <> "/sitemap-00001.xml.gz",
               origin(site) <> "/sitemap-00002.xml.gz"
             ]

      assert site |> file!(@first_file) |> entries() |> length() == 50_000

      assert site |> file!("/sitemap-00002.xml.gz") |> entries() == [
               {origin(site) <> "/item/50001", nil}
             ]

      assert fetch(site, "/sitemap-00003.xml.gz") |> refused?()
    end
  end
end
