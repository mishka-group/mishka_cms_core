# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.SiteLookupRedirectTest do
  @moduledoc """
  A request for an address one of its site's redirect rules names, answered by
  `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` the moment the site is known: the rule's status and
  `location`, a halt, and nothing written to the session.

  Every other request goes on as before — an address no rule names, a rule switched off, another
  site's rule. A file `Plug.Static` does not find reaches the same check, since it falls through to
  the router; one it finds is served and never asks.
  """
  use MishkaCmsCore.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
  alias MishkaCmsCore.Runtime.Redirect
  alias MishkaCmsCore.Runtime.States.{RedirectsState, SiteState}
  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCore.Test.Plugins.WebRedirected
  alias MishkaInstaller.Event.{Event, EventHandler}

  @moduletag :integration

  # What a browser sends for an `<img>`: images first, then anything.
  @image_accept "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "redirecting-#{n}", host: "redirecting-#{n}.test", active: true)
    other = create_site!(name: "elsewhere-#{n}", host: "elsewhere-#{n}.test", active: true)

    for cached <- [site, other] do
      :ok =
        SiteState.save(%{
          id: cached.id,
          name: cached.name,
          host: cached.host,
          priority: 0,
          active: true
        })
    end

    on_exit(fn ->
      SiteState.delete(site.id)
      SiteState.delete(other.id)
    end)

    {:ok, site: site, other: other}
  end

  defp rule!(site, attrs) do
    redirect = Ash.create!(Redirect, attrs, action: :create, tenant: site.id, authorize?: false)
    _handled = :sys.get_state(RedirectsState)
    redirect
  end

  defp request(path, host, headers \\ []) do
    conn(:get, path)
    |> Map.put(:req_headers, [{"host", host} | headers])
    |> init_test_session(%{})
    |> fetch_query_params()
    |> SiteLookupPlug.call(SiteLookupPlug.init([]))
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  describe "an address a rule names" do
    test "is answered with the rule's status and location, before the session is touched", %{
      site: site
    } do
      rule!(site, %{from_path: "/images/blog/photo.jpg", to: "/uploads/s/media/photo.jpg"})

      conn = request("/images/blog/photo.jpg", site.host)

      assert conn.halted
      assert conn.status == 301
      assert location(conn) == "/uploads/s/media/photo.jpg"
      assert conn.assigns.current_site.id == site.id
      assert get_session(conn, :current_site) == nil
      assert Ash.PlugHelpers.get_tenant(conn) == nil
    end

    test "keeps the request's query string when the target has none of its own", %{site: site} do
      rule!(site, %{from_path: "/old", to: "/new"})
      rule!(site, %{from_path: "/tagged", to: "/new?utm=rule#top"})

      assert "/old?page=2&q=a" |> request(site.host) |> location() == "/new?page=2&q=a"
      assert "/tagged?page=2" |> request(site.host) |> location() == "/new?utm=rule#top"
    end

    test "answers with each status a rule may carry", %{site: site} do
      for status <- [302, 307, 308] do
        rule!(site, %{from_path: "/s#{status}", to: "/new", status: status})
        assert request("/s#{status}", site.host).status == status
      end
    end

    test "sends a visitor off the site to the full address exactly as it is stored", %{
      site: site
    } do
      rule!(site, %{from_path: "/docs", to: "https://docs.example.com/start"})

      conn = request("/docs/?ref=old", site.host)

      assert conn.status == 301
      assert location(conn) == "https://docs.example.com/start"
    end

    test "is matched however the request spells it, and its target is sent as ASCII", %{
      site: site
    } do
      rule!(site, %{from_path: "/fa/بلاگ/", to: "/fa/مجله"})

      conn = request("/fa/%D8%A8%D9%84%D8%A7%DA%AF/", site.host)

      assert conn.status == 301
      assert location(conn) == "/fa/%D9%85%D8%AC%D9%84%D9%87"
    end
  end

  describe "an address a rule names with a query" do
    test "is answered only when the request carries the query, alone or among others", %{
      site: site
    } do
      rule!(site, %{from_path: "/", from_query: "p=123", to: "/fa/وردپرس", status: 301})
      rule!(site, %{from_path: "/index.php", from_query: "page_id=7", to: "/about"})

      for path <- ["/?p=123", "/?utm_source=x&p=123"] do
        conn = request(path, site.host)
        assert conn.halted, path
        assert conn.status == 301
        assert location(conn) == "/fa/%D9%88%D8%B1%D8%AF%D9%BE%D8%B1%D8%B3"
      end

      assert location(request("/index.php?page_id=7", site.host)) == "/about"

      for path <- ["/", "/?p=124", "/index.php"] do
        refute request(path, site.host).halted, path
      end
    end

    test "wins over the rule on the path alone, which keeps the visitor's query", %{site: site} do
      rule!(site, %{from_path: "/old", to: "/new"})
      rule!(site, %{from_path: "/old", from_query: "cat=3", to: "/category/three"})

      assert location(request("/old?cat=3", site.host)) == "/category/three"
      assert location(request("/old?cat=4", site.host)) == "/new?cat=4"
      assert location(request("/old", site.host)) == "/new"
    end
  end

  describe "the visitor's request never becomes the target" do
    test "a query value carrying an address stays a query of the stored target", %{site: site} do
      rule!(site, %{from_path: "/old", to: "/new"})

      location = location(request("/old?next=https://evil.com&to=//evil.com", site.host))

      assert %URI{host: nil, path: "/new"} = URI.parse(location)
    end

    test "a wildcard rule never carries the value it matched", %{site: site} do
      rule!(site, %{from_path: "/", from_query: "p=*", to: "/blog"})

      assert location(request("/?p=https://evil.com", site.host)) == "/blog"
    end

    test "the Host header plays no part in where a visitor is sent", %{site: site} do
      rule!(site, %{from_path: "/old", to: "/new"})

      assert location(request("/old", site.host, [{"x-forwarded-host", "evil.com"}])) == "/new"
    end
  end

  describe "a rule on a wildcard query" do
    test "answers any value at its own path, and an exact rule wins over it", %{site: site} do
      rule!(site, %{from_path: "/", from_query: "p=*", to: "/blog"})
      rule!(site, %{from_path: "/", from_query: "p=1", to: "/one"})
      rule!(site, %{from_path: "/", from_query: "p=2", to: "/two"})

      assert location(request("/?p=1", site.host)) == "/one"
      assert location(request("/?p=2", site.host)) == "/two"
      assert location(request("/?p=3", site.host)) == "/blog"
      assert location(request("/?utm=x&p=1", site.host)) == "/one"
      refute request("/other?p=3", site.host).halted
      refute request("/", site.host).halted
    end

    test "a different query, or another site, is never answered with this rule", %{
      site: site,
      other: other
    } do
      rule!(site, %{from_path: "/", from_query: "p=1", to: "/one"})

      assert location(request("/?p=1", site.host)) == "/one"
      refute request("/?p=2", site.host).halted
      refute request("/?p=1", other.host).halted
    end
  end

  describe "a rule that answers 410 or 404" do
    test "raises the site's error page with its status, for no cache to keep", %{site: site} do
      rule!(site, %{kind: :gone, from_path: "/retired"})
      rule!(site, %{kind: :not_found, from_path: "/never"})

      for {path, status} <- [{"/retired", 410}, {"/never?x=1", 404}] do
        assert %Plug.Conn.WrapperError{conn: conn, reason: reason} =
                 catch_error(request(path, site.host))

        assert Plug.Exception.status(reason) == status
        assert conn.assigns.current_site.id == site.id
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end
  end

  describe "a rule that rewrites a page" do
    test "goes on to the page with the address kept and its target noted", %{site: site} do
      rule!(site, %{kind: :rewrite, from_path: "/", from_query: "p=55", to: "/fa/blog/hello"})

      conn = request("/?p=55", site.host)

      refute conn.halted
      assert conn.request_path == "/"
      assert conn.private[:mishka_cms_rewrite] == "/fa/blog/hello"
      assert get_resp_header(conn, "location") == []
      assert get_session(conn, :current_site).id == site.id
    end
  end

  describe "a rule that rewrites a media file" do
    setup %{site: site} do
      dir = Path.join(System.tmp_dir!(), "redirect-rewrite-#{System.unique_integer([:positive])}")
      folder = Path.join([dir, "uploads", site.id, "media", "images"])
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "title.webp"), "webp-bytes")
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf!(dir)
      end)

      :ok
    end

    test "serves the file at the address asked for, revalidated by any cache", %{site: site} do
      rule!(site, %{
        kind: :rewrite,
        from_path: "/images/title_announcement.jpg",
        to: "/uploads/#{site.id}/media/images/title.webp"
      })

      conn = request("/images/title_announcement.jpg", site.host, [{"accept", @image_accept}])

      assert conn.halted
      assert conn.status == 200
      assert conn.request_path == "/images/title_announcement.jpg"
      assert get_resp_header(conn, "location") == []
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/webp"
      assert get_resp_header(conn, "cache-control") == ["public, no-cache"]
      assert [_etag] = get_resp_header(conn, "etag")
    end

    test "a file that is not there is the site's 404", %{site: site} do
      rule!(site, %{
        kind: :rewrite,
        from_path: "/images/missing.jpg",
        to: "/uploads/#{site.id}/media/images/missing.webp"
      })

      assert %Plug.Conn.WrapperError{reason: reason} =
               catch_error(request("/images/missing.jpg", site.host))

      assert Plug.Exception.status(reason) == 404
    end
  end

  describe "a request no rule answers" do
    test "goes on to its page, the session written as before", %{site: site} do
      rule!(site, %{from_path: "/old", to: "/new"})

      conn = request("/about", site.host)

      refute conn.halted
      assert conn.status == nil
      assert get_session(conn, :current_site).id == site.id
      assert Ash.PlugHelpers.get_tenant(conn) == site.id
    end

    test "a rule switched off answers nothing", %{site: site} do
      rule!(site, %{from_path: "/old", to: "/new", active: false})

      refute request("/old", site.host).halted
    end

    test "another site's rule answers nothing here", %{site: site, other: other} do
      rule!(other, %{from_path: "/old", to: "/new"})

      refute request("/old", site.host).halted
      assert request("/old", other.host).status == 301
    end
  end

  describe "a static file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "redirect-static-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "images/blog"))
      File.write!(Path.join(dir, "images/blog/kept.jpg"), "kept")
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, static: Plug.Static.init(at: "/", from: dir, only: ~w(images))}
    end

    # `Plug.Static`, then the `:browser` pipeline up to the site lookup, as the CMS's endpoint and
    # router run them for an address no route but the catch-all takes.
    defp served(path, host, static) do
      conn(:get, path)
      |> Map.put(:req_headers, [{"host", host}, {"accept", @image_accept}])
      |> Plug.Static.call(static)
      |> then(fn
        %Plug.Conn{halted: true} = conn ->
          conn

        conn ->
          conn
          |> fetch_query_params()
          |> MishkaCmsCore.ExtensionRouter.route_accepts(["html"])
          |> init_test_session(%{})
          |> SiteLookupPlug.call(SiteLookupPlug.init([]))
      end)
    end

    test "that is missing falls through to the router and is redirected", %{
      site: site,
      static: static
    } do
      rule!(site, %{from_path: "/images/blog/gone.jpg", to: "/uploads/s/media/gone.jpg"})

      conn = served("/images/blog/gone.jpg", site.host, static)

      assert conn.halted
      assert conn.status == 301
      assert location(conn) == "/uploads/s/media/gone.jpg"
    end

    test "that exists is served as it is, whatever a rule says", %{site: site, static: static} do
      rule!(site, %{from_path: "/images/blog/kept.jpg", to: "/elsewhere.jpg"})

      conn = served("/images/blog/kept.jpg", site.host, static)

      assert conn.status == 200
      assert conn.resp_body == "kept"
      assert location(conn) == nil
    end
  end

  describe "web:request:redirected while it cannot run" do
    test "a rule's redirect is still answered", %{site: site} do
      EventCannotRun.stub!("web:request:redirected")
      rule!(site, %{from_path: "/old", to: "/new", status: 302})

      conn = request("/old", site.host)

      assert conn.halted
      assert conn.status == 302
      assert location(conn) == "/new"
    end
  end

  describe "web:request:redirected" do
    setup do
      Process.register(self(), :__plugin_hook_probe__)

      {:ok, _} =
        Event.write(%{
          name: WebRedirected,
          event: "web:request:redirected",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("web:request:redirected", :start, false)
      on_exit(fn -> Event.unregister(:name, WebRedirected, false) end)
      :ok
    end

    test "hears every answer first, and a plugin may change where it goes", %{site: site} do
      site_id = site.id
      rule!(site, %{from_path: "/old", to: "/new", status: 302})

      conn = request("/old?x=1", site.host)

      assert_receive {:redirected, ^site_id, "/old", {:redirect, "/new?x=1", 302}}
      assert conn.status == 302
      assert location(conn) == "/chosen-by-a-plugin"
    end

    test "a plugin may turn an answer into another kind, or serve none", %{site: site} do
      rule!(site, %{from_path: "/retire", to: "/new"})
      rule!(site, %{from_path: "/let-through", to: "/new"})

      assert %Plug.Conn.WrapperError{reason: reason} =
               catch_error(request("/retire", site.host))

      assert Plug.Exception.status(reason) == 410

      conn = request("/let-through", site.host)
      refute conn.halted
      assert get_session(conn, :current_site).id == site.id
    end

    test "an address no rule names never reaches it", %{site: site} do
      refute request("/about", site.host).halted
      refute_received {:redirected, _site_id, "/about", _answer}
    end
  end
end
