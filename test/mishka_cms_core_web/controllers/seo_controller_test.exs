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
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Settings

  alias MishkaCmsCore.Test.Plugins.{
    SeoManyUrls,
    SeoRobotsLines,
    SeoSitemapSlashes,
    SeoSitemapUrls
  }

  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCore.Test.Plugins.{SitemapUnavailable, SitemapUnavailablePage}
  alias MishkaInstaller.Event.{Event, EventHandler}

  # The mark a page carries when its template answers every language its site has.
  @every_language %{"serves_all_languages" => true}

  @first_file "/sitemap-00001.xml.gz"

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

    test "sends a browser to the site's own favicon, on the site", %{site: site} do
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

    test "is kept by no cache while the site is offline", %{site: site} do
      {:ok, _} = Settings.put("site.favicon", "/icon.png", site_id: site.id)
      {:ok, _} = Settings.put("cms.offline", true, site_id: site.id)

      assert fetch(site, "/favicon.ico") |> get_resp_header("cache-control") == [
               "private, no-store"
             ]
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
