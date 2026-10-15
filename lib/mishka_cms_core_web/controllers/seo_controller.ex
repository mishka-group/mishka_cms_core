defmodule MishkaCmsCoreWeb.SeoController do
  @moduledoc """
  A site's `/robots.txt`, `/favicon.ico` and `/sitemap.xml`, with the `/sitemap-00001.xml.gz`…
  files it lists, each its own, answered on the site's own address.

  All are routed through `MishkaCmsCoreWeb.Routes`' `:public` list, so the site is the one the
  request's host resolved to (`conn.assigns.current_site`), and an offline site answers them with
  `MishkaCms.Plugs.MaintenanceGate`'s 503 before this is reached. Every URL they name is absolute,
  on the site's `host` (`MishkaCmsCore.Helpers.site_url/2`).

  ## robots.txt

  Built on every request, from ETS:

    1. the rules every site has — `User-agent: *` and a `Disallow` for `/admin/`, `/api/` and
       `/_preview/` — and the sign-in page with a query and the pages under it, at `/auth` and at
       its address in each language the site publishes in
       (`MishkaCmsCore.Runtime.Plugs.SiteLookupPlug.auth_address/3`): `Disallow: /auth$`,
       `Disallow: /auth?` and `Disallow: /auth/`, then the same for `/fa/auth`…, which leave an
       address that only starts the same way, such as `/authors`, open;
    2. what a plugin on `seo:robots:lines` makes of them: it is handed `%{site: site, lines: lines}`
       and returns the map with its `lines`;
    3. the site's `seo.robots.extra` setting, a line at a time;
    4. a blank line and `Sitemap: <the site's /sitemap.xml>`.

  Sent as `text/plain`.

  ## favicon.ico

  A redirect to the site's favicon, the picture its pages name in `<link rel="icon">`
  (`MishkaCmsCore.Runtime.Seo.favicon/1`): a `/…` path on the site itself, or an `http://…` or
  `https://…` address. A browser asks for it on a page that names none, such as an admin page. A
  site with no favicon, or one set to anything else, is a 404 no cache keeps. Answers whatever
  `Accept` a browser sends.

  ## sitemap.xml and its files

  Served from `MishkaCmsCore.Runtime.States.AssetsState` under `{site.name, "sitemap"}`, which
  `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` fills — what goes in it, and when it is built,
  is described there. No request builds it. `/sitemap.xml` is its `<sitemapindex>`, sent as
  `application/xml`; `/sitemap-00001.xml.gz`… are the gzipped files it lists, at the root beside
  it, each sent as it is stored, as `application/gzip`. Both with `x-robots-tag: noindex`.

  A file answers whatever `Accept` a crawler sends, as a static file does
  (`MishkaCmsCore.ExtensionRouter.route_accepts/2`).

  ## Caching

  `public, max-age=60`, and no session cookie: the session is read, as the gates in front of these
  need it, and never written back, so a shared cache may keep the answer. An admin let through to an
  offline site gets `private, no-store`, as the gate gives every page it lets them through to. A
  gzipped file adds `no-transform`, which keeps the server's response compression from gzipping it
  again on every request.

  ## Refusals

  A file name that is not `sitemap-<5 digits>.xml.gz`, or one the stored sitemap does not hold, or a
  request for the sitemap with no site, is a 404 that no cache keeps. A site whose sitemap this node
  has not built yet — one created a moment ago, a node still booting — has its job enqueued and is
  answered 503 with `retry-after: 60` and `cache-control: no-store`, so a crawler comes back rather
  than reading the sitemap as gone. A plugin on `web:request:sitemap_unavailable` hears each first,
  with `%{site: site | nil, reason: :unknown_file | :no_site | :not_built}` as its meta, and may
  answer instead by halting the conn.
  """
  use Phoenix.Controller, formats: []
  import Plug.Conn

  plug :keep_session_unwritten

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.Hook

  @rules [
    "User-agent: *",
    "Disallow: /admin/",
    "Disallow: /api/"
  ]

  # Seconds a crawler is told to wait for a sitemap not built yet.
  @retry_after "60"

  # The only names `SitemapCompiler` gives a file.
  @file_name ~r/\Asitemap-\d{5}\.xml\.gz\z/

  def robots(%{assigns: %{current_site: %{} = site}} = conn, _params),
    do: answer(conn, site, "text/plain", robots_txt(site))

  def favicon(%{assigns: %{current_site: %{} = site}} = conn, _params) do
    case Seo.favicon(site.id) do
      "/" <> _ = path -> conn |> cache_control(site) |> redirect(to: path)
      url when is_binary(url) -> conn |> cache_control(site) |> redirect(external: url)
      nil -> refused(conn, :no_favicon)
    end
  end

  def favicon(conn, _params), do: refused(conn, :no_site)

  def sitemap(%{assigns: %{current_site: %{} = site}} = conn, _params) do
    case stored(site) do
      {:ok, %{index: index}} -> serve(conn, site, "application/xml", index)
      {:error, :not_built} -> refuse(conn, site, :not_built)
    end
  end

  def sitemap(conn, _params), do: refuse(conn, nil, :no_site)

  def sitemap_file(%{assigns: %{current_site: %{} = site}} = conn, %{"file" => file}) do
    name = "sitemap-" <> file

    with true <- Regex.match?(@file_name, name),
         {:ok, %{files: files}} <- stored(site),
         {:ok, file} <- Map.fetch(files, name) do
      serve(conn, site, "application/gzip", file)
    else
      {:error, :not_built} -> refuse(conn, site, :not_built)
      _no_such_file -> refuse(conn, site, :unknown_file)
    end
  end

  def sitemap_file(conn, _params), do: refuse(conn, nil, :no_site)

  defp serve(conn, site, type, body),
    do: conn |> put_resp_header("x-robots-tag", "noindex") |> answer(site, type, body)

  defp answer(conn, site, type, body) do
    conn
    |> put_resp_content_type(type, charset(type))
    |> cache_control(site, transform(type))
    |> send_resp(200, body)
  end

  defp cache_control(conn, site, extra \\ "") do
    cache_control =
      if Settings.offline?(site), do: "private, no-store", else: "public, max-age=60"

    put_resp_header(conn, "cache-control", cache_control <> extra)
  end

  # A gzipped file is bytes, so it names no charset.
  defp charset("application/gzip"), do: nil
  defp charset(_text), do: "utf-8"

  # Sent as it is stored: Bandit compresses every response a client accepts gzip for unless it is
  # told not to transform it, and would gzip the gzipped file again on every request.
  defp transform("application/gzip"), do: ", no-transform"
  defp transform(_text), do: ""

  # Nothing here changes the session, so no answer sends the cookie.
  defp keep_session_unwritten(conn, _opts), do: configure_session(conn, ignore: true)

  defp refuse(conn, site, reason) do
    "web:request:sitemap_unavailable"
    |> Hook.call(conn, meta: %{site: site, reason: reason})
    |> refused(reason)
  end

  defp refused(%{halted: true} = conn, _reason), do: conn

  defp refused(conn, :not_built) do
    conn
    |> put_resp_header("retry-after", @retry_after)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(503, "")
    |> halt()
  end

  defp refused(conn, _reason),
    do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "") |> halt()

  defp robots_txt(site) do
    rules = rules(site)

    lines =
      case Hook.call("seo:robots:lines", %{site: site, lines: rules}) do
        %{lines: lines} when is_list(lines) -> Enum.filter(lines, &is_binary/1)
        _refused -> rules
      end

    sitemap = "Sitemap: " <> Helpers.site_url(site.host, "/sitemap.xml")
    Enum.join(lines ++ extra_rules(site) ++ ["", sitemap], "\n") <> "\n"
  end

  # `/auth` whatever the URL mode, then the address of each language's: in `"prefix_others"` the
  # primary language's is `/auth` itself.
  defp rules(site) do
    addresses = Enum.map(Languages.site(site.id), &SiteLookupPlug.auth_address(&1, site.id))

    disallowed =
      for path <- Enum.uniq(["/auth" | addresses]),
          ending <- ["$", "?", "/"],
          do: "Disallow: #{path}#{ending}"

    @rules ++ disallowed ++ ["Disallow: /_preview/"]
  end

  defp extra_rules(site) do
    with text when is_binary(text) <- Settings.get("seo.robots.extra", "", site.id),
         text when text != "" <- String.trim(text) do
      text |> String.split(["\r\n", "\n", "\r"]) |> Enum.map(&String.trim/1)
    else
      _none -> []
    end
  end

  defp stored(site) do
    case AssetsState.get_value(site.name, "sitemap") do
      %{index: _index, files: _files} = sitemap -> {:ok, sitemap}
      _not_built -> not_built(site)
    end
  end

  # NOT BUILT ON THIS NODE YET, which is not a sitemap that is gone: its job is enqueued, and the
  # request is answered without one. A job already pending, waiting to retry or running is left as
  # it is: moved later on every miss, it would never run for a site a crawler asks every few seconds,
  # and one added beside a running build would read the whole site again for nothing.
  defp not_built(site) do
    _ = SitemapCompiler.schedule(site.id, replace: [], states: :incomplete)
    {:error, :not_built}
  end
end
